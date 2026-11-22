#!/usr/bin/env python3
"""Download the pinned CC0 camera fixtures; large originals stay outside Git."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "Fixtures/RAW/samples.json").read_text())
destination = root / "build/raw-samples"
destination.mkdir(parents=True, exist_ok=True)


def fetch(sample):
    path = destination / sample["name"]
    expected = sample["sha256"]
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        return f"Verified {sample['camera']}: {path.name}"
    url = urllib.parse.quote(sample["url"], safe=":/")
    assert urllib.parse.urlsplit(url).hostname == "raw.pixls.us"
    temporary = path.with_suffix(path.suffix + ".download")
    try:
        digest = hashlib.sha256()
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f"Checksum mismatch: {sample['name']}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return f"Downloaded {sample['camera']}: {path.name}"


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    for result in executor.map(fetch, manifest["samples"]):
        print(result, flush=True)
