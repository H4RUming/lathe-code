#!/usr/bin/env python3
"""Verify the actual app owns its runtime and runner lifetime, using isolated data.

Only the app process started here is terminated. A loopback fixture supplies the
command; no model service, credentials, or existing application data are used.
Requires a macOS GUI login session (as provided by GitHub's macOS runners).
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import uuid


spec = importlib.util.spec_from_file_location("agent_fixture", Path(__file__).with_name("smoke-agent.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def wait_for(predicate, label, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("Timed out: " + label)


def process_gone(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return not result.stdout.strip() or result.stdout.strip().startswith("Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binaries = args.bin_dir.resolve()
    app = binaries / "Lathe.app"
    executable = app / "Contents/MacOS/Lathe"
    cli = binaries / "lathe"
    assert executable.is_file() and cli.is_file(), "Build with --developer-tools first."
    helpers = app / "Contents/Helpers"
    assert {item.name for item in helpers.iterdir()} == {"lathe-runner"}, "Only the execution helper belongs in the app."
    checks = []
    server = fixture.FixtureServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="lathe-app-smoke-") as temporary:
            base = Path(temporary).resolve()
            # A separate bundle identity prevents LaunchServices/SwiftUI from
            # routing activation to a user's already-running Lathe instance.
            isolated_app = base / "Lathe.app"
            subprocess.run(["/usr/bin/ditto", str(app), str(isolated_app)], check=True)
            plist = isolated_app / "Contents/Info.plist"
            metadata = plistlib.loads(plist.read_bytes())
            metadata["CFBundleIdentifier"] = "dev.lathe.lifecycle." + uuid.uuid4().hex
            plist.write_bytes(plistlib.dumps(metadata))
            subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(isolated_app)],
                           check=True, capture_output=True)
            executable = isolated_app / "Contents/MacOS/Lathe"
            root, workspace = base / "state", base / "workspace"
            workspace.mkdir()
            command = [str(cli), "--root", str(root)]
            # Cocoa's terminate request exercises applicationShouldTerminate,
            # addressed by the exact owned PID, never by a bundle ID or name.
            source = base / "quit.m"
            source.write_text('''#import <AppKit/AppKit.h>
#include <stdlib.h>
int main(int argc, const char **argv) {
    if (argc != 2) return 2;
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[1])];
        return app && [app terminate] ? 0 : 1;
    }
}
''')
            quitter = base / "quit"
            subprocess.run(["/usr/bin/clang", "-Werror", "-framework", "AppKit", str(source), "-o", str(quitter)], check=True, capture_output=True)
            process = None

            def call(*words, expected=0):
                result = subprocess.run(command + list(words), capture_output=True, text=True, timeout=10)
                assert result.returncode == expected, (words, result.returncode, result.stdout, result.stderr)
                return result.stdout

            def js(*words):
                return json.loads(call(*words))

            def status():
                assert process is not None and process.poll() is None, "Owned app exited before readiness."
                result = subprocess.run(command + ["status", "--json"], capture_output=True, text=True, timeout=6)
                return json.loads(result.stdout) if result.returncode == 0 else None

            def start(log):
                nonlocal process
                environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "TMPDIR": tempfile.gettempdir(), "LATHE_DATA_DIR": str(root)}
                process = subprocess.Popen([str(executable)], stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=environment)
                info = wait_for(status, "app runtime startup")
                assert info["processID"] == process.pid, "The app connected to a separate daemon."
                return info

            def quit_idle():
                assert process.poll() is None
                requested = subprocess.run([str(quitter), str(process.pid)], capture_output=True, text=True)
                assert requested.returncode == 0, (requested.returncode, requested.stderr)
                assert process.wait(timeout=15) == 0, "Idle app did not terminate gracefully."
                call("status", "--json", expected=1)

            def check(name):
                with server.lock:
                    assert not server.errors, server.errors
                checks.append(name)
                print("PASS " + name, flush=True)

            with (base / "app.log").open("wb") as log:
                try:
                    call("status", "--json", expected=1)
                    first = start(log)
                    check("app PID is engine PID; developer CLI cannot launch an engine implicitly")
                    quit_idle()
                    second = start(log)
                    assert first["engineID"] != second["engineID"]
                    check("idle Cocoa quit releases the runtime and lease; the app restarts cleanly")

                    profile = js("provider-set", "--name", "App lifetime fixture", "--api", "openAIChat",
                                 "--model", "fixture-model", "--base-url", f"http://127.0.0.1:{server.server_port}/prefix/v1",
                                 "--allow-http", "--json")["id"]
                    session = js("new", "--workspace", str(workspace), "App lifetime", "--json")["id"]
                    run = js("run", "--session", session, "--provider", profile, "--permission", "requestApproval",
                             "--detach", "fixture:cancel-shell")
                    invocation = wait_for(lambda: next((item for item in js("tools", run["id"], "--json")
                                                        if item["state"] == "pendingApproval"), None), "shell approval")
                    assert invocation["name"] == "run_command"
                    js("approve", invocation["id"], "--hash", invocation["requestHash"], "--json")
                    pid_file = workspace / "owned-child.pid"
                    wait_for(lambda: pid_file.exists() and pid_file.read_text().strip(), "owned command start")
                    child_pid = int(pid_file.read_text())
                    processes = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,comm="],
                                               capture_output=True, text=True, check=True)
                    owned_helpers = [int(parts[0]) for line in processes.stdout.splitlines()
                                     if len(parts := line.strip().split(None, 2)) == 3
                                     and int(parts[1]) == process.pid and Path(parts[2]).name == "lathe-runner"]
                    assert len(owned_helpers) == 1, "Expected one app-owned execution helper."
                    # KILL intentionally bypasses the app's graceful cleanup.
                    process.kill()
                    process.wait(timeout=5)
                    wait_for(lambda: process_gone(child_pid), "runner cancels command after app loss", seconds=8)
                    receipt = root / "executions" / invocation["id"] / "execution/result.json"
                    wait_for(receipt.exists, "runner writes terminal receipt after owner loss", seconds=8)
                    assert json.loads(receipt.read_text())["result"]["reason"] == "cancelled"
                    wait_for(lambda: all(process_gone(pid) for pid in owned_helpers), "runner helper exit", seconds=8)
                    assert not (workspace / "late.txt").exists()
                    call("status", "--json", expected=1)
                    check("app crash cancels the owned shell and records a runner receipt; no daemon remains")

                    start(log)
                    recovered = js("show", session, "--json")
                    assert next(item for item in recovered["runs"] if item["id"] == run["id"])["state"] == "interrupted"
                    assert server.count("cancel-shell") == 1, "Crash recovery replayed a command."
                    quit_idle()
                    check("relaunch recovers interrupted work without replay and quits cleanly")
                except Exception:
                    log.flush()
                    print((base / "app.log").read_text(errors="replace")[-4_000:], flush=True)
                    raise
                finally:
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"status": "passed", "checks": checks}, indent=2) + "\n")
    print(f"All {len(checks)} app lifetime checks passed.")


if __name__ == "__main__":
    main()
