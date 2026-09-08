#!/usr/bin/env python3
"""Run the actual NSLog sink on a Mac; keep all remote artifacts on Desktop."""
import os
from pathlib import Path
import shlex
import subprocess
import time

host = os.environ.get("TEST_HOST") or "x4-vm"
root = Path(os.environ["BUILD_ROOT"]) / "tests/macOS/logging"
run = "RetroCloudSync-LoggingTests-" + time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid())
remote = "Desktop/" + run
artifacts = root / run
artifacts.mkdir(parents=True)

def ssh(command):
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", host, command],
                          check=False, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout

ssh("mkdir " + shlex.quote(remote))
subprocess.run(["scp", "-O", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
                str(root / "LoggerTests"), host + ":" + remote + "/"], check=True)
for level in ("INFO", "DEBUG"):
    output = ssh("cd " + shlex.quote(remote) + " && RETROCLOUDSYNC_LOG_LEVEL=" + level +
                 " ./LoggerTests > " + level + ".log 2>&1; result=$?; cat " + level + ".log; exit $result")
    (artifacts / (level + ".log")).write_text(output)
    assert "Logger tests passed" in output
    assert "percent=100% Unicode=café new-line end" in output
    assert "Invalid UTF-8 log message" in output
    assert "[truncated]" in output
    assert ("debug-marker" in output) == (level == "DEBUG")
    assert "WARN [Mail/IMAP][TLS][connection=7] connection-marker" in output
    assert "INFO [Daemon][Test] main-context-marker" in output
    for service, poll in (("Contacts", 41), ("Calendars", 42)):
        for i in range(10):
            assert output.count(f"INFO [{service}][Test][poll={poll}] worker={service} item={i}\n") == 1
    assert all(len(line) < 2300 for line in output.splitlines())
    # 20 worker lines, five normal messages, one stdout result; DEBUG adds one.
    assert len(output.splitlines()) == (27 if level == "DEBUG" else 26)
print("NSLog formatting, levels, UTF-8, truncation, errno, thread context, and mail error tests passed.")
print("Artifacts:", artifacts)
