"""NexGrab v3.3 - Windows desktop app (customtkinter + yt-dlp).

GUI only. All downloading / networking lives in rsk_core.py. Worker threads never
touch widgets: they post events to Manager.events and this file drains the queue
on the Tk main thread every 100 ms.
"""

from __future__ import annotations

import io
import os
import queue
import sys
import threading
import webbrowser
import subprocess
import tkinter as tk
from tkinter import filedialog, messagebox

try:
    import customtkinter as ctk
except ImportError:  # pragma: no cover
    raise SystemExit("Install first: py -m pip install -r requirements.txt")

from PIL import Image

import rsk_bridge as bridge
import rsk_core as core

# ----------------------------------------------------------------------------- look & feel

BG = ("#EEF2F8", "#070B14")
SIDEBAR = ("#E3E9F4", "#0B1222")
CARD = ("#FFFFFF", "#0F172A")
CARD2 = ("#F3F6FB", "#141F38")
BORDER = ("#D5DCEA", "#1F2B4A")
CYAN = "#38D7FF"
BLUE = "#3B82F6"
VIOLET = "#8B5CF6"
TEXT = ("#0F172A", "#E6EDF7")
MUTED = ("#5B6478", "#8A97B2")
OK = "#22C55E"
WARN = "#F59E0B"
BAD = "#EF4444"

STATUS_COLOR = {
    core.Task.DONE: OK, core.Task.FAILED: BAD, core.Task.CANCELED: MUTED,
    core.Task.PAUSED: WARN, core.Task.QUEUED: MUTED, core.Task.RUNNING: CYAN, core.Task.PROCESSING: VIOLET,
}

COOKIE_FILE_ITEM = "cookies.txt file..."
LOGO_PNG = core.resource_path(os.path.join("assets", "nexgrab_logo.png"))
APP_ICON = core.resource_path(os.path.join("assets", "nexgrab.ico"))


def font(size=13, weight="normal"):
    return ctk.CTkFont(size=size, weight=weight)


def card(parent, **kw):
    kw.setdefault("corner_radius", 18)
    kw.setdefault("fg_color", CARD)
    kw.setdefault("border_width", 1)
    kw.setdefault("border_color", BORDER)
    return ctk.CTkFrame(parent, **kw)


def label(parent, text="", size=13, weight="normal", color=TEXT, **kw):
    kw.setdefault("anchor", "w")
    kw.setdefault("justify", "left")
    return ctk.CTkLabel(parent, text=text, font=font(size, weight), text_color=color, **kw)


def button(parent, text, command, kind="primary", **kw):
    styles = {
        "primary": dict(fg_color=BLUE, hover_color="#2563EB", text_color="white", text_color_disabled="#C7D7FB"),
        "accent": dict(fg_color=CYAN, hover_color="#22B8DD", text_color="#04111F", text_color_disabled="#0B3B4A"),
        "ghost": dict(fg_color=CARD2, hover_color=BORDER, text_color=TEXT, border_width=1, border_color=BORDER),
        "danger": dict(fg_color="#9F2F3C", hover_color="#7F2430", text_color="white"),
        "ok": dict(fg_color="#15803D", hover_color="#166534", text_color="white"),
    }
    kw.setdefault("height", 38)
    kw.setdefault("corner_radius", 12)
    return ctk.CTkButton(parent, text=text, command=command, font=font(13, "bold"), **styles[kind], **kw)


def entry(parent, var=None, placeholder="", **kw):
    kw.setdefault("height", 40)
    kw.setdefault("corner_radius", 12)
    return ctk.CTkEntry(parent, textvariable=var, placeholder_text=placeholder, fg_color=CARD2,
                        border_color=BORDER, text_color=TEXT, **kw)


# ----------------------------------------------------------------------------- download card


class TaskCard(ctk.CTkFrame):
    def __init__(self, parent, app: "App", task: core.Task):
        super().__init__(parent, corner_radius=16, fg_color=CARD, border_width=1, border_color=BORDER)
        self.app = app
        self.task = task
        self.grid_columnconfigure(0, weight=1)

        self.title = label(self, task.title, 14, "bold")
        self.title.grid(row=0, column=0, sticky="ew", padx=16, pady=(12, 0))
        self.sub = label(self, "", 12, color=MUTED)
        self.sub.grid(row=1, column=0, sticky="ew", padx=16)

        row = ctk.CTkFrame(self, fg_color="transparent")
        row.grid(row=2, column=0, sticky="ew", padx=16, pady=(8, 2))
        row.grid_columnconfigure(0, weight=1)
        self.bar = ctk.CTkProgressBar(row, height=10, corner_radius=6, progress_color=CYAN, fg_color=BORDER)
        self.bar.set(0)
        self.bar.grid(row=0, column=0, sticky="ew", padx=(0, 12))
        self.pct = label(row, "0%", 13, "bold", width=64, anchor="e")
        self.pct.grid(row=0, column=1)

        bottom = ctk.CTkFrame(self, fg_color="transparent")
        bottom.grid(row=3, column=0, sticky="ew", padx=16, pady=(2, 12))
        bottom.grid_columnconfigure(0, weight=1)
        self.stats = label(bottom, "", 12, color=MUTED)
        self.stats.grid(row=0, column=0, sticky="ew")
        self.btns = ctk.CTkFrame(bottom, fg_color="transparent")
        self.btns.grid(row=0, column=1, sticky="e")
        self._btn_state = None
        self.refresh()

    def _buttons(self, spec):
        if spec == self._btn_state:
            return
        self._btn_state = spec
        for w in self.btns.winfo_children():
            w.destroy()
        m, tid = self.app.m, self.task.id
        actions = {
            "pause": ("Pause", lambda: m.pause(tid), "ghost"),
            "resume": ("Resume", lambda: m.resume(tid), "accent"),
            "cancel": ("Cancel", lambda: m.cancel(tid), "danger"),
            "retry": ("Retry", lambda: m.resume(tid), "accent"),
            "open": ("Open", self._open_file, "ok"),
            "folder": ("Folder", self._open_folder, "ghost"),
            "remove": ("Remove", lambda: m.remove(tid), "ghost"),
        }
        for i, key in enumerate(spec):
            t, cmd, kind = actions[key]
            button(self.btns, t, cmd, kind, width=78, height=32).grid(row=0, column=i, padx=(6, 0))

    def _open_file(self):
        f = self.task.final_file
        if f and os.path.exists(f):
            self.app.safe(core.open_path, f)
        else:
            self._open_folder()

    def _open_folder(self):
        f = self.task.final_file
        self.app.safe(core.reveal_in_folder, f if f and os.path.exists(f) else self.task.outdir)

    def refresh(self):
        t = self.task
        color = STATUS_COLOR.get(t.status, CYAN)
        self.title.configure(text=t.title[:140])
        sub = [t.choice.label.split("  •  ")[0]]
        if t.route:
            sub.append(t.route)
        if t.item:
            sub.append(f"item {t.item}")
        self.sub.configure(text="  •  ".join(sub))
        self.bar.configure(progress_color=color)

        if t.status in (core.Task.RUNNING,) and t.total:
            self.bar.set(min(1.0, t.downloaded / t.total))
            self.pct.configure(text=f"{t.percent:.1f}%", text_color=TEXT)
        elif t.status == core.Task.DONE:
            self.bar.set(1)
            self.pct.configure(text="100%", text_color=OK)
        elif t.status == core.Task.PROCESSING:
            self.pct.configure(text="...", text_color=VIOLET)
        elif t.status in (core.Task.FAILED, core.Task.CANCELED):
            self.pct.configure(text="—", text_color=color)

        if t.status == core.Task.RUNNING:
            parts = [f"{core.fmt_bytes(t.downloaded)} / {core.fmt_bytes(t.total) if t.total else '?'}"]
            if t.speed:
                parts.append(f"{core.fmt_bytes(t.speed)}/s")
            if t.eta is not None:
                parts.append(f"ETA {core.fmt_time(t.eta)}")
            text = "   •   ".join(parts) if (t.downloaded or t.total) else "Connecting..."
            self._buttons(("pause", "cancel"))
        elif t.status == core.Task.PROCESSING:
            text = t.stage or "Processing..."
            self._buttons(("cancel",))
        elif t.status == core.Task.QUEUED:
            text = "Queue mein (baari ka intezar)"
            self._buttons(("pause", "cancel"))
        elif t.status == core.Task.PAUSED:
            text = f"Paused at {core.fmt_bytes(t.downloaded)}" + (f" / {core.fmt_bytes(t.total)}" if t.total else "")
            self._buttons(("resume", "cancel"))
        elif t.status == core.Task.DONE:
            f = t.final_file
            text = ("Saved: " + os.path.basename(f)) if f else "Completed"
            if len(t.files) > 1:
                text = f"{len(t.files)} files saved in {t.outdir}"
            self._buttons(("open", "folder", "remove"))
        elif t.status == core.Task.FAILED:
            text = t.error.split("\n")[0][:160]
            self._buttons(("retry", "remove"))
        else:
            text = "Canceled"
            self._buttons(("retry", "remove"))
        self.stats.configure(text=text, text_color=BAD if t.status == core.Task.FAILED else MUTED)


