use super::{
    emit_connected, emit_devices_listed, emit_disconnected, emit_error, now_millis, DevicePayload,
    BRIDGE_ERROR,
};
use super::smart_trainer;
use tauri::Emitter;

const PREFIX: &str = "power_meter";

/// Measurement: instantaneous power output.
#[derive(Clone, serde::Serialize)]
pub struct PowerReading {
    /// Watts.
    pub watts: u16,
    pub at: u64,
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn list_power_meter_devices(window: tauri::Window) -> Result<(), String> {
    let mut devices = Vec::new();

    if let Some(device) = smart_trainer::trainer_power_source_device() {
        devices.push(device);
    }

    emit_devices_listed(&window, PREFIX, devices)
}

#[tauri::command]
pub fn connect_power_meter_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = smart_trainer::trainer_power_source_device()
        .filter(|source| source.id == device_id)
        .unwrap_or(DevicePayload {
            id: device_id,
            name: "Power Meter".to_string(),
        });

    emit_connected(&window, PREFIX, device.clone())?;

    window
        .emit(
            &format!("{PREFIX}:reading"),
            PowerReading {
                watts: 0,
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

#[tauri::command]
pub fn disconnect_power_meter_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = DevicePayload {
        id: device_id,
        name: "Power Meter".to_string(),
    };

    emit_disconnected(&window, PREFIX, device)
}

#[tauri::command]
pub fn power_meter_bridge_error(window: tauri::Window, message: String) -> Result<(), String> {
    emit_error(&window, PREFIX, message)
}
