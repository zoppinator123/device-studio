#!/usr/bin/env node
// Runs the real ChromeExtension/content.js against a small fake of Google Meet's captions menu, so the
// caption on/off behaviour and name handling can be checked without Chrome or a call.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const source = fs.readFileSync(process.env.MEET_CONTENT_JS || path.join(__dirname, "..", "ChromeExtension", "content.js"), "utf8");

function element(attrs = {}, extra = {}) {
  return {
    attrs, textContent: "", innerText: "", click() {},
    getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; },
    querySelector: () => null, querySelectorAll: () => [],
    ...extra,
  };
}

// Meet as the extension sees it. A "Captions and translation" button opens a menu holding a switch labelled
// "Turn on captions" / "Turn off live captions". `autoClose` models the menu closing after the switch is used.
function makeMeet(opts = {}) {
  const meet = { captionsOn: !!opts.captionsOn, menuOpen: false, switchClicks: 0, shortcuts: 0 };
  const opener = element({ "aria-label": "Captions and translation" }, {
    click() { meet.menuOpen = !meet.menuOpen; },
  });
  const makeSwitch = () => meet.menuOpen
    ? element({ "aria-label": meet.captionsOn ? "Turn off live captions" : "Turn on captions" }, {
      click() { meet.switchClicks += 1; meet.captionsOn = !meet.captionsOn; if (opts.autoClose) meet.menuOpen = false; },
    })
    : null;

  const entries = (opts.captions || []).map(([speaker, text]) => element({}, {
    querySelector(sel) {
      if (sel.includes(".NWpY1d")) return { innerText: speaker, textContent: speaker };
      if (sel.includes(".ygicle")) return { innerText: text, textContent: text };
      return null;
    },
  }));
  const region = element({ "aria-label": "Captions" }, { querySelectorAll: () => entries });

  const document = {
    body: { dispatchEvent(event) { if (event.key === "c") { meet.shortcuts += 1; meet.captionsOn = !meet.captionsOn; } } },
    querySelector(sel) {
      if (sel.startsWith('button[aria-label*="Leave call"')) return element();
      if (sel === "[data-self-name]") return opts.selfName ? element({ "data-self-name": opts.selfName }) : null;
      if (sel.startsWith('div[role="region"]')) return meet.captionsOn ? region : null;
      if (sel.startsWith('button[aria-label^="Captions and translation"')) return opts.noOpener ? null : opener;
      return null;
    },
    querySelectorAll(sel) {
      if (sel === "[aria-label]") {
        const toggle = makeSwitch();
        return [...(opts.noOpener ? [] : [opener]), ...(toggle ? [toggle] : [])];
      }
      if (sel.includes("data-participant-id")) return (opts.tiles || []).map((name) => element({}, { textContent: name }));
      return [];
    },
  };
  return { meet, document };
}

