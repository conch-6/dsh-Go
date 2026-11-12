#!/usr/bin/env python3
"""Exercise shipped shell/CI consumers with small real runtime archives."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('layer_fixtures', Path(__file__).with_name('test_runtime_layers.py'))
layers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layers)


def heredoc(text, start, end):
    return textwrap.dedent(text.split(start, 1)[1].split(end, 1)[0])


class RuntimeConsumers(unittest.TestCase):
    def setUp(self):
        self.fixture = layers.LayerPackaging()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root / 'consumers'
        self.root.mkdir()

    def run_python(self, code, *args, cwd=None):
        return subprocess.run([sys.executable, '-I', '-c', code, *map(str, args)],
                              cwd=cwd, capture_output=True, text=True)

    def test_host_selects_legacy_or_base_then_engine(self):
        text = (ROOT / 'runtime/test-host.sh').read_text()
        code = heredoc(text, 'archive_names="$(python3 -I - "$MANIFEST" <<\'PY\'\n', '\nPY\n)"')
        for layered in (False, True):
            out, _ = self.fixture.build('host-' + str(layered), layered=layered)
            manifest = self.fixture.manifest(out)
            result = self.run_python(code, out / 'manifest.json')
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = ([manifest['layers'][name]['asset'] for name in ('base', 'engine')]
                        if layered else [manifest['rootfs']])
            self.assertEqual(result.stdout.splitlines(), expected)
        bad = self.root / 'unknown.json'
        bad.write_text('{"schema": 99}')
        self.assertNotEqual(self.run_python(code, bad).returncode, 0)

    def test_index_preserves_legacy_then_layered_format(self):
        text = (ROOT / 'runtime/build-runtime.sh').read_text()
        code = heredoc(text, 'python3 -I - "$OUT" <<\'PYEOF\'\n', '\nPYEOF')
        target = self.root / 'arm64-v8a/assets/runtime'
        target.mkdir(parents=True)
        for layered in (False, True):
            out, _ = self.fixture.build('index-' + str(layered), layered=layered)
            manifest = self.fixture.manifest(out)
            (target / 'manifest.json').write_text(json.dumps(manifest))
            result = self.run_python(code, self.root)
            self.assertEqual(result.returncode, 0, result.stderr)
            index = json.loads((self.root / 'manifest.json').read_text())
            self.assertEqual(index['schema'], 2 if layered else 1)
            current = index['abis']['arm64-v8a']
            if layered:
                self.assertEqual(current['schema'], 2)
                self.assertEqual(set(current['layers']), {'base', 'engine'})
                self.assertIn('baseCompatibility', current)
                self.assertNotIn('rootfs', current)
                self.assertNotIn('rootfsSha256', current)
            else:
                self.assertEqual(current['rootfs'], manifest['rootfs'])
                self.assertEqual(current['rootfsSha256'], manifest['rootfsSha256'])

    def test_host_and_direct_unpack_all_archives_from_another_directory(self):
        text = (ROOT / 'runtime/test-host.sh').read_text()
        first = text.split('mapfile -t archives <<< "$archive_names"\n', 1)[1].split('\nmapfile -t GUEST', 1)[0]
        direct = text.split('  chmod 0755 "$DIRECT_ROOT"\n', 1)[1].split('  if bash "$HERE/tests/direct/run-tests.sh"', 1)[0]
        for layered in (False, True):
            out, _ = self.fixture.build('direct assets ' + str(layered), layered=layered)
            manifest = self.fixture.manifest(out)
            names = ([manifest['layers'][name]['asset'] for name in ('base', 'engine')]
                     if layered else [manifest['rootfs']])
            host_root = self.root / ('host ' + str(layered))
            direct_root = self.root / ('direct ' + str(layered))
            direct_root.mkdir()
            env = dict(os.environ, MANIFEST=str(out / 'manifest.json'), ROOT=str(host_root),
                       DIRECT_ROOT=str(direct_root))
            result = subprocess.run(['bash', '-e', '-c', 'archives=("$@")\n' + first + direct,
                                     'runtime-unpack-test', *names], env=env, cwd=self.root,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for tree in (host_root, direct_root):
                self.assertEqual((tree / 'usr/lib/fixture').read_text(), 'base content')
                self.assertEqual((tree / 'opt/dsh/node_modules/example/index.js').read_text(),
                                 'synthetic engine input')

    def test_build_arguments_keep_default_and_quote_paths(self):
        text = (ROOT / 'runtime/build-runtime.sh').read_text()
        code = text.split('  local -a archives=', 1)[1].split('  local -a prune=', 1)[0]
        code = 'build_args() {\n  local -a archives=' + code + '\nprintf "%s\\n" "${archive_args[@]}";\n}\nbuild_args'
        env = dict(os.environ, assets=str(self.root / 'assets with spaces'), abi='arm64-v8a',
                   COMPRESS='xz', BASE_LAYER_CACHE=str(self.root / 'cache with spaces'))
        for mode in ('0', '1'):
            env['RUNTIME_LAYERS'] = mode
            result = subprocess.run(['bash', '-c', code], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = result.stdout.splitlines()
            if mode == '0':
                self.assertEqual(args, ['--out', env['assets'] + '/rootfs-arm64-v8a.tar.xz'])
            else:
                self.assertEqual(args, ['--base-out', env['assets'] + '/base-arm64-v8a.tar.xz',
                                        '--engine-out', env['assets'] + '/engine-arm64-v8a.tar.xz',
                                        '--base-cache', env['BASE_LAYER_CACHE']])
        env['RUNTIME_LAYERS'] = 'invalid'
        result = subprocess.run(['bash', str(ROOT / 'runtime/build-runtime.sh')], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RUNTIME_LAYERS', result.stderr)


if __name__ == '__main__':
    unittest.main()
