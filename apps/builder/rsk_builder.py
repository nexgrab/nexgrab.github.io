"""NexGrab Builder - one-click GUI that builds the Android APK and the Windows EXE.

* live progress (overall + current step), step list, timer, live log
* before building: Flutter upgrade, Dart packages upgrade, yt-dlp Android library patch update
* keeps Gradle / Flutter caches + Temp on the drive with the most space (L: if present),
  so C: does not fill up
* wraps android\\MAKE_APK.cmd and pc\\build_exe.bat (they still work on their own)
"""
from __future__ import annotations

import json
import os
import queue
import re
import shutil
import string
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

import customtkinter as ctk

APP = "NexGrab Builder"
VERSION = "3.2"
IS_WIN = os.name == "nt"
NO_WINDOW = 0x08000000 if IS_WIN else 0
NEW_GROUP = 0x00000200 if IS_WIN else 0

BG = "#060a13"
CARD = "#0d1424"
CARD2 = "#111a2e"
BORDER = "#1c2a45"
CYAN = "#22d3ee"
PURPLE = "#8b5cf6"
GREEN = "#22c55e"
RED = "#ef4444"
AMBER = "#f59e0b"
TEXT = "#e6edf7"
MUTED = "#8394b4"

DEBUG = open(os.environ["RSK_DEBUG"], "a") if os.environ.get("RSK_DEBUG") else None
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
YTDL_DEP = re.compile(r"(youtubedl-android:(?:library|ffmpeg):)(\d+)\.(\d+)\.(\d+)")


# ----------------------------------------------------------------------------- paths
def project_root() -> Path:
    here = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
    for p in (here, here.parent, here.parent / "NexGrab"):
        if (p / "android" / "MAKE_APK.cmd").exists():
            return p
    return here


ROOT = project_root()
SETTINGS = ROOT / "builder_settings.json"
OUTDIR = ROOT / "OUTPUT"


def resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", ROOT / "pc"))
    for p in (base / "assets" / name, ROOT / "pc" / "assets" / name):
        if p.exists():
            return p
    return base / name


def load_settings() -> dict:
    try:
        return json.loads(SETTINGS.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_settings(s: dict) -> None:
    try:
        SETTINGS.write_text(json.dumps(s, indent=2), encoding="utf-8")
    except Exception:
        pass


def copy_file(src, dst, *, follow_symlinks=True) -> str:
    """Plain stream copy (avoids CopyFile2, which crashes under some setups)."""
    with open(src, "rb") as a, open(dst, "wb") as b:
        shutil.copyfileobj(a, b, 1024 * 1024)
    try:
        shutil.copystat(src, dst)
    except OSError:
        pass
    return str(dst)


def dir_size(paths) -> int:
    total = 0
    for p in paths:
        for root, _dirs, files in os.walk(p):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    return total


def http_get(url: str, timeout: int = 25) -> bytes:
    """Windows: use PowerShell (system TLS + proxy). Fallback: urllib."""
    if IS_WIN:
        try:
            ps = ("[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;"
                  f"(Invoke-WebRequest -UseBasicParsing -TimeoutSec {timeout} -Uri '{url}').Content")
            r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True,
                               timeout=timeout + 15, creationflags=NO_WINDOW)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout
        except Exception:
            pass
    import ssl
    ctx = ssl.create_default_context()
    try:
        import certifi  # type: ignore
        ctx.load_verify_locations(certifi.where())
    except Exception:
        pass
    with urllib.request.urlopen(url, timeout=timeout, context=ctx) as r:
        return r.read()


def free_gb(path: str) -> float | None:
    try:
        return shutil.disk_usage(path).free / 1024**3
    except Exception:
        return None


def drives() -> dict[str, float]:
    out = {}
    if not IS_WIN:
        g = free_gb("/")
        return {"/": g} if g is not None else {}
    for letter in string.ascii_uppercase:
        root = f"{letter}:\\"
        if os.path.exists(root):
            g = free_gb(root)
            if g is not None:
                out[f"{letter}:"] = g
    return out


def drive_of(path: str) -> str:
    return os.path.splitdrive(os.path.abspath(path))[0].upper() or "/"


def pick_cache_root() -> tuple[str | None, str]:
    """Where Gradle / pub / temp should live. Returns (folder or None=leave default, reason)."""
    env_g = os.environ.get("GRADLE_USER_HOME", "")
    if env_g and os.path.exists(drive_of(env_g) + os.sep):
        return str(Path(env_g).parent), "aap ki setting (GRADLE_USER_HOME)"
    d = drives()
    if not IS_WIN or not d:
        return None, "default"
    cands = {k: v for k, v in d.items() if k != "C:" and v >= 20}
    if "L:" in cands:
        best = "L:"
    elif cands:
        best = max(cands, key=cands.get)
    else:
        return None, "sirf C: drive"
    if d.get("C:", 0) >= 60 and d[best] < d["C:"]:
        return None, "C: par kaafi jagah"
    return f"{best}\\DevCache", f"{best} par sab se zyada jagah"


def find_flutter() -> str | None:
    for name in ("flutter.bat", "flutter"):
        w = shutil.which(name)
        if w:
            return w
    fr = os.environ.get("FLUTTER_ROOT")
    cands = [Path(fr) / "bin" / "flutter.bat"] if fr else []
    roots = [f"{k}\\" for k in drives()] if IS_WIN else []
    for r in roots:
        for pat in ("flutter\\bin\\flutter.bat", "src\\flutter\\bin\\flutter.bat", "dev\\flutter\\bin\\flutter.bat",
                    "flutter*\\flutter\\bin\\flutter.bat", "flutter*\\bin\\flutter.bat"):
            cands += sorted(Path(r).glob(pat), reverse=True)
    home = Path.home()
    for sub in ("flutter", "dev\\flutter", "Documents\\flutter", "Downloads\\flutter", "Desktop\\flutter"):
        cands.append(home / sub / "bin" / "flutter.bat")
    for c in cands:
        try:
            if c.exists():
                return str(c)
        except OSError:
            pass
    return None


