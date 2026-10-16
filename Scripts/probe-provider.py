#!/usr/bin/env python3
"""Opt-in live OpenAI-compatible coding probe using the built Lathe engine and CLI.

Sends only a synthetic prompt/file to the supplied server. Uses a fresh temporary
workspace and data directory, no saved profiles, API keys, or inherited environment.
Approves only one exact synthetic edit and one literal /usr/bin/printf command.
The optional JSON report contains checks and tool states, never a session transcript.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import urlsplit


BEFORE = "def add(a, b):\n    return a - b\n"
AFTER = "def add(a, b):\n    return a + b\n"
MARKER = "LATHE_LIVE_OK\n"
PROMPT = """This is a small isolated coding integration test. Perform these steps in order:
1. Use read_file to read source.txt and obtain its SHA-256.
2. Use write_file to fix only the subtraction bug in add. The complete new contents must be exactly:
def add(a, b):
    return a + b
(Keep the final newline. Use the SHA-256 returned by read_file.)
3. After the edit succeeds, use run_command with executable /usr/bin/printf,
arguments [\"LATHE_LIVE_OK\\n\"], workingDirectory \".\", and timeoutSeconds 10.
The arguments array must contain the string LATHE_LIVE_OK followed by a newline.
Do not run a shell or any other command. Do not create or edit any other file.
4. After the command succeeds, give a brief final response summarizing the observed results.
Call the real tools; do not merely describe what you would do. No further actions are needed.
"""


class ProbeFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ProbeFailure(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", required=True, type=Path)
    parser.add_argument("--base-url", required=True, help="OpenAI-compatible API root, including /v1 if required")
    parser.add_argument("--model", required=True, help="Served model ID")
    parser.add_argument("--allow-http", action="store_true", help="Explicitly permit an unencrypted HTTP endpoint")
    parser.add_argument("--timeout", type=float, default=180, help="Run deadline in seconds (10–180; default 180)")
    parser.add_argument("--output", type=Path, help="Optional summary report, preferably under ignored .build/probes")
    args = parser.parse_args()
    url = urlsplit(args.base_url)
    if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.query or url.fragment:
        parser.error("--base-url must be an absolute HTTP(S) URL without credentials, query, or fragment")
    if url.scheme == "http" and not args.allow_http:
        parser.error("HTTP requires explicit --allow-http")
    if not 10 <= args.timeout <= 180:
        parser.error("--timeout must be between 10 and 180 seconds")
    binaries = args.bin_dir.resolve()
    cli, engine, runner = [binaries / name for name in ("lathe", "lathe-engine", "lathe-runner")]
    if not all(path.is_file() and os.access(path, os.X_OK) for path in (cli, engine, runner)):
        parser.error("Build lathe, lathe-engine, and lathe-runner first")

    report = {"status": "failed", "scope": "opt-in live provider; synthetic isolated workspace; no credentials",
              "checks": [], "runState": None, "toolStates": [], "cleanup": False}
    started = time.monotonic()

    def check(label):
        report["checks"].append(label)
        print("PASS " + label, flush=True)

    try:
        with tempfile.TemporaryDirectory(prefix="lathe-live-probe-") as temporary:
            base = Path(temporary).resolve()
            root, workspace, tmp = base / "state", base / "workspace", base / "tmp"
            workspace.mkdir(mode=0o700)
            tmp.mkdir(mode=0o700)
            source = workspace / "source.txt"
            source.write_text(BEFORE, encoding="utf-8")
            original_hash = hashlib.sha256(BEFORE.encode()).hexdigest()
            # Never inherit API keys, proxy variables, shell startup configuration,
            # or any of the caller's private environment into the test engine.
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": str(tmp)}
            cli_command = [str(cli), "--root", str(root)]
            owned = subprocess.Popen([str(engine), "--root", str(root)], env=environment,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            active_run = None
            run_deadline = None
            observed = {}
            approved = set()

            def call(*words, timeout=15, cleanup=False):
                if run_deadline is not None and not cleanup:
                    remaining = run_deadline - time.monotonic()
                    require(remaining > 0, "Live model run exceeded the deadline")
                    timeout = min(timeout, remaining)
                result = subprocess.run(cli_command + list(words), env=environment, stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=timeout)
                # Do not copy potential model output from CLI errors into a saved report.
                require(result.returncode == 0, "CLI command failed: " + words[0])
                try:
                    return json.loads(result.stdout)
                except json.JSONDecodeError as error:
                    raise ProbeFailure("CLI returned invalid JSON: " + words[0]) from error

            def refresh_tools(run_id):
                for item in call("tools", run_id, "--json"):
                    observed[item["id"]] = item
                # A previous tool may fall outside the latest-four list after later
                # reads. Refresh known pending/executing records by their exact ID.
                for item_id, item in list(observed.items()):
                    if item["state"] in {"pendingApproval", "approved", "executing"}:
                        observed[item_id] = call("tool", item_id, "--json")

            def completed(name):
                return [item for item in observed.values() if item["name"] == name and item["state"] == "completed"]

            try:
                bootstrap_deadline = time.monotonic() + 10
                # EngineMain acquires its lifetime flock before opening this new
                # database. The CLI will therefore wait for this owned engine,
                # without racing to spawn another one. Do not predict readiness
                # from a socket hash: Darwin/Python canonicalize /var differently.
                while not (root / "lathe.sqlite").is_file():
                    require(owned.poll() is None, "Owned engine exited during startup")
                    require(time.monotonic() < bootstrap_deadline, "Owned engine startup timed out")
                    time.sleep(0.05)
                info = call("status", "--json")
                require(info["processID"] == owned.pid, "CLI connected to an unexpected engine")
                check("CLI connected to the owned isolated engine")
                profile_words = ["provider-set", "--name", "Live synthetic probe", "--api", "openAIChat",
                                 "--base-url", args.base_url, "--model", args.model, "--json"]
                if args.allow_http:
                    profile_words.append("--allow-http")
                profile = call(*profile_words)
                session = call("new", "--workspace", str(workspace), "Live synthetic probe", "--json")
                run = call("run", "--session", session["id"], "--provider", profile["id"], "--permission", "requestApproval",
                           "--max-steps", "8", "--detach", PROMPT)
                active_run = run["id"]
                run_deadline = time.monotonic() + args.timeout
                final = None
                while time.monotonic() < run_deadline:
                    refresh_tools(active_run)
                    for item in observed.values():
                        if item["state"] != "pendingApproval" or item["id"] in approved:
                            continue
                        arguments = json.loads(item["arguments"])
                        valid = False
                        if item["name"] == "list_directory":
                            valid = arguments == {"path": "."}
                        elif item["name"] == "read_file":
                            valid = arguments == {"path": "source.txt"}
                        elif item["name"] == "write_file":
                            reads = completed("read_file")
                            valid = (not any(record["name"] == "write_file" and record["id"] in approved for record in observed.values())
                                     and any(json.loads(record["arguments"]) == {"path": "source.txt"} for record in reads)
                                     and arguments == {"path": "source.txt", "content": AFTER, "expectedSHA256": original_hash}
                                     and source.read_text(encoding="utf-8") == BEFORE)
                        elif item["name"] == "run_command":
                            valid = (not any(record["name"] == "run_command" and record["id"] in approved for record in observed.values())
                                     and len(completed("write_file")) == 1
                                     and arguments == {"executable": "/usr/bin/printf", "arguments": [MARKER],
                                                       "workingDirectory": ".", "timeoutSeconds": 10}
                                     and source.read_text(encoding="utf-8") == AFTER)
                        call("approve" if valid else "deny", item["id"], "--hash", item["requestHash"], "--json")
                        require(valid, "Unexpected tool request denied; probe stopped")
                        approved.add(item["id"])
                        check("Approved exact synthetic tool: " + item["name"])
                    snapshot = call("show", session["id"], "--json")
                    final = next(item for item in snapshot["runs"] if item["id"] == active_run)
                    report["runState"] = final["state"]
                    if final["state"] != "running":
                        active_run = None
                        break
                    time.sleep(0.15)
                require(active_run is None, "Live model run exceeded the deadline")
                refresh_tools(run["id"])
                require(final is not None and final["state"] == "completed", "Live model run did not complete successfully")
                require(source.read_text(encoding="utf-8") == AFTER, "Synthetic edit content did not match")
                require(list(workspace.iterdir()) == [source], "Unexpected workspace file exists")
                require(len(completed("write_file")) == 1 and len(completed("run_command")) == 1,
                        "Required edit and command were not both completed exactly once")
                command_output = json.loads(completed("run_command")[0]["output"])
                require(command_output.get("exitCode") == 0 and command_output.get("stdout") == MARKER
                        and command_output.get("stderr") == "", "Command output or exit code did not match")
                require(bool(final.get("response", "").strip()), "Model did not produce a final response")
                check("Live model read, edited, executed and returned a final response")
                check("Synthetic file, literal command output and exit status verified")
                report["status"] = "passed"
            finally:
                report["toolStates"] = [{"name": item["name"], "state": item["state"]} for item in observed.values()]
                if active_run is not None and owned.poll() is None:
                    try:
                        call("cancel", active_run, "--json", timeout=20, cleanup=True)
                    except (ProbeFailure, subprocess.TimeoutExpired):
                        pass
                # Only this Popen child is signalled. No lookup by process name and
                # no normal app engine or user profile is touched.
                if owned.poll() is None:
                    owned.terminate()
                    try:
                        owned.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        owned.kill()
                        owned.wait(timeout=5)
                report["cleanup"] = True
        check("Owned engine and temporary workspace/data removed")
    except (ProbeFailure, subprocess.TimeoutExpired, OSError, ValueError, KeyError, StopIteration) as error:
        report["status"] = "failed"
        report["error"] = str(error) if isinstance(error, ProbeFailure) else type(error).__name__
        print("FAIL " + report["error"], flush=True)
    report["durationSeconds"] = round(time.monotonic() - started, 2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
