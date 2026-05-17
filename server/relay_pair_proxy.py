#!/usr/bin/env python3
"""
relay_pair_proxy.py - minimal standalone relay pairer for UpDesk/RustDesk.

Purpose:
  - accept websocket relay connections on 127.0.0.1:21129
  - accept TCP relay connections on 0.0.0.0:21127
  - read the first RequestRelay message
  - pair both sides by uuid
  - forward subsequent bytes transparently in both directions

This avoids relying on hbbr 1.1.15 relay protocol compatibility while keeping:
  - nginx /ws/relay on 443
  - TCP fallback on port 21117 (via REDIRECT to 21127)
"""
import asyncio
import logging
import sys
import traceback
from dataclasses import dataclass, field

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

TCP_LISTEN_HOST = "0.0.0.0"
TCP_LISTEN_PORT = 21127
WS_LISTEN_HOST = "127.0.0.1"
WS_LISTEN_PORT = 21129
PAIR_TIMEOUT = 30

PENDING = {}
PENDING_LOCK = asyncio.Lock()


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


def _read_varint(buf: bytes, pos: int):
    result, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
    raise ValueError("truncated varint")


def _parse_outer(data: bytes):
    try:
        pos = 0
        tag_val, pos = _read_varint(data, pos)
        wire_type = tag_val & 0x7
        field_num = tag_val >> 3
        if wire_type != 2:
            return None
        length, pos = _read_varint(data, pos)
        payload = data[pos:pos + length]
        return field_num, payload
    except Exception as e:
        _log_exception("_parse_outer", e)
        return None


def _parse_inner_fields(payload: bytes) -> dict:
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


def _extract_uuid(msg: bytes) -> str:
    parsed = _parse_outer(msg)
    if not parsed:
        return ""
    _outer_field, payload = parsed
    inner = _parse_inner_fields(payload)
    uuid_bytes = inner.get(2, b"")
    if isinstance(uuid_bytes, bytes):
        return uuid_bytes.decode(errors="replace")
    return ""


def _extract_peer_id(msg: bytes) -> str:
    parsed = _parse_outer(msg)
    if not parsed:
        return ""
    _outer_field, payload = parsed
    inner = _parse_inner_fields(payload)
    peer_id = inner.get(1, b"")
    if isinstance(peer_id, bytes):
        return peer_id.decode(errors="replace")
    return ""


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


@dataclass
class RelayConn:
    kind: str
    peer: str
    ws: object | None = None
    reader: asyncio.StreamReader | None = None
    writer: asyncio.StreamWriter | None = None
    paired: asyncio.Event = field(default_factory=asyncio.Event)
    closed: asyncio.Event = field(default_factory=asyncio.Event)
    partner: "RelayConn | None" = None

    async def send(self, data: bytes):
        if self.kind == "ws":
            await self.ws.send(data)
        else:
            self.writer.write(data)
            await self.writer.drain()

    async def recv(self):
        if self.kind == "ws":
            msg = await self.ws.recv()
            if isinstance(msg, bytes):
                return msg
            return msg.encode()
        data = await self.reader.read(65536)
        if not data:
            raise EOFError("tcp peer closed")
        return data

    async def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        try:
            if self.kind == "ws":
                await self.ws.close()
            else:
                self.writer.close()
                await self.writer.wait_closed()
        except Exception as e:
            _log_exception("RelayConn.close", e)


async def _pair_or_wait(uuid: str, conn: RelayConn) -> bool:
    async with PENDING_LOCK:
        waiting = PENDING.pop(uuid, None)
        if waiting is None:
            PENDING[uuid] = conn
            logging.info("Relay waiting uuid=%s kind=%s peer=%s", uuid, conn.kind, conn.peer)
            return False
        waiting.partner = conn
        conn.partner = waiting
        waiting.paired.set()
        conn.paired.set()
        logging.info(
            "Relay paired uuid=%s %s<->%s",
            uuid,
            waiting.peer,
            conn.peer,
        )
        return True


async def _remove_pending(uuid: str, conn: RelayConn):
    async with PENDING_LOCK:
        if PENDING.get(uuid) is conn:
            PENDING.pop(uuid, None)


async def _pump(src: RelayConn, dst: RelayConn, label: str):
    try:
        while True:
            data = await src.recv()
            _frame_preview(data, label=label)
            await dst.send(data)
    except Exception as e:
        _log_exception(label, e)
    finally:
        await src.close()
        await dst.close()


async def _handle_after_pair(conn: RelayConn, uuid: str):
    try:
        await asyncio.wait_for(conn.paired.wait(), timeout=PAIR_TIMEOUT)
    except Exception as e:
        _log_exception(f"pair-timeout uuid={uuid}", e)
        await _remove_pending(uuid, conn)
        await conn.close()
        return
    partner = conn.partner
    if not partner:
        await conn.close()
        return
    if id(conn) < id(partner):
        asyncio.create_task(_pump(conn, partner, f"{conn.kind}->{partner.kind} uuid={uuid}"))
        asyncio.create_task(_pump(partner, conn, f"{partner.kind}->{conn.kind} uuid={uuid}"))
    await conn.closed.wait()


async def handle_ws(ws):
    peer = str(ws.remote_address)
    try:
        first = await ws.recv()
        data = first if isinstance(first, bytes) else first.encode()
        _frame_preview(data, label="WS-RELAY first")
        uuid = _extract_uuid(data)
        peer_id = _extract_peer_id(data)
        if not uuid:
            logging.error("WS relay missing uuid peer=%s peer_id=%s", peer, peer_id)
            await ws.close()
            return
        conn = RelayConn(kind="ws", peer=f"{peer}/{peer_id or '-'}", ws=ws)
        await _pair_or_wait(uuid, conn)
        await _handle_after_pair(conn, uuid)
    except Exception as e:
        _log_exception("handle_ws", e)
        try:
            await ws.close()
        except Exception as close_error:
            _log_exception("handle_ws.close", close_error)


async def handle_tcp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = str(writer.get_extra_info("peername"))
    try:
        first_payload = await _read_bc_frame(reader)
        _frame_preview(first_payload, label="TCP-RELAY first-payload")
        uuid = _extract_uuid(first_payload)
        peer_id = _extract_peer_id(first_payload)
        if not uuid:
            logging.error("TCP relay missing uuid peer=%s peer_id=%s", peer, peer_id)
            writer.close()
            await writer.wait_closed()
            return
        conn = RelayConn(kind="tcp", peer=f"{peer}/{peer_id or '-'}", reader=reader, writer=writer)
        await _pair_or_wait(uuid, conn)
        await _handle_after_pair(conn, uuid)
    except Exception as e:
        _log_exception("handle_tcp", e)
        try:
            writer.close()
            await writer.wait_closed()
        except Exception as close_error:
            _log_exception("handle_tcp.close", close_error)


async def main():
    try:
        ws_cm = ws_server.serve(handle_ws, WS_LISTEN_HOST, WS_LISTEN_PORT)
    except Exception as e:
        _log_exception("main.ws_server_serve", e)
        from websockets.server import serve as legacy_serve
        ws_cm = legacy_serve(handle_ws, WS_LISTEN_HOST, WS_LISTEN_PORT)

    tcp_server = await asyncio.start_server(handle_tcp, TCP_LISTEN_HOST, TCP_LISTEN_PORT)
    async with ws_cm, tcp_server:
        logging.info(
            "Relay pair proxy WS %s:%d and TCP %s:%d",
            WS_LISTEN_HOST, WS_LISTEN_PORT, TCP_LISTEN_HOST, TCP_LISTEN_PORT,
        )
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