def decode(b: bytes) -> str:
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        s = b.decode("cp437" if not IS_WIN else f"cp{_oemcp()}", errors="replace")
    return ANSI.sub("", s).rstrip("\r\n")


def _oemcp() -> int:
    try:
        import ctypes
        return ctypes.windll.kernel32.GetOEMCP()
    except Exception:
        return 437


# ----------------------------------------------------------------------------- stages
@dataclass
class Stage:
    key: str
    title: str
    weight: float
    est: float  # expected seconds (overwritten by history)
    state: str = "wait"  # wait | run | done | fail | skip
    started: float = 0.0
    ended: float = 0.0
    frac: float = 0.0
    detail: str = ""


APK_STEPS = [
    ("a1", "Java 17", 2, 15), ("a2", "Flutter", 3, 40), ("a3", "Android SDK", 5, 60),
    ("a4", "Project files", 3, 40), ("a5", "Flutter packages", 5, 60),
    ("a6", "APK build (Gradle)", 62, 600), ("a7", "Final APK", 2, 5),
]
EXE_STEPS = [
    ("e1", "Python", 3, 10), ("e2", "Python packages update", 25, 120), ("e3", "Icon", 2, 5),
    ("e4", "Purani build saaf", 2, 5), ("e5", "EXE build (PyInstaller)", 45, 240), ("e6", "Release folder", 8, 40),
]


@dataclass
class Plan:
    target: str
    update: bool
    stages: list[Stage] = field(default_factory=list)

    @staticmethod
    def make(target: str, update: bool, hist: dict) -> "Plan":
        p = Plan(target, update)

        def add(k, t, w, e):
            p.stages.append(Stage(k, t, w, float(hist.get(k, e))))

        add("prep", "Tayyari: disk + cache drive", 1, 2)
        if update:
            add("upd", "Flutter + libraries update", 8, 90)
        if target in ("apk", "both"):
            for s in APK_STEPS:
                add(*s)
        if target in ("exe", "both"):
            for s in EXE_STEPS:
                add(*s)
        if target != "update":
            add("out", "OUTPUT folder", 1, 3)
        return p

    def get(self, key: str) -> Stage | None:
        return next((s for s in self.stages if s.key == key), None)

    def overall(self) -> float:
        tot = sum(s.weight for s in self.stages if s.state != "skip") or 1
        done = 0.0
        for s in self.stages:
            if s.state in ("done",):
                done += s.weight
            elif s.state in ("run", "fail"):
                done += s.weight * s.frac
        return min(1.0, done / tot)


class Stopped(Exception):
    pass


class BuildFailed(Exception):
    pass


