"""
NexGrab - core engine (no GUI code in here).

Everything that talks to yt-dlp, the network (Direct / Tor / proxy / SSH tunnel),
the file system and background threads lives here. The GUI only reads state and
receives events through a thread-safe queue, so Tk widgets are never touched from
worker threads.
"""

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import zipfile
from datetime import datetime
from urllib.parse import urlparse

import yt_dlp

APP_NAME = "NexGrab"
APP_VERSION = "3.2.4"
DEVELOPER = "WSNex"

IS_WIN = sys.platform.startswith("win")
FROZEN = getattr(sys, "frozen", False)

# ---------------------------------------------------------------------------- paths


def app_dir() -> str:
    """Folder of the .exe (frozen) or of this .py file."""
    if FROZEN:
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def resource_path(relative: str) -> str:
    """Bundled read-only files (works for .py and PyInstaller --onefile)."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, relative)


def data_dir() -> str:
    if IS_WIN:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return os.path.join(base, "NexGrab")
    return os.path.join(os.path.expanduser("~"), ".rsk_downloader")


DATA_DIR = data_dir()
CONFIG_FILE = os.path.join(DATA_DIR, "settings.json")
HISTORY_FILE = os.path.join(DATA_DIR, "history.json")
TOOLS_DIRS = [os.path.join(app_dir(), "tools"), app_dir(), os.path.join(DATA_DIR, "tools")]
LEGACY_DIR = os.path.join(os.path.expanduser("~"), ".rsk_downloader")
# v3.0-3.1 (before the NexGrab name) kept data here on Windows
LEGACY_DIRS = [os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "RSK Futuristic Downloader"),
               LEGACY_DIR]

NO_WINDOW = subprocess.CREATE_NO_WINDOW if IS_WIN else 0


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


_save_lock = threading.Lock()


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with _save_lock:
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)


def migrate_legacy():
    """Copy settings / history / tools from older versions (RSK names) once."""
    for old_dir in LEGACY_DIRS:
        if not os.path.isdir(old_dir) or os.path.abspath(old_dir) == os.path.abspath(DATA_DIR):
            continue
        for name in ("settings.json", "history.json"):
            old = os.path.join(old_dir, name)
            new = os.path.join(DATA_DIR, name)
            if os.path.exists(old) and not os.path.exists(new):
                try:
                    os.makedirs(DATA_DIR, exist_ok=True)
                    shutil.copyfile(old, new)
                except Exception:
                    pass
        old_tools = os.path.join(old_dir, "tools")
        new_tools = os.path.join(DATA_DIR, "tools")
        if os.path.isdir(old_tools) and not os.path.exists(new_tools):
            try:
                shutil.copytree(old_tools, new_tools, copy_function=shutil.copyfile)
            except Exception:
                pass


# ---------------------------------------------------------------------------- formatting


def fmt_bytes(n) -> str:
    if not n:
        return "0 B"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def fmt_time(seconds) -> str:
    if seconds is None or seconds < 0:
        return "--:--"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def open_path(path: str):
    path = os.path.abspath(path)
    if IS_WIN:
        os.startfile(path)  # noqa: S606 - opening user's own file
    elif sys.platform == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


def reveal_in_folder(path: str):
    """Open Explorer with the file selected (falls back to opening the folder)."""
    if IS_WIN and os.path.isfile(path):
        subprocess.Popen(["explorer", "/select,", os.path.abspath(path)])
        return
    open_path(path if os.path.isdir(path) else os.path.dirname(path))


# ---------------------------------------------------------------------------- tools (ffmpeg / JS runtime)


def _exe(name):
    return f"{name}.exe" if IS_WIN else name


def find_tool(name: str):
    for d in TOOLS_DIRS:
        p = os.path.join(d, _exe(name))
        if os.path.isfile(p):
            return p
    if name == "ffmpeg" and not FROZEN:
        try:
            import imageio_ffmpeg  # bundled ffmpeg when running from source

            p = imageio_ffmpeg.get_ffmpeg_exe()
            if p and os.path.isfile(p):
                return p
        except Exception:
            pass
    if name == "deno" and not FROZEN:
        try:
            import deno

            p = deno.find_deno_bin()
            if p and os.path.isfile(p):
                return p
        except Exception:
            pass
    return shutil.which(name)


class Tools:
    """Resolved helper programs. Call refresh() after installing something."""

    def __init__(self):
        self.refresh()

    def refresh(self):
        self.ffmpeg = find_tool("ffmpeg")
        self.deno = find_tool("deno")
        self.node = None if self.deno else shutil.which("node")
        self.aria2c = shutil.which("aria2c")

    @property
    def js_runtime(self):
        if self.deno:
            return "deno", self.deno
        if self.node:
            return "node", self.node
        return None, None

    def status_lines(self):
        rt, path = self.js_runtime
        return [
            ("FFmpeg", bool(self.ffmpeg), "Merge HD video + audio, MP3" if self.ffmpeg else "Missing: only single-file qualities, no MP3"),
            ("YouTube JS engine", bool(rt), f"{rt} ready" if rt else "Missing: YouTube may show fewer formats or fail"),
            ("aria2c (optional)", bool(self.aria2c), "Found" if self.aria2c else "Not installed (optional)"),
            ("yt-dlp", True, yt_dlp.version.__version__),
        ]


DENO_ZIP = "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip"
FFMPEG_ZIP = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip"


def _download(url, dest, progress=None, cancel=None):
    req = urllib.request.Request(url, headers={"User-Agent": f"{APP_NAME}/{APP_VERSION}"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while True:
            if cancel and cancel.is_set():
                raise RuntimeError("Cancelled")
            chunk = r.read(256 * 1024)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if progress:
                progress(done, total)


def install_tools(tools: Tools, log=lambda msg: None, cancel=None):
    """Download missing ffmpeg / deno (Windows) into the app data tools folder."""
    if not IS_WIN:
        raise RuntimeError("Automatic install is for Windows. Install ffmpeg and deno with your package manager.")
    target = os.path.join(DATA_DIR, "tools")
    os.makedirs(target, exist_ok=True)

    def prog(label):
        last = [0.0]

        def f(done, total):
            now = time.time()
            if now - last[0] > 0.5:
                last[0] = now
                pct = f"{done * 100 / total:.0f}%" if total else fmt_bytes(done)
                log(f"{label}: {pct}")

        return f

    if not tools.deno:
        z = os.path.join(target, "deno.zip")
        log("Downloading YouTube JS engine (deno, ~40 MB)...")
        _download(DENO_ZIP, z, prog("deno"), cancel)
        with zipfile.ZipFile(z) as zf:
            zf.extract("deno.exe", target)
        os.remove(z)
    if not tools.ffmpeg:
        z = os.path.join(target, "ffmpeg.zip")
        log("Downloading FFmpeg (~170 MB, one time)...")
        _download(FFMPEG_ZIP, z, prog("ffmpeg"), cancel)
        with zipfile.ZipFile(z) as zf:
            for member in zf.namelist():
                base = os.path.basename(member)
                if base in ("ffmpeg.exe", "ffprobe.exe"):
                    with zf.open(member) as src, open(os.path.join(target, base), "wb") as dst:
                        shutil.copyfileobj(src, dst)
        os.remove(z)
    tools.refresh()
    log("Tools ready.")


# ---------------------------------------------------------------------------- network routes

TOR_PORTS = (9150, 9050)  # Tor Browser, standalone Tor / Orbot


def socks5_alive(port: int, host="127.0.0.1", timeout=1.0) -> bool:
    """True only if a real SOCKS5 server answers (not just any open port)."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(b"\x05\x01\x00")
            return s.recv(2) == b"\x05\x00"
    except Exception:
        return False


