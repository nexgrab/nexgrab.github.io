"""Browser bridge for NexGrab (IDM-style integration).

The NexGrab browser extension sends "download this" requests to a tiny HTTP server that
listens ONLY on 127.0.0.1 (this PC). Web pages cannot use it:
  * requests must come from the NexGrab extension origin (fixed extension id below), and
  * must carry the custom header "X-NexGrab: 1" (forces a CORS pre-flight, which we only
    answer for the extension).

It also registers the nexgrab:// link type (HKCU, no admin), so the extension can start the
app when it is closed:  nexgrab://grab?url=...&mode=ask
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 47321
EXTENSION_IDS = {"fmhjojfbnkngkppncalnifdfcdneebbo"}  # fixed by the "key" in extension/manifest.json
MODES = ("ask", "best", "mp3")
MAX_BODY = 64 * 1024


def allowed_origin(origin: str | None) -> bool:
    if not origin:
        return False
    if origin.startswith("chrome-extension://"):
        return origin.split("://", 1)[1].strip("/") in EXTENSION_IDS
    if origin.startswith("moz-extension://"):  # Firefox gives every install a random uuid
        return True
    return False


def clean_request(data: dict) -> dict:
    url = str(data.get("url") or "").strip()
    if not url.lower().startswith(("http://", "https://")) or len(url) > 4000:
        raise ValueError("bad url")
    mode = data.get("mode") if data.get("mode") in MODES else "ask"
    title = str(data.get("title") or "")[:300]
    page = str(data.get("page") or "")[:4000]
    return {"url": url, "mode": mode, "title": title, "page": page}


class _Handler(BaseHTTPRequestHandler):
    server_version = "NexGrabBridge"
    on_grab = None  # set by Bridge
    version = "?"

    def log_message(self, *a):  # keep the console quiet, never log links
        pass

    def _cors(self, origin):
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-NexGrab")
        self.send_header("Access-Control-Max-Age", "600")

    def _json(self, code, obj, origin=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        if origin and allowed_origin(origin):
            self._cors(origin)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check(self):
        """Returns the origin to echo in CORS headers ("" when none), or None after refusing.

        Browsers always attach Origin to cross-site requests from web pages, so:
          * Origin present -> it must be the NexGrab extension.
          * Origin absent  -> only possible for the extension itself (Chrome drops it on extension
            GETs) or a local program; the custom X-NexGrab header is still required.
        """
        origin = self.headers.get("Origin")
        if origin is not None and not allowed_origin(origin):
            self._json(403, {"ok": False, "error": "origin"})
            return None
        if self.headers.get("X-NexGrab") != "1":
            self._json(403, {"ok": False, "error": "header"}, origin)
            return None
        return origin or ""

    def do_OPTIONS(self):  # noqa: N802
        origin = self.headers.get("Origin")
        if not allowed_origin(origin):
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(204)
        self._cors(origin)
        self.end_headers()

    def do_GET(self):  # noqa: N802
        origin = self._check()
        if origin is None:
            return
        if self.path.split("?")[0] == "/ping":
            self._json(200, {"ok": True, "app": "NexGrab", "version": self.version}, origin)
        else:
            self._json(404, {"ok": False}, origin)

    def do_POST(self):  # noqa: N802
        origin = self._check()
        if origin is None:
            return
        if self.path.split("?")[0] != "/grab":
            self._json(404, {"ok": False}, origin)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_BODY:
                raise ValueError("size")
            req = clean_request(json.loads(self.rfile.read(n).decode("utf-8")))
        except Exception:
            self._json(400, {"ok": False, "error": "bad request"}, origin)
            return
        try:
            type(self).on_grab(req)
        except Exception:
            self._json(500, {"ok": False}, origin)
            return
        self._json(200, {"ok": True}, origin)


class Bridge:
    """Runs the localhost server in a daemon thread. on_grab(dict) is called from that thread."""

    def __init__(self, on_grab, version="?", port=PORT):
        self.port = port
        handler = type("Handler", (_Handler,), {"on_grab": staticmethod(on_grab), "version": version})
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        try:
            self.httpd.shutdown()
            self.httpd.server_close()
        except Exception:
            pass


# ---------------------------------------------------------------------------- nexgrab:// links

def parse_protocol(arg: str) -> dict | None:
    """nexgrab://grab?url=...&mode=ask  ->  request dict (or None)."""
    if not arg or not arg.lower().startswith("nexgrab:"):
        return None
    q = urllib.parse.urlsplit(arg).query
    params = {k: v[0] for k, v in urllib.parse.parse_qs(q).items()}
    try:
        return clean_request(params)
    except ValueError:
        return None


def forward_to_running(req: dict, port=PORT, timeout=3) -> bool:
    """If NexGrab is already open, hand the request to it (second launch from a nexgrab:// link)."""
    try:
        data = json.dumps(req).encode()
        r = urllib.request.Request(f"http://127.0.0.1:{port}/grab", data=data, method="POST", headers={
            "Content-Type": "application/json", "X-NexGrab": "1",
            "Origin": "chrome-extension://" + next(iter(EXTENSION_IDS))})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never via a proxy
        with opener.open(r, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def register_protocol() -> bool:
    """Windows: make nexgrab:// open this app (current user only, no admin)."""
    if os.name != "nt":
        return False
    try:
        import winreg

        if getattr(sys, "frozen", False):
            cmd = f'"{sys.executable}" "%1"'
        else:
            pyw = sys.executable.replace("python.exe", "pythonw.exe")
            cmd = f'"{pyw}" "{os.path.abspath(sys.argv[0])}" "%1"'
        base = r"Software\Classes\nexgrab"
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, base) as k:
            winreg.SetValueEx(k, "", 0, winreg.REG_SZ, "URL:NexGrab")
            winreg.SetValueEx(k, "URL Protocol", 0, winreg.REG_SZ, "")
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, base + r"\shell\open\command") as k:
            winreg.SetValueEx(k, "", 0, winreg.REG_SZ, cmd)
        return True
    except Exception:
        return False


def extension_folder() -> str | None:
    """The unpacked extension shipped next to the EXE (or in the source tree)."""
    base = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
    for p in (os.path.join(base, "extension"), os.path.join(base, "..", "extension")):
        if os.path.isfile(os.path.join(p, "manifest.json")):
            return os.path.abspath(p)
    return None


def open_extension_setup(browser_exe: str | None = None):
    """Open the browser's extensions page + the extension folder (for 'Load unpacked')."""
    folder = extension_folder()
    if folder and os.name == "nt":
        subprocess.Popen(["explorer", folder])
    if browser_exe:
        url = "edge://extensions/" if "edge" in browser_exe.lower() else "chrome://extensions/"
        subprocess.Popen([browser_exe, url])
    return folder
