#!/usr/bin/env node
// obsidian-sync-audit.mjs — per-file sync-divergence detector for the headless
// Obsidian Sync client.
//
// Why this exists (2026-07-29 incident): specific files under
// 00_Inbox/mindrift-platform-handoffs/ silently stopped uploading for 20+ min
// while other files synced fine and syncStatus stayed "Fully synced". The
// readiness probe (obsidian-sync-probe.mjs) checks the sync plugin's state
// flags (ready/pause/error/syncStatus) — all of which stay green in this
// failure mode. Neither a status check nor a canary write can catch a PARTIAL
// wedge; only per-file reconciliation can.
//
// Core invariant: the vault filesystem (ground truth) must agree with the sync
// plugin's server-side mirror (instance.serverFiles — what the cloud actually
// holds). instance.localFiles is used only as a cheap content-hash shortcut:
// when its mtime matches the fs mtime, its hash IS the file's SHA-256
// (verified 2026-07-29), so no re-hashing is needed. Comparing against
// synchash alone is wrong: a benign ledger gap (content on server, synctime=0
// bookkeeping never written) was found live on 2026-07-29 that had sat for 20
// days — content everywhere, only the bookkeeping missing. fs-vs-server has no
// such false positive.
//
// Divergence classes (each only after AUDIT_GRACE_SECONDS of persistence):
//   upload-pending           ledger saw the change; server lacks the content
//   unnoticed-modify/create  watcher missed it; server lacks the content
//   remote-delete-unapplied  server tombstone, file still on fs
//   missing-local            server holds a live file absent from fs
//                            (missed deletion upload OR wedged download —
//                             the receive path the git bridge depends on)
//
// False-positive guards:
//   - grace window: anything newer than AUDIT_GRACE_SECONDS is sync's
//     business, not ours yet. The healthcheck's 2-strike rule adds a second
//     temporal confirmation 2 minutes later.
//   - mtime-only drift with identical content is invisible by design (git
//     pull/rebase rewrites files whose content the cloud already has).
//   - flagged paths are filtered through the plugin's own canSyncPath().
//   - dot-paths and ignoreFolders are excluded from walk and sweeps; files
//     in sync's own skippedFiles set are excluded; files >200MB are excluded.
//   - plugin paused/error/not-ready/initial-sync → skip: that's the readiness
//     probe's territory; exit 0 so a broken monitor can't harm a healthy app.
//
// Modes:  (default) read-only audit.
//         --rescan  additionally ask the app to scanFiles() + requestSync()
//                   when divergence is found — the same "Detecting changes"
//                   pass a service restart triggers, without the restart.
//
// Output: one JSON line. Exit codes match probe conventions:
//   0 = healthy (or deliberately skipped), 1 = divergence found,
//   2 = tooling/CDP problem (no verdict — caller should NOT strike on this).
//
// Env knobs: AUDIT_GRACE_SECONDS (default 300), OBSIDIAN_DEBUG_PORT (9222),
//            OBSIDIAN_VAULT_PATH (/home/tyler/obsidian-vault).

import { createHash } from "node:crypto";
import { createReadStream, promises as fsp } from "node:fs";
import path from "node:path";

const VAULT = process.env.OBSIDIAN_VAULT_PATH || "/home/tyler/obsidian-vault";
const PORT = process.env.OBSIDIAN_DEBUG_PORT || "9222";
const GRACE_MS = parseInt(process.env.AUDIT_GRACE_SECONDS || "300", 10) * 1000;
const MTIME_TOLERANCE_MS = 2000;
const MAX_AUDIT_BYTES = 200 * 1024 * 1024; // beyond Sync's own per-file ceiling
const RESCAN = process.argv.includes("--rescan");
const STALE_SAMPLE = 5;

const out = (obj, code) => {
  console.log(JSON.stringify(obj));
  process.exit(code);
};

// Hard watchdog: the healthcheck must never hang on its monitor.
setTimeout(() => out({ healthy: false, reason: "audit watchdog timeout" }, 2), RESCAN ? 90000 : 30000);

