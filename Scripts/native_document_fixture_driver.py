#!/usr/bin/env python3
"""Run native macOS UI tests with access only to their own Trash fixtures.

Usage: python3 Scripts/native_document_fixture_driver.py -- xcodebuild ...
The helper lives only while the supplied command runs. No Trash enumeration,
existing-document cleanup, app permission changes, or production APIs are used.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid


CACHE = Path.home() / "Library/Containers/com.asherbloom.Tally/Data/Library/Caches"
TRASH = Path.home() / ".Trash"
MARKER = CACHE / ".tally-native-fixture-driver.json"
PREFIX = "TallyNativeDocumentTests-"


def canonical_uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)).upper() != value:
        raise ValueError("Expected canonical fixture UUID")
    return value


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp-" + str(uuid.uuid4()))
    try:
        with temporary.open("x") as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_request(root, request_path, started):
    if root.is_symlink() or root.resolve().parent != CACHE.resolve():
        raise ValueError("Fixture directory is not inside the test cache")
    if root.stat().st_birthtime < started:
        raise ValueError("Fixture predates this driver")
    session = canonical_uuid(root.name.removeprefix(PREFIX))
    marker = root / ".test-owner"
    if marker.is_symlink() or marker.read_text() != session:
        raise ValueError("Fixture ownership marker mismatch")
    if request_path.is_symlink():
        raise ValueError("Request must not be a symlink")
    request = json.loads(request_path.read_text())
    request_id = canonical_uuid(request["requestID"])
    if request_path.name != f".native-request-{request_id}.json":
        raise ValueError("Request filename mismatch")
    if request["session"] != session:
        raise ValueError("Request session mismatch")
    if request["operation"] not in ("verifyTrash", "deleteTrash", "restoreTrash"):
        raise ValueError("Unsupported fixture operation")
    target = Path(request["path"])
    if target.parent != TRASH or target.name != f"Native-A-{session[:8]}.tally":
        raise ValueError("Only the exact owned Native-A Trash file is allowed")
    if target.is_symlink():
        raise ValueError("Trash fixture must not be a symlink")
    if not re.fullmatch(r"[0-9a-f]{64}", request["sha256"]):
        raise ValueError("Invalid fixture digest")
    canonical_uuid(request["ledgerID"])
    return request, target


def service_request(root, request_path, started, remover):
    request, target = validate_request(root, request_path, started)
    response_path = root / f'.native-response-{request["requestID"]}.json'
    if response_path.exists():
        return
    response = {"requestID": request["requestID"], "session": request["session"]}
    try:
        if target.exists():
            data = target.read_bytes()
            ledger = json.loads(data)
            if hashlib.sha256(data).hexdigest() != request["sha256"] or ledger.get("id") != request["ledgerID"]:
                raise ValueError("Trash file no longer matches the original fixture bytes and ledger UUID")
            if not target.is_file():
                raise ValueError("Trash fixture must be a regular file")
        elif request["operation"] in ("verifyTrash", "restoreTrash"):
            raise FileNotFoundError("The owned Trash fixture is absent")
        if request["operation"] == "restoreTrash":
            destination = root / target.name
            if destination.exists() or destination.is_symlink():
                raise ValueError("Restore destination is already occupied")
            subprocess.run([str(remover), str(target), request["sha256"], request["ledgerID"], str(destination)],
                           check=True, timeout=8, capture_output=True, text=True)
            if target.exists() or not destination.is_file():
                raise RuntimeError("The coordinated restore did not move the owned file")
            state = "restored"
        elif request["operation"] == "deleteTrash":
            subprocess.run([str(remover), str(target), request["sha256"], request["ledgerID"]],
                           check=True, timeout=8, capture_output=True, text=True)
            if target.exists():
                raise RuntimeError("The coordinated removal did not remove the owned file")
            state = "missing"
        else:
            state = "present"
        response.update(ok=True, state=state)
        print(f'Fixture {request["session"][:8]}: {request["operation"]} -> {state}', flush=True)
    except Exception as error:
        detail = getattr(error, "stderr", None) or str(error)
        response.update(ok=False, error=detail)
        print(f"Fixture operation rejected: {detail}", file=sys.stderr, flush=True)
    atomic_json(response_path, response)


def main():
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit(__doc__)
    CACHE.mkdir(parents=True, exist_ok=True)
    if MARKER.exists():
        try:
            active = time.time() - json.loads(MARKER.read_text())["heartbeat"] < 5
        except (ValueError, KeyError):
            active = False
        if active:
            raise SystemExit("Another native fixture driver is already running")
    driver_id = str(uuid.uuid4())
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="TallyNativeFixtureDriver-") as temporary:
        remover = Path(temporary) / "remove-owned-fixture"
        subprocess.run(["xcrun", "swiftc", str(Path(__file__).with_name("native_fixture_remove.swift")),
                        "-o", str(remover)], check=True)
        process = None
        try:
            atomic_json(MARKER, {"driverID": driver_id, "heartbeat": time.time()})
            process = subprocess.Popen(command)
            while process.poll() is None:
                atomic_json(MARKER, {"driverID": driver_id, "heartbeat": time.time()})
                for root in CACHE.glob(PREFIX + "*"):
                    if not root.is_dir() or root.is_symlink() or root.stat().st_birthtime < started:
                        continue
                    for request in root.glob(".native-request-*.json"):
                        try:
                            service_request(root, request, started, remover)
                        except (OSError, ValueError, KeyError, TypeError) as error:
                            print(f"Rejected fixture request {request.name}: {error}", file=sys.stderr, flush=True)
                time.sleep(0.05)
            return process.returncode
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
            if MARKER.exists() and json.loads(MARKER.read_text()).get("driverID") == driver_id:
                MARKER.unlink()


if __name__ == "__main__":
    sys.exit(main())
