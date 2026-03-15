use super::{
    emit_connected, emit_devices_listed, emit_disconnected, emit_error, now_millis,
    simulated_devices_enabled, DevicePayload, BRIDGE_ERROR,
};
use super::bluetooth::{get_adapter, SCAN_DURATION_SECS};
use btleplug::api::{Central, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::Peripheral;
use futures::stream::StreamExt;
use std::sync::{Mutex, OnceLock};
use tauri::Emitter;
use tauri::Manager;

const PREFIX: &str = "smart_trainer";
const POWER_PREFIX: &str = "power_meter";
const CADENCE_PREFIX: &str = "cadence";

const FITNESS_MACHINE_SERVICE: uuid::Uuid =
    uuid::uuid!("00001826-0000-1000-8000-00805f9b34fb");
const CYCLING_POWER_SERVICE: uuid::Uuid =
    uuid::uuid!("00001818-0000-1000-8000-00805f9b34fb");
const CSC_SERVICE: uuid::Uuid = uuid::uuid!("00001816-0000-1000-8000-00805f9b34fb");
const FTMS_INDOOR_BIKE_DATA: uuid::Uuid =
    uuid::uuid!("00002ad2-0000-1000-8000-00805f9b34fb");
const FTMS_CONTROL_POINT: uuid::Uuid =
    uuid::uuid!("00002ad9-0000-1000-8000-00805f9b34fb");

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

fn cascade_state() -> &'static Mutex<CascadeState> {
    static CASCADE_STATE: OnceLock<Mutex<CascadeState>> = OnceLock::new();
    CASCADE_STATE.get_or_init(|| Mutex::new(CascadeState::default()))
}

#[derive(Clone, Default)]
struct CascadeState {
    device: Option<DevicePayload>,
    power_connected: bool,
    cadence_connected: bool,
    supports_target_power: bool,
    supports_resistance: bool,
    target_watts: Option<u16>,
    resistance_factor: Option<u8>,
    distance_km: f32,
    last_distance_at: Option<u64>,
}

pub fn trainer_power_source_device() -> Option<DevicePayload> {
    let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());

    if guard.power_connected {
        guard.device.as_ref().map(|device| DevicePayload {
            id: device.id.clone(),
            name: format!("{} (trainer power)", device.name),
        })
    } else {
        None
    }
}

pub fn trainer_cadence_source_device() -> Option<DevicePayload> {
    let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());

    if guard.cadence_connected {
        guard.device.as_ref().map(|device| DevicePayload {
            id: device.id.clone(),
            name: format!("{} (trainer cadence)", device.name),
        })
    } else {
        None
    }
}

/// Measurement: current trainer state including power output and resistance factor.
#[derive(Clone, serde::Serialize)]
pub struct SmartTrainerReading {
    /// Instantaneous speed in km/h.
    pub speed_kph: Option<f32>,
    /// Resistance factor in the 0-100 range when reported by the trainer.
    pub resistance_factor: u8,
    /// Optional current target power in watts.
    pub target_watts: Option<u16>,
    /// Cumulative estimated distance in km.
    pub distance_km: f32,
    /// Optional trainer-reported power if available.
    pub watts: Option<u16>,
    /// Optional cadence value in rpm when supported by the trainer.
    pub rpm: Option<u16>,
    pub at: u64,
}

#[derive(Clone, serde::Serialize)]
struct PowerReading {
    watts: u16,
    source_id: String,
    at: u64,
}

#[derive(Clone, serde::Serialize)]
struct CadenceReading {
    rpm: u16,
    source_id: String,
    at: u64,
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn list_smart_trainer_devices(window: tauri::Window) -> Result<(), String> {
    if simulated_devices_enabled() {
        return emit_devices_listed(&window, PREFIX, simulated_devices());
    }

    abort_task(scan_task());

    let task = tauri::async_runtime::spawn(async move {
        match ble_scan().await {
            Ok(devices) => {
                let _ = emit_devices_listed(&window, PREFIX, devices);
            }
            Err(e) => {
                log::error!("Smart-trainer scan error: {e}");
                let _ = emit_error(&window, PREFIX, format!("Bluetooth scan failed: {e}"));
            }
        }
    });

    set_task(scan_task(), task);
    Ok(())
}

#[tauri::command]
pub fn connect_smart_trainer_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    stop_stream();

    if simulated_devices_enabled() {
        return connect_simulated(&window, device_id);
    }

