pub mod bluetooth;
pub mod cadence;
pub mod heart_rate;
pub mod power_meter;
pub mod secondary_power_meter;
pub mod smart_trainer;

use tauri::Emitter;
use tauri::Manager;

// ── Shared payload types ──────────────────────────────────────────────────────

/// A generic device reference – id and display name as reported by the OS.
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct DevicePayload {
    pub id: String,
    pub name: String,
}

#[derive(Clone, serde::Serialize)]
pub struct DevicesListedPayload {
    pub devices: Vec<DevicePayload>,
}

/// Reused for both connected and disconnected events.
#[derive(Clone, serde::Serialize)]
pub struct DeviceConnectedPayload {
    pub device: DevicePayload,
}

#[derive(Clone, serde::Serialize)]
pub struct DeviceErrorPayload {
    pub message: String,
}

// ── Shared constants ──────────────────────────────────────────────────────────

pub const BRIDGE_ERROR: &str = "Unable to access device bridge";

pub fn simulated_devices_enabled() -> bool {
    std::env::var("SIMULATE_DEVICES")
        .map(|value| {
            let normalized = value.trim().to_ascii_lowercase();
            matches!(normalized.as_str(), "1" | "true" | "yes" | "on")
        })
        .unwrap_or(false)
}

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Current time as Unix milliseconds – used for reading timestamps.
pub fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn emit_devices_listed(
    window: &tauri::Window,
    prefix: &str,
    devices: Vec<DevicePayload>,
) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{prefix}:devices_listed"),
            DevicesListedPayload { devices },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

pub fn emit_connected(
    window: &tauri::Window,
    prefix: &str,
    device: DevicePayload,
) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{prefix}:connected"),
            DeviceConnectedPayload { device },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

pub fn emit_disconnected(
    window: &tauri::Window,
    prefix: &str,
    device: DevicePayload,
) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{prefix}:disconnected"),
            DeviceConnectedPayload { device },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

pub fn emit_error(
    window: &tauri::Window,
    prefix: &str,
    message: String,
) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{prefix}:error"),
            DeviceErrorPayload { message },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}
