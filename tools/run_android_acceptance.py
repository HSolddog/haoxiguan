"""Run native no-cloud persistence and same-certificate upgrade on a disposable AVD."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--api', type=int, required=True)
parser.add_argument('--apks', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
adb = str(sdk / 'platform-tools/adb')
package = 'com.haoxiguan.haoxiguan.acceptance'
activity = package + '/com.haoxiguan.haoxiguan.MainActivity'
args.output.mkdir(parents=True, exist_ok=True)

def command(*values, timeout=90, check=True, **kwargs):
    return subprocess.run(list(values), timeout=timeout, check=check, capture_output=True, **kwargs)

def shell(*values, timeout=90):
    return command(adb, 'shell', *values, timeout=timeout).stdout.decode()

def start_and_wait(build, phase, previous=None):
    shell('am', 'start', '-n', activity)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        report = command(adb, 'exec-out', 'run-as', package, 'cat',
                         'files/acceptance-report.json', check=False, timeout=15)
        try:
            value = json.loads(report.stdout)
            if value.get('runId') != previous and value.get('build') == str(build):
                if value.get('status') == 'failed':
                    raise RuntimeError(json.dumps(value, ensure_ascii=False))
                if value.get('status') == 'passed':
                    assert value['phase'] == phase, value
                    return value
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
        time.sleep(2)
    raise TimeoutError('native acceptance report did not complete')

image = f'system-images;android-{args.api};default;x86_64'
manager = sdk / 'cmdline-tools/latest/bin'
subprocess.run([str(manager / 'sdkmanager'), image], input='y\n' * 100,
               text=True, check=True, timeout=600)
subprocess.run([str(manager / 'avdmanager'), 'create', 'avd', '--force', '--name', 'acceptance',
                '--package', image, '--device', 'pixel_4'], input='no\n', text=True, check=True, timeout=60)
# New tools may default to a 10 GiB userdata partition, unnecessary for this fixture.
for root in [Path(os.environ.get('ANDROID_USER_HOME', str(Path.home()/'.android'))), Path.home()/'.android']:
    config = root / 'avd/acceptance.avd/config.ini'
    if config.exists():
        config.write_text(re.sub(r'disk.dataPartition.size=.*', 'disk.dataPartition.size=2G', config.read_text()))
log = (args.output/'emulator.log').open('wb')
process = subprocess.Popen([str(sdk/'emulator/emulator'), '-avd', 'acceptance', '-no-window', '-no-audio',
                            '-no-snapshot', '-no-boot-anim', '-no-metrics', '-accel', 'on',
                            '-gpu', 'swiftshader', '-memory', '1536'], stdout=log, stderr=subprocess.STDOUT)
try:
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('emulator exited; inspect emulator.log')
        r = command(adb, 'shell', 'getprop', 'sys.boot_completed', check=False, timeout=15)
        if r.stdout.strip() == b'1':
            break
        time.sleep(2)
    else:
        raise TimeoutError('emulator did not boot')
    shell('input', 'keyevent', '82')
    for setting in ['window_animation_scale', 'transition_animation_scale', 'animator_duration_scale']:
        shell('settings', 'put', 'global', setting, '0')
    results = []
    for build in (10001, 10002):
        apk = args.apks/f'acceptance-{build}.apk'
        assert apk.exists(), apk
        command(adb, 'install', '-r', str(apk), timeout=180)
        info = shell('dumpsys', 'package', package)
        assert f'versionCode={build} ' in info, 'OS package version did not change'
        value = start_and_wait(build, 'create' if build == 10001 else 'reopen',
                               results[-1]['runId'] if results else None)
        results.append(value)
        shell('am', 'force-stop', package)
        value = start_and_wait(build, 'reopen', value['runId'])
        results.append(value)
    (args.output/'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
    screenshot = command(adb, 'exec-out', 'screencap', '-p')
    (args.output/'result.png').write_bytes(screenshot.stdout)
    print(f'API {args.api}: native SQLite, crypto, Keystore, process reopen and version upgrade passed')
finally:
    diagnostic = command(adb, 'logcat', '-d', '-s', 'flutter', 'AndroidRuntime', check=False, timeout=30)
    (args.output/'runtime.log').write_bytes(diagnostic.stdout)
    process.terminate()
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
    log.close()
