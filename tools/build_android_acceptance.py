"""Build two isolated, identically signed Android upgrade fixtures.
Preserve the normal APK first. Temporary source changes are restored byte for
byte, including on Windows and when a build fails, and must never be committed.
"""
from pathlib import Path
import shutil
import subprocess

def isolated_activity(original, template):
    source = original.decode('utf-8')
    marker = 'class MainActivity : FlutterActivity() {'
    configure = '        super.configureFlutterEngine(flutterEngine)'
    if source.count(marker) != 1 or source.count(configure) != 1:
        raise ValueError('acceptance host requires one exact MainActivity/configure hook')
    if 'provideFlutterEngine' in source or 'acceptanceEngineAttach' in source:
        raise ValueError('acceptance host must start from the unchanged product Activity')
    return source.replace(marker, marker + '\n' + template.decode('utf-8'), 1).replace(
        configure, configure + '\n        acceptanceEngineAttach(flutterEngine)', 1).encode('utf-8')


def build(root=Path(__file__).resolve().parent.parent):
    app = root / 'android/app/build.gradle.kts'
    manifest = root / 'android/app/src/main/AndroidManifest.xml'
    activity = root / 'android/app/src/main/kotlin/com/haoxiguan/haoxiguan/MainActivity.kt'
    repository = root / 'lib/data/sqlite_habit_repository.dart'
    originals = {path: path.read_bytes() for path in (app, manifest, activity, repository)}
    baseline = (root / 'tools/fixtures/schema2_repository.dart.txt').read_bytes()
    # Frozen from 7b3dad9; never derived from today's schema builder.
    assert 'int get schemaVersion => 2;' in baseline.decode('utf-8')
    fixture_activity = isolated_activity(originals[activity],
        (root / 'tools/fixtures/acceptance_engine_host.kt.txt').read_bytes())
    flutter = shutil.which('flutter')
    if flutter is None:
        raise RuntimeError('Flutter executable was not found on PATH')
    out = root / 'build/acceptance'
    out.mkdir(parents=True, exist_ok=True)
    try:
        app.write_bytes(originals[app].decode('utf-8').replace('applicationId = "com.haoxiguan.haoxiguan"',
                                            'applicationId = "com.haoxiguan.haoxiguan.acceptance"').encode('utf-8'))
        manifest.write_bytes(originals[manifest].decode('utf-8').replace('android:label="好习惯"', 'android:label="好习惯隔离验收"')
                            .replace('android:name=".MainActivity"', 'android:name="com.haoxiguan.haoxiguan.MainActivity"').encode('utf-8'))
        activity.write_bytes(fixture_activity)
        for number in (10001, 10002):
            repository.write_bytes(baseline if number == 10001 else originals[repository])
            subprocess.run([flutter, 'build', 'apk', '--debug', '--no-pub', '--target-platform', 'android-x64',
                            '--target', 'tools/android_acceptance.dart', '--build-number', str(number),
                            '--dart-define=ACCEPTANCE_BUILD=' + str(number)], cwd=root, check=True)
            shutil.copy2(root / 'build/app/outputs/flutter-apk/app-debug.apk', out / f'acceptance-{number}.apk')
    finally:
        for path, raw in originals.items():
            path.write_bytes(raw)


if __name__ == '__main__':
    build()
