defmodule LostGreen.Metrics.SecondaryPowerMeterServer do
  @moduledoc false

  alias LostGreen.Metrics.DeviceServer

  @tracked_metrics [:secondary_power]
  @device_type :secondary_power_meter

  def child_spec(_opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :transient
    }
  end

  def start_link(_opts \\ []) do
    DeviceServer.start_link(
      name: __MODULE__,
      device_type: @device_type,
      tracked_metrics: @tracked_metrics
    )
  end
end
