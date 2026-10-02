"""Run native no-cloud persistence and same-certificate upgrade on a disposable AVD."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

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
# Command-line tools and the emulator otherwise inherit different AVD roots on
# hosted runners. Keep every selector explicit and outside uploaded evidence.
android_user = (Path.cwd() / 'build/android-acceptance-user').resolve()
(android_user/'avd').mkdir(parents=True, exist_ok=True)
os.environ['ANDROID_USER_HOME'] = str(android_user)
os.environ['ANDROID_EMULATOR_HOME'] = str(android_user)
os.environ['ANDROID_AVD_HOME'] = str(android_user/'avd')

def command(*values, timeout=90, check=True, **kwargs):
    return subprocess.run(list(values), timeout=timeout, check=check, capture_output=True, **kwargs)

def shell(*values, timeout=90):
    return command(adb, 'shell', *values, timeout=timeout).stdout.decode()

oversize_ready = set()
background_requested = set()

def drive_document_picker(value):
    # Only the isolated fixture's requested picker is driven. Never tap the app
    # or a permission prompt by approximate screen coordinates.
    stage = value.get('stage')
    if stage == 'awaitingBackgroundReschedule':
        if value['runId'] not in background_requested:
            jobs = shell('dumpsys', 'jobscheduler')
            matches = re.findall(r'JOB #[^/\s]+/(\d+):[^\n]*' + re.escape(package) +
                                 r'/androidx\.work\.impl\.background\.systemjob\.SystemJobService', jobs)
            (args.output/'workmanager-jobs.txt').write_text('\n'.join(
                line for line in jobs.splitlines() if package in line))
            if matches:
                for job in set(matches):
                    command(adb, 'shell', 'cmd', 'jobscheduler', 'run', '-f', '-u', '0', package, job, check=False)
                background_requested.add(value['runId'])
        return
    if stage not in ('awaitingDocumentSave', 'awaitingDocumentOpen', 'awaitingOversizeSave', 'awaitingOversizeOpen'):
        return
    if stage == 'awaitingOversizeOpen' and value['runId'] not in oversize_ready:
        name = value['documentName']
        assert re.fullmatch(r'hgw-oversize-\d+\.hgb', name)
        path = '/sdcard/Download/' + name
        assert shell('stat', '-c', '%s', path).strip().isdigit(), 'SAF fixture must exist first'
        shell('dd', 'if=/dev/zero', 'of=' + path, 'bs=1048576', 'count=51')
        assert shell('stat', '-c', '%s', path).strip() == str(51*1024*1024)
        oversize_ready.add(value['runId'])
    shell('uiautomator', 'dump', '/sdcard/acceptance-ui.xml', timeout=25)
    xml = shell('cat', '/sdcard/acceptance-ui.xml')
    (args.output/'document-picker.xml').write_text(xml)
    try:
        nodes = [n for n in ET.fromstring(xml).iter('node')
                 if 'documentsui' in n.get('package', '') and n.get('enabled') == 'true']
    except ET.ParseError:
        return
    def tap(node):
        bounds = [int(x) for x in re.findall(r'\d+', node.get('bounds', ''))]
        if len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1]:
            shell('input', 'tap', str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2))
            return True
        return False
    if stage in ('awaitingDocumentSave', 'awaitingOversizeSave'):
        for node in nodes:
            if node.get('text', '').upper() == 'SAVE' and tap(node):
                return
    else:
        # Android 7 defaults to a grid whose nameplate is not the item's open
        # target. Use the document list before selecting an exact filename.
        for node in nodes:
            if node.get('content-desc') == 'List view' and tap(node):
                return
        for node in nodes:
            if node.get('text') == value['documentName'] and tap(node):
                return
        for node in nodes:
            if node.get('text', '').upper() == 'OPEN' and tap(node):
                return
    for node in nodes:
        if node.get('text') == 'Downloads' and tap(node):
            return
    for node in nodes:
        if node.get('content-desc') in ('Show roots', 'Show navigation drawer') and tap(node):
            return

def start_and_wait(build, phase, previous=None):
    shell('am', 'start', '-n', activity)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        report = command(adb, 'exec-out', 'run-as', package, 'cat',
                         'files/acceptance-report.json', check=False, timeout=15)
        try:
            value = json.loads(report.stdout)
            (args.output/'last-report.json').write_text(json.dumps(value, ensure_ascii=False, indent=2))
            if value.get('runId') != previous and value.get('build') == str(build):
                if value.get('status') == 'failed':
                    raise RuntimeError(json.dumps(value, ensure_ascii=False))
                if value.get('status') == 'passed':
                    assert value['phase'] == phase, value
                    assert value['schema'] == (2 if build == 10001 else 3), value
                    if build == 10002:
                        assert all(value[k] for k in ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit',
                                                     'nativeReminderScheduling', 'workManagerRenewal')), value
                    return value
                drive_document_picker(value)
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
        time.sleep(2)
    raise TimeoutError('native acceptance report did not complete')

image = f'system-images;android-{args.api};default;x86_64'
manager = sdk / 'cmdline-tools/latest/bin'
subprocess.run([str(manager / 'sdkmanager'), 'emulator', 'platform-tools', image], input='y\n' * 100,
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
        try:
            r = command(adb, 'shell', 'getprop', 'sys.boot_completed', check=False, timeout=15)
        except subprocess.TimeoutExpired:
            continue
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
        if args.api >= 33:
            shell('pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
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
    print(f'API {args.api}: SQLite, crypto, Keystore, process reopen, schema upgrade and bounded SAF save/open passed')
finally:
    try:
        diagnostic = command(adb, 'logcat', '-d', '-s', 'flutter', 'AndroidRuntime', check=False, timeout=15)
        (args.output/'runtime.log').write_bytes(diagnostic.stdout)
    except subprocess.TimeoutExpired:
        (args.output/'runtime.log').write_text('adb logcat timed out; inspect emulator.log')
    try:
        (args.output/'last-screen.png').write_bytes(command(adb, 'exec-out', 'screencap', '-p', timeout=15).stdout)
    except subprocess.TimeoutExpired:
        pass
    process.terminate()
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
    log.close()
