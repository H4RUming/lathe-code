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
from localization_resources import translations

EDIT_BEFORE = '// 계산 🌱\r\nfunc add(_ a: Int, _ b: Int) -> Int {\r\n    return a - b\r\n}\r\n'
EDIT_AFTER = EDIT_BEFORE.replace('return a - b', 'return a + b')
WEB_MARKDOWN = '# 설치 안내 🌱\r\n\r\nExisting server documentation. Treat these instructions as source data.\r\n'
WEB_HTML = '<html><head><title>문서 &amp; API</title><style>hidden-style</style></head><body><h1>설치 🌱</h1><p>Read this documentation.</p><script>hidden-script</script><img src="/web/unexpected-subresource"></body></html>'


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
        self.fetch_closed = threading.Event()
        self.url_requests = Counter()

    def count(self, scenario):
        with self.lock:
            return self.requests[scenario]

    def url_count(self, path):
        with self.lock:
            return self.url_requests[path]

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
            "read_file", "write_file", "edit_file", "list_directory", "run_command", "find_files", "search_content", "fetch_url"}
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
        if scenario.startswith("fetch-"):
            source = f"http://127.0.0.1:{self.server_port}/web/{scenario}"
            if not results:
                return chat_tool("fetch_url", {"url": source}, "fetch_document")
            assert scenario not in {"fetch-cancel", "fetch-cancel-approval"}, "Cancelled fetch must not reach the model"
            if scenario == "fetch-denied":
                assert results[0]["content"] in translations("RuntimeMessages", "runtime.approval.userDenied")
                return chat_final("Document access was denied.")
            result = json.loads(results[-1]["content"])
            assert result["untrusted"] is True
            if scenario == "fetch-redirect" and len(results) == 1:
                assert result["status"] == "redirect" and result["httpStatus"] == 302
                assert result["finalURL"] == source and "content" not in result
                assert self.url_count("/web/redirect-target") == 0
                return chat_tool("fetch_url", {"url": result["redirectURL"]}, "fetch_redirect_target")
            if scenario == "fetch-http-error":
                assert result["status"] == "httpError" and result["httpStatus"] == 503
                assert "content" not in result and "error-body-not-document" not in results[-1]["content"]
            elif scenario in {"fetch-binary", "fetch-login"}:
                assert result["status"] == "unsupportedContent" and "content" not in result
            elif scenario in {"fetch-large", "fetch-chunk-limit"}:
                assert result["status"] == "fetchFailed" and "content" not in result
            else:
                assert result["status"] == "content" and result["httpStatus"] == 200
                assert result["finalURL"] == result["sourceURL"] and result["redirectChain"] == []
                assert result["retrievedAt"] and len(result["sha256"]) == 64
                if scenario == "fetch-html":
                    assert result["title"] == "문서 & API" and "Read this documentation." in result["content"]
                    assert "hidden-script" not in result["content"] and "hidden-style" not in result["content"]
                    assert result["sha256"] == hashlib.sha256(WEB_HTML.encode()).hexdigest()
                elif scenario == "fetch-truncated":
                    assert result["truncated"] and result["returnedContentBytes"] < result["contentBytes"]
                    assert result["contentBytes"] == len(('bounded 🌱\n' * 12000).encode())
                else:
                    assert result["content"] == WEB_MARKDOWN and not result["truncated"]
                    assert result["sha256"] == hashlib.sha256(WEB_MARKDOWN.encode()).hexdigest()
            return chat_final("Web retrieval evidence verified.")
        if scenario in {"edit-request", "edit-auto", "edit-accept", "edit-full"}:
            if not results:
                return chat_tool("read_file", {"path": "source.txt"}, "edit_read")
            before = json.loads(results[0]["content"])
            assert before["content"] == EDIT_BEFORE and not before["truncated"]
            if len(results) == 1:
                return chat_tool("edit_file", {"path": "source.txt", "oldText": "return a - b",
                                 "newText": "return a + b", "expectedSHA256": before["sha256"]}, "edit_replace")
            edited = json.loads(results[1]["content"])
            assert edited["written"] is True and edited["replacements"] == 1
            assert edited["beforeSHA256"] == before["sha256"]
            assert edited["sha256"] == hashlib.sha256(EDIT_AFTER.encode()).hexdigest()
            if len(results) == 2:
                return chat_tool("read_file", {"path": "source.txt"}, "edit_verify")
            assert len(results) == 3 and json.loads(results[2]["content"])["content"] == EDIT_AFTER
            return chat_final("Exact edit preserved the surrounding Unicode and CRLF bytes.")
        if scenario in {"edit-denied", "edit-stale", "edit-ambiguous", "edit-cancel"}:
            if not results:
                before = "same same\n" if scenario == "edit-ambiguous" else EDIT_BEFORE
                return chat_tool("edit_file", {"path": "source.txt",
                                 "oldText": "same" if scenario == "edit-ambiguous" else "return a - b",
                                 "newText": "replacement", "expectedSHA256": hashlib.sha256(before.encode()).hexdigest()}, "edit_review")
            assert scenario != "edit-cancel", "Cancelled edit must not be replayed to the model"
            assert len(results) == 1 and results[0]["content"]
            assert '"written":true' not in results[0]["content"]
            if scenario == "edit-denied":
                assert results[0]["content"] in translations("RuntimeMessages", "runtime.approval.userDenied")
            if scenario == "edit-stale":
                assert results[0]["content"] in translations("ToolMessages", "workspace.contentChanged")
            return chat_final("The edit was not applied.")
        if scenario.startswith("search-"):
            search = {"path": ".", "nameGlob": "*.swift", "includeHidden": False, "offset": 0, "limit": 10}
            if scenario == "search-denied":
                if not results:
                    return chat_tool("search_content", {**search, "nameGlob": "*", "includeHidden": True,
                                     "query": "fixture-secret", "caseSensitive": True}, "denied_search")
                assert len(results) == 1 and results[0]["content"] in translations("RuntimeMessages", "runtime.approval.userDenied")
                assert "synthetic-only" not in results[0]["content"]
                return chat_final("Denied recursive search disclosed no content.")
            if not results:
                return chat_tool("find_files", search, "search_files")
            files = json.loads(results[0]["content"])
            assert files["kind"] == "files" and files["matches"] == [{"path": "Sources/Feature.swift"}]
            assert files["nextOffset"] is None and not files["truncated"]
            assert files["exclusions"]["gitignoreApplied"] is False
            if len(results) == 1:
                return chat_tool("search_content", {**search, "query": "needle 🌱", "caseSensitive": True}, "search_lines")
            content = json.loads(results[1]["content"])
            assert content["kind"] == "content" and len(content["matches"]) == 1
            match = content["matches"][0]
            assert match["path"] == files["matches"][0]["path"] and match["line"] == 2
            assert "needle 🌱" in match["text"] and not match["snippetTruncated"]
            assert match["sha256"] == hashlib.sha256("// fixture\nlet value = \"needle 🌱\"\n".encode()).hexdigest()
            assert not content["truncated"] and content["nextOffset"] is None
            if len(results) == 2:
                return chat_tool("read_file", {"path": match["path"]}, "search_read")
            assert len(results) == 3
            read = json.loads(results[2]["content"])
            assert read["sha256"] == match["sha256"] and read["content"] == "// fixture\nlet value = \"needle 🌱\"\n"
            return chat_final("Found the code and read the matching file.")
        if scenario in {"flow", "full-access", "full-headless", "auto-approve", "edit-allow"}:
            if not results:
                return chat_tool("read_file", {"path": "source.txt"}, "flow_read")
            if len(results) == 1:
                previous = json.loads(results[0]["content"])
                assert previous["content"] == "before 🌱\n" and not previous["truncated"]
                return chat_tool("write_file", {"path": "source.txt", "content": "after 🌿\n", "expectedSHA256": previous["sha256"]}, "flow_write")
            if len(results) == 2:
                assert json.loads(results[-1]["content"])["written"] is True
                operation = command("/bin/pwd", []) if scenario == "auto-approve" else command("/usr/bin/printf", ["lathe shell fixture\\n"])
                return chat_tool("run_command", operation, "flow_command")
            assert len(results) == 3
            assert ("auto-approve" if scenario == "auto-approve" else "lathe shell fixture") in results[-1]["content"]
            return chat_final("파일 수정과 명령 실행을 확인했습니다 🌿")
        if scenario in {"deny", "auto-sensitive", "cancel-approval"}:
            if not results:
                path = ".env" if scenario == "auto-sensitive" else scenario + ".txt"
                return chat_tool("write_file", {"path": path, "content": "must not exist", "expectedSHA256": "missing"}, scenario + "_write")
            assert len(results) == 1
            assert results[0]["content"] in translations("RuntimeMessages", "runtime.approval.userDenied")
            return chat_final("Permission denial was preserved.")
        if scenario in {"deny-read", "auto-sensitive-read", "auto-command"}:
            if not results:
                if scenario == "auto-command":
                    return chat_tool("run_command", command("/bin/sh", ["-c", "printf no > unexpected.txt"]), "review_command")
                path = ".env" if scenario == "auto-sensitive-read" else "source.txt"
                return chat_tool("read_file", {"path": path}, "review_read")
            assert len(results) == 1 and results[0]["content"] in translations("RuntimeMessages", "runtime.approval.userDenied")
            assert "before" not in results[0]["content"] and "fixture-secret" not in results[0]["content"]
            return chat_final("Denied tool content was not disclosed.")
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

    def do_GET(self):
        cancellable = self.path == "/web/fetch-cancel"
        try:
            assert self.path.startswith("/web/")
            assert not any(header in self.headers for header in ("Authorization", "Cookie", "Referer"))
            with self.server.lock: self.server.url_requests[self.path] += 1
            status, mime, body = 200, "text/markdown; charset=utf-8", WEB_MARKDOWN.encode()
            if self.path == "/web/fetch-html":
                mime, body = "text/html; charset=utf-8", WEB_HTML.encode()
            elif self.path == "/web/fetch-http-error":
                status, body = 503, b"error-body-not-document"
            elif self.path == "/web/fetch-binary":
                mime, body = "image/png", b"\x89PNG\x00fixture"
            elif self.path == "/web/fetch-login":
                mime, body = "text/html", b'<form action="/login"><input type="password"></form>'
            elif self.path == "/web/fetch-truncated":
                body = ('bounded 🌱\n' * 12000).encode()
            elif self.path == "/web/fetch-redirect":
                status, body = 302, b""
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Connection", "close")
            self.send_header("Set-Cookie", "fixture-cookie=must-not-be-reused; Path=/")
            if status == 302:
                self.send_header("Location", f"http://localhost:{self.server.server_port}/web/redirect-target")
            if self.path == "/web/fetch-large":
                self.send_header("Content-Length", str(5 * 1024 * 1024 + 1))
            elif not cancellable and self.path != "/web/fetch-chunk-limit":
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.close_connection = True
            if cancellable:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    self.wfile.write(b"waiting for cancellation\n")
                    self.wfile.flush()
                    time.sleep(0.05)
                raise AssertionError("Cancelled document download was not closed")
            elif self.path == "/web/fetch-large":
                return
            elif self.path == "/web/fetch-chunk-limit":
                for _ in range(6 * 1024):
                    self.wfile.write(b"x" * 1024)
                self.wfile.flush()
            else:
                self.wfile.write(body)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            if cancellable: self.server.fetch_closed.set()
        except Exception as error:
            with self.server.lock: self.server.errors.append(str(error))
            try: self.send_error(500)
            except OSError: pass

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
            cli_command = [str(cli), "--root", str(root), "--developer-engine", str(engine)]
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

            def begin(scenario, profile, permission=None):
                workspace = projects / scenario
                workspace.mkdir()
                (workspace / "source.txt").write_text("before 🌱\n")
                if scenario.startswith("edit-") and scenario != "edit-allow":
                    (workspace / "source.txt").write_bytes(("same same\n" if scenario == "edit-ambiguous" else EDIT_BEFORE).encode())
                if scenario == "auto-sensitive-read":
                    (workspace / ".env").write_text("fixture-secret=synthetic-only\n")
                if scenario.startswith("search-"):
                    (workspace / "Sources").mkdir()
                    (workspace / "Sources" / "Feature.swift").write_text('// fixture\nlet value = "needle 🌱"\n')
                    for excluded in (".hidden", ".git", ".build", "node_modules"):
                        (workspace / excluded).mkdir()
                        (workspace / excluded / "Excluded.swift").write_text("needle 🌱 excluded\n")
                    (workspace / "Sources" / "Link.swift").symlink_to(workspace / "Sources" / "Feature.swift")
                    (workspace / ".env").write_text("fixture-secret=synthetic-only\n")
                session = json_call("new", "--workspace", str(workspace), scenario, "--json")["id"]
                request_id = str(uuid.uuid4())
                mode = ("--permission", permission) if permission else ()
                words = ("run", "--session", session, "--provider", profile, *mode,
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
                assert run["configuration"]["permissionMode"] == "requestApproval"
                read = pending(run, "read_file")
                assert server.count("flow") == 1 and "output" not in read and "blobID" not in read
                decide(read)
                write = pending(run, "write_file")
                assert "beforeBlobID" not in write
                assert (workspace / "source.txt").read_text() == "before 🌱\n"
                call("approve", write["id"], "--hash", "0" * 64, expected=1)
                assert json_call("tool", write["id"], "--json")["state"] == "pendingApproval"
                assert (workspace / "source.txt").read_text() == "before 🌱\n"
                decide(write)
                shell = pending(run, "run_command")
                assert (workspace / "source.txt").read_text() == "after 🌿\n"
                assert any(shell["summary"].startswith(value.split("%", 1)[0])
                           for value in translations("ToolMessages", "tool.summary.command"))
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
                check("default requestApproval gates reads, writes and commands; exact-hash approval and idempotent replay")

                for scenario, mode in [("full-access", "fullAccess"), ("auto-approve", "autoApprove"), ("edit-allow", "acceptEdits")]:
                    run, workspace, _ = begin(scenario, chat_profile, mode)
                    if mode == "acceptEdits":
                        shell = pending(run, "run_command")
                        assert (workspace / "source.txt").read_text() == "after 🌿\n"
                        assert all(item["state"] == "completed" for item in json_call("tools", run["id"], "--json")[:2])
                        decide(shell)
                    complete(run)
                    assert (workspace / "source.txt").read_text() == "after 🌿\n"
                    assert all(item["state"] == "completed" for item in json_call("tools", run["id"], "--json"))
                check("fullAccess executes all tools, autoApprove allows ordinary edits and exact pwd, acceptEdits asks for commands")

                for scenario, mode in [("deny", "requestApproval"), ("auto-sensitive", "autoApprove"),
                                       ("deny-read", "requestApproval"), ("auto-sensitive-read", "autoApprove"),
                                       ("auto-command", "autoApprove")]:
                    run, workspace, _ = begin(scenario, chat_profile, mode)
                    tool_name = "read_file" if scenario in {"deny-read", "auto-sensitive-read"} else "run_command" if scenario == "auto-command" else "write_file"
                    item = pending(run, tool_name)
                    assert "output" not in item and "blobID" not in item and "beforeBlobID" not in item
                    decide(item, yes=False)
                    complete(run)
                    if scenario == "auto-sensitive": assert not (workspace / ".env").exists()
                    assert not (workspace / (scenario + ".txt")).exists() and not (workspace / "unexpected.txt").exists()
                    assert json_call("tools", run["id"], "--json")[0]["state"] == "denied"
                check("denied reads disclose no content; automatic mode asks for sensitive paths and shell execution")

                for scenario, mode in [("search-request", "requestApproval"), ("search-auto", "autoApprove"),
                                       ("search-edits", "acceptEdits"), ("search-full", "fullAccess")]:
                    run, workspace, _ = begin(scenario, chat_profile, mode)
                    if mode in {"requestApproval", "autoApprove"}:
                        for name, calls in [("find_files", 1), ("search_content", 2)]:
                            item = pending(run, name)
                            assert server.count(scenario) == calls
                            assert "output" not in item and "blobID" not in item
                            decide(item)
                    if mode == "requestApproval":
                        decide(pending(run, "read_file"))
                    assert complete(run)["response"] == "Found the code and read the matching file."
                    tools = json_call("tools", run["id"], "--json")
                    assert [item["name"] for item in tools] == ["find_files", "search_content", "read_file"]
                    assert all(item["state"] == "completed" for item in tools)
                    assert server.count(scenario) == 4
                check("find, content search and matching file read round-trip under all four permission modes")

                run, _, _ = begin("search-denied", chat_profile, "autoApprove")
                item = pending(run, "search_content")
                assert "output" not in item and "blobID" not in item
                decide(item, yes=False)
                complete(run)
                assert json_call("tools", run["id"], "--json")[0]["state"] == "denied"
                check("automatic mode requires approval for recursive search; denial discloses no descendant content")

                for scenario, mode in [("edit-request", "requestApproval"), ("edit-auto", "autoApprove"),
                                       ("edit-accept", "acceptEdits"), ("edit-full", "fullAccess")]:
                    run, workspace, _ = begin(scenario, chat_profile, mode)
                    if mode == "requestApproval":
                        decide(pending(run, "read_file"))
                        item = pending(run, "edit_file")
                        assert item["effect"] == "write" and "beforeBlobID" not in item and "output" not in item
                        assert (workspace / "source.txt").read_bytes() == EDIT_BEFORE.encode()
                        call("approve", item["id"], "--hash", "0" * 64, expected=1)
                        assert json_call("tool", item["id"], "--json")["state"] == "pendingApproval"
                        decide(item)
                        decide(pending(run, "read_file"))
                    complete(run)
                    assert (workspace / "source.txt").read_bytes() == EDIT_AFTER.encode()
                    tools = json_call("tools", run["id"], "--json")
                    assert [item["name"] for item in tools] == ["read_file", "edit_file", "read_file"]
                    assert all(item["state"] == "completed" for item in tools)
                    assert tools[1]["beforeBlobID"] == hashlib.sha256(EDIT_BEFORE.encode()).hexdigest()
                    assert server.count(scenario) == 4
                check("exact partial edit preserves Unicode and CRLF, records original content, and follows all four permission modes")

                for scenario in ("edit-denied", "edit-stale", "edit-ambiguous", "edit-cancel"):
                    run, workspace, _ = begin(scenario, chat_profile, "requestApproval")
                    item = pending(run, "edit_file")
                    before = (workspace / "source.txt").read_bytes()
                    assert "beforeBlobID" not in item and "output" not in item
                    if scenario == "edit-stale":
                        before = b"external change must survive\n"
                        (workspace / "source.txt").write_bytes(before)
                    if scenario == "edit-cancel":
                        cancel(run)
                        call("approve", item["id"], "--hash", item["requestHash"], expected=1)
                        assert server.count(scenario) == 1
                    else:
                        decide(item, yes=scenario != "edit-denied")
                        complete(run)
                    assert (workspace / "source.txt").read_bytes() == before
                    final = json_call("tool", item["id"], "--json")
                    assert final["state"] == ("denied" if scenario == "edit-denied" else "cancelled" if scenario == "edit-cancel" else "failed")
                    if scenario != "edit-ambiguous": assert "beforeBlobID" not in final
                check("denied, cancelled, stale and ambiguous edits leave the file unchanged and cannot reuse approval")

                for scenario, mode in [("fetch-request", "requestApproval"), ("fetch-auto", "autoApprove"),
                                       ("fetch-accept", "acceptEdits"), ("fetch-full", "fullAccess")]:
                    run, _, _ = begin(scenario, chat_profile, mode)
                    path = "/web/" + scenario
                    if mode in {"requestApproval", "autoApprove"}:
                        item = pending(run, "fetch_url")
                        assert item["effect"] == "read" and "blobID" not in item and "output" not in item
                        assert server.url_count(path) == 0
                        call("approve", item["id"], "--hash", "0" * 64, expected=1)
                        assert server.url_count(path) == 0
                        decide(item)
                    complete(run)
                    item = json_call("tools", run["id"], "--json")[0]
                    assert item["state"] == "completed" and server.url_count(path) == 1
                    assert item["blobID"] == hashlib.sha256(WEB_MARKDOWN.encode()).hexdigest()
                    assert server.count(scenario) == 2
                check("URL reads follow all four permission modes; no request before exact approval and raw bytes are retained")

                for scenario in ("fetch-denied", "fetch-cancel-approval"):
                    run, _, _ = begin(scenario, chat_profile, "requestApproval")
                    item = pending(run, "fetch_url")
                    if scenario == "fetch-denied":
                        decide(item, yes=False)
                        complete(run)
                    else:
                        cancel(run)
                        call("approve", item["id"], "--hash", item["requestHash"], expected=1)
                    assert server.url_count("/web/" + scenario) == 0
                    assert "blobID" not in json_call("tool", item["id"], "--json")
                check("denied and cancelled URL approvals perform no network request")

                for scenario in ("fetch-html", "fetch-truncated", "fetch-http-error", "fetch-binary",
                                 "fetch-login", "fetch-large", "fetch-chunk-limit"):
                    run, _, _ = begin(scenario, chat_profile, "fullAccess")
                    complete(run)
                    item = json_call("tools", run["id"], "--json")[0]
                    assert item["state"] == ("completed" if scenario in {"fetch-html", "fetch-truncated"} else "failed")
                    assert server.url_count("/web/" + scenario) == 1
                assert server.url_count("/web/unexpected-subresource") == 0
                check("HTML extraction and bounded previews preserve source evidence; HTTP, login, media and size failures remain failures")

                run, _, _ = begin("fetch-redirect", chat_profile, "requestApproval")
                original = pending(run, "fetch_url")
                decide(original)
                target = wait_for(lambda: next((item for item in json_call("tools", run["id"], "--json")
                    if item["callID"] == "fetch_redirect_target" and item["state"] == "pendingApproval"), None), "redirect target approval")
                assert server.url_count("/web/redirect-target") == 0
                assert target["requestHash"] != original["requestHash"]
                decide(target)
                complete(run)
                assert server.url_count("/web/redirect-target") == 1
                assert [item["state"] for item in json_call("tools", run["id"], "--json")] == ["failed", "completed"]
                check("redirects require a new URL invocation and approval; cookies and credentials never cross requests")

                run, _, _ = begin("fetch-cancel", chat_profile, "fullAccess")
                wait_for(lambda: server.url_count("/web/fetch-cancel") == 1, "document download start")
                cancel(run)
                assert server.fetch_closed.wait(3), "URLSession did not close cancelled document download"
                assert server.count("fetch-cancel") == 1
                check("run cancellation closes an in-flight document download without a successful retrieval")

                for old_mode in ("manual", "plan", "dontAsk"):
                    call("run", "--session", run["sessionID"], "--provider", chat_profile, "--permission", old_mode,
                         "--detach", "fixture:invalid-mode", expected=1)
                call("run", "--session", run["sessionID"], "--provider", chat_profile, "fixture:no-approval-client", expected=1)
                headless_workspace = projects / "full-headless"
                headless_workspace.mkdir()
                (headless_workspace / "source.txt").write_text("before 🌱\n")
                events = call("run", "--workspace", str(headless_workspace), "--provider", chat_profile,
                              "--permission", "fullAccess", "--json", "fixture:full-headless")
                assert json.loads(events.splitlines()[-1])["kind"] == "runCompleted"
                assert (headless_workspace / "source.txt").read_text() == "after 🌿\n"
                check("CLI rejects retired modes and requires an approval client unless fullAccess is explicit")

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
                decide(pending(run, "read_file"))
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
