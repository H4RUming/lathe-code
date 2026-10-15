#!/usr/bin/env python3
"""Exercise the real runner control protocol and journal in disposable fixtures."""

import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import tempfile
import time
import uuid


class Invocation:
    def __init__(self, runner, root, name, executable="/bin/sleep", arguments=None,
                 environment=None, journal=None, protocol=1, **options):
        self.root = root / name
        self.root.mkdir()
        self.journal = journal or self.root / "journal"
        self.request = self.root / "request.json"
        command = {
            "executable": executable, "arguments": ["10"] if arguments is None else arguments,
            "workingDirectory": str(self.root), "environment": environment or {},
            "mode": "pipes", "timeoutSeconds": 3, "terminationGraceSeconds": 0.03,
            "outputLimitBytes": 65_536, "terminalColumns": 80, "terminalRows": 24,
        }
        command.update(options)
        self.request.write_text(json.dumps({"protocolVersion": protocol, "command": command}))
        self.process = subprocess.Popen([str(runner), "--request", str(self.request),
                                         "--journal", str(self.journal)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        for pipe, name in ((self.process.stdout, "stdout"), (self.process.stderr, "stderr")):
            os.set_blocking(pipe.fileno(), False)
            self.selector.register(pipe, selectors.EVENT_READ, name)
        self.pending = b""
        self.stderr = b""
        self.events = []
        self.intent = None
        self.total_bytes = 0

    def pump(self, timeout=0.05):
        for key, _ in self.selector.select(timeout):
            data = os.read(key.fileobj.fileno(), 65_536)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            self.total_bytes += len(data)
            assert self.total_bytes <= 2_097_152, "Runner protocol output exceeded harness bound"
            if key.data == "stderr":
                self.stderr += data
                continue
            self.pending += data
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                record = json.loads(line)
                assert record["protocolVersion"] == 1, record
                assert record["sequence"] == len(self.events) + 1, record
                assert isinstance(record["timestamp"], (int, float)), record
                if "started" in record["event"]:
                    # stdout can only expose start after the durable intent and
                    # initial event record exist. Inspect while the process lives.
                    self.intent = json.loads((self.journal / "intent.json").read_text())
                    journal_events = (self.journal / "events.ndjson").read_bytes().splitlines()
                    assert json.loads(journal_events[0]) == record
                    assert stat.S_IMODE(self.journal.stat().st_mode) == 0o700
                    assert stat.S_IMODE((self.journal / "intent.json").stat().st_mode) == 0o600
                self.events.append(record)

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            assert time.monotonic() < deadline, ("Runner fixture deadline exceeded", self.stderr.decode(errors="replace"))
            self.pump()
            if self.process.poll() is not None and not self.selector.get_map():
                assert predicate(), ("Runner exited prematurely", self.process.returncode,
                                     self.events, self.stderr.decode(errors="replace"))

    def started(self):
        self.until(lambda: any("started" in record["event"] for record in self.events))
        return self

    def send(self, value):
        self.raw(json.dumps(value).encode() + b"\n")

    def raw(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def output(self, stream):
        return b"".join(base64.b64decode(record["event"]["output"]["data"], validate=True)
                        for record in self.events if "output" in record["event"]
                        and record["event"]["output"]["stream"] == stream)

    def finish(self, code=0, reason="exited", status="finished"):
        self.until(lambda: self.process.poll() is not None and not self.selector.get_map())
        assert self.process.returncode == code, (self.process.returncode, self.stderr.decode(errors="replace"))
        assert not self.pending, "Partial trailing event frame"
        receipt = json.loads((self.journal / "result.json").read_text())
        assert receipt["status"] == status, receipt
        assert receipt["protocolVersion"] == 1
        assert receipt["invocationID"] == self.intent["invocationID"]
        assert receipt["result"]["reason"] == reason, receipt
        assert self.events[0]["event"].keys() == {"started"}
        assert self.events[-1]["event"].keys() == {"finished"}
        assert sum("finished" in item["event"] for item in self.events) == 1
        assert self.events[-1]["event"]["finished"]["_0"] == receipt["result"]
        journal_events = [json.loads(line) for line in (self.journal / "events.ndjson").read_text().splitlines()]
        assert journal_events == self.events, "Owner events differ from durable journal"
        assert sum(len(self.output(stream)) for stream in ("stdout", "stderr", "terminal")) == receipt["result"]["outputBytes"]
        for path in self.journal.iterdir():
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
        return receipt

    def rejected(self):
        self.until(lambda: self.process.poll() is not None and not self.selector.get_map())
        assert self.process.returncode == 1
        assert not self.events
        assert self.stderr, "Rejected invocation must provide a diagnostic"

    def close(self):
        if self.process.poll() is None:
            try:
                self.send({"action": "cancel"})
            except (OSError, ValueError):
                self.process.terminate()
            try:
                self.until(lambda: self.process.poll() is not None and not self.selector.get_map(), timeout=3)
            except Exception:
                self.process.kill()
                self.process.wait(timeout=3)
        self.selector.close()
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            pipe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    args = parser.parse_args()
    runner = args.runner.resolve()
    assert runner.is_file(), "Build lathe-runner first"
    invocations = []
    with tempfile.TemporaryDirectory(prefix="lathe-runner-smoke-") as temporary:
        root = Path(temporary).resolve()

        def start(name, *arguments, **options):
            invocation = Invocation(runner, root, name, *arguments, **options)
            invocations.append(invocation)
            return invocation

        try:
            sentinel = "fixture-environment-" + uuid.uuid4().hex
            journal = root / "durability" / "journal"
            script = 'test -f "$1/intent.json" || exit 42; printf "stdout fixture\\n"; printf "stderr fixture\\n" >&2'
            run = start("durability", "/bin/sh", ["-c", script, "fixture", str(journal)],
                        environment={"LATHE_FIXTURE_VALUE": sentinel}).started()
            run.finish()
            assert run.output("stdout") == b"stdout fixture\n"
            assert run.output("stderr") == b"stderr fixture\n"
            assert run.intent["environmentKeys"] == ["LATHE_FIXTURE_VALUE"]
            assert all(sentinel.encode() not in path.read_bytes() for path in journal.iterdir())
            print("PASS intent before side effect/start; private journal, redacted environment, events and receipt", flush=True)

            original = {path.name: path.read_bytes() for path in journal.iterdir()}
            reuse = start("reuse", "/bin/echo", ["must not execute"], journal=journal)
            reuse.rejected()
            assert {path.name: path.read_bytes() for path in journal.iterdir()} == original
            unsupported = start("unsupported-protocol", protocol=99)
            unsupported.rejected()
            assert not unsupported.journal.exists()
            print("PASS reused journal and unsupported protocol rejected without replay", flush=True)

            failed = start("spawn-failure", str(root / "missing-executable"), [])
            failed.rejected()
            receipt = json.loads((failed.journal / "result.json").read_text())
            assert receipt["status"] == "failed" and receipt.get("result") is None
            assert json.loads((failed.journal / "intent.json").read_text())["protocolVersion"] == 1
            assert not (failed.journal / "events.ndjson").read_bytes()
            print("PASS spawn failure retains intent and a failed receipt without started event", flush=True)

            data = bytes([0, 1, 2, 10, 255, 254, 128]) + "UTF-8 입력\n".encode()
            run = start("binary-input", "/bin/cat", []).started()
            run.send({"action": "input", "data": base64.b64encode(data).decode()})
            run.send({"action": "eof"})
            run.finish()
            assert run.output("stdout") == data
            print("PASS base64 input and target EOF preserve arbitrary bytes", flush=True)

            run = start("renamed-journal", "/bin/cat", []).started()
            original_path = run.journal
            moved_path = run.root / "original-journal-moved"
            original_path.rename(moved_path)
            original_path.mkdir()
            replacement = original_path / "untouched.txt"
            replacement.write_text("replacement directory fixture")
            run.journal = moved_path
            run.send({"action": "input", "data": base64.b64encode(b"after rename\n").decode()})
            run.send({"action": "eof"})
            run.finish()
            assert run.output("stdout") == b"after rename\n"
            assert list(original_path.iterdir()) == [replacement]
            assert replacement.read_text() == "replacement directory fixture"
            print("PASS journal directory replacement cannot redirect retained result/event file descriptors", flush=True)

            run = start("owner-eof").started()
            run.process.stdin.close()
            run.finish(code=130, reason="cancelled")
            run = start("cancel").started()
            run.send({"action": "cancel"})
            run.finish(code=130, reason="cancelled")
            run = start("timeout", timeoutSeconds=0.15).started()
            run.finish(code=124, reason="timedOut")
            print("PASS owner EOF, explicit cancellation and timeout have durable distinct results", flush=True)

            run = start("output-limit", "/usr/bin/yes", [], outputLimitBytes=1025).started()
            receipt = run.finish(code=125, reason="outputLimit")
            assert receipt["result"]["outputBytes"] == 1025
            print("PASS output limit bounds streamed and journaled bytes exactly", flush=True)

            for name, control in (("invalid-json", b"not json\n"),
                                  ("unknown-control", b'{"action":"not-an-action"}\n'),
                                  ("invalid-base64", b'{"action":"input","data":"!!!"}\n')):
                run = start(name).started()
                run.raw(control)
                receipt = run.finish(code=1, reason="cancelled", status="failed")
                assert "Control channel failed" in receipt["error"]
            print("PASS malformed controls cancel and persist failed receipts", flush=True)

            for name, close_reader in (("owner-backpressure", False), ("owner-disconnected", True)):
                run = start(name, "/usr/bin/yes", [], outputLimitBytes=4_194_304,
                            timeoutSeconds=8).started()
                run.selector.unregister(run.process.stdout)
                if close_reader:
                    run.process.stdout.close()
                start_time = time.monotonic()
                run.until(lambda: run.process.poll() is not None and not run.selector.get_map())
                assert time.monotonic() - start_time < 4, "Failed owner channel did not stop execution promptly"
                assert run.process.returncode == 1, run.stderr.decode(errors="replace")
                receipt = json.loads((run.journal / "result.json").read_text())
                assert receipt["status"] == "failed" and receipt["error"]
                assert receipt["result"]["reason"] == "cancelled", receipt
            print("PASS blocked or disconnected event consumer cancels target and retains failure receipt", flush=True)

            script = ('test -t 0 && test -t 1 && test -t 2 || exit 21; '
                      ': </dev/tty || exit 22; printf READY; read line; '
                      '/bin/stty size; printf "GOT:%s\\n" "$line"')
            run = start("pty", "/bin/sh", ["-c", script], mode="pty",
                        environment={"TERM": "xterm-256color"}).started()
            run.until(lambda: b"READY" in run.output("terminal"))
            run.send({"action": "resize", "columns": 103, "rows": 37})
            run.send({"action": "input", "data": base64.b64encode(b"hello terminal\n").decode()})
            run.finish()
            assert b"37 103" in run.output("terminal")
            assert b"GOT:hello terminal" in run.output("terminal")
            assert not run.output("stdout") and not run.output("stderr")
            print("PASS controlling PTY, resize and input through helper protocol", flush=True)
        finally:
            for invocation in reversed(invocations):
                invocation.close()
    print("PASS runner helper integration smoke", flush=True)


if __name__ == "__main__":
    main()
