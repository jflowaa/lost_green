defmodule LostGreen.Metrics.SmartTrainerServer do
  @moduledoc false

  use GenServer

  @tracked_metrics [
    :trainer_speed,
    :trainer_resistance_factor,
    :trainer_target_power,
    :trainer_distance
  ]
  @device_type :smart_trainer
  @max_points 120

  @default_physics %{
    gravity: 9.80665,
    air_density: 1.225,
    drag: 0.32,
    slope: 0.0,
    rolling_resistance: 0.005,
    user_weight_kg: 75.0,
    resistance_factor: nil
  }

  def child_spec(_opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :transient
    }
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def connect_device(pid, attrs \\ %{}) when is_pid(pid) do
    GenServer.call(pid, {:connect_device, attrs})
  end

  def disconnect_device(pid) when is_pid(pid) do
    GenServer.call(pid, :disconnect_device)
  end

  def record_reading(pid, params) when is_pid(pid) do
    GenServer.call(pid, {:record_reading, params})
  end

  def update_physics(pid, attrs) when is_pid(pid) do
    GenServer.call(pid, {:update_physics, attrs})
  end

  def physics(pid) when is_pid(pid) do
    GenServer.call(pid, :physics)
  end

  def set_user_weight(pid, weight_kg) when is_pid(pid) do
    GenServer.call(pid, {:set_user_weight, weight_kg})
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       latest: Map.new(@tracked_metrics, &{&1, nil}),
       series: Map.new(@tracked_metrics, &{&1, []}),
       connected_device: nil,
       last_updated_at: nil,
       physics: @default_physics,
       last_speed_at: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:connect_device, attrs}, _from, state) do
    state =
      state
      |> Map.put(:connected_device, LostGreen.DataHelper.normalize_device(attrs))
      |> Map.put(:last_updated_at, System.system_time(:millisecond))

    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:disconnect_device, _from, state) do
    state =
      state
      |> Map.put(:connected_device, nil)
      |> Map.put(:last_updated_at, System.system_time(:millisecond))

    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:record_reading, params}, _from, state) do
    at = LostGreen.DataHelper.normalize_timestamp(params)
    watts = parse_number(Map.get(params, "watts"), nil)

    resistance_factor =
      parse_number(Map.get(params, "resistance_factor"), nil)

    target_watts = parse_number(Map.get(params, "target_watts"), nil)
    fallback_speed = parse_number(Map.get(params, "speed_kph"), nil)

    speed_kph =
      case watts do
        value when is_number(value) and value > 0 ->
          estimate_speed_kph(value, state.physics)

        _ ->
          fallback_speed
      end

    distance_km =
      advance_distance_km(
        state.latest.trainer_distance || 0.0,
        state.last_speed_at,
        at,
        speed_kph || 0.0
      )

    metrics =
      []
      |> maybe_metric(:trainer_speed, speed_kph)
      |> maybe_metric(:trainer_resistance_factor, resistance_factor)
      |> maybe_metric(:trainer_target_power, target_watts)
      |> maybe_metric(:trainer_distance, distance_km)

    state =
      Enum.reduce(metrics, state, fn {metric, value}, acc ->
        point = %{at: at, value: value}

        acc
        |> put_in([:latest, metric], value)
        |> update_in([:series, metric], fn series ->
          series
          |> Kernel.++([point])
          |> Enum.take(-@max_points)
        end)
      end)
      |> Map.put(:last_updated_at, at)
      |> update_in([:physics], fn physics ->
        case resistance_factor do
          value when is_number(value) -> Map.put(physics, :resistance_factor, round(value))
          _ -> physics
        end
      end)
      |> Map.put(:last_speed_at, if(is_number(speed_kph), do: at, else: state.last_speed_at))

    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:update_physics, attrs}, _from, state) do
    physics =
      state.physics
      |> Map.merge(%{
        gravity:
          parse_number(
            Map.get(attrs, :gravity),
            state.physics.gravity
          ),
        air_density:
          parse_number(
            Map.get(attrs, :air_density),
            state.physics.air_density
          ),
        drag: parse_number(Map.get(attrs, :drag), state.physics.drag),
        slope:
          parse_number(Map.get(attrs, :slope), state.physics.slope),
        rolling_resistance:
          parse_number(
            Map.get(attrs, :rolling_resistance),
            state.physics.rolling_resistance
          )
      })

    {:reply, physics, %{state | physics: physics}}
  end

  def handle_call(:physics, _from, state) do
    {:reply, state.physics, state}
  end

  def handle_call({:set_user_weight, weight_kg}, _from, state) do
    parsed = parse_number(weight_kg, state.physics.user_weight_kg)
    physics = Map.put(state.physics, :user_weight_kg, max(parsed, 1.0))
    {:reply, physics, %{state | physics: physics}}
  end

  defp snapshot_from_state(state) do
    %{
      device_type: @device_type,
      latest: state.latest,
      series: state.series,
      connected_device: state.connected_device,
      last_updated_at: state.last_updated_at
    }
  end

  defp parse_number(nil, default), do: default
  defp parse_number(value, _default) when is_float(value), do: value
  defp parse_number(value, _default) when is_integer(value), do: value / 1.0

  defp parse_number(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_number(_, default), do: default

  defp maybe_metric(metrics, _metric, nil), do: metrics
  defp maybe_metric(metrics, _metric, value) when is_binary(value) and value == "", do: metrics
  defp maybe_metric(metrics, metric, value), do: [{metric, value} | metrics]

  defp advance_distance_km(distance_km, nil, _at, _speed_kph), do: distance_km

  defp advance_distance_km(distance_km, previous_at, at, speed_kph)
       when is_integer(previous_at) and is_integer(at) and at >= previous_at do
    dt_hours = (at - previous_at) / 3_600_000
    distance_km + speed_kph * dt_hours
  end

  defp advance_distance_km(distance_km, _previous_at, _at, _speed_kph), do: distance_km

  defp estimate_speed_kph(power_watts, physics) do
    gravity = max(physics.gravity, 0.1)
    air_density = max(physics.air_density, 0.0)
    drag_area = max(physics.drag, 0.0001)
    rolling_resistance = max(physics.rolling_resistance, 0.0)
    user_weight_kg = max(physics.user_weight_kg, 1.0)
    slope = physics.slope / 100.0
    theta = :math.atan(slope)

    a = 0.5 * air_density * drag_area
    b = user_weight_kg * gravity * (rolling_resistance * :math.cos(theta) + :math.sin(theta))

    solve_speed_newton(power_watts, a, b)
  end

  defp solve_speed_newton(power_watts, a, b) do
    initial = max(power_watts / max(b + 1.0, 1.0), 1.0)

    v_ms =
      Enum.reduce(1..12, initial, fn _, v ->
        f = a * v * v * v + b * v - power_watts
        fp = 3.0 * a * v * v + b

        if fp <= 0.0001 do
          v
        else
          max(v - f / fp, 0.0)
        end
      end)

    v_ms * 3.6
  end
end
