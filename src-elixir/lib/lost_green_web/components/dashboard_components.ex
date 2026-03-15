defmodule LostGreenWeb.DashboardComponents do
  use LostGreenWeb, :html

  attr :current_user, :map, required: true

  def dashboard_header(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.24em] text-primary/80">
          Live training dashboard
        </p>
        <h1 class="mt-2 text-3xl font-semibold tracking-tight">
          Welcome, {@current_user.handle}
        </h1>
        <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/70">
          Connect your training devices to stream live data into your session.
        </p>
      </div>
      <div class="flex items-center gap-2">
        <.link href={~p"/profile/edit"} class="btn btn-ghost btn-sm rounded-lg">
          Edit Profile
        </.link>
        <.form
          for={%{}}
          action={~p"/logout"}
          method="delete"
          id="change-profile-form"
          data-device-logout
        >
          <button type="submit" class="btn btn-ghost btn-sm rounded-lg">
            Change Profile
          </button>
        </.form>
      </div>
    </section>
    """
  end

  attr :metrics, :map, required: true
  attr :trainer_physics_form, :map, required: true
  attr :trainer_resistance_factor_form, :map, required: true

  def trainer_physics_section(assigns) do
    ~H"""
    <%= if Map.get(@metrics.devices, :smart_trainer) do %>
      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body p-5">
          <div class="mb-3 flex items-center justify-between gap-2">
            <h3 class="text-xs font-semibold uppercase tracking-[0.24em] text-base-content/55">
              Trainer Physics
            </h3>
            <span class="text-xs text-base-content/45">Used for speed + distance estimation</span>
          </div>

          <.form
            for={@trainer_physics_form}
            id="trainer-physics-form"
            phx-change="update_trainer_physics"
          >
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              <.input
                field={@trainer_physics_form[:gravity]}
                type="number"
                step="0.0001"
                min="0"
                label="Gravity"
              />
              <.input
                field={@trainer_physics_form[:air_density]}
                type="number"
                step="0.0001"
                min="0"
                label="Air Density"
              />
              <.input
                field={@trainer_physics_form[:drag]}
                type="number"
                step="0.0001"
                min="0"
                label="Drag (CdA)"
              />
              <.input
                field={@trainer_physics_form[:slope]}
                type="number"
                step="0.01"
                label="Slope (%)"
              />
              <.input
                field={@trainer_physics_form[:rolling_resistance]}
                type="number"
                step="0.0001"
                min="0"
                label="Rolling Coefficient"
              />
            </div>
          </.form>

          <.form
            for={@trainer_resistance_factor_form}
            id="trainer-resistance-factor-form"
            phx-submit="set_trainer_resistance_factor"
            class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between"
          >
            <div class="flex-1">
              <.input
                field={@trainer_resistance_factor_form[:value]}
                type="number"
                step="1"
                min="0"
                max="100"
                label="Trainer Resistance Factor"
              />
            </div>

            <div class="flex items-center justify-between gap-3 sm:justify-end">
              <p class="text-xs text-base-content/55">
                Applies only after the trainer acknowledges the command.
              </p>
              <button type="submit" class="btn btn-primary btn-sm rounded-xl">
                Apply Resistance Factor
              </button>
            </div>
          </.form>
        </div>
      </section>
    <% end %>
    """
  end

  attr :device_defs, :list, required: true
  attr :metrics, :map, required: true
  attr :current_user, :map, required: true

  def devices_section(assigns) do
    ~H"""
    <section>
      <div class="mb-4 flex items-center justify-between gap-3">
        <h2 class="text-xs font-semibold uppercase tracking-[0.24em] text-base-content/50">
          Devices
        </h2>
        <button
          id="devices-connect-button"
          type="button"
          phx-click="open_device_modal"
          class="btn btn-primary btn-xs rounded-lg"
        >
          Connect Device
        </button>
      </div>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <.device_tray_tile
          :for={d <- @device_defs}
          device_def={d}
          current_user={@current_user}
          connected={Map.get(@metrics.devices, d.atom)}
          smart_trainer={Map.get(@metrics.devices, :smart_trainer)}
          reading={Map.get(@metrics.latest, d.metric)}
        />
      </div>
    </section>
    """
  end

  attr :metrics, :map, required: true
  attr :chart_points, :list, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true

  def heart_rate_panel(assigns) do
    ~H"""
    <section class="card overflow-hidden border border-base-300 bg-base-100 shadow-sm">
      <div class="card-body gap-5 p-6">
        <div class="flex flex-wrap items-start justify-between gap-6">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-primary/80">
              Heart rate
            </p>
            <div class="mt-1 flex items-end gap-2">
              <span id="heart-rate-value" class="text-5xl font-semibold tracking-tight">
                {@metrics.latest.heart_rate || "--"}
              </span>
              <span class="pb-1 text-sm font-medium uppercase tracking-[0.2em] text-base-content/55">
                bpm
              </span>
            </div>
          </div>

          <div class="flex gap-8">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-primary/80">
                Calories
              </p>
              <div class="mt-1 flex items-end gap-2">
                <span id="calories-value" class="text-5xl font-semibold tracking-tight">
                  {@metrics.latest.calories || "--"}
                </span>
                <span class="pb-1 text-sm font-medium uppercase tracking-[0.2em] text-base-content/55">
                  kcal
                </span>
              </div>
            </div>
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-primary/80">
                Burn rate
              </p>
              <div class="mt-1 flex items-end gap-2">
                <span id="calories-per-minute-value" class="text-5xl font-semibold tracking-tight">
                  {@metrics.latest.calories_per_minute || "--"}
                </span>
                <span class="pb-1 text-sm font-medium uppercase tracking-[0.2em] text-base-content/55">
                  kcal/min
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="relative h-40 rounded-2xl border border-base-300/80 bg-base-100/80 p-3">
          <%= if @chart_points == [] do %>
            <div class="flex h-full items-center justify-center rounded-xl border border-dashed border-base-300 text-center text-sm text-base-content/55">
              Streaming heart rate data will appear here.
            </div>
          <% else %>
            <svg
              viewBox={"0 0 #{@chart_width} #{@chart_height}"}
              class="h-full w-full"
              role="img"
              aria-label="Real-time heart rate chart"
            >
              <line
                x1="0"
                y1="20"
                x2={@chart_width}
                y2="20"
                stroke="currentColor"
                stroke-opacity="0.08"
              />
              <line
                x1="0"
                y1="60"
                x2={@chart_width}
                y2="60"
                stroke="currentColor"
                stroke-opacity="0.08"
              />
              <line
                x1="0"
                y1="100"
                x2={@chart_width}
                y2="100"
                stroke="currentColor"
                stroke-opacity="0.08"
              />
              <polyline
                fill="none"
                stroke="#f97316"
                stroke-width="4"
                stroke-linecap="round"
                stroke-linejoin="round"
                points={chart_polyline(@chart_points)}
              />
              <circle
                :for={point <- @chart_points}
                cx={point.x}
                cy={point.y}
                r="3.5"
                fill="#84cc16"
              />
            </svg>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :modal_step, :atom, required: true
  attr :device_defs, :list, required: true
  attr :modal_device_type, :string, default: nil
  attr :modal_available_devices, :list, required: true

  def device_modal(assigns) do
    ~H"""
    <div
      id="device-modal-overlay"
      class="fixed inset-0 z-30 flex items-center justify-center bg-base-content/30 p-4 backdrop-blur-sm"
    >
      <div class="w-full max-w-lg rounded-3xl border border-base-300 bg-base-100 p-6 shadow-2xl">
        <div class="mb-6 flex items-start justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.24em] text-primary/80">
              Device manager
            </p>
            <%= cond do %>
              <% @modal_step == :pick_type -> %>
                <h3 class="mt-1 text-xl font-semibold tracking-tight">
                  Select device type
                </h3>
              <% true -> %>
                <h3 class="mt-1 text-xl font-semibold tracking-tight">
                  {label_for_type(@device_defs, @modal_device_type)}
                </h3>
            <% end %>
          </div>
          <button
            id="device-modal-close"
            type="button"
            phx-click="close_device_modal"
            class="btn btn-ghost btn-sm rounded-xl"
          >
            Close
          </button>
        </div>

        <%= cond do %>
          <% @modal_step == :pick_type -> %>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
              <button
                :for={d <- @device_defs}
                id={"modal-type-#{d.key}"}
                type="button"
                phx-click="pick_device_type"
                phx-value-device_type={d.key}
                class="flex flex-col items-start gap-2 rounded-2xl border border-base-300 bg-base-200/50 p-4 text-left transition-colors hover:border-primary/40 hover:bg-primary/5"
              >
                <div class="flex size-9 items-center justify-center rounded-xl bg-primary/10">
                  <.icon name={d.icon} class="size-5 text-primary" />
                </div>
                <span class="text-sm font-medium">{d.label}</span>
              </button>
            </div>
          <% @modal_step == :pick_device -> %>
            <div class="mb-4 flex items-center gap-3">
              <button
                id="modal-back-button"
                type="button"
                phx-click="back_to_type_picker"
                class="btn btn-ghost btn-sm rounded-xl"
              >
                ← Back
              </button>
              <button
                id="modal-refresh-button"
                type="button"
                data-tauri-action="list"
                data-device-type={@modal_device_type}
                class="btn btn-primary btn-sm rounded-xl"
              >
                Refresh
              </button>
            </div>

            <div id="modal-device-list" class="space-y-3">
              <%= if @modal_available_devices == [] do %>
                <div class="rounded-2xl border border-dashed border-base-300 bg-base-200/50 px-4 py-8 text-center text-sm text-base-content/60">
                  No devices found. Click Refresh to scan.
                </div>
              <% else %>
                <div
                  :for={{device, index} <- Enum.with_index(@modal_available_devices)}
                  id={"modal-device-#{index}"}
                  class="flex items-center justify-between gap-4 rounded-2xl border border-base-300 bg-base-200/40 px-4 py-3"
                >
                  <div>
                    <p class="font-medium">{device.name}</p>
                    <p class="text-xs uppercase tracking-[0.2em] text-base-content/45">
                      {device.id}
                    </p>
                  </div>
                  <button
                    type="button"
                    data-tauri-action="connect"
                    data-device-type={@modal_device_type}
                    data-device-id={device.id}
                    class="btn btn-outline btn-sm rounded-xl"
                  >
                    Connect
                  </button>
                </div>
              <% end %>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :device_def, :map, required: true
  attr :current_user, :map, required: true
  attr :connected, :map, default: nil
  attr :smart_trainer, :map, default: nil
  attr :reading, :any, default: nil

  def device_tray_tile(assigns) do
    ~H"""
    <div
      id={"device-tray-#{@device_def.key}"}
      class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
    >
      <div class="flex items-start justify-between">
        <div class="flex size-9 items-center justify-center rounded-xl bg-primary/10">
          <.icon name={@device_def.icon} class="size-4 text-primary" />
        </div>
        <span class={[
          "badge px-2 py-1 text-xs",
          if(@connected, do: "badge-success", else: "badge-ghost border border-base-300")
        ]}>
          {if @connected, do: "Connected", else: "Disconnected"}
        </span>
      </div>

      <div class="mt-3">
        <p class="text-xs uppercase tracking-[0.22em] text-base-content/50">
          {@device_def.label}
        </p>
        <div class="mt-1 flex items-end gap-1">
          <span class="text-2xl font-semibold">
            {format_device_reading(@reading, @device_def, @current_user)}
          </span>
          <span class="pb-0.5 text-xs text-base-content/40">
            {display_device_unit(@device_def, @current_user)}
          </span>
        </div>
        <%= if @connected do %>
          <p class="mt-1 truncate text-xs text-base-content/50">{@connected.name}</p>

          <%= if sourced_from_trainer?(@device_def, @connected, @smart_trainer) do %>
            <span class="badge badge-info mt-2 px-2 py-1 text-[10px] uppercase tracking-[0.12em]">
              Trainer Source
            </span>
          <% end %>
        <% else %>
          <p class="mt-1 text-xs text-base-content/35">Not connected</p>
        <% end %>
      </div>

      <%= if @connected && @connected.id do %>
        <div class="mt-4 flex items-center gap-2">
          <button
            id={"device-disconnect-#{@device_def.key}"}
            type="button"
            data-tauri-action="disconnect"
            data-device-type={@device_def.key}
            data-device-id={@connected.id}
            class="btn btn-ghost btn-xs w-full rounded-lg"
          >
            <.icon name="hero-x-mark" class="size-3" /> Disconnect
          </button>
        </div>
      <% else %>
        <%= if @connected do %>
          <div class="mt-4 text-xs text-warning">
            Connected device is missing an id. Reconnect this device.
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp label_for_type(device_defs, type) do
    case Enum.find(device_defs, &(&1.key == type)) do
      nil -> "Select device"
      d -> d.label
    end
  end

  defp sourced_from_trainer?(%{key: key}, connected, smart_trainer)
       when key in ["power_meter", "cadence"] and is_map(connected) and is_map(smart_trainer) do
    trainer_id = Map.get(smart_trainer, :id) || Map.get(smart_trainer, "id")
    device_id = Map.get(connected, :id) || Map.get(connected, "id")

    is_binary(trainer_id) and trainer_id != "" and trainer_id == device_id
  end

  defp sourced_from_trainer?(_, _, _), do: false

  defp format_device_reading(nil, _device_def, _current_user), do: "--"

  defp format_device_reading(reading, %{metric: :trainer_speed}, current_user)
       when is_integer(reading) do
    reading
    |> Kernel./(1)
    |> trainer_speed_for_user(current_user)
    |> round()
  end

  defp format_device_reading(reading, %{metric: :trainer_speed}, current_user)
       when is_float(reading) do
    reading
    |> trainer_speed_for_user(current_user)
    |> round()
  end

  defp format_device_reading(reading, _device_def, _current_user), do: reading

  defp display_device_unit(%{metric: :trainer_speed}, %{measurement_units: "imperial"}), do: "mph"
  defp display_device_unit(device_def, _current_user), do: device_def.unit

  defp trainer_speed_for_user(speed_kph, %{measurement_units: "imperial"}),
    do: speed_kph * 0.621371

  defp trainer_speed_for_user(speed_kph, _current_user), do: speed_kph

  defp chart_polyline(points) do
    Enum.map_join(points, " ", fn point -> "#{point.x},#{point.y}" end)
  end
end
