// Plays a web UI tour in headless Chrome and records it: screencast frames (2x) go to <work dir>/frames/,
// with their wall-clock times in frames.txt; events (EVT|epoch|…) go to stdout, as with the Mac driver.
// No dependencies: Chrome DevTools Protocol over Node's built-in WebSocket.
// usage: node drive.mjs <base url> <tour file> <work dir>
//
// Tour commands (one per line, fields separated by |; # comments):
//   scene|chapter|caption        caption change (logged for compose.py)
//   go|/path                     load a page (no click)
//   click|target[|nth]           move the cursor there and click   (click? = optional: skip if not found)
//   hover|target[|nth]           move the cursor there
//   at|x|y                       move the cursor to viewport point x,y
//   type|text                    type into the focused field
//   key|Enter|Escape|Tab|cmd+Enter
//   select|target|value          pick an option of a <select> (dropdowns don't render in headless Chrome)
//   scroll|dy                    scroll the page with the wheel (dy in CSS px, + = down)
//   drag|target|dx|dy            drag an element (HTML5 drag and drop) by dx,dy
//   pause|seconds  ·  end
// Targets: an aria-label, title, placeholder or visible text (exact; ^prefix = starts with, ~text = contains),
// or css:<selector>[::<text it contains>][>><selector inside it>]. nth counts matches from 1.
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";

const [BASE, TOUR, W] = process.argv.slice(2);
const VW = 1280, VH = 768, DSF = 2;
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = s => new Promise(r => setTimeout(r, s * 1000));
const now = () => (Date.now() / 1000).toFixed(3);
const log = (...a) => console.log(["EVT", now(), ...a].join("|"));

