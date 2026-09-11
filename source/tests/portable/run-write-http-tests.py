#!/usr/bin/env python3
"""Exercise the production HTTP client against an ephemeral local TLS server."""
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    received = []

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            # Certificate rejection deliberately abandons these connections.
            pass

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        match = self.headers.get("If-Match")
        none = self.headers.get("If-None-Match")
        self.received.append((self.command, self.path, match, none, body))
        location = None
        status = 400
        if self.path == "/create" and (self.command, match, none, body) == ("PUT", None, "*", b"new"):
            status = 201
        elif self.path == "/update" and (self.command, match, none, body) == ("PUT", '"base"', None, b"edit"):
            status = 204
        elif self.path == "/delete" and (self.command, match, none, body) == ("DELETE", '"base"', None, b""):
            status = 204
        elif self.path == "/calendar-create" and (self.command, match, none, body) == ("MKCALENDAR", None, "*", b"<new/>"):
            status = 201
        elif self.path == "/calendar-move" and self.command == "MOVE" and match == '"base"' and none is None and self.headers.get("Overwrite") == "F" and self.headers.get("Destination") == f"https://localhost:{self.server.server_port}/target":
            status = 201
        elif self.path == "/move":
            status, location = 307, "/must-not-follow"
        elif self.path == "/discovery":
            status, location = 302, "/principal"
        elif self.path == "/principal" and self.command == "PROPFIND" and body == b"<probe/>":
            status = 207
        elif self.path == "/foreign":
            status, location = 307, "https://unexpected.invalid/private"
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = do_PUT = do_DELETE = do_PROPFIND = do_MOVE = do_MKCALENDAR = handle_request


def main():
    with tempfile.TemporaryDirectory(prefix="retro-write-http-") as directory:
        root = Path(directory)
        for name in ("server", "untrusted"):
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(root / (name + ".key")), "-out", str(root / (name + ".pem")),
                "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / "server.pem", root / "server.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = dict(os.environ, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
            subprocess.run([sys.argv[1], f"https://localhost:{server.server_port}",
                            str(root / "server.pem"), str(root / "untrusted.pem")], check=True, env=env, timeout=30)
            paths = [request[1] for request in Handler.received]
            assert paths == ["/create", "/update", "/delete", "/move", "/move", "/calendar-move", "/calendar-create", "/discovery", "/principal", "/foreign"], paths
        finally:
            server.shutdown()
            thread.join()
            server.server_close()


if __name__ == "__main__":
    main()
