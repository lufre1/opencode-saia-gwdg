#!/usr/bin/env node
//
// effort-selftest.mjs — check the /effort level mapping in saia-gwdg-plugin.js.
//
// Dev-only: NOT in build-setup.sh's MANIFEST, so it never ships to the installer.
// Run with: node scripts/effort-selftest.mjs
//
// The plugin can't be imported directly — opencode calls every exported function
// as a plugin hook, so the mapping helpers deliberately stay unexported. This
// pulls the two shipped literals out of the source and exercises them, which is
// what catches the failures that actually happen: a wrong chat-template key, or
// a missing/typo'd alias entry.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";

const src = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), "../plugin/saia-gwdg-plugin.js"),
  "utf-8"
);

const grab = (re, what) => {
  const m = src.match(re);
  assert.ok(m, `could not find ${what} in the plugin — was it renamed?`);
  return m[1];
};

const EFFORT_ALIAS = eval(
  "(" + grab(/const EFFORT_ALIAS = (\{[\s\S]*?\n\});/, "EFFORT_ALIAS") + ")"
);
const effortKwargsSrc = grab(
  /const effortKwargs = (\(level\) => \{[\s\S]*?\n  \});/,
  "effortKwargs"
);
const effortKwargs = eval("(" + effortKwargsSrc + ")");
const FORCE_REASONING = eval(
  "(new Set(" + grab(/const FORCE_REASONING = new Set\((\[[\s\S]*?\n\])\);/, "FORCE_REASONING") + "))"
);

// Mirrors withEffort's one-liner: alias lookup, then kwargs.
const effortFor = (modelId, level) =>
  effortKwargs(EFFORT_ALIAS[modelId]?.[level] ?? level);

// The bug that made /effort a no-op: `thinking` is ignored by the Qwen/vLLM
// chat template, only `enable_thinking` is read.
assert.deepEqual(effortFor("qwen3.5-122b-a10b", "off"), { enable_thinking: false });
assert.deepEqual(effortFor("qwen3.8-27b", "off"), { enable_thinking: false });
assert.ok(
  !/[^_]\bthinking\s*:/.test(effortKwargsSrc),
  "effortKwargs still emits a bare `thinking:` key"
);

// qwen3.8-27b 400s on high/max; both must become its own top rung.
assert.deepEqual(effortFor("qwen3.8-27b", "high"), {
  enable_thinking: true,
  reasoning_effort: "xhigh",
});
assert.deepEqual(effortFor("qwen3.8-27b", "max"), {
  enable_thinking: true,
  reasoning_effort: "xhigh",
});
// ...but its supported levels are untouched.
assert.deepEqual(effortFor("qwen3.8-27b", "medium"), {
  enable_thinking: true,
  reasoning_effort: "medium",
});

// Models with no alias entry pass every level through unchanged.
for (const level of ["low", "medium", "high", "max"]) {
  assert.deepEqual(effortFor("qwen3.5-122b-a10b", level), {
    enable_thinking: true,
    reasoning_effort: level,
  });
  assert.deepEqual(effortFor("some-future-model", level), {
    enable_thinking: true,
    reasoning_effort: level,
  });
}

// The three models SAIA under-reports as non-reasoning.
for (const id of ["qwen3.6-35b-a3b", "qwen3.8-27b", "openai-gpt-oss-120b"]) {
  assert.ok(FORCE_REASONING.has(id), `${id} missing from FORCE_REASONING`);
}

console.log("effort mapping: all checks passed");
