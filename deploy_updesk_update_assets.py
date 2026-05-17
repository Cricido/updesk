from pathlib import Path
import posixpath
import paramiko
import argparse
import json
import hashlib
import re
from urllib.parse import urlparse
import base64
import os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


HOST = "updesk.uptimeservice.it"
PORT = 22
USERNAME = "uptime"
PASSWORD = "Memento@2017"

ROOT = Path(__file__).resolve().parent
REMOTE_WEB_ROOT = "/var/www/updesk"
EXPECTED_HOST = "updesk.uptimeservice.it"
PUBLIC_KEY_PATH = ROOT / "res" / "update_manifest_public_key.txt"
PUBLISH_LOCK_PATH = ROOT / ".deploy_updesk_update_assets.lock"


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


def parse_manifest(local_manifest: Path) -> dict:
    return json.loads(local_manifest.read_text(encoding="utf-8"))


def is_version_string(value: str) -> bool:
    return bool(re.fullmatch(r"\d+\.\d+\.\d+", value or ""))


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(data: dict, expected_channel: str) -> str:
    channel = str(data.get("channel") or "").strip().lower()
    version = str(data.get("version") or "").strip()
    url = str(data.get("url") or "").strip()
    sha256 = str(data.get("sha256") or "").strip().lower()
    min_supported = str(data.get("min_supported") or "").strip()

    if channel != expected_channel:
        raise RuntimeError(
            f"manifest channel mismatch: expected={expected_channel} actual={channel or '<empty>'}"
        )
    if not is_version_string(version):
        raise RuntimeError(f"invalid manifest version: {version!r}")
    if min_supported and not is_version_string(min_supported):
        raise RuntimeError(f"invalid manifest min_supported: {min_supported!r}")
    if len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256):
        raise RuntimeError("invalid manifest sha256: expected 64 lowercase hex chars")

    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise RuntimeError(f"invalid manifest url scheme: {url}")
    if parsed.netloc != EXPECTED_HOST:
        raise RuntimeError(f"invalid manifest host: {parsed.netloc}")
    expected_path = f"/releases/windows/updesk-{version}.exe"
    if parsed.path != expected_path:
        raise RuntimeError(
            f"invalid manifest release path: expected={expected_path} actual={parsed.path}"
        )
    signature = str(data.get("signature") or "").strip()
    if not signature:
        raise RuntimeError("manifest signature missing")
    return version


def canonical_manifest_payload(data: dict) -> bytes:
    mandatory = "true" if bool(data.get("mandatory")) else "false"
    changelog = str(data.get("changelog") or "").replace("\r\n", "\n").replace("\r", "\n")
    payload = (
        f"channel={str(data.get('channel') or '').strip().lower()}\n"
        f"version={str(data.get('version') or '').strip()}\n"
        f"url={str(data.get('url') or '').strip()}\n"
        f"sha256={str(data.get('sha256') or '').strip().lower()}\n"
        f"mandatory={mandatory}\n"
        f"min_supported={str(data.get('min_supported') or '').strip()}\n"
        f"changelog={changelog}\n"
    )
    return payload.encode("utf-8")


def verify_manifest_signature(data: dict):
    if not PUBLIC_KEY_PATH.exists():
        raise RuntimeError(f"manifest public key not found: {PUBLIC_KEY_PATH}")
    public_key = Ed25519PublicKey.from_public_bytes(
        base64.b64decode(PUBLIC_KEY_PATH.read_text(encoding="utf-8").strip())
    )
    signature = base64.b64decode(str(data.get("signature") or "").strip())
    public_key.verify(signature, canonical_manifest_payload(data))


def parse_version_from_manifest(local_manifest: Path, expected_channel: str) -> tuple[str, dict]:
    data = parse_manifest(local_manifest)
    version = validate_manifest(data, expected_channel)
    return version, data


def require_ok(name: str, code: int, out: str, err: str):
    print(f"=== {name} code={code} ===")
    if out:
        print(out.strip())
    if err:
        print("--- STDERR ---")
        print(err.strip())
    print()
    if code != 0:
        raise RuntimeError(f"{name} failed with exit code {code}")


def acquire_publish_lock():
    try:
        fd = os.open(str(PUBLISH_LOCK_PATH), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode("ascii", errors="ignore"))
        return fd
    except FileExistsError as exc:
        raise RuntimeError(
            f"publish lock already held: {PUBLISH_LOCK_PATH}. "
            "Run channel publish jobs sequentially."
        ) from exc


def release_publish_lock(fd: int | None):
    if fd is None:
        return
    try:
        os.close(fd)
    finally:
        try:
            PUBLISH_LOCK_PATH.unlink(missing_ok=True)
        except OSError:
            pass


