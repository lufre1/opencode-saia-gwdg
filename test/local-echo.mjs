// Focused test for the /effort local-echo short-circuit in
// plugin/saia-gwdg-plugin.js.
//
// The 2026-11-01 halt: a read of setup-saia-opencode.sh (which embeds
// command/effort.md, sentinel line included) put the sentinel into a TOOL
// RESULT. tryLocalEcho matched on `includes` alone, swallowed the next model
// turn, and returned the 57KB file dump as the "answer" (zero SAIA requests,
// step-finish reason=stop). The echo must fire ONLY for an expanded slash
// command: a USER message whose FIRST line is the sentinel.
//
// Cases (one process; the pacer is installed at module load, and
// every request is pointed at test/fake-saia.py — zero real SAIA requests):
//   echo         last msg = user, first line is the sentinel   -> local echo, no upstream
//   tool-result  last msg = tool result containing the sentinel -> passes through
//   assistant    last msg = assistant quoting the sentinel      -> passes through
//   user-midtext last msg = user, sentinel NOT on the first line -> passes through
//
// Usage: node test/local-echo.mjs
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, openSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { spawn } from "child_process";

const PORT = 8791;
const work = mkdtempSync(join(tmpdir(), "saia-echo-"));
const LOG = join(work, "pacer.log");
const BUDGET = join(work, "budget.json");
const SRVLOG = join(work, "server.log");
writeFileSync(LOG, "");
writeFileSync(BUDGET, "{}");
// Private HOME: the real key lives in opencode's credential store, which only
// setup()'s ctx can reach, so the v1 config hook driven here gets a fake key
// through the failover-keys file, plus a models cache (no /models fetch).
const home = join(work, "home");
mkdirSync(join(home, ".local/share/opencode"), { recursive: true });
mkdirSync(join(home, ".cache/opencode"), { recursive: true });
writeFileSync(join(home, ".local/share/opencode/saia-gwdg-keys.json"), JSON.stringify({ keys: ["test-key"] }));
writeFileSync(
  join(home, ".cache/opencode/saia-gwdg-models.json"),
  JSON.stringify({ fetchedAt: Date.now(), models: [{ id: "qwen3.8-27b", name: "Qwen 3.8 27B", status: "ready", input: ["text"], output: ["text"] }] })
);
process.env.HOME = home;
process.env.USERPROFILE = home;
process.env.SAIA_TEST_HOST = "127.0.0.1";
process.env.SAIA_BASE_URL = `http://127.0.0.1:${PORT}/v1`;
process.env.SAIA_PACER_LOG = LOG;
process.env.SAIA_BUDGET_PATH = BUDGET;

const srvLogFd = openSync(SRVLOG, "w");
// Windows has no python3 alias; python is the interpreter there.
const PY = process.platform === "win32" ? "python" : "python3";
const srv = spawn(
  PY,
  [join(import.meta.dirname, "fake-saia.py")],
  {
    env: { ...process.env, FAKE_SAIA_MODE: "ok", FAKE_SAIA_PORT: String(PORT) },
    stdio: ["ignore", "ignore", srvLogFd],
  }
);

// Give the server a moment to listen.
await new Promise((r) => setTimeout(r, 700));

const { server } = await import("../plugin/saia-gwdg-plugin.js");
const hooks = await server({
  client: {
    session: { get: async () => ({ data: { id: "ses_test", parentID: undefined } }) },
    tui: { showToast: async () => {} },
  },
  directory: "/tmp",
});
await hooks.config({});

const SENTINEL = "(local command — handled without a model call)";
const URL = `http://127.0.0.1:${PORT}/v1/chat/completions`;

const upstreamCount = () =>
  readFileSync(SRVLOG, "utf-8").split("\n").filter((l) => l.includes("mode=ok")).length;
const pacerLines = () => readFileSync(LOG, "utf-8").split("\n").filter(Boolean);

let pass = 0;
let fail = 0;
const check = (name, cond, detail = "") => {
  if (cond) {
    pass++;
    console.log(`  ok: ${name}`);
  } else {
    fail++;
    console.log(`  FAIL: ${name} ${detail}`);
  }
};

const post = (messages) =>
  fetch(URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "saia-gwdg/qwen3.8-27b", stream: true, messages }),
  });

console.log("case: echo (real /effort expansion)");
{
  const before = upstreamCount();
  const resp = await post([{ role: "user", content: `${SENTINEL}\n\ncurrent effort: high` }]);
  const text = await resp.text();
  check("status 200", resp.status === 200, `got ${resp.status}`);
  check("local-echo id", text.includes("chatcmpl-local-echo"), text.slice(0, 160));
  check("no upstream request", upstreamCount() === before, `${before} -> ${upstreamCount()}`);
  check("pacer logged local echo", pacerLines().some((l) => l.includes("local echo for /effort")));
}

console.log("case: tool-result (the 2026-11-01 halt)");
{
  const before = upstreamCount();
  const fileDump =
    `<path>/home/pi/opencode-extras/setup-saia-opencode.sh</path>\n` +
    `<type>file</type>\n<content>\n1: #!/usr/bin/env bash\n` +
    `42: ${SENTINEL}\n43: more installer content\n</content>`;
  const resp = await post([
    { role: "user", content: "read the installer file" },
    {
      role: "assistant",
      content: "",
      tool_calls: [{ id: "c1", type: "function", function: { name: "read", arguments: "{}" } }],
    },
    { role: "tool", tool_call_id: "c1", content: fileDump },
  ]);
  const text = await resp.text();
  check("reached upstream", upstreamCount() === before + 1, `${before} -> ${upstreamCount()}`);
  check("fake-server response", text.includes("chatcmpl-fake"), text.slice(0, 160));
  check("not a local echo", !text.includes("chatcmpl-local-echo"));
  check("pacer logged a real req", pacerLines().some((l) => l.includes("req /v1/chat/completions")));
}

console.log("case: assistant quoting the sentinel");
{
  const before = upstreamCount();
  const resp = await post([
    { role: "user", content: "what is the local-echo sentinel?" },
    { role: "assistant", content: `It is ${SENTINEL} — defined in the plugin.` },
  ]);
  const text = await resp.text();
  check("reached upstream", upstreamCount() === before + 1, `${before} -> ${upstreamCount()}`);
  check("fake-server response", text.includes("chatcmpl-fake"), text.slice(0, 160));
}

console.log("case: user message with sentinel mid-text");
{
  const before = upstreamCount();
  const resp = await post([
    { role: "user", content: `Here is the file I read:\n${SENTINEL}\nrest of the content` },
  ]);
  const text = await resp.text();
  check("reached upstream", upstreamCount() === before + 1, `${before} -> ${upstreamCount()}`);
  check("fake-server response", text.includes("chatcmpl-fake"), text.slice(0, 160));
}

srv.kill();
console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
