chrome.runtime.sendMessage({ type: "status" }, (s) => {
  const set = (id, text, cls) => {
    document.getElementById(id).textContent = text;
    document.getElementById(id + "Dot").className = "dot " + (cls || "");
  };
  if (!s) { set("app", "Not available", "warn"); return; }
  if (s.running) set("app", "Device Studio connected", "good");
  else if (/not found|forbidden/i.test(s.error || "")) set("app", "Open Device Studio › Meetings › Set Up Chrome", "warn");
  else set("app", s.meetTabs ? "Device Studio is not running" : "Waiting for a Meet tab", "warn");
  set("rec", s.recording ? "Recording" : "Not recording", s.recording ? "rec" : "");
  set("meet", s.meetTabs ? `${s.meetTabs} Meet tab${s.meetTabs === 1 ? "" : "s"} open` : "No Meet tab open", s.meetTabs ? "good" : "");
});
