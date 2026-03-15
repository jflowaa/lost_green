defmodule LostGreenWeb.DashboardLive do
  use LostGreenWeb, :live_view

  alias LostGreen.Metrics
  alias LostGreenWeb.DashboardComponents

  @chart_width 320
  @chart_height 120

  @device_defs [
    %{
      key: "smart_trainer",
      atom: :smart_trainer,
      label: "Smart Trainer",
      icon: "hero-rocket-launch",
      metric: :trainer_speed,
      unit: "km/h",
      value_field: "speed_kph"
    },
    %{
      key: "power_meter",
      atom: :power_meter,
      label: "Power Meter",
      icon: "hero-bolt",
      metric: :power,
      unit: "W",
      value_field: "watts"
    },
    %{
      key: "cadence",
      atom: :cadence_sensor,
      label: "Cadence",
      icon: "hero-arrow-path",
      metric: :cadence,
      unit: "rpm",
      value_field: "rpm"
    },
    %{
      key: "heart_rate",
      atom: :heart_rate_monitor,
      label: "Heart Rate",
      icon: "hero-heart",
      metric: :heart_rate,
      unit: "bpm",
      value_field: "value"
    },
    %{
      key: "secondary_power_meter",
      atom: :secondary_power_meter,
      label: "Secondary Power Meter",
      icon: "hero-bolt",
      metric: :secondary_power,
      unit: "W",
      value_field: "watts"
    }
  ]

  def mount(_params, _session, socket) do
    app_name = Application.get_env(:lost_green, :application_name, "Lost Green")
    Metrics.set_user_profile(socket.assigns.current_user)
    Metrics.set_trainer_profile(socket.assigns.current_user)
    metrics = Metrics.snapshot()
    trainer_physics = Metrics.trainer_physics()

    {:ok,
     socket
     |> assign(:page_title, "Dashboard · #{app_name}")
     |> assign(:device_defs, @device_defs)
     |> assign(:device_modal_open?, false)
     |> assign(:modal_step, :pick_type)
     |> assign(:modal_device_type, nil)
     |> assign(:modal_available_devices, [])
     |> assign(:trainer_physics, trainer_physics)
     |> assign(:trainer_physics_form, trainer_physics_form(trainer_physics))
     |> assign(:trainer_resistance_factor_form, trainer_resistance_factor_form(trainer_physics))
     |> assign(:metrics, metrics)}
  end

  # ── Modal lifecycle ──────────────────────────────────────────────────────────

  def handle_event("open_device_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:device_modal_open?, true)
     |> assign(:modal_step, :pick_type)
     |> assign(:modal_device_type, nil)
     |> assign(:modal_available_devices, [])}
  end

  def handle_event("close_device_modal", _params, socket) do
    {:noreply, assign(socket, :device_modal_open?, false)}
  end

  def handle_event("pick_device_type", %{"device_type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:modal_step, :pick_device)
     |> assign(:modal_device_type, type)
     |> assign(:modal_available_devices, [])
     |> push_event("request_device_list", %{device_type: type})}
  end

  def handle_event("back_to_type_picker", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_step, :pick_type)
     |> assign(:modal_device_type, nil)
     |> assign(:modal_available_devices, [])}
  end

  # ── Device events from the JS DeviceBridge hook ──────────────────────────────

  def handle_event("devices_listed", %{"device_type" => type, "devices" => devices}, socket) do
    {:noreply,
     socket
     |> assign(:modal_available_devices, normalize_devices(devices))
     |> assign(:modal_step, :pick_device)
     |> assign(:modal_device_type, type)
     |> assign(:device_modal_open?, true)}
  end

  def handle_event("device_connected", %{"device_type" => type, "device" => device}, socket) do
    case find_device_def(type) do
      nil ->
        {:noreply, socket}

      d ->
        snapshot = Metrics.connect_device(d.atom, device)

        {:noreply,
         socket
         |> assign(:device_modal_open?, false)
         |> assign(:metrics, snapshot)}
    end
  end

  def handle_event("device_disconnected", %{"device_type" => type}, socket) do
    case find_device_def(type) do
      nil ->
        {:noreply, socket}

      d ->
        snapshot = Metrics.disconnect_device(d.atom)
        {:noreply, assign(socket, :metrics, snapshot)}
    end
  end

  def handle_event("device_reading", %{"device_type" => type} = params, socket) do
    case find_device_def(type) do
      nil ->
        {:noreply, socket}

      d ->
        if should_record_reading?(socket.assigns.metrics.devices, d.atom, params) do
          snapshot =
            if d.atom == :smart_trainer do
              Metrics.record_smart_trainer_reading(params)
            else
              value = Map.get(params, d.value_field)
              Metrics.record_metric(d.atom, d.metric, value, %{at: params["at"]})
            end

          {:noreply, assign(socket, :metrics, snapshot)}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("device_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("update_trainer_physics", %{"trainer_physics" => params}, socket) do
    physics = trainer_physics_params(params, socket.assigns.trainer_physics)

    snapshot = Metrics.update_trainer_physics(physics)
    trainer_physics = Metrics.trainer_physics()

    {:noreply,
     socket
     |> assign(:metrics, snapshot)
     |> assign(:trainer_physics, trainer_physics)
     |> assign(:trainer_physics_form, trainer_physics_form(trainer_physics))
     |> assign(:trainer_resistance_factor_form, trainer_resistance_factor_form(trainer_physics))}
  end

  def handle_event(
        "set_trainer_resistance_factor",
        %{"trainer_resistance_factor" => params},
        socket
      ) do
    resistance_factor =
      params["value"]
      |> parse_int_param(socket.assigns.trainer_physics.resistance_factor || 0)
      |> normalize_resistance_factor()

    {:noreply,
     socket
     |> assign(
       :trainer_resistance_factor_form,
       trainer_resistance_factor_form(%{value: resistance_factor})
     )
     |> push_event("set_trainer_resistance_factor", %{resistance_factor: resistance_factor})}
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(assigns) do
    chart_points = heart_rate_chart_points(assigns.metrics.series.heart_rate)

    assigns =
      assigns
      |> assign(:chart_points, chart_points)
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)

    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="device-bridge"
        phx-hook="DeviceBridge"
        data-connected-devices={connected_devices_json(@metrics.devices)}
        class="space-y-8"
      >
        <DashboardComponents.dashboard_header current_user={@current_user} />

        <DashboardComponents.trainer_physics_section
          metrics={@metrics}
          trainer_physics_form={@trainer_physics_form}
          trainer_resistance_factor_form={@trainer_resistance_factor_form}
        />

        <DashboardComponents.devices_section
          device_defs={@device_defs}
          metrics={@metrics}
          current_user={@current_user}
        />

        <DashboardComponents.heart_rate_panel
          :if={@metrics.latest.heart_rate || @metrics.series.heart_rate != []}
          metrics={@metrics}
          chart_points={@chart_points}
          chart_width={@chart_width}
          chart_height={@chart_height}
        />

        <DashboardComponents.device_modal
          :if={@device_modal_open?}
          modal_step={@modal_step}
          device_defs={@device_defs}
          modal_device_type={@modal_device_type}
          modal_available_devices={@modal_available_devices}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp find_device_def(type) when is_binary(type) do
    Enum.find(@device_defs, &(&1.key == type))
  end

  defp normalize_devices(devices) when is_list(devices) do
    Enum.map(devices, fn device ->
      %{
        id: Map.get(device, "id") || Map.get(device, :id),
        name: Map.get(device, "name") || Map.get(device, :name) || "Unknown Device"
      }
    end)
  end

  defp normalize_devices(_), do: []

  defp should_record_reading?(devices, device_atom, params) do
    case Map.get(devices, device_atom) do
      %{id: connected_id} when is_binary(connected_id) and connected_id != "" ->
        case reading_source_id(params) do
          nil -> true
          source_id -> source_id == connected_id
        end

      _ ->
        false
    end
  end

  defp parse_float_param(nil, default), do: default
  defp parse_float_param(value, _default) when is_float(value), do: value
  defp parse_float_param(value, _default) when is_integer(value), do: value / 1.0

  defp parse_float_param(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_float_param(_, default), do: default

  defp parse_int_param(nil, default), do: default
  defp parse_int_param(value, _default) when is_integer(value), do: value

  defp parse_int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int_param(_, default), do: default

  defp normalize_resistance_factor(nil), do: 0

  defp normalize_resistance_factor(value) when is_float(value),
    do: value |> round() |> normalize_resistance_factor()

  defp normalize_resistance_factor(value) when is_integer(value) do
    value
    |> max(0)
    |> min(100)
  end

  defp trainer_physics_form(physics) do
    physics
    |> trainer_physics_form_values()
    |> to_form(as: :trainer_physics)
  end

  defp trainer_resistance_factor_form(%{value: value}) do
    to_form(%{"value" => normalize_resistance_factor(value)}, as: :trainer_resistance_factor)
  end

  defp trainer_resistance_factor_form(physics) do
    to_form(
      %{"value" => normalize_resistance_factor(Map.get(physics, :resistance_factor, 0))},
      as: :trainer_resistance_factor
    )
  end

  defp trainer_physics_form_values(physics) do
    %{
      "gravity" => physics.gravity,
      "air_density" => physics.air_density,
      "drag" => physics.drag,
      "slope" => physics.slope,
      "rolling_resistance" => physics.rolling_resistance
    }
  end

  defp trainer_physics_params(params, current_physics) do
    %{
      gravity: parse_float_param(params["gravity"], current_physics.gravity),
      air_density: parse_float_param(params["air_density"], current_physics.air_density),
      drag: parse_float_param(params["drag"], current_physics.drag),
      slope: parse_float_param(params["slope"], current_physics.slope),
      rolling_resistance:
        parse_float_param(params["rolling_resistance"], current_physics.rolling_resistance)
    }
  end

  defp reading_source_id(params) do
    source = Map.get(params, "source_id") || Map.get(params, "device_id")

    if is_binary(source) and source != "" do
      source
    end
  end

  defp connected_devices_json(devices) do
    devices
    |> Enum.reduce(%{}, fn {device_type, device}, acc ->
      case device do
        %{id: id, name: name} when is_binary(id) and id != "" ->
          Map.put(acc, device_type_key(device_type), %{id: id, name: name})

        _ ->
          acc
      end
    end)
    |> Jason.encode!()
  end

  defp device_type_key(:heart_rate_monitor), do: "heart_rate"
  defp device_type_key(:power_meter), do: "power_meter"
  defp device_type_key(:cadence_sensor), do: "cadence"
  defp device_type_key(:smart_trainer), do: "smart_trainer"
  defp device_type_key(:secondary_power_meter), do: "secondary_power_meter"

  defp heart_rate_chart_points([]), do: []

  defp heart_rate_chart_points(series) do
    min_value = Enum.min_by(series, & &1.value).value
    max_value = Enum.max_by(series, & &1.value).value
    range = max(max_value - min_value, 1)
    step = if length(series) == 1, do: 0.0, else: @chart_width / (length(series) - 1)

    series
    |> Enum.with_index()
    |> Enum.map(fn {%{value: value}, index} ->
      x = Float.round(index * step * 1.0, 2)
      y = Float.round(@chart_height - (value - min_value) / range * (@chart_height - 20) - 10, 2)
      %{x: x, y: y}
    end)
  end
end