def detect_tor():
    for p in TOR_PORTS:
        if socks5_alive(p):
            return p
    return None


def normalize_proxy(value: str, kind: str = "http") -> str:
    value = (value or "").strip()
    if not value:
        return ""
    if "://" not in value:
        value = ("socks5h://" if kind == "socks5" else "http://") + value
    if value.lower().startswith("socks5://"):
        value = "socks5h://" + value[9:]  # resolve DNS through the proxy too
    p = urlparse(value)
    if not p.hostname or not p.port:
        raise ValueError("Proxy must look like host:port, e.g. 127.0.0.1:1080")
    return value


ROUTES = ("auto", "direct", "tor", "proxy", "tunnel")
ROUTE_LABELS = {
    "auto": "Auto (Tor when running)",
    "direct": "Direct",
    "tor": "Tor only",
    "proxy": "Custom proxy",
    "tunnel": "Private tunnel (SSH)",
}


class NetworkState:
    """Works out which proxy yt-dlp should use right now."""

    def __init__(self, settings: dict):
        self.settings = settings
        self.tor_port = None
        self.tunnel = SSHTunnel()
        self._lock = threading.Lock()

    @property
    def mode(self):
        m = self.settings.get("route", "auto")
        return m if m in ROUTES else "auto"

    def refresh_tor(self):
        port = detect_tor()
        with self._lock:
            self.tor_port = port
        return port

    def proxy(self) -> str:
        """Proxy URL for yt-dlp ('' = direct). Raises if the chosen route is unavailable."""
        mode = self.mode
        if mode == "direct":
            return ""
        if mode == "auto":
            return f"socks5h://127.0.0.1:{self.tor_port}" if self.tor_port else ""
        if mode == "tor":
            port = self.tor_port or self.refresh_tor()
            if not port:
                raise RouteError("Tor nahi mila. Tor Browser khol kar connect hone dein, phir dobara try karein.")
            return f"socks5h://127.0.0.1:{port}"
        if mode == "proxy":
            kind = self.settings.get("proxy_kind", "http")
            url = normalize_proxy(self.settings.get("proxy_url", ""), kind)
            if not url:
                raise RouteError("Custom proxy khali hai. Network page par proxy likhein.")
            return url
        if mode == "tunnel":
            if not self.tunnel.connected:
                raise RouteError("Private tunnel connected nahi. Network → Private tunnel → Connect.")
            return self.tunnel.proxy_url
        return ""

    def label(self) -> str:
        mode = self.mode
        if mode == "auto":
            return f"Auto • Tor (port {self.tor_port})" if self.tor_port else "Auto • Direct"
        if mode == "tor":
            return f"Tor • port {self.tor_port}" if self.tor_port else "Tor • not running"
        if mode == "proxy":
            return f"Proxy • {self.settings.get('proxy_url') or 'not set'}"
        if mode == "tunnel":
            return "Tunnel • connected" if self.tunnel.connected else "Tunnel • disconnected"
        return "Direct"

    def is_tor(self) -> bool:
        return (self.mode == "auto" and bool(self.tor_port)) or (self.mode == "tor" and bool(self.tor_port))

    def can_bypass_tor(self, proxy: str) -> bool:
        """Only Auto mode may drop Tor for Direct (Tor-only / proxy / tunnel never do)."""
        return bool(proxy) and self.mode == "auto" and route_name(proxy) == "Tor"

    def fallback_proxy(self, failed_proxy: str):
        """Smart fallback: Direct failed -> try Tor if it is running. Never leaves Tor/proxy for Direct."""
        if not self.settings.get("smart_network", True):
            return None
        if failed_proxy:
            return None
        port = self.refresh_tor()
        return f"socks5h://127.0.0.1:{port}" if port else None


