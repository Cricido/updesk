# UpDesk Relay Compatibility

Questo progetto usa un layer di compatibilita` per far lavorare il client UpDesk/RustDesk `1.4.6`
con `hbbs/hbbr 1.1.15` dietro `nginx` su `443`, anche quando le porte standard sono bloccate lato client.

## Topologia attuale

- `wss://updesk.uptimeservice.it/ws/id` -> `127.0.0.1:21121`
- `wss://updesk.uptimeservice.it/ws/relay` -> `127.0.0.1:21129`
- `21116/tcp` -> NAT redirect a `21126`
- `21117/tcp` -> NAT redirect a `21127`

Componenti locali server:

- `server/ws_hbbs_bridge.py`
- `server/hbbs_tcp_proxy.py`
- `server/relay_pair_proxy.py`
- `server/updesk-bridge.service`
- `server/updesk-relay-pair.service`
- `server/updesk_nginx_patch.py`

Sorgenti upstream inclusi nel progetto:

- `third_party/updesk-server-1.1.15`
  - copia locale dei sorgenti `hbbs/hbbr` usati come riferimento compat

## Problemi risolti

1. Mismatch protobuf:
   - client `RequestRelay=18`, `RelayResponse=19`
   - hbbs vecchio `RequestRelay=9`, `RelayResponse=10`
2. Registrazione websocket compat:
   - `RegisterPk` / `RegisterPeer`
   - `OnlineRequest` / `OnlineResponse`
3. Pair relay websocket e TCP compat dietro `443`
4. Fallback legacy che ritornava `127.0.0.1:*`
   - il client ora ignora il direct TCP loopback e forza il relay pubblico

## Deploy server

Script stabile:

```powershell
python C:\Users\cri\Desktop\rustdesk-1.4.6\deploy_updesk_server.py
```

Lo script:

- pubblica `ws_hbbs_bridge.py`
- pubblica `hbbs_tcp_proxy.py`
- pubblica `relay_pair_proxy.py`
- pubblica gli unit file systemd dal repo
- aggiorna nginx websocket con `server/updesk_nginx_patch.py`
- abilita/riavvia `updesk-relay-pair`
- abilita/riavvia `updesk-bridge`
- rilancia il proxy TCP
- verifica redirect NAT `21116` e `21117`

## Deploy client locale

Dopo una build Rust, riallineare sempre la DLL installata:

```powershell
.\deploy_local_client.ps1
```

Questo evita di rilanciare il client con una DLL vecchia anche se la build nuova e` corretta.

## Build consigliata

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -Command "cd 'C:\Users\cri\Desktop\rustdesk-1.4.6'; cargo build --features flutter --lib --release"
```

Poi:

```powershell
.\deploy_local_client.ps1
```

## Log utili

Server:

```bash
journalctl -u updesk-bridge -f
journalctl -u updesk-relay-pair -f
tail -f /var/log/updesk-hbbs-tcp-proxy.log
```

Client locale:

- `%AppData%\UpDesk\log\uptimedesk_rCURRENT.log`

## Sintomo da evitare

Se ricompare:

```text
Failed to connect to 127.0.0.1:xxxxx
```

significa che il client sta usando una DLL vecchia oppure il ramo fallback loopback non e` quello patchato.
