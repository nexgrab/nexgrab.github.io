// NexGrab extension - background service worker.
// Sends "download this" requests to the NexGrab PC app (http://127.0.0.1:47321, this PC only).
// If the app is closed, opens a nexgrab:// link so Windows starts it.
const APP = "http://127.0.0.1:47321";

async function callApp(path, body, timeoutMs = 2500) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(APP + path, {
      method: body ? "POST" : "GET",
      headers: body ? { "Content-Type": "application/json", "X-NexGrab": "1" } : { "X-NexGrab": "1" },
      body: body ? JSON.stringify(body) : undefined,
      signal: ctl.signal,
    });
    return r.ok ? await r.json() : null;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

async function launchApp(req) {
  const q = new URLSearchParams({ url: req.url, mode: req.mode || "ask" });
  const tab = await chrome.tabs.create({ url: "nexgrab://grab?" + q.toString(), active: true });
  // the browser asks "Open NexGrab?" - close the helper tab afterwards
  setTimeout(() => chrome.tabs.remove(tab.id).catch(() => {}), 15000);
}

async function grab(req) {
  if (!/^https?:\/\//i.test(req.url || "")) return { ok: false, error: "Is video ka link nahi mila." };
  const res = await callApp("/grab", req);
  if (res && res.ok) return { ok: true };
  await launchApp(req);
  return { ok: false, launched: true };
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "grab") {
    grab(msg.req).then(reply);
    return true;
  }
  if (msg && msg.type === "ping") {
    callApp("/ping").then((r) => reply(r || { ok: false }));
    return true;
  }
  return false;
});

// ------------------------------------------------------------------ right-click menu
function makeMenus() {
  chrome.contextMenus.removeAll(() => {
    const contexts = ["link", "video", "audio", "page", "frame"];
    chrome.contextMenus.create({ id: "ng-ask", title: "NexGrab se download karein", contexts });
    chrome.contextMenus.create({ id: "ng-best", title: "NexGrab: Best quality (seedha)", contexts });
    chrome.contextMenus.create({ id: "ng-mp3", title: "NexGrab: sirf audio (MP3)", contexts });
  });
}
chrome.runtime.onInstalled.addListener(makeMenus);
chrome.runtime.onStartup.addListener(makeMenus);

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const src = info.srcUrl && /^https?:/i.test(info.srcUrl) ? info.srcUrl : "";
  const url = info.linkUrl || src || info.frameUrl || info.pageUrl;
  const mode = { "ng-ask": "ask", "ng-best": "best", "ng-mp3": "mp3" }[info.menuItemId] || "ask";
  grab({ url, mode, title: (tab && tab.title) || "", page: info.pageUrl || "" });
});
