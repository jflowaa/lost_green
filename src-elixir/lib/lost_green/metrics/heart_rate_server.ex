defmodule LostGreen.Metrics.HeartRateServer do
  @moduledoc """
  Device server for heart rate monitors.

  In addition to tracking live heart rate readings it accumulates calorie
  expenditure using the Keytel et al. heart-rate-based formula:

      Men:
        Calories = (T × (0.2017·Age + 0.1988·Weight_kg + 0.6309·HR − 55.0969)) / 4.184

      Women:
        Calories = (T × (0.2017·Age − 0.074·Weight_kg + 0.4472·HR − 20.4022)) / 4.184

  where `T` is elapsed time in **minutes**.

  Calories accumulate from the moment a device is connected and reset on
  reconnect or disconnect. When a workout window is active (via `start_workout/1`)
  `latest.calories` reflects only the calories burned since the workout began;
  outside of a workout it reflects the full session total.

  Profile data (age, weight, gender) must be supplied via `set_user_profile/2`
  before calorie calculation can run. If any required field is absent the calorie
  fields remain `nil` and no accumulation occurs.
  """

  use GenServer

  @max_points 120
  @device_type :heart_rate_monitor

  # ── Public API ─────────────────────────────────────────────────────────────

  def child_spec(_opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :transient
    }
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # DeviceServer-compatible API so Metrics can route through DeviceServer helpers.
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def record_metric(pid, metric, value, metadata \\ %{}),
    do: GenServer.call(pid, {:record_metric, metric, value, metadata})

  def connect_device(pid, attrs \\ %{}), do: GenServer.call(pid, {:connect_device, attrs})
  def disconnect_device(pid), do: GenServer.call(pid, :disconnect_device)

  @doc "Load the current rider's profile so calorie calculations can run."
  def set_user_profile(pid, profile), do: GenServer.call(pid, {:set_user_profile, profile})

  @doc "Mark the start of a workout window. Snapshots will show calories burned within the window."
  def start_workout(pid), do: GenServer.call(pid, :start_workout)

  @doc "End the active workout window. Snapshots revert to showing the full session total."
  def end_workout(pid), do: GenServer.call(pid, :end_workout)

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:record_metric, :heart_rate, value, metadata}, _from, state) do
    value = LostGreen.DataHelper.normalize_int(value)
    at = LostGreen.DataHelper.normalize_timestamp(metadata)

    state =
      state
      |> put_in([:latest, :heart_rate], value)
      |> update_series(:heart_rate, %{value: value, at: at})
      |> accumulate_calories(value, at)
      |> Map.put(:last_updated_at, at)

    {:reply, build_snapshot(state), state}
  end

  def handle_call({:record_metric, _other, _value, _metadata}, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:connect_device, attrs}, _from, state) do
    now = System.system_time(:millisecond)

    state =
      state
      |> Map.put(:connected_device, LostGreen.DataHelper.normalize_device(attrs))
      |> Map.put(:total_calories, 0.0)
      |> Map.put(:workout_calories_offset, 0.0)
      |> Map.put(:workout_active?, false)
      |> Map.put(:workout_start_at, nil)
      |> Map.put(:last_hr_at, nil)
      |> put_in([:latest, :calories], nil)
      |> put_in([:latest, :calories_per_minute], nil)
      |> Map.update!(:series, &Map.put(&1, :calories, []))
      |> Map.put(:last_updated_at, now)

    {:reply, build_snapshot(state), state}
  end

  def handle_call(:disconnect_device, _from, state) do
    state =
      state
      |> Map.put(:connected_device, nil)
      |> Map.put(:last_hr_at, nil)
      |> Map.put(:last_updated_at, System.system_time(:millisecond))

    {:reply, build_snapshot(state), state}
  end

  def handle_call({:set_user_profile, profile}, _from, state) do
    {:reply, :ok, Map.put(state, :user_profile, LostGreen.DataHelper.normalize_profile(profile))}
  end

  def handle_call(:start_workout, _from, state) do
    state =
      state
      |> Map.put(:workout_active?, true)
      |> Map.put(:workout_calories_offset, state.total_calories)
      |> Map.put(:workout_start_at, System.system_time(:millisecond))

    {:reply, build_snapshot(state), state}
  end

  def handle_call(:end_workout, _from, state) do
    state =
      state
      |> Map.put(:workout_active?, false)
      |> Map.put(:workout_start_at, nil)

    {:reply, build_snapshot(state), state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp initial_state do
    %{
      device_type: @device_type,
      connected_device: nil,
      latest: %{heart_rate: nil, calories: nil, calories_per_minute: nil},
      series: %{heart_rate: [], calories: []},
      last_updated_at: nil,
      total_calories: 0.0,
      workout_calories_offset: 0.0,
      workout_active?: false,
      workout_start_at: nil,
      last_hr_at: nil,
      user_profile: %{age: nil, weight_kg: nil, gender: nil}
    }
  end

  defp build_snapshot(state) do
    displayed_calories =
      if state.workout_active? do
        state.total_calories - state.workout_calories_offset
      else
        state.total_calories
      end

    calories_rounded = if displayed_calories > 0, do: Float.round(displayed_calories, 1)

    %{
      device_type: state.device_type,
      latest: %{
        heart_rate: state.latest.heart_rate,
        calories: calories_rounded,
        calories_per_minute: state.latest.calories_per_minute
      },
      series: state.series,
      connected_device: state.connected_device,
      last_updated_at: state.last_updated_at
    }
  end

  defp accumulate_calories(state, hr, at) do
    %{age: age, weight_kg: weight_kg, gender: gender} = state.user_profile

    rate = calories_per_minute(gender, age, weight_kg, hr)

    elapsed_minutes =
      case state.last_hr_at do
        nil -> 0.0
        prev -> max(0.0, (at - prev) / 60_000.0)
      end

    interval_calories = if rate && elapsed_minutes > 0, do: rate * elapsed_minutes, else: 0.0

    new_total = state.total_calories + interval_calories

    calories_per_minute_rounded = if rate, do: Float.round(max(0.0, rate), 2)

    state
    |> Map.put(:total_calories, new_total)
    |> Map.put(:last_hr_at, at)
    |> update_series(:calories, %{value: Float.round(new_total, 1), at: at})
    |> put_in([:latest, :calories_per_minute], calories_per_minute_rounded)
  end

  # All three profile fields are required; return nil when any is absent.
  defp calories_per_minute(_gender, nil, _weight_kg, _hr), do: nil
  defp calories_per_minute(_gender, _age, nil, _hr), do: nil

  defp calories_per_minute(:male, age, weight_kg, hr) do
    (0.2017 * age + 0.1988 * weight_kg + 0.6309 * hr - 55.0969) / 4.184
  end

  defp calories_per_minute(:female, age, weight_kg, hr) do
    (0.2017 * age - 0.074 * weight_kg + 0.4472 * hr - 20.4022) / 4.184
  end

  defp calories_per_minute(_unknown, age, weight_kg, hr) do
    # Unknown gender: average the two formulas.
    male = (0.2017 * age + 0.1988 * weight_kg + 0.6309 * hr - 55.0969) / 4.184
    female = (0.2017 * age - 0.074 * weight_kg + 0.4472 * hr - 20.4022) / 4.184
    (male + female) / 2.0
  end

  defp update_series(state, metric, point) do
    update_in(state, [:series, metric], fn series ->
      (series ++ [point]) |> Enum.take(-@max_points)
    end)
  end
end
