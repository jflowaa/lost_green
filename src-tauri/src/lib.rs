mod devices;

use devices::{cadence, heart_rate, power_meter, secondary_power_meter, smart_trainer};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_shell::process::CommandChild;

const BACKEND_SHUTDOWN_TOKEN: &str = "d1d2f5a3-5d7c-4d34-a3af-86f2eb31d8dc";

#[derive(Default)]
struct BackendChildState(Mutex<Option<CommandChild>>);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            // Heart rate monitor
            heart_rate::list_heart_rate_devices,
            heart_rate::connect_heart_rate_device,
            heart_rate::disconnect_heart_rate_device,
            heart_rate::heart_rate_bridge_error,
            // Power meter
            power_meter::list_power_meter_devices,
            power_meter::connect_power_meter_device,
            power_meter::disconnect_power_meter_device,
            power_meter::power_meter_bridge_error,
            // Cadence sensor
            cadence::list_cadence_devices,
            cadence::connect_cadence_device,
            cadence::disconnect_cadence_device,
            cadence::cadence_bridge_error,
            // Smart trainer
            smart_trainer::list_smart_trainer_devices,
            smart_trainer::connect_smart_trainer_device,
            smart_trainer::disconnect_smart_trainer_device,
            smart_trainer::set_smart_trainer_target_watts,
            smart_trainer::set_smart_trainer_resistance_factor,
            smart_trainer::smart_trainer_bridge_error,
            // Secondary power meter
            secondary_power_meter::list_secondary_power_meter_devices,
            secondary_power_meter::connect_secondary_power_meter_device,
            secondary_power_meter::disconnect_secondary_power_meter_device,
            secondary_power_meter::secondary_power_meter_bridge_error,
        ])
        .setup(|app| {
            app.manage(BackendChildState::default());

            let handle = app.handle().clone();

            if let Err(error) = init_tauri_logging(&handle) {
                eprintln!("Failed to initialize Tauri logger: {error}");
            }

            // Start the Elixir backend as a sidecar
            tauri::async_runtime::spawn(async move {
                if let Err(e) = start_backend(&handle).await {
                    log::error!("Failed to start backend: {e}");
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if let tauri::RunEvent::ExitRequested { .. } = event {
            shutdown_backend(app_handle);
        }
    });
}

async fn start_backend(handle: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    use tauri_plugin_shell::ShellExt;

    log::info!("Starting lost green backend...");
    log::info!("Platform: {}", std::env::consts::OS);
    log::info!("Architecture: {}", std::env::consts::ARCH);

    let data_dir = resolve_data_dir(handle)?;

    std::fs::create_dir_all(&data_dir)?;

    let logs_dir = data_dir.join("logs");
    std::fs::create_dir_all(&logs_dir)?;

    let database_path = data_dir.join("lost_green.db");
    let database_path = database_path.to_string_lossy().into_owned();
    let logs_dir = logs_dir.to_string_lossy().into_owned();
        let backend_url = backend_base_url();

    log::info!("Database path: {}", database_path);
    log::info!("Logs directory: {}", logs_dir);
        log::info!("Backend URL: {}", backend_url);

        if cfg!(debug_assertions) {
            log::info!("Dev mode: checking for an externally running backend...");

            if wait_for_backend_ready(&backend_url, 3).await.is_ok() {
                    log::info!("Using externally running backend in dev mode");
                    open_main_window(handle, &backend_url)?;
                    return Ok(());
            }

            log::info!("No external backend detected, falling back to sidecar startup");
        }

        shutdown_existing_backend(&backend_url).await?;

    // Get the sidecar command for the backend - Tauri will automatically select the right binary
    let sidecar_command = handle
        .shell()
        .sidecar("lost_green_backend")?
        .env("PORT", "4000")
        .env("MIX_ENV", "prod")
        .env("DATABASE_PATH", &database_path)
        .env("LOGS_DIRECTORY", &logs_dir)
        .env("BACKEND_SHUTDOWN_TOKEN", BACKEND_SHUTDOWN_TOKEN)
        .env("SECRET_KEY_BASE", "U/C6TzOHVzM+7XTFUfwKU/zolVW5U+hfSXOVPinz9/0nG0X2eO9/SwTIlpdhZOoz")
        .env("RUNNING_UNDER_TAURI", "true");

    // Spawn the sidecar process
    let (_rx, child) = sidecar_command.spawn()?;

    {
        let state: tauri::State<BackendChildState> = handle.state();
        let mut backend_child = match state.0.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };

        if let Some(existing_child) = backend_child.take() {
            if let Err(error) = existing_child.kill() {
                log::warn!("Failed to terminate existing backend process: {error}");
            }
        }

        *backend_child = Some(child);
    }

    log::info!("Backend process started, waiting for it to be ready...");
    wait_for_backend_ready(&backend_url, 60).await?;
    open_main_window(handle, &backend_url)?;

    Ok(())
}

fn resolve_data_dir(handle: &tauri::AppHandle) -> Result<PathBuf, Box<dyn std::error::Error>> {
    if cfg!(debug_assertions) {
        Ok(std::env::current_dir()?)
    } else {
        Ok(handle.path().app_data_dir()?)
    }
}

fn init_tauri_logging(handle: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let logs_dir = resolve_data_dir(handle)?.join("logs");
    std::fs::create_dir_all(&logs_dir)?;

    let mut logger = flexi_logger::Logger::try_with_str("info")?
        .log_to_file(
            flexi_logger::FileSpec::default()
                .directory(logs_dir)
                .basename("frontend"),
        )
        .rotate(
            flexi_logger::Criterion::Size(10_485_760),
            flexi_logger::Naming::Numbers,
            flexi_logger::Cleanup::KeepLogFiles(10),
        );

    if cfg!(debug_assertions) {
        logger = logger.duplicate_to_stdout(flexi_logger::Duplicate::Info);
    }

    logger.start()?;

    Ok(())
}

fn shutdown_backend(handle: &tauri::AppHandle) {
    let state: tauri::State<BackendChildState> = handle.state();
    let mut backend_child = match state.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    if let Some(child) = backend_child.take() {
        if let Err(error) = child.kill() {
            log::warn!("Failed to stop backend sidecar process during shutdown: {error}");
        } else {
            log::info!("Stopped backend sidecar process");
        }
    }
}

async fn shutdown_existing_backend(backend_url: &str) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::builder()
        .timeout(tokio::time::Duration::from_secs(2))
        .build()?;

    let health = client.get(backend_url).send().await;

    if health.is_err() {
        return Ok(());
    }

    log::info!("Existing backend detected at {backend_url}, requesting shutdown");

    let shutdown_response = client
        .post(format!("{backend_url}/internal/shutdown"))
        .header("x-backend-shutdown-token", BACKEND_SHUTDOWN_TOKEN)
        .send()
        .await;

    match shutdown_response {
        Ok(response) if response.status().is_success() => {
            for _ in 0..30 {
                tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;

                if client.get(backend_url).send().await.is_err() {
                    log::info!("Existing backend shutdown confirmed");
                    return Ok(());
                }
            }

            Err("existing backend did not stop in time".into())
        }
        Ok(response) => Err(
            format!(
                "failed to stop existing backend: shutdown endpoint returned {}",
                response.status()
            )
            .into(),
        ),
        Err(error) => Err(format!("failed to stop existing backend: {error}").into()),
    }
}

