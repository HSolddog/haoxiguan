"""Isolated build restoration contracts; never invokes Flutter or an SDK."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('acceptance_builder', Path(__file__).with_name('build_android_acceptance.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

REPO = Path(__file__).resolve().parent.parent


class AcceptanceBuilderTest(unittest.TestCase):
    def setup_tree(self, directory):
        root = Path(directory)
        originals = {}
        for name in ('android/app/build.gradle.kts', 'android/app/src/main/AndroidManifest.xml',
                     'android/app/src/main/kotlin/com/haoxiguan/haoxiguan/MainActivity.kt',
                     'lib/data/sqlite_habit_repository.dart'):
            path = root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            originals[path] = (REPO/name).read_bytes()
            path.write_bytes(originals[path])
        for name in ('schema2_repository.dart.txt', 'acceptance_engine_host.kt.txt'):
            path = root/'tools/fixtures'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((REPO/'tools/fixtures'/name).read_bytes())
        return root, originals

    def exercise_build(self, fail_at):
        with tempfile.TemporaryDirectory() as directory:
            root, originals = self.setup_tree(directory)
            calls = []
            def compile_stub(command, cwd, check):
                number = int(command[command.index('--build-number')+1])
                calls.append(number)
                self.assertEqual(cwd, root)
                self.assertTrue(check)
                self.assertIn('--no-pub', command)
                self.assertEqual(command[command.index('--target')+1], 'tools/android_acceptance.dart')
                self.assertIn('com.haoxiguan.haoxiguan.acceptance', (root/'android/app/build.gradle.kts').read_text('utf-8'))
                activity = (root/'android/app/src/main/kotlin/com/haoxiguan/haoxiguan/MainActivity.kt').read_text('utf-8')
                self.assertIn('override fun provideFlutterEngine', activity)
                self.assertNotIn('executeDartEntrypoint', activity)
                self.assertIn('shouldDestroyEngineWithHost(): Boolean = false', activity)
                self.assertIn('shouldRestoreAndSaveState(): Boolean = false', activity)
                repository = root/'lib/data/sqlite_habit_repository.dart'
                expected = (root/'tools/fixtures/schema2_repository.dart.txt').read_bytes() if number==10001 else originals[repository]
                self.assertEqual(repository.read_bytes(), expected)
                if number==fail_at:
                    raise subprocess.CalledProcessError(1, command)
                output = root/'build/app/outputs/flutter-apk/app-debug.apk'
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(f'synthetic host stub {number}'.encode())
            with patch.object(fixture.shutil, 'which', return_value='fixture-flutter'), patch.object(fixture.subprocess, 'run', side_effect=compile_stub):
                if fail_at:
                    with self.assertRaises(subprocess.CalledProcessError): fixture.build(root)
                else:
                    fixture.build(root)
            for path, original in originals.items(): self.assertEqual(path.read_bytes(), original, path)
            self.assertEqual(calls, [10001,10002] if fail_at!=10001 else [10001])
            self.assertEqual((root/'tools/fixtures/schema2_repository.dart.txt').read_bytes(), (REPO/'tools/fixtures/schema2_repository.dart.txt').read_bytes())

    def test_both_builds_restore_every_product_file_byte_for_byte(self):
        self.exercise_build(None)

    def test_first_or_second_build_failure_restores_every_product_file(self):
        for number in (10001,10002):
            with self.subTest(number=number): self.exercise_build(number)

    def test_unavailable_flutter_never_mutates_product_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root, originals = self.setup_tree(directory)
            with patch.object(fixture.shutil,'which',return_value=None):
                with self.assertRaises(RuntimeError):fixture.build(root)
            for path, original in originals.items():self.assertEqual(path.read_bytes(),original)

    def test_unknown_or_prepatched_activity_is_rejected_before_build(self):
        original=(REPO/'android/app/src/main/kotlin/com/haoxiguan/haoxiguan/MainActivity.kt').read_bytes()
        template=(REPO/'tools/fixtures/acceptance_engine_host.kt.txt').read_bytes()
        for bad in (original.replace(b'class MainActivity',b'class OtherActivity'), original+original,
                    original.replace(b'super.configureFlutterEngine(flutterEngine)',b'super.configureFlutterEngine(other)'),
                    fixture.isolated_activity(original,template)):
            with self.subTest(bytes=len(bad)), self.assertRaises(ValueError):fixture.isolated_activity(bad,template)


if __name__=='__main__':unittest.main()
