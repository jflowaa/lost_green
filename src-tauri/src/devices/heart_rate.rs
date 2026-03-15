use super::{
    emit_connected, emit_devices_listed, emit_disconnected, emit_error, now_millis,
    simulated_devices_enabled, DevicePayload,
};
use super::bluetooth::{
    get_adapter, parse_heart_rate_bytes, HEART_RATE_MEASUREMENT, HEART_RATE_SERVICE,
    SCAN_DURATION_SECS,
};
use btleplug::api::{Central, Peripheral as _, ScanFilter};
use btleplug::platform::Peripheral;
use futures::stream::StreamExt;
use std::sync::{Mutex, OnceLock};
use tauri::Emitter;
use tauri::Manager;

const PREFIX: &str = "heart_rate";

// ── Shared mutable state ──────────────────────────────────────────────────────

fn scan_task() -> &'static Mutex<Option<tauri::async_runtime::JoinHandle<()>>> {
    static SCAN_TASK: OnceLock<Mutex<Option<tauri::async_runtime::JoinHandle<()>>>> =
        OnceLock::new();
    SCAN_TASK.get_or_init(|| Mutex::new(None))
}

fn stream_task() -> &'static Mutex<Option<tauri::async_runtime::JoinHandle<()>>> {
    static STREAM_TASK: OnceLock<Mutex<Option<tauri::async_runtime::JoinHandle<()>>>> =
        OnceLock::new();
    STREAM_TASK.get_or_init(|| Mutex::new(None))
}

fn connected_peripheral() -> &'static Mutex<Option<Peripheral>> {
    static PERIPHERAL: OnceLock<Mutex<Option<Peripheral>>> = OnceLock::new();
    PERIPHERAL.get_or_init(|| Mutex::new(None))
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// Scan for available heart rate monitors and emit `heart_rate:devices_listed`
/// when the scan window closes.
///
/// In simulation mode, the list is returned immediately.
#[tauri::command]
pub fn list_heart_rate_devices(window: tauri::Window) -> Result<(), String> {
    if simulated_devices_enabled() {
        let devices = simulated_devices();
        log::info!("Heart-rate list: {} simulated device(s)", devices.len());
        return emit_devices_listed(&window, PREFIX, devices);
    }

    // Cancel any in-progress scan before starting a new one.
    abort_task(scan_task());

    log::info!("Heart-rate BLE scan started ({SCAN_DURATION_SECS}s window)");

    let task = tauri::async_runtime::spawn(async move {
        match ble_scan(&window).await {
            Ok(devices) => {
                log::info!("Heart-rate BLE scan complete: {} device(s) found", devices.len());
                let _ = emit_devices_listed(&window, PREFIX, devices);
            }
            Err(e) => {
                log::error!("Heart-rate BLE scan error: {e}");
                let _ = emit_error(&window, PREFIX, format!("Bluetooth scan failed: {e}"));
            }
        }
    });

    set_task(scan_task(), task);
    Ok(())
}

/// Connect to a heart rate monitor by its peripheral ID and begin streaming
/// readings as `heart_rate:reading` events.
#[tauri::command]
pub fn connect_heart_rate_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    if simulated_devices_enabled() {
        return connect_simulated(&window, device_id);
    }

    // Abort any existing stream before opening a new connection.
    stop_heart_rate_stream();

    log::info!("Heart-rate BLE connect requested: {device_id}");

    let task = tauri::async_runtime::spawn(async move {
        match ble_connect(&window, &device_id).await {
            Ok(()) => {}
            Err(e) => {
                log::error!("Heart-rate BLE connect error: {e}");
                let _ = emit_error(&window, PREFIX, format!("Bluetooth connect failed: {e}"));
            }
        }
    });

    set_task(stream_task(), task);
    Ok(())
}