// Loads content.js into a sandbox with a fake page, a fake extension port and a manual clock.
function load(opts) {
  const { meet, document } = makeMeet(opts);
  const port = {
    sent: [], listeners: [],
    onMessage: { addListener(f) { port.listeners.push(f); } },
    onDisconnect: { addListener() {} },
    postMessage(m) { port.sent.push(m); },
  };
  const timers = [];
  let clock = 0, interval = null, observerCallback = null;
  const sandbox = {
    document,
    location: { pathname: "/abc-defg-hij" },
    chrome: { runtime: { connect: () => port } },
    setInterval(fn) { interval = fn; return 1; },
    setTimeout(fn, ms) { timers.push({ at: clock + ms, fn }); return timers.length; },
    clearTimeout() {},
    MutationObserver: class { constructor(cb) { observerCallback = cb; } observe() {} disconnect() {} },
    KeyboardEvent: class { constructor(type, init) { Object.assign(this, { type }, init); } },
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const page = {
    meet, port,
    state(recording) { port.listeners.forEach((f) => f({ type: "state", running: true, recording, speakers: true })); },
    // Advance the clock; the extension's own 2-second tick fires along the way.
    run(ms) {
      for (let t = 0; t < ms; t += 100) {
        clock += 100;
        if (clock % 2000 === 0 && interval) interval();
        timers.filter((x) => x.at <= clock).forEach((x) => { timers.splice(timers.indexOf(x), 1); x.fn(); });
      }
    },
    mutate() { observerCallback && observerCallback(); },
    last(type) { return port.sent.filter((m) => m.type === type).pop(); },
  };
  return page;
}

let failures = 0;
function check(name, fn) {
  try { fn(); console.log("PASS: " + name); } catch (error) { failures += 1; console.log("FAIL: " + name + "\n  " + error.message); }
}

for (const autoClose of [false, true]) {
  const shape = autoClose ? "menu closes itself" : "menu stays open";

  check(`captions go on once when recording starts, and the menu is left closed (${shape})`, () => {
    const page = load({ autoClose });
    page.state(true);
    page.run(8000);
    assert.strictEqual(page.meet.captionsOn, true, "captions should be on");
    assert.strictEqual(page.meet.switchClicks, 1, "the switch should be pressed exactly once");
    assert.strictEqual(page.meet.menuOpen, false, "the menu should be closed");
  });

  check(`captions go back off when recording stops, and the menu is left closed (${shape})`, () => {
    const page = load({ autoClose });
    page.state(true);
    page.run(8000);
    page.state(false);
    page.run(4000);
    assert.strictEqual(page.meet.captionsOn, false, "captions should be off");
    assert.strictEqual(page.meet.switchClicks, 2, "one press to turn on, one to turn off");
    assert.strictEqual(page.meet.menuOpen, false, "the menu should be closed");
  });

  check(`captions the user already had on are left on (${shape})`, () => {
    const page = load({ autoClose, captionsOn: true });
    page.state(true);
    page.run(8000);
    page.state(false);
    page.run(4000);
    assert.strictEqual(page.meet.captionsOn, true, "captions should still be on");
    assert.strictEqual(page.meet.switchClicks, 0, "the switch should never be pressed");
    assert.strictEqual(page.meet.menuOpen, false, "the menu should be closed");
  });
}

check("a second recording in the same call turns captions on and off again", () => {
  const page = load({});
  for (let i = 0; i < 2; i += 1) {
    page.state(true);
    page.run(8000);
    assert.strictEqual(page.meet.captionsOn, true, "on during recording " + (i + 1));
    page.state(false);
    page.run(4000);
    assert.strictEqual(page.meet.captionsOn, false, "off after recording " + (i + 1));
  }
});

check("nothing is touched when Device Studio is not recording", () => {
  const page = load({});
  page.state(false);
  page.run(10000);
  assert.strictEqual(page.meet.switchClicks, 0);
  assert.strictEqual(page.meet.menuOpen, false);
  assert.strictEqual(page.meet.captionsOn, false);
});

check("with no captions control on the page, Meet's keyboard shortcut is used both ways", () => {
  const page = load({ noOpener: true });
  page.state(true);
  page.run(8000);
  assert.strictEqual(page.meet.captionsOn, true);
  page.state(false);
  page.run(4000);
  assert.strictEqual(page.meet.captionsOn, false);
  assert.strictEqual(page.meet.shortcuts, 2);
});

check("a name read twice by a tile is listed once, and the user is left out", () => {
  const page = load({ selfName: "Jack Zoppa", tiles: ["Jack ZoppaJack Zoppa", "Priya RamanPriya Raman", "Sam Lee"] });
  page.state(true);
  page.run(4000);
  assert.deepStrictEqual(Array.from(page.last("participants").names), ["Priya Raman", "Sam Lee"]);
});

check("other people's captions are sent with their name; the user's own are not", () => {
  const page = load({ captionsOn: true, selfName: "Jack Zoppa", captions: [["Priya Raman", "We ship on Friday"], ["You", "Sounds good"]] });
  page.state(true);
  page.run(4000);
  page.mutate();
  page.run(500);
  const sent = page.port.sent.filter((m) => m.type === "caption");
  assert.strictEqual(sent.length, 1);
  assert.strictEqual(sent[0].speaker, "Priya Raman");
  assert.strictEqual(sent[0].text, "We ship on Friday");
});

if (failures) { console.log(`${failures} Meet extension check(s) failed.`); process.exit(1); }
console.log("All Meet extension checks passed.");
