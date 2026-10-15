#!/usr/bin/env python3
"""Exercise the actual CLI/engine processes in an isolated temporary workspace."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    args = parser.parse_args()
    binary = args.bin_dir.resolve()
    cli, engine = (binary / "lathe").resolve(), (binary / "lathe-engine").resolve()
    assert cli.is_file() and engine.is_file(), "Build both executables first."

    with tempfile.TemporaryDirectory(prefix="lathe-integration-") as temporary:
        base = Path(temporary).resolve()
        root, workspace = base / "state", base / "project"
        workspace.mkdir()
        marker = workspace / "unchanged.txt"
        marker.write_text("Mock execution must preserve project files.\n")
        command = [str(cli), "--data-dir", str(root), "--engine", str(engine)]
        owned = set()
        socket_path = None

        def call(*arguments, expected=0, stdin=None):
            result = subprocess.run(command + list(arguments), input=stdin,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == expected, (arguments, result.returncode, result.stdout, result.stderr)
            return result.stdout

        def json_call(*arguments, **kwargs):
            return json.loads(call(*arguments, **kwargs))

        def events(session):
            return [json.loads(line) for line in call("events", "--session", session).splitlines()]

        def kill_owned(pid, number):
            # Never signal a pre-existing/user engine, even if a PID was reused.
            assert pid in owned
            process = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                     capture_output=True, text=True)
            if not process.stdout.strip():
                return
            parts = process.stdout.strip().rsplit(" --root ", 1)
            assert len(parts) == 2 and Path(parts[0]).resolve() == engine and Path(parts[1]).resolve() == root, process.stdout
            os.kill(pid, number)

        def receive(sock, size):
            data = b""
            while len(data) < size:
                piece = sock.recv(size - len(data))
                assert piece, "Unexpected IPC EOF"
                data += piece
            return data

        def rpc(value):
            payload = value if isinstance(value, bytes) else json.dumps(value).encode()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(5)
                sock.connect(str(socket_path))
                sock.sendall(struct.pack("!I", len(payload)) + payload)
                length, = struct.unpack("!I", receive(sock, 4))
                assert length <= 1_048_576
                return json.loads(receive(sock, length))

        try:
            def start_client(_):
                info = json_call("status", "--json")
                owned.add(info["processID"])
                return info

            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                infos = list(pool.map(start_client, range(6)))
            assert len({info["engineID"] for info in infos}) == 1
            assert len(owned) == 1
            first = infos[0]
            assert first["mode"] == "coding-preview" and first["protocolVersion"] == 2
            print("PASS concurrent clients bootstrap one engine", flush=True)

            # Foundation may preserve /var where Python resolves /private/var.
            # Hash the engine client's canonical spelling, not Python's spelling.
            canonical_root = call("status").splitlines()[-1]
            assert Path(canonical_root).resolve() == root
            digest = hashlib.sha256(canonical_root.encode()).hexdigest()[:24]
            candidates = [Path(tempfile.gettempdir()) / ("lathe-" + digest) / "engine.sock",
                          Path("/private/tmp") / f"lathe-{os.geteuid()}-{digest}" / "engine.sock"]
            socket_path = next((path for path in candidates if path.is_socket()), None)
            assert socket_path is not None, candidates
            envelope = {"jsonrpc": "2.0", "id": "smoke", "method": "handshake", "params": {"protocolVersion": 2}}
            assert rpc(envelope)["result"]["info"]["engineID"] == first["engineID"]
            envelope["params"]["protocolVersion"] = 999
            assert rpc(envelope)["error"]["code"] == -32001
            envelope["params"]["protocolVersion"] = 2
            envelope["method"] = "unknown"
            assert rpc(envelope)["error"]["code"] == -32601
            assert rpc({"jsonrpc": "2.0"})["error"]["code"] == -32600
            assert rpc(b"not-json")["error"]["code"] == -32700
            print("PASS RPC version and malformed request boundaries", flush=True)

            session = json_call("new", "--workspace", str(workspace), "한글 mock 검증", "--json")["id"]
            key = str(uuid.uuid4())
            arguments = ("run", "--session", session, "--request-id", key, "--detach", "cancel me")
            run = json_call(*arguments)
            assert json_call(*arguments)["id"] == run["id"]
            call("run", "--session", session, "--detach", "conflicting run", expected=1)
            cancelled = json_call("cancel", run["id"], "--json")
            assert cancelled["state"] == "cancelled"
            before = events(session)
            time.sleep(0.3)
            assert events(session) == before, "Deltas appeared after terminal cancellation"
            assert json_call(*arguments)["state"] == "cancelled"
            call("run", "--session", session, "--request-id", key, "--detach", "changed payload", expected=1)
            print("PASS idempotency, active-run conflict and terminal cancellation", flush=True)

            completed_events = [json.loads(line) for line in call("run", "--session", session, "--json", "한글\nstreaming").splitlines()]
            assert completed_events[-1]["kind"] == "runCompleted"
            deltas = [item["text"] for item in completed_events if item["kind"] == "textDelta"]
            assert len(deltas) > 1
            snapshot = json_call("show", session, "--json")
            completed = snapshot["runs"][-1]
            assert completed["response"] == "".join(deltas)
            assert completed["state"] == "completed"
            listing = json_call("sessions", "--json")
            assert listing[0]["id"] == session and listing[0]["runs"] == []
            print("PASS streamed output equals durable replay through a new client", flush=True)

            process = subprocess.Popen(command + ["run", "--session", session, "--json", "signal cancellation"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert "run=" in process.stderr.readline()
                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
                assert process.returncode == 130, (process.returncode, stdout, stderr)
                assert json.loads(stdout.splitlines()[-1])["state"] == "cancelled"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            print("PASS CLI SIGINT cancels its run and exits 130", flush=True)

            for index in range(5):
                item = json_call("run", "--session", session, "--detach", f"history {index}")
                json_call("cancel", item["id"], "--json")
            page = json_call("show", session, "--json")
            total = page["totalRunCount"]
            seen = set()
            while True:
                for item in page["runs"]:
                    assert item["id"] not in seen
                    seen.add(item["id"])
                cursor = page.get("nextBeforeRunID")
                if cursor is None:
                    break
                page = json_call("show", session, "--before", cursor, "--json")
            assert len(seen) == total and total > 4
            print("PASS paged history has no missing or duplicate runs", flush=True)

            crash_key = str(uuid.uuid4())
            crash_args = ("run", "--session", session, "--request-id", crash_key, "--detach", "crash recovery")
            crashed = json_call(*crash_args)
            kill_owned(first["processID"], signal.SIGKILL)
            time.sleep(0.15)
            second = json_call("status", "--json")
            owned.add(second["processID"])
            assert second["engineID"] != first["engineID"]
            assert json_call(*crash_args)["id"] == crashed["id"]
            assert json_call(*crash_args)["state"] == "interrupted"
            replay = events(session)
            assert sum(e["kind"] == "runInterrupted" and e.get("runID") == crashed["id"] for e in replay) == 1
            sequences = [item["sequence"] for item in replay]
            assert sequences == sorted(set(sequences))
            cursor = sequences[len(sequences) // 2]
            after = [json.loads(line) for line in call("events", "--session", session, "--after", str(cursor)).splitlines()]
            assert after == [item for item in replay if item["sequence"] > cursor]
            print("PASS crash recovery, stale socket replacement and ordered event replay", flush=True)

            old_count = json_call("show", session, "--json")["totalRunCount"]
            call("run", "--session", session, stdin="x" * 32_769, expected=1)
            assert json_call("show", session, "--json")["totalRunCount"] == old_count
            giant = json_call("run", "--workspace", str(workspace), "--detach", stdin="a" + "\u0301" * 1_000)
            json_call("cancel", giant["id"], "--json")
            giant_session = json_call("show", giant["sessionID"], "--json")
            assert len(giant_session["title"].encode()) <= 512
            assert list(workspace.iterdir()) == [marker]
            assert marker.read_text() == "Mock execution must preserve project files.\n"
            print("PASS bounded stdin and untouched project files", flush=True)
        finally:
            for pid in owned:
                try:
                    kill_owned(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if socket_path is not None:
                deadline = time.monotonic() + 3
                while socket_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert not socket_path.exists(), "Engine did not remove its socket on SIGTERM"
                try:
                    socket_path.parent.rmdir()
                except OSError:
                    pass
    print("PASS graceful engine shutdown removes its socket")
    print("All engine integration checks passed.")


if __name__ == "__main__":
    main()
