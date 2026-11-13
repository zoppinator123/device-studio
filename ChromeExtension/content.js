// Google Meet: reads the on-screen captions (speaker name and words) and passes them to Device Studio
// while it is recording, so each line of the local transcript can be named. Nothing is stored here and
// nothing is sent anywhere except Device Studio on this Mac.
(() => {
  "use strict";
  const MAX_WORDS = 40;           // only the newest words of a caption block are sent
  const SCAN_MS = 300;

  let port = null;
  let state = { running: false, recording: false, speakers: true };
  let lastSent = new WeakMap();    // caption entry -> text last sent
  let scanTimer = null;
  let observer = null;
  let observedRegion = null;
  let weEnabledCaptions = false;
  let captionAttempts = 0;
  let lastMeeting = "";
  let lastParticipants = "";
  const seenSpeakers = new Set();

  function connect() {
    try {
      port = chrome.runtime.connect({ name: "meet" });
    } catch (_) {
      port = null;            // the extension was reloaded; this page needs a refresh
      return;
    }
    port.onMessage.addListener((msg) => {
      if (msg && msg.type === "state") {
        const was = state.recording && state.speakers;
        state = { running: !!msg.running, recording: !!msg.recording, speakers: msg.speakers !== false };
        const now = state.recording && state.speakers;
        if (now && !was) { captionAttempts = 0; lastMeeting = ""; lastParticipants = ""; }
        if (!now && was) restoreCaptions();
        tick();
      }
    });
    port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 1000); });
  }

  function send(msg) {
    if (!port) return;
    try { port.postMessage(msg); } catch (_) { port = null; }
  }

  const active = () => state.running && state.recording && state.speakers;

  // MARK: Page reading. Meet's markup changes often, so each lookup tries known names first and falls
  // back to structure and accessibility labels.

  function inCall() {
    return !!document.querySelector('button[aria-label*="Leave call" i], button[jsname="CQylAd"], [data-call-ended="false"]');
  }

  function selfName() {
    const el = document.querySelector("[data-self-name]");
    return el ? el.getAttribute("data-self-name").trim() : "";
  }

  function meetingTitle() {
    const el = document.querySelector("[data-meeting-title]");
    const t = el && el.getAttribute("data-meeting-title");
    return (t || "").trim();
  }

  function captionRegion() {
    return document.querySelector('div[role="region"][aria-label*="aption" i]')
      || document.querySelector('div[jsname="dsyhDe"]')
      || document.querySelector(".a4cQT");
  }

  function captionsButton() {
    return document.querySelector('button[aria-label*="captions" i], button[jsname="r8qRAd"]');
  }

  const isOn = (b) => b.getAttribute("aria-pressed") === "true" || /turn off/i.test(b.getAttribute("aria-label") || "");

  function lines(el) {
    return (el.innerText || el.textContent || "").split("\n").map((s) => s.trim()).filter(Boolean);
  }

  // One caption entry -> {speaker, text}. Known classes first, then "first line is the name".
  function parseEntry(entry) {
    const nameEl = entry.querySelector(".NWpY1d, .zs7s8d, .KcIKyf");
    const textEl = entry.querySelector(".ygicle, .iTTPOb, .VbkSUe");
    if (nameEl && textEl) {
      return { speaker: (nameEl.innerText || nameEl.textContent || "").trim(), text: (textEl.innerText || textEl.textContent || "").trim() };
    }
    const parts = lines(entry);
    if (parts.length < 2) return null;
    return { speaker: parts[0], text: parts.slice(1).join(" ") };
  }

  // Each caption entry carries one avatar image; the entry is the largest ancestor of that image, inside
  // the region, that holds no other avatar.
  function captionEntries(region) {
    const known = region.querySelectorAll(".nMcdL, .TBMuR");
    if (known.length) return Array.from(known);
    const entries = [];
    for (const img of region.querySelectorAll("img")) {
      let node = img;
      while (node.parentElement && node.parentElement !== region && node.parentElement.querySelectorAll("img").length === 1) {
        node = node.parentElement;
      }
      if (!entries.includes(node)) entries.push(node);
    }
    return entries;
  }

  function tail(text) {
    const words = text.split(/\s+/).filter(Boolean);
    return words.slice(-MAX_WORDS).join(" ");
  }

  function scanCaptions() {
    const region = captionRegion();
    if (!region) return;
    const me = selfName();
    for (const entry of captionEntries(region)) {
      const parsed = parseEntry(entry);
      if (!parsed || !parsed.speaker || !parsed.text) continue;
      if (/^you$/i.test(parsed.speaker) || (me && parsed.speaker === me)) continue;
      if (lastSent.get(entry) === parsed.text) continue;
      lastSent.set(entry, parsed.text);
      seenSpeakers.add(parsed.speaker);
      send({ type: "caption", speaker: parsed.speaker, text: tail(parsed.text), at: Date.now() });
    }
  }

  function participants() {
    const names = new Set(seenSpeakers);
    for (const el of document.querySelectorAll('[data-participant-id] [jsname="EydYod"], [data-participant-id] .zWGUib, [data-participant-id] .XEazBc')) {
      const n = (el.textContent || "").trim();
      if (n && n.length <= 60) names.add(n);
    }
    const me = selfName();
    names.delete("You");
    if (me) names.delete(me);
    return Array.from(names).sort();
  }

  // MARK: Captions on while recording (and back off afterwards, if this extension turned them on).

  function ensureCaptions() {
    if (captionRegion() || captionAttempts >= 5) return;
    const button = captionsButton();
    captionAttempts += 1;
    if (button && !isOn(button)) {
      button.click();
      weEnabledCaptions = true;
    } else if (!button) {
      // Meet's own shortcut for captions.
      document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "c", code: "KeyC", keyCode: 67, bubbles: true }));
      weEnabledCaptions = true;
    }
  }

  function restoreCaptions() {
    if (!weEnabledCaptions) return;
    weEnabledCaptions = false;
    const button = captionsButton();
    if (button && isOn(button)) button.click();
  }

  function watchRegion() {
    const region = captionRegion();
    if (region === observedRegion) return;
    if (observer) observer.disconnect();
    observedRegion = region;
    lastSent = new WeakMap();
    if (!region) return;
    observer = new MutationObserver(() => {
      if (scanTimer) return;
      scanTimer = setTimeout(() => { scanTimer = null; if (active()) scanCaptions(); }, SCAN_MS);
    });
    observer.observe(region, { childList: true, subtree: true, characterData: true });
  }

  function tick() {
    if (!active() || !inCall()) return;
    ensureCaptions();
    watchRegion();
    const meeting = JSON.stringify({ code: location.pathname.replace(/^\//, "").split("?")[0], title: meetingTitle() });
    if (meeting !== lastMeeting) {
      lastMeeting = meeting;
      send({ type: "meeting", ...JSON.parse(meeting), inCall: true });
    }
    const list = participants();
    const key = list.join("\u0000");
    if (key !== lastParticipants) {
      lastParticipants = key;
      send({ type: "participants", names: list });
    }
  }

  connect();
  setInterval(tick, 2000);
})();
