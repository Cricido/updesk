#!/usr/bin/env python3
"""
ws_hbbs_bridge.py - UptimeDesk WebSocket-to-WebSocket bridge for hbbs rendezvous.

hbbs 1.1.15 already exposes a native websocket endpoint on port 21118.
The remaining compatibility problem is protobuf field numbering:
  - Client 1.4.6 uses new proto (RequestRelay=field18, RelayResponse=field19)
  - hbbs 1.1.15 uses old proto (RequestRelay=field9,  RelayResponse=field10)

This bridge keeps the websocket transport intact and only translates the
protobuf outer field numbers transparently between the client and hbbs.

Deploy on server, configure nginx /ws/id to proxy to this port (21121).
"""
import asyncio
import logging
import sys
import traceback
from uuid import uuid4

try:
    import websockets
    import websockets.asyncio.server as ws_server
except ImportError:
    try:
        from websockets.server import serve as _serve
        ws_server = None
    except ImportError:
        print("ERROR: pip3 install websockets", file=sys.stderr)
        sys.exit(1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 21121
HBBS_WS_URL = "ws://127.0.0.1:21118"
HBBS_TCP_HOST = "127.0.0.1"
HBBS_TCP_PORT = 21116
PUBLIC_RELAY_SERVER = "updesk.uptimeservice.it"

PEER_REGISTRY = {}
PEER_REGISTRY_LOCK = asyncio.Lock()
LOCAL_RELAY_UUIDS = set()
LOCAL_RELAY_UUIDS_LOCK = asyncio.Lock()
LOCAL_RELAY_ROUTES = {}
LOCAL_RELAY_ROUTES_LOCK = asyncio.Lock()


def _log_exception(context: str, e: Exception):
    logging.error("ERROR [%s]: %s", context, e)
    logging.error(traceback.format_exc())


def _frame_preview(data, *, label: str):
    if isinstance(data, bytes):
        preview = data[:64].hex()
        logging.debug("%s type=%s len=%d hex64=%s", label, type(data).__name__, len(data), preview)
    else:
        text = str(data)
        logging.debug("%s type=%s len=%d text200=%r", label, type(data).__name__, len(text), text[:200])


# ── minimal protobuf helpers ──────────────────────────────────────────────────

def _varint(n):
    out = []
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _read_varint(buf, pos):
    result, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
    raise ValueError("truncated varint")


def _pb_len_field(field_number, payload):
    tag = _varint((field_number << 3) | 2)
    return tag + _varint(len(payload)) + payload


def _pb_string(field_number, s):
    return _pb_len_field(field_number, s.encode())


def _pb_bool(field_number, val):
    return _varint((field_number << 3) | 0) + _varint(1 if val else 0)


def _pb_int(field_number, val: int):
    return _varint((field_number << 3) | 0) + _varint(val)


def _bc_encode(data: bytes) -> bytes:
    n = len(data)
    if n < 0x40:
        return bytes([n << 2]) + data
    if n < 0x4000:
        return bytes([((n & 0x3F) << 2) | 1, n >> 6]) + data
    if n < 0x400000:
        h = ((n << 2) | 0x2).to_bytes(4, "little")[:3]
        return h + data
    h = ((n << 2) | 0x3).to_bytes(4, "little")
    return h + data


async def _read_bc_frame(reader: asyncio.StreamReader) -> bytes:
    first = await reader.readexactly(1)
    b = first[0]
    tag = b & 0x3
    if tag == 0:
        n = b >> 2
    elif tag == 1:
        second = await reader.readexactly(1)
        n = (b >> 2) | (second[0] << 6)
    else:
        rest = await reader.readexactly(3)
        n = int.from_bytes(bytes([b]) + rest, "little") >> 2
    return await reader.readexactly(n)


async def _proxy_tcp_rendezvous_once(data: bytes, *, label: str) -> bytes | None:
    reader = None
    writer = None
    try:
        reader, writer = await asyncio.open_connection(HBBS_TCP_HOST, HBBS_TCP_PORT)
        _frame_preview(data, label=f"{label}(to-hbbs-tcp)")
        writer.write(_bc_encode(data))
        await writer.drain()
        response = await asyncio.wait_for(_read_bc_frame(reader), timeout=8)
        _frame_preview(response, label=f"{label}(from-hbbs-tcp)")
        return response
    except Exception as e:
        _log_exception(label, e)
        return None
    finally:
        if writer is not None:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception as e:
                _log_exception(f"{label}.writer.close", e)


def _parse_outer(data: bytes):
    """Return (field_num, payload_bytes) for the first outer LEN field, or None."""
    try:
        pos = 0
        tag_val, pos = _read_varint(data, pos)
        wire_type = tag_val & 0x7
        field_num = tag_val >> 3
        if wire_type != 2:
            return None
        length, pos = _read_varint(data, pos)
        payload = data[pos:pos + length]
        return (field_num, payload)
    except Exception as e:
        _log_exception("_parse_outer", e)
        return None


def _parse_inner_fields(payload: bytes) -> dict:
    """Parse inner protobuf fields: {field_num: bytes_or_int}."""
    result = {}
    pos = 0
    while pos < len(payload):
        try:
            tag_val, pos = _read_varint(payload, pos)
            wire_type = tag_val & 0x7
            field_num = tag_val >> 3
            if wire_type == 2:
                length, pos = _read_varint(payload, pos)
                result[field_num] = payload[pos:pos + length]
                pos += length
            elif wire_type == 0:
                val, pos = _read_varint(payload, pos)
                result[field_num] = val
            else:
                break
        except Exception as e:
            _log_exception("_parse_inner_fields", e)
            break
    return result


def _parse_fields(payload: bytes) -> list[tuple[int, int, object]]:
    """Parse protobuf fields preserving repeats."""
    result = []
    pos = 0
    while pos < len(payload):
        try:
            tag_val, pos = _read_varint(payload, pos)
            wire_type = tag_val & 0x7
            field_num = tag_val >> 3
            if wire_type == 2:
                length, pos = _read_varint(payload, pos)
                value = payload[pos:pos + length]
                pos += length
            elif wire_type == 0:
                value, pos = _read_varint(payload, pos)
            else:
                break
            result.append((field_num, wire_type, value))
        except Exception as e:
            _log_exception("_parse_fields", e)
            break
    return result


def _pack_online_states(peers: list[str], online_peers: set[str]) -> bytes:
    if not peers:
        return b""
    states = bytearray((len(peers) + 7) // 8)
    for i, peer_id in enumerate(peers):
        if peer_id in online_peers:
            states[i // 8] |= 0x01 << (7 - (i % 8))
    return bytes(states)


async def _register_peer(peer_id: str, ws, peer):
    if not peer_id:
        return
    async with PEER_REGISTRY_LOCK:
        PEER_REGISTRY[peer_id] = {"ws": ws, "peer": peer}
    logging.info("Peer online via WS bridge: id=%s peer=%s", peer_id, peer)


async def _unregister_peers(peer_ids: set[str], ws):
    if not peer_ids:
        return
    async with PEER_REGISTRY_LOCK:
        for peer_id in list(peer_ids):
            entry = PEER_REGISTRY.get(peer_id)
            if entry and entry.get("ws") is ws:
                PEER_REGISTRY.pop(peer_id, None)
                logging.info("Peer offline via WS bridge: id=%s", peer_id)


async def _get_online_peers() -> set[str]:
    async with PEER_REGISTRY_LOCK:
        return set(PEER_REGISTRY.keys())


async def _get_peer_entry(peer_id: str):
    async with PEER_REGISTRY_LOCK:
        return PEER_REGISTRY.get(peer_id)


async def _remember_local_relay_uuid(relay_uuid: str):
    async with LOCAL_RELAY_UUIDS_LOCK:
        LOCAL_RELAY_UUIDS.add(relay_uuid)


async def _is_local_relay_uuid(relay_uuid: str) -> bool:
    async with LOCAL_RELAY_UUIDS_LOCK:
        return relay_uuid in LOCAL_RELAY_UUIDS


async def _remember_local_relay_route(relay_uuid: str, initiator_ws, target_ws):
    async with LOCAL_RELAY_ROUTES_LOCK:
        LOCAL_RELAY_ROUTES[relay_uuid] = {
            "initiator_ws": initiator_ws,
            "target_ws": target_ws,
        }


async def _find_local_relay_route_for_ws(ws):
    async with LOCAL_RELAY_ROUTES_LOCK:
        for relay_uuid, route in LOCAL_RELAY_ROUTES.items():
            if route.get("initiator_ws") is ws or route.get("target_ws") is ws:
                return relay_uuid, route
    return None, None


async def _drop_local_relay_routes_for_ws(ws):
    async with LOCAL_RELAY_ROUTES_LOCK:
        stale = [
            relay_uuid
            for relay_uuid, route in LOCAL_RELAY_ROUTES.items()
            if route.get("initiator_ws") is ws or route.get("target_ws") is ws
        ]
        for relay_uuid in stale:
            LOCAL_RELAY_ROUTES.pop(relay_uuid, None)


async def _start_local_relay_pair(ws, source_id: str, target_id: str, relay_uuid: str, relay_server: str):
    target_entry = await _get_peer_entry(target_id)
    if not target_entry or target_entry.get("ws") is ws:
        return None
    relay_server = relay_server or PUBLIC_RELAY_SERVER
    await _remember_local_relay_uuid(relay_uuid)
    logging.info(
        "Local compat Relay pair: from=%s to=%s uuid=%s relay=%s",
        source_id,
        target_id,
        relay_uuid,
        relay_server,
    )
    target_ws = target_entry["ws"]
    request_relay_inner = (
        _pb_len_field(1, source_id.encode()) +
        _pb_string(2, relay_uuid) +
        _pb_len_field(3, b"") +
        _pb_string(4, relay_server) +
        _pb_bool(5, False)
    )
    request_relay_msg = _pb_len_field(18, request_relay_inner)
    _frame_preview(request_relay_msg, label="BRIDGE->WS(target-request-relay)")
    await target_ws.send(request_relay_msg)
    await _remember_local_relay_route(relay_uuid, ws, target_ws)

    relay_response_inner = (
        _pb_len_field(1, b"") +
        _pb_string(2, relay_uuid) +
        _pb_string(3, relay_server)
    )
    return _pb_len_field(19, relay_response_inner)


async def handle_local_compat(data: bytes, ws, peer, bound_peer_ids: set[str]) -> bytes | None:
    """
    Keep 1.4.6 clients connected against hbbs 1.1.15 websocket rendezvous.

    hbbs 1.1.15 answers RegisterPk with NOT_SUPPORT and then closes before the
    client can execute its fallback. We intercept the registration round-trip
    locally so the websocket session stays alive long enough for subsequent
    rendezvous traffic.
    """
    parsed = _parse_outer(data)
    if not parsed:
        return None
    outer_field, payload = parsed
    inner = _parse_inner_fields(payload)

    if outer_field == 15:
        peer_id = inner.get(1, b"").decode(errors="replace")
        await _register_peer(peer_id, ws, peer)
        bound_peer_ids.add(peer_id)
        logging.info("Local compat RegisterPk→RegisterPkResponse(OK): id=%s", peer_id)
        resp_inner = _pb_int(1, 0) + _pb_int(2, 12)
        return _pb_len_field(16, resp_inner)

    if outer_field == 6:
        peer_id = inner.get(1, b"").decode(errors="replace")
        await _register_peer(peer_id, ws, peer)
        bound_peer_ids.add(peer_id)
        logging.info("Local compat RegisterPeer→RegisterPeerResponse: id=%s", peer_id)
        resp_inner = _pb_bool(2, False)
        return _pb_len_field(7, resp_inner)

    if outer_field == 23:
        fields = _parse_fields(payload)
        peers = [
            value.decode(errors="replace")
            for field_num, wire_type, value in fields
            if field_num == 2 and wire_type == 2 and isinstance(value, bytes)
        ]
        online_peers = await _get_online_peers()
        states = _pack_online_states(peers, online_peers)
        logging.info("Local compat OnlineRequest→OnlineResponse: peers=%s online=%s", peers, sorted(online_peers))
        return _pb_len_field(24, _pb_len_field(1, states))

    if outer_field == 8:
        target_id = inner.get(1, b"").decode(errors="replace")
        source_id = next(iter(bound_peer_ids), "")
        relay_uuid = str(uuid4())
        resp = await _start_local_relay_pair(ws, source_id, target_id, relay_uuid, PUBLIC_RELAY_SERVER)
        if resp is not None:
            logging.info("Local compat PunchHoleRequest→Relay pair: from=%s to=%s uuid=%s", source_id, target_id, relay_uuid)
            return resp

    if outer_field == 18:
        target_id = inner.get(1, b"").decode(errors="replace")
        relay_uuid = inner.get(2, b"").decode(errors="replace") or str(uuid4())
        relay_server = inner.get(4, b"").decode(errors="replace") if isinstance(inner.get(4, b""), bytes) else ""
        source_id = next(iter(bound_peer_ids), "")
        resp = await _start_local_relay_pair(ws, source_id, target_id, relay_uuid, relay_server)
        if resp is not None:
            logging.info("Local compat RequestRelay→Relay pair: from=%s to=%s uuid=%s relay=%s", source_id, target_id, relay_uuid, relay_server or PUBLIC_RELAY_SERVER)
            return resp

    return None


# ── proto translation ─────────────────────────────────────────────────────────
#
# RendezvousMessage field numbers:
#   old hbbs 1.1.15:  RequestRelay = 9,  RelayResponse = 10
#   new client 1.4.6: RequestRelay = 18, RelayResponse = 19
#
# RequestRelay inner (new proto sent by connecting PC):
#   field 1 = id (string)         → target peer id
#   field 2 = uuid (string)       ← SKIP in old proto
#   field 3 = socket_addr (bytes) ← SKIP in old proto request
#   field 4 = relay_server (string)
#   field 5 = secure (bool)
#
# RequestRelay inner (old proto for hbbs):
#   field 1 = id (string)          ← same field, same value
#   field 2 = relay_server (string) ← mapped from new field 4
#   field 3 = secure (bool)         ← mapped from new field 5
#
# RelayResponse inner: same field numbers in both old and new proto.
#   field 1 = socket_addr (bytes)
#   field 2 = uuid (string)
#   field 3 = relay_server (string)
# Only the outer field number differs (10 vs 19).


def translate_client_to_hbbs(data: bytes) -> bytes:
    """Translate new-proto messages from WS client to old-proto for hbbs."""
    parsed = _parse_outer(data)
    if not parsed:
        return data
    outer_field, payload = parsed

    if outer_field == 18:
        # RequestRelay new proto (field 18) → old proto (field 9)
        inner = _parse_inner_fields(payload)
        id_bytes = inner.get(1, b'')
        relay_server_bytes = inner.get(4, b'')
        secure = inner.get(5, 0)

        target_id = id_bytes.decode(errors='replace') if id_bytes else ''
        relay_server = relay_server_bytes.decode(errors='replace') if relay_server_bytes else ''

        logging.debug("Translate RequestRelay f18→f9: target=%s relay=%s", target_id, relay_server)

        old_inner = (
            _pb_len_field(1, id_bytes) +        # field 1: id (string bytes)
            _pb_string(2, relay_server) +        # field 2: relay_server
            _pb_bool(3, bool(secure))            # field 3: secure
        )
        return _pb_len_field(9, old_inner)

    if outer_field == 19:
        # RelayResponse new proto (field 19) → old proto (field 10)
        # Inner fields are identical; just change outer field number.
        logging.debug("Translate RelayResponse f19→f10 (%d bytes inner)", len(payload))
        return _pb_len_field(10, payload)

    return data


def translate_hbbs_to_client(data: bytes) -> bytes:
    """Translate old-proto messages from hbbs to new-proto for WS client."""
    parsed = _parse_outer(data)
    if not parsed:
        return data
    outer_field, payload = parsed

    if outer_field == 10:
        # RelayResponse old proto (field 10) → new proto (field 19)
        # Inner fields are identical; just change outer field number.
        inner = _parse_inner_fields(payload)
        uuid_bytes = inner.get(2, b'')
        relay_bytes = inner.get(3, b'')
        logging.debug(
            "Translate RelayResponse f10→f19: uuid=%s relay=%s",
            uuid_bytes[:20].decode(errors='replace'),
            relay_bytes.decode(errors='replace'),
        )
        return _pb_len_field(19, payload)

    # Field 9 is legacy RequestRelay. We keep it unchanged on purpose:
    # client 1.4.6 interprets it as PunchHole and still reaches create_relay().
    return data


# ── bridge handler ────────────────────────────────────────────────────────────

async def handle(ws):
    peer = ws.remote_address
    logging.info("Connect from %s", peer)
    hbbs_ws = None
    hbbs_reader_task = None
    bound_peer_ids = set()
    cached_register_pk = None
    cached_register_peer = None

    async def ensure_hbbs_ws():
        nonlocal hbbs_ws, hbbs_reader_task
        if hbbs_ws is None:
            hbbs_ws = await websockets.connect(
                HBBS_WS_URL,
                open_timeout=10,
                close_timeout=5,
                ping_interval=None,
            )
            logging.info("Connected upstream hbbs websocket %s for %s", HBBS_WS_URL, peer)
        if hbbs_reader_task is None or hbbs_reader_task.done():
            hbbs_reader_task = asyncio.create_task(from_hbbs_to_ws())

    async def from_ws_to_hbbs():
        nonlocal cached_register_pk, cached_register_peer
        logging.info("from_ws_to_hbbs start peer=%s", peer)
        try:
            async for msg in ws:
                _frame_preview(msg, label="WS->BRIDGE")
                data = msg if isinstance(msg, bytes) else msg.encode()
                parsed = _parse_outer(data)
                outer_field = parsed[0] if parsed else None
                local_resp = await handle_local_compat(data, ws, peer, bound_peer_ids)
                if local_resp is not None:
                    _frame_preview(local_resp, label="BRIDGE->WS(local-compat)")
                    await ws.send(local_resp)
                    # Keep a real legacy hbbs rendezvous session alive for WS peers.
                    # Local compat keeps the modern 1.4.6 client happy; shadowing
                    # RegisterPeer upstream lets hbbs know this peer when outbound
                    # RequestRelay must reach legacy/non-WS peers.
                    if outer_field == 15:
                        cached_register_pk = data
                    elif outer_field == 6:
                        cached_register_peer = data
                    continue
                if parsed:
                    _outer_field, payload = parsed
                    if outer_field in (8, 18):
                        tcp_response = await _proxy_tcp_rendezvous_once(
                            data,
                            label=f"BRIDGE<->HBBS-TCP outer={outer_field}",
                        )
                        if tcp_response is not None:
                            await ws.send(tcp_response)
                            continue
                    if outer_field == 19:
                        inner = _parse_inner_fields(payload)
                        relay_uuid = inner.get(2, b"").decode(errors="replace")
                        if relay_uuid and await _is_local_relay_uuid(relay_uuid):
                            logging.info("Swallow local RelayResponse uuid=%s from peer=%s", relay_uuid, peer)
                            continue
                        local_route_uuid, local_route = await _find_local_relay_route_for_ws(ws)
                        if local_route_uuid and local_route:
                            if local_route.get("target_ws") is ws:
                                counterpart = local_route.get("initiator_ws")
                            elif local_route.get("initiator_ws") is ws:
                                counterpart = local_route.get("target_ws")
                            else:
                                counterpart = None
                            if counterpart is not None:
                                logging.info(
                                    "Forward local RelayResponse over WS pair uuid=%s peer=%s",
                                    local_route_uuid,
                                    peer,
                                )
                                _frame_preview(data, label="BRIDGE->WS(local-relay-forward)")
                                await counterpart.send(data)
                                continue
                    if outer_field == 18:
                        await ensure_hbbs_ws()
                        if cached_register_pk is not None:
                            shadow_pk = translate_client_to_hbbs(cached_register_pk)
                            _frame_preview(shadow_pk, label="BRIDGE->HBBS-WS(registerpk-on-demand)")
                            await hbbs_ws.send(shadow_pk)
                        if cached_register_peer is not None:
                            shadow_peer = translate_client_to_hbbs(cached_register_peer)
                            _frame_preview(shadow_peer, label="BRIDGE->HBBS-WS(registerpeer-on-demand)")
                            await hbbs_ws.send(shadow_peer)
                        translated = translate_client_to_hbbs(data)
                        _frame_preview(translated, label="BRIDGE->HBBS-WS(request-relay)")
                        await hbbs_ws.send(translated)
                        continue
                await ensure_hbbs_ws()
                translated = translate_client_to_hbbs(data)
                _frame_preview(translated, label="BRIDGE->HBBS-WS")
                await hbbs_ws.send(translated)
            logging.info("from_ws_to_hbbs ended cleanly peer=%s", peer)
        except Exception as e:
            _log_exception("from_ws_to_hbbs", e)

    async def from_hbbs_to_ws():
        nonlocal hbbs_ws
        logging.info("from_hbbs_to_ws start peer=%s", peer)
        try:
            async for msg in hbbs_ws:
                _frame_preview(msg, label="HBBS-WS->BRIDGE")
                data = msg if isinstance(msg, bytes) else msg.encode()
                parsed = _parse_outer(data)
                if parsed:
                    outer_field, _payload = parsed
                    if outer_field in (7, 16):
                        logging.info("Swallow hbbs compat response field=%s for peer=%s", outer_field, peer)
                        continue
                translated = translate_hbbs_to_client(data)
                _frame_preview(translated, label="BRIDGE->WS")
                await ws.send(translated)
            logging.info("from_hbbs_to_ws ended cleanly peer=%s", peer)
        except Exception as e:
            _log_exception("from_hbbs_to_ws", e)
        finally:
            hbbs_ws = None

    t1 = asyncio.ensure_future(from_ws_to_hbbs())
    try:
        await t1
        try:
            exc = t1.exception()
        except asyncio.CancelledError:
            exc = None
        if exc:
            _log_exception("handle.wait.client_task", exc)
        else:
            logging.info("handle.wait.client_task peer=%s finished_without_exception", peer)
    finally:
        if hbbs_reader_task is not None:
            hbbs_reader_task.cancel()
        await _unregister_peers(bound_peer_ids, ws)
        await _drop_local_relay_routes_for_ws(ws)
    try:
        if hbbs_ws is not None:
            await hbbs_ws.close()
    except Exception as e:
        _log_exception("hbbs_ws.close", e)
    logging.info("Closed %s", peer)


# ── main ──────────────────────────────────────────────────────────────────────

async def main():
    try:
        # websockets >= 14 (asyncio API)
        async with ws_server.serve(handle, LISTEN_HOST, LISTEN_PORT):
            logging.info(
                "Bridge WS %s:%d ↔ hbbs WS %s",
                LISTEN_HOST, LISTEN_PORT, HBBS_WS_URL,
            )
            await asyncio.Future()
    except Exception as e:
        _log_exception("main.serve_asyncio_api", e)
        # fallback for older websockets
        from websockets.server import serve
        async with serve(handle, LISTEN_HOST, LISTEN_PORT):
            logging.info(
                "Bridge WS %s:%d ↔ hbbs WS %s",
                LISTEN_HOST, LISTEN_PORT, HBBS_WS_URL,
            )
            await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
