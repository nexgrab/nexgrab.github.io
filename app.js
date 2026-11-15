/* NexGrab website - paste a link, get the file. Nothing is stored (no cookies, no localStorage, no analytics). */
(() => {
  "use strict";
  const CFG = window.NEXGRAB || {};
  const API = (CFG.API || "").replace(/\/+$/, "");
  const REPO = CFG.REPO || "";
  const $ = (id) => document.getElementById(id);
  const el = {
    form: $("pasteForm"), url: $("url"), paste: $("pasteBtn"), clear: $("clearBtn"), grab: $("grabBtn"),
    pill: $("serverPill"), msg: $("msg"),
    result: $("result"), thumb: $("thumb"), site: $("site"), dur: $("dur"), title: $("title"), uploader: $("uploader"), opts: $("opts"),
    prog: $("prog"), stage: $("stage"), pct: $("pct"), bar: $("bar"), pinfo: $("pinfo"), cancel: $("cancelBtn"),
    done: $("done"), doneName: $("doneName"), again: $("againBtn"),
  };
  let current = null;      // {url, info}
  let jobId = null;
  let pollTimer = null;
  let serverUp = false;

  $("yr").textContent = new Date().getFullYear();

  // ------------------------------------------------------------------ helpers
  const show = (node, on = true) => { node.hidden = !on; };
  function message(text, kind = "err") {
    el.msg.textContent = text;
    el.msg.className = "msg" + (kind === "info" ? " info" : "");
    show(el.msg, !!text);
  }
  function fmtBytes(n) {
    if (!n) return "";
    const u = ["B", "KB", "MB", "GB"]; let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(n >= 100 || i === 0 ? 0 : 1) + " " + u[i];
  }
  function fmtTime(s) {
    s = Math.max(0, Math.round(s || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return h ? `${h}:${String(m).padStart(2, "0")}:${String(x).padStart(2, "0")}` : `${m}:${String(x).padStart(2, "0")}`;
  }
  function extractUrl(text) {
    const m = (text || "").match(/https?:\/\/[^\s"'<>]+/i);
    if (m) return m[0];
    const t = (text || "").trim();
    return /^[\w.-]+\.[a-z]{2,}(\/\S*)?$/i.test(t) ? "https://" + t : t;
  }
  async function api(path, opts = {}, timeout = 120000) {
    if (!API) throw new Error("Server abhi set nahi hua. Thori der baad try karein - ya NexGrab app download karein.");
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), timeout);
    try {
      const r = await fetch(API + path, { ...opts, signal: ctl.signal,
        headers: opts.body ? { "Content-Type": "application/json" } : undefined });
      let data = null;
      try { data = await r.json(); } catch (_) { /* not json */ }
      if (!r.ok) throw new Error((data && (data.error || data.detail)) || `Server error (${r.status})`);
      return data;
    } catch (e) {
      if (e.name === "AbortError") throw new Error("Server jawab nahi de raha. Dobara try karein.");
      if (e instanceof TypeError) throw new Error("Server tak pahunch nahi ho saki. Internet check karein ya thori der baad try karein.");
      throw e;
    } finally { clearTimeout(t); }
  }

  // ------------------------------------------------------------------ server status (free servers sleep - wake it early)
  function pill(state, text) { el.pill.className = "pill " + state; el.pill.lastElementChild.textContent = text; }
  async function wake() {
    if (!API) { pill("off", "Server setup baaqi hai - abhi apps use karein"); return false; }
    pill("wake", "Server jaag raha hai... (pehli dafa ~30-60 sec)");
    for (let i = 0; i < 6; i++) {
      try {
        const h = await api("/api/health", {}, 25000);
        serverUp = true;
        pill("on", `Server online · engine ${h.ytdlp || ""}`);
        return true;
      } catch (_) { await new Promise((r) => setTimeout(r, 4000)); }
    }
    pill("off", "Server abhi offline - NexGrab app use karein");
    return false;
  }

  // ------------------------------------------------------------------ analyze
  function resetCards() {
    show(el.result, false); show(el.prog, false); show(el.done, false); message("");
  }
  async function analyze(e) {
    if (e) e.preventDefault();
    stopPoll();
    const url = extractUrl(el.url.value);
    el.url.value = url;
    toggleClear();
    if (!url) { message("Pehle link paste karein."); el.url.focus(); return; }
    resetCards();
    el.grab.disabled = true; el.grab.classList.add("loading");
    try {
      if (!serverUp) {
        message("Server jaag raha hai, thora intezar karein...", "info");
        await wake();
      }
      message("Link check ho raha hai...", "info");
      const info = await api("/api/info", { method: "POST", body: JSON.stringify({ url }) }, 120000);
      current = { url: info.url || url, info };
      message("");
      renderInfo(info);
    } catch (err) {
      message(err.message);
    } finally {
      el.grab.disabled = false; el.grab.classList.remove("loading");
    }
  }

  function renderInfo(info) {
    el.title.textContent = info.title || "Video";
    el.uploader.textContent = info.uploader || "";
    const site = /^generic$/i.test(info.site || "") ? "" : (info.site || "");
    el.site.textContent = site;
    show(el.site, !!site);
    el.dur.textContent = info.duration ? fmtTime(info.duration) : "";
    show(el.dur, !!info.duration);
    el.thumb.style.backgroundImage = info.thumbnail ? `url("${info.thumbnail.replace(/"/g, "%22")}")` : "";
    el.thumb.classList.toggle("noimg", !info.thumbnail);
    el.opts.replaceChildren();
    (info.options || []).forEach((o, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "opt" + (i === 0 ? " first" : "") + (o.kind === "audio" ? " audio" : "");
      const t = document.createElement("b"); t.textContent = o.label;
      const s = document.createElement("small"); s.textContent = o.detail || "";
      b.append(t, s);
      b.addEventListener("click", () => startJob(o));
      el.opts.append(b);
    });
    show(el.result);
    el.result.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  // ------------------------------------------------------------------ download job
  async function startJob(opt) {
    if (!current) return;
    message("");
    show(el.done, false);
    setProgress({ status: "queued", progress: 0, stage: "Server par tayyar ho raha hai..." });
    show(el.prog);
    el.prog.scrollIntoView({ behavior: "smooth", block: "nearest" });
    el.opts.querySelectorAll("button").forEach((b) => (b.disabled = true));
    try {
      const r = await api("/api/jobs", { method: "POST", body: JSON.stringify({ url: current.url, option: opt.id }) }, 30000);
      jobId = r.id;
      poll();
    } catch (err) {
      show(el.prog, false);
      message(err.message);
      el.opts.querySelectorAll("button").forEach((b) => (b.disabled = false));
    }
  }

  function setProgress(j) {
    const p = Math.max(0, Math.min(100, j.progress || 0));
    const indet = (j.status === "queued") || (j.status === "processing") || (j.status === "downloading" && !p);
    el.bar.parentElement.classList.toggle("indet", indet);
    el.bar.style.width = p + "%";
    el.pct.textContent = indet && !p ? "…" : Math.floor(p) + "%";
    el.stage.textContent = j.stage || "Chal raha hai";
    const bits = [];
    if (j.downloaded) bits.push(fmtBytes(j.downloaded) + (j.total ? " / " + fmtBytes(j.total) : ""));
    if (j.speed) bits.push(fmtBytes(j.speed) + "/s");
    if (j.eta && j.status === "downloading") bits.push(fmtTime(j.eta) + " baaqi");
    el.pinfo.textContent = bits.join("  ·  ") || " ";
  }

  function stopPoll() { if (pollTimer) clearTimeout(pollTimer); pollTimer = null; }

  async function poll() {
    stopPoll();
    if (!jobId) return;
    let j;
    try {
      j = await api(`/api/jobs/${jobId}`, {}, 20000);
    } catch (err) {
      pollTimer = setTimeout(poll, 2500);
      return;
    }
    setProgress(j);
    if (j.status === "ready") {
      saveFile(j);
    } else if (j.status === "error" || j.status === "canceled") {
      show(el.prog, false);
      if (j.status === "error") message(j.error || "Download fail ho gaya.");
      jobId = null;
      el.opts.querySelectorAll("button").forEach((b) => (b.disabled = false));
    } else {
      pollTimer = setTimeout(poll, 900);
    }
  }

  function saveFile(j) {
    const a = document.createElement("a");
    a.href = `${API}/api/jobs/${jobId}/file`;
    a.rel = "noopener";
    a.download = j.filename || "";
    document.body.append(a);
    a.click();
    a.remove();
    jobId = null;
    show(el.prog, false);
    el.doneName.textContent = j.filename || "";
    show(el.done);
    el.opts.querySelectorAll("button").forEach((b) => (b.disabled = false));
  }

  el.cancel.addEventListener("click", async () => {
    const id = jobId;
    stopPoll(); jobId = null;
    show(el.prog, false);
    el.opts.querySelectorAll("button").forEach((b) => (b.disabled = false));
    if (id) { try { await api(`/api/jobs/${id}`, { method: "DELETE" }, 10000); } catch (_) { /* ignore */ } }
  });

  el.again.addEventListener("click", () => {
    resetCards(); current = null; el.url.value = ""; toggleClear(); el.url.focus();
    window.scrollTo({ top: 0, behavior: "smooth" });
  });

  // ------------------------------------------------------------------ input helpers
  function toggleClear() { show(el.clear, !!el.url.value); show(el.paste, !el.url.value); }
  el.url.addEventListener("input", toggleClear);
  el.url.addEventListener("paste", () => setTimeout(() => { toggleClear(); if (/^https?:\/\//i.test(el.url.value.trim())) analyze(); }, 30));
  el.clear.addEventListener("click", () => { el.url.value = ""; toggleClear(); resetCards(); el.url.focus(); });
  el.paste.addEventListener("click", async () => {
    try {
      const t = await navigator.clipboard.readText();
      if (t) { el.url.value = extractUrl(t); toggleClear(); analyze(); }
    } catch (_) {
      message("Browser ne clipboard ki ijazat nahi di - box mein long-press karke Paste karein.", "info");
      el.url.focus();
    }
  });
  el.form.addEventListener("submit", analyze);

  // ?url=... (share a link straight to the site)
  const q = new URLSearchParams(location.search).get("url") || new URLSearchParams(location.search).get("text");
  if (q) { el.url.value = extractUrl(q); toggleClear(); history.replaceState(null, "", location.pathname); analyze(); }
  else wake();

  // ------------------------------------------------------------------ app downloads (GitHub Releases)
  const base = REPO ? `https://github.com/${REPO}/releases/latest/download/` : "";
  const links = { dlAndroid: "NexGrab.apk", dlAndroid32: "NexGrab_32bit.apk", dlWindows: "NexGrab_Windows.zip", dlExtension: "NexGrab_Extension.zip" };
  Object.entries(links).forEach(([id, file]) => { const a = $(id); if (base) a.href = base + file; else a.classList.add("disabled"); });
  if (REPO) {
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((rel) => {
        const sizes = {};
        (rel.assets || []).forEach((a) => (sizes[a.name] = a.size));
        document.querySelectorAll(".ver").forEach((v) => {
          const s = sizes[v.dataset.asset];
          v.textContent = `${rel.tag_name || ""}${s ? " · " + fmtBytes(s) : ""}`;
        });
        const d = rel.published_at ? new Date(rel.published_at).toLocaleDateString() : "";
        $("relInfo").textContent = `Latest: ${rel.name || rel.tag_name}${d ? " · " + d : ""}`;
      })
      .catch(() => { $("relInfo").textContent = "Apps jald aa rahi hain - pehli release ban rahi hai."; });
  }
})();
