"""Tests for saia_keyring.py against a scripted fake upstream (no SAIA cost).

    python3 -m unittest discover keyring/test

The first three cases are scripts/keys-selftest.mjs, ported: a 401 fails over
to the next key, the dead key is skipped afterwards, and with every key dead
the error names the real cause.
"""

import http.client
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import saia_keyring as sk  # noqa: E402

A, B, C = "sk-first-key-AAAA", "sk-second-key-BBBB", "sk-third-key-CCCC"
FULL = {"minute": 29, "hour": 150, "day": 900, "month": 2500}


class FakeUpstream:
    """Behaviour per bearer key: a list of scripted actions popped per call,
    then `default[key]` (or "ok"). Records (key, method, path) per call."""

    def __init__(self):
        self.script, self.default, self.remaining = {}, {}, {}
        self.calls = []
        self.lock = threading.Lock()
        fake = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def send_body(self, code, obj, headers=None):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def handle_any(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                key = (self.headers.get("Authorization") or "")[7:]
                with fake.lock:
                    fake.calls.append((key, self.command, self.path, body))
                    queue = fake.script.get(key) or []
                    action = queue.pop(0) if queue else fake.default.get(key, "ok")
                    rem = dict(FULL, **fake.remaining.get(key, {}))
                rl = {f"x-ratelimit-remaining-{b}": str(v) for b, v in rem.items()}
                if isinstance(action, tuple):           # ("429", {headers})
                    action, extra = action
                    rl.update(extra)
                if action == "ok":
                    return self.send_body(200, {"ok": True, "key": key[-4:],
                                                "echo": body.decode()}, rl)
                if action in ("401", "403"):
                    return self.send_body(int(action), {"error": "invalid key"})
                if action == "429":
                    return self.send_body(429, {"error": "rate"}, rl)
                if action == "500":
                    return self.send_body(500, {"error": "boom"}, rl)
                if action == "stream":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    for k, v in rl.items():
                        self.send_header(k, v)
                    self.end_headers()
                    for i in range(3):
                        ev = f"data: {{\"n\": {i}}}\n\n".encode()
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(ev), ev))
                        self.wfile.flush()
                        time.sleep(0.4)
                    self.wfile.write(b"0\r\n\r\n")
                    return None
                raise AssertionError(action)

            do_GET = do_POST = handle_any

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/v1"

    def keys_called(self):
        with self.lock:
            return [c[0] for c in self.calls]

    def reset_calls(self):
        with self.lock:
            self.calls.clear()


class KeyringTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="saia-keyring-test-"))
        self.state = self.tmp / "state"
        self.cfg = self.tmp / "keyring.json"
        self.fake = FakeUpstream()
        self.addCleanup(self.fake.srv.server_close)
        self.addCleanup(self.fake.srv.shutdown)
        self.logs = []
        quiet = mock.patch.object(sk, "log", self.logs.append)
        quiet.start()
        self.addCleanup(quiet.stop)
        self.offset = 0.0
        real_now = time.time
        patcher = mock.patch.object(sk, "now", lambda: real_now() + self.offset)
        patcher.start()
        self.addCleanup(patcher.stop)

    def start(self, keys, upstream=None):
        self.cfg.write_text(json.dumps({"upstream": upstream or self.fake.url, "port": 0,
                                        "keys": keys}))
        self.kr, self.srv = sk.make_server(self.cfg, self.state, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.port = self.srv.server_address[1]
        return self.kr

    def stop(self):
        self.srv.shutdown()
        self.srv.server_close()

    def tearDown(self):
        try:
            self.stop()
        except AttributeError:
            pass

    def call(self, key=A, method="POST", path="/v1/chat/completions", body=b'{"x":1}'):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
        conn.request(method, path, body=body if method == "POST" else None, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        try:
            return resp, json.loads(data)
        except ValueError:
            return resp, data

    # -- keys-selftest.mjs, ported

    def test_401_fails_over_to_next_key(self):
        self.fake.default[A] = "401"
        self.start([A, B])
        resp, body = self.call()
        self.assertEqual(resp.status, 200, "a 401 on key #1 must fail over, not surface")
        self.assertEqual(self.fake.keys_called(), [A, B])
        self.assertEqual(body["echo"], '{"x":1}', "the request body must be replayed")
        self.assertEqual(resp.getheader("x-saia-keyring-key"), "key2(...BBBB)")

    def test_dead_key_not_retried_on_next_request(self):
        self.fake.default[A] = "401"
        self.start([A, B])
        self.call()
        self.fake.reset_calls()
        self.assertEqual(self.call()[0].status, 200)
        self.assertEqual(self.fake.keys_called(), [B])

    def test_concurrent_401s_log_the_dead_key_once(self):
        self.start([A, B])
        ks = self.kr.ring.keys[0]
        self.kr.ring.mark_dead(ks)
        self.kr.ring.mark_dead(ks)
        self.assertEqual(sum("rejected (401/403)" in m for m in self.logs), 1)

    def test_all_dead_names_the_real_cause(self):
        self.fake.default[A] = "403"
        self.start([A])
        resp, body = self.call()
        self.assertEqual(resp.status, 401)
        self.assertRegex(body["error"]["message"], "revoked or expired")
        self.assertIn("saia.gwdg.de", body["error"]["message"])
        self.fake.reset_calls()
        self.assertEqual(self.call()[0].status, 401)
        self.assertEqual(self.fake.keys_called(), [], "no upstream request once all keys are out")

    # -- depletion

    def test_floor_switches_on_next_request(self):
        self.fake.remaining[A] = {"hour": 5}
        self.start([A, B])
        self.assertEqual(self.call()[0].status, 200)  # this one still goes out on A
        self.fake.reset_calls()
        self.call()
        self.assertEqual(self.fake.keys_called(), [B])
        self.call()
        self.assertEqual(self.fake.keys_called(), [B, B], "rotation is sticky")

    def test_minute_429_fails_over_without_waiting(self):
        self.fake.script[A] = [("429", {"ratelimit-reset": "30", "x-ratelimit-remaining-minute": "0"})]
        self.start([A, B])
        t = time.time()
        resp, _ = self.call()
        self.assertEqual(resp.status, 200)
        self.assertLess(time.time() - t, 2, "must not sleep when another key is usable")
        self.assertEqual(self.fake.keys_called(), [A, B])
        a = self.kr.ring.describe()[0]
        self.assertFalse(a["usable"])
        self.offset = 31
        self.assertTrue(self.kr.ring.describe()[0]["usable"], "parked key returns after reset")

    def test_drained_429_marks_bucket_and_fails_over(self):
        self.fake.script[A] = [("429", {"x-ratelimit-remaining-day": "0"})]
        self.start([A, B])
        t = time.time()
        self.assertEqual(self.call()[0].status, 200)
        self.assertLess(time.time() - t, 2)
        self.assertEqual(self.kr.ring.describe()[0]["out"], "day")

    def test_single_key_429_waits_once_then_gives_up(self):
        self.fake.default[A] = ("429", {"ratelimit-reset": "1"})
        self.start([A])
        t = time.time()
        resp, body = self.call()
        self.assertGreaterEqual(time.time() - t, 1.0, "waits ratelimit-reset before the retry")
        self.assertEqual(resp.status, 429)
        self.assertEqual(self.fake.keys_called(), [A, A])
        self.assertRegex(body["error"]["message"], "nearly exhausted")

    def test_exhausted_key_revives_after_ttl(self):
        self.fake.remaining[A] = {"hour": 3}
        self.start([A, B])
        self.call()                      # A reports hour=3
        self.call()                      # -> switches to B
        self.fake.default[B] = "401"     # B dies; A is still inside its hour TTL
        self.fake.reset_calls()
        self.assertEqual(self.call()[0].status, 429)
        self.assertEqual(self.fake.keys_called(), [B])
        self.offset = 3601
        self.fake.remaining[A] = {}
        self.fake.reset_calls()
        self.assertEqual(self.call()[0].status, 200)
        self.assertEqual(self.fake.keys_called(), [A])

    def test_dead_key_reprobed_after_a_day(self):
        self.fake.script[A] = ["401"]
        self.start([A, B])
        self.call()
        self.offset = sk.DEAD_REPROBE_S + 1
        self.fake.default[B] = "401"
        self.fake.reset_calls()
        self.assertEqual(self.call()[0].status, 200)
        self.assertEqual(self.fake.keys_called(), [B, A])

    # -- transport

    def test_sse_is_relayed_unbuffered_and_intact(self):
        self.fake.default[A] = "stream"
        self.start([A])
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        t = time.time()
        conn.request("POST", "/v1/chat/completions", body=b"{}",
                     headers={"Authorization": f"Bearer {A}"})
        resp = conn.getresponse()
        first = resp.read1(65536)
        t_first = time.time() - t
        rest = resp.read()
        total = time.time() - t
        self.assertLess(t_first, 0.35, "first event must arrive before the stream ends")
        self.assertGreaterEqual(total, 1.0)
        self.assertEqual(first + rest, b"".join(f"data: {{\"n\": {i}}}\n\n".encode()
                                                for i in range(3)))

    def test_get_models_passthrough(self):
        self.start([A])
        resp, _ = self.call(method="GET", path="/v1/models")
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.fake.calls[-1][1:3], ("GET", "/v1/models"))

    def test_upstream_error_passed_through(self):
        self.fake.default[A] = "500"
        self.start([A, B])
        self.assertEqual(self.call()[0].status, 500)
        self.assertEqual(self.fake.keys_called(), [A], "5xx is not a key problem")

    def test_upstream_down_is_502(self):
        self.start([A], upstream="http://127.0.0.1:9/v1")
        self.assertEqual(self.call()[0].status, 502)

    # -- auth and config

    def test_unknown_bearer_rejected_locally(self):
        self.start([A])
        resp, body = self.call(key="not-a-configured-key")
        self.assertEqual(resp.status, 401)
        self.assertEqual(body["error"]["code"], "unknown_key")
        self.assertEqual(self.fake.keys_called(), [])

    def test_config_reload_without_restart(self):
        self.start([A])
        self.assertEqual(self.call(key=B)[0].status, 401)
        self.cfg.write_text(json.dumps({"upstream": self.fake.url, "port": 0, "keys": [A, B]}))
        st = self.cfg.stat()
        os.utime(self.cfg, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))
        self.assertEqual(self.call(key=B)[0].status, 200)
        self.assertEqual(len(self.kr.ring.keys), 2)

    def test_dead_state_survives_restart_and_reorder(self):
        self.fake.default[A] = "401"
        self.start([A, B])
        self.call()
        self.stop()
        self.fake.reset_calls()
        self.start([C, A, B])            # A moved to position 2
        self.fake.default[C] = "401"
        self.call()
        self.assertEqual(self.fake.keys_called(), [C, B], "A must stay dead after the restart")
        labels = {k["label"]: k["dead"] for k in self.kr.ring.describe()}
        self.assertEqual(labels, {"key1(…CCCC)": True, "key2(…AAAA)": True,
                                  "key3(…BBBB)": False})

    def test_budget_snapshot_in_plugin_format(self):
        self.fake.default[A] = "401"
        self.start([A, B])
        self.call()
        snap = json.loads((self.state / "budget.json").read_text())
        self.assertEqual(snap["activeIndex"], 1)
        self.assertEqual(snap["remaining"]["hour"], 150)
        self.assertEqual([k["label"] for k in snap["keys"]], ["key1(…AAAA)", "key2(…BBBB)"])
        self.assertTrue(snap["keys"][0]["dead"])
        self.assertNotIn(A, json.dumps(snap), "full keys never land in the snapshot")
        self.assertNotIn(A, (self.state / "keys_state.json").read_text())

    def test_health_endpoint(self):
        self.start([A, B])
        h = sk.fetch_health(self.port)
        self.assertEqual(h["service"], "saia-keyring")
        self.assertEqual(h["version"], sk.VERSION)
        self.assertEqual(len(h["keys"]), 2)


if __name__ == "__main__":
    unittest.main()
