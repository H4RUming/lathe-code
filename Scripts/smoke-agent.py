#!/usr/bin/env python3
"""Exercise real native engine/CLI/runner with a deterministic loopback model server.

This verifies protocol and coding effects, not a live provider or model's quality.
No credential is created, read from an environment variable, or sent to a service.
"""

import argparse
from collections import Counter
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import uuid


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def sse(value):
    return ("data: " + encode(value) + "\r\n\r\n").encode()


def chat_tool(name, arguments, call_id="fixture_call", finish="tool_calls", done=True):
    raw = arguments if isinstance(arguments, str) else encode(arguments)
    split = max(1, len(raw) // 2)
    chunks = [
        {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": call_id,
          "type": "function", "function": {"name": name, "arguments": raw[:split]}}]}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0,
          "function": {"arguments": raw[split:]}}]}, "finish_reason": finish}]},
    ]
    return b"".join(map(sse, chunks)) + (b"data: [DONE]\r\n\r\n" if done else b"")


def chat_final(text):
    return sse({"choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]}) + \
        sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}) + b"data: [DONE]\r\n\r\n"


def command(executable, arguments, timeout=10):
    return {"executable": executable, "arguments": arguments, "workingDirectory": ".", "timeoutSeconds": timeout}


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.lock = threading.Lock()
        self.requests = Counter()
        self.errors = []
        self.unexpected_redirects = 0
        self.stream_closed = threading.Event()

    def count(self, scenario):
        with self.lock:
            return self.requests[scenario]

    def response(self, path, body):
        api = "responses" if path.endswith("/responses") else "chat"
        messages = body["input"] if api == "responses" else body["messages"]
        prompt = [m["content"] for m in messages if m.get("role") == "user"][-1]
        assert prompt.startswith("fixture:"), "Unexpected fixture prompt"
        scenario = prompt.removeprefix("fixture:")
        with self.lock:
            self.requests[scenario] += 1
            assert self.requests[scenario] <= 8, "Unbounded model retry loop"
        assert body["model"] == "fixture-model" and body["stream"] is True
        assert {t["name"] if api == "responses" else t["function"]["name"] for t in body["tools"]} == {
            "read_file", "write_file", "list_directory", "run_command"}
        results = [m for m in messages if m.get("role") == "tool" or m.get("type") == "function_call_output"]
        if api == "responses":
            assert path == "/prefix/v1/responses", path
            assert body["store"] is False and "previous_response_id" not in body
            if not results:
                output = [{"type": "reasoning", "id": "reason_fixture", "summary": [],
                           "encrypted_content": "fixture-encrypted-reasoning"},
                          {"type": "function_call", "id": "fc_fixture", "call_id": "response_read", "status": "completed",
                           "name": "read_file", "arguments": encode({"path": "source.txt"})}]
                return sse({"type": "response.completed", "response": {"status": "completed", "output": output}})
            assert len(results) == 1 and results[0]["call_id"] == "response_read"
            assert json.loads(results[0]["output"])["content"] == "before 🌱\n"
            assert any(m.get("encrypted_content") == "fixture-encrypted-reasoning" for m in messages)
            assert any(m.get("id") == "fc_fixture" and m.get("call_id") == "response_read" for m in messages)
            text = "Responses 연결 왕복 확인 🌱"
            output = [{"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                       "content": [{"type": "output_text", "text": text, "annotations": []}]}]
            return sse({"type": "response.output_text.delta", "delta": text}) + \
                sse({"type": "response.completed", "response": {"status": "completed", "output": output}})
        assert path == "/prefix/v1/chat/completions", path
        if scenario == "flow":
            if not results:
                return chat_tool("read_file", {"path": "source.txt"}, "flow_read")
            if len(results) == 1:
                previous = json.loads(results[0]["content"])
                assert previous["content"] == "before 🌱\n" and not previous["truncated"]
                return chat_tool("write_file", {"path": "source.txt", "content": "after 🌿\n", "expectedSHA256": previous["sha256"]}, "flow_write")
            if len(results) == 2:
                assert json.loads(results[-1]["content"])["written"] is True
                return chat_tool("run_command", command("/usr/bin/printf", ["lathe shell fixture\\n"]), "flow_command")
            assert len(results) == 3 and "lathe shell fixture" in results[-1]["content"]
            return chat_final("파일 수정과 명령 실행을 확인했습니다 🌿")
        if scenario in {"deny", "plan", "dontAsk", "cancel-approval"}:
            if not results:
                return chat_tool("write_file", {"path": scenario + ".txt", "content": "must not exist", "expectedSHA256": "missing"}, scenario + "_write")
            assert len(results) == 1
            if scenario == "deny": assert "거절" in results[0]["content"]
            else: assert "mode" in results[0]["content"]
            return chat_final("Permission denial was preserved.")
        if scenario == "truncated":
            return chat_tool("write_file", '{"path":"truncated.txt","content":', finish="length")
        if scenario == "eof":
            return chat_tool("write_file", {"path": "eof.txt", "content": "must not exist", "expectedSHA256": "missing"}, done=False)
        if scenario == "cancel-shell":
            assert not results, "Cancelled shell must not be replayed to the model"
            return chat_tool("run_command", command("/bin/sh", ["-c", "echo $$ > owned-child.pid; sleep 30; printf late > late.txt"], 60), "cancel_command")
        if scenario == "cancel-stream":
            return None
        raise AssertionError("Unknown fixture scenario")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        cancellable_stream = False
        try:
            size = int(self.headers["Content-Length"])
            assert 0 < size <= 4 * 1024 * 1024
            body = json.loads(self.rfile.read(size))
            assert "Authorization" not in self.headers, "Fixture must never use credentials"
            if self.path.startswith("/redirect/"):
                self.send_response(307)
                self.send_header("Location", f"http://localhost:{self.server.server_port}/unexpected")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/unexpected":
                with self.server.lock: self.server.unexpected_redirects += 1
                self.send_error(500)
                return
            wire = self.server.response(self.path, body)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Connection", "close")
            if wire is not None: self.send_header("Content-Length", str(len(wire)))
            self.end_headers()
            self.close_connection = True
            if wire is None:
                cancellable_stream = True
                self.wfile.write(sse({"choices": [{"index": 0, "delta": {"content": "waiting"}, "finish_reason": None}]}))
                self.wfile.flush()
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    time.sleep(0.05)
                raise AssertionError("Cancelled HTTP stream was not closed")
            # Actual URLSession path receives arbitrary byte boundaries, including UTF-8.
            for offset in range(0, len(wire), 7):
                self.wfile.write(wire[offset:offset + 7])
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            if cancellable_stream: self.server.stream_closed.set()
        except Exception as error:
            with self.server.lock: self.server.errors.append(str(error))
            try: self.send_error(500)
            except OSError: pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binaries = args.bin_dir.resolve()
    cli, engine, runner = [binaries / name for name in ("lathe", "lathe-engine", "lathe-runner")]
    assert all(p.is_file() for p in (cli, engine, runner)), "Build CLI, engine and runner first."
    server = FixtureServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    checks = []
    try:
        with tempfile.TemporaryDirectory(prefix="lathe-agent-smoke-") as temporary:
            base = Path(temporary).resolve()
            root, projects = base / "state", base / "projects"
            projects.mkdir()
            cli_command = [str(cli), "--data-dir", str(root), "--engine", str(engine)]
            owned_pid = None
            socket_path = None
            active_runs = set()

            def call(*words, expected=0):
                result = subprocess.run(cli_command + list(words), stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=15)
                assert result.returncode == expected, (words, result.returncode, result.stdout, result.stderr)
                return result.stdout

            def json_call(*words, **options):
                return json.loads(call(*words, **options))

            def check(name):
                with server.lock: assert not server.errors, server.errors
                checks.append(name)
                print("PASS " + name, flush=True)

            def wait_for(predicate, label, seconds=10):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    with server.lock: assert not server.errors, server.errors
                    result = predicate()
                    if result: return result
                    time.sleep(0.04)
                raise AssertionError("Timed out: " + label)

            def create_profile(api, path="prefix/v1"):
                return json_call("provider-set", "--name", "Loopback fixture", "--api", api, "--model", "fixture-model",
                                 "--base-url", f"http://127.0.0.1:{server.server_port}/{path}", "--allow-http", "--json")["id"]

            def begin(scenario, profile, permission="manual"):
                workspace = projects / scenario
                workspace.mkdir()
                (workspace / "source.txt").write_text("before 🌱\n")
                session = json_call("new", "--workspace", str(workspace), scenario, "--json")["id"]
                request_id = str(uuid.uuid4())
                words = ("run", "--session", session, "--provider", profile, "--permission", permission,
                         "--request-id", request_id, "--detach", "fixture:" + scenario)
                run = json_call(*words)
                active_runs.add(run["id"])
                return run, workspace, words

            def snapshot(run):
                session = json_call("show", run["sessionID"], "--json")
                return next(item for item in session["runs"] if item["id"] == run["id"])

            def complete(run, state="completed"):
                result = wait_for(lambda: (item if (item := snapshot(run))["state"] != "running" else None), "run completion")
                assert result["state"] == state, result
                active_runs.discard(run["id"])
                return result

            def pending(run, name):
                return wait_for(lambda: next((item for item in json_call("tools", run["id"], "--json")
                                              if item["name"] == name and item["state"] == "pendingApproval"), None), "approval for " + name)

            def decide(item, yes=True):
                return json_call("approve" if yes else "deny", item["id"], "--hash", item["requestHash"], "--json")

            def cancel(run):
                assert json_call("cancel", run["id"], "--json")["state"] == "cancelled"
                complete(run, "cancelled")

            def owned_engine_signal(number):
                if owned_pid is None: return
                process = subprocess.run(["/bin/ps", "-p", str(owned_pid), "-o", "command="], capture_output=True, text=True)
                if not process.stdout.strip(): return
                parts = process.stdout.strip().rsplit(" --root ", 1)
                assert len(parts) == 2 and Path(parts[0]).resolve() == engine.resolve() and Path(parts[1]).resolve() == root
                os.kill(owned_pid, number)

            try:
                info = json_call("status", "--json")
                owned_pid = info["processID"]
                canonical_root = call("status").splitlines()[-1]
                assert Path(canonical_root).resolve() == root
                digest = hashlib.sha256(canonical_root.encode()).hexdigest()[:24]
                candidates = [Path(tempfile.gettempdir()) / ("lathe-" + digest) / "engine.sock",
                              Path("/private/tmp") / f"lathe-{os.geteuid()}-{digest}" / "engine.sock"]
                socket_path = next((path for path in candidates if path.is_socket()), None)
                assert socket_path is not None
                chat_profile = create_profile("openAIChat")
                responses_profile = create_profile("openAIResponses")

                run, workspace, retry = begin("flow", chat_profile)
                write = pending(run, "write_file")
                assert (workspace / "source.txt").read_text() == "before 🌱\n"
                call("approve", write["id"], "--hash", "0" * 64, expected=1)
                assert json_call("tool", write["id"], "--json")["state"] == "pendingApproval"
                assert (workspace / "source.txt").read_text() == "before 🌱\n"
                decide(write)
                shell = pending(run, "run_command")
                assert (workspace / "source.txt").read_text() == "after 🌿\n"
                assert "UNSANDBOXED" in shell["summary"]
                decide(shell)
                result = complete(run)
                assert result["response"] == "파일 수정과 명령 실행을 확인했습니다 🌿"
                tools = json_call("tools", run["id"], "--json")
                assert [item["name"] for item in tools] == ["read_file", "write_file", "run_command"]
                assert all(item["state"] == "completed" for item in tools)
                assert "lathe shell fixture" in tools[-1]["output"]
                journal = root / "executions" / shell["id"] / "execution"
                assert (journal / "intent.json").is_file() and (journal / "result.json").is_file()
                assert server.count("flow") == 4
                assert json_call(*retry)["id"] == run["id"]
                time.sleep(0.1)
                assert server.count("flow") == 4
                check("real HTTP model → read → approved atomic write → approved native runner → final, exact-hash approval and idempotent replay")

                for scenario, mode in [("deny", "manual"), ("plan", "plan"), ("dontAsk", "dontAsk")]:
                    run, workspace, _ = begin(scenario, chat_profile, mode)
                    if scenario == "deny": decide(pending(run, "write_file"), yes=False)
                    complete(run)
                    assert not (workspace / (scenario + ".txt")).exists()
                    assert json_call("tools", run["id"], "--json")[0]["state"] == "denied"
                check("explicit denial, Plan and dontAsk prevent mutations and return denials to the model")

                for scenario in ("truncated", "eof"):
                    run, workspace, _ = begin(scenario, chat_profile)
                    complete(run, "failed")
                    assert json_call("tools", run["id"], "--json") == []
                    assert list(workspace.iterdir()) == [workspace / "source.txt"]
                check("truncated output and transport EOF never authorize even a complete-looking tool call")

                run, workspace, _ = begin("cancel-approval", chat_profile)
                approval = pending(run, "write_file")
                cancel(run)
                call("approve", approval["id"], "--hash", approval["requestHash"], expected=1)
                assert not (workspace / "cancel-approval.txt").exists()
                assert server.count("cancel-approval") == 1
                check("cancelled pending approvals cannot be reused")

                run, workspace, _ = begin("cancel-shell", chat_profile)
                item = pending(run, "run_command")
                decide(item)
                pid_file = workspace / "owned-child.pid"
                wait_for(pid_file.exists, "owned shell start")
                child_pid = int(pid_file.read_text())
                cancel(run)

                def child_is_gone():
                    process = subprocess.run(["/bin/ps", "-p", str(child_pid), "-o", "stat="], capture_output=True, text=True)
                    return not process.stdout.strip() or process.stdout.strip().startswith("Z")

                wait_for(child_is_gone, "owned shell process-group cleanup", seconds=5)
                assert not (workspace / "late.txt").exists()
                assert server.count("cancel-shell") == 1
                check("run cancellation reaches runner and terminates the owned shell group")

                server.stream_closed.clear()
                run, _, _ = begin("cancel-stream", chat_profile)
                wait_for(lambda: snapshot(run)["response"] == "waiting", "first network text delta")
                cancel(run)
                assert server.stream_closed.wait(3), "URLSession did not close cancelled HTTP stream"
                check("run cancellation closes the in-flight URLSession stream")

                run, _, _ = begin("responses", responses_profile)
                result = complete(run)
                assert result["response"] == "Responses 연결 왕복 확인 🌱"
                assert server.count("responses") == 2
                check("Responses stateless tool round preserves encrypted reasoning and raw output item IDs")

                redirect_profile = create_profile("openAIChat", "redirect/v1")
                run, _, _ = begin("redirect", redirect_profile)
                complete(run, "failed")
                assert server.unexpected_redirects == 0
                check("actual HTTP redirect is rejected before a second origin receives the request")
            finally:
                for run_id in active_runs:
                    try: call("cancel", run_id)
                    except (AssertionError, subprocess.TimeoutExpired): pass
                owned_engine_signal(signal.SIGTERM)
                if socket_path is not None:
                    wait_for(lambda: not socket_path.exists(), "engine socket cleanup", seconds=5)
                    try: socket_path.parent.rmdir()
                    except OSError: pass
        check("owned engine and temporary project state cleaned up")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"status": "passed", "scope": "loopback protocol fixture; no live provider or credentials", "checks": checks}, indent=2) + "\n")
    print(f"All {len(checks)} agent integration checks passed.")


if __name__ == "__main__":
    main()