async function openCdp() {
  const res = await fetch(`http://127.0.0.1:${PORT}/json/list`, { signal: AbortSignal.timeout(3000) });
  const targets = await res.json();
  const page = targets.find((t) => t.type === "page" && !/devtools/i.test(t.url || ""));
  if (!page) throw new Error("no app window target");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error("cdp websocket error"));
  });
  let seq = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (pending.has(d.id)) {
      pending.get(d.id)(d);
      pending.delete(d.id);
    }
  };
  return {
    evaluate: (expression, awaitPromise = false) =>
      new Promise((resolve, reject) => {
        const id = ++seq;
        pending.set(id, (d) => {
          const v = d?.result?.result?.value;
          if (v === undefined) reject(new Error("evaluate returned no value"));
          else resolve(v);
        });
        ws.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression, returnByValue: true, awaitPromise } }));
        setTimeout(() => {
          if (pending.has(id)) {
            pending.delete(id);
            reject(new Error("evaluate timeout"));
          }
        }, RESCAN ? 60000 : 15000);
      }),
    close: () => { try { ws.close(); } catch { /* already closed */ } },
  };
}

const SNAPSHOT_EXPR = `(() => {
  const p = app.internalPlugins && app.internalPlugins.plugins && app.internalPlugins.plugins.sync;
  const i = p && p.instance;
  if (!i) return JSON.stringify({ missing: true });
  const local = {};
  for (const k of Object.keys(i.localFiles || {})) {
    const e = i.localFiles[k];
    if (!e || e.folder) continue;
    local[k] = [e.mtime || 0, e.hash || ""];
  }
  const server = {};
  for (const k of Object.keys(i.serverFiles || {})) {
    const e = i.serverFiles[k];
    if (!e || e.folder) continue;
    server[k] = [e.mtime || 0, e.hash || "", e.deleted ? 1 : 0];
  }
  return JSON.stringify({
    enabled: !!p.enabled, pause: !!i.pause, error: !!i.error, ready: !!i.ready,
    initialized: !!i.initialized, dataLoaded: !!i.dataLoaded, initial: !!i.initial,
    syncing: !!i.syncing, syncStatus: String(i.syncStatus || ""),
    ignoreFolders: (i.filter && i.filter.ignoreFolders) || i.ignoreFolders || [],  // excluded folders live on i.filter (fixed 2026-11-21)
    retry: Object.keys(i.fileRetry || {}),
    skipped: Object.keys(i.skippedFiles || {}),
    local, server
  });
})()`;

function sha256(fp) {
  return new Promise((resolve, reject) => {
    const h = createHash("sha256");
    const s = createReadStream(fp);
    s.on("data", (d) => h.update(d));
    s.on("end", () => resolve(h.digest("hex")));
    s.on("error", reject);
  });
}

async function walkVault(ignoreSet) {
  const acc = new Map();
  async function walk(dir, rel) {
    let entries;
    try {
      entries = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
      return; // folder vanished mid-walk (active vault) — next tick catches up
    }
    for (const ent of entries) {
      if (ent.name.startsWith(".")) continue;
      const rp = rel ? `${rel}/${ent.name}` : ent.name;
      if (ignoreSet.has(rp)) continue;
      if (ent.isSymbolicLink()) continue;
      const ap = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        await walk(ap, rp);
      } else if (ent.isFile()) {
        try {
          const st = await fsp.stat(ap);
          acc.set(rp, { mtime: st.mtimeMs, size: st.size });
        } catch { /* vanished mid-walk */ }
      }
    }
  }
  await walk(VAULT, "");
  return acc;
}

const isDotPath = (rp) => rp.startsWith(".") || rp.includes("/.");
const underIgnored = (rp, ignoreFolders) =>
  ignoreFolders.some((f) => rp === f || rp.startsWith(`${f}/`));

