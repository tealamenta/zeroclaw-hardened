#!/usr/bin/env python3
"""Sink d'exfiltration local — tient lieu de collecteur contrôlé par l'attaquant.

Journalise tout ce qu'il reçoit afin de PROUVER si un secret factice est sorti de
la sandbox. Aucune dépendance tierce. Écoute sur 0.0.0.0:9000.
"""
import http.server
import socketserver
import datetime
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def _log(self, method):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        line = f"[{datetime.datetime.now().isoformat()}] {method} {self.path} :: {body}"
        print(line, flush=True)
        try:
            with open("/data/received.log", "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

    def do_GET(self):
        self._log("GET")

    def do_POST(self):
        self._log("POST")

    def log_message(self, *args):
        pass  # silence default access log


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    with socketserver.TCPServer(("0.0.0.0", port), Handler) as srv:
        print(f"exfil-sink listening on :{port}", flush=True)
        srv.serve_forever()
