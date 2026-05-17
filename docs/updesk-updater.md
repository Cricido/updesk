# UpDesk Auto-Update

This document describes the current UpDesk updater flow for Windows and the
supporting publish pipeline for the `stable`, `recommended`, and `beta`
channels.

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
  "signature": "INSERIRE_FIRMA_ED25519_BASE64",
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

## Policy mapping

- `Disattivato`
  - `enable-check-update = N`
  - `allow-auto-update = N`
  - `update-channel = stable`
- `Canale stabile`
  - `enable-check-update = Y`
  - `allow-auto-update = N`
  - `update-channel = stable`
- `Aggiornamenti consigliati`
  - `enable-check-update = Y`
  - `allow-auto-update = Y`
  - `update-channel = recommended`
- `Canale beta`
  - `enable-check-update = Y`
  - `allow-auto-update = N`
  - `update-channel = beta`

## Update states

The updater publishes a simple state machine to the UI:

- `checking`
- `available`
- `downloading`
- `verifying`
- `ready`
- `preparing`
- `launching`
- `installer-launched`
- `deferred`
- `up-to-date`
- `failed`

`deferred` means the package is already downloaded and verified, but the
installation has been postponed because there are active remote sessions or
controlling connections.

## Manifest validation

The client accepts a manifest only if:

- `channel` matches the selected update channel
- `version` is present and formatted like `X.Y.Z`
- `url` is `https`
- `url` host is exactly `updesk.uptimeservice.it`
- `url` path is under `/releases/windows/`
- `sha256` is a 64-character hex string
- `signature` is a valid Ed25519 detached signature in base64
- `min_supported`, if present, uses the same simple version format

If `min_supported` is greater than the currently installed version, the update
is automatically treated as mandatory.

## Manifest signing

Update manifests are signed with Ed25519.

- Public key committed in repo:
  - `res/update_manifest_public_key.txt`
- Private key kept outside git:
  - `.secrets/updesk-update-sign-private.key`
- Signing tool:
  - `tools/update_manifest_sign.py`

Generate a keypair once:

```powershell
python .\tools\update_manifest_sign.py keygen --private .secrets\updesk-update-sign-private.key --public res\update_manifest_public_key.txt
```

Sign and verify a manifest manually:

```powershell
python .\tools\update_manifest_sign.py sign --private .secrets\updesk-update-sign-private.key --manifest .\stable.json
python .\tools\update_manifest_sign.py verify --public .\res\update_manifest_public_key.txt --manifest .\stable.json
```

## Logging

Useful log lines:

- `update check requested`
- `update check started`
- `update check finished`
- `update available`
- `update download attempt`
- `update download started`
- `update download completed`
- `update sha256 ok`
- `update install deferred`
- `failed to launch updater`
- `update installer launched`
- `updesk_updater.log` entries for installer/restart flow

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

Publish channels sequentially, not in parallel. All channels point to the same
installer path on the server and the publish script now enforces a local lock
to prevent overlapping uploads.

It will:

- validate the selected channel manifest locally
- validate the manifest signature locally
- validate that the manifest SHA256 matches the local installer
- upload the selected channel manifest
- upload `UptimeDesk-<version>-x86_64-Setup.exe`
- publish it as `/releases/windows/updesk-<version>.exe`
- verify the remote installer SHA256
- validate nginx
- reload nginx
- verify:
  - `/api/v1/update/<channel>.json`
  - `/releases/windows/updesk-<version>.exe`

Note:

- `/ws/id` and `/ws/relay` are not probed with `HEAD`, because they are
  websocket endpoints and that check would produce false negatives.
- Relay compatibility on `443` must remain untouched by updater publishing.

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

## Release generation

From the project root:

```powershell
.\release.ps1 -Version "1.0.3" -Notes "Build stabile" -Channel stable
.\release.ps1 -Version "1.0.4" -Notes "Build consigliata" -Channel recommended
.\release.ps1 -Version "1.0.5" -Notes "Build beta" -Channel beta
```

The release script:

- validates the version format
- updates version files in Rust, Flutter, and Inno Setup
- builds the Rust library and `updesk_updater.exe`
- builds Flutter Windows
- builds the installers
- computes SHA256
- signs `stable.json` and the selected channel manifest
- verifies manifest signatures before completing
- writes:
  - `stable.json`
  - `<channel>.json`
  - `version.json`
  - `version-assistenza.json`

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
