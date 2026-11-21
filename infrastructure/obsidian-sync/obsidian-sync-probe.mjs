#!/usr/bin/env node
// obsidian-sync-probe.mjs — readiness probe for the headless Obsidian Sync client.
//
// Process liveness is NOT sync health: after the 2026-07-13 systemd-oomd kill the
// app auto-restarted into a zombie state (DevTools port never bound, sync never
// reconnected) while every process-level check stayed green for ~8 hours. This
// probe asks the running app itself via the Chrome DevTools Protocol on :9222.
//
// Output: one JSON line {healthy, reason, status}.
// Exit codes: 0 = sync ready, 1 = app answered but sync unhealthy,
//             2 = CDP unreachable/wedged (the zombie signature).
const port = process.env.OBSIDIAN_DEBUG_PORT || "9222";

const finish = (healthy, reason, status = null, code = null) => {
  console.log(JSON.stringify({ healthy, reason, status }));
  process.exit(code ?? (healthy ? 0 : 1));
};

setTimeout(() => finish(false, "probe timeout", null, 2), 8000);

let targets;
try {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`, {
    signal: AbortSignal.timeout(3000),
  });
  targets = await res.json();
} catch (e) {
  finish(false, `cdp unreachable on ${port}: ${e.cause?.code || e.name}`, null, 2);
}
if (!Array.isArray(targets)) finish(false, "cdp target list malformed", null, 2);

const page = targets.find((t) => t.type === "page" && !/devtools/i.test(t.url || ""));
if (!page) finish(false, "no app window target", null, 2);

const expr = `(() => {
  const p = app.internalPlugins && app.internalPlugins.plugins && app.internalPlugins.plugins.sync;
  const i = p && p.instance;
  if (!i) return JSON.stringify({ missing: true });
  return JSON.stringify({
    enabled: !!p.enabled,
    initialized: !!i.initialized,
    dataLoaded: !!i.dataLoaded,
    ready: !!i.ready,
    pause: !!i.pause,
    error: !!i.error,
    syncStatus: String(i.syncStatus || "")
  });
})()`;

const ws = new WebSocket(page.webSocketDebuggerUrl);
ws.onerror = () => finish(false, "cdp websocket error", null, 2);
ws.onopen = () =>
  ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: expr, returnByValue: true } }));
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id !== 1) return;
  let s;
  try {
    s = JSON.parse(d.result.result.value);
  } catch {
    finish(false, "bad evaluate result", null, 2);
  }
  ws.close();
  if (s.missing) finish(false, "sync plugin instance missing");
  if (!s.enabled) finish(false, "sync plugin disabled", s.syncStatus);
  if (s.pause) finish(false, "sync paused", s.syncStatus);
  if (s.error) finish(false, "sync error flag set", s.syncStatus);
  if (!s.initialized || !s.dataLoaded || !s.ready)
    finish(false, `sync not ready (status: ${s.syncStatus})`, s.syncStatus);
  finish(true, "ok", s.syncStatus);
};
