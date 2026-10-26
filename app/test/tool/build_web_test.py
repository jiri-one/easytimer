import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WebBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='easytimer-web-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        (self.app / 'tool').mkdir(parents=True)
        shutil.copyfile(Path(__file__).parents[2] / 'tool/build_web.sh',
                        self.app / 'tool/build_web.sh')
        (self.root / 'LICENSE').write_text('GNU GENERAL PUBLIC LICENSE')
        (self.root / 'NOTICE').write_text('Notices')
        (self.root / 'packaging/licenses').mkdir(parents=True)
        (self.root / 'packaging/licenses/interval-timer-MIT.txt').write_text('MIT')
        (self.app / 'assets/licenses').mkdir(parents=True)
        (self.app / 'assets/licenses/EasyTimer-GPL-3.0.txt').write_text('GPL')
        (self.app / 'assets/licenses/MaterialIcons-Apache-2.0.txt').write_text('Apache')
        self.renderer = self.app / 'build/web/canvaskit'
        self.renderer.mkdir(parents=True)
        for name in ('canvaskit.js', 'canvaskit.wasm', 'skwasm.js',
                     'skwasm.wasm', 'skwasm_heavy.js', 'webparagraph', 'test.symbols'):
            (self.renderer / name).touch()
        assets = self.app / 'build/web/assets'
        assets.mkdir()
        (assets / 'DroidSansMono.ttf').touch()
        self.manifest = assets / 'FontManifest.json'
        self.fonts = [{'family': family, 'fonts': [{'asset': 'DroidSansMono.ttf'}]}
                      for family in ('Roboto', 'DroidSansMono')]
        self.manifest.write_text(json.dumps(self.fonts))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        flutter = self.bin / 'flutter'
        flutter.write_text('#!/bin/sh\nexit 0\n')
        flutter.chmod(0o755)

    def build(self, *args):
        import os
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        return subprocess.run(['sh', str(self.app / 'tool/build_web.sh'), *args],
                              env=env, capture_output=True, text=True)

    def test_javascript_keeps_canvaskit_and_local_fonts_and_licences(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.renderer / 'canvaskit.wasm').is_file())
        self.assertFalse((self.renderer / 'skwasm.wasm').exists())
        self.assertFalse((self.renderer / 'test.symbols').exists())
        licences = self.app / 'build/web/licenses'
        self.assertTrue((licences / 'EasyTimer-GPL-3.0.txt').is_file())
        self.assertTrue((licences / 'MaterialIcons-Apache-2.0.txt').is_file())
        self.assertEqual(json.loads(self.manifest.read_text()), self.fonts)

    def test_wasm_keeps_skwasm_and_javascript_fallback(self):
        result = self.build('--wasm')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.renderer / 'skwasm.wasm').is_file())
        self.assertTrue((self.renderer / 'skwasm.js').is_file())
        self.assertTrue((self.renderer / 'skwasm_heavy.js').is_file())
        self.assertTrue((self.renderer / 'canvaskit.wasm').is_file())
        self.assertFalse((self.renderer / 'test.symbols').exists())

    def test_material_icon_font_is_rejected(self):
        self.manifest.write_text(json.dumps(self.fonts + [
            {'family': 'MaterialIcons', 'fonts': []}]))
        self.assertNotEqual(self.build().returncode, 0)

    def test_changed_default_font_alias_is_rejected(self):
        self.fonts[0]['fonts'] = []
        self.manifest.write_text(json.dumps(self.fonts))
        self.assertNotEqual(self.build().returncode, 0)
