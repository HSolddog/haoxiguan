"""Run native no-cloud persistence and same-certificate upgrade on a disposable AVD."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import traceback
import xml.etree.ElementTree as ET

package = 'com.haoxiguan.haoxiguan.acceptance'
activity = package + '/com.haoxiguan.haoxiguan.MainActivity'
process = None


def event(kind, **fields):
    with (args.output/'driver-events.jsonl').open('a', encoding='utf-8') as evidence:
        evidence.write(json.dumps({'event': kind, 'time': time.monotonic(), **fields}) + '\n')


def require_emulator(stage):
    code = process.poll()
    if code is not None:
        event('emulator-exited', stage=stage, exit=code)
        raise RuntimeError(f'emulator exited with status {code} during {stage}; inspect emulator.log')


def wait_for_reopen(timeout=45):
    """Observe a completed force-stop and two healthy reads before one launch.

    Never repeat am start/force-stop: even a closed ADB connection may have
    delivered the mutation. Persistent disconnection or an exited AVD fails.
    """
    deadline = time.monotonic() + timeout
    failure = 'force-stop did not reach a stable Android framework with the package marked stopped'

    def read(*values):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(failure)
        return command(adb, 'shell', *values, check=False, timeout=min(5, remaining))

    stable = 0
    while time.monotonic() < deadline:
        require_emulator('force-stop readiness')
        ready = False
        try:
            boot = read('getprop', 'sys.boot_completed')
            service = read('service', 'check', 'activity')
            installed = read('dumpsys', 'package', package)
            stopped = re.search(r'User 0:[^\n]*\bstopped=true\b', installed.stdout.decode(errors='replace'))
            ready = (all(r.returncode == 0 for r in (boot, service, installed)) and
                     boot.stdout.strip() == b'1' and b'Service activity: found' in service.stdout and
                     bool(stopped))
        except subprocess.TimeoutExpired:
            pass
        stable = stable + 1 if ready else 0
        event('force-stop-readiness', ready=ready, consecutive=stable)
        if stable == 2:
            return
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    raise TimeoutError(failure)

def adb_values(*values):
    return [adb, '-s', adb_serial, *values]


def require_unused_serial():
    # The only untargeted ADB operation is a read-only inventory before launch.
    devices = subprocess.run([adb, 'devices'], timeout=15, check=True, capture_output=True)
    if any(line.split() and line.split()[0] == adb_serial
           for line in devices.stdout.decode(errors='replace').splitlines()):
        raise RuntimeError(f'{adb_serial} is already present; choose a different isolated --port')


def command(*values, timeout=90, check=True, **kwargs):
    if values and str(values[0]) == adb:
        values = adb_values(*values[1:])
    try:
        result = subprocess.run(list(values), timeout=timeout, check=False, capture_output=True, **kwargs)
    except subprocess.TimeoutExpired:
        event('command-timeout', command=[str(v) for v in values], timeout=timeout)
        raise
    if result.returncode:
        event('command-failed', command=[str(v) for v in values], exit=result.returncode,
              stdout=result.stdout.decode(errors='replace')[:4000],
              stderr=result.stderr.decode(errors='replace')[:4000])
    if check:
        result.check_returncode()
    return result

def shell(*values, timeout=90):
    # ADB occasionally closes a shell with status 255 on a busy AVD. Retry only
    # reads, never input/installation/writes that could duplicate an action.
    attempts = 3 if values and values[0] in ('stat', 'dumpsys', 'cat', 'getprop') else 1
    for attempt in range(attempts):
        result = command(adb, 'shell', *values, timeout=timeout, check=False)
        if result.returncode == 0:
            return result.stdout.decode()
        with (args.output/'adb-read-errors.jsonl').open('a') as evidence:
            evidence.write(json.dumps({'command': values[0], 'exit': result.returncode,
                                       'attempt': attempt + 1, 'stdoutBytes': len(result.stdout),
                                       'stderr': result.stderr.decode(errors='replace')[:2000]}) + '\n')
        if result.returncode != 255 or attempt + 1 == attempts:
            result.check_returncode()
        time.sleep(0.5)

oversize_ready = set()
background_requested = set()
environment_events = []

def drive_document_picker(value):
    # Only the isolated fixture's requested picker is driven. Never tap the app
    # or a permission prompt by approximate screen coordinates.
    stage = value.get('stage')
    if stage == 'awaitingBackgroundReschedule':
        if value['runId'] not in background_requested:
            background_requested.add(value['runId'])
            # This is optional evidence, not the test's success condition. Android
            # 16 dumpsys can exit 255 while WorkManager mutates the job list.
            # The fixture must still report renewal + periodic registration.
            try:
                diagnostic = command(adb, 'shell', 'dumpsys', 'jobscheduler', check=False, timeout=15)
                jobs = diagnostic.stdout.decode(errors='replace')
                (args.output/'workmanager-jobs.txt').write_text('\n'.join(
                    line for line in jobs.splitlines() if package in line))
                if diagnostic.returncode:
                    (args.output/'workmanager-diagnostic.txt').write_text(
                        f'dumpsys exit {diagnostic.returncode}\n' + diagnostic.stderr.decode(errors='replace'))
            except subprocess.TimeoutExpired:
                (args.output/'workmanager-diagnostic.txt').write_text('dumpsys timed out; application assertions still required\n')
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
        all_nodes = list(ET.fromstring(xml).iter('node'))
    except ET.ParseError:
        return
    def tap(node, hold=False):
        bounds = [int(x) for x in re.findall(r'\d+', node.get('bounds', ''))]
        if len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1]:
            x, y = str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2)
            if hold:
                shell('input', 'swipe', x, y, x, y, '900')
            else:
                shell('input', 'tap', x, y)
            return True
        return False
    # AOSP's launcher occasionally ANRs during a fresh headless boot. Record
    # and close that exact system dialog once; never dismiss an app/other ANR.
    if any(n.get('resource-id') == 'android:id/alertTitle' and
           n.get('text') == "Quickstep isn't responding" for n in all_nodes):
        if environment_events:
            raise RuntimeError('repeated AOSP launcher ANR; emulator is unhealthy')
        (args.output/'launcher-anr.xml').write_text(xml)
        (args.output/'launcher-anr.png').write_bytes(command(adb, 'exec-out', 'screencap', '-p').stdout)
        for node in all_nodes:
            if node.get('resource-id') == 'android:id/aerr_close' and tap(node):
                environment_events.append({'event': 'closed AOSP Quickstep ANR', 'runId': value['runId']})
                (args.output/'environment-events.json').write_text(json.dumps(environment_events, indent=2))
                print('Recorded and closed one AOSP Quickstep ANR in disposable AVD', flush=True)
                return
    nodes = [n for n in all_nodes if 'documentsui' in n.get('package', '') and n.get('enabled') == 'true']
    # API 24 can expose obscured controls in its accessibility tree while the
    # IME still consumes their screen coordinates. Dismiss only a visible IME
    # owned by DocumentsUI; an unconditional Back would cancel the picker.
    if nodes:
        ime = shell('dumpsys', 'input_method')
        # mIsInputViewShown remains true on API 24 even after its window hides.
        if re.search(r'\bmInputShown=true\b', ime):
            shell('input', 'keyevent', '4')
            return
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
            if node.get('text', '').upper() == 'OPEN' and tap(node):
                return
        for node in nodes:
            # API 24's single-tap activation can be ignored by DocumentsUI.
            # Its supported selection + OPEN flow has an explicit state change.
            if node.get('text') == value['documentName'] and tap(node, hold=args.api == 24):
                return
    for node in nodes:
        if node.get('text') == 'Downloads' and tap(node):
            return
    for node in nodes:
        if node.get('content-desc') in ('Show roots', 'Show navigation drawer') and tap(node):
            return

def start_and_wait(build, phase, previous=None):
    require_emulator(f'{build}/{phase} launch')
    event('launch', build=build, phase=phase, previous=previous)
    shell('am', 'start', '-n', activity)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        require_emulator(f'{build}/{phase} report')
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
                                                     'nativeReminderScheduling', 'workManagerRenewal',
                                                     'periodicTasksRegistered')), value
                    return value
                drive_document_picker(value)
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
        time.sleep(2)
    raise TimeoutError('native acceptance report did not complete')

def diagnostic(label, action):
    """Evidence collection must never replace the primary acceptance failure."""
    try:
        action()
    except Exception as error:
        try:
            event('diagnostic-failed', diagnostic=label, type=type(error).__name__, message=str(error))
        except Exception:
            print(f'Diagnostic {label} failed: {error}', flush=True)


def stop_process(target):
    if target is None or target.poll() is not None:
        return
    target.terminate()
    try:
        target.wait(timeout=10)
    except subprocess.TimeoutExpired:
        target.kill()
        target.wait(timeout=5)


def collect_diagnostics(emulator, log, runtime_process=None, runtime_log=None):
    diagnostic('emulator-status', lambda: event('emulator-status', pid=emulator.pid, exit=emulator.poll()))
    diagnostic('adb-status', lambda: (args.output/'adb-status.txt').write_bytes(
        command(adb, 'get-state', timeout=5).stdout))
    diagnostic('runtime', lambda: (args.output/'runtime.log').write_bytes(command(
        adb, 'logcat', '-d', '-s', 'flutter', 'AndroidRuntime', 'ActivityManager',
        'libc', 'DEBUG', 'lowmemorykiller', 'WM-WorkerWrapper', 'WM-SystemJobService', timeout=10).stdout))
    diagnostic('last-screen', lambda: (args.output/'last-screen.png').write_bytes(
        command(adb, 'exec-out', 'screencap', '-p', timeout=10).stdout))
    # Host memory is useful for investigating abrupt hosted-AVD exits; this
    # reads no process environments, command lines, credentials or user files.
    if Path('/proc/meminfo').exists():
        diagnostic('host-memory', lambda: (args.output/'host-memory.txt').write_bytes(Path('/proc/meminfo').read_bytes()))
    diagnostic('stop-logcat', lambda: stop_process(runtime_process))
    diagnostic('stop-emulator', lambda: stop_process(emulator))
    if runtime_log is not None:
        diagnostic('close-runtime-log', runtime_log.close)
    diagnostic('close-emulator-log', log.close)


def main(argv=None):
    global args, sdk, adb, adb_serial, process
    parser = argparse.ArgumentParser()
    parser.add_argument('--api', type=int, required=True)
    parser.add_argument('--apks', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=5554)
    args = parser.parse_args(argv)
    if args.port < 5554 or args.port > 5682 or args.port % 2:
        parser.error('--port must be an even emulator console port from 5554 to 5682')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    adb = str(sdk / 'platform-tools/adb')
    adb_serial = f'emulator-{args.port}'
    args.output.mkdir(parents=True, exist_ok=True)
    # Keep every AVD selector explicit and outside uploaded evidence.
    android_user = (Path.cwd() / 'build/android-acceptance-user').resolve()
    (android_user/'avd').mkdir(parents=True, exist_ok=True)
    os.environ['ANDROID_USER_HOME'] = str(android_user)
    os.environ['ANDROID_EMULATOR_HOME'] = str(android_user)
    os.environ['ANDROID_AVD_HOME'] = str(android_user/'avd')
    image = f'system-images;android-{args.api};default;x86_64'
    manager = sdk / 'cmdline-tools/latest/bin'
    subprocess.run([str(manager / 'sdkmanager'), 'emulator', 'platform-tools', image], input='y\n' * 100,
                   text=True, check=True, timeout=600)
    require_unused_serial()
    subprocess.run([str(manager / 'avdmanager'), 'create', 'avd', '--force', '--name', 'acceptance',
                    '--package', image, '--device', 'pixel_4'], input='no\n', text=True, check=True, timeout=60)
    # New tools may default to a 10 GiB userdata partition, unnecessary for this fixture.
    config = android_user / 'avd/acceptance.avd/config.ini'
    if config.exists():
        config.write_text(re.sub(r'disk.dataPartition.size=.*', 'disk.dataPartition.size=2G', config.read_text()))
    log = (args.output/'emulator.log').open('wb')
    process = subprocess.Popen([str(sdk/'emulator/emulator'), '-avd', 'acceptance', '-port', str(args.port), '-no-window', '-no-audio',
                                '-no-snapshot', '-no-boot-anim', '-no-metrics', '-accel', 'on',
                                '-gpu', 'swiftshader', '-memory', '2048', '-skin', '720x1280',
                                '-prop', 'qemu.sf.lcd_density=320'], stdout=log, stderr=subprocess.STDOUT)
    runtime_process = None
    runtime_log = None
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
        # Keep evidence while the guest is alive; a final logcat cannot recover
        # anything once its ADB transport or emulator has died.
        runtime_log = (args.output/'runtime-live.log').open('wb')
        runtime_process = subprocess.Popen(
            adb_values('logcat', '-v', 'threadtime', 'flutter:V', 'AndroidRuntime:V',
             'ActivityManager:I', 'libc:W', 'DEBUG:I', 'lowmemorykiller:I',
             'WM-WorkerWrapper:V', 'WM-SystemJobService:V', '*:S'),
            stdout=runtime_log, stderr=subprocess.STDOUT)
        shell('input', 'keyevent', '82')
        if args.api == 24:
            # boot_completed can precede the CE user store and package service on
            # Android 7. Its UserManager dump uses numeric RUNNING_UNLOCKED = 3.
            ready = time.monotonic() + 90
            while time.monotonic() < ready:
                users = shell('dumpsys', 'user', timeout=15)
                packages = command(adb, 'shell', 'pm', 'path', 'android', check=False, timeout=15)
                if re.search(r'Started users state:\s*\{[^}]*\b0=3\b', users) and packages.stdout.startswith(b'package:'):
                    break
                time.sleep(2)
            else:
                raise TimeoutError('Android 7 user storage/package service did not become ready')
        shell('settings', 'put', 'system', 'screen_off_timeout', '2147483647')
        shell('svc', 'power', 'stayon', 'true')
        for setting in ['window_animation_scale', 'transition_animation_scale', 'animator_duration_scale']:
            shell('settings', 'put', 'global', setting, '0')
        results = []
        for build in (10001, 10002):
            apk = args.apks/f'acceptance-{build}.apk'
            assert apk.exists(), apk
            install_mode = ['--no-streaming'] if args.api == 24 else []
            command(adb, 'install', *install_mode, '-r', str(apk), timeout=180)
            if args.api >= 33:
                shell('pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
            info = shell('dumpsys', 'package', package)
            assert f'versionCode={build} ' in info, 'OS package version did not change'
            value = start_and_wait(build, 'create' if build == 10001 else 'reopen',
                                   results[-1]['runId'] if results else None)
            results.append(value)
            (args.output/'completed-phases.json').write_text(json.dumps(results, indent=2)+'\n')
            shell('am', 'force-stop', package)
            wait_for_reopen()
            value = start_and_wait(build, 'reopen', value['runId'])
            results.append(value)
            (args.output/'completed-phases.json').write_text(json.dumps(results, indent=2)+'\n')
        (args.output/'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
        screenshot = command(adb, 'exec-out', 'screencap', '-p')
        (args.output/'result.png').write_bytes(screenshot.stdout)
        print(f'API {args.api}: SQLite, crypto, Keystore, process reopen, schema upgrade and bounded SAF save/open passed')
    except BaseException as error:
        details = {'type': type(error).__name__, 'message': str(error),
                   'traceback': traceback.format_exc(), 'emulatorExit': process.poll()}
        diagnostic('primary-failure', lambda: (args.output/'failure.json').write_text(
            json.dumps(details, indent=2)+'\n', encoding='utf-8'))
        raise
    finally:
        collect_diagnostics(process, log, runtime_process, runtime_log)


if __name__ == '__main__':
    main()
