"use strict";

// Shared with Node tests. An uncertain network result keeps its exact ID and payload.
class SendState {
  constructor() { this.pending = null; }
  begin(text, ticket, makeID) {
    if (!this.pending) this.pending = { id: makeID(), text, ticket };
    return this.pending;
  }
  finish() { this.pending = null; }
}
function makeID(cryptoObject) {
  const bytes = new Uint8Array(16);
  // getRandomValues works on HTTP; randomUUID/subtle require secure contexts.
  cryptoObject.getRandomValues(bytes);
  return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("");
}
if (typeof module !== "undefined") module.exports = { SendState, makeID };

if (typeof document !== "undefined") {
  const el = id => document.getElementById(id);
  const state = new SendState();
  let paired = false, ticket = null, busy = false, pairingTimer = null;
  let token = "", clientID = "";
  const say = (id, message) => { el(id).textContent = message; };
  function controls() {
    el("arm").disabled = !paired || busy || !!state.pending;
    el("send").disabled = busy || (!state.pending && (!paired || !ticket || !el("draft").value.trim()));
    el("connect").disabled = busy || !!state.pending;
    el("draft").readOnly = busy || !!state.pending;
    el("send").textContent = state.pending ? "Retry the same send" : "Send to Mac";
    el("discard").hidden = !state.pending || busy;
  }
  async function api(path, body) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(path, {
        method: body === undefined ? "GET" : "POST",
        headers: { "Authorization": `Bearer ${token}`, "X-Client-ID": clientID,
                   ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: "no-store", credentials: "omit", redirect: "error", signal: controller.signal
      });
      const result = await response.json();
      if (!response.ok) {
        const error = new Error(result.error || "Receiver rejected the request.");
        error.definite = true; error.status = response.status;
        throw error;
      }
      return result;
    } finally { clearTimeout(timeout); }
  }
  async function waitForApproval(remaining) {
    if (!remaining || document.hidden) return;
    try {
      const result = await api("/api/status");
      if (result.paired) {
        paired = true;
        say("connection", "Connected. Your Mac has approved this browser.");
        el("arm").textContent = result.mode === "clipboard" ? "Use Mac clipboard" : "Use current Mac text field";
        controls(); return;
      }
      pairingTimer = setTimeout(() => waitForApproval(remaining - 1), 2000);
    } catch (_) { say("connection", "Connection paused. Check the Mac receiver, then tap Connect."); }
  }
  async function connect() {
    if (!token || busy || state.pending) return;
    clearTimeout(pairingTimer); busy = true; controls();
    try {
      const result = await api("/api/connect", {});
      paired = !!result.paired;
      say("connection", paired ? "Connected to your Mac." : "Approve this browser in the PhoneBridge window on your Mac.");
      waitForApproval(30);
    } catch (error) {
      paired = false;
      say("connection", error.definite ? error.message : "Cannot reach the Mac. Keep both devices on the same home Wi-Fi and check that the receiver is running.");
    } finally { busy = false; controls(); }
  }
  el("connect").addEventListener("click", connect);
  el("draft").addEventListener("input", controls);
  el("arm").addEventListener("click", async () => {
    if (busy || state.pending) return;
    busy = true; ticket = null; controls();
    try {
      const result = await api("/api/arm", {});
      ticket = result.ticket;
      say("target", `${result.target} selected for one send within two minutes. ${result.mode === "clipboard" ? "Copy-only: you will press Command–V on the Mac." : "Keep that same text field selected."}`);
    } catch (error) {
      say("target", error.definite ? error.message : "Could not select a destination. Check the Mac and try again.");
    } finally { busy = false; controls(); }
  });
  el("send").addEventListener("click", async () => {
    if (busy || (!state.pending && (!ticket || !el("draft").value.trim()))) return;
    const payload = state.begin(el("draft").value, ticket, () => makeID(window.crypto));
    busy = true; controls(); say("result", "Sending finished text…");
    try {
      const result = await api("/api/send", payload);
      if (result.id !== payload.id || !["clipboard", "paste_requested"].includes(result.result)) {
        throw new Error("Unrecognised receipt.");
      }
      say("result", result.message);
      // Do not erase a last dictation correction that arrived during the network request.
      if (el("draft").value === payload.text) el("draft").value = "";
      state.finish(); ticket = null;
      say("target", "Choose the destination again for the next send.");
    } catch (error) {
      // Even a 401 after a retry may mean the old session already pasted before restarting.
      // Retain the original ID for uncertain delivery; never auto-send or silently mint a new ID.
      say("result", error.definite
        ? `${error.message} Check your Mac before making a new send. Your draft is kept.`
        : "No receipt received. Your Mac may already have received the text. Retry uses the same ID to avoid a second paste. Your draft is kept.");
    } finally { busy = false; controls(); }
  });
  el("discard").addEventListener("click", () => {
    if (busy) return;
    if (!window.confirm("Check your Mac first: this text may already have arrived. Keep the draft and stop retrying this send?")) return;
    state.finish(); ticket = null;
    say("result", "Draft kept. Choose a destination only after checking what already reached the Mac.");
    controls();
  });
  document.addEventListener("visibilitychange", () => { if (document.hidden) clearTimeout(pairingTimer); });
  try {
    const fromQR = location.hash.slice(1);
    if (/^[a-f0-9]{64}$/.test(fromQR)) {
      sessionStorage.setItem("phonebridge-token", fromQR);
      history.replaceState(null, "", location.pathname);
    }
    token = sessionStorage.getItem("phonebridge-token") || "";
    clientID = sessionStorage.getItem("phonebridge-client") || makeID(window.crypto);
    sessionStorage.setItem("phonebridge-client", clientID);
    if (!/^[a-f0-9]{64}$/.test(token)) {
      say("connection", "Scan the QR code in the Mac app. Opening its address without the QR token will not pair.");
    } else { connect(); }
  } catch (_) {
    say("connection", "Safari could not store this session. Open the QR link in a normal Safari tab and try again.");
  }
  controls();
}
