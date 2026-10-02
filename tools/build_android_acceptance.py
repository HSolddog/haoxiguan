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
out = root / 'build/acceptance'
out.mkdir(parents=True, exist_ok=True)
try:
    app.write_text(original_app.replace('applicationId = "com.haoxiguan.haoxiguan"',
                                        'applicationId = "com.haoxiguan.haoxiguan.acceptance"'))
    manifest.write_text(original_manifest.replace('android:label="好习惯"', 'android:label="好习惯隔离验收"')
                        .replace('android:name=".MainActivity"', 'android:name="com.haoxiguan.haoxiguan.MainActivity"'))
    for number in (10001, 10002):
        subprocess.run(['flutter', 'build', 'apk', '--debug', '--target-platform', 'android-x64',
                        '--target', 'tools/android_acceptance.dart', '--build-number', str(number),
                        '--dart-define=ACCEPTANCE_BUILD=' + str(number)], cwd=root, check=True)
        shutil.copy2(root / 'build/app/outputs/flutter-apk/app-debug.apk', out / f'acceptance-{number}.apk')
finally:
    app.write_text(original_app)
    manifest.write_text(original_manifest)
