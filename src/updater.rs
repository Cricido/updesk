use crate::{
    common::{do_check_software_update, get_software_update_manifest, SoftwareUpdateManifest},
    hbbs_http::create_http_client_with_url,
};
use hbb_common::{bail, config, log, ResultType};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{channel, Receiver, Sender},
        Mutex,
    },
    time::{Duration, Instant},
};
use url::Url;

enum UpdateMsg {
    CheckUpdate,
    Exit,
}

lazy_static::lazy_static! {
    static ref TX_MSG : Mutex<Sender<UpdateMsg>> = Mutex::new(start_auto_update_check());
    static ref UPDATE_ACTION_STATUS: Mutex<String> = Mutex::new(String::new());
    static ref UPDATE_ACTION_ERROR: Mutex<String> = Mutex::new(String::new());
}

static CONTROLLING_SESSION_COUNT: AtomicUsize = AtomicUsize::new(0);

const DUR_ONE_DAY: Duration = Duration::from_secs(60 * 60 * 24);
const UPDATE_DOWNLOAD_RETRY_COUNT: usize = 2;

pub fn set_update_action_state(status: &str, error: &str) {
    *UPDATE_ACTION_STATUS.lock().unwrap() = status.to_owned();
    *UPDATE_ACTION_ERROR.lock().unwrap() = error.to_owned();
}

pub fn get_update_action_status() -> String {
    UPDATE_ACTION_STATUS.lock().unwrap().clone()
}

pub fn get_update_action_error() -> String {
    UPDATE_ACTION_ERROR.lock().unwrap().clone()
}

pub fn update_controlling_session_count(count: usize) {
    CONTROLLING_SESSION_COUNT.store(count, Ordering::SeqCst);
}

#[allow(dead_code)]
pub fn start_auto_update() {
    let _sender = TX_MSG.lock().unwrap();
}

#[allow(dead_code)]
pub fn manually_check_update() -> ResultType<()> {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::CheckUpdate)?;
    Ok(())
}

#[allow(dead_code)]
pub fn stop_auto_update() {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::Exit).unwrap_or_default();
}

#[inline]
fn has_no_active_conns() -> bool {
    let conns = crate::Connection::alive_conns();
    conns.is_empty() && has_no_controlling_conns()
}

#[cfg(any(not(target_os = "windows"), feature = "flutter"))]
fn has_no_controlling_conns() -> bool {
    CONTROLLING_SESSION_COUNT.load(Ordering::SeqCst) == 0
}

#[cfg(not(any(not(target_os = "windows"), feature = "flutter")))]
fn has_no_controlling_conns() -> bool {
    let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
    for arg in [
        "--connect",
        "--play",
        "--file-transfer",
        "--view-camera",
        "--port-forward",
        "--rdp",
    ] {
        if !crate::platform::get_pids_of_process_with_first_arg(&app_exe, arg).is_empty() {
            return false;
        }
    }
    true
}

fn start_auto_update_check() -> Sender<UpdateMsg> {
    let (tx, rx) = channel();
    std::thread::spawn(move || start_auto_update_check_(rx));
    return tx;
}

fn start_auto_update_check_(rx_msg: Receiver<UpdateMsg>) {
    std::thread::sleep(Duration::from_secs(30));
    if let Err(e) = check_update(false) {
        log::error!("Error checking for updates: {}", e);
    }

    const MIN_INTERVAL: Duration = Duration::from_secs(60 * 10);
    const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 30);
    let mut last_check_time = Instant::now();
    let mut check_interval = DUR_ONE_DAY;
    loop {
        let recv_res = rx_msg.recv_timeout(check_interval);
        match &recv_res {
            Ok(UpdateMsg::CheckUpdate) | Err(_) => {
                if last_check_time.elapsed() < MIN_INTERVAL {
                    // log::debug!("Update check skipped due to minimum interval.");
                    continue;
                }
                // Don't check update if there are alive connections.
                if !has_no_active_conns() {
                    check_interval = RETRY_INTERVAL;
                    continue;
                }
                if let Err(e) = check_update(matches!(recv_res, Ok(UpdateMsg::CheckUpdate))) {
                    log::error!("Error checking for updates: {}", e);
                    check_interval = RETRY_INTERVAL;
                } else {
                    last_check_time = Instant::now();
                    check_interval = DUR_ONE_DAY;
                }
            }
            Ok(UpdateMsg::Exit) => break,
        }
    }
}

