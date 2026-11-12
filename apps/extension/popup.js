const $ = (id) => document.getElementById(id);

chrome.runtime.sendMessage({ type: "ping" }, (r) => {
  const ok = r && r.ok;
  $("status").className = "status " + (ok ? "on" : "off");
  $("statusText").textContent = ok ? `NexGrab app chal rahi hai (v${r.version})` : "NexGrab app band hai - click par khul jayegi";
});

chrome.storage.sync.get({ overlay: true }, (v) => { $("overlay").checked = v.overlay !== false; });
$("overlay").addEventListener("change", (e) => chrome.storage.sync.set({ overlay: e.target.checked }));

async function grab(mode) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https?:/i.test(tab.url || "")) {
    $("msg").textContent = "Is page se download nahi ho sakta.";
    return;
  }
  chrome.runtime.sendMessage({ type: "grab", req: { url: tab.url, mode, title: tab.title || "", page: tab.url } }, (res) => {
    if (res && res.ok) { $("msg").textContent = "NexGrab mein bhej diya ✓"; setTimeout(() => window.close(), 900); }
    else if (res && res.launched) $("msg").textContent = "NexGrab app khul rahi hai… browser poochhe to Open dabayein.";
    else $("msg").textContent = (res && res.error) || "NexGrab app tak nahi pahunch saka.";
  });
}
$("grab").addEventListener("click", () => grab("ask"));
$("best").addEventListener("click", () => grab("best"));
$("mp3").addEventListener("click", () => grab("mp3"));