try {
  const cdp = await openCdp();
  let snap;
  try {
    snap = JSON.parse(await cdp.evaluate(SNAPSHOT_EXPR));
  } catch (e) {
    cdp.close();
    out({ healthy: false, reason: `snapshot failed: ${e.message}` }, 2);
  }
  if (snap.missing) { cdp.close(); out({ healthy: true, reason: "skipped: sync plugin instance missing (probe territory)" }, 0); }
  if (!snap.enabled || snap.pause || snap.error || !snap.ready || !snap.initialized || !snap.dataLoaded) {
    cdp.close();
    out({ healthy: true, reason: "skipped: sync not in steady state (probe territory)", syncStatus: snap.syncStatus }, 0);
  }
  if (snap.initial) { cdp.close(); out({ healthy: true, reason: "skipped: initial sync in progress" }, 0); }

  const fsFiles = await walkVault(new Set(snap.ignoreFolders));
  const skippedSet = new Set(snap.skipped);
  const now = Date.now();
  const stale = [];
  let hashed = 0;
  let oversize = 0;

  // Direction 1: filesystem → server mirror. Every syncable file on disk that
  // has settled (past grace) must have live, content-identical server state.
  for (const [rp, f] of fsFiles) {
    if (skippedSet.has(rp)) continue;
    if (f.size > MAX_AUDIT_BYTES) { oversize++; continue; }
    if (now - f.mtime < GRACE_MS) continue;
    const rec = snap.local[rp];
    const ledgerSawIt = rec && Math.abs(f.mtime - rec[0]) <= MTIME_TOLERANCE_MS;
    let fsHash;
    if (ledgerSawIt) {
      fsHash = rec[1];
    } else {
      try {
        hashed++;
        fsHash = await sha256(path.join(VAULT, rp));
      } catch {
        continue; // unreadable/vanished — next tick decides
      }
    }
    const srv = snap.server[rp];
    const age = Math.round((now - f.mtime) / 1000);
    if (srv && srv[2]) {
      stale.push({ path: rp, kind: "remote-delete-unapplied", ageSeconds: age });
    } else if (!srv || srv[1] !== fsHash) {
      const kind = ledgerSawIt ? "upload-pending" : rec ? "unnoticed-modify" : "unnoticed-create";
      stale.push({ path: rp, kind, ageSeconds: age });
    }
  }

  // Direction 2: server mirror → filesystem. A live server file absent from
  // disk is either a deletion whose upload was missed or a download that never
  // happened — the receive path the git bridge depends on.
  for (const [rp, srv] of Object.entries(snap.server)) {
    if (srv[2]) continue; // tombstone: nothing to have locally
    if (fsFiles.has(rp) || skippedSet.has(rp)) continue;
    if (isDotPath(rp) || underIgnored(rp, snap.ignoreFolders)) continue;
    if (now - srv[0] > GRACE_MS) {
      stale.push({ path: rp, kind: "missing-local", ageSeconds: Math.round((now - srv[0]) / 1000) });
    }
  }

  // Let the plugin itself veto paths it legitimately won't sync.
  let confirmed = stale;
  if (stale.length > 0) {
    try {
      const paths = JSON.stringify(stale.map((s) => s.path));
      const verdicts = JSON.parse(await cdp.evaluate(
        `JSON.stringify(${paths}.map(p => app.internalPlugins.plugins.sync.instance.canSyncPath(p)))`
      ));
      confirmed = stale.filter((_, idx) => verdicts[idx]);
    } catch { /* filter is a nicety; keep the unfiltered verdict */ }
  }

  let rescanRequested = false;
  if (confirmed.length > 0 && RESCAN) {
    try {
      await cdp.evaluate(
        `(async () => { const i = app.internalPlugins.plugins.sync.instance;
           try { await i.scanFiles(); } catch (e) {}
           try { i.requestSync(); } catch (e) {}
           return "ok"; })()`,
        true
      );
      rescanRequested = true;
    } catch { /* verdict still stands; healthcheck escalates */ }
  }
  cdp.close();

  const base = {
    checked: fsFiles.size,
    serverEntries: Object.keys(snap.server).length,
    hashed,
    oversize,
    retry: snap.retry.slice(0, 3),
    syncStatus: snap.syncStatus,
  };
  if (confirmed.length === 0) {
    out({ healthy: true, reason: "ok", ...base }, 0);
  }
  const first = confirmed[0];
  out({
    healthy: false,
    reason: `${confirmed.length} file(s) diverged from sync server state (e.g. ${first.kind}: ${first.path.slice(0, 80)}, ${first.ageSeconds}s)`,
    staleCount: confirmed.length,
    stale: confirmed.slice(0, STALE_SAMPLE),
    rescanRequested,
    ...base,
  }, 1);
} catch (e) {
  out({ healthy: false, reason: `audit error: ${e.message}` }, 2);
}
