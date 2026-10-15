#!/usr/bin/env python3
"""Probe experimental macOS Seatbelt behavior against disposable fixtures only.

Exit codes: 0 passed, 1 failed, 2 unsupported. This is development evidence,
not a production sandbox implementation or a reason to permit unrestricted tools.
"""

import argparse
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import sys
import tempfile


PROFILE = """(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath (param "ALLOWED_ROOT")))
(deny network*)
"""

WORKER = """
import json, pathlib, socket, sys
try:
    if sys.argv[1] == "write":
        pathlib.Path(sys.argv[2]).write_text("fixture marker\\n", encoding="utf-8")
    else:
        with socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=2):
            pass
    print(json.dumps({"succeeded": True}))
except OSError as error:
    print(json.dumps({"succeeded": False, "errno": error.errno,
                      "error": error.strerror}))
"""

CHILD_WORKER = """
import subprocess, sys
child = subprocess.run([sys.executable, "-I", "-B", "-c", sys.argv[1],
                        "write", sys.argv[2]], capture_output=True, text=True,
                       timeout=5, close_fds=True)
sys.stdout.write(child.stdout)
sys.stderr.write(child.stderr)
sys.exit(child.returncode)
"""


def command_output(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        return (result.stdout or result.stderr).strip()[:2048]
    except (OSError, subprocess.TimeoutExpired) as error:
        return str(error)


def inspect_environment():
    binary = Path("/usr/bin/sandbox-exec")
    man = Path("/usr/share/man/man1/sandbox-exec.1")
    return {
        "system": platform.system(),
        "macOS": command_output(["/usr/bin/sw_vers"]) if sys.platform == "darwin" else None,
        "architecture": platform.machine(),
        "python": platform.python_version(),
        "swift": command_output(["/usr/bin/xcrun", "swift", "--version"])
        if sys.platform == "darwin" else None,
        "sandboxExecutable": str(binary) if binary.is_file() else None,
        # sandbox-exec has no version flag. Record the OS build and binary hash.
        "sandboxSHA256": hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else None,
        "installedManPageMarksDeprecated": "DEPRECATED" in man.read_text() if man.is_file() else None,
    }


def probe(report):
    checks = report["checks"]

    def record(name, status, **detail):
        checks.append({"name": name, "status": status, **detail})

    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        record("backend_available", "unsupported", reason="Requires macOS /usr/bin/sandbox-exec.")
        return

    with tempfile.TemporaryDirectory(prefix="lathe-sandbox-probe-") as temporary:
        base = Path(temporary).resolve()
        allowed, outside = base / "allowed", base / "outside"
        allowed.mkdir()
        outside.mkdir()
        (allowed / "link-outside").symlink_to(outside, target_is_directory=True)
        profile = base / "probe.sb"
        profile.write_text(PROFILE)
        # Do not pass provider credentials or unrelated user environment to fixtures.
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(allowed),
                       "TMPDIR": str(allowed), "LC_ALL": "C"}
        prefix = ["/usr/bin/sandbox-exec", "-D", f"ALLOWED_ROOT={allowed}",
                  "-f", str(profile)]
        python = [sys.executable, "-I", "-B", "-c"]

        def launch(arguments, sandboxed=True):
            command = (prefix if sandboxed else []) + arguments
            # Every fixture has its own session. On timeout terminate only this
            # owned process group, including the descendant fixture worker.
            process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True,
                                       env=environment, cwd=allowed,
                                       close_fds=True, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=10)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

        def diagnostic(result):
            return {"exitCode": result.returncode,
                    "stderr": result.stderr.replace(str(base), "<fixture>")[:2048]}

        activation = launch(["/usr/bin/true"])
        if activation.returncode != 0:
            unavailable = any(token in activation.stderr.lower() for token in (
                "operation not permitted", "not supported", "sandbox_init:",
                "sandbox initialization failed"))
            record("backend_activation", "unsupported" if unavailable else "failed",
                   **diagnostic(activation))
            return
        record("backend_activation", "passed")

        def observe(arguments, sandboxed=True):
            result = launch(arguments, sandboxed)
            if result.returncode != 0:
                return {"launchFailure": diagnostic(result)}
            try:
                value = json.loads(result.stdout)
                if not isinstance(value, dict) or not isinstance(value.get("succeeded"), bool):
                    raise ValueError("Invalid worker result")
                return value
            except ValueError:
                return {"launchFailure": {**diagnostic(result), "reason": "Invalid worker JSON"}}

        def write_check(name, target, should_allow, child=False):
            # First prove the same target is writable without this experimental policy.
            control = observe(python + [WORKER, "write", str(target)], sandboxed=False)
            control_ok = control.get("succeeded") is True and target.read_text() == "fixture marker\n"
            if target.exists():
                target.unlink()
            if not control_ok:
                record(name, "unsupported", reason="Unsandboxed fixture control failed", control=control)
                return
            command = python + ([CHILD_WORKER, WORKER, str(target)] if child
                                else [WORKER, "write", str(target)])
            observed = observe(command)
            if should_allow:
                passed = (observed.get("succeeded") is True and target.is_file()
                          and target.read_text() == "fixture marker\n")
            else:
                passed = (observed.get("succeeded") is False and
                          observed.get("errno") in (errno.EPERM, errno.EACCES) and
                          not target.exists())
            record(name, "passed" if passed else "failed", control=control,
                   observed=observed, fileExists=target.exists())

        write_check("allowed_directory_write", allowed / "allowed.txt", True)
        write_check("outside_directory_write_denied", outside / "outside.txt", False)
        write_check("symlink_escape_write_denied", allowed / "link-outside" / "symlink.txt", False)
        write_check("child_inherits_write_denial", outside / "child.txt", False, child=True)
        write_check("child_inherits_write_grant", allowed / "child.txt", True, child=True)

        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(4)
                listener.settimeout(3)
                command = python + [WORKER, "connect", str(listener.getsockname()[1])]
                control = observe(command, sandboxed=False)
                if control.get("succeeded") is not True:
                    record("loopback_tcp_denied", "unsupported",
                           reason="Unsandboxed TCP control failed", control=control)
                    return
                accepted, _ = listener.accept()
                accepted.close()
                observed = observe(command)
                passed = (observed.get("succeeded") is False and
                          observed.get("errno") in (errno.EPERM, errno.EACCES))
                record("loopback_tcp_denied", "passed" if passed else "failed",
                       control=control, observed=observed)
        except OSError as error:
            record("loopback_tcp_denied", "unsupported", reason="Host cannot run localhost fixture",
                   errno=error.errno, error=error.strerror)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Also save the JSON report to this file.")
    args = parser.parse_args()
    report = {
        "schemaVersion": 1,
        "probe": "lathe.m0.sandbox",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "backend": "experimental-seatbelt-sandbox-exec",
        "environment": inspect_environment(),
        "profile": PROFILE,
        "checks": [],
        "limitations": [
            "Deprecated unsupported SBPL interface; this is not a production isolation guarantee.",
            "Read access, inherited descriptors, Mach IPC, toolchains and filesystem races are untested.",
            "Only disposable filesystem targets and localhost IPv4 TCP are exercised.",
            "No implicit unrestricted execution fallback is provided.",
        ],
    }
    try:
        probe(report)
    except (OSError, subprocess.TimeoutExpired) as error:
        report["checks"].append({"name": "probe_execution", "status": "failed", "reason": str(error)})
    statuses = {check["status"] for check in report["checks"]}
    report["status"] = "failed" if "failed" in statuses else "unsupported" if "unsupported" in statuses else "passed"
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return {"passed": 0, "failed": 1, "unsupported": 2}[report["status"]]


if __name__ == "__main__":
    sys.exit(main())
