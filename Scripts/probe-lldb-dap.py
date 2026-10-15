#!/usr/bin/env python3
"""M0 real-toolchain feasibility probe, not Lathe's production debugger.

Only builds/runs the checked-in fixture. Never accepts an external PID or program.
Exit: 0 all checks pass; 1 failure; 2 unsupported (also 0 with --allow-unsupported).
"""

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import subprocess
import sys
import tempfile
import time


MAX_FRAME = 1024 * 1024
TIMEOUT = 15
AUTH_ERRORS = (
    "operation not permitted", "permission denied", "not allowed to attach",
    "not permitted to attach", "unable to get the task port", "failed to get task",
    "developer tools access", "developer mode", "not authorized", "authorization",
    "debugserver is not available",
)


class ProbeError(Exception):
    pass


class Unsupported(ProbeError):
    pass


class AdapterRejected(ProbeError):
    pass


def require(condition, message):
    if not condition:
        raise ProbeError(message)


def run(command, env, timeout=30):
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False)
    output = result.stdout.decode("utf-8", errors="replace")[-8192:].strip()
    if result.returncode:
        diagnostic = result.stderr.decode("utf-8", errors="replace")[-8192:].strip()
        raise ProbeError(f"{Path(command[0]).name} exited {result.returncode}: {output}\n{diagnostic}")
    return output


def clean_environment(directory):
    # No model credentials or user LLDB init file in this probe's subprocesses.
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(directory),
                   "TMPDIR": str(directory), "LANG": "en_US.UTF-8"}
    for key in ("DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"):
        if key in os.environ:
            environment[key] = os.environ[key]
    return environment