class RouteError(Exception):
    pass


class SSHTunnel:
    """ssh -N -D 127.0.0.1:<port> user@host  (app-only SOCKS5 tunnel)."""

    def __init__(self):
        self.proc = None
        self.local_port = 1080
        self.error = ""

    @property
    def connected(self):
        return self.proc is not None and self.proc.poll() is None

    @property
    def proxy_url(self):
        return f"socks5h://127.0.0.1:{self.local_port}"

    def connect(self, host, user, key, port=22, local_port=1080, timeout=15):
        ssh = shutil.which("ssh")
        if not ssh:
            raise RuntimeError("Windows OpenSSH Client nahi mila. Settings → Apps → Optional features → OpenSSH Client install karein.")
        if not host or not user:
            raise ValueError("Server host aur SSH username likhein.")
        if not key or not os.path.isfile(key):
            raise ValueError("SSH private key file select karein.")
        self.disconnect()
        self.local_port = int(local_port)
        cmd = [
            ssh, "-N", "-D", f"127.0.0.1:{self.local_port}", "-p", str(int(port)), "-i", key,
            "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes", f"{user}@{host}",
        ]
        err_file = os.path.join(DATA_DIR, "ssh_error.log")
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(err_file, "w", encoding="utf-8") as ef:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=ef, creationflags=NO_WINDOW)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                break
            if socks5_alive(self.local_port, timeout=1):
                return True
            time.sleep(0.4)
        self.disconnect()
        try:
            with open(err_file, encoding="utf-8", errors="replace") as ef:
                self.error = ef.read()[-800:]
        except Exception:
            self.error = ""
        raise RuntimeError("SSH tunnel connect nahi hua.\n\n" + (self.error or "Host, user, port, firewall aur key check karein."))

    def disconnect(self):
        p = self.proc
        self.proc = None
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except Exception:
                p.kill()


# ---------------------------------------------------------------------------- errors


NETWORK_SIGNS = (
    "failed to resolve", "getaddrinfo failed", "temporary failure in name resolution",
    "name or service not known", "connection refused", "connection timed out", "timed out",
    "network is unreachable", "unable to connect", "remote end closed", "connection reset",
    "unable to download webpage", "socks", "proxy",
)


def is_bot_check(msg: str) -> bool:
    m = (msg or "").lower()
    return ("confirm you" in m and "bot" in m) or "sign in to confirm" in m


def route_name(proxy: str) -> str:
    if not proxy:
        return "Direct"
    if any(f"127.0.0.1:{p}" in proxy for p in TOR_PORTS):
        return "Tor"
    return "Proxy"


def is_network_error(msg: str) -> bool:
    m = (msg or "").lower()
    if "http error" in m:  # the server answered -> not a connectivity problem
        return False
    return any(s in m for s in NETWORK_SIGNS)


def friendly_error(exc) -> str:
    raw = re.sub(r"\x1b\[[0-9;]*m", "", str(exc)).replace("ERROR: ", "").strip()
    low = raw.lower()
    if isinstance(exc, RouteError):
        return raw
    if is_bot_check(low):
        return ("YouTube ne 'not a bot' check maanga.\n\n"
                "• Tor / VPN / proxy se ho raha tha to: Network → Direct (YouTube Tor ko block karta hai).\n"
                "• Direct par bhi aaye to cookies dein: Home → Cookies → Firefox, ya 'cookies.txt file...'.\n"
                "  (Chrome ki cookies Windows par yt-dlp aksar read nahi kar pata — Firefox ya cookies.txt use karein.)")
    if ("could not copy" in low and "cookie" in low) or "app-bound" in low or "failed to decrypt" in low:
        return ("Browser cookies read nahi ho sakin. Chrome/Edge ki cookies Windows par encrypted hoti hain.\n"
                "Firefox select karein, ya 'Get cookies.txt LOCALLY' extension se cookies.txt bana kar "
                "Cookies → 'cookies.txt file...' chunein.")
    if "unsupported url" in low:
        return "Ye link supported nahi hai (yt-dlp ise nahi pehchanta).\n\n" + raw[:300]
    if "ffmpeg" in low and ("not found" in low or "not installed" in low):
        return "FFmpeg chahiye. Settings → Install missing tools dabayein, ya MP4 (single file) quality chunein."
    if "requested format is not available" in low:
        return "Ye quality ab available nahi. Dobara Analyze karke koi aur quality chunein."
    if "private video" in low or "video unavailable" in low:
        return "Video private / delete / region-blocked hai.\n\n" + raw[:300]
    if "http error 404" in low or "http error 410" in low:
        return "Link par file nahi mili (404). Link check karein."
    if "http error 403" in low:
        return "Server ne access deny kiya (403). Dobara Analyze karein, ya route badal kar dekhein."
    if "http error 429" in low:
        return "Bohat zyada requests (429). Thori der baad, ya Tor/proxy se try karein."
    if is_network_error(low):
        return "Network error: connection nahi ban saka. Internet / Tor / proxy check karein.\n\n" + raw[:300]
    return raw[:900] or exc.__class__.__name__


