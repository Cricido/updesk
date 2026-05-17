from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)


MANIFEST_FIELDS = (
    "channel",
    "version",
    "url",
    "sha256",
    "mandatory",
    "min_supported",
    "changelog",
)


def canonical_manifest_payload(data: dict) -> bytes:
    normalized = {
        "channel": str(data.get("channel") or "").strip().lower(),
        "version": str(data.get("version") or "").strip(),
        "url": str(data.get("url") or "").strip(),
        "sha256": str(data.get("sha256") or "").strip().lower(),
        "mandatory": "true" if bool(data.get("mandatory")) else "false",
        "min_supported": str(data.get("min_supported") or "").strip(),
        "changelog": str(data.get("changelog") or "").replace("\r\n", "\n").replace("\r", "\n"),
    }
    payload = "".join(f"{key}={normalized[key]}\n" for key in MANIFEST_FIELDS)
    return payload.encode("utf-8")


def load_manifest(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_manifest(path: Path, data: dict):
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_private_key(path: Path) -> Ed25519PrivateKey:
    raw = base64.b64decode(path.read_text(encoding="utf-8").strip())
    return Ed25519PrivateKey.from_private_bytes(raw)


def load_public_key(path: Path) -> Ed25519PublicKey:
    raw = base64.b64decode(path.read_text(encoding="utf-8").strip())
    return Ed25519PublicKey.from_public_bytes(raw)


def cmd_keygen(args):
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()

    private_raw = private_key.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption(),
    )
    public_raw = public_key.public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw,
    )

    args.private.parent.mkdir(parents=True, exist_ok=True)
    args.public.parent.mkdir(parents=True, exist_ok=True)
    args.private.write_text(base64.b64encode(private_raw).decode("ascii") + "\n", encoding="utf-8")
    args.public.write_text(base64.b64encode(public_raw).decode("ascii") + "\n", encoding="utf-8")
    print(f"private={args.private}")
    print(f"public={args.public}")


def cmd_sign(args):
    manifest = load_manifest(args.manifest)
    signature = load_private_key(args.private).sign(canonical_manifest_payload(manifest))
    manifest["signature"] = base64.b64encode(signature).decode("ascii")
    save_manifest(args.manifest, manifest)
    print(f"signed={args.manifest}")


def cmd_verify(args):
    manifest = load_manifest(args.manifest)
    signature_b64 = str(manifest.get("signature") or "").strip()
    if not signature_b64:
        raise SystemExit("manifest signature missing")
    signature = base64.b64decode(signature_b64)
    load_public_key(args.public).verify(signature, canonical_manifest_payload(manifest))
    print(f"verified={args.manifest}")


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    keygen = sub.add_parser("keygen")
    keygen.add_argument("--private", type=Path, required=True)
    keygen.add_argument("--public", type=Path, required=True)
    keygen.set_defaults(func=cmd_keygen)

    sign = sub.add_parser("sign")
    sign.add_argument("--private", type=Path, required=True)
    sign.add_argument("--manifest", type=Path, required=True)
    sign.set_defaults(func=cmd_sign)

    verify = sub.add_parser("verify")
    verify.add_argument("--public", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.set_defaults(func=cmd_verify)
    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
