#!/usr/bin/env python3
"""Check a test daemon on an authorized phone; no login or mail submission.

The test daemon must listen on loopback ports 11143 (IMAP) and 11587 (SMTP).
SSH forwards expose those ports only on the test runner's loopback interface.
"""
import socket
import subprocess
import sys
import time


def line(stream):
    value = stream.readline(65537)
    if not value or len(value) > 65536:
        raise RuntimeError("Missing or oversized server response")
    return value


def connect(port):
    for attempt in range(50):
        try:
            connection = socket.create_connection(("127.0.0.1", port), timeout=30)
            return connection
        except ConnectionRefusedError:
            time.sleep(0.1)
    raise RuntimeError("SSH forwarding did not start")


def check(host):
    tunnel = subprocess.Popen([
        "ssh", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        "-o", "LogLevel=ERROR", "-N",
        "-L", "127.0.0.1:21143:127.0.0.1:11143",
        "-L", "127.0.0.1:21587:127.0.0.1:11587", host,
    ])
    try:
        with connect(21143) as connection, connection.makefile("rb") as stream:
            assert line(stream).startswith(b"* OK"), "IMAP greeting"
            connection.sendall(b"a1 CAPABILITY\r\n")
            for _ in range(100):
                response = line(stream)
                if response.startswith(b"a1 "):
                    assert response.startswith(b"a1 OK"), "IMAP CAPABILITY"
                    break
            else:
                raise RuntimeError("IMAP command did not finish")
            connection.sendall(b"a2 LOGOUT\r\n")
        print("PASS: IMAP greeting and CAPABILITY through verified upstream TLS")
        with connect(21587) as connection, connection.makefile("rb") as stream:
            assert line(stream).startswith(b"220 "), "SMTP greeting"
            connection.sendall(b"EHLO retrocloud-test.invalid\r\n")
            for _ in range(100):
                response = line(stream)
                assert response.startswith((b"250-", b"250 ")), "SMTP EHLO"
                if response.startswith(b"250 "):
                    break
            else:
                raise RuntimeError("SMTP command did not finish")
            connection.sendall(b"QUIT\r\n")
            assert line(stream).startswith(b"221 "), "SMTP QUIT"
        print("PASS: SMTP EHLO and QUIT through verified upstream STARTTLS")
    finally:
        tunnel.terminate()
        tunnel.wait(timeout=10)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-tunnel.py AUTHORIZED_TEST_HOST")
    check(sys.argv[1])
