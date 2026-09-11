import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import bergfex as b

BOOTSTRAP = json.loads((Path(__file__).parent / 'HelperLaunch.js').read_text().split('var bootstrap = ', 1)[1].split('\n', 1)[0])

class WriteSecurityTests(unittest.TestCase):
    def test_symlink_parent_and_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            actual = root / 'actual'
            actual.mkdir()
            target = actual / 'data.json'
            target.write_text('untouched')
            link = root / 'link'
            link.symlink_to(actual, target_is_directory=True)
            with self.assertRaises(OSError): b.atomic_json(link / 'data.json', {})
            link.unlink()
            link.symlink_to(target)
            with self.assertRaises(ValueError): b.atomic_json(link, {})
            self.assertEqual(target.read_text(), 'untouched')

    def test_unprotected_parent_and_size_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o777)
            with self.assertRaises(ValueError): b.atomic_json(root / 'data.json', {})
            root.chmod(0o700)
            with patch.object(b, 'protected_directory') as directory:
                with self.assertRaises(ValueError): b.atomic_json(root / 'data.json', {'x': 'a'*100}, limit=20)
                directory.assert_not_called()

    def test_parent_swap_does_not_redirect_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = root / 'original'
            original.mkdir()
            elsewhere = root / 'elsewhere'
            elsewhere.mkdir()
            (elsewhere / 'data.json').write_text('untouched')
            replace = os.replace
            def swap(src, dst, **kwargs):
                original.rename(root / 'moved')
                original.symlink_to(elsewhere, target_is_directory=True)
                return replace(src, dst, **kwargs)
            with patch.object(b.os, 'replace', side_effect=swap):
                b.atomic_json(original / 'data.json', {'ok': True})
            self.assertEqual((elsewhere / 'data.json').read_text(), 'untouched')
            self.assertEqual(json.loads((root / 'moved/data.json').read_text()), {'ok': True})
            self.assertEqual(list((root / 'moved').glob('.tmp-*')), [])

class HelperSecurityTests(unittest.TestCase):
    def launch(self, helper, env=None):
        return subprocess.run(['/usr/bin/timeout', '--kill-after=0.2s', '2s', '/usr/bin/python3', '-I', '-c', BOOTSTRAP, str(helper)], env=env, capture_output=True, timeout=4)

    def test_shadow_python_and_pythonpath_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plugin = root / 'io.github.jwm3000.bergfex-weather'
            plugin.mkdir()
            helper = plugin / 'bergfex.py'
            helper.write_text('print("trusted")')
            (root / 'python3').write_text('#!/bin/sh\necho SHADOW\n')
            (root / 'python3').chmod(0o755)
            (root / 'sitecustomize.py').write_text('raise RuntimeError("injected")')
            env = dict(os.environ, PATH=str(root), PYTHONPATH=str(root))
            result = self.launch(helper, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), b'trusted')

    def test_helper_symlink_fifo_and_writable_file_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plugin = root / 'io.github.jwm3000.bergfex-weather'
            plugin.mkdir()
            helper = plugin / 'bergfex.py'
            target = root / 'target.py'
            target.write_text('print("executed")')
            helper.symlink_to(target)
            self.assertNotEqual(self.launch(helper).returncode, 0)
            helper.unlink()
            os.mkfifo(helper)
            self.assertNotEqual(self.launch(helper).returncode, 0)
            helper.unlink()
            helper.write_text('print("executed")')
            helper.chmod(0o666)
            self.assertNotEqual(self.launch(helper).returncode, 0)

    def test_watchdog_kills_term_ignoring_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            plugin = Path(tmp) / 'io.github.jwm3000.bergfex-weather'
            plugin.mkdir()
            helper = plugin / 'bergfex.py'
            helper.write_text('import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)')
            start = time.monotonic()
            result = self.launch(helper)
            self.assertEqual(result.returncode, -9)
            self.assertLess(time.monotonic() - start, 4)

if __name__ == '__main__': unittest.main()
