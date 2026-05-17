#!/usr/bin/env python3
"""
hbbs_tcp_proxy.py - TCP proto-translation proxy for hbbs 1.1.15.

hbbs 1.1.15 uses OLD proto field numbers:
  RequestRelay = field 9  (client 1.4.6 sends field 18)
  RelayResponse = field 10 (client 1.4.6 sends/expects field 19)

This proxy sits between external TCP clients and hbbs TCP 21116.
It translates field numbers transparently so relay works with client 1.4.6.

Deploy:
  1. Run this proxy on port 21126 (or any free port).
  2. Redirect external TCP 21116 to 21126:
       sudo iptables -t nat -A PREROUTING -p tcp --dport 21116 -j REDIRECT --to-port 21126
  3. To make persistent:
       sudo apt install iptables-persistent
       sudo netfilter-persistent save

Layout:
  External client TCP → iptables → :21126 (this proxy) → hbbs localhost:21116 TCP
  External client UDP → hbbs :21116 UDP directly (UDP unaffected by iptables REDIRECT)
"""
import asyncio
import logging
import struct
import sys
import traceback

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 21126
HBBS_HOST = "127.0.0.1"
HBBS_PORT = 21116   # hbbs internal TCP port


def _log_exception(context: str, e: Exception):
    logging.error("ERROR [%s]: %s", context, e)
    logging.error(traceback.format_exc())


def _frame_preview(data: bytes, *, label: str):
    preview = data[:64].hex()
    logging.debug("%s type=%s len=%d hex64=%s", label, type(data).__name__, len(data), preview)


# ── bc_encode framing ─────────────────────────────────────────────────────────
# Each message is: [length_prefix][protobuf_bytes]
# length_prefix encoding:
#   1 byte  if len < 64:     (len << 2) | 0
#   2 bytes if len < 16384:  [(len & 0x3F) << 2 | 1, len >> 6]
#   4 bytes if len >= 16384: struct.pack('<I', len << 2 | 2)

def bc_encode(data: bytes) -> bytes:
    n = len(data)
    if n < 0x40:
        return bytes([n << 2]) + data
    elif n < 0x4000:
        return bytes([(n & 0x3F) << 2 | 1, n >> 6]) + data
    else:
        return struct.pack('<I', (n << 2) | 2) + data


async def read_bc_frame(reader: asyncio.StreamReader) -> bytes:
    """Read one bc-encoded frame. Returns raw proto bytes (no length prefix)."""
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
        n = struct.unpack('<I', bytes([b]) + rest)[0] >> 2
    return await reader.readexactly(n)


# ── minimal protobuf helpers ──────────────────────────────────────────────────

def _varint(n: int) -> bytes:
    out = []
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _read_varint(buf: bytes, pos: int):
    result, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
    raise ValueError("truncated varint")


def _pb_len_field(field_number: int, payload: bytes) -> bytes:
    tag = _varint((field_number << 3) | 2)
    return tag + _varint(len(payload)) + payload


def _pb_string(field_number: int, s: str) -> bytes:
    return _pb_len_field(field_number, s.encode())


def _pb_bool(field_number: int, val: bool) -> bytes:
    return _varint((field_number << 3) | 0) + _varint(1 if val else 0)


def _parse_outer(data: bytes):
    """Return (field_num, payload) for the first outer LEN field, or None."""
    try:
        tag_val, pos = _read_varint(data, 0)
        if (tag_val & 0x7) != 2:
            return None
        field_num = tag_val >> 3
        length, pos = _read_varint(data, pos)
        return field_num, data[pos:pos + length]
    except Exception as e:
        _log_exception("_parse_outer", e)
        return None


def _parse_inner(payload: bytes) -> dict:
    result = {}
    pos = 0
    while pos < len(payload):
        try:
            tag_val, pos = _read_varint(payload, pos)
            wt = tag_val & 0x7
            fn = tag_val >> 3
            if wt == 2:
                ln, pos = _read_varint(payload, pos)
                result[fn] = payload[pos:pos + ln]
                pos += ln
            elif wt == 0:
                val, pos = _read_varint(payload, pos)
                result[fn] = val
            else:
                break
        except Exception as e:
            _log_exception("_parse_inner", e)
            break
    return result