def main():
    lock_fd = acquire_publish_lock()
    args = parse_args()
    local_manifest = ROOT / f"{args.channel}.json"
    if not local_manifest.exists():
        raise RuntimeError(f"manifest not found: {local_manifest}")

    version, local_manifest_data = parse_version_from_manifest(local_manifest, args.channel)
    verify_manifest_signature(local_manifest_data)
    local_installer = ROOT / f"UptimeDesk-{version}-x86_64-Setup.exe"
    if not local_installer.exists():
        raise RuntimeError(f"installer not found: {local_installer}")
    local_installer_sha256 = compute_sha256(local_installer)
    manifest_sha256 = str(local_manifest_data.get("sha256") or "").strip().lower()
    if local_installer_sha256 != manifest_sha256:
        raise RuntimeError(
            "local installer sha256 mismatch: "
            f"manifest={manifest_sha256} actual={local_installer_sha256}"
        )

    remote_manifest = f"{REMOTE_WEB_ROOT}/api/v1/update/{args.channel}.json"
    remote_installer = f"{REMOTE_WEB_ROOT}/releases/windows/updesk-{version}.exe"

    try:
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
        code, out, err = run(
            client,
            "echo 'Memento@2017' | sudo -S mkdir -p "
            f"{REMOTE_WEB_ROOT}/api/v1/update {REMOTE_WEB_ROOT}/releases/windows",
        )
        require_ok("prepare_dirs", code, out, err)

        tmp_manifest = posixpath.join("/home/uptime", f"{args.channel}.json.tmp")
        tmp_installer = posixpath.join("/home/uptime", f"updesk-{version}.exe.tmp")
        sftp.put(str(local_manifest), tmp_manifest)
        sftp.put(str(local_installer), tmp_installer)

        code, out, err = run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_manifest} {remote_manifest}")
        require_ok("publish_manifest", code, out, err)
        code, out, err = run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_installer} {remote_installer}")
        require_ok("publish_installer", code, out, err)
        code, out, err = run(client, f"echo 'Memento@2017' | sudo -S chown -R www-data:www-data {REMOTE_WEB_ROOT}")
        require_ok("chown_web_root", code, out, err)
        code, out, err = run(client, f"echo 'Memento@2017' | sudo -S find {REMOTE_WEB_ROOT} -type d -exec chmod 755 {{}} \\;")
        require_ok("chmod_dirs", code, out, err)
        code, out, err = run(client, f"echo 'Memento@2017' | sudo -S find {REMOTE_WEB_ROOT} -type f -exec chmod 644 {{}} \\;")
        require_ok("chmod_files", code, out, err)

        code, out, err = run(client, f"sha256sum {remote_installer} | awk '{{print $1}}'")
        require_ok("remote_sha256", code, out, err)
        remote_sha256 = out.strip().lower()
        if remote_sha256 != local_installer_sha256:
            raise RuntimeError(
                "remote installer sha256 mismatch: "
                f"local={local_installer_sha256} remote={remote_sha256}"
            )

        checks = {
            "nginx_config": "grep -n \"location /ws/id\\|location /ws/relay\\|location /api/\\|location /releases/\\|proxy_buffering off\" /etc/nginx/sites-enabled/updesk-static || true",
            "nginx_test": "echo 'Memento@2017' | sudo -S nginx -t",
            "reload_nginx": "echo 'Memento@2017' | sudo -S systemctl reload nginx",
            "manifest_url": f"curl -fsSI https://updesk.uptimeservice.it/api/v1/update/{args.channel}.json",
            "release_url": f"curl -fsSI https://updesk.uptimeservice.it/releases/windows/updesk-{version}.exe",
            "manifest_body": f"curl -fsS https://updesk.uptimeservice.it/api/v1/update/{args.channel}.json",
        }
        manifest_body = None
        nginx_config_body = None
        for name, cmd in checks.items():
            code, out, err = run(client, cmd)
            require_ok(name, code, out, err)
            if name == "manifest_body":
                manifest_body = out
            elif name == "nginx_config":
                nginx_config_body = out
        if not nginx_config_body:
            raise RuntimeError("nginx update/websocket locations were not found in updesk-static")
        for fragment in ("location /ws/id", "location /ws/relay", "location /api/", "location /releases/", "proxy_buffering off"):
            if fragment not in nginx_config_body:
                raise RuntimeError(f"nginx config check missing fragment: {fragment}")
        if not manifest_body:
            raise RuntimeError("published manifest body is empty")
        remote_manifest_data = json.loads(manifest_body)
        validate_manifest(remote_manifest_data, args.channel)
        verify_manifest_signature(remote_manifest_data)
        if str(remote_manifest_data.get("sha256") or "").strip().lower() != local_installer_sha256:
            raise RuntimeError("published manifest sha256 does not match uploaded installer")
        if str(remote_manifest_data.get("channel") or "").strip().lower() != args.channel:
            raise RuntimeError("published manifest channel does not match requested channel")
    finally:
        try:
            sftp.close()
            client.close()
        except UnboundLocalError:
            pass
        release_publish_lock(lock_fd)


if __name__ == "__main__":
    main()
