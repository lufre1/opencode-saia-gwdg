# SAIA backend investigation — HTTP 500s **and** silent hangs

Investigated 2026-08-26, extended 2026-08-28. Symptoms: opencode with SAIA models
frequently shows `Internal Server Error: Internal Server Error`, and — separately —
**silently stops working**: the session freezes with no error and no log entry.

## Verdict

**Root cause is server-side at SAIA (chat-ai.academiccloud.de): broken/hung
backend replicas.** Identical minimal request to `deepseek-v4-flash-0731`,
three consecutive tries a few seconds apart:

| Try | Result |
|-----|--------|
| 1 | HTTP 500 in ~0.1 s, empty body (`content-length: 0`) |
| 2 | HTTP 200, normal completion |
| 3 | Hang — connection accepted, 0 bytes for 30+ s (client timeout) |

Load balancer routes across a mix of healthy, crashed, and hung replicas.
Not request-shape-dependent, not rate limiting, not client config.

## The hang is a distinct failure mode, not a quiet 500

Added 2026-08-28, from `~/.local/share/opencode/log/opencode.log` (Jun–Aug 2026,
9067 streams):

| Signal | Count |
|---|---|
| `AI_APICallError: Internal Server Error` | 1062, across 61 distinct hours |
| Requests where `llm runtime selected` is the **last log line ever written** — fired, never returned | **123** |
| Requests followed by >60 s of silence, then recovery | 145 |
| `Too Many Requests` / `Service Unavailable` / `Bad Gateway` | 18 / 5 / 2 |
| vLLM-origin errors (`EngineCore encountered an issue`, `add_generation_prompt`) | 11 |

Hangs by model: `qwen3-coder-next` 70, `deepseek-v4-flash` 24,
`qwen3.5-122b-a10b` 9, `qwen3.5-397b-a17b` 6, `deepseek-v4-flash-0731` 4.

**Only 33 % of hang-hours also contain 500s.** A replica that accepts the
connection and then sends nothing is a separate defect from one that returns an
immediate 500 — both must be reported.

## Live reproduction (2026-08-26, ~13:06–13:12 UTC, curl)

- `deepseek-v4-flash-0731` minimal request: 500/200/hang roulette (above)
- `qwen3.6-35b-a3b` minimal request: hung, 0 bytes for 90 s
- `qwen3.5-122b-a10b`, `glm-4.7` minimal request: 500 in ~60 ms, empty body
- `qwen3-coder-next`: minimal OK; with tool definitions once 500
  (`text/plain` body `Internal Server Error`), identical request 200 shortly after
- `/v1/models` reported **all** affected models `ready` throughout — status
  unreliable (re-verified 2026-08-28: 16/16 `ready`)
- 500s decrement `x-ratelimit-remaining-*` — outages consume quota
- Kong request IDs for GWDG correlation:
  - `82f2ea69ad87953decf98f7b1b540761` (500, deepseek-v4-flash-0731, 13:06:46 GMT, upstream latency 11 ms)
  - `88e20552f7b7fc6a8d0ded6ababd084c` (500, qwen3-coder-next, 13:08:22 GMT, upstream latency 50 ms)

## Why the message is doubled

opencode core concatenates HTTP statusText + response body on provider errors.
SAIA's 500 body is plain text `Internal Server Error` →
`"Internal Server Error" + ": " + "Internal Server Error"`.

## Why it was *silent* (client-side, all three now fixed)

1. **opencode logs stream start, never stream success.** `message=stream` and
   `message="llm runtime selected"` are written *before* the request; nothing is
   written on completion. A request that never returns left zero trace anywhere.
2. **No timeout anywhere.** The plugin called `realFetch` with no `AbortSignal`,
   and `opencode.jsonc` provider options had only `baseURL`
   (`@ai-sdk/openai-compatible` has no default). A hung replica froze opencode
   forever.
3. **One hang froze everything.** All SAIA traffic runs through a single global
   promise chain in `plugin/saia-gwdg-plugin.js`. A pending `realFetch` never
   released the queue, so every other agent, subagent and `/v1/models` call in
   the process stalled behind it — which is why it read as "opencode died"
   rather than "one model is slow".