# ── proto translation ─────────────────────────────────────────────────────────
#
# Direction: client → hbbs
#   field 18 (RequestRelay new)  → field 9  (RequestRelay old)
#   field 19 (RelayResponse new) → field 10 (RelayResponse old)
#
# Direction: hbbs → client
#   field 10 (RelayResponse old) → field 19 (RelayResponse new)
#   field 9  (RequestRelay old / PunchHole new): pass through
#
# RequestRelay inner mapping:
#   new: id=1, uuid=2, socket_addr=3, relay_server=4, secure=5, licence_key=6
#   old (request): id=1, relay_server=2, secure=3
#
# RelayResponse inner: same field numbers in old and new proto.
#   field 1=socket_addr, field 2=uuid, field 3=relay_server, field 4=id/pk, ...


def translate_client_to_hbbs(proto: bytes) -> bytes:
    parsed = _parse_outer(proto)
    if not parsed:
        return proto
    outer, payload = parsed

    if outer == 18:
        # RequestRelay new proto → old proto
        inner = _parse_inner(payload)
        id_bytes = inner.get(1, b'')
        relay_server_bytes = inner.get(4, b'')
        secure = inner.get(5, 1)  # default True
        target_id = id_bytes.decode(errors='replace') if id_bytes else ''
        relay_server = relay_server_bytes.decode(errors='replace') if relay_server_bytes else ''
        logging.debug("TCP proxy: RequestRelay f18→f9 target=%s relay=%s", target_id, relay_server)
        old_inner = (
            _pb_len_field(1, id_bytes) +
            _pb_string(2, relay_server) +
            _pb_bool(3, bool(secure))
        )
        return _pb_len_field(9, old_inner)

    if outer == 19:
        # RelayResponse new proto → old proto (inner fields identical, change outer only)
        logging.debug("TCP proxy: RelayResponse f19→f10")
        return _pb_len_field(10, payload)

    return proto


def translate_hbbs_to_client(proto: bytes) -> bytes:
    parsed = _parse_outer(proto)
    if not parsed:
        return proto
    outer, payload = parsed

    if outer == 10:
        # RelayResponse old proto → new proto (inner fields identical, change outer only)
        inner = _parse_inner(payload)
        uuid_b = inner.get(2, b'')
        relay_b = inner.get(3, b'')
        logging.debug(
            "TCP proxy: RelayResponse f10→f19 uuid=%s relay=%s",
            uuid_b[:16].decode(errors='replace'),
            relay_b.decode(errors='replace'),
        )
        return _pb_len_field(19, payload)

    # field 9 = old RequestRelay. Keep unchanged because new client treats it
    # as PunchHole and still reaches create_relay().
    return proto


# ── connection handler ────────────────────────────────────────────────────────

async def pipe(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    translate_fn,
    label: str,
):
    """Read bc-encoded frames, translate, write to other side."""
    try:
        while True:
            proto = await read_bc_frame(reader)
            _frame_preview(proto, label=f"{label} raw")
            translated = translate_fn(proto)
            _frame_preview(translated, label=f"{label} translated")
            writer.write(bc_encode(translated))
            await writer.drain()
    except asyncio.IncompleteReadError:
        logging.info("%s pipe closed by peer", label)
    except Exception as e:
        _log_exception(f"{label} pipe", e)
    finally:
        try:
            writer.close()
        except Exception as e:
            _log_exception(f"{label} writer.close", e)


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    logging.info("TCP proxy connect from %s", peer)
    try:
        hbbs_reader, hbbs_writer = await asyncio.open_connection(HBBS_HOST, HBBS_PORT)
    except Exception as e:
        _log_exception("handle.open_connection", e)
        writer.close()
        return

    await asyncio.gather(
        pipe(reader, hbbs_writer, translate_client_to_hbbs, "c→s"),
        pipe(hbbs_reader, writer, translate_hbbs_to_client, "s→c"),
    )
    logging.info("TCP proxy closed %s", peer)


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    addrs = ", ".join(str(s.getsockname()) for s in server.sockets)
    logging.info("hbbs TCP proxy listening on %s → %s:%d", addrs, HBBS_HOST, HBBS_PORT)
    logging.info("Apply iptables rule: sudo iptables -t nat -A PREROUTING -p tcp --dport 21116 -j REDIRECT --to-port %d", LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
