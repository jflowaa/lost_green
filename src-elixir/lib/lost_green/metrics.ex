defmodule LostGreen.Metrics do
  @moduledoc false

  alias LostGreen.Metrics.CadenceServer
  alias LostGreen.Metrics.DeviceServer
  alias LostGreen.Metrics.HeartRateServer
  alias LostGreen.Metrics.PowerMeterServer
  alias LostGreen.Metrics.SecondaryPowerMeterServer
  alias LostGreen.Metrics.SmartTrainerServer

  @device_servers %{
    heart_rate_monitor: HeartRateServer,
    power_meter: PowerMeterServer,
    cadence_sensor: CadenceServer,
    smart_trainer: SmartTrainerServer,
    secondary_power_meter: SecondaryPowerMeterServer
  }

  @metric_defaults %{
    heart_rate: nil,
    calories: nil,
    calories_per_minute: nil,
    power: nil,
    secondary_power: nil,
    cadence: nil,
    distance: nil,
    trainer_speed: nil,
    trainer_resistance_factor: nil,
    trainer_target_power: nil,
    trainer_distance: nil
  }

  @doc """
  Get the latest snapshot of all metrics across all devices, along with metadata about connected devices and timestamps,
  then merge them into a single cohesive snapshot. This is the main entry point for getting all relevant metrics data for the dashboard.
  """
  def snapshot do
    Enum.each(@device_servers, fn {_type, module} -> ensure_server(module) end)

    Enum.reduce(@device_servers, empty_snapshot(), fn {device_type, module}, acc ->
      server_snapshot =
        case module do
          SmartTrainerServer ->
            module
            |> server_pid!()
            |> SmartTrainerServer.snapshot()

          _ ->
            module
            |> server_pid!()
            |> DeviceServer.snapshot()
        end

      merge_snapshot(acc, device_type, server_snapshot)
    end)
  end

  @doc """
  Gets the latest snapshot from the specified device server and returns the value of the requested metric.
  """
  def read_metric(device_type, metric) when is_atom(device_type) do
    snapshot =
      device_type
      |> ensure_server_for!()
      |> DeviceServer.snapshot()

    Map.get(snapshot.latest, metric)
  end

  @doc """
  Records a new metric value for the specified device type and metric, along with optional metadata.
  """
  def record_metric(device_type, metric, value, metadata \\ %{}) when is_atom(device_type) do
    pid = ensure_server_for!(device_type)

    device_snapshot =
      case device_type do
        :smart_trainer ->
          SmartTrainerServer.record_reading(pid, %{
            "watts" => if(metric != :trainer_speed, do: value),
            "speed_kph" => if(metric == :trainer_speed, do: value),
            "resistance_factor" => if(metric == :trainer_resistance_factor, do: value),
            "target_watts" => if(metric == :trainer_target_power, do: value),
            "distance_km" => if(metric == :trainer_distance, do: value),
            "at" => LostGreen.DataHelper.normalize_timestamp(metadata)
          })

        _ ->
          DeviceServer.record_metric(pid, metric, value, metadata)
      end

    merge_snapshot(snapshot(), device_type, device_snapshot)
  end

  def connect_device(device_type, attrs \\ %{}) when is_atom(device_type) do
    pid = ensure_server_for!(device_type)

    device_snapshot =
      case device_type do
        :smart_trainer -> SmartTrainerServer.connect_device(pid, attrs)
        _ -> DeviceServer.connect_device(pid, attrs)
      end

    merge_snapshot(snapshot(), device_type, device_snapshot)
  end

  def disconnect_device(device_type) when is_atom(device_type) do
    pid = ensure_server_for!(device_type)

    device_snapshot =
      case device_type do
        :smart_trainer -> SmartTrainerServer.disconnect_device(pid)
        _ -> DeviceServer.disconnect_device(pid)
      end

    merge_snapshot(snapshot(), device_type, device_snapshot)
  end

  def record_smart_trainer_reading(params) when is_map(params) do
    pid = ensure_server_for!(:smart_trainer)
    device_snapshot = SmartTrainerServer.record_reading(pid, params)
    merge_snapshot(snapshot(), :smart_trainer, device_snapshot)
  end

  @doc """
  Update the physics configuration on the smart trainer server, which is used to calculate speed.
  Properties include things like: rolling coefficient, slope, and drag.
  """
  def update_trainer_physics(attrs) when is_map(attrs) do
    pid = ensure_server_for!(:smart_trainer)
    _ = SmartTrainerServer.update_physics(pid, attrs)
    snapshot()
  end

  @doc """
  Get the current physics configuration from the smart trainer server, which is used to calculate speed.
  Properties include things like: rolling coefficient, slope, and drag.
  """
  def get_trainer_physics do
    pid = ensure_server_for!(:smart_trainer)
    SmartTrainerServer.physics(pid)
  end

  @doc """
  Seed the current rider's profile into the heart rate server so calorie
  calculations have the necessary context (age, weight, gender).
  """
  def set_user_profile_on_heart_rate(user) do
    ensure_server(HeartRateServer)

    case Process.whereis(HeartRateServer) do
      nil -> :ok
      pid -> HeartRateServer.set_user_profile(pid, LostGreen.DataHelper.normalize_profile(user))
    end
  end

  @doc """
  Seed the current rider's weight into the smart trainer server so power to speed
  calculations have the necessary context.
  """
  def set_user_profile_on_smart_trainer(user) do
    ensure_server(SmartTrainerServer)

    case Process.whereis(SmartTrainerServer) do
      nil ->
        :ok

      pid ->
        SmartTrainerServer.set_user_weight(
          pid,
          LostGreen.DataHelper.to_weight_kg(user.weight, user.measurement_units)
        )
    end
  end

  @doc "Start a workout window on the heart rate server."
  def start_workout do
    ensure_server(HeartRateServer)

    case Process.whereis(HeartRateServer) do
      nil -> :ok
      pid -> HeartRateServer.start_workout(pid)
    end
  end

  @doc "End the active workout window on the heart rate server."
  def end_workout do
    ensure_server(HeartRateServer)

    case Process.whereis(HeartRateServer) do
      nil -> :ok
      pid -> HeartRateServer.end_workout(pid)
    end
  end

  def stop_all do
    Enum.each(@device_servers, fn {_type, module} ->
      case Process.whereis(module) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    end)

    :ok
  end

  defp ensure_server_for!(device_type) do
    module = Map.fetch!(@device_servers, device_type)
    ensure_server(module)
    server_pid!(module)
  end

  defp ensure_server(module) do
    case DynamicSupervisor.start_child(LostGreen.Metrics.Supervisor, module) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _child}} -> :ok
      :ignore -> :ok
      other -> raise "unable to start metrics server #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp server_pid!(module) do
    case Process.whereis(module) do
      nil -> raise ArgumentError, "metrics server not found for #{inspect(module)}"
      pid -> pid
    end
  end

  defp empty_snapshot do
    %{
      latest: @metric_defaults,
      series: Map.new(Map.keys(@metric_defaults), &{&1, []}),
      devices: Map.new(Map.keys(@device_servers), &{&1, nil}),
      last_updated_at: nil
    }
  end

  defp merge_snapshot(acc, device_type, server_snapshot) do
    %{
      latest: Map.merge(acc.latest, server_snapshot.latest),
      series: Map.merge(acc.series, server_snapshot.series),
      devices: Map.put(acc.devices, device_type, server_snapshot.connected_device),
      last_updated_at: latest_timestamp(acc.last_updated_at, server_snapshot.last_updated_at)
    }
  end

  defp latest_timestamp(nil, timestamp), do: timestamp
  defp latest_timestamp(timestamp, nil), do: timestamp
  defp latest_timestamp(left, right), do: max(left, right)
end
