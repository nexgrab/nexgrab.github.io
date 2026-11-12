/* NexGrab Pro section: prices + payment details come from pro.json (edit that file, no code change). */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const rs = (n) => "Rs " + Number(n || 0).toLocaleString("en-PK");
  const feats = ["Android + Windows apps", "Browser extension (IDM jaisa)", "HD / 4K, MP3, poori playlist", "Tor / proxy, pause / resume"];

  fetch("pro.json?t=" + Math.floor(Date.now() / 3600000))
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((cfg) => {
      const plans = Array.isArray(cfg.plans) ? cfg.plans : [];
      $("plans").innerHTML = plans.map((p) => `
        <div class="plan${p.best ? " best" : ""}">
          ${p.best ? '<span class="tag">Sab se behtar</span>' : ""}
          <h3>${esc(p.name)}</h3>
          <div class="price">${rs(p.pkr)}${p.id === "month" ? "<small>/mahina</small>" : ""}</div>
          <p class="muted">${esc(p.note)}</p>
          <ul>${feats.map((f) => `<li>${f}</li>`).join("")}</ul>
        </div>`).join("");

      const pays = Array.isArray(cfg.payments) ? cfg.payments.filter((x) => x && x.number) : [];
      if (pays.length) {
        $("payList").innerHTML = pays.map((x) => `
          <div class="acct"><b>${esc(x.method)}</b><span class="num">${esc(x.number)}</span><span class="muted">${esc(x.title)}</span>
          <button type="button" class="copy" data-copy="${esc(x.number)}">Copy</button></div>`).join("");
        $("payList").querySelectorAll(".copy").forEach((b) => b.addEventListener("click", () => {
          navigator.clipboard && navigator.clipboard.writeText(b.dataset.copy).then(() => { b.textContent = "Copied ✓"; setTimeout(() => (b.textContent = "Copy"), 1500); });
        }));
      }
      const wa = String(cfg.whatsapp || "").replace(/\D/g, "").replace(/^0/, "92");
      if (wa) {
        const text = "Assalam o Alaikum! Mujhe NexGrab Pro chahiye.\nPlan: \nNaam: \nDevice code(s): \n(Payment screenshot saath hai)";
        $("waBtn").href = `https://wa.me/${wa}?text=${encodeURIComponent(text)}`;
        $("waBtn").hidden = false;
      }
      if (cfg.gumroad_url && /^https:\/\//.test(cfg.gumroad_url)) {
        $("cardBtn").href = cfg.gumroad_url;
        $("cardBtn").hidden = false;
      }
    })
    .catch(() => { $("plans").innerHTML = '<p class="muted center">Prices load nahi ho sakin. Page refresh karein.</p>'; });
})();
