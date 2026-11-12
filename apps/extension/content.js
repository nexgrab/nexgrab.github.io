// NexGrab extension - shows a download button on top of videos (like IDM's panel).
(() => {
  if (window.__nexgrab) return;
  window.__nexgrab = true;

  let enabled = true;
  try {
    chrome.storage.sync.get({ overlay: true }, (v) => { enabled = v.overlay !== false; });
    chrome.storage.onChanged.addListener((c) => { if (c.overlay) { enabled = c.overlay.newValue !== false; if (!enabled) hide(); } });
  } catch (_) { /* storage unavailable: keep default */ }

  // ---------------------------------------------------------------- UI (shadow DOM: site CSS cannot touch it)
  const host = document.createElement("div");
  host.setAttribute("data-nexgrab", "");
  host.style.cssText = "all:initial;position:fixed;z-index:2147483647;top:0;left:0;width:0;height:0;";
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <style>
      :host { all: initial; }
      .bar { position: fixed; display: none; align-items: center; gap: 2px; font: 600 13px/1 system-ui, "Segoe UI", sans-serif;
             filter: drop-shadow(0 6px 16px rgba(0,0,0,.45)); user-select: none; }
      .bar.show { display: flex; }
      button { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 7px; height: 32px; padding: 0 12px;
               color: #04121a; background: linear-gradient(100deg, #22d3ee, #6366f1 60%, #a855f7); }
      .main { border-radius: 10px 0 0 10px; }
      .more { border-radius: 0 10px 10px 0; padding: 0 9px; border-left: 1px solid rgba(4,18,26,.25); }
      button:hover { filter: brightness(1.12); }
      svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; }
      .menu { position: fixed; display: none; min-width: 190px; padding: 6px; border-radius: 12px; background: #0d1424;
              border: 1px solid #1c2a45; box-shadow: 0 14px 40px rgba(0,0,0,.5); font: 500 13px system-ui, "Segoe UI", sans-serif; }
      .menu.show { display: block; }
      .menu div { padding: 9px 12px; border-radius: 8px; color: #e6edf7; cursor: pointer; }
      .menu div:hover { background: rgba(34,211,238,.12); color: #22d3ee; }
      .toast { position: fixed; display: none; max-width: 300px; padding: 10px 14px; border-radius: 12px; background: #0d1424;
               color: #e6edf7; border: 1px solid #1c2a45; font: 500 13px/1.4 system-ui, "Segoe UI", sans-serif;
               box-shadow: 0 14px 40px rgba(0,0,0,.5); }
      .toast.show { display: block; }
      .toast b { color: #22d3ee; }
    </style>
    <div class="bar" part="bar">
      <button class="main" title="NexGrab se download karein">
        <svg viewBox="0 0 24 24"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 20h14"/></svg><span>NexGrab</span>
      </button>
      <button class="more" title="Aur options">
        <svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>
      </button>
    </div>
    <div class="menu">
      <div data-mode="ask">Quality chunein…</div>
      <div data-mode="best">Best quality (seedha)</div>
      <div data-mode="mp3">Sirf audio (MP3)</div>
    </div>
    <div class="toast"></div>`;
  const bar = root.querySelector(".bar");
  const menu = root.querySelector(".menu");
  const toast = root.querySelector(".toast");
  const attach = () => { if (!host.isConnected) (document.body || document.documentElement).appendChild(host); };

  let current = null;  // the video under the mouse
  let hideTimer = 0;

  function hide() { bar.classList.remove("show"); menu.classList.remove("show"); current = null; }

  function place(v) {
    const r = v.getBoundingClientRect();
    const top = Math.max(6, r.top + 10);
    const right = Math.min(window.innerWidth - 6, r.right - 10);
    bar.style.top = top + "px";
    bar.style.left = Math.max(6, right - 150) + "px";
  }

  function usable(v) {
    const r = v.getBoundingClientRect();
    return r.width >= 160 && r.height >= 90 && r.bottom > 0 && r.top < window.innerHeight && getComputedStyle(v).visibility !== "hidden";
  }

  function videoAt(x, y) {
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom && usable(v)) return v;
    }
    return null;
  }

  document.addEventListener("mousemove", (e) => {
    if (!enabled) return;
    const path = e.composedPath ? e.composedPath() : [];
    if (path.includes(host)) { clearTimeout(hideTimer); return; }
    const v = videoAt(e.clientX, e.clientY);
    if (v) {
      attach();
      current = v;
      place(v);
      bar.classList.add("show");
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { if (!menu.classList.contains("show")) hide(); }, 2500);
    } else if (!menu.classList.contains("show")) {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(hide, 600);
    }
  }, { passive: true });
  window.addEventListener("scroll", () => { if (current && bar.classList.contains("show")) place(current); }, { passive: true });

  // ---------------------------------------------------------------- which link to send
  const abs = (href) => { try { return new URL(href, location.href).href; } catch (_) { return ""; } };
  function near(v, sel) {
    let el = v;
    for (let i = 0; el && i < 12; i++, el = el.parentElement) {
      const a = el.querySelector && el.querySelector(sel);
      if (a && a.getAttribute("href")) return abs(a.getAttribute("href"));
    }
    return "";
  }
  function linkFor(v) {
    const h = location.hostname.replace(/^www\.|^m\.|^mobile\./, "");
    const here = location.href;
    if (/youtube\.com$|youtube-nocookie\.com$/.test(h)) {
      if (/\/(watch|shorts|embed|live)\b/.test(location.pathname)) return here;
      return near(v, 'a[href*="/watch?v="], a[href^="/shorts/"]') || here;
    }
    if (/(^|\.)x\.com$|twitter\.com$/.test(h)) {
      const art = v.closest("article");
      const a = art && [...art.querySelectorAll('a[href*="/status/"]')].map((x) => x.getAttribute("href"))
        .find((x) => /\/status\/\d+$/.test(x));
      return a ? abs(a) : here;
    }
    if (/instagram\.com$/.test(h)) {
      if (/\/(p|reel|reels|tv)\//.test(location.pathname)) return here;
      return near(v, 'a[href*="/p/"], a[href*="/reel/"]') || here;
    }
    if (/tiktok\.com$/.test(h)) {
      if (/\/video\//.test(location.pathname)) return here;
      return near(v, 'a[href*="/video/"]') || here;
    }
    if (/facebook\.com$|fb\.watch$/.test(h)) {
      if (/\/(videos|reel|watch|share)\b/.test(location.pathname + location.search)) return here;
      return near(v, 'a[href*="/videos/"], a[href*="/reel/"], a[href*="/watch/"]') || here;
    }
    const src = v.currentSrc || v.src || "";
    if (/^https?:\/\//i.test(src) && !/\.m3u8|\.mpd/i.test(src)) return src;  // plain video file
    return here;
  }

  // ---------------------------------------------------------------- send
  function show(msg, ms = 3500) {
    attach();
    toast.innerHTML = msg;
    const r = bar.getBoundingClientRect();
    toast.style.top = (r.bottom ? r.bottom + 8 : 20) + "px";
    toast.style.left = Math.max(6, Math.min(window.innerWidth - 310, r.left || 20)) + "px";
    toast.classList.add("show");
    setTimeout(() => toast.classList.remove("show"), ms);
  }

  function send(mode) {
    menu.classList.remove("show");
    if (!current) return;
    const req = { url: linkFor(current), mode, title: document.title, page: location.href };
    try {
      chrome.runtime.sendMessage({ type: "grab", req }, (res) => {
        if (chrome.runtime.lastError) { show("NexGrab extension dobara load karein (page refresh)."); return; }
        if (res && res.ok) show("<b>NexGrab</b> mein bhej diya ✓");
        else if (res && res.launched) show("<b>NexGrab</b> app khul rahi hai… browser poochhe to <b>Open</b> dabayein.", 6000);
        else show((res && res.error) || "NexGrab app tak nahi pahunch saka.");
      });
    } catch (_) {
      show("NexGrab extension dobara load karein (page refresh).");
    }
  }

  root.querySelector(".main").addEventListener("click", (e) => { e.stopPropagation(); e.preventDefault(); send("ask"); });
  root.querySelector(".more").addEventListener("click", (e) => {
    e.stopPropagation(); e.preventDefault();
    const r = bar.getBoundingClientRect();
    menu.style.top = r.bottom + 6 + "px";
    menu.style.left = Math.max(6, r.right - 190) + "px";
    menu.classList.toggle("show");
  });
  menu.addEventListener("click", (e) => {
    const m = e.target && e.target.getAttribute && e.target.getAttribute("data-mode");
    if (m) { e.stopPropagation(); send(m); }
  });
  document.addEventListener("click", (e) => { if (!(e.composedPath ? e.composedPath() : []).includes(host)) menu.classList.remove("show"); });
})();