# ---------------------------------------------------------------------------- yt-dlp options


class _QuietLogger:
    def __init__(self):
        self.warnings = []

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        self.warnings.append(msg)

    def error(self, msg):
        pass


BROWSERS = ["None", "Chrome", "Edge", "Firefox", "Brave", "Opera", "Vivaldi", "Chromium"]


def base_opts(settings: dict, tools: Tools, proxy: str, cookies_browser: str = "None") -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "logger": _QuietLogger(),
        "socket_timeout": 30,
        "retries": 10,
        "extractor_retries": 3,
        "windowsfilenames": True,
        "trim_file_name": 160,
        "proxy": proxy or "",
    }
    rt, path = tools.js_runtime
    if rt:
        opts["js_runtimes"] = {rt: {"path": path}}
    if tools.ffmpeg:
        opts["ffmpeg_location"] = tools.ffmpeg
    if cookies_browser and cookies_browser.startswith("file:"):
        path = cookies_browser[5:]
        if not os.path.isfile(path):
            raise RouteError("Cookies file nahi mili: " + path)
        opts["cookiefile"] = path
    elif cookies_browser and cookies_browser != "None":
        opts["cookiesfrombrowser"] = (cookies_browser.lower(), None, None, None)
    return opts


# ---------------------------------------------------------------------------- analyze


class Choice:
    """One entry of the quality list."""

    def __init__(self, label, selector, kind, est=0, height=None, needs_ffmpeg=False):
        self.label = label
        self.selector = selector
        self.kind = kind  # video | mp3 | m4a
        self.est = est
        self.height = height
        self.needs_ffmpeg = needs_ffmpeg

    def __repr__(self):
        return f"Choice({self.label!r}, {self.selector!r})"


def _size(f):
    return f.get("filesize") or f.get("filesize_approx") or 0


def build_choices(info: dict, has_ffmpeg: bool):
    formats = info.get("formats") or []
    # yt-dlp: "none" = stream definitely absent, None = unknown (treat unknown as present)
    audio = [f for f in formats if f.get("vcodec") == "none" and f.get("acodec") not in (None, "none")]
    best_audio = max(audio, key=lambda f: f.get("abr") or f.get("tbr") or 0, default=None)
    audio_size = _size(best_audio) if best_audio else 0

    best_by_height = {}
    for f in formats:
        if f.get("vcodec") == "none" or not f.get("height"):
            continue
        if (f.get("protocol") or "").startswith("mhtml"):
            continue  # storyboards
        has_audio = f.get("acodec") != "none"
        if not has_audio and not has_ffmpeg:
            continue  # cannot merge without ffmpeg
        h = int(f["height"])
        score = (f.get("fps") or 0, 1 if (f.get("ext") == "mp4") else 0, f.get("tbr") or 0, 1 if has_audio else 0)
        if h not in best_by_height or score > best_by_height[h][0]:
            best_by_height[h] = (score, f)

    choices = []
    if not formats or not (best_by_height or audio):
        # direct file / site without a format list: just take the best single file
        return [Choice("Original file" + (f"  •  ~{fmt_bytes(_size(info))}" if _size(info) else ""), "b/best", "video", _size(info))]

    best_sel = "bv*+ba/b" if has_ffmpeg else "b"
    choices.append(Choice("Best quality (auto)", best_sel, "video", 0, None, has_ffmpeg))
    for h in sorted(best_by_height, reverse=True):
        f = best_by_height[h][1]
        has_audio = f.get("acodec") != "none"
        fps = int(f.get("fps") or 0)
        name = f"{h}p" + (f"{fps}" if fps > 30 else "")
        if has_audio:
            sel = f"{f['format_id']}/b[height<={h}]/b"
            est = _size(f)
            note = f"{f.get('ext', '?')}"
        else:
            sel = f"{f['format_id']}+ba/bv*[height<={h}]+ba/b[height<={h}]/b"
            est = _size(f) + audio_size if _size(f) else 0
            note = "mp4" if has_ffmpeg else f.get("ext", "?")
        label = f"{name}  •  {note}" + (f"  •  ~{fmt_bytes(est)}" if est else "")
        choices.append(Choice(label, sel, "video", est, h, not has_audio))

    if best_audio:
        if has_ffmpeg:
            choices.append(Choice("Audio MP3 (192 kbps)", "ba/b", "mp3", audio_size, None, True))
        choices.append(Choice("Audio M4A (original, no convert)", "ba[ext=m4a]/ba/b", "m4a", audio_size))
    return choices


class MediaInfo:
    def __init__(self, url, info, choices, proxy_used, warnings):
        self.url = url
        self.raw = info
        self.choices = choices
        self.proxy_used = proxy_used
        self.warnings = warnings
        self.title = info.get("title") or "Untitled media"
        self.uploader = info.get("uploader") or info.get("channel") or ""
        self.duration = info.get("duration")
        self.site = info.get("webpage_url_domain") or urlparse(url).netloc
        self.extractor = info.get("extractor_key") or info.get("extractor") or ""
        self.thumbnail = info.get("thumbnail")
        self.is_playlist = info.get("_type") in ("playlist", "multi_video")
        self.count = len([e for e in (info.get("entries") or []) if e]) if self.is_playlist else 1


