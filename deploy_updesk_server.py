from pathlib import Path
import posixpath
import paramiko


HOST = "updesk.uptimeservice.it"
PORT = 22
USERNAME = "uptime"
PASSWORD = "Memento@2017"

ROOT = Path(__file__).resolve().parent
REMOTE_ROOT = "/opt/updesk-bridge"
LOCAL_FILES = {
    ROOT / "server" / "ws_hbbs_bridge.py": f"{REMOTE_ROOT}/ws_hbbs_bridge.py",
    ROOT / "server" / "hbbs_tcp_proxy.py": f"{REMOTE_ROOT}/hbbs_tcp_proxy.py",
    ROOT / "server" / "relay_pair_proxy.py": f"{REMOTE_ROOT}/relay_pair_proxy.py",
    ROOT / "server" / "updesk_nginx_patch.py": f"{REMOTE_ROOT}/updesk_nginx_patch.py",
}
LOCAL_SERVICE_FILES = {
    ROOT / "server" / "updesk-bridge.service": "/etc/systemd/system/updesk-bridge.service",
    ROOT / "server" / "updesk-relay-pair.service": "/etc/systemd/system/updesk-relay-pair.service",
}


def run(client, cmd):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def main():
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
        run(client, f"echo 'Memento@2017' | sudo -S mkdir -p {REMOTE_ROOT}")
        for local_path, remote_path in LOCAL_FILES.items():
            tmp_remote = posixpath.join("/home/uptime", posixpath.basename(remote_path) + ".tmp")
            sftp.put(str(local_path), tmp_remote)
            run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_remote} {remote_path}")
            run(client, f"echo 'Memento@2017' | sudo -S chown root:root {remote_path}")
            run(client, f"echo 'Memento@2017' | sudo -S chmod 755 {remote_path}")
        for local_path, remote_path in LOCAL_SERVICE_FILES.items():
            tmp_remote = posixpath.join("/home/uptime", posixpath.basename(remote_path) + ".tmp")
            sftp.put(str(local_path), tmp_remote)
            run(client, f"echo 'Memento@2017' | sudo -S mv {tmp_remote} {remote_path}")
            run(client, f"echo 'Memento@2017' | sudo -S chown root:root {remote_path}")
            run(client, f"echo 'Memento@2017' | sudo -S chmod 644 {remote_path}")

        run(client, "echo 'Memento@2017' | sudo -S python3 /opt/updesk-bridge/updesk_nginx_patch.py")
        run(client, "echo 'Memento@2017' | sudo -S systemctl daemon-reload")
        run(client, "echo 'Memento@2017' | sudo -S systemctl enable updesk-bridge")
        run(client, "echo 'Memento@2017' | sudo -S systemctl unmask updesk-relay-pair || true")
        run(client, "echo 'Memento@2017' | sudo -S systemctl enable updesk-relay-pair")

        run(client, "echo 'Memento@2017' | sudo -S systemctl restart updesk-bridge")
        run(client, "echo 'Memento@2017' | sudo -S systemctl restart updesk-relay-pair")
        run(client, "echo 'Memento@2017' | sudo -S pkill -f /opt/updesk-bridge/hbbs_tcp_proxy.py || true")
        run(client, "echo 'Memento@2017' | sudo -S bash -lc 'nohup python3 /opt/updesk-bridge/hbbs_tcp_proxy.py >/var/log/updesk-hbbs-tcp-proxy.log 2>&1 &'")
        run(client, "echo 'Memento@2017' | sudo -S iptables -t nat -C PREROUTING -p tcp --dport 21116 -j REDIRECT --to-ports 21126 || echo 'Memento@2017' | sudo -S iptables -t nat -A PREROUTING -p tcp --dport 21116 -j REDIRECT --to-ports 21126")
        run(client, "echo 'Memento@2017' | sudo -S iptables -t nat -C PREROUTING -p tcp --dport 21117 -j REDIRECT --to-ports 21127 || echo 'Memento@2017' | sudo -S iptables -t nat -A PREROUTING -p tcp --dport 21117 -j REDIRECT --to-ports 21127")
        run(client, "echo 'Memento@2017' | sudo -S nginx -t")
        run(client, "echo 'Memento@2017' | sudo -S systemctl reload nginx")

        checks = {
            "bridge_status": "systemctl status updesk-bridge --no-pager -l || true",
            "relay_pair_status": "systemctl status updesk-relay-pair --no-pager -l || true",
            "ss": "ss -tlnp | grep -E '21121|21126|21127|21129|21116|21117|21119|21118' || true",
            "nginx_ws": "grep -n \"location /ws/id\\|location /ws/relay\\|proxy_buffering off\\|proxy_read_timeout\\|proxy_send_timeout\" /etc/nginx/sites-enabled/updesk-static || true",
            "bridge_log_tail": "journalctl -u updesk-bridge -n 50 --no-pager || true",
            "relay_pair_log_tail": "journalctl -u updesk-relay-pair -n 50 --no-pager || true",
            "tcp_proxy_log_tail": "tail -n 50 /var/log/updesk-hbbs-tcp-proxy.log 2>/dev/null || true",
        }
        for name, cmd in checks.items():
            code, out, err = run(client, cmd)
            print(f"=== {name} code={code} ===")
            if out:
                print(out.strip().encode("ascii", errors="backslashreplace").decode("ascii"))
            if err:
                print("--- STDERR ---")
                print(err.strip().encode("ascii", errors="backslashreplace").decode("ascii"))
            print()
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
