// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/lost_green";
import topbar from "../vendor/topbar";

// ── Device bridge constants ───────────────────────────────────────────────────

// Maps device type key → Tauri command names.
const DEVICE_COMMANDS = {
  heart_rate: {
    list: "list_heart_rate_devices",
    connect: "connect_heart_rate_device",
    disconnect: "disconnect_heart_rate_device",
  },
  power_meter: {
    list: "list_power_meter_devices",
    connect: "connect_power_meter_device",
    disconnect: "disconnect_power_meter_device",
  },
  cadence: {
    list: "list_cadence_devices",
    connect: "connect_cadence_device",
    disconnect: "disconnect_cadence_device",
  },
  smart_trainer: {
    list: "list_smart_trainer_devices",
    connect: "connect_smart_trainer_device",
    disconnect: "disconnect_smart_trainer_device",
  },
  secondary_power_meter: {
    list: "list_secondary_power_meter_devices",
    connect: "connect_secondary_power_meter_device",
    disconnect: "disconnect_secondary_power_meter_device",
  },
};

// Maps Tauri event suffix → LiveView event name pushed to the server.
const TAURI_TO_LV = {
  devices_listed: "devices_listed",
  connected: "device_connected",
  disconnected: "device_disconnected",
  reading: "device_reading",
  error: "device_error",
};

// ── Bridge API resolver ───────────────────────────────────────────────────────

const resolveBridgeApi = () => {
  const tauri = window.__TAURI__;
  if (!tauri) return null;

  const invoke = tauri.core?.invoke
    ? tauri.core.invoke.bind(tauri.core)
    : tauri.invoke
      ? tauri.invoke.bind(tauri)
      : null;

  const listens = [];

  const currentWebviewWindow = tauri.webviewWindow?.getCurrentWebviewWindow?.();
  if (
    currentWebviewWindow &&
    typeof currentWebviewWindow.listen === "function"
  ) {
    listens.push(currentWebviewWindow.listen.bind(currentWebviewWindow));
  }

  const currentWindow = tauri.window?.getCurrentWindow?.();
  if (currentWindow && typeof currentWindow.listen === "function") {
    listens.push(currentWindow.listen.bind(currentWindow));
  }

  if (tauri.event?.listen) {
    listens.push(tauri.event.listen.bind(tauri.event));
  }

  if (typeof invoke !== "function" || listens.length === 0) return null;

  return { invoke, listens };
};

// ── DeviceBridge hook ─────────────────────────────────────────────────────────
//
// Attach to a persistent LiveView element with phx-hook="DeviceBridge".
// All device commands and events are routed through this single hook.
//
// DOM contract:
//   data-tauri-action="list|connect|disconnect"
//   data-device-type="heart_rate|power_meter|cadence|smart_trainer|secondary_power_meter"
//   data-device-id="<id>"    (required for connect/disconnect)
//
// Server → client events (via push_event):
//   "request_device_list" %{device_type: string}
//
// Client → server events (via pushEvent):
//   "devices_listed"      %{device_type, devices}
//   "device_connected"    %{device_type, device}
//   "device_disconnected" %{device_type, device}
//   "device_reading"      %{device_type, value/watts/rpm, at}
//   "device_error"        %{message}

