# UpDesk Auto-Update v1

This document describes the first minimal and safe auto-update flow for UpDesk.

## URLs

- Relay rendezvous: `https://updesk.uptimeservice.it/ws/id`
- Relay websocket: `https://updesk.uptimeservice.it/ws/relay`
- Update manifests:
  - `https://updesk.uptimeservice.it/api/v1/update/stable.json`
  - `https://updesk.uptimeservice.it/api/v1/update/recommended.json`
  - `https://updesk.uptimeservice.it/api/v1/update/beta.json`
- Windows release download: `https://updesk.uptimeservice.it/releases/windows/updesk-<version>.exe`

## Manifest format

```json
{
  "channel": "stable",
  "version": "1.0.2",
  "url": "https://updesk.uptimeservice.it/releases/windows/updesk-1.0.2.exe",
  "sha256": "INSERIRE_HASH_REALE",
  "mandatory": false,
  "min_supported": "1.0.0",
  "changelog": "Bug fix e miglioramenti stabilita"
}
```

## Client flow

1. UpDesk checks the manifest for the selected channel.
2. If `version > local_version`, the client stores the manifest and exposes update UI.
3. The installer is downloaded to:
   - `%TEMP%\updesk-update\updesk-<version>.exe`
4. SHA256 is verified against the manifest.
5. If verification succeeds, `updesk_updater.exe` is launched.
6. `updesk_updater.exe` waits for the current UpDesk process to exit, launches the downloaded installer, and then tries to restart UpDesk.

## Logging

Useful log lines:

- `update check started`
- `update check finished`
- `update available`
- `update download started`
- `update download completed`
- `update sha256 ok`
- `failed to launch updater`

## Server layout

```text
/var/www/updesk/api/v1/update/stable.json
/var/www/updesk/api/v1/update/recommended.json
/var/www/updesk/api/v1/update/beta.json
/var/www/updesk/releases/windows/updesk-1.0.2.exe
```

## Publish commands

```bash
sudo mkdir -p /var/www/updesk/api/v1/update
sudo mkdir -p /var/www/updesk/releases/windows
sudo cp stable.json /var/www/updesk/api/v1/update/stable.json
sudo cp recommended.json /var/www/updesk/api/v1/update/recommended.json
sudo cp beta.json /var/www/updesk/api/v1/update/beta.json
sudo cp UptimeDesk-1.0.2-x86_64-Setup.exe /var/www/updesk/releases/windows/updesk-1.0.2.exe
sudo chown -R www-data:www-data /var/www/updesk
sudo find /var/www/updesk -type d -exec chmod 755 {} \;
sudo find /var/www/updesk -type f -exec chmod 644 {} \;
```

## Automated publish

From the project root:

```powershell
python .\deploy_updesk_update_assets.py --channel stable
python .\deploy_updesk_update_assets.py --channel recommended
python .\deploy_updesk_update_assets.py --channel beta
```

It will:

- upload the selected channel manifest
- upload `UptimeDesk-<version>-x86_64-Setup.exe`
- publish it as `/releases/windows/updesk-<version>.exe`
- validate nginx
- reload nginx
- verify:
  - `/api/v1/update/<channel>.json`
  - `/releases/windows/updesk-<version>.exe`
  - `/ws/id`
  - `/ws/relay`

## Channels

- `stable`
  - manual checks enabled
  - no automatic install
- `recommended`
  - preferred production channel
  - can be combined with automatic install policy
- `beta`
  - test channel
  - never recommended for silent rollout

## Nginx

Use `server/updesk-nginx-update.conf.example` as the base layout.

Important:

- Do not modify `/ws/id` behavior.
- Do not modify `/ws/relay` behavior.
- Keep:
  - `proxy_http_version 1.1`
  - `Upgrade`
  - `Connection upgrade`
  - `proxy_read_timeout`
  - `proxy_buffering off`
