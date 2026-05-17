use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant, SystemTime},
};

#[cfg(target_os = "windows")]
use winapi::um::{
    handleapi::CloseHandle,
    minwinbase::STILL_ACTIVE,
    processthreadsapi::{GetExitCodeProcess, OpenProcess},
    winnt::PROCESS_QUERY_LIMITED_INFORMATION,
};

fn log_line(message: &str) {
    let timestamp = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_else(|_| "0".to_string());
    let line = format!("[{}] {}\n", timestamp, message);
    let _ = std::io::stderr().write_all(line.as_bytes());
    if let Some(dir) = get_update_download_dir() {
        let path = dir.join("updesk_updater.log");
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

fn get_update_download_dir() -> Option<PathBuf> {
    let dir = env::temp_dir().join("updesk-update");
    fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

#[cfg(target_os = "windows")]
fn launch_update_installer(file: &Path) -> Result<(), String> {
    let file_str = file
        .to_str()
        .ok_or_else(|| "invalid update file path".to_string())?;
    if file_str.to_ascii_lowercase().ends_with(".msi") {
        log_line(&format!("launching msi updater: {}", file.display()));
        let status = Command::new("msiexec.exe")
            .arg("/i")
            .arg(file_str)
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!("msi updater exited with status {:?}", status.code()));
        }
    } else {
        log_line(&format!("launching exe updater: {}", file.display()));
        let status = Command::new(file_str)
            .arg("--update")
            .status()
            .map_err(|e| e.to_string())?;
        log_line(&format!(
            "exe updater exit status with --update: {:?}",
            status.code()
        ));
        if !status.success() {
            log_line("retrying exe updater without --update argument");
            let retry_status = Command::new(file_str)
                .status()
                .map_err(|e| e.to_string())?;
            log_line(&format!(
                "exe updater exit status without args: {:?}",
                retry_status.code()
            ));
            if !retry_status.success() {
                return Err(format!(
                    "exe updater exited with statuses {:?} and {:?}",
                    status.code(),
                    retry_status.code()
                ));
            }
        }
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn launch_update_installer(_file: &Path) -> Result<(), String> {
    Err("updesk_updater is currently implemented for Windows only".to_string())
}

fn parse_arg(flag: &str) -> Option<String> {
    let args: Vec<String> = env::args().collect();
    let index = args.iter().position(|a| a == flag)?;
    args.get(index + 1).cloned()
}

#[cfg(target_os = "windows")]
fn is_process_running(pid: u32) -> bool {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return false;
        }
        let mut exit_code = 0;
        let ok = GetExitCodeProcess(handle, &mut exit_code) != 0;
        CloseHandle(handle);
        ok && exit_code == STILL_ACTIVE
    }
}

#[cfg(target_os = "windows")]
fn wait_for_process_exit(pid: u32, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if !is_process_running(pid) {
            return true;
        }
        thread::sleep(Duration::from_millis(300));
    }
    !is_process_running(pid)
}

#[cfg(target_os = "windows")]
fn terminate_process_tree(pid: u32) {
    log_line(&format!("forcing process shutdown for pid {}", pid));
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .status();
}

#[cfg(target_os = "windows")]
fn restart_app(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("restart target does not exist: {}", path.display()));
    }
    log_line(&format!("restarting app: {}", path.display()));
    Command::new(path).spawn().map_err(|e| e.to_string())?;
    log_line("app restart launched successfully");
    Ok(())
}

fn main() {
    let Some(file) = parse_arg("--file") else {
        log_line("missing --file argument");
        std::process::exit(2);
    };
    let file = PathBuf::from(file);
    if !file.exists() {
        log_line(&format!("update file not found: {}", file.display()));
        std::process::exit(3);
    }
    let pid = parse_arg("--pid").and_then(|p| p.parse::<u32>().ok());
    let restart = parse_arg("--restart").map(PathBuf::from);
    log_line(&format!("update launch requested: {}", file.display()));
    #[cfg(target_os = "windows")]
    if let Some(pid) = pid {
        log_line(&format!("waiting for UpDesk process to exit: pid={}", pid));
        thread::sleep(Duration::from_millis(1200));
        if !wait_for_process_exit(pid, Duration::from_secs(8)) {
            terminate_process_tree(pid);
            if !wait_for_process_exit(pid, Duration::from_secs(12)) {
                log_line(&format!("process {} did not exit after force close", pid));
                std::process::exit(4);
            }
        }
        log_line(&format!("UpDesk process exited: pid={}", pid));
    } else {
        thread::sleep(Duration::from_millis(1200));
    }
    match launch_update_installer(&file) {
        Ok(_) => {
            log_line("update installer launched");
            #[cfg(target_os = "windows")]
            if let Some(restart_path) = restart {
                thread::sleep(Duration::from_millis(1200));
                if let Err(e) = restart_app(&restart_path) {
                    log_line(&format!("restart skipped: {}", e));
                }
            }
        }
        Err(e) => {
            log_line(&format!("update installer launch failed: {}", e));
            std::process::exit(1);
        }
    }
}