    let task = tauri::async_runtime::spawn(async move {
        match ble_connect(&window, &device_id).await {
            Ok(()) => {}
            Err(e) => {
                log::error!("Smart-trainer connect error: {e}");
                let _ = emit_error(&window, PREFIX, format!("Bluetooth connect failed: {e}"));
            }
        }
    });

    set_task(stream_task(), task);
    Ok(())
}

#[tauri::command]
pub fn disconnect_smart_trainer_device(
    window: tauri::Window,
    device_id: String,
) -> Result<(), String> {
    stop_stream();

    let states = {
        let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        let snapshot = guard.clone();
        *guard = CascadeState::default();
        snapshot
    };

    if !simulated_devices_enabled() {
        let peripheral_opt = {
            let mut guard = connected_peripheral().lock().unwrap_or_else(|p| p.into_inner());
            guard.take()
        };

        if let Some(peripheral) = peripheral_opt {
            tauri::async_runtime::spawn(async move {
                use btleplug::api::Peripheral as _;
                let _ = peripheral.disconnect().await;
            });
        }
    }

    let device = DevicePayload {
        id: device_id.clone(),
        name: "Smart Trainer".to_string(),
    };

    emit_disconnected(&window, PREFIX, device.clone())?;

    if states.power_connected {
        let _ = emit_disconnected(&window, POWER_PREFIX, DevicePayload {
            id: device_id.clone(),
            name: format!("{} (trainer power)", device.name),
        });
    }

    if states.cadence_connected {
        let _ = emit_disconnected(&window, CADENCE_PREFIX, DevicePayload {
            id: device_id,
            name: format!("{} (trainer cadence)", device.name),
        });
    }

    Ok(())
}

/// Set ERG target power in watts; the trainer will adjust resistance to maintain it.
#[tauri::command]
pub fn set_smart_trainer_target_watts(
    window: tauri::Window,
    device_id: String,
    watts: u16,
) -> Result<(), String> {
    if simulated_devices_enabled() {
        {
            let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
            guard.target_watts = Some(watts);
        }

        return emit_trainer_reading(&window, Some(watts), 0, None, None, None);
    }

    let state = {
        let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        guard.clone()
    };

    let Some(device) = state.device else {
        return emit_error(&window, PREFIX, "No smart trainer connected".to_string());
    };

    if device.id != device_id {
        return emit_error(
            &window,
            PREFIX,
            "Smart trainer id does not match current connection".to_string(),
        );
    }

    if !state.supports_target_power {
        return emit_error(
            &window,
            PREFIX,
            "This trainer does not support target power control".to_string(),
        );
    }

    let result = with_ftms_control_point(|peripheral, control_point| async move {
        let power = watts.to_le_bytes();
        let payload = [0x05, power[0], power[1]];
        peripheral
            .write(&control_point, &payload, WriteType::WithResponse)
            .await
            .map_err(|e| format!("Failed to set trainer target power: {e}"))
    });

    match result {
        Ok(()) => {
            {
                let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
                guard.target_watts = Some(watts);
            }

            emit_trainer_reading(
                &window,
                Some(watts),
                state.resistance_factor.unwrap_or(0),
                None,
                None,
                None,
            )
        }
        Err(message) => emit_error(&window, PREFIX, message),
    }
}

/// Set a manual trainer resistance factor in the 0-100 range when supported.
#[tauri::command]
pub fn set_smart_trainer_resistance_factor(
    window: tauri::Window,
    device_id: String,
    resistance_factor: u8,
) -> Result<(), String> {
    if resistance_factor > 100 {
        return emit_error(
            &window,
            PREFIX,
            "Resistance factor must be between 0 and 100".to_string(),
        );
    }

    if simulated_devices_enabled() {
        {
            let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
            guard.resistance_factor = Some(resistance_factor);
        }

        return emit_trainer_reading(&window, None, resistance_factor, None, None, None);
    }

    let state = {
        let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        guard.clone()
    };

    let Some(device) = state.device else {
        return emit_error(&window, PREFIX, "No smart trainer connected".to_string());
    };

    if device.id != device_id {
        return emit_error(
            &window,
            PREFIX,
            "Smart trainer id does not match current connection".to_string(),
        );
    }

    if !state.supports_resistance {
        return emit_error(
            &window,
            PREFIX,
            "This trainer does not support resistance control".to_string(),
        );
    }

    let result = with_ftms_control_point(|peripheral, control_point| async move {
        let level = ((resistance_factor as u16) * 10).to_le_bytes();
        let payload = [0x04, level[0], level[1]];
        peripheral
            .write(&control_point, &payload, WriteType::WithResponse)
            .await
            .map_err(|e| format!("Failed to set trainer resistance factor: {e}"))
    });

    match result {
        Ok(()) => Ok(()),
        Err(message) => emit_error(&window, PREFIX, message),
    }
}

