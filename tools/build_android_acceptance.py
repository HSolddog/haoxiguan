"""Build two isolated, identically signed Android upgrade fixtures in CI.
Run after the normal APK is already uploaded. Changes to Android identity stay
inside the disposable CI checkout and are never committed to the repository.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / 'android/app/build.gradle.kts'
manifest = root / 'android/app/src/main/AndroidManifest.xml'
original_app, original_manifest = app.read_text(), manifest.read_text()
repository = root / 'lib/data/sqlite_habit_repository.dart'
original_repository = repository.read_text()
baseline = (root / 'tools/fixtures/schema2_repository.dart.txt').read_bytes()
# This is frozen from 7b3dad9, not generated from today's schema builder.
assert 'int get schemaVersion => 2;' in baseline.decode()
out = root / 'build/acceptance'
out.mkdir(parents=True, exist_ok=True)
try:
    app.write_text(original_app.replace('applicationId = "com.haoxiguan.haoxiguan"',
                                        'applicationId = "com.haoxiguan.haoxiguan.acceptance"'))
    manifest.write_text(original_manifest.replace('android:label="好习惯"', 'android:label="好习惯隔离验收"')
                        .replace('android:name=".MainActivity"', 'android:name="com.haoxiguan.haoxiguan.MainActivity"'))
    for number in (10001, 10002):
        repository.write_text(baseline.decode() if number == 10001 else original_repository)
        subprocess.run(['flutter', 'build', 'apk', '--debug', '--target-platform', 'android-x64',
                        '--target', 'tools/android_acceptance.dart', '--build-number', str(number),
                        '--dart-define=ACCEPTANCE_BUILD=' + str(number)], cwd=root, check=True)
        shutil.copy2(root / 'build/app/outputs/flutter-apk/app-debug.apk', out / f'acceptance-{number}.apk')
finally:
    app.write_text(original_app)
    manifest.write_text(original_manifest)
    repository.write_text(original_repository)
