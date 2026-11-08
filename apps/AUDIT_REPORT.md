# NexGrab – Code Audit (v2.7 → v3.0)

Scope: `rsk_futuristic_downloader.py` (2,445 lines), `build_exe.bat`, `run_app.bat`,
`make_icon.py`, `requirements.txt`, `server_setup_ubuntu.sh`, plus the Android app.

Every fix listed below was tested. The tests used real downloads against a local
server, a local fake-Tor (SOCKS5) server, and the GUI running under a virtual
display. The EXE was also built with PyInstaller and run.

## Critical – the app broke or gave wrong results

| # | Problem in v2.7 | What happened | Fix in v3.0 |
|---|---|---|---|
| 1 | Download cards lived inside the page that `_clear_page()` destroys on every menu click | Switching pages during a download destroyed the card. Progress then stopped updating (TclError), and the Downloads page only showed a frozen snapshot | Pages are created once and only hidden/shown; cards are tied to task IDs |
| 2 | Worker threads updated Tk widgets (`root.after` from threads, `card.stats_lbl.configure`) | Tkinter is not thread-safe, which causes random freezes or crashes with many downloads | Workers only send events to a queue; the UI thread reads that queue every 100 ms |
| 3 | `fetch_btn`, `quality_combo` and `info_title` were used after leaving Home | Changing page while Analyze was running caused a crash | Fixed by the persistent pages |
| 4 | aria2c was used together with the Tor/SOCKS proxy | aria2c does not support SOCKS, so Tor downloads failed or ignored the proxy; aria2c also gave no live progress and cancel did not work | aria2c is off by default and is never used with Tor or a proxy |
| 5 | New yt-dlp needs a JavaScript runtime (deno) for YouTube | YouTube showed missing formats or failed | deno ships in `tools\` and `js_runtimes` is set; if missing it can be installed with one click |
| 6 | FFmpeg was not included | "Best available" (video+audio merge) and MP3 failed **after** the whole download had finished | FFmpeg ships in `tools\`; without it only single-file qualities are shown and MP3 is hidden |
| 7 | PyInstaller EXE: `PIL._tkinter_finder` was not bundled | In the EXE the logo and thumbnails did not load (found by actually building the EXE) | `--hidden-import PIL._tkinter_finder` added |

## High

| # | Problem | Fix |
|---|---|---|
| 8 | The "Open" button pointed to the pre-merge/pre-MP3 filename (`prepare_filename`) | The real final path comes from `post_hooks` |
| 9 | Cancel did nothing during merging, and `.part` files were left behind | Cancel works at every stage; only that task's own temp files are deleted |
| 10 | Smart fallback silently changed the **saved** settings to Tor permanently, and only worked during Analyze | Fallback now applies per request, for both Analyze and Download |
| 11 | Tor detection treated any open port 9150/9050 as Tor, and ran on the UI thread (2+ s freeze) | A real SOCKS5 handshake check now runs in a background watcher every 3 s |
| 12 | Tor was used only after clicking "Detect" | New **Auto** mode: open Tor Browser and it is picked up automatically |
| 13 | "Tor only" did not exist; smart fallback could move a Tor user to Direct | Tor-only refuses to download when Tor is down (no IP leak) |
| 14 | Playlists showed one card, a wrong file path and no item progress | Item x/y progress, a separate folder per playlist, one failed item does not stop the rest |
| 15 | SSH tunnel: `stderr=PIPE` could block, a dead tunnel still showed "connected", and a password prompt could hang it | stderr goes to a log file, a watcher detects a dead tunnel, `BatchMode=yes` is used |

## Medium

- Unlimited parallel downloads → proper queue with a 1–4 parallel setting.
- No pause/resume → added (resumes from the `.part` file; tested to continue from 4 MB, not from zero).
- Raw yt-dlp error text → clear messages (bot check, locked cookies, 403/404/429, private video, missing ffmpeg). A 404 is no longer reported as a "network error", which had also triggered a pointless Tor retry.
- Windows filenames → `windowsfilenames` + 160-character trim.
- Settings in `~\.rsk_downloader` → `%LOCALAPPDATA%\NexGrab` (old settings and history are copied over automatically).
- `requirements.txt`: `yt-dlp` without `[default]` → `yt-dlp[default]` (includes the YouTube JS solver files).
- `build_exe.bat`: global pip installs, required the `py` launcher, no tools, no checks → private `.venv`, Python detection (+ winget install), tkinter check, tools copied, ready zip.

## UI

- 10 sidebar items → 6 (Proxy/VPN, Private Tunnel, Tor Mode and Network Center merged into **Network / Tor**; Browser and VPN Browser merged).
- Route chip always visible (🧅 green when Tor is on).
- Thumbnail preview, live history search, Open / Folder / Again / Copy actions.
- Same dark-navy + cyan theme as the Android app; light theme still works.

## Build scripts (v3.0.1)

- `MAKE_APK.cmd` rejected the installed Flutter (a "3.41.4" rule plus a 25 s timeout). It then
  downloaded the whole 1 GB Flutter SDK with PowerShell `Invoke-WebRequest`, which is extremely slow
  (the "bytes written" that ran all night). It now **always uses the installed Flutter** and finds it
  in PATH and the common folders. If Flutter is truly missing, it uses `git clone` or `curl` with resume.
- A stale Flutter `lockfile` is removed first (a common cause of Flutter appearing to "hang").
- Java: only JDK 17/21 (Gradle fails on very new Java). The Android SDK is installed with no
  Android Studio needed. The ~1 GB NDK auto-download is skipped (this app has no C/C++ code).
- `flutter clean` was removed (it forced a full rebuild every time).
- All three batch files were run under a real `cmd.exe` (Wine): the full APK flow with a fake Flutter/SDK,
  and the full EXE build with real Windows Python + PyInstaller. The EXE built this way was opened
  and used to download and merge a 720p video; Tor detection also worked.
  Two more issues were found and fixed this way: ffmpeg could be picked from PATH instead of the
  bundled copy, and a broken Tcl/Tk could silently produce an EXE that does not start
  (the builder now stops with a clear message).

## YouTube "not a bot"

- Auto mode: when YouTube blocks Tor, the app retries the same request on Direct (both Analyze
  and Download). Tor-only mode never does this.
- Cookies: the `cookies.txt file...` option was added. A clear message is shown when Chrome cookies
  cannot be decrypted on Windows (use Firefox or cookies.txt instead).

## Android (same release)

- New logo (app + launcher icon), version 3.0.0.
- Tor-only mode never falls back to Direct (same rule as PC).
- Tested again: 68/68 engine tests, Auto Tor test, 0 analyzer issues on Flutter stable and 3.35.