# ---------------------------------------------------------------------------- X / Twitter fallback
# X hides many videos (e.g. "sensitive" posts) from logged-out visitors, so yt-dlp finds nothing.
# FxTwitter's public API returns the direct video.twimg.com files for those posts.
X_RE = re.compile(r"https?://(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com/"
                  r"(?:i/web/status/|i/status/|[^/?#]+/status(?:es)?/)(\d+)", re.I)


def x_lookup(url: str, proxy: str = "") -> dict | None:
    m = X_RE.search(url or "")
    if not m:
        return None
    tid = m.group(1)
    def get(u):
        try:
            return fetch_bytes(u, proxy)
        except Exception:
            return b""
    try:
        data = json.loads(get(f"https://api.fxtwitter.com/status/{tid}").decode("utf-8", "replace") or "{}")
    except Exception:
        data = {}
    tw = data.get("tweet") or {}
    vids = []
    for v in (tw.get("media") or {}).get("videos") or []:
        mp4 = [x for x in v.get("variants") or [] if x.get("content_type") == "video/mp4" and x.get("url")]
        best = max(mp4, key=lambda x: x.get("bitrate") or 0)["url"] if mp4 else v.get("url")
        if best:
            vids.append({"url": best, "w": v.get("width") or 0, "h": v.get("height") or 0,
                         "duration": v.get("duration") or 0, "thumb": v.get("thumbnail_url") or ""})
    text = tw.get("text") or ""
    author = (tw.get("author") or {}).get("screen_name") or ""
    if not vids:  # backup service
        vids, text, author = _vx_videos(get(f"https://api.vxtwitter.com/Twitter/status/{tid}"))
    if not vids:
        return None
    text = re.sub(r"\s+", " ", text).strip()
    return {"id": tid, "title": text[:90] or f"X video {tid}", "uploader": f"@{author}" if author else "",
            "videos": vids}


def _vx_videos(raw: bytes) -> tuple[list, str, str]:
    """api.vxtwitter.com answer -> (videos, text, author) in the same shape as the FxTwitter parser."""
    try:
        j = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return [], "", ""
    vids = []
    for m in j.get("media_extended") or []:
        if m.get("type") in ("video", "gif") and m.get("url"):
            size = m.get("size") or {}
            vids.append({"url": m["url"], "w": size.get("width") or 0, "h": size.get("height") or 0,
                         "duration": (m.get("duration_millis") or 0) / 1000, "thumb": m.get("thumbnail_url") or ""})
    return vids, j.get("text") or "", j.get("user_screen_name") or ""


def _x_media(url: str, x: dict, proxy: str, has_ffmpeg: bool, warns: list) -> "MediaInfo":
    v = x["videos"][0]
    info = {"title": x["title"], "uploader": x["uploader"], "duration": v["duration"] or None,
            "thumbnail": v["thumb"] or None, "webpage_url_domain": "x.com", "extractor_key": "X (FxTwitter)",
            "id": x["id"]}
    res = min(v["w"], v["h"]) if v["w"] and v["h"] else 0
    choices = [Choice(f"Best quality  •  {res}p mp4" if res else "Best quality  •  mp4", "b/best", "video", 0, res or None)]
    if has_ffmpeg:
        choices.append(Choice("Audio MP3 (192 kbps)", "b/best", "mp3", 0, None, True))
    if len(x["videos"]) > 1:
        warns.append(f"Is post mein {len(x['videos'])} videos hain - pehli wali download hogi.")
    mi = MediaInfo(v["url"], info, choices, proxy, warns)
    mi.site = "x.com"
    return mi


def analyze(url: str, settings: dict, tools: Tools, net: NetworkState, playlist=False, cookies="None") -> MediaInfo:
    url = (url or "").strip()
    m = re.search(r"https?://\S+", url)
    if not m:
        raise ValueError("Poora link paste karein (http:// ya https:// se shuru).")
    url = m.group(0).rstrip(").,;!")

    def run(proxy):
        opts = base_opts(settings, tools, proxy, cookies)
        opts.update({"skip_download": True, "noplaylist": not playlist})
        if playlist:
            opts["extract_flat"] = "in_playlist"
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            info = ydl.sanitize_info(info)
        return info, opts["logger"].warnings

    if net.mode == "auto":
        net.refresh_tor()
    proxy = net.proxy()
    is_x = bool(X_RE.search(url))
    try:
        info, warns = run(proxy)
        if is_x and not (info.get("formats") or info.get("url") or info.get("entries")):
            raise ValueError("No video could be found in this tweet")
    except Exception as exc:
        if is_x:
            # X hides the video from logged-out users -> ask FxTwitter for the direct file
            x = x_lookup(url, proxy)
            if x:
                return _x_media(url, x, proxy, bool(tools.ffmpeg), ["X video FxTwitter ke zariye mili."])
        if net.can_bypass_tor(proxy) and is_bot_check(str(exc)):
            # Auto mode: YouTube blocks Tor exits -> same request on Direct
            info, warns = run("")
            proxy = ""
            warns.append("YouTube ne Tor block kiya, is liye Direct use hua.")
        else:
            fb = net.fallback_proxy(proxy) if is_network_error(str(exc)) else None
            if not fb:
                raise
            info, warns = run(fb)
            proxy = fb

    if info.get("_type") in ("playlist", "multi_video") and not playlist:
        entries = [e for e in (info.get("entries") or []) if e]
        if entries:
            info = entries[0]
    if info.get("_type") in ("playlist", "multi_video"):
        choices = [
            Choice("Best quality (auto)", "bv*+ba/b" if tools.ffmpeg else "b", "video", 0, None, bool(tools.ffmpeg)),
            *[Choice(f"Up to {h}p", (f"bv*[height<={h}]+ba/b[height<={h}]/b" if tools.ffmpeg else f"b[height<={h}]/b"),
                     "video", 0, h) for h in (1080, 720, 480, 360)],
            *([Choice("Audio MP3 (192 kbps)", "ba/b", "mp3", 0, None, True)] if tools.ffmpeg else []),
            Choice("Audio M4A (original, no convert)", "ba[ext=m4a]/ba/b", "m4a"),
        ]
    else:
        choices = build_choices(info, bool(tools.ffmpeg))
    return MediaInfo(url, info, choices, proxy, warns)


