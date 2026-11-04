// Focused test for the opencode v2 front-end of plugin/saia-gwdg-plugin.js:
// `export default { id, setup(ctx) }`, driven with a fake v2 ctx.
//
// opencode >= 2 loads a plugin only from that default export and never calls
// the v1 hooks, so this is the path a real install takes. Covered:
//   - the default export has the shape v2's loader validates
//   - setup installs the pacer and registers the ready SAIA models
//   - wire templating: __SAIA_BUDGET_STATUS__ and the coder2 -> coder prompt
//     swap land in SYSTEM messages only; an unready model is remapped
//   - the "subagent" tool hook is registered and passes on an unknown budget
//   - v2 events drive auto-resume: execution.failed schedules a resume that
//     fires session.prompt; execution.interrupted is never resumed
//   - the cleanup function returned by setup runs
//
//   - the key comes from opencode's credential store (ctx.integration), is
//     not injected into the provider, and a key switched later reaches the wire
//
// Fully isolated: HOME points at a temp dir holding a fake models cache, the
// stored key is a fake ctx.integration, so the real ~/.cache/opencode files
// are never read or written, and every request goes to test/fake-saia.py.
// Zero real SAIA requests.
//
// Usage: node test/v2-setup.mjs
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, openSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { spawn } from "child_process";

const PORT = 8792;
const work = mkdtempSync(join(tmpdir(), "saia-v2-"));
const home = join(work, "home");
mkdirSync(join(home, ".local/share/opencode"), { recursive: true });
mkdirSync(join(home, ".cache/opencode"), { recursive: true });
writeFileSync(
  join(home, ".cache/opencode/saia-gwdg-models.json"),
  JSON.stringify({
    fetchedAt: Date.now(),
    models: [
      { id: "qwen3.8-27b", name: "Qwen 3.8 27B", status: "ready", input: ["text"], output: ["text"] },
      { id: "qwen3-coder-next", name: "Qwen3 Coder Next", status: "ready", input: ["text"], output: ["text"] },
      { id: "deepseek-v4-flash-0731", name: "DeepSeek V4 Flash", status: "ready", input: ["text"], output: ["text", "thought"] },
      { id: "glm-5.3-flash", name: "GLM 5.3 Flash", status: "offline", input: ["text"], output: ["text", "thought"] },
    ],
  })
);
const LOG = join(work, "pacer.log");
const SRVLOG = join(work, "server.log");
writeFileSync(LOG, "");
// os.homedir() reads HOME on Linux, USERPROFILE on Windows.
process.env.HOME = home;
process.env.USERPROFILE = home;
process.env.SAIA_TEST_HOST = "127.0.0.1";
process.env.SAIA_BASE_URL = `http://127.0.0.1:${PORT}/v1`;
process.env.SAIA_PACER_LOG = LOG;
process.env.SAIA_BUDGET_PATH = join(work, "budget.json");
writeFileSync(process.env.SAIA_BUDGET_PATH, "{}");

// Windows has no python3 alias; python is the interpreter there.
const PY = process.platform === "win32" ? "python" : "python3";
const srv = spawn(PY, [join(import.meta.dirname, "fake-saia.py")], {
  env: { ...process.env, FAKE_SAIA_MODE: "ok", FAKE_SAIA_PORT: String(PORT) },
  stdio: ["ignore", "ignore", openSync(SRVLOG, "w")],
});
await new Promise((r) => setTimeout(r, 700));

