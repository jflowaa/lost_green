defmodule LostGreenWeb.DashboardLiveTest do
  use LostGreenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LostGreen.Accounts
  alias LostGreen.Metrics

  setup do
    Metrics.stop_all()
    on_exit(&Metrics.stop_all/0)
    :ok
  end

  test "renders the generic device flow for the selected profile", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        "handle" => "DashboardRider",
        "gender" => "male",
        "birthdate" => "1992-07-04",
        "height" => "68",
        "weight" => "170",
        "measurement_units" => "imperial"
      })

    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#devices-connect-button")
    assert has_element?(view, "#device-tray-heart_rate")
    assert has_element?(view, "#device-tray-power_meter")

    view
    |> element("#devices-connect-button")
    |> render_click()

    assert has_element?(view, "#device-modal-overlay")

    view
    |> element("#modal-type-heart_rate")
    |> render_click()

    render_hook(view, "devices_listed", %{
      "device_type" => "heart_rate",
      "devices" => [%{"id" => "hrm-1", "name" => "Polar H10"}]
    })

    assert has_element?(view, "#modal-device-0")

    render_hook(view, "device_connected", %{
      "device_type" => "heart_rate",
      "device" => %{"id" => "hrm-1", "name" => "Polar H10"}
    })

    assert has_element?(view, "#device-tray-heart_rate", "Polar H10")
    refute has_element?(view, "#device-modal-overlay")

    render_hook(view, "device_reading", %{
      "device_type" => "heart_rate",
      "value" => 147,
      "at" => 1_700_000_000_001
    })

    assert has_element?(view, "#heart-rate-value", "147")
  end
end