#[tauri::command]
pub fn smart_trainer_bridge_error(window: tauri::Window, message: String) -> Result<(), String> {
    emit_error(&window, PREFIX, message)
}

async fn ble_scan() -> Result<Vec<DevicePayload>, String> {
    let adapter = get_adapter().await?;

    adapter
        .start_scan(ScanFilter {
            services: vec![
                FITNESS_MACHINE_SERVICE,
                CYCLING_POWER_SERVICE,
                CSC_SERVICE,
            ],
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
            let services = &props.services;
            let looks_like_trainer = services.contains(&FITNESS_MACHINE_SERVICE)
                || (services.contains(&CYCLING_POWER_SERVICE) && services.contains(&CSC_SERVICE));

            if looks_like_trainer {
                let name = props.local_name.unwrap_or_else(|| "Smart Trainer".to_string());
                devices.push(DevicePayload {
                    id: p.id().to_string(),
                    name,
                });
            }
        }
    }

    Ok(devices)
}

async fn ble_connect(window: &tauri::Window, device_id: &str) -> Result<(), String> {
    use btleplug::api::Peripheral as _;

    let adapter = get_adapter().await?;

    adapter
        .start_scan(ScanFilter {
            services: vec![
                FITNESS_MACHINE_SERVICE,
                CYCLING_POWER_SERVICE,
                CSC_SERVICE,
            ],
        })
        .await
        .map_err(|e| format!("Pre-connect scan error: {e}"))?;

    tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;

    adapter
        .stop_scan()
        .await
        .map_err(|e| format!("Pre-connect scan stop error: {e}"))?;

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

    let props = peripheral
        .properties()
        .await
        .ok()
        .flatten()
        .ok_or_else(|| "Unable to read peripheral properties".to_string())?;

    let chars = peripheral.characteristics();
    let services = &props.services;
    let has_ftms_bike_data = chars.iter().any(|c| c.uuid == FTMS_INDOOR_BIKE_DATA);
    let supports_power = services.contains(&CYCLING_POWER_SERVICE) || has_ftms_bike_data;
    let supports_cadence = services.contains(&CSC_SERVICE) || has_ftms_bike_data;
    let supports_ftms_control = chars.iter().any(|c| c.uuid == FTMS_CONTROL_POINT);

    let name = props.local_name.unwrap_or_else(|| "Smart Trainer".to_string());
    let device = DevicePayload {
        id: device_id.to_string(),
        name,
    };

    {
        let mut guard = connected_peripheral().lock().unwrap_or_else(|p| p.into_inner());
        *guard = Some(peripheral.clone());
    }

    {
        let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        *guard = CascadeState {
            device: Some(device.clone()),
            power_connected: supports_power,
            cadence_connected: supports_cadence,
            supports_target_power: supports_ftms_control,
            supports_resistance: supports_ftms_control,
            target_watts: None,
            resistance_factor: None,
            distance_km: 0.0,
            last_distance_at: None,
        };
    }

    emit_connected(window, PREFIX, device.clone())?;

    if supports_power {
        emit_connected(window, POWER_PREFIX, DevicePayload {
            id: device.id.clone(),
            name: format!("{} (trainer power)", device.name),
        })?;
    }

    if supports_cadence {
        emit_connected(window, CADENCE_PREFIX, DevicePayload {
            id: device.id.clone(),
            name: format!("{} (trainer cadence)", device.name),
        })?;
    }

    // Emit an initial reading immediately so dashboard state hydrates.
    emit_trainer_reading(window, Some(0), 0, None, Some(0.0), Some(0.0))?;
    if supports_power {
        emit_power_reading(window, 0, &device.id)?;
    }
    if supports_cadence {
        emit_cadence_reading(window, 0, &device.id)?;
    }

    // Subscribe if the trainer exposes FTMS Indoor Bike Data.
    if let Some(ftms_char) = chars
        .iter()
        .find(|c| c.uuid == FTMS_INDOOR_BIKE_DATA)
        .cloned()
    {
        peripheral
            .subscribe(&ftms_char)
            .await
            .map_err(|e| format!("Subscribe error: {e}"))?;

        let mut notifications = peripheral
            .notifications()
            .await
            .map_err(|e| format!("Notification stream error: {e}"))?;

        while let Some(notification) = notifications.next().await {
            if notification.uuid != FTMS_INDOOR_BIKE_DATA {
                continue;
            }

            let parsed = parse_ftms_indoor_bike_data(&notification.value);
            let watts = parsed.watts.unwrap_or(0);
            let distance_km = advance_distance_km(parsed.speed_kph);
            if let Some(resistance_factor) = parsed.resistance_factor {
                let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
                guard.resistance_factor = Some(resistance_factor);
            }
            let state = {
                let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
                guard.clone()
            };

            emit_trainer_reading(
                window,
                Some(watts),
                parsed.resistance_factor.unwrap_or(state.resistance_factor.unwrap_or(0)),
                parsed.rpm,
                parsed.speed_kph,
                Some(distance_km),
            )?;

            if supports_power {
                let _ = emit_power_reading(window, watts, &device.id);
            }

            if supports_cadence {
                let _ = emit_cadence_reading(window, parsed.rpm.unwrap_or(0), &device.id);
            }
        }
    }

    Ok(())
}

