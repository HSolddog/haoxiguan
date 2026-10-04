"""Build two disposable schema-3 SyncScreen APKs without changing product files.

Run after the normal debug APK and the frozen schema-2 upgrade fixtures. Only
debug signing is used; no signing credentials or runtime invitations enter APKs.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent
PACKAGES = {
    'A': 'com.haoxiguan.haoxiguan.syncacceptance.a',
    'B': 'com.haoxiguan.haoxiguan.syncacceptance.b',
}
BUILD_NUMBERS = {'A': 11001, 'B': 11002}


def replace_once(value, old, new):
    if value.count(old) != 1:
        raise ValueError('expected exactly one product application ID/activity')
    return value.replace(old, new)


def build(flutter, root=ROOT, output=None):
    root = Path(root)
    output = Path(output) if output is not None else root / 'build/sync-acceptance'
    app = root / 'android/app/build.gradle.kts'
    manifest = root / 'android/app/src/main/AndroidManifest.xml'
    repository = root / 'lib/data/sqlite_habit_repository.dart'
    originals = {path: path.read_bytes() for path in (app, manifest, repository)}
    if not re.search(rb'\bint get schemaVersion\s*=>\s*3;', originals[repository]):
        raise ValueError('native sync fixtures require the product schema-3 repository')
    label = re.compile(rb'android:label="[^"\r\n]*"')
    if len(label.findall(originals[manifest])) != 1:
        raise ValueError('expected exactly one product application label')
    # Validate before making the first temporary write.
    replace_once(originals[app], b'applicationId = "com.haoxiguan.haoxiguan"', b'')
    replace_once(originals[manifest], b'android:name=".MainActivity"', b'')
    output.mkdir(parents=True, exist_ok=True)
    try:
        for role, package in PACKAGES.items():
            app.write_bytes(replace_once(
                originals[app], b'applicationId = "com.haoxiguan.haoxiguan"',
                f'applicationId = "{package}"'.encode()))
            patched_manifest = replace_once(
                originals[manifest], b'android:name=".MainActivity"',
                b'android:name="com.haoxiguan.haoxiguan.MainActivity"')
            patched_manifest = label.sub(
                f'android:label="Haoxiguan Sync Acceptance {role}"'.encode(), patched_manifest)
            manifest.write_bytes(patched_manifest)
            # This fixture must always use today's default SQLite implementation.
            repository.write_bytes(originals[repository])
            subprocess.run([
                flutter, 'build', 'apk', '--debug', '--no-pub',
                '--target-platform', 'android-x64', '--target',
                'tools/android_sync_acceptance.dart', '--build-number',
                str(BUILD_NUMBERS[role]),
                '--dart-define=SYNC_ACCEPTANCE_BUILD=' + str(BUILD_NUMBERS[role]),
                '--dart-define=SYNC_ACCEPTANCE_PACKAGE=' + package,
            ], cwd=root, check=True, timeout=1200)
            shutil.copy2(root / 'build/app/outputs/flutter-apk/app-debug.apk',
                         output / f'sync-acceptance-{role.lower()}.apk')
    finally:
        # Byte restoration also preserves CRLF/BOM/non-ASCII labels on Windows.
        # Try every restoration even when one path becomes unwritable.
        failures = []
        for path, content in originals.items():
            try:
                path.write_bytes(content)
            except OSError as error:
                failures.append(error)
        if failures:
            raise RuntimeError('could not restore temporary sync build files') from failures[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=shutil.which('flutter'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    if not args.flutter:
        parser.error('Flutter executable was not found on PATH')
    build(args.flutter, output=args.output)


if __name__ == '__main__':
    main()