/// Disconnect the currently connected heart rate monitor.
#[tauri::command]
pub fn disconnect_heart_rate_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    stop_heart_rate_stream();

    if !simulated_devices_enabled() {
        // Best-effort explicit BLE disconnect — ignore errors.
        let peripheral_opt = {
            let mut guard = connected_peripheral().lock().unwrap_or_else(|p| p.into_inner());
            guard.take()
        };

        if let Some(peripheral) = peripheral_opt {
            tauri::async_runtime::spawn(async move {
                use btleplug::api::Peripheral as _;
                let _ = peripheral.disconnect().await;
                log::info!("Heart-rate peripheral disconnected");
            });
        }
    }

    let device = find_simulated_device(&device_id).unwrap_or(DevicePayload {
        id: device_id,
        name: "Heart Rate Monitor".to_string(),
    });

    emit_disconnected(&window, PREFIX, device)
}

#[tauri::command]
pub fn heart_rate_bridge_error(window: tauri::Window, message: String) -> Result<(), String> {
    emit_error(&window, PREFIX, message)
}

// ── BLE helpers ───────────────────────────────────────────────────────────────

/// Scan BLE for peripherals advertising the Heart Rate Service.
async fn ble_scan(window: &tauri::Window) -> Result<Vec<DevicePayload>, String> {
    let adapter = get_adapter().await?;

    adapter
        .start_scan(ScanFilter {
            services: vec![HEART_RATE_SERVICE],
        })
        .await
        .map_err(|e| format!("Failed to start BLE scan: {e}"))?;

    tokio::time::sleep(tokio::time::Duration::from_secs(SCAN_DURATION_SECS)).await;

    adapter
        .stop_scan()
        .await
        .map_err(|e| format!("Failed to stop BLE scan: {e}"))?;

    let peripherals = adapter
        .peripherals()
        .await
        .map_err(|e| format!("Failed to list peripherals: {e}"))?;

    let mut devices = Vec::new();

    for p in peripherals {
        if let Ok(Some(props)) = p.properties().await {
            if props.services.contains(&HEART_RATE_SERVICE) {
                let name = props
                    .local_name
                    .unwrap_or_else(|| "Heart Rate Monitor".to_string());

                log::info!("Found heart-rate device: {} ({})", name, p.id());

                devices.push(DevicePayload {
                    id: p.id().to_string(),
                    name,
                });
            }
        }
    }

    let _ = window;
    Ok(devices)
}

/// Connect to a BLE peripheral by its string ID, subscribe to Heart Rate
/// Measurement notifications, and emit readings until the stream ends.
async fn ble_connect(window: &tauri::Window, device_id: &str) -> Result<(), String> {
    use btleplug::api::Peripheral as _;

    let adapter = get_adapter().await?;

    // Brief re-scan so the peripheral is in the adapter's cache on all platforms.
    adapter
        .start_scan(ScanFilter {
            services: vec![HEART_RATE_SERVICE],
        })
        .await
        .map_err(|e| format!("Pre-connect scan error: {e}"))?;

    tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;

    adapter
        .stop_scan()
        .await
        .map_err(|e| format!("Pre-connect scan stop error: {e}"))?;

    // Locate peripheral by id.
    let peripherals = adapter
        .peripherals()
        .await
        .map_err(|e| format!("Peripheral list error: {e}"))?;

    let peripheral = peripherals
        .into_iter()
        .find(|p| p.id().to_string() == device_id)
        .ok_or_else(|| format!("Device {device_id} not found. Try scanning again."))?;

    peripheral
        .connect()
        .await
        .map_err(|e| format!("BLE connect error: {e}"))?;

    peripheral
        .discover_services()
        .await
        .map_err(|e| format!("Service discovery error: {e}"))?;

    let chars = peripheral.characteristics();
    let hr_char = chars
        .iter()
        .find(|c| c.uuid == HEART_RATE_MEASUREMENT)
        .ok_or_else(|| "Heart Rate Measurement characteristic not found on device".to_string())?
        .clone();

    let device_name = peripheral
        .properties()
        .await
        .ok()
        .flatten()
        .and_then(|p| p.local_name)
        .unwrap_or_else(|| "Heart Rate Monitor".to_string());

    let device_payload = DevicePayload {
        id: device_id.to_string(),
        name: device_name,
    };

    // Store the peripheral so disconnect() can reach it.
    {
        let mut guard = connected_peripheral().lock().unwrap_or_else(|p| p.into_inner());
        *guard = Some(peripheral.clone());
    }

    emit_connected(window, PREFIX, device_payload)
        .map_err(|e| format!("emit_connected error: {e}"))?;

    peripheral
        .subscribe(&hr_char)
        .await
        .map_err(|e| format!("Subscribe error: {e}"))?;

    log::info!("Heart-rate stream started for {device_id}");

    let mut notifications = peripheral
        .notifications()
        .await
        .map_err(|e| format!("Notification stream error: {e}"))?;

    while let Some(notification) = notifications.next().await {
        if notification.uuid != HEART_RATE_MEASUREMENT {
            continue;
        }

        let bpm = parse_heart_rate_bytes(&notification.value);

        let reading = HeartRateReading {
            value: bpm,
            at: now_millis(),
        };

        if window
            .app_handle()
            .emit(&format!("{PREFIX}:reading"), reading)
            .is_err()
        {
            break;
        }
    }

    log::info!("Heart-rate stream ended for {device_id}");
    Ok(())
}

