defmodule LostGreen.MetricsTest do
  use ExUnit.Case, async: false

  alias LostGreen.Metrics

  setup do
    Metrics.stop_all()
    on_exit(&Metrics.stop_all/0)
    :ok
  end

  test "stores connected devices and rolling heart rate ticks per device type" do
    snapshot = Metrics.snapshot()

    assert snapshot.latest.heart_rate == nil
    assert snapshot.devices.heart_rate_monitor == nil

    snapshot =
      Metrics.connect_device(:heart_rate_monitor, %{"id" => "hrm-1", "name" => "Polar H10"})

    assert snapshot.devices.heart_rate_monitor.id == "hrm-1"
    assert snapshot.devices.heart_rate_monitor.name == "Polar H10"

    snapshot =
      Enum.reduce(1..125, snapshot, fn tick, _snapshot ->
        Metrics.record_metric(:heart_rate_monitor, :heart_rate, 120 + rem(tick, 5), %{
          at: 1_700_000_000_000 + tick
        })
      end)

    assert snapshot.latest.heart_rate in 120..124
    assert length(snapshot.series.heart_rate) == 120

    assert Metrics.read_metric(:heart_rate_monitor, :heart_rate) == snapshot.latest.heart_rate

    snapshot = Metrics.disconnect_device(:heart_rate_monitor)
    assert snapshot.devices.heart_rate_monitor == nil
  end
end