# ---------------------------------------------------------------------------- downloads


class Task:
    QUEUED, RUNNING, PROCESSING, PAUSED, DONE, FAILED, CANCELED = (
        "Queued", "Downloading", "Processing", "Paused", "Completed", "Failed", "Canceled")

    def __init__(self, url, title, choice: Choice, outdir, playlist=False, cookies="None",
                 embed_thumb=False, write_meta=False, subtitles=False):
        self.id = uuid.uuid4().hex[:12]
        self.url = url
        self.title = title
        self.choice = choice
        self.outdir = outdir
        self.playlist = playlist
        self.cookies = cookies
        self.embed_thumb = embed_thumb
        self.write_meta = write_meta
        self.subtitles = subtitles
        self.status = Task.QUEUED
        self.downloaded = 0
        self.total = 0
        self.speed = 0.0
        self.eta = None
        self.item = ""  # "3/20" for playlists
        self.stage = ""
        self.error = ""
        self.files = []
        self.route = ""
        self.part_files = set()
        self._cancel = threading.Event()
        self._pause = threading.Event()
        self.thread = None

    @property
    def percent(self):
        return (self.downloaded / self.total * 100) if self.total else 0.0

    @property
    def final_file(self):
        return self.files[-1] if self.files else None


class Manager:
    """Owns settings, history, network and the download queue.

    Worker threads never touch the GUI. They push ("task", task_id) / ("info", text)
    events into `events`; the GUI drains that queue on its own thread.
    """

    def __init__(self):
        migrate_legacy()
        self.settings = load_json(CONFIG_FILE, {})
        self._defaults()
        self.history = load_json(HISTORY_FILE, [])
        if not isinstance(self.history, list):
            self.history = []
        self.tools = Tools()
        self.net = NetworkState(self.settings)
        self.tasks: list[Task] = []
        self.events: "queue.Queue[tuple]" = queue.Queue()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        threading.Thread(target=self._tor_watch, daemon=True).start()

    def _defaults(self):
        s = self.settings
        legacy_mode = s.get("proxy_mode")
        if "route" not in s:
            # migrate v2.x proxy settings
            url = (s.get("proxy_url") or "").lower()
            if url.startswith("socks5h://127.0.0.1:9150") or url.startswith("socks5h://127.0.0.1:9050"):
                s["route"] = "tor"
            elif legacy_mode in ("HTTP Proxy", "SOCKS5 Proxy") and url:
                s["route"] = "proxy"
                s["proxy_kind"] = "socks5" if legacy_mode == "SOCKS5 Proxy" else "http"
            else:
                s["route"] = "auto"
        s.setdefault("proxy_kind", "http")
        s.setdefault("proxy_url", "")
        s.setdefault("smart_network", True)
        s.setdefault("theme", "dark")
        s.setdefault("browser", "None")
        s.setdefault("output_dir", os.path.join(os.path.expanduser("~"), "Downloads"))
        s.setdefault("max_parallel", 2)
        s.setdefault("use_aria2c", False)
        s.setdefault("tunnel_host", "")
        s.setdefault("tunnel_port", "22")
        s.setdefault("tunnel_user", "")
        s.setdefault("tunnel_key", "")
        s.setdefault("tunnel_local_port", "1080")

    def save_settings(self):
        save_json(CONFIG_FILE, self.settings)

    def shutdown(self):
        self._stop.set()
        for t in self.tasks:
            if t.status in (Task.RUNNING, Task.PROCESSING, Task.QUEUED):
                t._cancel.set()
        self.net.tunnel.disconnect()
        self.save_settings()

    # -------------------------------------------------------------- tor watcher

    def _tor_watch(self):
        last = object()
        while not self._stop.is_set():
            port = self.net.refresh_tor()
            if port != last:
                last = port
                self.events.put(("route", None))
            if self.net.tunnel.proc is not None and not self.net.tunnel.connected:
                self.net.tunnel.proc = None
                self.events.put(("route", None))
            self._stop.wait(3)

    # -------------------------------------------------------------- queue

    def add(self, task: Task):
        with self._lock:
            self.tasks.insert(0, task)
        self.events.put(("task", task.id))
        self._pump()
        return task

    def find(self, tid):
        for t in self.tasks:
            if t.id == tid:
                return t
        return None

    def _running(self):
        return sum(1 for t in self.tasks if t.status in (Task.RUNNING, Task.PROCESSING))

    def _pump(self):
        with self._lock:
            limit = max(1, int(self.settings.get("max_parallel", 2)))
            for t in reversed(self.tasks):
                if self._running() >= limit:
                    break
                if t.status == Task.QUEUED and (t.thread is None or not t.thread.is_alive()):
                    t.status = Task.RUNNING
                    t._cancel.clear()
                    t._pause.clear()
                    t.thread = threading.Thread(target=self._worker, args=(t,), daemon=True)
                    t.thread.start()

    def cancel(self, tid):
        t = self.find(tid)
        if not t:
            return
        if t.status in (Task.RUNNING, Task.PROCESSING):
            t._cancel.set()
        elif t.status in (Task.QUEUED, Task.PAUSED):
            t.status = Task.CANCELED
            self.events.put(("task", t.id))

    def pause(self, tid):
        t = self.find(tid)
        if not t:
            return
        if t.status == Task.RUNNING:
            t._pause.set()
        elif t.status == Task.QUEUED:
            t.status = Task.PAUSED
            self.events.put(("task", t.id))

    def resume(self, tid):
        t = self.find(tid)
        if t and t.status in (Task.PAUSED, Task.FAILED, Task.CANCELED):
            t.status = Task.QUEUED
            t.error = ""
            self.events.put(("task", t.id))
            self._pump()

    def remove(self, tid):
        t = self.find(tid)
        if t and t.status not in (Task.RUNNING, Task.PROCESSING):
            with self._lock:
                self.tasks.remove(t)
            self.events.put(("removed", t.id))

    def clear_finished(self):
        with self._lock:
            gone = [t for t in self.tasks if t.status in (Task.DONE, Task.CANCELED)]
            for t in gone:
                self.tasks.remove(t)
        for t in gone:
            self.events.put(("removed", t.id))

    # -------------------------------------------------------------- worker

    def _opts_for(self, t: Task, proxy: str):
        opts = base_opts(self.settings, self.tools, proxy, t.cookies)
        tmpl = "%(title)s [%(id)s].%(ext)s"
        if "video.twimg.com" in (t.url or ""):
            # direct X file (FxTwitter): its own "title" is just "464" -> use the tweet text
            safe = re.sub(r'[\\/:*?"<>|\r\n\t%]+', " ", t.title or "X video").strip()[:80] or "X video"
            tmpl = safe + " [X].%(ext)s"
        if t.playlist:
            tmpl = os.path.join("%(playlist_title|Playlist)s", "%(playlist_index|0)03d - " + tmpl)
        opts.update({
            "format": t.choice.selector,
            "outtmpl": os.path.join(t.outdir, tmpl),
            "noplaylist": not t.playlist,
            "continuedl": True,
            "fragment_retries": 10,
            "file_access_retries": 5,
            "concurrent_fragment_downloads": 6,
            "ignoreerrors": "only_download" if t.playlist else False,
            "progress_hooks": [lambda d: self._progress(t, d)],
            "postprocessor_hooks": [lambda d: self._pp(t, d)],
            "post_hooks": [lambda path: self._finished_file(t, path)],
        })
        pps = []
        if t.choice.kind == "mp3" and self.tools.ffmpeg:
            pps.append({"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"})
        elif t.choice.kind == "video" and self.tools.ffmpeg:
            opts["merge_output_format"] = "mp4/mkv"
        if t.embed_thumb and self.tools.ffmpeg:
            opts["writethumbnail"] = True
            pps.append({"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"})
            pps.append({"key": "EmbedThumbnail"})
        if t.write_meta and self.tools.ffmpeg:
            pps.append({"key": "FFmpegMetadata", "add_metadata": True})
        if t.subtitles:
            opts.update({"writesubtitles": True, "subtitleslangs": ["en.*", "ur", "hi"], "subtitlesformat": "srt/best"})
            if self.tools.ffmpeg and t.choice.kind == "video":
                pps.append({"key": "FFmpegEmbedSubtitle"})
        if pps:
            opts["postprocessors"] = pps
        # aria2c cannot use SOCKS (Tor) - only allow it on a direct connection
        if self.settings.get("use_aria2c") and self.tools.aria2c and not proxy:
            opts["external_downloader"] = {"default": self.tools.aria2c}
            opts["external_downloader_args"] = {"aria2c": ["-x", "16", "-s", "16", "-k", "1M",
                                                           "--file-allocation=none", "--console-log-level=warn"]}
        return opts

    def _progress(self, t: Task, d: dict):
        if t._cancel.is_set():
            raise yt_dlp.utils.DownloadCancelled("Canceled")
        if t._pause.is_set():
            raise yt_dlp.utils.DownloadCancelled("Paused")
        st = d.get("status")
        info = d.get("info_dict") or {}
        if info.get("title") and not t.playlist:
            t.title = info["title"]
        idx, n = info.get("playlist_index"), info.get("n_entries") or info.get("playlist_count")
        if idx and n:
            t.item = f"{idx}/{n}"
        if d.get("tmpfilename"):
            t.part_files.add(d["tmpfilename"])
        if st == "downloading":
            t.status = Task.RUNNING
            t.total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            t.downloaded = d.get("downloaded_bytes") or 0
            t.speed = d.get("speed") or 0
            t.eta = d.get("eta")
            t.stage = ""
        elif st == "finished":
            t.downloaded = t.total = d.get("total_bytes") or t.downloaded or t.total
            t.speed = 0
            t.stage = "Processing..."
        self.events.put(("task", t.id))

    def _pp(self, t: Task, d: dict):
        if t._cancel.is_set():
            raise yt_dlp.utils.DownloadCancelled("Canceled")
        if d.get("status") == "started":
            t.status = Task.PROCESSING
            names = {"Merger": "Merging video + audio", "ExtractAudio": "Converting to MP3",
                     "EmbedThumbnail": "Adding thumbnail", "Metadata": "Writing metadata"}
            pp = d.get("postprocessor") or ""
            t.stage = next((v for k, v in names.items() if k in pp), f"{pp}...")
            self.events.put(("task", t.id))

    def _finished_file(self, t: Task, path):
        if path and path not in t.files:
            t.files.append(path)

    def _worker(self, t: Task):
        os.makedirs(t.outdir, exist_ok=True)
        try:
            if self.net.mode == "auto":
                self.net.refresh_tor()
            proxy = self.net.proxy()
            t.route = route_name(proxy)
            try:
                self._run_ydl(t, proxy)
            except yt_dlp.utils.DownloadCancelled:
                raise
            except Exception as exc:
                if t._cancel.is_set() or t._pause.is_set():
                    raise
                if self.net.can_bypass_tor(proxy) and is_bot_check(str(exc)):
                    t.route = "Direct (YouTube blocks Tor)"
                    self._run_ydl(t, "")
                else:
                    fb = self.net.fallback_proxy(proxy) if is_network_error(str(exc)) else None
                    if not fb:
                        raise
                    t.route = "Tor (smart fallback)"
                    self._run_ydl(t, fb)
            t.status = Task.DONE
            t.stage = ""
            t.downloaded = t.total = t.total or t.downloaded
            self._add_history(t)
        except yt_dlp.utils.DownloadCancelled:
            if t._pause.is_set() and not t._cancel.is_set():
                t.status = Task.PAUSED
            else:
                t.status = Task.CANCELED
                self._cleanup_parts(t)
        except Exception as exc:
            if t._cancel.is_set():
                t.status = Task.CANCELED
            else:
                t.status = Task.FAILED
                t.error = friendly_error(exc)
        finally:
            t.speed = 0
            self.events.put(("task", t.id))
            self._pump()

    def _run_ydl(self, t, proxy):
        with yt_dlp.YoutubeDL(self._opts_for(t, proxy)) as ydl:
            code = ydl.download([t.url])
        if t._cancel.is_set():
            raise yt_dlp.utils.DownloadCancelled("Canceled")
        if code and not t.files:
            raise RuntimeError("Download fail ho gaya (koi file nahi bani).")

    def _cleanup_parts(self, t: Task):
        """Remove only the temp files this task created (never touches other files)."""
        for p in list(t.part_files):
            for cand in (p, p + ".ytdl", p if p.endswith(".part") else p + ".part"):
                try:
                    if os.path.isfile(cand) and cand.endswith((".part", ".ytdl")):
                        os.remove(cand)
                except Exception:
                    pass
        t.part_files.clear()

    # -------------------------------------------------------------- history

    def _add_history(self, t: Task):
        item = {
            "date": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "title": t.title,
            "url": t.url,
            "site": urlparse(t.url).netloc.replace("www.", ""),
            "quality": t.choice.label.split("  •  ")[0],
            "folder": t.outdir,
            "file": t.final_file or "",
            "count": len(t.files),
            "route": t.route,
        }
        with self._lock:
            self.history.append(item)
            self.history = self.history[-1000:]
            data = list(self.history)
        save_json(HISTORY_FILE, data)
        self.events.put(("history", None))

    def clear_history(self):
        self.history = []
        save_json(HISTORY_FILE, [])
        self.events.put(("history", None))

    def remove_history(self, item):
        try:
            self.history.remove(item)
        except ValueError:
            return
        save_json(HISTORY_FILE, self.history)
        self.events.put(("history", None))


