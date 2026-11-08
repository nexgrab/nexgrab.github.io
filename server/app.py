"""NexGrab web server - paste a link, get the file. Stores NOTHING.

* no database, no history, no URL logging (access log is off)
* every job lives only in memory; its temp folder is deleted right after the
  download (or after JOB_TTL seconds if nobody fetches it)

API
  GET  /api/health                 -> {"ok": true, "ytdlp": "..."}
  POST /api/info   {"url"}         -> title, thumbnail, options
  POST /api/jobs   {"url","option"}-> {"id"}
  GET  /api/jobs/{id}              -> live progress
  GET  /api/jobs/{id}/file         -> the file (then it is deleted)
  DELETE /api/jobs/{id}            -> cancel
"""
from __future__ import annotations

import os
import re
import shutil
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

import yt_dlp
from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

APP_VERSION = "3.2"
WORK = Path(os.environ.get("WORK_DIR") or tempfile.gettempdir()) / "nexgrab"
MAX_JOBS = int(os.environ.get("MAX_JOBS", "2"))            # parallel downloads on the server
MAX_PER_IP = int(os.environ.get("MAX_PER_IP", "1"))        # active jobs per visitor
MAX_FILESIZE = int(os.environ.get("MAX_FILESIZE_MB", "1500")) * 1024 * 1024
MAX_DURATION = int(os.environ.get("MAX_DURATION_MIN", "180")) * 60
JOB_TTL = int(os.environ.get("JOB_TTL_SEC", "900"))
PROXY = os.environ.get("PROXY", "")                        # optional, e.g. socks5h://...
COOKIES = os.environ.get("COOKIES_FILE", "")               # optional Netscape cookies.txt
ORIGINS = [o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",") if o.strip()]

shutil.rmtree(WORK, ignore_errors=True)
WORK.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="NexGrab", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(CORSMiddleware, allow_origins=ORIGINS, allow_methods=["GET", "POST", "DELETE"],
                   allow_headers=["Content-Type"], expose_headers=["Content-Disposition"])

slots = threading.BoundedSemaphore(MAX_JOBS)


# ----------------------------------------------------------------------------- helpers
class UserError(Exception):
    pass


def check_url(url: str) -> str:
    url = (url or "").strip()
    m = re.search(r"https?://\S+", url)
    if m:
        url = m.group(0)
    elif re.match(r"^[\w.-]+\.[a-z]{2,}(/\S*)?$", url, re.I):
        url = "https://" + url
    p = urlparse(url)
    if p.scheme not in ("http", "https") or not p.netloc:
        raise UserError("Ye sahi link nahi lag raha. Poora link paste karein (https://...).")
    host = (p.hostname or "").lower()
    if host in ("localhost",) or host.endswith(".local") or re.match(r"^(127\.|10\.|192\.168\.|169\.254\.|0\.)", host) \
            or re.match(r"^172\.(1[6-9]|2\d|3[01])\.", host) or host in ("::1", "[::1]"):
        if not os.environ.get("ALLOW_PRIVATE_URLS"):
            raise UserError("Ye link allowed nahi.")
    return url


def base_opts() -> dict:
    o = {
        "quiet": True, "no_warnings": True, "noplaylist": True, "noprogress": True,
        "socket_timeout": 30, "retries": 5, "fragment_retries": 10, "concurrent_fragment_downloads": 4,
        "max_filesize": MAX_FILESIZE, "cachedir": False, "restrictfilenames": False,
        "windowsfilenames": True, "trim_file_name": 150,
    }
    if PROXY:
        o["proxy"] = PROXY
    if COOKIES and Path(COOKIES).exists():
        # copy: yt-dlp rewrites the cookie file and secret files are read-only
        tmp = WORK / "cookies.txt"
        if not tmp.exists():
            shutil.copyfile(COOKIES, tmp)
        o["cookiefile"] = str(tmp)
    return o


