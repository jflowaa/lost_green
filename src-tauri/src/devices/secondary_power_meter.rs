use super::{
    emit_connected, emit_devices_listed, emit_disconnected, emit_error, now_millis, DevicePayload,
    BRIDGE_ERROR,
};
use tauri::Emitter;

const PREFIX: &str = "secondary_power_meter";

/// Measurement: instantaneous power from the secondary meter (e.g. left crank/pedal pod).
#[derive(Clone, serde::Serialize)]
pub struct SecondaryPowerReading {
    /// Watts.
    pub watts: u16,
    /// Optional left/right balance percentage (0–100); None when not supported.
    pub balance: Option<u8>,
    pub at: u64,
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn list_secondary_power_meter_devices(window: tauri::Window) -> Result<(), String> {
    emit_devices_listed(&window, PREFIX, vec![])
}

#[tauri::command]
pub fn connect_secondary_power_meter_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = DevicePayload {
        id: device_id,
        name: "Secondary Power Meter".to_string(),
    };

    emit_connected(&window, PREFIX, device.clone())?;

    window
        .emit(
            &format!("{PREFIX}:reading"),
            SecondaryPowerReading {
                watts: 0,
                balance: None,
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

#[tauri::command]
pub fn disconnect_secondary_power_meter_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = DevicePayload {
        id: device_id,
        name: "Secondary Power Meter".to_string(),
    };

    emit_disconnected(&window, PREFIX, device)
}

#[tauri::command]
pub fn secondary_power_meter_bridge_error(
    window: tauri::Window,
    message: String,
) -> Result<(), String> {
    emit_error(&window, PREFIX, message)
}