const DeviceBridge = {
  mounted() {
    this.api = resolveBridgeApi();
    this.connectedDevices = {};
    this.unlisten = [];
    this.listenersReady = false;
    this.listenersReadyPromise = null;
    this.isDisconnectingForProfileChange = false;

    this.handleClick = this.handleClick.bind(this);
    this.handleSubmit = this.handleSubmit.bind(this);
    this.el.addEventListener("click", this.handleClick);
    this.el.addEventListener("submit", this.handleSubmit);
    this.syncConnectedDevices();

    this.listenersReadyPromise = this.setupListeners();

    // Server can push this event to trigger a device list refresh.
    this.handleEvent("request_device_list", ({ device_type }) =>
      this.requestList(device_type),
    );

    this.handleEvent("set_trainer_resistance_factor", ({ resistance_factor }) =>
      this.setTrainerResistanceFactor(resistance_factor),
    );
  },

  updated() {
    this.syncConnectedDevices();
  },

  async destroyed() {
    this.el.removeEventListener("click", this.handleClick);
    this.el.removeEventListener("submit", this.handleSubmit);
    for (const fn of this.unlisten) {
      try {
        await fn();
      } catch (_) {
        // no-op
      }
    }
    this.unlisten = [];
  },

  async setupListeners() {
    if (!this.api) return;

    const { listens } = this.api;

    const subscribe = async (eventName, callback) => {
      let lastError = null;

      for (const listen of listens) {
        try {
          return await listen(eventName, callback);
        } catch (error) {
          lastError = error;
        }
      }

      throw lastError || new Error("No supported event listener backend found");
    };

    try {
      for (const [type, commands] of Object.entries(DEVICE_COMMANDS)) {
        for (const [suffix, lvEvent] of Object.entries(TAURI_TO_LV)) {
          // Capture loop variables for the async callback.
          const capturedType = type;
          const capturedLvEvent = lvEvent;

          this.unlisten.push(
            await subscribe(`${type}:${suffix}`, ({ payload }) => {
              this.updateConnectedDeviceState(capturedType, suffix, payload);

              this.pushEvent(capturedLvEvent, {
                device_type: capturedType,
                ...(payload || {}),
              });
            }),
          );
        }

        // Suppress unused-variable lint in ESLint-like tools.
        void commands;
      }

      this.listenersReady = true;
    } catch (error) {
      const raw =
        typeof error === "string"
          ? error
          : error && typeof error.toString === "function"
            ? error.toString()
            : "unknown error";

      const message =
        error && typeof error.message === "string"
          ? `Unable to subscribe to device bridge events: ${error.message}`
          : `Unable to subscribe to device bridge events: ${raw}`;

      this.pushDeviceError(message);
    }
  },

  async waitForListeners() {
    if (this.listenersReady) return;
    if (this.listenersReadyPromise) {
      await this.listenersReadyPromise;
    }
  },

  async handleClick(event) {
    const target = event.target.closest("[data-tauri-action]");
    if (!target || !this.el.contains(target)) return;

    event.preventDefault();

    const {
      tauriAction: action,
      deviceType: type,
      deviceId: id,
    } = target.dataset;
    const commands = DEVICE_COMMANDS[type];

    if (!commands) {
      this.pushDeviceError("Unable to access device bridge.");
      return;
    }

    await this.waitForListeners();

    if (action === "list") {
      await this.requestList(type);
    } else if (action === "connect" && id) {
      await this.invoke(commands.connect, { deviceId: id });
    } else if (action === "disconnect" && id) {
      await this.invoke(commands.disconnect, { deviceId: id });
    }
  },

  async handleSubmit(event) {
    const form = event.target.closest("form[data-device-logout]");
    if (
      !form ||
      !this.el.contains(form) ||
      this.isDisconnectingForProfileChange
    )
      return;

    event.preventDefault();
    this.isDisconnectingForProfileChange = true;

    try {
      await this.disconnectAllDevices();
      form.submit();
    } finally {
      this.isDisconnectingForProfileChange = false;
    }
  },

  async requestList(deviceType) {
    const commands = DEVICE_COMMANDS[deviceType];
    if (!commands) return;

    await this.waitForListeners();

    await this.invoke(commands.list);
  },

  async invoke(command, args = {}) {
    if (!this.api) {
      this.pushDeviceError("Unable to access device bridge.");
      return null;
    }
    try {
      return await this.api.invoke(command, args);
    } catch (_error) {
      this.pushDeviceError("Unable to access device bridge.");
      return null;
    }
  },

  pushDeviceError(message) {
    this.pushEvent("device_error", { message });
  },

  syncConnectedDevices() {
    const raw = this.el.dataset.connectedDevices;
    if (!raw) {
      this.connectedDevices = {};
      return;
    }

    try {
      const parsed = JSON.parse(raw);
      this.connectedDevices =
        parsed && typeof parsed === "object" ? parsed : {};
    } catch (_error) {
      this.connectedDevices = {};
    }
  },

  updateConnectedDeviceState(type, suffix, payload) {
    if (suffix === "connected" && payload?.device?.id) {
      this.connectedDevices = {
        ...this.connectedDevices,
        [type]: {
          id: payload.device.id,
          name: payload.device.name || "Unknown Device",
        },
      };
      return;
    }

    if (suffix === "disconnected") {
      const next = { ...this.connectedDevices };
      delete next[type];
      this.connectedDevices = next;
    }
  },

  async disconnectAllDevices() {
    const devices = Object.entries(this.connectedDevices).filter(
      ([, device]) =>
        device && typeof device.id === "string" && device.id.length > 0,
    );

    if (devices.length === 0) return;

    await this.waitForListeners();

    await Promise.allSettled(
      devices.map(([type, device]) => {
        const commands = DEVICE_COMMANDS[type];
        if (!commands) return Promise.resolve();
        return this.invoke(commands.disconnect, { deviceId: device.id });
      }),
    );
  },

  async setTrainerResistanceFactor(resistanceFactor) {
    const trainer = this.connectedDevices.smart_trainer;

    if (!trainer?.id) {
      this.pushDeviceError("No smart trainer is connected.");
      return;
    }

    await this.waitForListeners();

    await this.invoke("set_smart_trainer_resistance_factor", {
      deviceId: trainer.id,
      resistanceFactor,
    });
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, DeviceBridge },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
