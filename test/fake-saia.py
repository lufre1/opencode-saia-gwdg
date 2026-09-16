#!/usr/bin/env python3
"""Fault-injecting stand-in for the SAIA endpoint.

Test-only: nothing here is installed by setup-saia-opencode.sh. It exists
because the SAIA stall paths in plugin/saia-gwdg-plugin.js cannot be triggered
on demand against the real endpoint, and shipped for 12 days without their
stream-retry path ever executing once.

Point opencode at it with:
    SAIA_TEST_HOST=127.0.0.1 SAIA_BASE_URL=http://127.0.0.1:8787/v1

Behaviour is chosen per request by the `mode` query parameter, falling back to
the FAKE_SAIA_MODE environment variable. See MODES below.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODES = {
    "ok": "stream three chunks and finish normally",
    "slow": "one chunk every 3s for 90s, then finish — must NOT be cut off at 45s",
    "headers-stall": "headers + 3 content chunks, then silence forever",
    "headers-stall-long": "headers + >1500 chars of content, then silence forever",
    "headers-stall-toolcall": "headers + content + tool_call arg fragments, then silence",
    "late-error": "a complete stream including finish_reason, then kill the socket",
    "accept-silent": "accept the connection and never send headers",
    "empty-200": "200 + event-stream, no kong headers, no bytes ever",
    "five-hundred": "500 on the first 3 requests of the process, then ok",
    "slow-json": "non-streaming: content-type json, half a body, then silence",
}

PORT = int(os.environ.get("FAKE_SAIA_PORT", "8787"))
DEFAULT_MODE = os.environ.get("FAKE_SAIA_MODE", "ok")
MODEL = "fake-model-1"
STALL_SECONDS = 600  # "forever" as far as any plugin deadline is concerned

_five_hundred_count = 0


def sse(delta, finish=None, extra=None):
    payload = {
        "id": "chatcmpl-fake",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": MODEL,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    if extra:
        payload.update(extra)
    return f"data: {json.dumps(payload)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[fake-saia] {self.address_string()} {fmt % args}\n")

    # ---------------------------------------------------------------- helpers
    def _mode(self):
        if "?" in self.path:
            for pair in self.path.split("?", 1)[1].split("&"):
                if pair.startswith("mode="):
                    return pair[5:]
        return DEFAULT_MODE

    def _stream_headers(self, kong=True):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        # The plugin treats a 200 with neither header as a dead replica and
        # uses the short EMPTY_200_TIMEOUT_MS window instead of the idle one.
        if kong:
            self.send_header("x-kong-request-id", "fake-kong-id")
            self.send_header("x-kong-upstream-latency", "12")
        for bucket, left in (("minute", 29), ("hour", 199), ("day", 999), ("month", 2999)):
            self.send_header(f"x-ratelimit-remaining-{bucket}", str(left))
        self.end_headers()

    def _write_chunked(self, data: bytes):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ------------------------------------------------------------------ routes
    def do_GET(self):
        if self.path.split("?")[0].endswith("/models"):
            self._json({
                "data": [
                    {"id": MODEL, "name": "Fake Model", "status": "ready",
                     "input": ["text"], "output": ["text"]},
                    {"id": "fake-reasoner-1", "name": "Fake Reasoner", "status": "ready",
                     "input": ["text"], "output": ["text", "thought"]},
                ]
            })
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if not self.path.split("?")[0].endswith("/chat/completions"):
            self._json({"error": "not found"}, 404)
            return
        mode = self._mode()
        self.log_message("mode=%s", mode)
        handler = getattr(self, f"_m_{mode.replace('-', '_')}", None)
        if handler is None:
            self._json({"error": f"unknown mode {mode}", "modes": sorted(MODES)}, 400)
            return
        handler()

    # ------------------------------------------------------------------- modes
    def _m_ok(self):
        self._stream_headers()
        for word in ("Hello", " from", " the", " fake", " endpoint."):
            self._write_chunked(sse({"content": word}))
        self._write_chunked(sse({}, "stop"))
        self._write_chunked(b"data: [DONE]\n\n")
        self._write_chunked(b"")

    def _m_slow(self):
        self._stream_headers()
        deadline = time.time() + 90
        n = 0
        while time.time() < deadline:
            n += 1
            self._write_chunked(sse({"content": f"chunk{n} "}))
            time.sleep(3)
        self._write_chunked(sse({}, "stop"))
        self._write_chunked(b"data: [DONE]\n\n")
        self._write_chunked(b"")

    def _m_headers_stall(self):
        self._stream_headers()
        for word in ("The", " answer", " begins"):
            self._write_chunked(sse({"content": word}))
        time.sleep(STALL_SECONDS)

    def _m_headers_stall_long(self):
        self._stream_headers()
        # >RESUME_ANCHOR_CHARS (1500) of content, so the retry anchor truncates
        for i in range(60):
            self._write_chunked(sse({"content": f"sentence number {i} padding padding padding. "}))
        time.sleep(STALL_SECONDS)

    def _m_headers_stall_toolcall(self):
        self._stream_headers()
        self._write_chunked(sse({"content": "Let me read that file."}))
        self._write_chunked(sse({"tool_calls": [
            {"index": 0, "id": "call_fake", "type": "function",
             "function": {"name": "read", "arguments": ""}}
        ]}))
        for frag in ('{"file', 'Path": "/tm', 'p/x.tx'):
            self._write_chunked(sse({"tool_calls": [
                {"index": 0, "function": {"arguments": frag}}
            ]}))
        time.sleep(STALL_SECONDS)

    def _m_late_error(self):
        self._stream_headers()
        self._write_chunked(sse({"content": "Complete answer."}))
        self._write_chunked(sse({}, "stop"))
        # finish_reason is out; now die before [DONE] and the terminating chunk
        try:
            self.connection.close()
        except OSError:
            pass

    def _m_accept_silent(self):
        time.sleep(STALL_SECONDS)

    def _m_empty_200(self):
        self._stream_headers(kong=False)
        time.sleep(STALL_SECONDS)

    def _m_five_hundred(self):
        global _five_hundred_count
        _five_hundred_count += 1
        if _five_hundred_count <= 3:
            self._json({"error": {"message": "Internal Server Error"}}, 500)
        else:
            self._m_ok()

    def _m_slow_json(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self._write_chunked(b'{"id": "chatcmpl-fake", "choices": [')
        time.sleep(STALL_SECONDS)


if __name__ == "__main__":
    if "--list" in sys.argv:
        for name, desc in sorted(MODES.items()):
            print(f"{name:24s} {desc}")
        sys.exit(0)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print(f"[fake-saia] listening on http://127.0.0.1:{PORT}/v1 (default mode={DEFAULT_MODE})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