def friendly(err: Exception | str) -> str:
    s = re.sub(r"\x1b\[[0-9;]*m", "", str(err)).replace("ERROR: ", "").strip()
    l = s.lower()
    if "not a bot" in l or "confirm you" in l:
        return ("YouTube ne is server ko bot samjha aur rok diya. Thori der baad try karein, "
                "ya NexGrab ki Android / Windows app use karein (woh aap ke apne internet se chalti hai).")
    if "login" in l or "cookies" in l or "private" in l or "rate-limit" in l:
        return "Is post ke liye login chahiye ya ye private hai. NexGrab app mein cookies ke saath try karein."
    if "unsupported url" in l:
        return "Ye website supported nahi hai."
    if "nsfw" in l or "sensitive" in l or "age-restricted" in l or "age restricted" in l:
        return ("Ye post 'sensitive / 18+' hai - website ise login ke baghair nahi dekh sakti. "
                "NexGrab app mein apni cookies.txt daal kar try karein.")
    if "[twitter]" in l and ("no video" in l or "no media" in l):
        return ("X ne is post ki video nahi di. Ya to post mein sirf photo / text hai, ya X ne ise 'Sensitive content' "
                "bana kar sirf login walon ke liye rakha hai (tab website se nahi milegi - NexGrab app + cookies use karein).")
    if "no video" in l or "no media" in l or "there is no video" in l:
        return "Is link mein video nahi mili (sirf photo / text ho sakti hai)."
    if "file is larger than" in l or "max_filesize" in l:
        return f"File bohat bari hai (website ki limit {MAX_FILESIZE // 1048576} MB). Bari files ke liye NexGrab app use karein."
    if "unavailable" in l or "removed" in l or "404" in l:
        return "Video maujood nahi (delete / private / region-blocked)."
    if "timed out" in l or "connection" in l:
        return "Website se connection nahi bana. Dobara try karein."
    return s[:300] or "Kuch ghalat ho gaya. Dobara try karein."


def build_options(info: dict) -> list[dict]:
    fmts = info.get("formats") or []
    heights = sorted({int(f["height"]) for f in fmts if f.get("height") and f.get("vcodec") not in (None, "none")},
                     reverse=True)
    has_audio = any(f.get("acodec") not in (None, "none") for f in fmts) or not fmts
    opts = []
    if heights:
        opts.append({"id": "best", "label": "Best quality", "detail": f"{heights[0]}p MP4", "kind": "video"})
        for h in (2160, 1440, 1080, 720, 480, 360):
            if any(x >= h for x in heights) and h <= heights[0]:
                if h == heights[0]:
                    continue
                opts.append({"id": f"h{h}", "label": f"{h}p", "detail": "MP4", "kind": "video"})
    if has_audio and (heights or fmts):
        opts.append({"id": "mp3", "label": "Audio MP3", "detail": "192 kbps", "kind": "audio"})
        opts.append({"id": "m4a", "label": "Audio M4A", "detail": "original", "kind": "audio"})
    if not opts:
        ext = info.get("ext") or "file"
        opts.append({"id": "file", "label": "Download", "detail": ext.upper(), "kind": "file"})
    return opts