// ---- Chrome + CDP
rmSync(`${W}/chrome`, { recursive: true, force: true }); rmSync(`${W}/frames`, { recursive: true, force: true });
mkdirSync(`${W}/frames`, { recursive: true });
const chrome = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${W}/chrome`,
  "--no-first-run", "--no-default-browser-check", `--force-device-scale-factor=${DSF}`, "--hide-scrollbars", "--disable-extensions",
  `--window-size=${VW},${VH}`, "about:blank"], { stdio: "ignore" });
let port;
for (let i = 0; i < 100 && !port; i++) {
  await sleep(0.1);
  if (existsSync(`${W}/chrome/DevToolsActivePort`)) port = readFileSync(`${W}/chrome/DevToolsActivePort`, "utf8").split("\n")[0];
}
const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r));
let seq = 0; const pending = new Map(), handlers = {};
ws.addEventListener("message", m => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { const [res, rej] = pending.get(d.id); pending.delete(d.id); d.error ? rej(new Error(d.error.message)) : res(d.result); }
  else if (d.method && handlers[d.method]) handlers[d.method](d.params);
});
const cdp = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, [res, rej]); ws.send(JSON.stringify({ id, method, params })); });

async function js(expr) {               // evaluate in the page; retries across navigations
  for (let i = 0; i < 40; i++) {
    try {
      const r = await cdp("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
      if (!r.exceptionDetails) return r.result.value;
      if (process.env.DEBUG) console.error("JS", JSON.stringify(r.exceptionDetails).slice(0, 300));
    } catch (e) { if (process.env.DEBUG) console.error("CDP", e.message); }
    await sleep(0.1);
  }
  throw new Error("evaluate failed: " + expr.slice(0, 80));
}

// ---- page setup: light mode, 2x, a drawn cursor (headless has none) that survives page loads
await cdp("Page.enable"); await cdp("Runtime.enable");
await cdp("Emulation.setDeviceMetricsOverride", { width: VW, height: VH, deviceScaleFactor: DSF, mobile: false });
await cdp("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] });
const CURSOR = `(() => {
  const at = () => { try { return JSON.parse(sessionStorage.getItem("__cur")) || [640, 400]; } catch { return [640, 400]; } };
  let el = null;
  const place = (x, y) => { if (el) el.style.transform = "translate(" + x + "px," + y + "px)"; };
  window.__cur = (x, y) => { place(x, y); try { sessionStorage.setItem("__cur", JSON.stringify([x, y])); } catch {} };
  const mk = () => {
    el = document.createElement("div");
    el.innerHTML = '<svg width="24" height="32" viewBox="0 0 24 32"><path d="M2 2 L2 25 L7.6 19.6 L11.4 28.4 L15.2 26.8 L11.5 18.2 L19.4 18.2 Z" fill="#000" stroke="#fff" stroke-width="1.7" stroke-linejoin="round"/></svg>';
    el.style.cssText = "position:fixed;left:-2px;top:-2px;z-index:2147483647;pointer-events:none;filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.35))";
    document.documentElement.appendChild(el); place(...at());
  };
  addEventListener("mousemove", e => window.__cur(e.clientX, e.clientY), true);
  addEventListener("dragover", e => window.__cur(e.clientX, e.clientY), true);
  document.readyState === "loading" ? addEventListener("DOMContentLoaded", mk) : mk();
})();`;
await cdp("Page.addScriptToEvaluateOnNewDocument", { source: CURSOR });

// ---- screencast
const frames = []; let nframe = 0;
handlers["Page.screencastFrame"] = p => {
  const name = `f${String(++nframe).padStart(6, "0")}.jpg`;
  writeFileSync(`${W}/frames/${name}`, Buffer.from(p.data, "base64"));
  frames.push(`${name}|${p.metadata.timestamp.toFixed(4)}`);
  cdp("Page.screencastFrameAck", { sessionId: p.sessionId }).catch(() => {});
};

// ---- input
let cx = 640, cy = 400;
const mouse = (type, x, y, extra = {}) => cdp("Input.dispatchMouseEvent", { type, x, y, button: "left", ...extra });
async function moveTo(x, y, dur) {
  const d = Math.hypot(x - cx, y - cy); dur ??= Math.min(0.9, 0.25 + d / 1400);
  const n = Math.max(2, Math.round(dur * 60)), x0 = cx, y0 = cy;
  for (let i = 1; i <= n; i++) {
    const t = i / n, e = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2;
    cx = x0 + (x - x0) * e; cy = y0 + (y - y0) * e;
    await mouse("mouseMoved", cx, cy, { button: "none" });
    await sleep(dur / n);
  }
}
async function key(spec) {
  const K = { Enter: [13, "\r"], Escape: [27, ""], Tab: [9, ""], ArrowUp: [38, ""], ArrowDown: [40, ""], Backspace: [8, ""] };
  let mods = 0, k = spec;
  if (spec.startsWith("cmd+")) { mods = 4; k = spec.slice(4); }
  const [vk, text] = K[k];
  await cdp("Input.dispatchKeyEvent", { type: text && !mods ? "keyDown" : "rawKeyDown", key: k, code: k, windowsVirtualKeyCode: vk, text: mods ? undefined : text, modifiers: mods });
  await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k, windowsVirtualKeyCode: vk, modifiers: mods });
}
async function type(s) {
  for (const ch of s) {
    await cdp("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
    await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
    await sleep(0.045 + Math.random() * 0.05);
  }
}
async function wheel(dy, dur = 0.7) {
  const n = Math.round(dur * 60); let done = 0;
  for (let i = 1; i <= n; i++) {
    const t = i / n, want = Math.round(dy * (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2));
    await mouse("mouseWheel", cx, cy, { button: "none", deltaX: 0, deltaY: want - done }); done = want;
    await sleep(dur / n);
  }
}

// finds a target and returns its center in viewport coordinates (null if not found)
const FIND = `(target, nth) => {
  const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== "hidden"; };
  let els;
  if (target.startsWith("css:")) {
    const [base, sub] = target.slice(4).split(">>");
    const [sel, txt] = base.split("::");
    els = [...document.querySelectorAll(sel)].filter(e => !txt || e.textContent.includes(txt));
    if (sub) els = els.flatMap(e => [...e.querySelectorAll(sub)]);
  } else {
    let m = s => s === target;
    if (target[0] === "^") { const t = target.slice(1); m = s => s.startsWith(t); }
    else if (target[0] === "~") { const t = target.slice(1); m = s => s.includes(t); }
    const all = [...document.querySelectorAll("body *")].filter(e => e.id !== "__cur");
    const attr = all.filter(e => ["aria-label", "title", "placeholder"].some(a => e.hasAttribute(a) && m(e.getAttribute(a).trim())));
    const text = all.filter(e => m((e.innerText || "").trim().replace(/\\s+/g, " ")) && ![...e.children].some(c => m((c.innerText || "").trim().replace(/\\s+/g, " "))));
    els = [...attr, ...text];
  }
  els = els.filter(vis);
  const e = els[(nth || 1) - 1];
  if (!e) return null;
  window.__el = e;
  const r = e.getBoundingClientRect();
  let pinned = false;                                 // in a fixed/sticky bar: never needs scrolling
  for (let a = e; a && a !== document.body; a = a.parentElement)
    if (/fixed|sticky/.test(getComputedStyle(a).position)) pinned = true;
  return [r.left + r.width / 2, r.top + r.height / 2, pinned ? 100 : r.top, pinned ? 100 : r.bottom];
}`;
async function find(target, nth, optional) {
  for (let i = 0; i < (optional ? 8 : 30); i++) {
    const r = await js(`(${FIND})(${JSON.stringify(target)}, ${nth || 1})`).catch(() => null);
    if (r) {
      if ((r[2] < 70 || r[3] > VH - 40) && i < 6) {  // off screen: scroll it into view first
        const dy = Math.round(r[3] > VH - 40 ? r[3] - VH * 0.62 : r[2] - VH * 0.3);
        await wheel(dy); await sleep(0.3); continue;
      }
      return r;
    }
    await sleep(0.1);
  }
  console.error("NOTFOUND " + target);
  return null;
}

// ---- tour
await cdp("Page.navigate", { url: BASE + "/today" }); await sleep(1.5);
await cdp("Page.startScreencast", { format: "jpeg", quality: 90, maxWidth: VW * DSF, maxHeight: VH * DSF, everyNthFrame: 1 });
await sleep(0.5); await moveTo(640, 400, 0.1);

for (const raw of readFileSync(TOUR, "utf8").split("\n")) {
  const line = raw.trim(); if (!line || line.startsWith("#")) continue;
  const [cmd, ...a] = line.split("|");
  switch (cmd) {
    case "scene": log("SCENE", a[0], a[1]); break;
    case "go": await cdp("Page.navigate", { url: BASE + a[0] }); await sleep(1); break;
    case "pause": await sleep(+a[0]); break;
    case "at": await moveTo(+a[0], +a[1]); break;
    case "hover": case "click": case "click?": {
      const r = await find(a[0], +a[1] || 1, cmd === "click?"); if (!r) break;
      await moveTo(r[0], r[1]); await sleep(0.12);
      if (cmd === "hover") break;
      log("CLICK", cx.toFixed(1), cy.toFixed(1));
      await mouse("mousePressed", cx, cy, { clickCount: 1 }); await sleep(0.07);
      await mouse("mouseReleased", cx, cy, { clickCount: 1 }); await sleep(0.35);
      break;
    }
    case "type": await type(a[0]); break;
    case "key": await key(a[0]); await sleep(0.3); break;
    case "scroll": await wheel(+a[0]); break;
    case "select": {
      const r = await find(a[0]); if (!r) break;
      await moveTo(r[0], r[1]); await sleep(0.12); log("CLICK", cx.toFixed(1), cy.toFixed(1));
      await js(`(() => { const e = window.__el.closest("select") || window.__el.querySelector("select");
        e.focus(); e.value = ${JSON.stringify(a[1])}; e.dispatchEvent(new Event("input", {bubbles: true}));
        e.dispatchEvent(new Event("change", {bubbles: true})); })()`);
      await sleep(0.4); break;
    }
    case "drag": {                                  // HTML5 drag and drop, via Chrome's drag interception
      const r = await find(a[0]); if (!r) break;
      const dx = +a[1], dy = +a[2];
      await moveTo(r[0], r[1]); await sleep(0.15);
      await cdp("Input.setInterceptDrags", { enabled: true });
      const got = new Promise(res => { handlers["Input.dragIntercepted"] = p => res(p.data); });
      await mouse("mousePressed", cx, cy, { clickCount: 1 });
      log("DRAG", cx.toFixed(1), cy.toFixed(1), dx, dy);
      const x0 = cx, y0 = cy;
      await mouse("mouseMoved", cx + 2, cy + 6, { button: "left", buttons: 1 });
      const data = await Promise.race([got, sleep(1).then(() => null)]);
      if (!data) { console.error("NODRAG " + a[0]); await mouse("mouseReleased", cx, cy); break; }
      await cdp("Input.dispatchDragEvent", { type: "dragEnter", x: cx, y: cy, data });
      const n = 70;
      for (let i = 1; i <= n; i++) {
        const t = i / n, e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
        cx = x0 + dx * e; cy = y0 + dy * e;
        await cdp("Input.dispatchDragEvent", { type: "dragOver", x: cx, y: cy, data });
        await js(`window.__cur(${cx}, ${cy})`).catch(() => {});
        await sleep(1.1 / n);
      }
      await cdp("Input.dispatchDragEvent", { type: "drop", x: cx, y: cy, data });
      await mouse("mouseReleased", cx, cy, { clickCount: 1 });
      await cdp("Input.setInterceptDrags", { enabled: false });
      break;
    }
    case "end": log("END"); break;
    default: console.error("unknown command " + cmd);
  }
}
await sleep(1.2);
await cdp("Page.stopScreencast"); await sleep(0.3);
writeFileSync(`${W}/frames.txt`, frames.join("\n") + "\n");
ws.close(); chrome.kill();
process.exit(0);
