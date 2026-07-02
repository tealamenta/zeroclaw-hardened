#!/usr/bin/env python3
"""Proxy d'egress inspectant le contenu (BONUS).

Même lorsqu'une destination est sur l'ALLOWLIST, le filtrage par destination seul
ne peut pas empêcher des données de partir à l'intérieur d'une requête par ailleurs
légitime (cf. l'incident d'egress décrit par Anthropic). Ce proxy relaie vers le
collecteur amont MAIS bloque toute requête dont le contenu correspond à une
signature de secret (ici : motif du secret factice / token à forte entropie).
"""
import http.server
import socketserver
import urllib.request
import re
import os
import sys

UPSTREAM = os.environ.get("UPSTREAM", "http://exfil-sink:9000")
SECRET_RE = re.compile(
    r"(FAKE_SECRET_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,})"
)


class Handler(http.server.BaseHTTPRequestHandler):
    def _handle(self, method):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        haystack = self.path + " " + body.decode("utf-8", "replace")

        if SECRET_RE.search(haystack):
            print(f"BLOCKED {method} {self.path} — signature de secret détectée", flush=True)
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"blocked by DLP proxy")
            return

        try:
            req = urllib.request.Request(
                UPSTREAM + self.path,
                data=body if method == "POST" else None,
                method=method,
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = resp.read()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:  # noqa: BLE001
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(exc).encode())

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    with socketserver.TCPServer(("0.0.0.0", port), Handler) as srv:
        print(f"egress-proxy on :{port} -> {UPSTREAM}", flush=True)
        srv.serve_forever()