## Changes applied

**2026-08-26**

- `SAIA_PACER_DEBUG=1` exported in `~/.bashrc`
- Plugin instrumented: 5xx responses log body, `retry-after`, model
- Stale bare `deepseek-v4-flash` ids in `ROLE_MODELS` fixed to `deepseek-v4-flash-0731`

**2026-08-28**

- **Fixed a logging bug**: the 5xx capture read `x-request-id`, which SAIA does
  not send. It sends `x-kong-request-id`. Every 500 logged between 2026-08-26 and
  2026-08-28 recorded `x-request-id=null`, so the correlation IDs GWDG needs were
  never captured. Now read correctly and emitted on **every** response, giving a
  healthy baseline to diff against.
- **Network timeout** (`SAIA_TIMEOUT_MS`, default 60 s) around the single
  `realFetch` call. Wrapping only the network call means the pacer's queue wait,
  2100 ms spacing, 30 s cooldown and 429 sleeps cannot cause a false abort.
  Aborting also releases the shared queue, so one hung replica no longer freezes
  the whole process.
- **One reconnect on connection-level failure** (`MAX_CONNECT_TRIES = 2`).
  opencode retries 5xx and 429 itself (`AI_RetryError: Failed after 3 attempts`),
  but the AI SDK classifies an abort as user cancellation, so a timed-out or
  dropped connection got exactly one shot and surfaced as a hard error — verified
  in the log: a `TimeoutError` produced a single attempt with no `AI_RetryError`
  wrapper. Since the defect is a bad *replica* and a fresh connection is
  re-load-balanced, retrying at this layer is what actually recovers. The
  caller's own abort (`init.signal.aborted`) is never retried. Both tries share
  one `id=`, and the `retrying=` field on the `fail` line records the decision.
- **`chunkTimeout: 60000`** in the `opencode.jsonc` provider options for the
  mid-stream stall (stream opens, then dies). Deliberately no `timeout` /
  `headerTimeout`: opencode measures those around the plugin's patched
  `globalThis.fetch`, so they would include the pacer's own waits.
- **Pacer log is now always on** (was gated on `SAIA_PACER_DEBUG=1`, which a
  desktop or IDE launch does not inherit — so the rare event went uncaptured).
  Only the expensive 5xx body read stays behind the env var. 8 MB single-generation
  rotation.
- **Three log lines per request** in `~/.cache/opencode/saia-gwdg-pacer.log`:
  - `req <path> model= key= id= queued=<ms>`
  - `resp <status> model= key= id= ttfb=<ms> kong=<x-kong-request-id> upstream=<ms> remaining=<m/h/d>`
  - `fail <ErrorName> model= key= id= after=<ms> timeout=<ms> msg=…` — **new**;
    this is the line that turns a silent hang into a dated, attributable record.
- **Client-side correlation ID** `x-client-request-id` (a UUID) sent on every
  request and logged on the `req` line. A hang produces no response and therefore
  no Kong ID; this is the only identifier that can exist for that failure mode.

Verified end to end: `SAIA_TIMEOUT_MS=1` fails in ~4 s with
`Error: The operation timed out.` instead of hanging, writes two `fail TimeoutError`
lines (proving the queue advanced between opencode's retries), and a normal request
succeeds immediately afterwards.

**Postscript (2026-08-28):** that `SAIA_TIMEOUT_MS=1` export leaked into a real
work session's terminal and aborted every request after 1 ms (six `timeout=1ms`
fail lines). The plugin now clamps env values below 5000 to a 5 s floor; re-running
this fault injection requires editing the `TIMEOUT_MS` constant directly.

## Harvesting evidence for the next report

```sh
grep -E '^\S+ (fail|resp [45])' ~/.cache/opencode/saia-gwdg-pacer.log
```

`fail TimeoutError` lines are hangs (report timestamp + model + `x-client-request-id`);
`resp 5xx` lines carry `kong=` for direct GWDG correlation.