#[derive(Default)]
struct FtmsParsed {
    watts: Option<u16>,
    rpm: Option<u16>,
    speed_kph: Option<f32>,
    resistance_factor: Option<u8>,
}

fn parse_ftms_indoor_bike_data(data: &[u8]) -> FtmsParsed {
    if data.len() < 2 {
        return FtmsParsed::default();
    }

    let flags = u16::from_le_bytes([data[0], data[1]]);
    let mut index = 2usize;
    let mut parsed = FtmsParsed::default();

    // Instantaneous speed (0.01 km/h) is present when bit 0 is NOT set.
    if flags & 0b1 == 0 && data.len() >= index + 2 {
        let raw = u16::from_le_bytes([data[index], data[index + 1]]);
        parsed.speed_kph = Some(raw as f32 / 100.0);
        index += 2;
    }

    // Bit 1: average speed (0.01 km/h) - skip
    if flags & (1 << 1) != 0 && data.len() >= index + 2 {
        index += 2;
    }

    // Bit 2: instantaneous cadence (0.5 rpm)
    if flags & (1 << 2) != 0 && data.len() >= index + 2 {
        let raw = u16::from_le_bytes([data[index], data[index + 1]]);
        parsed.rpm = Some((raw / 2) as u16);
        index += 2;
    }

    // Bit 3: average cadence (0.5 rpm) - skip
    if flags & (1 << 3) != 0 && data.len() >= index + 2 {
        index += 2;
    }

    // Bit 4: total distance (meters, 24-bit) - skip
    if flags & (1 << 4) != 0 && data.len() >= index + 3 {
        index += 3;
    }

    // Bit 5: resistance level (0.1%)
    if flags & (1 << 5) != 0 && data.len() >= index + 2 {
        let raw = i16::from_le_bytes([data[index], data[index + 1]]);
        let factor = ((raw as f32) / 10.0).round().clamp(0.0, 100.0) as u8;
        parsed.resistance_factor = Some(factor);
        index += 2;
    }

    // Bit 6: instantaneous power (s16). Clamp negative values to 0.
    if flags & (1 << 6) != 0 && data.len() >= index + 2 {
        let raw = i16::from_le_bytes([data[index], data[index + 1]]);
        parsed.watts = Some(raw.max(0) as u16);
    }

    parsed
}

