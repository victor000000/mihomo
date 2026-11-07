import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('docs', Path(__file__).resolve().parents[2] / 'tools/Check-Docs.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class DocumentationChecks(unittest.TestCase):
    def test_missing_target_and_anchor_are_reported(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'README.md').write_text('[absent](absent.md)\n[bad](#absent)', encoding='utf-8')
            r = m.check(p)
            self.assertEqual(len(r['errors']), 2)

    def test_duplicate_unicode_headings_and_escaped_paths(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'other page.md').write_text('# Setup\n# Setup\n## 数据', encoding='utf-8')
            (p / 'README.md').write_text('[ok](other%20page.md#setup-1)\n[ok](other%20page.md#数据)', encoding='utf-8')
            self.assertFalse(m.check(p)['errors'])

    def test_fenced_examples_and_external_urls_are_not_checked(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'README.md').write_text('```md\n[example](absent)\n```\n[out](https://example.test/path)', encoding='utf-8')
            r = m.check(p)
            self.assertEqual(r['local_links'], 0)
            self.assertFalse(r['errors'])

    def test_parent_escape_and_empty_inventory_fail(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            self.assertTrue(m.check(p)['errors'])
            (p / 'README.md').write_text('[outside](../private.md)', encoding='utf-8')
            self.assertIn('leaves repository', m.check(p)['errors'][0])

    def test_current_only_scope_excludes_historical_links_explicitly(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'docs/verification').mkdir(parents=True)
            (p / 'README.md').write_text('# Current', encoding='utf-8')
            (p / 'docs/verification/old.md').write_text('[old](removed-source.ps1)', encoding='utf-8')
            self.assertTrue(m.check(p)['errors'])
            self.assertFalse(m.check(p, current_only=True)['errors'])

    def test_published_documentation_has_no_broken_inline_local_links(self):
        self.assertEqual(m.check(Path(__file__).resolve().parents[2])['errors'], [])


if __name__ == '__main__':
    unittest.main()
