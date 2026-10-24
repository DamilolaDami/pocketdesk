"""One Machine: supervise Caddy certificate automation and the Quinn UDP relay.

Certificates/ACME account live on the persistent /data volume. No key material is
passed through stdout, process arguments, image layers or Fly environment variables.
"""
import http.server
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time


def main():
    hostname = os.environ.get("RELAY_HOSTNAME", "")
    if not re.fullmatch(r"(?=.{1,253}$)[a-z0-9]+(?:[-.][a-z0-9]+)*\.[a-z]{2,}", hostname):
        raise SystemExit("Set RELAY_HOSTNAME to the relay's public DNS hostname")
    stopping = False
    relay = None
    caddy = None

    def stop(_number, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    class Health(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            ready = relay is not None and relay.poll() is None
            self.send_response(200 if ready else 503)
            self.end_headers()
            self.wfile.write(b"ready\n" if ready else b"waiting for relay\n")

        def log_message(self, *_args):
            pass

    health = http.server.ThreadingHTTPServer(("0.0.0.0", 8081), Health)
    threading.Thread(target=health.serve_forever, daemon=True).start()
    try:
        caddy = subprocess.Popen(["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"])
        directory = Path("/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory") / hostname
        certificate = directory / (hostname + ".crt")
        key = directory / (hostname + ".key")
        print("Waiting for the public TLS certificate; DNS and TCP port 80 must be reachable", flush=True)
        while not stopping:
            if caddy.poll() is not None:
                raise SystemExit("Certificate manager exited")
            if relay is None and certificate.is_file() and key.is_file():
                relay = subprocess.Popen([
                    "pocketdesk-relay", "--listen", "fly-global-services:4433",
                    "--max-connections", os.environ.get("RELAY_MAX_CONNECTIONS", "256"),
                    "--cert", str(certificate), "--key", str(key),
                ])
            if relay is not None and relay.poll() is not None:
                raise SystemExit("Relay process exited")
            time.sleep(0.5)
    finally:
        health.shutdown()
        for process, sig in [(relay, signal.SIGINT), (caddy, signal.SIGTERM)]:
            if process is not None and process.poll() is None:
                process.send_signal(sig)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