fn backend_base_url() -> String {
    std::env::var("TAURI_BACKEND_URL").unwrap_or_else(|_| "http://localhost:4000".to_string())
}

async fn wait_for_backend_ready(
    backend_url: &str,
    max_attempts: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    for attempt in 1..=max_attempts {
        match reqwest::get(backend_url).await {
            Ok(response) if response.status().is_success() => {
                log::info!("Backend is ready after {} attempts!", attempt);
                return Ok(());
            }
            Ok(response) => {
                if attempt == max_attempts {
                    break;
                }

                log::info!(
                    "Backend responded with status: {} (attempt {})",
                    response.status(),
                    attempt
                );
            }
            Err(error) => {
                if attempt == max_attempts {
                    break;
                }

                if attempt % 5 == 0 {
                    log::info!(
                        "Waiting for backend... (attempt {}/{}): {}",
                        attempt,
                        max_attempts,
                        error
                    );
                }
            }
        }

        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
    }

    Err(format!("Backend failed to start after {} attempts", max_attempts).into())
}

fn open_main_window(
    handle: &tauri::AppHandle,
    backend_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    WebviewWindowBuilder::new(
        handle,
        "main",
        WebviewUrl::External(backend_url.parse()?),
    )
    .title("Bike Potato")
    .inner_size(1200.0, 800.0)
    .center()
    .build()?;

    log::info!("Main window opened successfully");

    Ok(())
}
