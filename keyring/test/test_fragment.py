"""Tests for saia-keyring.sh, the fragment every harness installer sources.

Runs the fragment in a throwaway HOME with SAIA_KEYRING_SERVICE=none (or rc),
so neither the real systemd user manager nor the real shell rc is touched.
"""

import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from test_keyring import FakeUpstream, sk

FRAGMENT = Path(__file__).resolve().parent.parent / "saia-keyring.sh"
PROD = "https://chat-ai.academiccloud.de/v1"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FragmentTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="saia-keyring-home-"))
        self.port = free_port()
        self.fake = FakeUpstream()
        self.addCleanup(self.fake.srv.server_close)
        self.addCleanup(self.fake.srv.shutdown)
        self.addCleanup(self.kill_proxy)
        self.cfg = self.home / ".config/saia-keyring/keyring.json"

    def kill_proxy(self):
        h = sk.fetch_health(self.port, timeout=0.5)
        if h:
            os.kill(h["pid"], signal.SIGTERM)

    def setup(self, primary, args=(), env=None, base_url=None):
        """Run keyring_arg over args, then keyring_setup; returns (url, output)."""
        script = (f'set -euo pipefail; source "{FRAGMENT}"\n'
                  'while [[ $# -gt 0 ]]; do keyring_arg "$@" || exit 9; shift "$KEYRING_SHIFT"; done\n'
                  'keyring_setup "$PRIMARY"\n'
                  'echo "URL=$SAIA_EFFECTIVE_BASE_URL ACTIVE=$KEYRING_ACTIVE"\n')
        e = {"PATH": os.environ["PATH"], "HOME": str(self.home), "PRIMARY": primary,
             "SAIA_KEYRING_SERVICE": "none", "SAIA_KEYRING_PORT": str(self.port)}
        if base_url:
            e["SAIA_BASE_URL"] = base_url
        e.update(env or {})
        p = subprocess.run(["bash", "-c", script, "setup", *args], env=e, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        last = p.stdout.strip().splitlines()[-1]
        return last.split()[0][4:], p.stdout + p.stderr

    def test_single_key_changes_nothing(self):
        url, _ = self.setup("only-key")
        self.assertEqual(url, PROD)
        self.assertFalse(self.cfg.exists(), "no keyring config for a single key")

    def test_extra_keys_alone_never_start_the_proxy(self):
        # the installers must work for anyone without the proxy: it is opt-in
        url, out = self.setup("k1", ["--extra-keys", "k2"], env={"SAIA_API_KEYS_EXTRA": "k3"})
        self.assertEqual(url, PROD)
        self.assertFalse(self.cfg.exists())
        self.assertIsNone(sk.fetch_health(self.port))
        self.assertIn("opt-in (add --keyring)", out)

    def test_keyring_flag_starts_the_proxy(self):
        url, out = self.setup("k1", ["--keyring"], env={"SAIA_API_KEYS_EXTRA": "k2, k3,k2"})
        self.assertEqual(url, f"http://127.0.0.1:{self.port}/v1", out)
        data = json.loads(self.cfg.read_text())
        self.assertEqual(data, {"upstream": PROD, "port": self.port, "keys": ["k1", "k2", "k3"]})
        self.assertEqual(stat.S_IMODE(self.cfg.stat().st_mode), 0o600)
        self.assertEqual(len(sk.fetch_health(self.port)["keys"]), 3)
        shim = self.home / ".local/bin/saia-keyring"
        st = subprocess.run([str(shim), "status"], env={"PATH": os.environ["PATH"],
                                                        "HOME": str(self.home)},
                            capture_output=True, text=True)
        self.assertIn("key3(…k3)", st.stdout)

    def test_gateway_override_never_gets_the_proxy(self):
        url, _ = self.setup("bench-token", env={"SAIA_API_KEYS_EXTRA": "k2"},
                            base_url="http://127.0.0.1:8787/v1")
        self.assertEqual(url, "http://127.0.0.1:8787/v1")
        self.assertFalse(self.cfg.exists())

    def test_gateway_override_does_no_work_without_python(self):
        # benchmark containers: an override with no python3 must stay silent
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        for tool in ("bash", "dirname"):        # what the fragment needs, minus python3
            (bin_dir / tool).symlink_to(shutil.which(tool))
        url, out = self.setup("bench-token", env={"SAIA_API_KEYS_EXTRA": "k2",
                                                  "PATH": str(bin_dir)},
                              base_url="http://saia-gw:8787/v1")
        self.assertEqual(url, "http://saia-gw:8787/v1")
        self.assertNotIn("WARNING", out)

    def test_no_keyring_flag_wins(self):
        url, _ = self.setup("k1", ["--no-keyring", "--extra-keys", "k2"])
        self.assertEqual(url, PROD)
        self.assertFalse(self.cfg.exists())

    def test_forced_keyring_fails_over_end_to_end(self):
        self.fake.default["dead"] = "401"
        url, out = self.setup("dead", ["--keyring", "--extra-keys", "good"],
                              base_url=self.fake.url)
        self.assertEqual(url, f"http://127.0.0.1:{self.port}/v1", out)
        out = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                              "-H", "Authorization: Bearer dead", url + "/models"],
                             capture_output=True, text=True).stdout
        self.assertEqual(out, "200")
        self.assertEqual(self.fake.keys_called(), ["dead", "good"])

    def test_extras_kept_on_reinstall_and_backed_up_on_change(self):
        self.setup("k1", ["--keyring", "--extra-keys", "k2"])
        url, out = self.setup("k1", ["--keyring"])
        self.assertIn("kept", out)
        self.assertEqual(json.loads(self.cfg.read_text())["keys"], ["k1", "k2"])
        self.setup("k1", ["--keyring", "--extra-keys", "k9"])
        self.assertEqual(json.loads(self.cfg.read_text())["keys"], ["k1", "k9"])
        baks = list(self.cfg.parent.glob("keyring.json.bak-*"))
        self.assertEqual(len(baks), 1)
        self.assertEqual(json.loads(baks[0].read_text())["keys"], ["k1", "k2"])
        self.assertEqual(stat.S_IMODE(baks[0].stat().st_mode), 0o600)
        # the running proxy picked the new key up without a restart
        time.sleep(0.05)
        self.assertEqual([k["label"] for k in sk.fetch_health(self.port)["keys"]],
                         ["key1(…k1)", "key2(…k9)"])

    def test_extras_file_in_opencode_format_and_plain_lines(self):
        oc = self.home / "saia-gwdg-keys.json"
        oc.write_text(json.dumps({"keys": ["k2", "k3"]}))
        self.setup("k1", ["--keyring", "--extra-keys-file", str(oc)])
        self.assertEqual(json.loads(self.cfg.read_text())["keys"], ["k1", "k2", "k3"])
        plain = self.home / "keys.txt"
        plain.write_text("# mine\nk4\n\nk5\n")
        self.setup("k1", ["--keyring", "--extra-keys-file", str(plain)])
        self.assertEqual(json.loads(self.cfg.read_text())["keys"], ["k1", "k4", "k5"])

    def test_missing_extras_file_is_a_clear_error(self):
        p = subprocess.run(["bash", "-c", f'set -e; source "{FRAGMENT}"; '
                            'KEYRING_MODE=on KEYRING_EXTRA_KEYS_FILE=/nope keyring_setup k1'],
                           env={"PATH": os.environ["PATH"], "HOME": str(self.home)},
                           capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cannot read extra keys file /nope", p.stderr)

    def test_opencode_hint_for_single_key(self):
        oc = self.home / ".local/share/opencode/saia-gwdg-keys.json"
        oc.parent.mkdir(parents=True)
        oc.write_text('{"keys": ["k2"]}')
        url, out = self.setup("k1")
        self.assertIn(f"--keyring --extra-keys-file {oc}", out)
        self.assertEqual(url, PROD, "a tip only — the proxy stays off")
        self.assertFalse(self.cfg.exists())

    def test_rc_mode_adds_one_block(self):
        rc = self.home / ".bashrc"
        rc.write_text("export FOO=1\n")
        env = {"SAIA_KEYRING_SERVICE": "rc", "SAIA_SHELL_RC": str(rc)}
        self.setup("k1", ["--keyring", "--extra-keys", "k2"], env=env)
        self.setup("k1", ["--keyring", "--extra-keys", "k2"], env=env)
        text = rc.read_text()
        self.assertTrue(text.startswith("export FOO=1\n"))
        self.assertEqual(text.count(">>> saia-keyring"), 1)
        self.assertIn(" ensure ", text)
        self.assertIsNotNone(sk.fetch_health(self.port))

    def test_stale_proxy_is_replaced_when_the_file_changes(self):
        self.setup("k1", ["--keyring", "--extra-keys", "k2"])
        old_pid = sk.fetch_health(self.port)["pid"]
        installed = self.home / ".local/share/saia-keyring/saia_keyring.py"
        installed.write_text(installed.read_text() + "\n# older build\n")
        self.setup("k1", ["--keyring", "--extra-keys", "k2"])
        new = sk.fetch_health(self.port)
        self.assertIsNotNone(new)
        self.assertNotEqual(new["pid"], old_pid)


if __name__ == "__main__":
    unittest.main()