fn connect_simulated(window: &tauri::Window, device_id: String) -> Result<(), String> {
    let device = find_simulated_device(&device_id).unwrap_or(DevicePayload {
        id: device_id,
        name: "Smart Trainer (Sim)".to_string(),
    });

    {
        let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        *guard = CascadeState {
            device: Some(device.clone()),
            power_connected: true,
            cadence_connected: true,
            supports_target_power: true,
            supports_resistance: true,
            target_watts: None,
            resistance_factor: Some(40),
            distance_km: 0.0,
            last_distance_at: None,
        };
    }

    emit_connected(window, PREFIX, device.clone())?;
    emit_connected(window, POWER_PREFIX, DevicePayload {
        id: device.id.clone(),
        name: format!("{} (trainer power)", device.name),
    })?;
    emit_connected(window, CADENCE_PREFIX, DevicePayload {
        id: device.id.clone(),
        name: format!("{} (trainer cadence)", device.name),
    })?;

    let stream_window = window.clone();
    let task = tauri::async_runtime::spawn(async move {
        let power_samples: [u16; 8] = [180, 194, 210, 223, 236, 228, 214, 199];
        let cadence_samples: [u16; 8] = [78, 81, 84, 87, 90, 88, 85, 82];
        let speed_samples: [f32; 8] = [28.0, 28.4, 29.1, 29.7, 30.2, 29.8, 29.0, 28.5];
        let mut index = 0usize;

        loop {
            let watts = power_samples[index % power_samples.len()];
            let rpm = cadence_samples[index % cadence_samples.len()];
            let speed_kph = speed_samples[index % speed_samples.len()];
            let distance_km = advance_distance_km(Some(speed_kph));
            let state = {
                let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
                guard.clone()
            };

            let _ = emit_trainer_reading(
                &stream_window,
                Some(watts),
                state.resistance_factor.unwrap_or(40),
                Some(rpm),
                Some(speed_kph),
                Some(distance_km),
            );
            let _ = emit_power_reading(&stream_window, watts, &device.id);
            let _ = emit_cadence_reading(&stream_window, rpm, &device.id);

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
            id: "trainer:sim:1".to_string(),
            name: "Smart Trainer (Sim)".to_string(),
        },
        DevicePayload {
            id: "trainer:sim:2".to_string(),
            name: "Indoor Trainer (Sim)".to_string(),
        },
    ]
}

fn find_simulated_device(device_id: &str) -> Option<DevicePayload> {
    simulated_devices().into_iter().find(|d| d.id == device_id)
}

fn stop_stream() {
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

fn emit_trainer_reading(
    window: &tauri::Window,
    watts: Option<u16>,
    resistance_factor: u8,
    rpm: Option<u16>,
    speed_kph: Option<f32>,
    distance_km: Option<f32>,
) -> Result<(), String> {
    let state = {
        let guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());
        guard.clone()
    };

    window
        .app_handle()
        .emit(
            &format!("{PREFIX}:reading"),
            SmartTrainerReading {
                speed_kph,
                resistance_factor,
                target_watts: state.target_watts,
                distance_km: distance_km.unwrap_or(state.distance_km),
                watts,
                rpm,
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

fn advance_distance_km(speed_kph: Option<f32>) -> f32 {
    let now = now_millis();
    let mut guard = cascade_state().lock().unwrap_or_else(|p| p.into_inner());

    let speed = speed_kph.unwrap_or(0.0).max(0.0);

    if let Some(previous) = guard.last_distance_at {
        let dt_hours = ((now.saturating_sub(previous)) as f32) / 3_600_000.0;
        guard.distance_km += speed * dt_hours;
    }

    guard.last_distance_at = Some(now);
    guard.distance_km
}

fn with_ftms_control_point<F, Fut>(operation: F) -> Result<(), String>
where
    F: FnOnce(Peripheral, btleplug::api::Characteristic) -> Fut,
    Fut: std::future::Future<Output = Result<(), String>>,
{
    let peripheral = {
        let guard = connected_peripheral().lock().unwrap_or_else(|p| p.into_inner());
        guard.clone()
    }
    .ok_or_else(|| "No smart trainer connected".to_string())?;

    let control_point = peripheral
        .characteristics()
        .into_iter()
        .find(|c| c.uuid == FTMS_CONTROL_POINT)
        .ok_or_else(|| "Trainer control characteristic unavailable".to_string())?;

    tauri::async_runtime::block_on(operation(peripheral, control_point))
}

fn emit_power_reading(window: &tauri::Window, watts: u16, source_id: &str) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{POWER_PREFIX}:reading"),
            PowerReading {
                watts,
                source_id: source_id.to_string(),
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}

fn emit_cadence_reading(window: &tauri::Window, rpm: u16, source_id: &str) -> Result<(), String> {
    window
        .app_handle()
        .emit(
            &format!("{CADENCE_PREFIX}:reading"),
            CadenceReading {
                rpm,
                source_id: source_id.to_string(),
                at: now_millis(),
            },
        )
        .map_err(|_| BRIDGE_ERROR.to_string())
}
