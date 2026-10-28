"""Loopback-only dashboard fixture for browser checks; never contacts Azure."""
import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

STATE = {"region": "krc", "tm": "KRC", "calls": []}
SERVICE = {
    "status": "ok", "ok": True, "latency_ms": 2.5, "error": None,
    "fqdn": "fixture.private.example", "ips": ["10.10.16.4"], "pe_region": "KRC",
    "data": {"id": "browser-fixture"},
}
SERVICES = {key: dict(SERVICE) for key in (
    "postgres", "redis", "event_hubs", "storage_primary", "storage_secondary", "search")}
SERVICES["redis"].update(status="disabled", ok=None)
SERVICES["event_hubs"].update(status="error", error="<img src=x onerror=alert(1)>")
SAMPLE = {
    "status": "ok", "manifest": {"endUtc": "2026-10-27T00:00:00Z"},
    "large": {"count": 80, "bytes": 85899345920},
    "small": {"count": 20000, "bytes": 20971520000},
    "total_bytes": 106870865920, "read_1mb_ms": 8.2, "read_bytes": 1048576,
    "cached": False, "cache_age_seconds": 0,
}


class Handler(BaseHTTPRequestHandler):
    def respond(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            body = (Path(__file__).resolve().parents[1] / "app" / "static" / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/__fixture":
            self.respond(STATE)
            return
        STATE["calls"].append(path)
        if path == "/api/info":
            self.respond({"region": STATE["region"], "pod_name": "fixture-pod",
                          "time": datetime.now(timezone.utc).isoformat(), "host": self.headers.get("Host"),
                          "storage_read_mode": "secondary"})
        elif path == "/api/tm":
            self.respond({"fqdn": "fixture.trafficmanager.net", "ips": ["203.0.113.10"],
                          "region": STATE["tm"], "cname_chain": ["fixture.example"]})
        elif path == "/api/check":
            self.respond(SERVICES)
        elif path == "/api/read":
            services = {key: SERVICES[key] for key in ("postgres", "redis", "event_hubs", "search")}
            services["storage"] = SERVICES["storage_secondary"]
            self.respond({"status": "partial", "services": services})
        elif path == "/api/sampledata":
            self.respond({"primary": SAMPLE, "secondary": SAMPLE,
                          "last_sync_time": "2026-10-27T00:10:00Z",
                          "manifest_end_time": "2026-10-27T00:00:00Z",
                          "replication_complete": True})
        else:
            self.respond({"error": "fixture path not found"}, 404)

    def do_POST(self):
        if self.path == "/__fixture":
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            for key in ("region", "tm"):
                if key in data:
                    STATE[key] = data[key]
            self.respond({"status": "ok"})
        elif self.path == "/api/write":
            STATE["calls"].append(self.path)
            self.respond({"status": "partial", "record": {"id": "browser-fixture"},
                          "services": {key: value for key, value in SERVICES.items() if key != "storage_secondary"},
                          "read_only": False})
        else:
            self.respond({"error": "fixture path not found"}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8766), Handler).serve_forever()
