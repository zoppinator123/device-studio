// Relays between Google Meet tabs and Device Studio on this Mac (through Chrome native messaging).
// Nothing is sent anywhere else.
const HOST = "com.jackzoppa.devicestudio";
const tabs = new Set();
let native = null;
let lastError = "";
let idleTimer = null;
let app = { running: false, recording: false, speakers: true };

function broadcast() {
  for (const port of tabs) {
    try { port.postMessage({ type: "state", ...app }); } catch (_) {}
  }
}

function ensureNative() {
  if (native) return native;
  try {
    native = chrome.runtime.connectNative(HOST);
  } catch (e) {
    lastError = String(e && e.message || e);
    native = null;
    return null;
  }
  native.onMessage.addListener((msg) => {
    if (!msg || typeof msg !== "object") return;
    if (msg.type === "state") {
      app = { running: true, recording: !!msg.recording, speakers: msg.speakers !== false };
      lastError = "";
    } else if (msg.type === "app") {
      app = { ...app, running: !!msg.running, recording: msg.running ? app.recording : false };
    }
    broadcast();
  });
  native.onDisconnect.addListener(() => {
    lastError = (chrome.runtime.lastError && chrome.runtime.lastError.message) || "Device Studio disconnected";
    native = null;
    app = { ...app, running: false, recording: false };
    broadcast();
    if (tabs.size) setTimeout(ensureNative, 5000);
  });
  return native;
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "meet") return;
  tabs.add(port);
  clearTimeout(idleTimer);
  ensureNative();
  port.postMessage({ type: "state", ...app });
  port.onMessage.addListener((msg) => {
    if (!msg || typeof msg !== "object") return;
    const n = ensureNative();
    if (n) { try { n.postMessage(msg); } catch (_) {} }
  });
  port.onDisconnect.addListener(() => {
    tabs.delete(port);
    if (!tabs.size) {
      // No Meet tab open: let the helper exit after a while.
      idleTimer = setTimeout(() => { if (!tabs.size && native) { native.disconnect(); native = null; app.running = false; } }, 30000);
    }
  });
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "status") {
    reply({ ...app, meetTabs: tabs.size, connected: !!native, error: lastError });
  }
});