def test_route(net: NetworkState, tools: Tools) -> float:
    """Fetch a tiny page through the current route. Returns seconds."""
    proxy = net.proxy()
    opts = base_opts({}, tools, proxy)
    start = time.time()
    with yt_dlp.YoutubeDL(opts) as ydl:
        r = ydl.urlopen("https://www.gstatic.com/generate_204")
        r.read()
    return time.time() - start


def fetch_bytes(url: str, proxy: str, limit=2_000_000) -> bytes:
    """Small downloads (thumbnails) through the same route as yt-dlp."""
    with yt_dlp.YoutubeDL({"quiet": True, "proxy": proxy or "", "logger": _QuietLogger()}) as ydl:
        return ydl.urlopen(url).read(limit)


def find_tor_browser():
    if not IS_WIN:
        return shutil.which("torbrowser-launcher") or shutil.which("tor-browser")
    home = os.path.expanduser("~")
    roots = [os.path.join(home, "Desktop"), os.path.join(home, "Downloads"), os.path.join(home, "OneDrive", "Desktop"),
             os.environ.get("PROGRAMFILES", ""), os.environ.get("PROGRAMFILES(X86)", ""),
             os.environ.get("LOCALAPPDATA", "")]
    for r in roots:
        p = os.path.join(r, "Tor Browser", "Browser", "firefox.exe")
        if r and os.path.exists(p):
            return p
    return None


def find_chrome():
    cands = []
    if IS_WIN:
        local = os.environ.get("LOCALAPPDATA", "")
        for base in (os.environ.get("PROGRAMFILES", ""), os.environ.get("PROGRAMFILES(X86)", ""), local):
            cands += [os.path.join(base, "Google", "Chrome", "Application", "chrome.exe"),
                      os.path.join(base, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
                      os.path.join(base, "Microsoft", "Edge", "Application", "msedge.exe")]
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "brave-browser"):
        p = shutil.which(name)
        if p:
            cands.append(p)
    return next((p for p in cands if p and os.path.exists(p)), None)
