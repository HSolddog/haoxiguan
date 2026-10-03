"""Build two isolated, identically signed Android upgrade fixtures.
Preserve the normal APK first. Temporary source changes are restored byte for
byte, including on Windows and when a build fails, and must never be committed.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / 'android/app/build.gradle.kts'
manifest = root / 'android/app/src/main/AndroidManifest.xml'
original_app, original_manifest = app.read_bytes(), manifest.read_bytes()
repository = root / 'lib/data/sqlite_habit_repository.dart'
original_repository = repository.read_bytes()
baseline = (root / 'tools/fixtures/schema2_repository.dart.txt').read_bytes()
# This is frozen from 7b3dad9, not generated from today's schema builder.
assert 'int get schemaVersion => 2;' in baseline.decode('utf-8')
flutter = shutil.which('flutter')
if flutter is None:
    raise RuntimeError('Flutter executable was not found on PATH')
out = root / 'build/acceptance'
out.mkdir(parents=True, exist_ok=True)
try:
    app.write_bytes(original_app.decode('utf-8').replace('applicationId = "com.haoxiguan.haoxiguan"',
                                        'applicationId = "com.haoxiguan.haoxiguan.acceptance"').encode('utf-8'))
    manifest.write_bytes(original_manifest.decode('utf-8').replace('android:label="好习惯"', 'android:label="好习惯隔离验收"')
                        .replace('android:name=".MainActivity"', 'android:name="com.haoxiguan.haoxiguan.MainActivity"').encode('utf-8'))
    for number in (10001, 10002):
        repository.write_bytes(baseline if number == 10001 else original_repository)
        subprocess.run([flutter, 'build', 'apk', '--debug', '--no-pub', '--target-platform', 'android-x64',
                        '--target', 'tools/android_acceptance.dart', '--build-number', str(number),
                        '--dart-define=ACCEPTANCE_BUILD=' + str(number)], cwd=root, check=True)
        shutil.copy2(root / 'build/app/outputs/flutter-apk/app-debug.apk', out / f'acceptance-{number}.apk')
finally:
    app.write_bytes(original_app)
    manifest.write_bytes(original_manifest)
    repository.write_bytes(original_repository)
