use super::{
    emit_connected, emit_devices_listed, emit_disconnected, emit_error, now_millis, DevicePayload,
    BRIDGE_ERROR,
};
use super::smart_trainer;
use tauri::Emitter;

const PREFIX: &str = "cadence";

/// Measurement: pedalling cadence.
#[derive(Clone, serde::Serialize)]
pub struct CadenceReading {
    /// Revolutions per minute.
    pub rpm: u16,
    pub at: u64,
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn list_cadence_devices(window: tauri::Window) -> Result<(), String> {
    let mut devices = Vec::new();

    if let Some(device) = smart_trainer::trainer_cadence_source_device() {
        devices.push(device);
    }

    emit_devices_listed(&window, PREFIX, devices)
}

#[tauri::command]
pub fn connect_cadence_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = smart_trainer::trainer_cadence_source_device()
        .filter(|source| source.id == device_id)
        .unwrap_or(DevicePayload {
            id: device_id,
            name: "Cadence Sensor".to_string(),
        });

    emit_connected(&window, PREFIX, device.clone())?;

    window
        .emit(
            &format!("{PREFIX}:reading"),
            CadenceReading {
                rpm: 0,
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

#[tauri::command]
pub fn disconnect_cadence_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    let device = DevicePayload {
        id: device_id,
        name: "Cadence Sensor".to_string(),
    };

    emit_disconnected(&window, PREFIX, device)
}

#[tauri::command]
pub fn cadence_bridge_error(window: tauri::Window, message: String) -> Result<(), String> {
    emit_error(&window, PREFIX, message)
}
