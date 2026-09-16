#!/usr/bin/env node
//
// keys-selftest.mjs — check that the pacer fails a rejected (401/403) key over.
//
// Dev-only: NOT in build-setup.sh's MANIFEST, so it never ships to the installer.
// Run with: node scripts/keys-selftest.mjs   (~3s: the pacer spaces requests 2.1s apart)
//
// Regression guard for the 2026-09-16 outage: the auth.json key was revoked,
// every request 401'd on it, and the two healthy keys in rotation were never
// tried — opencode just said "Unauthorized".

import { readFileSync, mkdtempSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import assert from "node:assert/strict";

// Module-level paths are computed from homedir() at import time — redirect them
// so the test writes its log/budget files into a temp dir, not the real cache.
process.env.HOME = mkdtempSync(join(tmpdir(), "saia-selftest-"));

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../plugin/saia-gwdg-plugin.js"), "utf-8")
  .replace(/from "(fs|os|path|url)"/g, 'from "node:$1"') // data: modules need the node: prefix
  .replace(/^export\s+/gm, "");
const { installPacer } = await import(
  `data:text/javascript,${encodeURIComponent(`${src}\nexport { installPacer };`)}`
);

const DEAD = "dead-key", GOOD = "good-key";
const seen = [];
globalThis.fetch = async (_input, init) => {
  const key = new Headers(init.headers).get("authorization");
  seen.push(key);
  return new Response("{}", { status: key === `Bearer ${DEAD}` ? 401 : 200 });
};

installPacer([DEAD, GOOD]);

const resp = await globalThis.fetch("https://chat-ai.academiccloud.de/v1/models", { headers: {} });
assert.equal(resp.status, 200, "a 401 on key #1 must fail over to the next key, not surface as Unauthorized");
assert.deepEqual(seen, [`Bearer ${DEAD}`, `Bearer ${GOOD}`], "expected exactly one retry, on the next key");

// The dead key stays out of rotation: the second request must skip it entirely.
seen.length = 0;
assert.equal((await globalThis.fetch("https://chat-ai.academiccloud.de/v1/models", { headers: {} })).status, 200);
assert.deepEqual(seen, [`Bearer ${GOOD}`], "a rejected key must not be retried on the next request");

// Every key dead => a clear error naming the real cause, not "nearly exhausted".
globalThis.__saiaKeys = [DEAD];
await assert.rejects(
  globalThis.fetch("https://chat-ai.academiccloud.de/v1/models", { headers: {} }),
  /revoked or expired/,
  "with no usable key left the error must say the key was rejected, not rate-limited"
);

console.log("keys-selftest: ok");
