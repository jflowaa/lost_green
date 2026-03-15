//! Shared Bluetooth (BLE) utilities.
//!
//! Each device-type module (heart_rate, power_meter, …) imports from here to
//! avoid duplicating adapter-acquisition and UUID constants.
//!
//! Wi-Fi discovery will live in a parallel `wifi.rs` module when that work begins.

use btleplug::api::Manager as _;
use btleplug::platform::{Adapter, Manager};
use uuid::Uuid;

// ── How long to scan before collecting results ────────────────────────────────

/// Default BLE scan window in seconds.
pub const SCAN_DURATION_SECS: u64 = 8;

// ── Heart Rate Monitor UUIDs ──────────────────────────────────────────────────

/// Bluetooth GATT Heart Rate Service (0x180D)
pub const HEART_RATE_SERVICE: Uuid = uuid::uuid!("0000180d-0000-1000-8000-00805f9b34fb");

/// Heart Rate Measurement Characteristic (0x2A37)
pub const HEART_RATE_MEASUREMENT: Uuid = uuid::uuid!("00002a37-0000-1000-8000-00805f9b34fb");

// ── Adapter acquisition ───────────────────────────────────────────────────────

/// Returns the first available Bluetooth adapter or an error string.
pub async fn get_adapter() -> Result<Adapter, String> {
    let manager = Manager::new()
        .await
        .map_err(|e| format!("BLE manager error: {e}"))?;

    let adapters = manager
        .adapters()
        .await
        .map_err(|e| format!("BLE adapter list error: {e}"))?;

    adapters
        .into_iter()
        .next()
        .ok_or_else(|| "No Bluetooth adapter found on this device".to_string())
}

// ── Heart Rate parsing ────────────────────────────────────────────────────────

/// Parse a Heart Rate Measurement GATT notification into BPM.
///
/// Byte-layout (Bluetooth GATT spec §3.106):
/// ```
/// Byte 0  – Flags
///   bit 0  = 0 → HR value is UINT8 (byte 1)
///   bit 0  = 1 → HR value is UINT16 LE (bytes 1..=2)
/// Byte 1[..=2] – Heart Rate Value
/// ```
pub fn parse_heart_rate_bytes(data: &[u8]) -> u16 {
    if data.len() < 2 {
        return 0;
    }
    let flags = data[0];
    if flags & 0x01 != 0 {
        // UINT16, little-endian
        let lo = data.get(1).copied().unwrap_or(0);
        let hi = data.get(2).copied().unwrap_or(0);
        u16::from_le_bytes([lo, hi])
    } else {
        // UINT8
        data[1] as u16
    }
}