# ----------------------------------------------------------------------------- app


class App:
    NAV = [
        ("home", "⌂  Home"),
        ("downloads", "⬇  Downloads"),
        ("history", "◷  History"),
        ("network", "⇄  Network / Tor"),
        ("browser", "◎  Browser"),
        ("settings", "⚙  Settings"),
    ]

    def __init__(self, root: ctk.CTk):
        self.root = root
        self.m = core.Manager()
        s = self.m.settings
        ctk.set_appearance_mode(s.get("theme", "dark"))

        root.title(f"{core.APP_NAME} v{core.APP_VERSION}")
        root.geometry("1220x800")
        root.minsize(1000, 680)
        root.configure(fg_color=BG)
        self._set_icon()

        self.pages = {}
        self.nav_buttons = {}
        self.cards: dict[str, TaskCard] = {}
        self.current = None
        self.info: core.MediaInfo | None = None
        self._req = 0
        self._ui_events: "queue.Queue[tuple]" = queue.Queue()
        self._history_dirty = True

        self.url_var = tk.StringVar()
        self.outdir_var = tk.StringVar(value=s["output_dir"])
        self.browser_var = tk.StringVar(value=s.get("browser", "None"))
        self.quality_var = tk.StringVar()
        self.playlist_var = tk.BooleanVar(value=False)
        self.thumb_var = tk.BooleanVar(value=False)
        self.meta_var = tk.BooleanVar(value=False)
        self.subs_var = tk.BooleanVar(value=False)
        self.status_var = tk.StringVar(value="Ready")

        self._pending_mode = None  # "best" / "mp3" when a browser request wants an instant download
        self.bridge = None
        self._build_shell()
        self.show("home")
        self._startup_hint()
        root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.after(100, self._drain)
        self._start_bridge()

    # ------------------------------------------------------------------ browser extension (IDM-style)

    def _start_bridge(self):
        try:
            self.bridge = bridge.Bridge(lambda req: self._ui_events.put(("grab", True, req)), core.APP_VERSION).start()
        except OSError:
            self.bridge = None  # port busy (another NexGrab is open)
        bridge.register_protocol()

    def handle_browser_request(self, req: dict):
        self._ui_events.put(("grab", True, req))

    def _bring_to_front(self):
        try:
            self.root.deiconify()
            self.root.lift()
            self.root.attributes("-topmost", True)
            self.root.after(400, lambda: self.root.attributes("-topmost", False))
            self.root.focus_force()
        except Exception:
            pass

    def _on_grab(self, ok, req):
        if not ok or not req:
            return
        self._bring_to_front()
        self.show("home")
        self.url_var.set(req["url"])
        self.playlist_var.set(False)
        self._pending_mode = req["mode"] if req["mode"] in ("best", "mp3") else None
        self.toast("Browser se link aaya", CYAN)
        self.analyze()

    # ------------------------------------------------------------------ helpers

    def _set_icon(self):
        try:
            if core.IS_WIN and os.path.exists(APP_ICON):
                self.root.iconbitmap(APP_ICON)
            elif os.path.exists(LOGO_PNG):
                self._icon_img = tk.PhotoImage(file=LOGO_PNG).subsample(8, 8)
                self.root.iconphoto(True, self._icon_img)
        except Exception:
            pass

    def safe(self, fn, *a):
        try:
            fn(*a)
        except Exception as exc:
            messagebox.showerror(core.APP_NAME, core.friendly_error(exc))

    def toast(self, text, color=None):
        self.status_var.set(text)
        if hasattr(self, "status_chip"):
            self.status_chip.configure(text_color=color or TEXT)

    def run_bg(self, kind, fn, *args):
        """Run fn in a thread and deliver (kind, result|exception) on the UI thread."""

        def worker():
            try:
                res = fn(*args)
                self._ui_events.put((kind, True, res))
            except Exception as exc:  # noqa: BLE001
                self._ui_events.put((kind, False, exc))

        threading.Thread(target=worker, daemon=True).start()

    # ------------------------------------------------------------------ shell

    def _build_shell(self):
        r = self.root
        r.grid_columnconfigure(1, weight=1)
        r.grid_rowconfigure(0, weight=1)

        side = ctk.CTkFrame(r, width=236, corner_radius=0, fg_color=SIDEBAR)
        side.grid(row=0, column=0, sticky="nsew")
        side.grid_propagate(False)
        side.grid_columnconfigure(0, weight=1)

        self.logo = None
        if os.path.exists(LOGO_PNG):
            try:
                img = Image.open(LOGO_PNG)
                self.logo = ctk.CTkImage(light_image=img, dark_image=img, size=(150, 150))
                ctk.CTkLabel(side, text="", image=self.logo).grid(row=0, column=0, pady=(18, 4))
            except Exception as exc:  # keep the app usable, but say why
                print("logo load failed:", repr(exc), file=sys.stderr)
        label(side, "NexGrab", 22, "bold", anchor="center").grid(row=1, column=0)
        label(side, "FUTURISTIC DOWNLOADER", 11, "bold", MUTED, anchor="center").grid(row=2, column=0, pady=(0, 16))

        for i, (key, text) in enumerate(self.NAV):
            b = ctk.CTkButton(side, text=text, anchor="w", height=42, corner_radius=12, font=font(14, "bold"),
                              fg_color="transparent", hover_color=CARD2, text_color=TEXT,
                              command=lambda k=key: self.show(k))
            b.grid(row=3 + i, column=0, sticky="ew", padx=14, pady=3)
            self.nav_buttons[key] = b

        side.grid_rowconfigure(20, weight=1)
        # Big, always-visible Tor ON/OFF switch (ON = use Tor whenever Tor Browser is running)
        tor_box = ctk.CTkFrame(side, fg_color=CARD2, corner_radius=12)
        tor_box.grid(row=20, column=0, sticky="sew", padx=14, pady=(0, 8))
        tor_box.grid_columnconfigure(0, weight=1)
        self.tor_var = tk.BooleanVar(value=self.m.settings.get("route") in ("auto", "tor"))
        self.tor_switch = ctk.CTkSwitch(tor_box, text="TOR", variable=self.tor_var, command=self._toggle_tor,
                                        font=font(15, "bold"), progress_color=OK, switch_width=50, switch_height=24)
        self.tor_switch.grid(row=0, column=0, sticky="w", padx=12, pady=(10, 2))
        self.tor_hint = label(tor_box, "", 11, color=MUTED, wraplength=180)
        self.tor_hint.grid(row=1, column=0, sticky="ew", padx=12, pady=(0, 10))
        self.route_chip = ctk.CTkLabel(side, text="", corner_radius=10, fg_color=CARD2, font=font(12, "bold"),
                                       padx=10, pady=8, wraplength=190)
        self.route_chip.grid(row=21, column=0, sticky="ew", padx=14, pady=(0, 8))
        label(side, f"v{core.APP_VERSION}  •  by {core.DEVELOPER}", 11, color=MUTED, anchor="center").grid(
            row=22, column=0, pady=(0, 16))

        main = ctk.CTkFrame(r, corner_radius=0, fg_color=BG)
        main.grid(row=0, column=1, sticky="nsew")
        main.grid_columnconfigure(0, weight=1)
        main.grid_rowconfigure(1, weight=1)
        top = ctk.CTkFrame(main, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=24, pady=(16, 4))
        top.grid_columnconfigure(0, weight=1)
        self.page_title = label(top, "", 26, "bold")
        self.page_title.grid(row=0, column=0, sticky="w")
        self.status_chip = ctk.CTkLabel(top, textvariable=self.status_var, corner_radius=10, fg_color=CARD,
                                        padx=12, pady=6, font=font(12, "bold"))
        self.status_chip.grid(row=0, column=1)
        self.host = main
        self._update_route_chip()

    def _make_page(self, key):
        if key not in self.pages:
            frame = ctk.CTkScrollableFrame(self.host, corner_radius=0, fg_color="transparent")
            frame.grid_columnconfigure(0, weight=1)
            getattr(self, f"_page_{key}")(frame)
            self.pages[key] = frame
        return self.pages[key]

    def show(self, key):
        self._make_page(key)
        if self.current and self.current != key:
            self.pages[self.current].grid_remove()
        self.pages[key].grid(row=1, column=0, sticky="nsew", padx=16, pady=(4, 16))
        self.current = key
        titles = dict(self.NAV)
        self.page_title.configure(text=titles[key].split("  ", 1)[1])
        for k, b in self.nav_buttons.items():
            b.configure(fg_color=CARD2 if k == key else "transparent", text_color=CYAN if k == key else TEXT)
        if key == "history" and self._history_dirty:
            self._render_history()
        if key == "network":
            self._refresh_network_page()
        if key == "settings":
            self._refresh_tools()

    # ------------------------------------------------------------------ event pump (UI thread)

    def _drain(self):
        changed = set()
        try:
            while True:
                kind, payload = self.m.events.get_nowait()
                if kind == "task":
                    changed.add(payload)
                elif kind == "removed":
                    c = self.cards.pop(payload, None)
                    if c:
                        c.destroy()
                    self._downloads_empty_state()
                elif kind == "history":
                    self._history_dirty = True
                    if self.current == "history":
                        self._render_history()
                elif kind == "route":
                    self._update_route_chip()
        except queue.Empty:
            pass
        for tid in changed:
            t = self.m.find(tid)
            if not t:
                continue
            c = self.cards.get(tid)
            if c is None:
                self._ensure_page("downloads")
                c = TaskCard(self.dl_list, self, t)
                self.cards[tid] = c
                self._relayout_cards()
            else:
                c.refresh()
        if changed:
            self._update_counts()
        try:
            while True:
                kind, ok, res = self._ui_events.get_nowait()
                getattr(self, f"_on_{kind}")(ok, res)
        except queue.Empty:
            pass
        self.root.after(100, self._drain)

    def _ensure_page(self, key):
        self._make_page(key)

    def _update_counts(self):
        active = sum(1 for t in self.m.tasks if t.status in (core.Task.RUNNING, core.Task.PROCESSING, core.Task.QUEUED))
        self.nav_buttons["downloads"].configure(text=f"⬇  Downloads ({active})" if active else "⬇  Downloads")
        if active:
            self.toast(f"{active} download(s) active", CYAN)
        elif self.status_var.get().endswith("active"):
            self.toast("Ready")

    def _toggle_tor(self):
        """Tor switch: ON -> Auto (Tor when Tor Browser runs), OFF -> Direct."""
        on = bool(self.tor_var.get())
        self.m.settings["route"] = "auto" if on else "direct"
        self.m.save_settings()
        if hasattr(self, "route_var"):
            self.route_var.set(self.m.settings["route"])
        if on and not self.m.net.tor_port:
            self.toast("Tor ON • ab Tor Browser kholein", WARN)
        else:
            self.toast("Tor ON" if on else "Tor OFF • Direct", OK if on else TEXT)
        self._update_route_chip()

    def _update_route_chip(self):
        net = self.m.net
        if hasattr(self, "tor_var"):
            on = net.mode in ("auto", "tor")
            if self.tor_var.get() != on:
                self.tor_var.set(on)
            if not on:
                hint, hc = "OFF: sab downloads Direct", MUTED
            elif net.tor_port:
                hint, hc = f"ON: Tor connected (port {net.tor_port})", OK
            else:
                hint, hc = "ON: Tor Browser kholein — khulte hi Tor use hoga", WARN
            self.tor_hint.configure(text=hint, text_color=hc)
        tor = net.is_tor()
        text = ("◆ " if tor else "◉ ") + net.label()
        color = OK if tor else (WARN if net.mode in ("tor", "tunnel") and not net.tor_port and not net.tunnel.connected else TEXT)
        if net.mode == "tunnel" and net.tunnel.connected:
            color = OK
        self.route_chip.configure(text=text, text_color=color)
        if hasattr(self, "home_route"):
            self.home_route.configure(text="Route: " + net.label(), text_color=color)
        if self.current == "network" and hasattr(self, "net_status"):
            self._refresh_network_page()

    def _startup_hint(self):
        tools = self.m.tools
        if not tools.ffmpeg or not tools.js_runtime[0]:
            self.toast("Tools missing • Settings → Install", WARN)
        else:
            self.toast("Ready", OK)

    # ------------------------------------------------------------------ HOME

    def _page_home(self, p):
        hero = card(p)
        hero.grid(row=0, column=0, sticky="ew", padx=8, pady=8)
        hero.grid_columnconfigure(0, weight=1)
        label(hero, "Download from 1000+ websites", 22, "bold").grid(row=0, column=0, sticky="ew", padx=22, pady=(20, 2))
        label(hero, "YouTube • Instagram • Facebook • X • TikTok • direct links • playlists",
              13, color=MUTED).grid(row=1, column=0, sticky="ew", padx=22, pady=(0, 14))

        row = ctk.CTkFrame(hero, fg_color="transparent")
        row.grid(row=2, column=0, sticky="ew", padx=22)
        row.grid_columnconfigure(0, weight=1)
        self.url_entry = entry(row, self.url_var, "Paste link here...", height=48, font=font(14))
        self.url_entry.grid(row=0, column=0, sticky="ew")
        self.url_entry.bind("<Return>", lambda e: self.analyze())
        button(row, "Paste", self.paste, "ghost", width=90, height=48).grid(row=0, column=1, padx=(8, 0))
        self.analyze_btn = button(row, "ANALYZE", self.analyze, "accent", width=130, height=48)
        self.analyze_btn.grid(row=0, column=2, padx=(8, 0))

        opts = ctk.CTkFrame(hero, fg_color="transparent")
        opts.grid(row=3, column=0, sticky="ew", padx=22, pady=(12, 4))
        ctk.CTkCheckBox(opts, text="Playlist (poori list)", variable=self.playlist_var, font=font(13)).pack(side="left")
        label(opts, "Cookies:", 13, color=MUTED).pack(side="left", padx=(24, 6))
        self.cookie_combo = ctk.CTkComboBox(opts, variable=self.browser_var, values=core.BROWSERS + [COOKIE_FILE_ITEM],
                                            state="readonly", width=170, command=self._on_cookie_choice)
        self.cookie_combo.pack(side="left")
        self.home_route = label(opts, "", 12, "bold")
        self.home_route.pack(side="right")

        self.analyze_bar = ctk.CTkProgressBar(hero, mode="indeterminate", height=4, progress_color=CYAN, fg_color=CARD)
        self.analyze_bar.grid(row=4, column=0, sticky="ew", padx=22, pady=(10, 0))
        self.analyze_bar.grid_remove()
        ctk.CTkFrame(hero, height=16, fg_color="transparent").grid(row=5, column=0)

        # result card (hidden until analyzed)
        self.result = card(p)
        self.result.grid_columnconfigure(1, weight=1)
        self.thumb = ctk.CTkLabel(self.result, text="", width=256, height=144, fg_color=CARD2, corner_radius=12)
        self.thumb.grid(row=0, column=0, rowspan=3, padx=(20, 16), pady=20, sticky="n")
        self.r_title = label(self.result, "", 17, "bold", wraplength=620)
        self.r_title.grid(row=0, column=1, sticky="ew", padx=(0, 20), pady=(20, 4))
        self.r_meta = label(self.result, "", 12, color=MUTED, wraplength=620)
        self.r_meta.grid(row=1, column=1, sticky="new", padx=(0, 20))

        form = ctk.CTkFrame(self.result, fg_color="transparent")
        form.grid(row=2, column=1, sticky="ew", padx=(0, 20), pady=(8, 0))
        form.grid_columnconfigure(1, weight=1)
        label(form, "Quality", 13, "bold").grid(row=0, column=0, sticky="w", pady=4)
        self.quality_combo = ctk.CTkComboBox(form, variable=self.quality_var, values=[""], state="readonly", height=38)
        self.quality_combo.grid(row=0, column=1, columnspan=2, sticky="ew", padx=(12, 0), pady=4)
        label(form, "Save to", 13, "bold").grid(row=1, column=0, sticky="w", pady=4)
        entry(form, self.outdir_var, height=38).grid(row=1, column=1, sticky="ew", padx=(12, 0), pady=4)
        button(form, "Browse", self.browse, "ghost", width=90).grid(row=1, column=2, padx=(8, 0), pady=4)

        extras = ctk.CTkFrame(self.result, fg_color="transparent")
        extras.grid(row=3, column=0, columnspan=2, sticky="ew", padx=20, pady=(4, 0))
        for text, var in (("Embed thumbnail", self.thumb_var), ("Write metadata", self.meta_var),
                          ("Subtitles", self.subs_var)):
            ctk.CTkCheckBox(extras, text=text, variable=var, font=font(13)).pack(side="left", padx=(0, 22))
        self.r_warn = label(self.result, "", 12, color=WARN, wraplength=900)
        self.r_warn.grid(row=4, column=0, columnspan=2, sticky="ew", padx=20, pady=(6, 0))
        self.download_btn = button(self.result, "⬇  START DOWNLOAD", self.download, "primary", height=50)
        self.download_btn.configure(font=font(15, "bold"))
        self.download_btn.grid(row=5, column=0, columnspan=2, sticky="ew", padx=20, pady=(12, 20))

        tips = card(p)
        tips.grid(row=2, column=0, sticky="ew", padx=8, pady=8)
        self.tips = tips
        label(tips, "Quick tips", 15, "bold").pack(anchor="w", padx=22, pady=(16, 6))
        for t in (
            "◆  Tor: bas Tor Browser kholein aur connect hone dein, phir link paste karein. Download khud Tor se jayega.",
            "⏸  Download ko Pause / Resume kar sakte hain. Band karke dobara kholne par Retry se wahin se chalega.",
            "♪  MP3 ke liye FFmpeg chahiye (Settings → Tools). M4A bina convert ke hamesha milta hai.",
            "✱  YouTube 'not a bot' aaye: Cookies → Firefox ya cookies.txt file (Chrome ki cookies Windows par aksar nahi chaltin).",
        ):
            label(tips, t, 13, color=MUTED, wraplength=900).pack(anchor="w", padx=22, pady=3)
        ctk.CTkFrame(tips, height=12, fg_color="transparent").pack()
        self._update_route_chip()

    def paste(self):
        try:
            self.url_var.set(self.root.clipboard_get().strip())
            self.analyze()
        except tk.TclError:
            self.toast("Clipboard khali hai", WARN)

    def browse(self):
        d = filedialog.askdirectory(initialdir=self.outdir_var.get() or os.path.expanduser("~"))
        if d:
            self.outdir_var.set(d)
            self.m.settings["output_dir"] = d
            self.m.save_settings()

    def _on_cookie_choice(self, value):
        if value == COOKIE_FILE_ITEM:
            if not self._pick_cookie_file():
                self.browser_var.set(self.m.settings.get("browser", "None"))
            return
        self.m.settings["browser"] = value
        self.m.save_settings()

    def _pick_cookie_file(self):
        path = filedialog.askopenfilename(
            title="cookies.txt select karein (Netscape format)",
            filetypes=[("cookies.txt", "*.txt"), ("All files", "*.*")])
        if not path:
            return False
        self.m.settings["cookie_file"] = path
        label_text = "File: " + os.path.basename(path)
        self.m.settings["browser"] = label_text
        self.m.save_settings()
        self.browser_var.set(label_text)
        self.toast("Cookies file set", OK)
        return True

    def _cookies(self):
        """Value for rsk_core: 'None', a browser name, or 'file:<path>'."""
        v = self.browser_var.get()
        if v.startswith("File: "):
            return "file:" + self.m.settings.get("cookie_file", "")
        return v

    def analyze(self):
        url = self.url_var.get().strip()
        if not url:
            self.toast("Pehle link paste karein", WARN)
            return
        self._req += 1
        req = self._req
        self.analyze_btn.configure(state="disabled", text="ANALYZING")
        self.analyze_bar.grid()
        self.analyze_bar.start()
        self.toast("Analyzing...", CYAN)
        cookies = self._cookies()
        self.run_bg("analyzed", lambda: (req, core.analyze(url, self.m.settings, self.m.tools, self.m.net,
                                                           self.playlist_var.get(), cookies)))

    def _on_analyzed(self, ok, res):
        self.analyze_btn.configure(state="normal", text="ANALYZE")
        self.analyze_bar.stop()
        self.analyze_bar.grid_remove()
        if not ok:
            self._pending_mode = None
            self.toast("Analyze failed", BAD)
            msg = core.friendly_error(res)
            if core.is_network_error(str(res)) and not self.m.net.is_tor():
                msg += "\n\nTip: Tor Browser khol dein (Auto mode khud Tor use karega)."
            if core.is_bot_check(str(res)):
                if messagebox.askyesno("YouTube bot-check", msg + "\n\nAbhi cookies.txt file select karein?"):
                    if self._pick_cookie_file():
                        self.analyze()
                return
            messagebox.showerror("Analyze failed", msg)
            return
        req, info = res
        if req != self._req:
            return
        self.info = info
        labels = [c.label for c in info.choices]
        self.quality_combo.configure(values=labels)
        self.quality_var.set(labels[0])
        self.r_title.configure(text=info.title)
        meta = [info.site]
        if info.uploader:
            meta.append(info.uploader)
        if info.duration:
            meta.append(core.fmt_time(info.duration))
        if info.is_playlist:
            meta.append(f"Playlist • {info.count} items")
        via = core.route_name(info.proxy_used)
        meta.append(f"via {via}")
        if info.warnings and any("Tor block" in w for w in info.warnings):
            meta.append("(YouTube ne Tor block kiya → Direct)")
        self.r_meta.configure(text="   •   ".join(meta))
        warn = []
        if not self.m.tools.ffmpeg:
            warn.append("FFmpeg nahi mila: HD (merge) aur MP3 band hain. Settings → Install missing tools.")
        if info.site.endswith("youtube.com") and not self.m.tools.js_runtime[0]:
            warn.append("YouTube JS engine (deno) nahi mila: kuch qualities missing ho sakti hain.")
        self.r_warn.configure(text="  ".join(warn))
        self.thumb.configure(image=None, text="No preview", text_color=MUTED)
        self.result.grid(row=1, column=0, sticky="ew", padx=8, pady=8)
        self.tips.grid_remove()
        self.toast("Ready to download", OK)
        mode, self._pending_mode = self._pending_mode, None
        if mode:
            pick = None
            if mode == "mp3":
                pick = next((c for c in info.choices if c.kind == "mp3"), None) or \
                    next((c for c in info.choices if c.kind == "m4a"), None)
            pick = pick or info.choices[0]
            self.quality_var.set(pick.label)
            self.root.after(50, self.download)
            return
        if info.thumbnail:
            self.run_bg("thumb", lambda: (req, core.fetch_bytes(info.thumbnail, info.proxy_used)))

    def _on_thumb(self, ok, res):
        if not ok:
            return
        req, data = res
        if req != self._req:
            return
        try:
            img = Image.open(io.BytesIO(data)).convert("RGB")
            img.thumbnail((256, 144))
            self._thumb_img = ctk.CTkImage(light_image=img, dark_image=img, size=img.size)
            self.thumb.configure(image=self._thumb_img, text="")
        except Exception:
            pass

    def download(self):
        info = self.info
        if not info:
            return
        choice = next((c for c in info.choices if c.label == self.quality_var.get()), info.choices[0])
        outdir = self.outdir_var.get().strip() or os.path.join(os.path.expanduser("~"), "Downloads")
        try:
            os.makedirs(outdir, exist_ok=True)
        except Exception as exc:
            messagebox.showerror("Folder", str(exc))
            return
        self.m.settings["output_dir"] = outdir
        self.m.save_settings()
        task = core.Task(info.url, info.title, choice, outdir, playlist=info.is_playlist,
                         cookies=self._cookies(), embed_thumb=self.thumb_var.get(),
                         write_meta=self.meta_var.get(), subtitles=self.subs_var.get())
        self.m.add(task)
        self.result.grid_remove()
        self.tips.grid()
        self.url_var.set("")
        self.info = None
        self.show("downloads")

    # ------------------------------------------------------------------ DOWNLOADS

    def _page_downloads(self, p):
        head = ctk.CTkFrame(p, fg_color="transparent")
        head.grid(row=0, column=0, sticky="ew", padx=8, pady=(8, 4))
        head.grid_columnconfigure(0, weight=1)
        label(head, "Download queue", 18, "bold").grid(row=0, column=0, sticky="w")
        label(head, "Parallel:", 12, color=MUTED).grid(row=0, column=1, padx=(0, 6))
        self.parallel_combo = ctk.CTkSegmentedButton(head, values=["1", "2", "3", "4"], command=self._set_parallel,
                                                     selected_color=BLUE)
        self.parallel_combo.set(str(self.m.settings.get("max_parallel", 2)))
        self.parallel_combo.grid(row=0, column=2, padx=(0, 12))
        button(head, "Clear finished", self.m.clear_finished, "ghost", width=120).grid(row=0, column=3)
        self.dl_list = ctk.CTkFrame(p, fg_color="transparent")
        self.dl_list.grid(row=1, column=0, sticky="ew")
        self.dl_list.grid_columnconfigure(0, weight=1)
        self.dl_empty = label(p, "Abhi koi download nahi. Home par link paste karein.", 14, color=MUTED, anchor="center")
        self._downloads_empty_state()

    def _set_parallel(self, v):
        self.m.settings["max_parallel"] = int(v)
        self.m.save_settings()
        self.m._pump()

    def _relayout_cards(self):
        order = [t.id for t in self.m.tasks]
        for i, tid in enumerate(order):
            c = self.cards.get(tid)
            if c:
                c.grid(row=i, column=0, sticky="ew", padx=8, pady=6)
        self._downloads_empty_state()

    def _downloads_empty_state(self):
        if not hasattr(self, "dl_empty"):
            return
        if self.cards:
            self.dl_empty.grid_remove()
        else:
            self.dl_empty.grid(row=2, column=0, sticky="ew", pady=40)

    # ------------------------------------------------------------------ HISTORY

    def _page_history(self, p):
        top = ctk.CTkFrame(p, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=8, pady=(8, 6))
        top.grid_columnconfigure(0, weight=1)
        self.hist_q = tk.StringVar()
        e = entry(top, self.hist_q, "Search title / site / link...")
        e.grid(row=0, column=0, sticky="ew")
        self.hist_q.trace_add("write", lambda *_: self._render_history())
        button(top, "Clear history", self._clear_history, "danger", width=120).grid(row=0, column=1, padx=(8, 0))
        self.hist_count = label(p, "", 12, color=MUTED)
        self.hist_count.grid(row=1, column=0, sticky="ew", padx=12)
        self.hist_list = ctk.CTkFrame(p, fg_color="transparent")
        self.hist_list.grid(row=2, column=0, sticky="ew")
        self.hist_list.grid_columnconfigure(0, weight=1)

    def _render_history(self):
        if not hasattr(self, "hist_list"):
            return
        self._history_dirty = False
        for w in self.hist_list.winfo_children():
            w.destroy()
        q = self.hist_q.get().strip().lower()
        rows = [x for x in reversed(self.m.history)
                if not q or q in (x.get("title", "") + x.get("url", "") + x.get("site", "")).lower()]
        self.hist_count.configure(text=f"{len(rows)} items" + (" (showing latest 150)" if len(rows) > 150 else ""))
        if not rows:
            label(self.hist_list, "History khali hai." if not q else "Kuch nahi mila.", 14, color=MUTED,
                  anchor="center").grid(row=0, column=0, sticky="ew", pady=40)
            return
        for i, item in enumerate(rows[:150]):
            box = card(self.hist_list, corner_radius=14)
            box.grid(row=i, column=0, sticky="ew", padx=8, pady=4)
            box.grid_columnconfigure(0, weight=1)
            label(box, item.get("title", "Untitled")[:140], 14, "bold").grid(row=0, column=0, sticky="ew", padx=14, pady=(10, 0))
            meta = "   •   ".join(x for x in (item.get("date", ""), item.get("site", ""), item.get("quality", ""),
                                             item.get("route", "")) if x)
            label(box, meta, 12, color=MUTED).grid(row=1, column=0, sticky="ew", padx=14, pady=(0, 10))
            bar = ctk.CTkFrame(box, fg_color="transparent")
            bar.grid(row=0, column=1, rowspan=2, padx=10)
            f = item.get("file")
            if f and os.path.exists(f):
                button(bar, "Open", lambda f=f: self.safe(core.open_path, f), "ok", width=64, height=30).pack(side="left", padx=3)
            button(bar, "Folder", lambda it=item: self.safe(core.reveal_in_folder, it.get("file") if it.get("file") and os.path.exists(it.get("file")) else it.get("folder", ".")),
                   "ghost", width=64, height=30).pack(side="left", padx=3)
            button(bar, "Again", lambda u=item.get("url", ""): self._again(u), "ghost", width=64, height=30).pack(side="left", padx=3)
            button(bar, "Copy", lambda u=item.get("url", ""): self._copy(u), "ghost", width=56, height=30).pack(side="left", padx=3)
            button(bar, "✕", lambda it=item: self.m.remove_history(it), "ghost", width=34, height=30).pack(side="left", padx=3)

    def _again(self, url):
        self.url_var.set(url)
        self.show("home")
        self.analyze()

    def _copy(self, text):
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.toast("Link copied", OK)

    def _clear_history(self):
        if messagebox.askyesno("Clear history", "Saari history delete karein? (Downloaded files delete nahi hongi)"):
            self.m.clear_history()

    # ------------------------------------------------------------------ NETWORK

    def _page_network(self, p):
        s = self.m.settings
        st = card(p)
        st.grid(row=0, column=0, sticky="ew", padx=8, pady=8)
        st.grid_columnconfigure(0, weight=1)
        label(st, "Current route", 13, "bold", MUTED).grid(row=0, column=0, sticky="w", padx=20, pady=(16, 0))
        self.net_status = label(st, "", 20, "bold")
        self.net_status.grid(row=1, column=0, sticky="w", padx=20)
        self.net_detail = label(st, "", 12, color=MUTED, wraplength=760)
        self.net_detail.grid(row=2, column=0, sticky="w", padx=20, pady=(2, 14))
        btns = ctk.CTkFrame(st, fg_color="transparent")
        btns.grid(row=0, column=1, rowspan=3, padx=20)
        button(btns, "TEST CONNECTION", self._test_route, "accent", width=170).pack(pady=3)
        button(btns, "Open Tor Browser", self._open_tor, "ghost", width=170).pack(pady=3)

        rc = card(p)
        rc.grid(row=1, column=0, sticky="ew", padx=8, pady=8)
        label(rc, "Route", 16, "bold").pack(anchor="w", padx=20, pady=(16, 6))
        self.route_var = tk.StringVar(value=s["route"])
        desc = {
            "auto": "Tor Browser khula ho to Tor, warna Direct. (PC par Tor kholo, link paste karo — bas.)",
            "direct": "Seedha internet. Sab se tez.",
            "tor": "Sirf Tor. Tor band ho to download nahi chalega (koi leak nahi).",
            "proxy": "Apna HTTP / SOCKS5 proxy (VPN provider ka proxy bhi).",
            "tunnel": "Apne VPS par SSH tunnel (sirf is app ka traffic).",
        }
        for key in core.ROUTES:
            f = ctk.CTkFrame(rc, fg_color="transparent")
            f.pack(fill="x", padx=20, pady=3)
            ctk.CTkRadioButton(f, text=core.ROUTE_LABELS[key], value=key, variable=self.route_var, font=font(14, "bold"),
                               command=self._set_route).pack(side="left")
            label(f, desc[key], 12, color=MUTED).pack(side="left", padx=12)
        self.smart_var = tk.BooleanVar(value=s.get("smart_network", True))
        ctk.CTkCheckBox(rc, text="Smart fallback: Direct fail ho aur Tor chal raha ho to khud Tor se retry",
                        variable=self.smart_var, command=self._set_smart, font=font(13)).pack(anchor="w", padx=20, pady=(8, 16))

        pc = card(p)
        pc.grid(row=2, column=0, sticky="ew", padx=8, pady=8)
        pc.grid_columnconfigure(1, weight=1)
        label(pc, "Custom proxy", 16, "bold").grid(row=0, column=0, columnspan=3, sticky="w", padx=20, pady=(16, 6))
        self.pkind = ctk.CTkSegmentedButton(pc, values=["http", "socks5"], selected_color=BLUE)
        self.pkind.set(s.get("proxy_kind", "http"))
        self.pkind.grid(row=1, column=0, padx=(20, 8), pady=4, sticky="w")
        self.purl = tk.StringVar(value=s.get("proxy_url", ""))
        entry(pc, self.purl, "127.0.0.1:8080  /  user:pass@host:port").grid(row=1, column=1, sticky="ew", pady=4)
        b = ctk.CTkFrame(pc, fg_color="transparent")
        b.grid(row=1, column=2, padx=20)
        button(b, "Detect system", self._detect_system_proxy, "ghost", width=120).pack(side="left", padx=3)
        button(b, "Save & use", self._save_proxy, "primary", width=110).pack(side="left", padx=3)
        ctk.CTkFrame(pc, height=12, fg_color="transparent").grid(row=2, column=0)

        tc = card(p)
        tc.grid(row=3, column=0, sticky="ew", padx=8, pady=8)
        tc.grid_columnconfigure(1, weight=1)
        label(tc, "Private tunnel (SSH SOCKS5)", 16, "bold").grid(row=0, column=0, columnspan=3, sticky="w", padx=20, pady=(16, 2))
        label(tc, "VPS chahiye (server_setup_ubuntu.sh dekhein). Password store nahi hota, sirf key file.", 12,
              color=MUTED).grid(row=1, column=0, columnspan=3, sticky="w", padx=20, pady=(0, 8))
        self.tv = {}
        for i, (k, lab, ph) in enumerate((("tunnel_host", "Server IP / domain", "203.0.113.10"),
                                          ("tunnel_port", "SSH port", "22"),
                                          ("tunnel_user", "Username", "ubuntu"),
                                          ("tunnel_local_port", "Local SOCKS port", "1080"),
                                          ("tunnel_key", "Private key file", ".pem / .key"))):
            label(tc, lab, 13).grid(row=2 + i, column=0, sticky="w", padx=20, pady=3)
            self.tv[k] = tk.StringVar(value=str(s.get(k, "")))
            entry(tc, self.tv[k], ph, height=36).grid(row=2 + i, column=1, sticky="ew", pady=3)
        button(tc, "Browse", self._browse_key, "ghost", width=90).grid(row=6, column=2, padx=20)
        tb = ctk.CTkFrame(tc, fg_color="transparent")
        tb.grid(row=7, column=0, columnspan=3, sticky="ew", padx=20, pady=(10, 16))
        self.tunnel_btn = button(tb, "CONNECT TUNNEL", self._connect_tunnel, "primary", width=180)
        self.tunnel_btn.pack(side="left")
        button(tb, "Disconnect", self._disconnect_tunnel, "danger", width=120).pack(side="left", padx=8)

    def _refresh_network_page(self):
        if not hasattr(self, "net_status"):
            return
        net = self.m.net
        self.net_status.configure(text=net.label(), text_color=OK if net.is_tor() else TEXT)
        if net.tor_port:
            d = f"Tor chal raha hai (127.0.0.1:{net.tor_port}). Auto / Tor mode mein saara traffic Tor se jayega."
        else:
            d = "Tor nahi chal raha. Tor Browser kholein aur 'Connect' dabayein — app 3 second mein khud pakar legi."
        if net.mode == "tunnel":
            d = "Tunnel connected: " + net.tunnel.proxy_url if net.tunnel.connected else "Tunnel disconnected."
        self.net_detail.configure(text=d)

    def _set_route(self):
        self.m.settings["route"] = self.route_var.get()
        self.m.save_settings()
        self._update_route_chip()
        self._refresh_network_page()

    def _set_smart(self):
        self.m.settings["smart_network"] = bool(self.smart_var.get())
        self.m.save_settings()

    def _test_route(self):
        self.toast("Testing route...", CYAN)
        self.run_bg("route_test", core.test_route, self.m.net, self.m.tools)

    def _on_route_test(self, ok, res):
        if ok:
            self.toast(f"Connected • {res * 1000:.0f} ms • {self.m.net.label()}", OK)
            messagebox.showinfo("Connection test", f"Internet reachable through: {self.m.net.label()}\nTime: {res * 1000:.0f} ms")
        else:
            self.toast("Connection test failed", BAD)
            messagebox.showerror("Connection test", core.friendly_error(res))

    def _open_tor(self):
        exe = core.find_tor_browser()
        if not exe:
            exe = filedialog.askopenfilename(title="Tor Browser (firefox.exe) select karein",
                                             filetypes=[("Tor Browser", "firefox.exe"), ("Programs", "*.exe"), ("All", "*.*")])
            if not exe:
                if messagebox.askyesno("Tor Browser", "Tor Browser nahi mila. Download page kholein?"):
                    webbrowser.open("https://www.torproject.org/download/")
                return
        self.safe(subprocess.Popen, [exe])
        self.toast("Tor Browser khul raha hai • connect hone ka intezar", CYAN)

    def _detect_system_proxy(self):
        import urllib.request
        prox = urllib.request.getproxies() or {}
        val = prox.get("https") or prox.get("http") or prox.get("all")
        if not val:
            messagebox.showinfo("Proxy", "Windows mein koi system proxy set nahi.\nChrome-only VPN extensions yahan nazar nahi aate.")
            return
        self.purl.set(val)
        self.pkind.set("socks5" if val.lower().startswith("socks") else "http")
        self.toast("System proxy mil gaya — Save & use dabayein", OK)

    def _save_proxy(self):
        try:
            core.normalize_proxy(self.purl.get(), self.pkind.get())
        except ValueError as exc:
            messagebox.showerror("Proxy", str(exc))
            return
        s = self.m.settings
        s.update(proxy_url=self.purl.get().strip(), proxy_kind=self.pkind.get(), route="proxy")
        self.route_var.set("proxy")
        self.m.save_settings()
        self._update_route_chip()
        self.toast("Custom proxy active", OK)

    def _browse_key(self):
        p = filedialog.askopenfilename(title="SSH private key", filetypes=[("Keys", "*.pem *.key *.ppk *"), ("All", "*.*")])
        if p:
            self.tv["tunnel_key"].set(p)

    def _connect_tunnel(self):
        v = {k: x.get().strip() for k, x in self.tv.items()}
        self.m.settings.update(v)
        self.m.save_settings()
        self.tunnel_btn.configure(state="disabled", text="CONNECTING...")
        self.run_bg("tunnel", self.m.net.tunnel.connect, v["tunnel_host"], v["tunnel_user"], v["tunnel_key"],
                    v["tunnel_port"] or 22, v["tunnel_local_port"] or 1080)

    def _on_tunnel(self, ok, res):
        self.tunnel_btn.configure(state="normal", text="CONNECT TUNNEL")
        if ok:
            self.m.settings["route"] = "tunnel"
            self.route_var.set("tunnel")
            self.m.save_settings()
            self.toast("Private tunnel connected", OK)
        else:
            messagebox.showerror("Tunnel", str(res))
        self._update_route_chip()

    def _disconnect_tunnel(self):
        self.m.net.tunnel.disconnect()
        if self.m.settings.get("route") == "tunnel":
            self.m.settings["route"] = "auto"
            self.route_var.set("auto")
            self.m.save_settings()
        self._update_route_chip()
        self.toast("Tunnel disconnected")

    # ------------------------------------------------------------------ BROWSER

    def _page_browser(self, p):
        c = card(p)
        c.grid(row=0, column=0, sticky="ew", padx=8, pady=8)
        label(c, "VPN Browser", 20, "bold").pack(anchor="w", padx=22, pady=(18, 4))
        label(c, "Chrome / Brave / Edge aapki normal profile ke saath khulta hai, is liye installed VPN extension "
                 "bhi wahan available hoti hai. Extension ke popup se connect / disconnect karein.",
              13, color=MUTED, wraplength=820).pack(anchor="w", padx=22)
        row = ctk.CTkFrame(c, fg_color="transparent")
        row.pack(anchor="w", padx=22, pady=16)
        button(row, "Open browser", lambda: self._launch_browser(False), "primary", width=170, height=44).pack(side="left")
        button(row, "Open incognito", lambda: self._launch_browser(True), "ghost", width=170, height=44).pack(side="left", padx=10)
        warn = card(c, fg_color=CARD2)
        warn.pack(fill="x", padx=22, pady=(0, 20))
        label(warn, "Zaroori baat", 14, "bold").pack(anchor="w", padx=14, pady=(10, 2))
        label(warn, "Browser ki VPN extension sirf browser ka traffic chalati hai. Downloader ka traffic us se nahi "
                    "jata. Downloader ke liye Network page par Tor, proxy ya tunnel use karein.",
              12, color=MUTED, wraplength=780).pack(anchor="w", padx=14, pady=(0, 12))

    def _launch_browser(self, incognito):
        exe = core.find_chrome()
        url = "https://www.google.com/"
        if not exe:
            webbrowser.open_new(url)
            return
        flag = "--inprivate" if incognito and exe.lower().endswith("msedge.exe") else ("--incognito" if incognito else "--new-window")
        self.safe(subprocess.Popen, [exe, flag, url])

    # ------------------------------------------------------------------ SETTINGS

    def _page_settings(self, p):
        s = self.m.settings
        gc = card(p)
        gc.grid(row=0, column=0, sticky="ew", padx=8, pady=8)
        gc.grid_columnconfigure(1, weight=1)
        label(gc, "General", 16, "bold").grid(row=0, column=0, columnspan=3, sticky="w", padx=20, pady=(16, 8))
        label(gc, "Theme", 13).grid(row=1, column=0, sticky="w", padx=20, pady=5)
        theme = ctk.CTkSegmentedButton(gc, values=["dark", "light", "system"], selected_color=BLUE,
                                       command=self._set_theme)
        theme.set(s.get("theme", "dark"))
        theme.grid(row=1, column=1, sticky="w", pady=5)
        label(gc, "Default folder", 13).grid(row=2, column=0, sticky="w", padx=20, pady=5)
        entry(gc, self.outdir_var, height=36).grid(row=2, column=1, sticky="ew", pady=5)
        button(gc, "Browse", self.browse, "ghost", width=90).grid(row=2, column=2, padx=20)
        label(gc, "aria2c (fast, Direct only)", 13).grid(row=3, column=0, sticky="w", padx=20, pady=(5, 16))
        self.aria_var = tk.BooleanVar(value=s.get("use_aria2c", False))
        ctk.CTkSwitch(gc, text="Use aria2c when installed (never with Tor / proxy)", variable=self.aria_var,
                      command=lambda: (s.update(use_aria2c=bool(self.aria_var.get())), self.m.save_settings())
                      ).grid(row=3, column=1, sticky="w", pady=(5, 16))

        tc = card(p)
        tc.grid(row=1, column=0, sticky="ew", padx=8, pady=8)
        tc.grid_columnconfigure(0, weight=1)
        label(tc, "Tools", 16, "bold").grid(row=0, column=0, sticky="w", padx=20, pady=(16, 6))
        self.tools_box = ctk.CTkFrame(tc, fg_color="transparent")
        self.tools_box.grid(row=1, column=0, sticky="ew", padx=20)
        self.tools_log = label(tc, "", 12, color=MUTED)
        self.tools_log.grid(row=2, column=0, sticky="ew", padx=20, pady=(6, 0))
        self.tools_btn = button(tc, "Install missing tools", self._install_tools, "accent", width=200)
        self.tools_btn.grid(row=3, column=0, sticky="w", padx=20, pady=(8, 16))

        ec = card(p)
        ec.grid(row=2, column=0, sticky="ew", padx=8, pady=8)
        ec.grid_columnconfigure(0, weight=1)
        label(ec, "Browser extension (IDM jaisa)", 16, "bold").grid(row=0, column=0, sticky="w", padx=20, pady=(16, 2))
        on = self.bridge is not None
        label(ec, ("● Browser se link lene ke liye tayyar" if on else "● Bridge band hai (shayad NexGrab pehle se khula hai)"),
              13, "bold", OK if on else WARN).grid(row=1, column=0, sticky="w", padx=20)
        label(ec, "Extension lagane ke baad har video par 'NexGrab' button aayega, aur right-click menu mein bhi. "
                  "Click karte hi video is app mein khulegi.\n"
                  "Lagane ka tareeqa: 1) neeche button dabayein  2) browser ke Extensions page par 'Developer mode' on karein  "
                  "3) 'Load unpacked' dabayein aur jo folder khula hai woh select karein.",
              12, color=MUTED, wraplength=760, justify="left").grid(row=2, column=0, sticky="w", padx=20, pady=(4, 8))
        button(ec, "Extension install karein", self._install_extension, "accent", width=220).grid(
            row=3, column=0, sticky="w", padx=20, pady=(0, 16))

        ac = card(p)
        ac.grid(row=3, column=0, sticky="ew", padx=8, pady=8)
        label(ac, core.APP_NAME, 16, "bold").pack(anchor="w", padx=20, pady=(16, 2))
        label(ac, f"Version {core.APP_VERSION}   •   Developer: {core.DEVELOPER}", 13, color=MUTED).pack(anchor="w", padx=20)
        label(ac, f"Data folder: {core.DATA_DIR}", 12, color=MUTED).pack(anchor="w", padx=20, pady=(2, 4))
        label(ac, "Sirf woh content download karein jis ka aap ko haq / ijazat ho.", 12, color=MUTED).pack(
            anchor="w", padx=20, pady=(0, 16))

    def _install_extension(self):
        folder = bridge.extension_folder()
        if not folder:
            messagebox.showerror("Extension", "Extension folder nahi mila. NexGrab zip dobara extract karein "
                                              "(EXE ke saath 'extension' folder hona chahiye).")
            return
        self.safe(bridge.open_extension_setup, core.find_chrome())
        messagebox.showinfo("Extension", "Browser ka Extensions page aur extension folder khul gaye hain.\n\n"
                                         "1) Upar right par 'Developer mode' on karein\n"
                                         "2) 'Load unpacked' dabayein\n"
                                         f"3) Yeh folder select karein:\n{folder}\n\n"
                                         "Folder ko delete ya move na karein, warna extension band ho jayegi.")

    def _set_theme(self, v):
        self.m.settings["theme"] = v
        self.m.save_settings()
        ctk.set_appearance_mode(v)

    def _refresh_tools(self):
        if not hasattr(self, "tools_box"):
            return
        for w in self.tools_box.winfo_children():
            w.destroy()
        missing = False
        for i, (name, ok, note) in enumerate(self.m.tools.status_lines()):
            if not ok and "optional" not in name:
                missing = True
            label(self.tools_box, ("✔  " if ok else "✖  ") + name, 13, "bold",
                  OK if ok else (MUTED if "optional" in name else BAD)).grid(row=i, column=0, sticky="w", pady=2)
            label(self.tools_box, note, 12, color=MUTED).grid(row=i, column=1, sticky="w", padx=16)
        self.tools_btn.configure(state="normal" if missing and core.IS_WIN else "disabled",
                                 text="Install missing tools" if missing else "All tools ready")

    def _install_tools(self):
        self.tools_btn.configure(state="disabled", text="Installing...")
        logq = self._ui_events

        def log(msg):
            logq.put(("tool_log", True, msg))

        self.run_bg("tools", core.install_tools, self.m.tools, log)

    def _on_tool_log(self, ok, msg):
        self.tools_log.configure(text=msg)

    def _on_tools(self, ok, res):
        self._refresh_tools()
        if ok:
            self.toast("Tools installed", OK)
        else:
            self.tools_log.configure(text=core.friendly_error(res))
            messagebox.showerror("Tools", core.friendly_error(res))

    # ------------------------------------------------------------------ close

    def _on_close(self):
        active = [t for t in self.m.tasks if t.status in (core.Task.RUNNING, core.Task.PROCESSING)]
        if active and not messagebox.askyesno(
                core.APP_NAME, f"{len(active)} download chal rahe hain. Band karein? (Baad mein Retry se resume ho jayenge)"):
            return
        self.m.settings["output_dir"] = self.outdir_var.get().strip() or self.m.settings["output_dir"]
        self.m.shutdown()
        if self.bridge:
            self.bridge.stop()
        self.root.destroy()


def main():
    if core.IS_WIN:
        try:  # crisp text on high-DPI screens + own taskbar icon
            import ctypes

            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("WSNex.NexGrab")
        except Exception:
            pass
    link = next((a for a in sys.argv[1:] if a.lower().startswith("nexgrab:")), None)
    req = bridge.parse_protocol(link) if link else None
    if req and bridge.forward_to_running(req):
        return  # NexGrab is already open - it got the link
    root = ctk.CTk()
    app = App(root)
    if req:
        root.after(600, lambda: app.handle_browser_request(req))
    if "--page" in sys.argv:  # e.g. "--page settings" (handy for shortcuts)
        try:
            app.show(sys.argv[sys.argv.index("--page") + 1])
        except Exception:
            pass
    root.mainloop()


if __name__ == "__main__":
    main()
