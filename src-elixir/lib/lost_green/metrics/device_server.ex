defmodule LostGreen.Metrics.DeviceServer do
  @moduledoc false

  use GenServer

  @max_points 120

  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def record_metric(pid, metric, value, metadata \\ %{}) when is_pid(pid) do
    GenServer.call(pid, {:record_metric, metric, value, metadata})
  end

  def connect_device(pid, attrs \\ %{}) when is_pid(pid) do
    GenServer.call(pid, {:connect_device, attrs})
  end

  def disconnect_device(pid) when is_pid(pid) do
    GenServer.call(pid, :disconnect_device)
  end

  @impl true
  def init(opts) do
    tracked_metrics = Keyword.fetch!(opts, :tracked_metrics)
    device_type = Keyword.fetch!(opts, :device_type)

    {:ok,
     %{
       device_type: device_type,
       tracked_metrics: tracked_metrics,
       latest: Map.new(tracked_metrics, &{&1, nil}),
       series: Map.new(tracked_metrics, &{&1, []}),
       connected_device: nil,
       last_updated_at: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:record_metric, metric, value, metadata}, _from, state) do
    metric = normalize_metric(metric, state.tracked_metrics)

    point = %{
      at: LostGreen.DataHelper.normalize_timestamp(metadata),
      value: normalize_value(value)
    }

    state =
      state
      |> put_in([:latest, metric], point.value)
      |> update_in([:series, metric], fn series ->
        series
        |> Kernel.++([point])
        |> Enum.take(-@max_points)
      end)
      |> Map.put(:last_updated_at, point.at)

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

  defp snapshot_from_state(state) do
    %{
      device_type: state.device_type,
      latest: state.latest,
      series: state.series,
      connected_device: state.connected_device,
      last_updated_at: state.last_updated_at
    }
  end

  defp normalize_metric(metric, tracked_metrics) when is_binary(metric) do
    metric
    |> String.to_existing_atom()
    |> normalize_metric(tracked_metrics)
  rescue
    ArgumentError -> raise ArgumentError, "unsupported metric #{inspect(metric)}"
  end

  defp normalize_metric(metric, tracked_metrics) do
    if metric in tracked_metrics do
      metric
    else
      raise ArgumentError, "unsupported metric #{inspect(metric)}"
    end
  end

  defp normalize_value(value) when is_integer(value), do: value
  defp normalize_value(value) when is_float(value), do: value

  defp normalize_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> raise ArgumentError, "metric value must be numeric"
    end
  end

  defp normalize_value(_value), do: raise(ArgumentError, "metric value must be numeric")
end