fn check_update(manually: bool) -> ResultType<()> {
    if !(manually || config::Config::get_bool_option(config::keys::OPTION_ALLOW_AUTO_UPDATE)) {
        return Ok(());
    }
    set_update_action_state("checking", "");
    log::info!("update check requested: manually={}", manually);
    if let Err(e) = do_check_software_update() {
        set_update_action_state("failed", &format!("Controllo aggiornamenti fallito: {}", e));
        log::error!("update check failed: {}", e);
        return Ok(());
    }

    let Some(manifest) = get_software_update_manifest() else {
        set_update_action_state("up-to-date", "");
        log::info!("no update available");
        return Ok(());
    };
    log::info!(
        "update available: local_version={} remote_version={} mandatory={} min_supported={}",
        crate::VERSION,
        manifest.version,
        manifest.mandatory,
        manifest.min_supported
    );
    let file_path = match download_update(&manifest) {
        Ok(path) => path,
        Err(e) => {
            set_update_action_state("failed", &format!("Download aggiornamento fallito: {}", e));
            return Err(e);
        }
    };
    if has_no_active_conns() {
        #[cfg(target_os = "windows")]
        update_new_version(&manifest, &file_path);
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn update_new_version(manifest: &SoftwareUpdateManifest, file_path: &PathBuf) {
    log::debug!(
        "new version is downloaded, update begin, version: {}, file: {:?}",
        manifest.version,
        file_path.to_str()
    );
    if let Err(e) = launch_updater_process(file_path) {
        log::error!(
            "failed to launch updater for version {}: {}",
            manifest.version,
            e
        );
        fs::remove_file(file_path).ok();
    }
}

pub fn get_download_file_from_url(url: &str) -> Option<PathBuf> {
    let parsed = Url::parse(url).ok()?;
    let filename = parsed.path_segments()?.next_back()?;
    if filename.trim().is_empty() {
        return None;
    }
    let dir = get_update_download_dir()?;
    Some(dir.join(filename))
}

pub fn get_update_download_dir() -> Option<PathBuf> {
    let dir = std::env::temp_dir().join("updesk-update");
    fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn cleanup_update_dir(active_file: Option<&Path>) {
    let Some(dir) = get_update_download_dir() else {
        return;
    };
    let active_name = active_file.and_then(|p| p.file_name()).map(|p| p.to_os_string());
    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) => {
            log::warn!("failed to read update dir {}: {}", dir.display(), e);
            return;
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = match path.file_name() {
            Some(name) => name.to_os_string(),
            None => continue,
        };
        if active_name.as_ref().is_some_and(|active| active == &name) {
            continue;
        }
        let remove = match path.extension().and_then(|e| e.to_str()) {
            Some("download") => true,
            Some("exe") | Some("msi") => true,
            _ => false,
        };
        if remove {
            if let Err(e) = fs::remove_file(&path) {
                log::warn!("failed to cleanup stale update file {}: {}", path.display(), e);
            }
        }
    }
}

fn write_update_file_atomically(target_path: &Path, file_data: &[u8]) -> ResultType<()> {
    let part_path = target_path.with_extension(format!(
        "{}download",
        target_path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| format!("{e}."))
            .unwrap_or_default()
    ));
    if part_path.exists() {
        fs::remove_file(&part_path).ok();
    }
    let mut file = fs::File::create(&part_path)?;
    file.write_all(file_data)?;
    file.sync_all()?;
    if target_path.exists() {
        fs::remove_file(target_path).ok();
    }
    fs::rename(&part_path, target_path)?;
    Ok(())
}

fn download_update(manifest: &SoftwareUpdateManifest) -> ResultType<PathBuf> {
    let download_url = manifest.url.clone();
    let client = create_http_client_with_url(&download_url);
    let Some(file_path) = get_download_file_from_url(&download_url) else {
        bail!("failed to get the file path from the URL: {}", download_url);
    };
    cleanup_update_dir(Some(&file_path));

    log::info!(
        "update download started: version={} url={} target={}",
        manifest.version,
        download_url,
        file_path.display()
    );
    set_update_action_state("downloading", "");

    if file_path.exists() {
        set_update_action_state("verifying", "");
        match verify_file_sha256(&file_path, &manifest.sha256) {
            Ok(_) => {
                log::info!("update sha256 ok on existing file: {}", file_path.display());
                set_update_action_state("ready", "");
                return Ok(file_path);
            }
            Err(e) => {
                log::warn!(
                    "existing update file verification failed, deleting {}: {}",
                    file_path.display(),
                    e
                );
                fs::remove_file(&file_path).ok();
            }
        }
    }
    let mut last_error = None;
    for attempt in 1..=UPDATE_DOWNLOAD_RETRY_COUNT {
        log::info!(
            "update download attempt: version={} attempt={}/{} url={}",
            manifest.version,
            attempt,
            UPDATE_DOWNLOAD_RETRY_COUNT,
            download_url
        );
        match client.get(&download_url).send() {
            Ok(response) => {
                if !response.status().is_success() {
                    last_error = Some(format!(
                        "failed to download the new version file: {}",
                        response.status()
                    ));
                } else {
                    let file_data = response.bytes()?;
                    write_update_file_atomically(&file_path, file_data.as_ref())?;
                    log::info!(
                        "update download completed: version={} bytes={} path={}",
                        manifest.version,
                        file_data.len(),
                        file_path.display()
                    );
                    set_update_action_state("verifying", "");
                    verify_file_sha256(&file_path, &manifest.sha256)?;
                    set_update_action_state("ready", "");
                    return Ok(file_path);
                }
            }
            Err(e) => {
                last_error = Some(e.to_string());
            }
        }
        fs::remove_file(&file_path).ok();
    }
    let message = last_error.unwrap_or_else(|| "unknown download error".to_owned());
    set_update_action_state("failed", &format!("Download aggiornamento fallito: {}", message));
    bail!(message)
}

pub fn verify_file_sha256(file_path: &Path, expected_sha256: &str) -> ResultType<()> {
    log::info!("verifying update sha256: file={}", file_path.display());
    let mut file = fs::File::open(file_path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let actual = format!("{:x}", hasher.finalize());
    if actual.eq_ignore_ascii_case(expected_sha256) {
        log::info!("update sha256 ok: file={}", file_path.display());
        Ok(())
    } else {
        fs::remove_file(file_path).ok();
        set_update_action_state("failed", "Verifica integrita fallita: SHA256 non valido");
        bail!(
            "update sha256 mismatch: expected={} actual={}",
            expected_sha256,
            actual
        );
    }
}

#[cfg(target_os = "windows")]
pub fn launch_update_updater(file_path: &Path) -> ResultType<()> {
    if !has_no_active_conns() {
        let message =
            "Aggiornamento bloccato: chiudi prima sessioni remote o connessioni attive.";
        set_update_action_state("failed", message);
        bail!(message);
    }
    set_update_action_state("preparing", "");
    let Some(manifest) = get_software_update_manifest() else {
        set_update_action_state("failed", "Manifest update non disponibile");
        bail!("missing cached update manifest");
    };
    if manifest.sha256.is_empty() {
        set_update_action_state("failed", "SHA256 manifest mancante");
        bail!("missing sha256 in cached update manifest");
    }
    let resolved_file = if file_path.exists() {
        file_path.to_path_buf()
    } else {
        log::warn!(
            "cached update file is missing, downloading again before launch: {}",
            file_path.display()
        );
        match download_update(&manifest) {
            Ok(path) => path,
            Err(e) => {
                set_update_action_state("failed", &format!("Download aggiornamento fallito: {}", e));
                return Err(e);
            }
        }
    };
    set_update_action_state("verifying", "");
    verify_file_sha256(&resolved_file, &manifest.sha256)?;
    set_update_action_state("launching", "");
    launch_updater_process(&resolved_file)
}

#[cfg(target_os = "windows")]
pub fn launch_update_from_url(download_url: &str) -> ResultType<()> {
    if !has_no_active_conns() {
        let message =
            "Aggiornamento bloccato: chiudi prima sessioni remote o connessioni attive.";
        set_update_action_state("failed", message);
        bail!(message);
    }
    set_update_action_state("preparing", "");
    let Some(manifest) = get_software_update_manifest() else {
        set_update_action_state("failed", "Manifest update non disponibile");
        bail!("missing cached update manifest");
    };
    if manifest.url != download_url {
        log::warn!(
            "update url differs from cached manifest, continuing with cached manifest url: requested={} cached={}",
            download_url,
            manifest.url
        );
    }
    let file_path = match download_update(&manifest) {
        Ok(path) => path,
        Err(e) => {
            set_update_action_state("failed", &format!("Download aggiornamento fallito: {}", e));
            return Err(e);
        }
    };
    launch_update_updater(&file_path)
}

#[cfg(target_os = "windows")]
fn launch_updater_process(file_path: &Path) -> ResultType<()> {
    let file_arg = file_path
        .to_str()
        .ok_or_else(|| hbb_common::anyhow::anyhow!("failed to convert update file path"))?;
    let current_exe = match std::env::current_exe() {
        Ok(path) => path,
        Err(e) => {
            log::warn!(
                "failed to resolve current exe for updater helper, fallback to in-process updater launch: {}",
                e
            );
            let res = crate::platform::update_to(file_arg);
            if res.is_ok() {
                set_update_action_state("installer-launched", "");
            } else if let Err(err) = &res {
                set_update_action_state("failed", &format!("Avvio installer fallito: {}", err));
            }
            return res;
        }
    };
    let Some(parent) = current_exe.parent() else {
        log::warn!(
            "failed to get current exe directory for updater helper, fallback to in-process updater launch"
        );
        let res = crate::platform::update_to(file_arg);
        if res.is_ok() {
            set_update_action_state("installer-launched", "");
        } else if let Err(err) = &res {
            set_update_action_state("failed", &format!("Avvio installer fallito: {}", err));
        }
        return res;
    };
    let updater_exe = parent.join("updesk_updater.exe");
    if updater_exe.exists() {
        log::info!(
            "update launch started via updater: updater={} file={}",
            updater_exe.display(),
            file_path.display()
        );
        match std::process::Command::new(&updater_exe)
            .current_dir(parent)
            .arg("--file")
            .arg(file_arg)
            .arg("--pid")
            .arg(std::process::id().to_string())
            .arg("--restart")
            .arg(current_exe.to_string_lossy().to_string())
            .spawn()
        {
            Ok(_) => {
                set_update_action_state("installer-launched", "");
                Ok(())
            }
            Err(e) => {
                log::warn!(
                    "failed to spawn updater helper at {}, fallback to in-process updater launch: {}",
                    updater_exe.display(),
                    e
                );
                let res = crate::platform::update_to(file_arg);
                if res.is_ok() {
                    set_update_action_state("installer-launched", "");
                } else if let Err(err) = &res {
                    set_update_action_state(
                        "failed",
                        &format!("Avvio updater helper fallito: {}; installer diretto fallito: {}", e, err),
                    );
                }
                res
            }
        }
    } else {
        log::warn!(
            "updesk_updater.exe not found at {}, fallback to in-process updater launch",
            updater_exe.display()
        );
        let file_str = file_path
            .to_str()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("failed to convert update file path"))?;
        let res = crate::platform::update_to(file_str);
        if res.is_ok() {
            set_update_action_state("installer-launched", "");
        } else if let Err(err) = &res {
            set_update_action_state("failed", &format!("Avvio installer fallito: {}", err));
        }
        res
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn download_path_uses_updesk_update_dir() {
        let path =
            get_download_file_from_url("https://updesk.uptimeservice.it/releases/windows/updesk-1.0.2.exe")
                .unwrap();
        let path_str = path.to_string_lossy().to_lowercase();
        assert!(path_str.contains("updesk-update"));
        assert!(path_str.ends_with("updesk-1.0.2.exe"));
    }

    #[test]
    fn download_path_rejects_invalid_urls() {
        assert!(get_download_file_from_url("not-a-url").is_none());
        assert!(get_download_file_from_url("https://updesk.uptimeservice.it/").is_none());
    }
}
