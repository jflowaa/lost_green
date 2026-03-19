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

const TAURI_TO_LV = {
  devices_listed: "devices_listed",
  connected: "device_connected",
  disconnected: "device_disconnected",
  reading: "device_reading",
  error: "device_error",
};

const LIST_PENDING_TIMEOUT_MS = 15_000;
const CONNECT_PENDING_TIMEOUT_MS = 20_000;

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

const DeviceBridge = {
  mounted() {
    this.api = resolveBridgeApi();
    this.connectedDevices = {};
    this.pendingListByType = {};
    this.pendingConnectByType = {};
    this.listTimeoutByType = {};
    this.connectTimeoutByType = {};
    this.unlisten = [];
    this.listenersReady = false;
    this.listenersReadyPromise = null;
    this.isDisconnectingForProfileChange = false;

    this.listenersReadyPromise = this.setupListeners();
    this.syncConnectedDevices();

    this.handleEvent("device_bridge_invoke", (payload) =>
      this.invokeBridgeAction(payload),
    );

    this.handleEvent("disconnect_all_devices", () =>
      this.disconnectAllAndProfileChange(),
    );

    this.handleEvent("set_trainer_resistance_factor", ({ resistance_factor }) =>
      this.setTrainerResistanceFactor(resistance_factor),
    );
  },

  async destroyed() {
    for (const timeout of Object.values(this.listTimeoutByType)) {
      clearTimeout(timeout);
    }
    for (const timeout of Object.values(this.connectTimeoutByType)) {
      clearTimeout(timeout);
    }

    this.listTimeoutByType = {};
    this.connectTimeoutByType = {};

    for (const fn of this.unlisten) {
      try {
        await fn();
      } catch (_) {}
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
          const capturedType = type;
          const capturedLvEvent = lvEvent;

          this.unlisten.push(
            await subscribe(`${type}:${suffix}`, ({ payload }) => {
              this.updateConnectedDeviceState(capturedType, suffix, payload);

              if (suffix === "devices_listed" || suffix === "error") {
                this.setListRefreshing(capturedType, false);
              }

              if (suffix === "connected" || suffix === "error") {
                this.setConnectPending(capturedType, false);
              }

              this.pushEvent(capturedLvEvent, {
                device_type: capturedType,
                ...(payload || {}),
              });
            }),
          );
        }

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

  async disconnectAllAndProfileChange() {
    if (this.isDisconnectingForProfileChange) return;
    this.isDisconnectingForProfileChange = true;

    try {
      await this.disconnectAllDevices();
      this.pushEvent("profile_change_ready", {});
    } finally {
      this.isDisconnectingForProfileChange = false;
    }
  },

  async requestList(deviceType) {
    const commands = DEVICE_COMMANDS[deviceType];
    if (!commands) return;

    await this.waitForListeners();
    this.setListRefreshing(deviceType, true);

    const result = await this.invoke(commands.list);
    if (result === null) {
      this.setListRefreshing(deviceType, false);
    }
  },

  async invokeBridgeAction(payload) {
    const action = payload?.action;
    const type = payload?.device_type;
    const id = payload?.device_id;
    const commands = DEVICE_COMMANDS[type];

    if (!action || !commands) {
      this.pushDeviceError("Unable to access device bridge.");
      return;
    }

    await this.waitForListeners();

    if (action === "list") {
      if (this.pendingListByType[type] || this.pendingConnectByType[type])
        return;
      await this.requestList(type);
      return;
    }

    if (action === "connect" && id) {
      if (this.pendingListByType[type] || this.pendingConnectByType[type])
        return;
      this.setConnectPending(type, true);
      const result = await this.invoke(commands.connect, { deviceId: id });
      if (result === null) {
        this.setConnectPending(type, false);
      }
      return;
    }

    if (action === "disconnect" && id) {
      await this.invoke(commands.disconnect, { deviceId: id });
    }
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

  async syncConnectedDevices() {
    try {
      const reply = await this.pushEvent("request_connected_devices", {});
      const connectedDevices = reply?.connected_devices;
      this.connectedDevices =
        connectedDevices && typeof connectedDevices === "object"
          ? connectedDevices
          : {};
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

  setListRefreshing(deviceType, isRefreshing) {
    const existingTimeout = this.listTimeoutByType[deviceType];
    if (existingTimeout) {
      clearTimeout(existingTimeout);
      delete this.listTimeoutByType[deviceType];
    }

    this.pendingListByType = {
      ...this.pendingListByType,
      [deviceType]: isRefreshing,
    };

    if (isRefreshing) {
      this.listTimeoutByType[deviceType] = setTimeout(() => {
        if (!this.pendingListByType[deviceType]) return;

        this.setListRefreshing(deviceType, false);
        this.pushDeviceError(
          "Device scan timed out. Please refresh and try again.",
        );
      }, LIST_PENDING_TIMEOUT_MS);
    }
  },

  setConnectPending(deviceType, isPending) {
    const existingTimeout = this.connectTimeoutByType[deviceType];
    if (existingTimeout) {
      clearTimeout(existingTimeout);
      delete this.connectTimeoutByType[deviceType];
    }

    this.pendingConnectByType = {
      ...this.pendingConnectByType,
      [deviceType]: isPending,
    };

    if (isPending) {
      this.connectTimeoutByType[deviceType] = setTimeout(() => {
        if (!this.pendingConnectByType[deviceType]) return;

        this.setConnectPending(deviceType, false);
        this.pushDeviceError(
          "Device connection timed out. Please try connecting again.",
        );
      }, CONNECT_PENDING_TIMEOUT_MS);
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

export default DeviceBridge;