// ── Simulation ────────────────────────────────────────────────────────────────

fn connect_simulated(window: &tauri::Window, device_id: String) -> Result<(), String> {
    log::info!("Heart-rate simulated connect: {device_id}");

    let device = find_simulated_device(&device_id).unwrap_or(DevicePayload {
        id: device_id.clone(),
        name: "Heart Rate Monitor".to_string(),
    });

    emit_connected(window, PREFIX, device.clone())?;

    let stream_window = window.clone();
    let task = tauri::async_runtime::spawn(async move {
        let samples: [u16; 10] = [102, 106, 110, 114, 118, 121, 119, 115, 111, 107];
        let mut index = 0usize;

        loop {
            let reading = HeartRateReading {
                value: samples[index % samples.len()],
                at: now_millis(),
            };

            if stream_window
                .app_handle()
                .emit(&format!("{PREFIX}:reading"), reading)
                .is_err()
            {
                break;
            }

            index = index.wrapping_add(1);
            tokio::time::sleep(tokio::time::Duration::from_millis(1_000)).await;
        }
    });

    set_task(stream_task(), task);
    Ok(())
}

fn simulated_devices() -> Vec<DevicePayload> {
    vec![
        DevicePayload {
            id: "hrm:sim:1".to_string(),
            name: "Heart Rate Strap (Sim)".to_string(),
        },
        DevicePayload {
            id: "hrm:sim:2".to_string(),
            name: "Wrist HR Sensor (Sim)".to_string(),
        },
    ]
}

fn find_simulated_device(device_id: &str) -> Option<DevicePayload> {
    simulated_devices().into_iter().find(|d| d.id == device_id)
}

// ── Task management ───────────────────────────────────────────────────────────

/// Measurement: beats per minute.
#[derive(Clone, serde::Serialize)]
pub struct HeartRateReading {
    pub value: u16,
    pub at: u64,
}

fn stop_heart_rate_stream() {
    abort_task(stream_task());
}

fn abort_task(slot: &Mutex<Option<tauri::async_runtime::JoinHandle<()>>>) {
    let mut guard = slot.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(task) = guard.take() {
        task.abort();
    }
}

fn set_task(
    slot: &Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    task: tauri::async_runtime::JoinHandle<()>,
) {
    let mut guard = slot.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(old) = guard.take() {
        old.abort();
    }
    *guard = Some(task);
}