## Open item

- Plugin cooldown still sleeps 30 s inside the shared queue after 3 consecutive
  5xx (`plugin/saia-gwdg-plugin.js`, `MAX_CONSECUTIVE_5XX`). With the network
  timeout in place the worst case is bounded and the symptom degrades from
  "frozen forever" to "slow", so this is no longer urgent. Fail fast per request
  instead of sleeping in the queue if it becomes annoying.

---

## Email draft for GWDG support

To: support@gwdg.de
Subject: SAIA / Chat AI API: intermittent HTTP 500 and hanging requests on multiple models (chat-ai.academiccloud.de)

Dear GWDG support team,

I am reporting reproducible backend problems with the SAIA API at
https://chat-ai.academiccloud.de/v1, observed while using it via
OpenAI-compatible clients. Requests to several models intermittently fail with
HTTP 500 or hang indefinitely, even though /v1/models reports the models as
"ready".

Observations (2026-08-26, approx. 13:06-13:12 UTC, minimal test requests via curl):

1. Identical minimal chat-completion request to `deepseek-v4-flash-0731`
   (single short user message, max_tokens=8) produced three different outcomes
   in consecutive attempts, a few seconds apart:
   - HTTP 500 in ~0.1 s with an empty body (content-length: 0)
   - HTTP 200 with a normal completion
   - a hang: connection accepted, no response bytes for 30+ seconds
     (client-side timeout)

2. `qwen3.6-35b-a3b`: minimal request hung with 0 bytes received for 90 s
   until client timeout.

3. `qwen3.5-122b-a10b` and `glm-4.7`: HTTP 500 in ~60 ms with empty body on
   minimal requests.

4. `qwen3-coder-next`: intermittent HTTP 500 with a plain-text body
   "Internal Server Error" (content-type: text/plain) on a request containing
   tool definitions; an identical request succeeded shortly after.

Request IDs for correlation:
- x-kong-request-id: 82f2ea69ad87953decf98f7b1b540761
  (500, deepseek-v4-flash-0731, 2026-08-26 13:06:46 GMT, x-kong-upstream-latency: 11 ms)
- x-kong-request-id: 88e20552f7b7fc6a8d0ded6ababd084c
  (500, qwen3-coder-next, 2026-08-26 13:08:22 GMT, x-kong-upstream-latency: 50 ms)

The very low upstream latencies on the 500s suggest requests are being
rejected immediately by an unhealthy backend replica rather than failing
during inference; the alternating 500/200/hang pattern for identical requests
looks like load balancing across a mix of healthy, crashed, and hung replicas.
My client logs also show earlier vLLM-originated errors such as "EngineCore
encountered an issue" from the API.

Scale, from my client logs for June-August 2026 (9067 requests total):

- 1062 HTTP 500 responses, clustered in bursts across 61 distinct hours.
  Most affected: qwen3-coder-next and qwen3.6-35b-a3b.
- 123 requests that were sent and never received any response at all, i.e.
  the connection was accepted and no bytes were ever returned. Most affected:
  qwen3-coder-next (70), deepseek-v4-flash (24), qwen3.5-122b-a10b (9).
  Only about a third of the hours containing hangs also contain 500s, so this
  appears to be a separate failure mode from the immediate-500 one rather than
  the same defect presenting differently.
- A further 145 requests took more than 60 s before any response.

I have since added a 60 s client-side timeout, so from now on I can supply exact
UTC timestamps, model names and a client-generated x-client-request-id header
for every hanging request, should that help you correlate against your Kong or
vLLM logs.

Two additional points you may want to look at:

- /v1/models reports status "ready" for all affected models while this is
  happening, so clients cannot detect or avoid the broken endpoints.
- Failed 500 responses still decrement the rate-limit budget
  (x-ratelimit-remaining-* headers), so outages additionally consume users'
  quota.

I am happy to provide further logs or run additional tests if that helps.

Best regards,
Luca Freckmann
luca.freckmann@uni-goettingen.de