// Records every body the pacer puts on the wire. Installed BEFORE the plugin,
// so the pacer captures it as its realFetch and sits on top of it.
const wire = [];
const wireAuth = [];
const baseFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  try {
    wire.push(JSON.parse(init?.body));
    wireAuth.push(new Headers(init?.headers).get("authorization"));
  } catch {}
  return baseFetch(input, init);
};

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
const pacerLines = () => readFileSync(LOG, "utf-8").split("\n").filter(Boolean);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- fake v2 ctx -----------------------------------------------------------
const registered = new Map();
const providers = new Map();
const toolHooks = [];
const prompts = [];
const queue = [];
let wake = null;
const push = (evt) => {
  queue.push({ id: `evt_${queue.length}_${Date.now()}`, ...evt });
  wake?.();
};
// opencode's credential store, as the 2.2.5 binary returns it.
let storedKey = "test-key";
const ctx = {
  location: { directory: work },
  integration: {
    connection: {
      active: async (id) => (id === "saia-gwdg" && storedKey ? { type: "credential", id: "cred_test", label: "SAIA (GWDG)", method: "key" } : undefined),
      resolve: async (c) => (c?.id === "cred_test" ? { type: "key", key: storedKey } : undefined),
    },
  },
  provider: {
    transform: async (cb) => {
      cb({
        update: (providerID, fn) => {
          const p = providers.get(providerID) ?? { id: providerID, settings: { baseURL: "https://chat-ai.academiccloud.de/v1" } };
          fn(p);
          providers.set(providerID, p);
        },
        models: {
          update: (providerID, modelID, fn) => {
            const m = { id: modelID, providerID, capabilities: { tools: true, input: ["text", "image"], output: ["text"] } };
            fn(m);
            registered.set(`${providerID}/${modelID}`, m);
          },
        },
      });
      return { dispose: async () => {} };
    },
  },
  tool: {
    hook: async (name, cb) => {
      toolHooks.push({ name, cb });
      return { dispose: async () => {} };
    },
  },
  session: {
    get: async ({ sessionID }) => ({ id: sessionID }),
    prompt: async (input) => {
      prompts.push(input);
      return {};
    },
  },
  event: {
    subscribe: ({ types, signal }) => ({
      [Symbol.asyncIterator]() {
        return {
          next: async () => {
            for (;;) {
              if (signal?.aborted) return { done: true, value: undefined };
              const i = queue.findIndex((e) => types.includes(e.type));
              if (i >= 0) return { done: false, value: queue.splice(i, 1)[0] };
              await new Promise((r) => {
                wake = r;
                signal?.addEventListener("abort", r, { once: true });
              });
            }
          },
          return: async () => ({ done: true, value: undefined }),
        };
      },
    }),
  },
};

const mod = await import("../plugin/saia-gwdg-plugin.js");

console.log("case: default export shape");
check("default.id is a string", typeof mod.default?.id === "string", JSON.stringify(mod.default?.id));
check("default.setup is a function", typeof mod.default?.setup === "function");
check("no default.effect (v2 would treat it as an Effect)", !("effect" in (mod.default ?? {})));

console.log("case: no stored key -> inactive");
{
  storedKey = undefined;
  const r = await mod.default.setup(ctx);
  check("setup returns nothing", r === undefined);
  check("no model registered", registered.size === 0, [...registered.keys()].join(","));
  check("inactive logged with the login hint", pacerLines().some((l) => l.includes("no saia-gwdg key stored") && l.includes("opencode auth login saia-gwdg")));
  storedKey = "test-key";
}

const cleanup = await mod.default.setup(ctx);

console.log("case: setup registers models and installs the pacer");
check("ready model registered", registered.has("saia-gwdg/qwen3.8-27b"), [...registered.keys()].join(","));
check("unready model not registered", !registered.has("saia-gwdg/glm-5.3-flash"));
check("temperature capability set", registered.get("saia-gwdg/qwen3.8-27b")?.capabilities?.temperature === true);
check("model display name set", registered.get("saia-gwdg/qwen3.8-27b")?.name === "Qwen 3.8 27B");
check("no apiKey injected (opencode supplies its stored credential)", !("apiKey" in (providers.get("saia-gwdg")?.settings ?? {})));
check("test baseURL wins", providers.get("saia-gwdg")?.settings?.baseURL === `http://127.0.0.1:${PORT}/v1`);
check("pacer installed", pacerLines().some((l) => l.includes("SAIA key(s) in rotation") && l.includes("opencode v2")));
check("cleanup is a function", typeof cleanup === "function");

console.log("case: wire templating");
{
  // Same frontmatter strip as the plugin's agentBody(): a CRLF checkout of
  // agent/*.md (.gitattributes only pins LF for sh/js/jsonc) must parse too.
  const agentBody = (name) => {
    const txt = readFileSync(join(import.meta.dirname, "..", "agent", `${name}.md`), "utf-8");
    const m = txt.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n?([\s\S]*)$/);
    return (m ? m[1] : txt).trim();
  };
  const coderBody = agentBody("coder");
  const coder2Body = agentBody("coder2");
  const resp = await fetch(`http://127.0.0.1:${PORT}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "glm-5.3-flash",
      stream: true,
      messages: [
        { role: "system", content: `Status: \`__SAIA_BUDGET_STATUS__\`\n${coder2Body}\n# Your Model` },
        { role: "user", content: "keep __SAIA_BUDGET_STATUS__ verbatim here" },
      ],
    }),
  });
  await resp.text();
  const sent = wire.at(-1);
  const sys = sent?.messages?.[0]?.content ?? "";
  check("request reached the wire", resp.status === 200 && !!sent, `status=${resp.status}`);
  check("stored key on the wire", wireAuth.at(-1) === "Bearer test-key", String(wireAuth.at(-1)));
  check("budget placeholder replaced in system", !sys.includes("__SAIA_BUDGET_STATUS__") && sys.includes("UNKNOWN"), sys.slice(0, 120));
  check("coder2 prompt swapped for coder's", sys.includes(coderBody.slice(0, 200)) && !sys.includes(coder2Body.slice(0, 200)));
  check("user message untouched", sent?.messages?.[1]?.content === "keep __SAIA_BUDGET_STATUS__ verbatim here");
  // glm-5.3-flash's role is solo (its first ROLE_MODELS list); solo's next
  // entry is deepseek-v4-flash-0731, which is ready.
  check("unready model remapped within its role", sent?.model === "deepseek-v4-flash-0731", `model=${sent?.model}`);
}

