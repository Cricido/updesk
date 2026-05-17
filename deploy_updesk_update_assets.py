from pathlib import Path
import posixpath
import paramiko
import argparse
import json


HOST = "updesk.uptimeservice.it"
PORT = 22
USERNAME = "uptime"
PASSWORD = "Memento@2017"

ROOT = Path(__file__).resolve().parent
REMOTE_WEB_ROOT = "/var/www/updesk"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--channel",
        choices=["stable", "recommended", "beta"],
        default="stable",
        help="Update channel manifest to publish",
    )
    return parser.parse_args()


def run(client, cmd):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def parse_version_from_manifest(local_manifest: Path) -> str:
    data = json.loads(local_manifest.read_text(encoding="utf-8"))
    version = (data.get("version") or "").strip()
    if not version:
        raise RuntimeError(f"{local_manifest.name} missing version")
    return version


def main():
    args = parse_args()
    local_manifest = ROOT / f"{args.channel}.json"
    if not local_manifest.exists():
        raise RuntimeError(f"manifest not found: {local_manifest}")

    version = parse_version_from_manifest(local_manifest)
    local_installer = ROOT / f"UptimeDesk-{version}-x86_64-Setup.exe"
    if not local_installer.exists():
        raise RuntimeError(f"installer not found: {local_installer}")

    remote_manifest = f"{REMOTE_WEB_ROOT}/api/v1/update/{args.channel}.json"
    remote_installer = f"{REMOTE_WEB_ROOT}/releases/windows/updesk-{version}.exe"

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        port=PORT,
        username=USERNAME,
        password=PASSWORD,
        timeout=20,
        banner_timeout=20,
        auth_timeout=20,
    )
    sftp = client.open_sftp()
    try:
        run(
            client,
            "echo 'Memento@2017' | sudo -S mkdir -p "
            f"{REMOTE_WEB_ROOT}/api/v1/update {REMOTE_WEB_ROOT}/releases/windows",
        )

        tmp_manifest = posixpath.join("/home/uptime", f"{args.channel}.json.tmp")
        tmp_installer = posixpath.join("/home/uptime", f"updesk-{version}.exe.tmp")
        sftp.put(str(local_manifest), tmp_manifest)
        sftp.put(str(local_installer), tmp_installer)

        run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_manifest} {remote_manifest}")
        run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_installer} {remote_installer}")
        run(client, f"echo 'Memento@2017' | sudo -S chown -R www-data:www-data {REMOTE_WEB_ROOT}")
        run(client, f"echo 'Memento@2017' | sudo -S find {REMOTE_WEB_ROOT} -type d -exec chmod 755 {{}} \\;")
        run(client, f"echo 'Memento@2017' | sudo -S find {REMOTE_WEB_ROOT} -type f -exec chmod 644 {{}} \\;")

        checks = {
            "nginx_config": "grep -n \"location /ws/id\\|location /ws/relay\\|location /api/\\|location /releases/\\|proxy_buffering off\" /etc/nginx/sites-enabled/updesk-static || true",
            "nginx_test": "echo 'Memento@2017' | sudo -S nginx -t",
            "reload_nginx": "echo 'Memento@2017' | sudo -S systemctl reload nginx",
            "manifest_url": f"curl -I -sS https://updesk.uptimeservice.it/api/v1/update/{args.channel}.json || true",
            "release_url": f"curl -I -sS https://updesk.uptimeservice.it/releases/windows/updesk-{version}.exe || true",
            "ws_id": "curl -I -sS https://updesk.uptimeservice.it/ws/id || true",
            "ws_relay": "curl -I -sS https://updesk.uptimeservice.it/ws/relay || true",
        }
        for name, cmd in checks.items():
            code, out, err = run(client, cmd)
            print(f"=== {name} code={code} ===")
            if out:
                print(out.strip())
            if err:
                print("--- STDERR ---")
                print(err.strip())
            print()
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