def format_for(option: str) -> tuple[dict, str]:
    """yt-dlp options for an option id, plus a human label."""
    if option == "best":
        return {"format": "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b", "merge_output_format": "mp4"}, "video"
    m = re.fullmatch(r"h(\d{3,4})", option)
    if m:
        h = int(m.group(1))
        return {"format": f"bv*[height<={h}][ext=mp4]+ba[ext=m4a]/bv*[height<={h}]+ba/b[height<={h}]/b",
                "merge_output_format": "mp4"}, "video"
    if option == "mp3":
        return {"format": "ba/b", "postprocessors": [
            {"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}]}, "audio"
    if option == "m4a":
        return {"format": "ba[ext=m4a]/ba/b"}, "audio"
    if option == "file":
        return {"format": "b/best"}, "file"
    raise UserError("Ghalat option.")


# ----------------------------------------------------------------------------- jobs
@dataclass
class Job:
    id: str
    url: str
    option: str
    ip: str
    status: str = "queued"      # queued | downloading | processing | ready | error | canceled
    progress: float = 0.0
    downloaded: int = 0
    total: int = 0
    speed: float = 0.0
    eta: int = 0
    stage: str = "Line mein"
    error: str = ""
    path: str = ""
    filename: str = ""
    created: float = field(default_factory=time.time)
    cancel: bool = False

    def public(self) -> dict:
        return {k: getattr(self, k) for k in ("id", "status", "progress", "downloaded", "total", "speed", "eta",
                                              "stage", "error", "filename")}


jobs: dict[str, Job] = {}
jobs_lock = threading.Lock()


class Canceled(Exception):
    pass


def run_job(job: Job) -> None:
    folder = WORK / job.id
    try:
        with slots:
            if job.cancel:
                raise Canceled()
            folder.mkdir(parents=True, exist_ok=True)
            extra, _ = format_for(job.option)

            def hook(d):
                if job.cancel:
                    raise Canceled()
                if d.get("status") == "downloading":
                    job.status, job.stage = "downloading", "Download ho raha hai"
                    tot = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                    got = d.get("downloaded_bytes") or 0
                    job.downloaded, job.total = int(got), int(tot)
                    job.speed = float(d.get("speed") or 0)
                    job.eta = int(d.get("eta") or 0)
                    if tot:
                        job.progress = min(99.0, got * 100.0 / tot)
                    frag = d.get("fragment_index"), d.get("fragment_count")
                    if not tot and frag[0] and frag[1]:
                        job.progress = min(99.0, frag[0] * 100.0 / frag[1])
                elif d.get("status") == "finished":
                    job.stage = "Jod rahe hain (merge)"

            def pp_hook(d):
                if job.cancel:
                    raise Canceled()
                if d.get("status") == "started":
                    job.status = "processing"
                    name = d.get("postprocessor", "")
                    job.stage = "MP3 bana rahe hain" if "ExtractAudio" in name else "Video + audio jod rahe hain"

            opts = base_opts() | extra | {
                "outtmpl": str(folder / "%(title).120B [%(id)s].%(ext)s"),
                "progress_hooks": [hook], "postprocessor_hooks": [pp_hook],
                "match_filter": yt_dlp.utils.match_filter_func(f"!is_live & duration <=? {MAX_DURATION}"),
            }
            job.status, job.stage = "downloading", "Shuru ho raha hai"
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(job.url, download=True)
                if info is None:
                    raise UserError("Ye video lambi hai ya live hai (website par allowed nahi).")
            files = [p for p in folder.iterdir() if p.is_file() and not p.name.endswith((".part", ".ytdl"))]
            if not files:
                raise UserError("File nahi bani. Dobara try karein.")
            f = max(files, key=lambda p: p.stat().st_size)
            job.path, job.filename = str(f), f.name
            job.progress, job.status, job.stage = 100.0, "ready", "Tayyar"
    except Canceled:
        job.status, job.stage = "canceled", "Cancel"
        shutil.rmtree(folder, ignore_errors=True)
    except Exception as e:  # noqa: BLE001
        job.status, job.error, job.stage = "error", friendly(e), "Fail"
        shutil.rmtree(folder, ignore_errors=True)


def janitor() -> None:
    while True:
        time.sleep(30)
        now = time.time()
        with jobs_lock:
            old = [j for j in jobs.values() if now - j.created > JOB_TTL]
            for j in old:
                j.cancel = True
                jobs.pop(j.id, None)
        for j in old:
            shutil.rmtree(WORK / j.id, ignore_errors=True)


threading.Thread(target=janitor, daemon=True).start()


def client_ip(req: Request) -> str:
    fwd = req.headers.get("x-forwarded-for", "")
    return (fwd.split(",")[0].strip() if fwd else (req.client.host if req.client else "?"))


# ----------------------------------------------------------------------------- routes
class InfoIn(BaseModel):
    url: str


class JobIn(BaseModel):
    url: str
    option: str


@app.exception_handler(UserError)
async def user_error(_req, exc: UserError):
    return JSONResponse({"error": str(exc)}, status_code=400)


@app.get("/")
@app.get("/api/health")
def health():
    return {"ok": True, "name": "NexGrab", "version": APP_VERSION, "ytdlp": yt_dlp.version.__version__,
            "busy": sum(1 for j in jobs.values() if j.status in ("queued", "downloading", "processing"))}


@app.post("/api/info")
def info(body: InfoIn):
    url = check_url(body.url)
    try:
        with yt_dlp.YoutubeDL(base_opts() | {"skip_download": True}) as ydl:
            data = ydl.extract_info(url, download=False)
    except Exception as e:  # noqa: BLE001
        raise UserError(friendly(e)) from None
    if not data:
        raise UserError("Is link se kuch nahi mila.")
    if data.get("_type") == "playlist" and data.get("entries"):
        first = next((e for e in data["entries"] if e), None)
        if first:
            data = first
    if data.get("is_live"):
        raise UserError("Live stream website se download nahi hoti.")
    thumb = data.get("thumbnail") or ""
    return {
        "url": data.get("webpage_url") or url,
        "title": data.get("title") or "Video",
        "uploader": data.get("uploader") or data.get("channel") or "",
        "duration": int(data.get("duration") or 0),
        "site": data.get("extractor_key") or data.get("extractor") or "",
        "thumbnail": thumb if thumb.startswith("https://") else "",
        "options": build_options(data),
    }


@app.post("/api/jobs")
def create_job(body: JobIn, req: Request):
    url = check_url(body.url)
    format_for(body.option)  # validates
    ip = client_ip(req)
    with jobs_lock:
        mine = [j for j in jobs.values() if j.ip == ip and j.status in ("queued", "downloading", "processing")]
        if len(mine) >= MAX_PER_IP:
            raise UserError("Aap ka ek download pehle se chal raha hai. Woh khatam hone dein.")
        busy = sum(1 for j in jobs.values() if j.status in ("queued", "downloading", "processing"))
        if busy >= MAX_JOBS * 4:
            raise UserError("Server abhi bohat busy hai. 1-2 minute baad try karein, ya NexGrab app use karein.")
        job = Job(uuid.uuid4().hex, url, body.option, ip)
        jobs[job.id] = job
    threading.Thread(target=run_job, args=(job,), daemon=True).start()
    return {"id": job.id}


def _get(job_id: str) -> Job:
    j = jobs.get(job_id)
    if not j:
        raise HTTPException(404, "Ye download khatam / expire ho chuka.")
    return j


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str):
    return _get(job_id).public()


@app.delete("/api/jobs/{job_id}")
def cancel_job(job_id: str):
    j = _get(job_id)
    j.cancel = True
    if j.status in ("ready", "error"):
        with jobs_lock:
            jobs.pop(j.id, None)
        shutil.rmtree(WORK / j.id, ignore_errors=True)
    return {"ok": True}


def _forget(job_id: str) -> None:
    with jobs_lock:
        jobs.pop(job_id, None)
    shutil.rmtree(WORK / job_id, ignore_errors=True)


@app.get("/api/jobs/{job_id}/file")
def job_file(job_id: str, background: BackgroundTasks):
    j = _get(job_id)
    if j.status != "ready" or not j.path or not Path(j.path).exists():
        raise HTTPException(409, "File abhi tayyar nahi.")
    background.add_task(_forget, j.id)   # delete right after it is sent - nothing is kept
    return FileResponse(j.path, filename=j.filename, media_type="application/octet-stream")