class DAP:
    def __init__(self, adapter, env, cwd):
        self.process = subprocess.Popen([adapter], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, cwd=cwd)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ, "stdout")
        self.selector.register(self.process.stderr, selectors.EVENT_READ, "stderr")
        self.buffer = bytearray()
        self.responses = {}
        self.events = []
        self.sequence = 0
        self.trace = collections.deque(maxlen=100)
        self.stderr = bytearray()
        self.reverse_requests = []
        self.capabilities = {}
        self.output = ""
        self.disconnected = False
        self.cleanup = "not_attempted"

    def send(self, message):
        self.sequence += 1
        message["seq"] = self.sequence
        payload = json.dumps(message).encode("utf-8")
        try:
            self.process.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise ProbeError(f"Adapter input closed: {error}") from error
        self.trace.append(f"send:{message['type']}:{message.get('command', '')}")
        return self.sequence

    def request(self, command, arguments=None):
        return self.send({"type": "request", "command": command, "arguments": arguments or {}})

    def pump(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeError("DAP timeout; " + self.diagnostics())
        ready = self.selector.select(min(remaining, 0.2))
        for key, _ in ready:
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                self.selector.unregister(key.fileobj)
                continue
            if key.data == "stderr":
                self.stderr.extend(chunk)
                del self.stderr[:-8192]
                continue
            self.buffer.extend(chunk)
            while b"\r\n\r\n" in self.buffer:
                header, body = self.buffer.split(b"\r\n\r\n", 1)
                require(len(header) <= 8192, "DAP header exceeds budget")
                lengths = [line.split(b":", 1)[1].strip() for line in header.split(b"\r\n")
                           if line.lower().startswith(b"content-length:")]
                require(len(lengths) == 1, "DAP requires one Content-Length")
                try:
                    length = int(lengths[0])
                except ValueError as error:
                    raise ProbeError("Invalid DAP Content-Length") from error
                require(0 < length <= MAX_FRAME, "DAP frame exceeds budget")
                if len(body) < length:
                    break
                self.buffer = bytearray(body[length:])
                try:
                    message = json.loads(body[:length])
                except (UnicodeDecodeError, ValueError) as error:
                    raise ProbeError("Invalid DAP JSON") from error
                require(isinstance(message, dict), "DAP message must be an object")
                require(isinstance(message.get("body", {}), dict), "DAP body must be an object")
                kind = message.get("type")
                self.trace.append(f"receive:{kind}:{message.get('event', message.get('command', ''))}")
                if kind == "response":
                    self.responses[message.get("request_seq")] = message
                    require(len(self.responses) <= 128, "DAP response budget exceeded")
                elif kind == "event":
                    if message.get("event") == "output":
                        self.output = (self.output + message.get("body", {}).get("output", ""))[-8192:]
                    else:
                        self.events.append(message)
                        require(len(self.events) <= 1000, "DAP event budget exceeded")
                elif kind == "request":
                    command = message.get("command")
                    self.reverse_requests.append(command)
                    require(len(self.reverse_requests) <= 16, "DAP reverse request budget exceeded")
                    self.send({"type": "response", "request_seq": message.get("seq"),
                               "command": command, "success": False,
                               "message": "Probe does not authorize reverse process execution"})
                else:
                    raise ProbeError("Unknown DAP message type")
            require(len(self.buffer) <= MAX_FRAME + 8192, "DAP receive buffer exceeds budget")
        if not ready and not self.selector.get_map() and self.process.poll() is not None:
            raise ProbeError("Adapter exited before expected response/event; " + self.diagnostics())

    def response(self, sequence, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while sequence not in self.responses:
            self.pump(deadline)
        response = self.responses.pop(sequence)
        if not response.get("success"):
            detail = response.get("message", "") + " " + json.dumps(response.get("body", {}))
            raise AdapterRejected(f"{response.get('command')} rejected: {detail}")
        if response.get("command") == "disconnect":
            self.disconnected = True
        return response.get("body", {})

    def call(self, command, arguments=None):
        return self.response(self.request(command, arguments))

    def event(self, name, pending=None, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while True:
            # Report early rejection instead of waiting for initialized forever.
            if pending in self.responses and not self.responses[pending].get("success"):
                self.response(pending)
            for index, message in enumerate(self.events):
                if message.get("event") == name:
                    return self.events.pop(index).get("body", {})
            self.pump(deadline)

    def initialize(self):
        self.capabilities = self.call("initialize", {
            "clientID": "lathe-m0-probe", "adapterID": "lldb", "pathFormat": "path",
            "linesStartAt1": True, "columnsStartAt1": True,
            "supportsRunInTerminalRequest": False, "supportsVariableType": True,
            "supportsVariablePaging": True,
            # LLDB test-only extension was renamed in LLVM 21; unknown keys are ignored.
            "sourceInitFile": False, "$__lldb_sourceInitFile": False,
        })
        require(self.capabilities.get("supportsConfigurationDoneRequest") is True,
                "Adapter lacks configurationDone capability needed by this probe")

    def diagnostics(self):
        return (self.stderr.decode("utf-8", errors="replace") + "\n" + self.output)[-8192:]

    def summary(self):
        return {"capabilities": self.capabilities, "trace": list(self.trace),
                "reverseRequestsDenied": self.reverse_requests, "diagnostics": self.diagnostics(),
                "adapterCleanup": self.cleanup}

    def close(self, terminate_debuggee):
        if self.process.poll() is None:
            if not self.disconnected:
                try:
                    sequence = self.request("disconnect", {"terminateDebuggee": terminate_debuggee})
                    self.response(sequence, timeout=3)
                except (ProbeError, OSError):
                    pass
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                self.process.wait(timeout=3)
                self.cleanup = "exited"
            except subprocess.TimeoutExpired:
                self.cleanup = "terminated"
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.cleanup = "killed"
                    self.process.kill()
                    self.process.wait(timeout=2)
        else:
            self.cleanup = "already_exited"
        self.selector.close()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def classify(error, client=None):
    detail = str(error)
    if client:
        detail += "\n" + client.diagnostics()
    if isinstance(error, Unsupported):
        return "unsupported", detail
    if isinstance(error, AdapterRejected) and any(fragment in detail.lower() for fragment in AUTH_ERRORS):
        return "unsupported", detail
    return "fail", detail


def inspect_local(client, stopped):
    thread = stopped.get("threadId")
    require(isinstance(thread, int), "Stopped event lacks thread ID")
    frames = client.call("stackTrace", {"threadId": thread, "startFrame": 0, "levels": 20}).get("stackFrames", [])
    frame = next((item for item in frames if "inspectLocal" in item.get("name", "")), None)
    require(frame is not None, "Fixture inspectLocal frame was not found")
    require(isinstance(frame.get("id"), int), "Fixture frame lacks a valid handle")
    scopes = client.call("scopes", {"frameId": frame["id"]}).get("scopes", [])
    values = []
    for scope in scopes:
        if scope.get("variablesReference", 0) > 0:
            values += client.call("variables", {"variablesReference": scope["variablesReference"],
                                               "start": 0, "count": 100}).get("variables", [])
    value = next((item for item in values if item.get("name") == "probeValue"), None)
    require(value is not None, "probeValue is absent from local scopes")
    return {"threadId": thread, "frame": {key: frame.get(key) for key in ("name", "line", "source")},
            "variable": {key: value.get(key) for key in ("name", "value", "type")}}


def launch_probe(adapter, env, directory, executable, source):
    client = DAP(adapter, env, directory)
    result = {"status": "fail"}
    try:
        client.initialize()
        launch = client.request("launch", {"program": str(executable), "cwd": str(directory),
                                           "stopOnEntry": False, "runInTerminal": False})
        client.event("initialized", pending=launch)
        breakpoint_line = next(index for index, line in enumerate(source.read_text().splitlines(), 1)
                               if "LATHE_BREAKPOINT" in line)
        breakpoints = client.call("setBreakpoints", {"source": {"path": str(source)},
                                                    "breakpoints": [{"line": breakpoint_line}]}).get("breakpoints", [])
        require(len(breakpoints) == 1 and breakpoints[0].get("verified") is True,
                "Fixture breakpoint was not verified")
        client.call("configurationDone")
        client.response(launch)
        stopped = client.event("stopped")
        require(stopped.get("reason") == "breakpoint", "Fixture did not stop for breakpoint")
        before = inspect_local(client, stopped)
        require(before["variable"]["value"] == "41", "Expected initial probeValue=41")
        client.call("next", {"threadId": before["threadId"]})
        stepped = client.event("stopped")
        after = inspect_local(client, stepped)  # New frame/scopes/handles after the stop.
        require(after["variable"]["value"] == "42", "Expected stepped probeValue=42")
        client.call("continue", {"threadId": after["threadId"]})
        exited = client.event("exited")
        require(exited.get("exitCode") == 0, "Fixture exit code was not zero")
        client.event("terminated")
        require("lathe-probe-value=42" in client.output, "Fixture stdout was not observed")
        require(not client.reverse_requests, "Adapter required an unsupported reverse request")
        result.update(status="pass", breakpoint=breakpoints[0], beforeStep=before,
                      afterStep=after, exitCode=0)
    except (ProbeError, OSError, ValueError, TypeError, KeyError) as error:
        status, reason = classify(error, client)
        result.update(status=status, reason=reason)
    finally:
        client.close(terminate_debuggee=True)
        result.update(client.summary())
    return result


def heartbeat_value(path):
    try:
        return int(path.read_text())
    except (OSError, ValueError):
        return -1


def wait_heartbeat(target, path, after=-1):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        require(target.poll() is None, "Owned attach fixture exited unexpectedly")
        value = heartbeat_value(path)
        if value > after:
            return value
        time.sleep(0.03)
    raise ProbeError("Owned fixture heartbeat did not advance")


def attach_probe(adapter, env, directory, executable):
    heartbeat = directory / "owned-child-heartbeat"
    target = subprocess.Popen([str(executable), "--attach", str(heartbeat)], env=env,
                              cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    client = None
    result = {"status": "fail", "ownedTargetPID": target.pid,
              "ownership": "direct child retained until wait; no external PID accepted"}
    try:
        wait_heartbeat(target, heartbeat)
        client = DAP(adapter, env, directory)
        client.initialize()
        require(target.poll() is None, "Owned target exited before attach")
        attach = client.request("attach", {"pid": target.pid, "program": str(executable),
                                           "waitFor": False, "stopOnEntry": True})
        client.event("initialized", pending=attach)
        client.call("configurationDone")
        client.response(attach)
        stopped = client.event("stopped")
        thread = stopped.get("threadId")
        require(isinstance(thread, int), "Attach stopped event lacks thread ID")
        frames = client.call("stackTrace", {"threadId": thread, "startFrame": 0, "levels": 10}).get("stackFrames", [])
        require(frames, "Attach stack was empty")
        stopped_heartbeat = heartbeat_value(heartbeat)
        client.call("disconnect", {"terminateDebuggee": False})
        advanced = wait_heartbeat(target, heartbeat, after=stopped_heartbeat)
        require(not client.reverse_requests, "Attach required an unsupported reverse request")
        result.update(status="pass", stackFrameCount=len(frames),
                      survivedDetach=True, heartbeatBeforeDetach=stopped_heartbeat,
                      heartbeatAfterDetach=advanced)
    except (ProbeError, OSError, ValueError, TypeError, KeyError) as error:
        status, reason = classify(error, client)
        result.update(status=status, reason=reason)
    finally:
        if client:
            client.close(terminate_debuggee=False)
            result.update(client.summary())
        # Popen still owns this unreaped child; no user process/PID lookup is involved.
        if target.poll() is None:
            target.terminate()
            try:
                target.wait(timeout=3)
            except subprocess.TimeoutExpired:
                target.kill()
                target.wait(timeout=3)
        result["ownedTargetReaped"] = target.poll() is not None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write JSON report (also printed to stdout)")
    parser.add_argument("--allow-unsupported", action="store_true",
                        help="Exit 0 for missing toolchain or explicit debug authorization restriction; report stays unsupported")
    options = parser.parse_args()
    report = {"schemaVersion": 1, "probe": "lldb-dap-m0", "status": "fail",
              "os": platform.platform(), "architecture": platform.machine(),
              "scope": "Swift local fixture launch/step and owned-child attach/detach only"}
    with tempfile.TemporaryDirectory(prefix="lathe-dap-probe-") as temporary:
        directory = Path(temporary)
        env = clean_environment(directory)
        try:
            if sys.platform != "darwin":
                raise Unsupported("This probe requires macOS and a selected Xcode toolchain")
            try:
                adapter = run(["/usr/bin/xcrun", "--find", "lldb-dap"], env)
                compiler = run(["/usr/bin/xcrun", "--find", "swiftc"], env)
            except ProbeError as error:
                raise Unsupported(f"Toolchain discovery unavailable: {error}") from error
            report["toolchain"] = {"adapter": adapter, "compiler": compiler,
                                   "adapterVersion": run([adapter, "--version"], env),
                                   "compilerVersion": run([compiler, "--version"], env),
                                   "xcode": run(["/usr/bin/xcodebuild", "-version"], env)}
            try:
                report["toolchain"]["developerSecurityStatus"] = run(
                    ["/usr/sbin/DevToolsSecurity", "-status"], env)
            except (ProbeError, OSError, subprocess.SubprocessError) as error:
                report["toolchain"]["developerSecurityStatus"] = f"unavailable: {error}"
            sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env)
            report["toolchain"]["sdk"] = sdk
            source = Path(__file__).resolve().parent / "Fixtures" / "lldb-probe.swift"
            executable = directory / "lathe-lldb-fixture"
            run([compiler, "-g", "-Onone", "-sdk", sdk, "-module-cache-path", str(directory / "module-cache"),
                 str(source), "-o", str(executable)], env, timeout=60)
            report["fixtureSHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            report["artifactSHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            report["compile"] = "pass"
            report["launch"] = launch_probe(adapter, env, directory, executable, source)
            report["attach"] = attach_probe(adapter, env, directory, executable)
            statuses = {report["launch"]["status"], report["attach"]["status"]}
            report["status"] = "fail" if "fail" in statuses else "unsupported" if "unsupported" in statuses else "pass"
        except (ProbeError, OSError, subprocess.SubprocessError) as error:
            status, reason = classify(error)
            report.update(status=status, reason=reason)
    payload = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(payload)
    print(payload, end="")
    return 1 if report["status"] == "fail" else 2 if report["status"] == "unsupported" and not options.allow_unsupported else 0


if __name__ == "__main__":
    sys.exit(main())
