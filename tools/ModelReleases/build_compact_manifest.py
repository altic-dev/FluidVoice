#!/usr/bin/env python3
"""Build a signed Mini/Pico release catalog without uploading anything.

Requires cryptography. Example:
  python3 tools/ModelReleases/build_compact_manifest.py releases.json catalog.json \
    --private-key /private/path/compact-model-release-ed25519.pem --verify-archives

releases.json contains schemaVersion: 1 and models: [variant, version, url,
sha256, byteCount] for exactly mini and pico. Keep the private key outside Git.
Publish catalog.json at parakeet/compact-models.json after installer verification.
Future releases reuse this signing key and update that catalog after uploading
the immutable versioned archives. Signing a catalog does not verify Core ML load.
"""

import argparse
import base64
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def validate(payload):
    if payload.get("schemaVersion") != 1:
        raise ValueError("Unsupported catalog schema")
    models = payload.get("models", [])
    if len(models) != 2 or {m.get("variant") for m in models} != {"mini", "pico"}:
        raise ValueError("Catalog must contain exactly Mini and Pico")
    for model in models:
        variant, version = model["variant"], model["version"]
        if len(version) > 32 or not re.fullmatch(r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})", version):
            raise ValueError("Release version must have three numeric components")
        expected = f"https://models.fluidvoice.app/parakeet/fluid-{variant}/{version}/fluid-parakeet-{variant}-coreml.tar"
        if model["url"] != expected:
            raise ValueError("Archive must use its immutable FluidVoice release URL")
        if not re.fullmatch(r"[0-9a-f]{64}", model["sha256"]):
            raise ValueError("Invalid archive SHA-256")
        if type(model["byteCount"]) is not int or not 0 < model["byteCount"] <= 600_000_000:
            raise ValueError("Invalid archive byte count")
    return {"schemaVersion": 1, "models": sorted(models, key=lambda m: m["variant"])}


def verify_archive(model):
    digest, count = hashlib.sha256(), 0
    request = Request(model["url"], headers={"User-Agent": "FluidVoiceModelPublisher/1.0"})
    with urlopen(request, timeout=60) as response:
        if response.status != 200 or urlparse(response.url).hostname != "models.fluidvoice.app":
            raise ValueError("Unexpected archive response")
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > model["byteCount"]:
                raise ValueError("Archive exceeds pinned size")
            digest.update(chunk)
    if count != model["byteCount"] or digest.hexdigest() != model["sha256"]:
        raise ValueError("Hosted archive differs from its pin")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("releases", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--verify-archives", action="store_true")
    args = parser.parse_args()
    payload = validate(json.loads(args.releases.read_text()))
    if args.verify_archives:
        for model in payload["models"]:
            verify_archive(model)
    key = serialization.load_pem_private_key(args.private_key.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Signing key must be Ed25519")
    data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    envelope = {"schemaVersion": 1, "payload": base64.b64encode(data).decode(),
                "signature": base64.b64encode(key.sign(data)).decode()}
    result = (json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(result) > 16_384:
        raise ValueError("Catalog exceeds app download limit")
    args.output.write_bytes(result)
    print(json.dumps({"output": str(args.output), "bytes": len(result),
                      "sha256": hashlib.sha256(result).hexdigest(),
                      "archivesVerified": args.verify_archives}))


if __name__ == "__main__":
    main()