console.log("case: test-mode routing");
{
  // v2 re-applies the config's production baseURL after every plugin; in test
  // mode the pacer must still route it to the fake server.
  const n = wire.length;
  const resp = await fetch("https://chat-ai.academiccloud.de/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "qwen3.8-27b", stream: true, messages: [{ role: "user", content: "hi" }] }),
  });
  const text = await resp.text();
  check("production host redirected to SAIA_BASE_URL", resp.status === 200 && text.includes("chatcmpl-fake"), `status=${resp.status}`);
  check("redirected request went through the pacer", wire.length === n + 1 && pacerLines().some((l) => /req \/v1\/chat\/completions model=qwen3\.8-27b/.test(l)));
  // Same hostname, other port (opencode probes LM Studio/Ollama on localhost):
  // must not be paced or sent the SAIA key.
  const before = pacerLines().length;
  try {
    await fetch("http://127.0.0.1:1/api/v1/models");
  } catch {}
  check("other localhost port not intercepted", !pacerLines().slice(before).some((l) => l.includes("/api/v1/models")));
}

console.log("case: tool hook");
{
  const before = toolHooks.find((h) => h.name === "execute.before");
  check("execute.before registered", !!before);
  let threw = null;
  try {
    await before?.cb({ tool: "subagent", sessionID: "ses_tool", input: {} });
  } catch (e) {
    threw = e;
  }
  check("subagent call allowed on unknown budget", threw === null, String(threw?.message ?? ""));
}

console.log("case: execution.failed -> auto-resume");
{
  push({ type: "session.step.started", data: { sessionID: "ses_a", assistantMessageID: "msg_a1", agent: "build", model: { id: "qwen3.8-27b", providerID: "saia-gwdg" } } });
  push({ type: "session.step.failed", data: { sessionID: "ses_a", assistantMessageID: "msg_a1", error: { type: "provider.transport", message: "headers not received within 45000ms" } } });
  push({ type: "session.execution.failed", data: { sessionID: "ses_a", error: { type: "provider.transport", message: "headers not received within 45000ms" } } });
  await sleep(300);
  check("resume scheduled", pacerLines().some((l) => /auto-resume scheduled session=ses_a msg=msg_a1 .*agent=build/.test(l)), pacerLines().slice(-3).join(" | "));
  await sleep(5500); // first backoff is 5s
  check("session.prompt called", prompts.some((p) => p.sessionID === "ses_a" && /AUTOMATIC RESUME/.test(p.text)), JSON.stringify(prompts).slice(0, 200));
  check("prompt tagged as ours", prompts.at(-1)?.metadata?.saia === "auto-resume");
  push({ type: "session.inbox.enqueued", data: { sessionID: "ses_a", inboxID: "msg_self", item: { type: "user", payload: { text: "x" } } } });
  await sleep(200);
  check("own prompt not read as takeover", pacerLines().some((l) => l.includes("own synthetic prompt seen in ses_a")));
}

console.log("case: execution.interrupted is not resumed");
{
  push({ type: "session.step.started", data: { sessionID: "ses_b", assistantMessageID: "msg_b1", agent: "build", model: { id: "qwen3.8-27b", providerID: "saia-gwdg" } } });
  push({ type: "session.execution.interrupted", data: { sessionID: "ses_b" } });
  await sleep(300);
  check("skip logged as user abort", pacerLines().some((l) => /auto-resume skip session=ses_b reason=aborted/.test(l)), pacerLines().slice(-3).join(" | "));
}

console.log("case: key switched in opencode reaches the pacer");
{
  storedKey = "rotated-key";
  push({ type: "credential.switched", data: { integrationID: "saia-gwdg", credentialID: "cred_test" } });
  await sleep(200);
  const resp = await fetch(`http://127.0.0.1:${PORT}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "qwen3.8-27b", stream: true, messages: [{ role: "user", content: "hi" }] }),
  });
  await resp.text();
  check("change logged", pacerLines().some((l) => l.includes("stored saia-gwdg key changed (…-key)")), pacerLines().slice(-2).join(" | "));
  check("new key on the wire", wireAuth.at(-1) === "Bearer rotated-key", String(wireAuth.at(-1)));
}

console.log("case: cleanup");
{
  let err = null;
  try {
    await cleanup();
  } catch (e) {
    err = e;
  }
  check("cleanup ran", err === null, String(err?.message ?? ""));
}

srv.kill();
console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