# ----------------------------------------------------------------------------- worker
class Builder:
    """Runs on a background thread; talks to the UI only through `events`."""

    def __init__(self, plan: Plan, events: queue.Queue, settings: dict):
        self.plan = plan
        self.ev = events
        self.settings = settings
        self.proc: subprocess.Popen | None = None
        self.stop_flag = False
        self.cur: Stage | None = None
        self.tasks = 0
        self.flutter = find_flutter()
        self.env = dict(os.environ)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        (OUTDIR / "logs").mkdir(parents=True, exist_ok=True)
        self.log_path = OUTDIR / "logs" / f"build_{stamp}.log"
        self.logf = open(self.log_path, "w", encoding="utf-8", errors="replace")
        self.tail: list[str] = []
        self.last_line = time.time()

    # -- messaging
    def log(self, line: str, show: bool = True, tag: str = "") -> None:
        self.logf.write(line + "\n")
        self.logf.flush()
        self.tail.append(line)
        if len(self.tail) > 400:
            del self.tail[:200]
        if show:
            self.ev.put(("log", line, tag))

    def start(self, key: str, detail: str = "") -> None:
        st = self.plan.get(key)
        if not st:
            return
        if self.cur and self.cur is not st and self.cur.state == "run":
            self.finish(self.cur)
        st.state, st.started, st.frac, st.detail = "run", time.time(), 0.0, detail
        self.cur = st
        self.log(f"=== {st.title} ===", tag="head")
        self.ev.put(("stage",))

    def finish(self, st: Stage) -> None:
        st.state, st.ended, st.frac = "done", time.time(), 1.0
        self.ev.put(("stage",))

    def check_stop(self) -> None:
        if self.stop_flag:
            raise Stopped()

    # -- process runner
    def run(self, cmd: str, cwd: Path, on_line=None, show=None) -> int:
        self.check_stop()
        self.log(f"> {cmd}", tag="cmd")
        self.proc = subprocess.Popen(
            cmd, cwd=str(cwd), env=self.env, shell=not IS_WIN if not IS_WIN else False,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=NO_WINDOW | NEW_GROUP)
        assert self.proc.stdout is not None
        for raw in iter(self.proc.stdout.readline, b""):
            self.last_line = time.time()
            line = decode(raw)
            if not line.strip():
                continue
            vis = show(line) if show else True
            self.log(line, show=vis, tag=self._tag(line))
            if on_line:
                on_line(line)
        rc = self.proc.wait()
        self.proc = None
        self.check_stop()
        return rc

    @staticmethod
    def _tag(line: str) -> str:
        l = line.lower()
        if "error" in l or "failed" in l or "failure" in l or "exception" in l:
            return "err"
        if "success" in l or "ready" in l or "mukammal" in l or line.strip().startswith(("OK", "√", "✓")):
            return "ok"
        if "warning" in l or "[!]" in l:
            return "warn"
        return ""

    def kill(self) -> None:
        self.stop_flag = True
        p = self.proc
        if p and p.poll() is None:
            try:
                if IS_WIN:
                    subprocess.run(f"taskkill /T /F /PID {p.pid}", creationflags=NO_WINDOW,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    p.kill()
            except Exception:
                pass

    @staticmethod
    def bat(path: Path, *args: str) -> str:
        a = " ".join(args)
        return f'cmd /s /c ""{path}" {a}"'

    def flutter_cmd(self, args: str) -> str:
        return f'cmd /s /c ""{self.flutter}" {args}"'

    # -- pipeline
    def go(self) -> None:
        ok = False
        try:
            self.prepare()
            if self.plan.get("upd"):
                self.updates()
            if self.plan.target in ("apk", "both"):
                self.build_apk()
            if self.plan.target in ("exe", "both"):
                self.build_exe()
            if self.plan.get("out"):
                self.outputs()
            if self.cur and self.cur.state == "run":
                self.finish(self.cur)
            ok = True
            hist = self.settings.setdefault("durations", {})
            for s in self.plan.stages:
                if s.state == "done" and s.ended > s.started > 0 and s.key not in ("prep", "out"):
                    hist[s.key] = round(s.ended - s.started, 1)
            if self.tasks > 20:
                self.settings["apk_tasks"] = self.tasks
            save_settings(self.settings)
            self.ev.put(("done", True, self.result_text()))
        except Stopped:
            self.fail_cur("Aap ne STOP kiya.")
            self.ev.put(("done", False, "Build roki gayi (STOP)."))
        except BuildFailed as e:
            self.fail_cur(str(e))
            self.ev.put(("done", False, str(e)))
        except Exception as e:  # noqa: BLE001
            self.log(traceback.format_exc(), tag="err")
            self.fail_cur(str(e))
            self.ev.put(("done", False, f"Ghalti: {e}"))
        finally:
            self.log(f"Log file: {self.log_path}")
            self.logf.close()
            self.ev.put(("finished", ok))

    def fail_cur(self, msg: str) -> None:
        if self.cur and self.cur.state == "run":
            self.cur.state = "fail"
            self.cur.detail = msg[:120]
        self.log(msg, tag="err")
        self.ev.put(("stage",))

    def prepare(self) -> None:
        self.start("prep")
        if not (ROOT / "android" / "MAKE_APK.cmd").exists():
            raise BuildFailed(f"Project folder nahi mila. NexGrab Builder.exe ko project folder mein rakhein.\n({ROOT})")
        cache, why = pick_cache_root()
        if cache:
            for sub, var in (("gradle-home", "GRADLE_USER_HOME"), ("pub-cache", "PUB_CACHE")):
                if var not in os.environ:
                    Path(cache, sub).mkdir(parents=True, exist_ok=True)
                    self.env[var] = str(Path(cache, sub))
            t = Path(cache, "Temp")
            t.mkdir(parents=True, exist_ok=True)
            self.env["TEMP"] = self.env["TMP"] = str(t)
            self.log(f"Cache drive: {cache}  ({why})", tag="ok")
        else:
            self.log(f"Cache: default jagah ({why})")
        self.ev.put(("cache", cache or "default"))
        if self.flutter:
            self.env["PATH"] = str(Path(self.flutter).parent) + os.pathsep + self.env.get("PATH", "")
            self.env["FLUTTER_ROOT"] = str(Path(self.flutter).parent.parent)
            self.log(f"Flutter: {self.flutter}")
        elif self.plan.target in ("apk", "both", "update"):
            self.log("Flutter PATH mein nahi mila - builder khud dhoondega / download karega.", tag="warn")
        # disk space
        need = []
        pd = drive_of(str(ROOT))
        g = free_gb(pd + os.sep) if IS_WIN else free_gb(str(ROOT))
        if g is not None:
            self.log(f"Project drive {pd}: {g:.1f} GB khali")
            if g < 4 and self.plan.target != "update":
                need.append(f"{pd} par {g:.1f} GB (kam az kam 4 GB chahiye)")
        cd = drive_of(self.env.get("GRADLE_USER_HOME", str(Path.home())))
        g2 = free_gb(cd + os.sep) if IS_WIN else None
        if g2 is not None and cd != pd:
            self.log(f"Cache drive {cd}: {g2:.1f} GB khali")
            if g2 < 3:
                need.append(f"{cd} par {g2:.1f} GB (kam az kam 3 GB chahiye)")
        if need:
            raise BuildFailed("Disk par jagah kam hai: " + "; ".join(need) +
                              '\n"C: saaf karo" button dabayein ya project L: drive par rakhein.')
        self.finish(self.cur)

    def updates(self) -> None:
        self.start("upd")
        st = self.cur
        assert st is not None
        # 1) Flutter upgrade
        if self.flutter:
            lock = Path(self.flutter).parent / "cache" / "lockfile"
            try:
                lock.unlink()
            except OSError:
                pass
            if shutil.which("git", path=self.env.get("PATH")):
                st.detail = "flutter upgrade"
                self.ev.put(("stage",))
                rc = self.run(self.flutter_cmd("upgrade --force"), ROOT / "android")
                if rc != 0:
                    self.log("[!] Flutter upgrade nahi hua - purana Flutter use hoga.", tag="warn")
            else:
                self.log("[!] Git nahi mila - Flutter upgrade skip (Git: https://git-scm.com/download/win).", tag="warn")
            st.frac = 0.6
            vers = []
            self.run(self.flutter_cmd("--version"), ROOT / "android",
                     on_line=lambda l: vers.append(l) if l.startswith("Flutter ") else None)
            if vers:
                mv = re.search(r"\d+\.\d+\.\d+", vers[0])
                self.ev.put(("flutter", mv.group(0) if mv else vers[0][:20]))
            # 2) Dart packages (within pubspec limits)
            st.detail = "flutter pub upgrade"
            self.ev.put(("stage",))
            if self.run(self.flutter_cmd("pub upgrade"), ROOT / "android") != 0:
                self.log("[!] pub upgrade nahi hua - purane packages chalenge.", tag="warn")
        st.frac = 0.85
        # 3) yt-dlp Android library: newest patch release of the same minor version
        st.detail = "yt-dlp library check"
        self.ev.put(("stage",))
        try:
            self.update_ytdl_lib()
        except Exception as e:  # noqa: BLE001
            self.log(f"[!] yt-dlp library check nahi hua ({e}) - maujooda version chalega.", tag="warn")
        self.settings["last_update"] = time.time()
        self.finish(st)

    def update_ytdl_lib(self) -> None:
        files = [ROOT / "android" / "android_template" / f"rsk_gradle_append.{e}" for e in ("kts", "groovy")]
        txt = files[0].read_text(encoding="utf-8")
        m = YTDL_DEP.search(txt)
        if not m:
            return
        cur = tuple(int(x) for x in m.groups()[1:])

        def versions(art: str) -> set[tuple[int, int, int]]:
            url = f"https://repo1.maven.org/maven2/io/github/junkfood02/youtubedl-android/{art}/maven-metadata.xml"
            root = ET.fromstring(http_get(url))
            out = set()
            for v in root.iter("version"):
                mm = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", (v.text or "").strip())
                if mm:
                    out.add(tuple(int(x) for x in mm.groups()))
            return out

        common = versions("library") & versions("ffmpeg")
        same = [v for v in common if v[:2] == cur[:2] and v > cur]  # only safe patch updates
        if not same:
            self.log(f"yt-dlp library {'.'.join(map(str, cur))} - latest hai.", tag="ok")
            return
        new = max(same)
        nv = ".".join(map(str, new))
        for f in files:
            t = f.read_text(encoding="utf-8")
            f.write_text(YTDL_DEP.sub(lambda mm: mm.group(1) + nv, t), encoding="utf-8", newline="")
        self.log(f"yt-dlp library update: {'.'.join(map(str, cur))} -> {nv}", tag="ok")

    def _apk_line(self, line: str) -> None:
        m = re.match(r"^\[(\d)/7\]", line.strip())
        if m:
            self.start(f"a{m.group(1)}")
            return
        st = self.cur
        if st and st.key == "a6" and "> Task :" in line:
            self.tasks += 1
            exp = max(60, int(self.settings.get("apk_tasks", 450)))
            st.frac = min(0.97, self.tasks / exp)
            task = line.split("> Task :", 1)[1].split()[0] if "> Task :" in line else ""
            st.detail = f"Gradle task {self.tasks}/~{exp}  {task}"
        elif st and ("MB in" in line or "Downloading" in line):
            st.detail = line.strip()[:90]

    def _apk_show(self, line: str) -> bool:
        if not (self.cur and self.cur.key == "a6"):
            return True
        l = line.lower()
        keys = ("> task :", "error", "failure", "what went wrong", "build ", "mb in", "warning:", "not enough space",
                "exception", "√", "✓", "built ", "[error]")
        return any(k in l for k in keys) or not line.lstrip().startswith("[")

    def _watch_downloads(self, proc_alive) -> None:
        """Gradle prints nothing while it downloads itself / libraries - show the MBs instead."""
        home = Path(self.env.get("GRADLE_USER_HOME") or Path.home() / ".gradle")
        dirs = [home / "wrapper" / "dists", home / "caches" / "modules-2" / "files-2.1"]
        base = dir_size(dirs)
        prev, prev_t, logged = base, time.time(), 0.0
        while proc_alive() and not self.stop_flag:
            time.sleep(3)
            st = self.cur
            if not st or st.key not in ("a5", "a6"):
                continue
            size = dir_size(dirs)
            now = time.time()
            speed = (size - prev) / max(0.5, now - prev_t)
            prev, prev_t = size, now
            got = size - base
            if got > 512 * 1024 and now - self.last_line > 4:
                txt = f"Gradle / libraries download: {got / 1048576:.0f} MB"
                if speed > 10 * 1024:
                    txt += f"  ·  {speed / 1048576:.1f} MB/s"
                st.detail = txt + "  ·  pehli dafa hai, intezar karein"
                if now - logged > 30:
                    logged = now
                    self.log(f"... {txt}")

    def build_apk(self) -> None:
        self.env["RSK_VERBOSE"] = "1"
        self.tasks = 0
        threading.Thread(target=self._watch_downloads, args=(lambda: self.proc is not None or not getattr(self, "_apk_done", False),),
                         daemon=True).start()
        self._apk_done = False
        rc = self.run(self.bat(ROOT / "android" / "MAKE_APK.cmd", "nopause"), ROOT / "android",
                      on_line=self._apk_line, show=self._apk_show)
        self._apk_done = True
        apk = ROOT / "android" / "APK" / "NexGrab.apk"
        if rc != 0 or not apk.exists():
            raise BuildFailed(self.explain("APK build fail hui."))
        if self.cur and self.cur.state == "run":
            self.finish(self.cur)

    def _exe_line(self, line: str) -> None:
        m = re.match(r"^\[(\d)/6\]", line.strip())
        if m:
            self.start(f"e{m.group(1)}")
        elif self.cur and self.cur.key in ("e2", "e5"):
            self.cur.detail = line.strip()[:90]

    def build_exe(self) -> None:
        rc = self.run(self.bat(ROOT / "pc" / "build_exe.bat", "nopause"), ROOT / "pc", on_line=self._exe_line)
        exe = ROOT / "pc" / "release" / "NexGrab" / "NexGrab.exe"
        if rc != 0 or not exe.exists():
            raise BuildFailed(self.explain("EXE build fail hui."))
        if self.cur and self.cur.state == "run":
            self.finish(self.cur)

    def explain(self, head: str) -> str:
        t = "\n".join(self.tail[-150:]).lower()
        if "not enough space" in t or "no space left" in t or "jagah kam" in t:
            return head + " Disk bhar gayi. \"C: saaf karo\" dabayein ya project L: par rakhein."
        if "could not resolve" in t or "unknownhost" in t or "connect timed out" in t or "connection reset" in t:
            return head + " Internet / download masla. Internet check karke dobara BUILD dabayein."
        if "flutter chal nahi raha" in t:
            return head + " Flutter nahi chala. Upar log dekhein."
        for line in reversed(self.tail[-150:]):
            if "[ERROR]" in line or "What went wrong" in line:
                return head + " " + line.strip()[:200]
        return head + " Neeche log dekhein (log file OUTPUT\\logs mein)."

    def outputs(self) -> None:
        self.start("out")
        res = []
        if self.plan.target in ("apk", "both"):
            d = OUTDIR / "Android"
            d.mkdir(parents=True, exist_ok=True)
            src = ROOT / "android" / "APK"
            for a, b in (("NexGrab.apk", f"NexGrab_v{VERSION}.apk"),
                         ("NexGrab_32bit.apk", f"NexGrab_v{VERSION}_32bit.apk")):
                if (src / a).exists():
                    copy_file(src / a, d / b)
                    res.append(str(d / b))
        if self.plan.target in ("exe", "both"):
            d = OUTDIR / "Windows"
            rel = ROOT / "pc" / "release"
            shutil.copytree(rel / "NexGrab", d / "NexGrab", dirs_exist_ok=True, copy_function=copy_file)
            z = rel / f"NexGrab_v{VERSION}_Windows.zip"
            if z.exists():
                copy_file(z, d / z.name)
            res.append(str(d / "NexGrab" / "NexGrab.exe"))
        self.results = res
        for r in res:
            self.log(f"READY: {r}", tag="ok")
        self.finish(self.cur)

    def result_text(self) -> str:
        if self.plan.target == "update":
            return "Flutter + libraries update mukammal."
        res = getattr(self, "results", [])
        apks = sum(1 for r in res if r.endswith(".apk"))
        exes = sum(1 for r in res if r.endswith(".exe"))
        parts = ([f"{apks} APK"] if apks else []) + (["Windows EXE"] if exes else [])
        return ("BUILD SUCCESS  -  " + " + ".join(parts) + " OUTPUT folder mein") if parts else "Mukammal."


# ----------------------------------------------------------------------------- UI
class App(ctk.CTk):
    ICONS = {"wait": ("○", MUTED), "run": ("◉", CYAN), "done": ("✓", GREEN), "fail": ("✗", RED), "skip": ("–", MUTED)}

    def __init__(self) -> None:
        super().__init__()
        ctk.set_appearance_mode("dark")
        self.settings = load_settings()
        self.events: queue.Queue = queue.Queue()
        self.builder: Builder | None = None
        self.plan: Plan | None = None
        self.t0 = 0.0
        self.running = False
        self.log_lines = 0
        self._painted: dict = {}

        self.title(f"{APP} v{VERSION}  -  by WSNex")
        self.geometry("1040x760")
        self.minsize(900, 640)
        self.configure(fg_color=BG)
        try:
            ico = resource("nexgrab.ico")
            if IS_WIN and ico.exists():
                self.iconbitmap(str(ico))
        except Exception:
            pass

        self.grid_columnconfigure(0, weight=0)
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(1, weight=1)
        self._header()
        self._left()
        self._right()
        self._statusbar()
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.after(100, self.pump)
        self.after(300, self.refresh_status)
        threading.Thread(target=self._probe_flutter, daemon=True).start()
        auto = os.environ.get("RSK_AUTOBUILD")  # used by automated tests only
        if auto:
            self.after(1500, lambda: self.on_build(auto))
            stop = os.environ.get("RSK_AUTOSTOP")
            if stop:
                self.after(int(float(stop) * 1000), self.on_stop)

    # ---- layout
    def _header(self) -> None:
        h = ctk.CTkFrame(self, fg_color=BG)
        h.grid(row=0, column=0, columnspan=2, sticky="ew", padx=18, pady=(14, 6))
        try:
            from PIL import Image
            img = Image.open(resource("nexgrab_logo.png"))
            self.logo = ctk.CTkImage(img, img, size=(54, 54))
            ctk.CTkLabel(h, image=self.logo, text="").pack(side="left", padx=(0, 12))
        except Exception:
            pass
        box = ctk.CTkFrame(h, fg_color=BG)
        box.pack(side="left")
        ctk.CTkLabel(box, text="NEXGRAB BUILDER", font=("Segoe UI", 26, "bold"), text_color=CYAN).pack(anchor="w")
        ctk.CTkLabel(box, text=f"Android APK + Windows EXE  ·  v{VERSION}  ·  by WSNex",
                     font=("Segoe UI", 12), text_color=MUTED).pack(anchor="w")
        self.elapsed = ctk.CTkLabel(h, text="00:00", font=("Consolas", 28, "bold"), text_color=PURPLE)
        self.elapsed.pack(side="right")

    def _card(self, parent, **kw) -> ctk.CTkFrame:
        return ctk.CTkFrame(parent, fg_color=CARD, corner_radius=16, border_width=1, border_color=BORDER, **kw)

    def _left(self) -> None:
        left = ctk.CTkFrame(self, fg_color=BG, width=330)
        left.grid(row=1, column=0, sticky="nsw", padx=(18, 8), pady=6)
        left.grid_rowconfigure(1, weight=1)

        c = self._card(left)
        c.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(c, text="Kya banana hai?", font=("Segoe UI", 14, "bold"), text_color=TEXT).pack(anchor="w", padx=16, pady=(14, 6))
        self.target = ctk.StringVar(value=self.settings.get("target", "APK"))
        ctk.CTkSegmentedButton(c, values=["APK", "EXE", "DONO"], variable=self.target, height=36,
                               selected_color=PURPLE, selected_hover_color="#7c3aed",
                               unselected_color=CARD2, font=("Segoe UI", 13, "bold")).pack(fill="x", padx=16)
        self.upd = ctk.BooleanVar(value=self.settings.get("auto_update", True))
        ctk.CTkCheckBox(c, text="Pehle Flutter + libraries update karo", variable=self.upd,
                        fg_color=CYAN, hover_color=CYAN, text_color=TEXT, font=("Segoe UI", 12)).pack(anchor="w", padx=16, pady=(12, 2))
        ctk.CTkLabel(c, text="(din mein ek dafa; internet chahiye)", font=("Segoe UI", 11), text_color=MUTED).pack(anchor="w", padx=44)
        self.btn = ctk.CTkButton(c, text="⚡  BUILD", height=50, corner_radius=14, font=("Segoe UI", 18, "bold"),
                                 fg_color=CYAN, hover_color="#06b6d4", text_color="#00131a", command=self.on_build)
        self.btn.pack(fill="x", padx=16, pady=(14, 8))
        self.stop_btn = ctk.CTkButton(c, text="■  STOP", height=34, corner_radius=12, font=("Segoe UI", 13, "bold"),
                                      fg_color=CARD2, hover_color="#3b1220", text_color=RED, border_width=1,
                                      border_color=RED, state="disabled", command=self.on_stop)
        self.stop_btn.pack(fill="x", padx=16, pady=(0, 14))

        steps = self._card(left)
        steps.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        ctk.CTkLabel(steps, text="Steps", font=("Segoe UI", 14, "bold"), text_color=TEXT).pack(anchor="w", padx=16, pady=(12, 4))
        self.steps_box = ctk.CTkScrollableFrame(steps, fg_color=CARD, width=290)
        self.steps_box.pack(fill="both", expand=True, padx=8, pady=(0, 10))
        self.step_rows: dict[str, tuple[ctk.CTkLabel, ctk.CTkLabel, ctk.CTkLabel]] = {}

        tools = self._card(left)
        tools.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        row = ctk.CTkFrame(tools, fg_color=CARD)
        row.pack(fill="x", padx=12, pady=12)
        for i, (t, cmd) in enumerate((("OUTPUT folder", self.open_output), ("C: saaf karo", self.free_space),
                                      ("Sirf update", self.on_update_only))):
            ctk.CTkButton(row, text=t, height=32, corner_radius=10, fg_color=CARD2, hover_color=BORDER,
                          font=("Segoe UI", 12), command=cmd).grid(row=0, column=i, padx=3, sticky="ew")
            row.grid_columnconfigure(i, weight=1)

    def _right(self) -> None:
        right = ctk.CTkFrame(self, fg_color=BG)
        right.grid(row=1, column=1, sticky="nsew", padx=(8, 18), pady=6)
        right.grid_rowconfigure(1, weight=1)
        right.grid_columnconfigure(0, weight=1)

        p = self._card(right)
        p.grid(row=0, column=0, sticky="ew")
        top = ctk.CTkFrame(p, fg_color=CARD)
        top.pack(fill="x", padx=16, pady=(14, 0))
        self.stage_lbl = ctk.CTkLabel(top, text="Tayyar - BUILD dabayein", font=("Segoe UI", 16, "bold"), text_color=TEXT)
        self.stage_lbl.pack(side="left")
        self.pct = ctk.CTkLabel(top, text="0%", font=("Consolas", 22, "bold"), text_color=CYAN)
        self.pct.pack(side="right")
        self.bar = ctk.CTkProgressBar(p, height=18, corner_radius=9, progress_color=CYAN, fg_color=CARD2)
        self.bar.set(0)
        self.bar.pack(fill="x", padx=16, pady=(8, 6))
        self.sub_lbl = ctk.CTkLabel(p, text=" ", font=("Segoe UI", 12), text_color=MUTED, anchor="w")
        self.sub_lbl.pack(fill="x", padx=16)
        self.sub = ctk.CTkProgressBar(p, height=8, corner_radius=4, progress_color=PURPLE, fg_color=CARD2)
        self.sub.set(0)
        self.sub.pack(fill="x", padx=16, pady=(4, 8))
        self.banner = ctk.CTkLabel(p, text="", font=("Segoe UI", 13, "bold"), text_color=TEXT, corner_radius=10,
                                   fg_color=CARD, wraplength=520, justify="left", anchor="w")
        self.banner.pack(fill="x", padx=16, pady=(0, 12))

        lg = self._card(right)
        lg.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        lh = ctk.CTkFrame(lg, fg_color=CARD)
        lh.pack(fill="x", padx=16, pady=(10, 4))
        ctk.CTkLabel(lh, text="Live log", font=("Segoe UI", 14, "bold"), text_color=TEXT).pack(side="left")
        ctk.CTkButton(lh, text="Log file", width=80, height=26, fg_color=CARD2, hover_color=BORDER,
                      command=self.open_log).pack(side="right")
        self.logbox = ctk.CTkTextbox(lg, fg_color="#050812", text_color="#b8c4dc", font=("Consolas", 11),
                                     corner_radius=10, border_width=0, wrap="none")
        self.logbox.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        tb = self.logbox._textbox
        for tag, col in (("err", RED), ("ok", GREEN), ("warn", AMBER), ("head", CYAN), ("cmd", PURPLE)):
            tb.tag_configure(tag, foreground=col)
        self.logbox.configure(state="disabled")

    def _statusbar(self) -> None:
        self.status = ctk.CTkLabel(self, text="", font=("Segoe UI", 11), text_color=MUTED, anchor="w")
        self.status.grid(row=2, column=0, columnspan=2, sticky="ew", padx=20, pady=(4, 10))
        self.cache_txt = "-"
        self.flutter_txt = "dhoond rahe hain..."

    # ---- status
    def _probe_flutter(self) -> None:
        f = find_flutter()
        if not f:
            self.events.put(("flutter", "nahi mila"))
            return
        root = Path(f).parent.parent
        txt = ""
        for vf in (root / "bin" / "cache" / "flutter.version.json", root / "version"):
            try:
                txt = vf.read_text(errors="ignore")
                break
            except OSError:
                pass
        mv = re.search(r"\d+\.\d+\.\d+", txt) or re.search(r"\d+\.\d+\.\d+", root.name + root.parent.name)
        self.events.put(("flutter", mv.group(0) if mv else "mil gaya"))

    def refresh_status(self) -> None:
        d = drives()
        ds = "   ".join(f"{k} {v:.0f} GB" for k, v in d.items() if v is not None)
        if not self.running:
            cache, _ = pick_cache_root()
            self.cache_txt = cache or "default"
        self.status.configure(text=f"Khali jagah:  {ds}      |      Cache: {self.cache_txt}      |      Flutter: {self.flutter_txt}      |      {ROOT}")
        self.after(15000, self.refresh_status)

    # ---- actions
    def _target_key(self) -> str:
        return {"APK": "apk", "EXE": "exe", "DONO": "both"}[self.target.get()]

    def on_build(self, target: str | None = None) -> None:
        if self.running:
            return
        target = target or self._target_key()
        self.settings["target"] = self.target.get()
        self.settings["auto_update"] = bool(self.upd.get())
        last = float(self.settings.get("last_update", 0))
        want_upd = target == "update" or (bool(self.upd.get()) and target in ("apk", "both") and time.time() - last > 20 * 3600)
        self.plan = Plan.make(target, want_upd, self.settings.get("durations", {}))
        self._build_steps()
        self.logbox.configure(state="normal")
        self.logbox.delete("1.0", "end")
        self.logbox.configure(state="disabled")
        self.log_lines = 0
        self.banner.configure(text="", fg_color=CARD)
        if bool(self.upd.get()) and target in ("apk", "both") and not want_upd:
            self._append("Update aaj ho chuka - is dafa skip (zaroorat ho to 'Sirf update').", "warn")
        self.running = True
        self.t0 = time.time()
        self.btn.configure(state="disabled", text="Build chal rahi hai...")
        self.stop_btn.configure(state="normal")
        self.builder = Builder(self.plan, self.events, self.settings)
        threading.Thread(target=self.builder.go, daemon=True).start()
        self.tick()

    def on_update_only(self) -> None:
        self.on_build("update")

    def on_stop(self) -> None:
        if self.builder:
            self.stop_btn.configure(state="disabled", text="Rok rahe hain...")
            threading.Thread(target=self.builder.kill, daemon=True).start()

    def open_output(self) -> None:
        OUTDIR.mkdir(parents=True, exist_ok=True)
        self._open(OUTDIR)

    def open_log(self) -> None:
        p = self.builder.log_path if self.builder else OUTDIR / "logs"
        self._open(p if Path(p).exists() else OUTDIR)

    @staticmethod
    def _open(p: Path) -> None:
        try:
            if IS_WIN:
                os.startfile(str(p))  # noqa: S606
            else:
                subprocess.Popen(["xdg-open", str(p)])
        except Exception:
            pass

    def free_space(self) -> None:
        bat = ROOT / "NexGrab_FREE_SPACE.bat"
        if bat.exists():
            self._open(bat)
        else:
            self.banner.configure(text="NexGrab_FREE_SPACE.bat project folder mein nahi mili.", fg_color="#3b1220")

    def on_close(self) -> None:
        if self.running and self.builder:
            self.builder.kill()
        save_settings(self.settings)
        self.destroy()

    # ---- live updates
    def _build_steps(self) -> None:
        for w in self.steps_box.winfo_children():
            w.destroy()
        self.step_rows.clear()
        self._painted = {}
        self._scrolled_to = None
        assert self.plan
        for s in self.plan.stages:
            r = ctk.CTkFrame(self.steps_box, fg_color=CARD)
            r.pack(fill="x", pady=2)
            ic = ctk.CTkLabel(r, text="○", width=22, font=("Segoe UI", 15, "bold"), text_color=MUTED)
            ic.pack(side="left")
            tl = ctk.CTkLabel(r, text=s.title, font=("Segoe UI", 12), text_color=MUTED, anchor="w")
            tl.pack(side="left", fill="x", expand=True)
            tm = ctk.CTkLabel(r, text="", font=("Consolas", 11), text_color=MUTED, width=48, anchor="e")
            tm.pack(side="right")
            self.step_rows[s.key] = (ic, tl, tm)

    def _set(self, w, key: str, **kw) -> None:
        """configure() only when something changed - ctk redraws are slow."""
        old = self._painted.get((id(w), key))
        if old != kw:
            self._painted[(id(w), key)] = kw
            if "value" in kw:
                w.set(kw["value"])
            else:
                w.configure(**kw)

    def _paint_steps(self) -> None:
        if not self.plan or not self.step_rows:
            return
        now = time.time()
        for s in self.plan.stages:
            row = self.step_rows.get(s.key)
            if not row:
                continue
            ic, tl, tm = row
            sym, col = self.ICONS[s.state]
            self._set(ic, "i", text=sym, text_color=col)
            self._set(tl, "t", text_color=TEXT if s.state in ("run", "done") else (RED if s.state == "fail" else MUTED))
            if s.started:
                self._set(tm, "m", text=fmt((s.ended or now) - s.started))
        run = [i for i, s in enumerate(self.plan.stages) if s.state in ("run", "fail")]
        if run and getattr(self, "_scrolled_to", None) != run[0]:
            self._scrolled_to = run[0]
            try:  # keep the running step visible
                frac = max(0.0, (run[0] - 3) / max(1, len(self.plan.stages)))
                self.steps_box._parent_canvas.yview_moveto(frac)
            except Exception:
                pass

    def tick(self) -> None:
        if DEBUG:
            DEBUG.write(f"{time.time():.2f} tick\n")
            DEBUG.flush()
        if not self.plan:
            return
        now = time.time()
        cur = next((s for s in self.plan.stages if s.state == "run"), None)
        if cur:
            el = now - cur.started
            # stages without real counters creep forward by time (history-based estimate)
            if not (cur.key == "a6" and self.builder and self.builder.tasks > 0):
                cur.frac = max(cur.frac, min(0.95, el / max(cur.est, 1) * 0.95))
            self._set(self.stage_lbl, "s", text=cur.title)
            self._set(self.sub, "v", value=round(cur.frac, 3))
            left = ""
            if cur.est > 30 and el < cur.est:
                left = f"   ·   andaazan {fmt(cur.est - el)} baaqi"
            self._set(self.sub_lbl, "d", text=(cur.detail or "chal raha hai...") + f"   ·   {fmt(el)}{left}")
        ov = self.plan.overall()
        self._set(self.bar, "v", value=round(ov, 3))
        self._set(self.pct, "p", text=f"{int(ov * 100)}%")
        if self.running:
            self._set(self.elapsed, "e", text=fmt(now - self.t0))
        self._paint_steps()
        if self.running:
            self.after(250, self.tick)

    def _append(self, line: str, tag: str = "") -> None:
        tb = self.logbox
        tb.configure(state="normal")
        tb._textbox.insert("end", line + "\n", tag or ())
        self.log_lines += 1
        if self.log_lines > 4000:
            tb._textbox.delete("1.0", "1000.0")
            self.log_lines -= 999
        tb._textbox.see("end")
        tb.configure(state="disabled")

    def _flush_log(self, batch: list) -> None:
        if not batch:
            return
        tb = self.logbox._textbox
        tb.configure(state="normal")
        args = []
        for line, tag in batch:
            args += [line + "\n", tag or ()]
        tb.insert("end", *args)
        self.log_lines += len(batch)
        if self.log_lines > 4000:
            tb.delete("1.0", "1500.0")
            self.log_lines -= 1499
        tb.see("end")
        tb.configure(state="disabled")
        batch.clear()

    def pump(self) -> None:
        n = 0
        batch: list = []
        try:
            while n < 500:
                ev = self.events.get_nowait()
                n += 1
                kind = ev[0]
                if kind == "log":
                    batch.append((ev[1], ev[2]))
                    continue
                self._flush_log(batch)
                if kind == "stage":
                    self._paint_steps()
                elif kind == "flutter":
                    self.flutter_txt = ev[1]
                elif kind == "cache":
                    self.cache_txt = ev[1]
                elif kind == "done":
                    ok, msg = ev[1], ev[2]
                    self.banner.configure(text=("✓  " if ok else "✗  ") + msg,
                                          fg_color="#0f2e1d" if ok else "#3b1220",
                                          text_color=GREEN if ok else "#fecaca")
                    if ok:
                        self.bar.set(1)
                        self.pct.configure(text="100%")
                        self.stage_lbl.configure(text="BUILD SUCCESS" if self.plan and self.plan.target != "update" else "UPDATE MUKAMMAL")
                        self.sub.set(1)
                        self.sub_lbl.configure(text="OUTPUT folder khul raha hai...")
                    else:
                        self.stage_lbl.configure(text="BUILD FAILED")
                        self.sub_lbl.configure(text="Neeche log dekhein · masla hal karke dobara BUILD dabayein")
                elif kind == "finished":
                    self.running = False
                    self.tick()
                    self.btn.configure(state="normal", text="⚡  BUILD")
                    self.stop_btn.configure(state="disabled", text="■  STOP")
                    self.refresh_status()
                    if ev[1] and self.plan and self.plan.target != "update":
                        self.open_output()
        except queue.Empty:
            pass
        self._flush_log(batch)
        self.after(100, self.pump)


def fmt(secs: float) -> str:
    secs = int(max(0, secs))
    h, r = divmod(secs, 3600)
    m, s = divmod(r, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main() -> None:
    App().mainloop()


if __name__ == "__main__":
    main()
