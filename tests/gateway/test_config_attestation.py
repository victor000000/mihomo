import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/Attest-Config.py'
spec = importlib.util.spec_from_file_location('attestation', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class AttestationTests(unittest.TestCase):
    def test_format_only_change_has_distinct_hash_and_equal_semantics(self):
        r = m.attest(b'rules: []\n', b'# formatting\nrules: []\n')
        self.assertTrue(r['semantics_equal'])
        self.assertFalse(r['bytes_equal'])
        self.assertNotEqual(r['before_sha256'], r['after_sha256'])

    def test_rule_order_is_material_even_when_theta_rule_is_equal(self):
        a = b'rules: ["MATCH,DIRECT", "DOMAIN-SUFFIX,thetadata.us,LA"]'
        b = b'rules: ["DOMAIN-SUFFIX,thetadata.us,LA", "MATCH,DIRECT"]'
        r = m.attest(a, b)
        self.assertEqual(r['changed_sections'], ['rules'])
        self.assertTrue(r['theta_explicit_rules_equal'])
        self.assertFalse(r['semantics_equal'])

    def test_proxy_change_does_not_hide_behind_equal_theta_rule(self):
        r = m.attest(b'proxies: [{password: old}]', b'proxies: [{password: new}]')
        self.assertEqual(r['changed_sections'], ['proxies'])
        self.assertTrue(r['theta_explicit_rules_equal'])
        self.assertFalse(r['semantics_equal'])

    def test_boolean_and_number_changes_are_material(self):
        r = m.attest(b'tun: {enable: true}', b'tun: {enable: 1}')
        self.assertFalse(r['semantics_equal'])
        self.assertEqual(r['changed_sections'], ['tun'])

    def test_private_values_and_unknown_keys_are_absent_from_report(self):
        r = m.attest(b'private-marker: credential-marker', b'other-private-marker: new-secret')
        encoded = json.dumps(r)
        for secret in ['private-marker', 'credential-marker', 'new-secret']:
            self.assertNotIn(secret, encoded)
        self.assertEqual(r['changed_sections'], ['other-settings'])

    def test_invalid_or_ambiguous_inputs_are_rejected(self):
        for data in [b'rules: []\nrules: []', b'[]', b'rules: wrong',
                     b'rules: [42]', b'a: .nan', b'a: 2026-11-07',
                     b'a: &a {x: 1}\nb: {<<: *a}', b'a: &a [*a]']:
            with self.subTest(data=data), self.assertRaises((ValueError, TypeError, RecursionError)):
                m.attest(data, b'{}')

    def test_cli_parser_error_does_not_echo_source(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'private.yaml'
            f.write_text('password: [credential-marker')
            r = subprocess.run([sys.executable, str(SCRIPT), str(f), str(f)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn('credential-marker', r.stdout + r.stderr)
            self.assertEqual(r.stderr, '')
            self.assertIn('error', json.loads(r.stdout))


if __name__ == '__main__':
    unittest.main()
