"""Run native no-cloud persistence and same-certificate upgrade on a disposable AVD."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import traceback
import uuid
import xml.etree.ElementTree as ET

package = 'com.haoxiguan.haoxiguan.acceptance'
app_label = '好习惯隔离验收'
activity = package + '/com.haoxiguan.haoxiguan.MainActivity'
process = None


def event(kind, **fields):
    with (args.output/'driver-events.jsonl').open('a', encoding='utf-8') as evidence:
        evidence.write(json.dumps({'event': kind, 'time': time.monotonic(), **fields}) + '\n')


def verify_fixture_apk(apk, build, aapt):
    # Read the actual APK before installing or driving Settings. A matching
    # display name alone cannot authorize testing a different application.
    badging = command(str(aapt), 'dump', 'badging', str(apk), timeout=30).stdout.decode('utf-8')
    (args.output/f'apk-{build}-badging.txt').write_text(badging, encoding='utf-8')
    identities = re.findall(r"^package: name='([^']+)' versionCode='([^']+)'(?: |$)", badging, re.MULTILINE)
    labels = re.findall(r"^application-label:'([^']*)'$", badging, re.MULTILINE)
    if identities != [(package, str(build))] or labels != [app_label]:
        raise ValueError('APK does not have the exact isolated package, build and application label')
    event('fixture-apk-identity', build=build, package=package, label=app_label)


def find_aapt(sdk):
    candidates = sorted((sdk/'build-tools').glob('*/aapt'))
    if not candidates:
        raise RuntimeError('Android SDK build-tools aapt is required to verify fixture identity')
    return candidates[-1]


def require_emulator(stage):
    code = process.poll()
    if code is not None:
        event('emulator-exited', stage=stage, exit=code)
        raise RuntimeError(f'emulator exited with status {code} during {stage}; inspect emulator.log')


def process_list_command():
    # Android 7 toolbox ps lists all processes; Android 8+ toybox needs -A.
    return ('ps',) if args.api < 26 else ('ps', '-A')


def process_identities(output):
    if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', output):
        raise ValueError('process list contains control characters')
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        raise ValueError('process list is missing its header or process rows')
    header = lines[0].split()
    # Both selected Android commands use NAME (argv[0]). Toybox CMD is the
    # possibly truncated thread name and cannot prove package PID absence.
    name_columns = [i for i, name in enumerate(header) if name == 'NAME']
    if (len(name_columns) != 1 or name_columns[0] != len(header) - 1 or
            header.count('PID') != 1 or header.count('USER') != 1):
        raise ValueError('process list has no unambiguous name column')
    pid_column, user_column = header.index('PID'), header.index('USER')
    # AOSP Android 7 toolbox ps.c prints an unlabelled state between PC and
    # NAME. Match only that exact header; guessing the last field would accept
    # malformed/truncated rows as proof that a previous PID disappeared.
    legacy = header == ['USER', 'PID', 'PPID', 'VSIZE', 'RSS', 'WCHAN', 'PC', 'NAME']
    if not legacy and header not in (
            ['USER', 'PID', 'PPID', 'VSZ', 'RSS', 'WCHAN', 'ADDR', 'S', 'NAME'],
            ['USER', 'PID', 'PPID', 'VSIZE', 'RSS', 'WCHAN', 'ADDR', 'S', 'NAME']):
        raise ValueError('unsupported process list header')
    identities = {}
    for line in lines[1:]:
        if legacy:
            # toolbox can print an EMPTY WCHAN after /proc/PID/wchan closes.
            # Its PC is zero-padded to at least 8 (32-bit) / 10 (64-bit)
            # hexadecimal digits; NAME is the remaining text, including spaces.
            row = re.fullmatch(
                r'\s*(\S+)\s+([0-9]+)\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+'
                r'(?:\S{1,10}\s+)?(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{10,16})\s+[RSDTtXZPIxKW]\s+(\S.*)', line)
            if row is None:
                raise ValueError('Android 7 process list contains an incomplete or invalid row')
            user, pid, name = row.groups()
        else:
            row = line.split(maxsplit=len(header) - 1)
            if len(row) != len(header) or not re.fullmatch(r'[0-9]+', row[pid_column]):
                raise ValueError('process list contains an incomplete row')
            if (not all(re.fullmatch(r'[0-9]+', row[index]) for index in (2, 3, 4)) or
                    not re.fullmatch(r'(?:[0-9a-fA-F]+|-)', row[6]) or
                    not re.fullmatch(r'[RSDTtXZPIxKW]', row[7])):
                raise ValueError('modern process list contains invalid structural fields')
            user, pid, name = row[user_column], row[pid_column], row[-1]
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]*', user):
            raise ValueError('process list contains an invalid USER')
        pid = int(pid)
        if pid <= 0 or pid in identities:
            raise ValueError('process list contains an invalid or duplicate PID')
        identities[pid] = {'user': user, 'name': name}
    return identities


def app_process_ids(output):
    return {pid for pid, identity in process_identities(output).items()
            if identity['name'] == package or identity['name'].startswith(package + ':')}


snapshot_sequence = 0


def read_process_snapshot(label, timeout):
    global snapshot_sequence
    snapshot_sequence += 1
    # Preserve the original bytes BEFORE decoding or parsing, including failures.
    stem = args.output / f'processes-{snapshot_sequence:03d}-{label}'
    try:
        result = command(adb, 'shell', *process_list_command(), check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stem.with_suffix('.txt').write_bytes(error.output or b'')
        stem.with_suffix('.stderr.txt').write_bytes(error.stderr or b'')
        raise
    stem.with_suffix('.txt').write_bytes(result.stdout)
    stem.with_suffix('.stderr.txt').write_bytes(result.stderr)
    if result.returncode:
        raise ValueError(f'process list exit {result.returncode}')
    return process_identities(result.stdout.decode('utf-8'))


def original_app_processes(timeout=15):
    deadline = time.monotonic() + timeout
    last_error = None
    for attempt in range(3):
        require_emulator('original process snapshot')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            identities = read_process_snapshot('before-stop', min(5, remaining))
            original = {pid: identity['user'] for pid, identity in identities.items()
                        if identity['name'] == package or identity['name'].startswith(package + ':')}
            if not original:
                raise ValueError('app process disappeared before the requested force-stop')
            return original
        except (subprocess.TimeoutExpired, ValueError) as error:
            last_error = error
            event('original-process-read-failed', attempt=attempt + 1, error=str(error))
        if attempt < 2:
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))
    raise RuntimeError(f'could not identify original app processes: {last_error}') from last_error


def wait_for_reopen(previous_pids, timeout=45):
    """Observe a completed force-stop and two healthy reads before one launch.

    Never repeat am start/force-stop: even a closed ADB connection may have
    delivered the mutation. Persistent disconnection or an exited AVD fails.
    """
    if not previous_pids:
        raise ValueError('force-stop requires a nonempty snapshot of the original app processes')
    deadline = time.monotonic() + timeout
    failure = 'force-stop did not end the original app processes with a stable Android framework'

    def read(*values):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(failure)
        return command(adb, 'shell', *values, check=False, timeout=min(5, remaining))

    stable = 0
    while time.monotonic() < deadline:
        require_emulator('force-stop readiness')
        ready = False
        current_pids = None
        boot_ready = activity_ready = False
        read_error = None
        try:
            boot = read('getprop', 'sys.boot_completed')
            service = read('service', 'check', 'activity')
            boot_ready = boot.returncode == 0 and boot.stdout.strip() == b'1'
            activity_ready = service.returncode == 0 and b'Service activity: found' in service.stdout
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(failure)
            identities = read_process_snapshot('after-stop', min(5, remaining))
            current_pids = set(identities)
            # Android 7 can start a NEW SystemJobService process just after a
            # successful force-stop. Package stopped=true is not stable then.
            # Prove the previous process lifetime ended, allowing that new PID;
            # the next launch must still produce a new, fully passing report.
            # The full PID/USER table still blocks an original process if its
            # NAME changed. A PID recycled under another USER is a new identity.
            ready = (boot_ready and activity_ready and all(
                pid not in identities or identities[pid]['user'] != user
                for pid, user in previous_pids.items()))
        except (subprocess.TimeoutExpired, ValueError) as error:
            read_error = str(error)
        stable = stable + 1 if ready else 0
        event('force-stop-readiness', ready=ready, consecutive=stable,
              bootReady=boot_ready, activityReady=activity_ready,
              previousPids=sorted(previous_pids),
              currentPids=None if current_pids is None else sorted(current_pids), readError=read_error)
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
ui_stages = {}
device_api = None


def verify_device_api():
    global device_api
    raw = shell('getprop', 'ro.build.version.sdk').strip()
    if not re.fullmatch(r'[0-9]+', raw) or int(raw) != args.api:
        raise RuntimeError(f'AVD SDK {raw!r} does not match requested API {args.api}')
    device_api = int(raw)


def tap_node(node):
    bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    if bounds is None:
        raise ValueError('requested UI control has no valid bounds')
    left, top, right, bottom = map(int, bounds.groups())
    if right <= left or bottom <= top:
        raise ValueError('requested UI control is not visible')
    shell('input', 'tap', str((left + right)//2), str((top + bottom)//2))


def settings_channel_title(root, expected_title):
    # Android 16 exposes this screen title through the collapsing toolbar's
    # accessibility description. Do not accept matching text from another row.
    titles = [node for node in root.iter('node')
              if node.get('package') == 'com.android.settings' and
              node.get('resource-id') == 'com.android.settings:id/collapsing_toolbar']
    if len(titles) != 1:
        return False
    values = (titles[0].get('text', ''), titles[0].get('content-desc', ''))
    if any(values):
        return expected_title in values and all(value in ('', expected_title) for value in values)
    # AOSP Settings' action_bar Toolbar creates its title as a direct TextView
    # child. Keep this fallback inside the unique, otherwise empty title bar.
    toolbars = [node for node in titles[0]
                if node.tag == 'node' and node.get('resource-id') == 'com.android.settings:id/action_bar']
    if len(toolbars) != 1:
        return False
    toolbar = toolbars[0]
    if toolbar.get('package') != 'com.android.settings' or toolbar.get('class') not in (
            'android.widget.Toolbar', 'android.view.ViewGroup'):
        return False
    children = [node for node in toolbar if node.tag == 'node' and
                node.get('class') == 'android.widget.TextView' and node.get('text', '')]
    return (len(children) == 1 and children[0].get('package') == 'com.android.settings' and
            children[0].get('text') == expected_title and
            children[0].get('content-desc', '') in ('', expected_title))


def settings_switch(root, label):
    parents = {child: parent for parent in root.iter() for child in parent}
    labels = [node for node in root.iter('node')
              if node.get('package') == 'com.android.settings' and node.get('text') == label]
    if len(labels) != 1:
        return None
    scope = labels[0]
    while scope in parents:
        scope = parents[scope]
        # Stop at the preference's own actionable row; never climb into the
        # whole screen and borrow an unrelated row's sole switch.
        if scope.get('scrollable') == 'true' or scope.get('class', '').endswith(('ListView', 'RecyclerView')):
            return None
        is_row = (scope.get('clickable') == 'true' or
                  scope.get('resource-id') in ('com.android.settings:id/main_switch_bar',
                                              'com.android.settings:id/settingslib_main_switch_bar'))
        if not is_row:
            continue
        switches = [node for node in scope.iter('node')
                    if node.get('package') == 'com.android.settings' and
                    node.get('resource-id') == 'android:id/switch_widget' and
                    node.get('checkable') == 'true' and node.get('class', '').endswith('Switch')]
        if switches:
            if len(switches) != 1:
                raise ValueError('notification preference has ambiguous switches')
            return switches[0]
        return None
    return None


def drive_native_ui(value):
    stage = value.get('stage')
    notification_stages = ('awaitingNotificationDeny', 'awaitingNotificationGrant',
                           'awaitingChannelDisable', 'awaitingChannelEnable')
    restore_stages = ('awaitingRestoreCancel', 'awaitingRestoreConfirm')
    if stage not in notification_stages + restore_stages:
        return False
    if device_api != args.api:
        raise RuntimeError('native UI requires independently verified AVD SDK')
    run_id = value['runId']
    if not isinstance(run_id, str) or not re.fullmatch(r'\d+', run_id):
        raise ValueError('native UI stage has an invalid runId')
    state = ui_stages.setdefault((run_id, stage), {})
    if state.get('done'):
        return True
    shell('uiautomator', 'dump', '/sdcard/acceptance-ui.xml', timeout=25)
    xml = shell('cat', '/sdcard/acceptance-ui.xml')
    (args.output/f'ui-{run_id}-{stage}.xml').write_text(xml, encoding='utf-8')
    root = ET.fromstring(xml)
    nodes = list(root.iter('node'))
    if stage in restore_stages:
        label = '取消' if stage == 'awaitingRestoreCancel' else '保护当前数据并恢复'
        controls = [node for node in nodes if node.get('package') == package and
                    (node.get('text') == label or node.get('content-desc') == label) and
                    node.get('enabled') == 'true' and node.get('clickable') == 'true']
        if len(controls) > 1:
            raise ValueError('ambiguous restore dialog button')
        if controls:
            state['done'] = True  # A delivered tap is never replayed.
            event('restore-ui-tap', runId=run_id, stage=stage, label=label)
            tap_node(controls[0])
        return True
    channel = stage in ('awaitingChannelDisable', 'awaitingChannelEnable')
    if channel and device_api < 26:
        raise ValueError('channel stage is not available below API 26')
    if state.get('verified'):
        # Return along the actual Settings back stack; do not relaunch or kill
        # the fixture. API24 has an additional App info screen in that stack.
        if any(node.get('package') == package for node in nodes):
            ack = json.dumps({'runId': run_id, 'stage': stage, 'apiLevel': device_api}).encode()
            state['done'] = True
            command(adb, 'shell', 'run-as', package, 'sh', '-c',
                    "'cat > files/acceptance-control.json'", input=ack, timeout=15)
            event('notification-ui-ack', runId=run_id, stage=stage, apiLevel=device_api)
        elif any(node.get('package') == 'com.android.settings' for node in nodes):
            if state.get('lastBackXml') != xml:
                if state.get('backs', 0) >= 3:
                    raise RuntimeError('Settings did not return to the fixture within three Back actions')
                state['lastBackXml'] = xml
                state['backs'] = state.get('backs', 0) + 1
                shell('input', 'keyevent', '4')
        return True
    allowed = stage in ('awaitingNotificationGrant', 'awaitingChannelEnable')
    label = ('Block all' if device_api < 26 else
             'Show notifications' if channel else f'All {app_label} notifications')
    if device_api < 26 or channel:
        expected_title = '习惯提醒' if channel else app_label
        title_matches = (settings_channel_title(root, expected_title) if channel else
                         any(node.get('package') == 'com.android.settings' and
                             node.get('text') == expected_title for node in nodes))
        if not title_matches:
            return True
    switch = settings_switch(root, label)
    if switch is None:
        if device_api < 26 and not state.get('enteredNotifications'):
            controls = [node for node in nodes if node.get('package') == 'com.android.settings' and
                        node.get('text') == 'Notifications' and node.get('enabled') == 'true']
            if len(controls) == 1:
                state['enteredNotifications'] = True
                tap_node(controls[0])
        return True
    checked = switch.get('checked')
    if checked not in ('true', 'false') or switch.get('enabled') != 'true':
        raise ValueError('notification switch is disabled or has no checked state')
    desired = (not allowed) if device_api < 26 else allowed
    if (checked == 'true') == desired:
        state['verified'] = True
        event('notification-ui-state', runId=run_id, stage=stage, checked=desired)
    elif not state.get('tapped'):
        state['tapped'] = True
        event('notification-ui-tap', runId=run_id, stage=stage, desiredChecked=desired)
        tap_node(switch)
    return True


def assert_engine_recreation(value):
    assert value.get('nativeEngineRecreation') is True, 'native engine recreation was not proved'
    assert type(value.get('ownerPid')) is int and value['ownerPid'] > 0, 'invalid current owner PID'
    assert isinstance(value.get('entryId'), str) and re.fullmatch('[0-9a-f]{32}', value['entryId']), 'invalid current owner entry'
    proof = value.get('nativeEngineRecreationEvidence')
    assert isinstance(proof, dict) and proof.get('firstRunningReportUnchanged') is True, 'missing native engine proof'
    assert (proof.get('runId'), proof.get('nonce')) == (value.get('runId'), value.get('launchNonce')), 'engine proof has another logical authorization'
    assert isinstance(proof.get('requestId'), str) and re.fullmatch('[0-9a-f]{32}', proof['requestId']), 'invalid recreate request'
    assert isinstance(proof.get('entryId'), str) and re.fullmatch('[0-9a-f]{32}', proof['entryId']), 'invalid original owner entry'
    before, after = proof.get('before'), proof.get('after')
    assert isinstance(before, dict) and isinstance(after, dict), 'missing actual native host identities'
    for host in (before, after):
        assert (host.get('package'), host.get('build')) == (package, value.get('build')), 'foreign native host'
        assert type(host.get('pid')) is int and host['pid'] > 0, 'invalid host PID'
        assert type(host.get('attachCount')) is int and host['attachCount'] > 0, 'invalid attach count'
        assert all(host.get(key) is True for key in ('attached', 'uiDisplayed', 'executingDart')), 'owner is not visibly attached'
        assert all(isinstance(host.get(key), str) and re.fullmatch('[0-9a-f]{32}', host[key]) for key in ('engineId', 'hostId')), 'invalid host/engine identity'
    assert (before['pid'], before['engineId']) == (after['pid'], after['engineId']), 'recreation changed process or engine'
    assert before['hostId'] != after['hostId'] and after['attachCount'] > before['attachCount'], 'Activity was not really recreated'
    assert (after.get('requestOutcome'), after.get('requestId'), after.get('requestHostId')) == ('executed', proof['requestId'], before['hostId']), 'new host has no exact executed recreation request'
    current = before['pid']
    resumes = value.get('notificationProcessResumes', [])
    assert isinstance(resumes, list), 'invalid continuation observations'
    for observation in resumes:
        assert isinstance(observation, dict) and observation.get('runId') == value.get('runId'), 'another logical continuation'
        assert type(observation.get('previousPid')) is int and observation['previousPid'] == current and type(observation.get('pid')) is int and observation['pid'] > 0 and observation['pid'] != current, 'broken continuation PID chain'
        assert observation.get('databaseDifferencePaths') == [] and observation.get('completeModelUnchanged') is True, 'continuation changed original business data'
        current = observation['pid']
    assert current == value.get('ownerPid'), 'report owner has no verified original engine or continuation'
    if not resumes:
        assert value.get('entryId') == proof['entryId'], 'recreation changed the original Dart owner'


def check_entry_ownership_failure(build, phase, nonce):
    runtime = args.output/'runtime-live.log'
    if not runtime.exists():
        return
    marker = 'ACCEPTANCE_ENTRY_OWNERSHIP_FAILURE '
    for line in runtime.read_text(encoding='utf-8', errors='strict').splitlines():
        if marker not in line:
            continue
        try:
            observation = json.loads(line.split(marker, 1)[1])
        except (ValueError, TypeError) as error:
            raise RuntimeError('malformed native entry ownership diagnostic') from error
        if not isinstance(observation, dict):
            raise RuntimeError('malformed native entry ownership diagnostic')
        if observation.get('nonce') != nonce:
            continue
        valid = (observation.get('package'), observation.get('build'), observation.get('phase')) == (package, str(build), phase)
        valid = valid and type(observation.get('pid')) is int and observation['pid'] > 0
        valid = valid and isinstance(observation.get('entryId'), str) and re.fullmatch('[0-9a-f]{32}', observation['entryId'])
        valid = valid and observation.get('reportWritten') is False and observation.get('businessOpened') is False
        valid = valid and observation.get('reason') == 'retained owner did not respond to the bounded challenge'
        (args.output/f'entry-ownership-failure-{nonce}.txt').write_text(line+'\n', encoding='utf-8')
        if not valid:
            raise RuntimeError('native entry ownership diagnostic has a wrong identity')
        event('entry-ownership-failure', observation=observation)
        raise RuntimeError('native acceptance entry owner did not respond; no business replay is permitted')


def assert_native_flags(value):
    fields = ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit',
              'nativeReminderScheduling', 'workManagerRenewal', 'periodicTasksRegistered',
              'nativeDeniedHabitSaved', 'nativeAppPermissionDiagnosis', 'nativeAppPermissionRecovery',
              'nativeRestorePreviewCancel', 'nativeRestoreProtection', 'nativeRestoreConfirm', 'nativeRestoreReopen')
    assert all(value.get(key) is True for key in fields), value
    assert type(value.get('notificationApiLevel')) is int and value['notificationApiLevel'] == device_api == args.api, value
    for key in ('nativeChannelDiagnosis', 'nativeChannelRecovery'):
        if device_api >= 26:
            assert value.get(key) is True, value
        else:
            assert value.get(key) == 'notApplicable', value

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

notification_stages = ('awaitingNotificationDeny', 'awaitingNotificationGrant',
                       'awaitingChannelDisable', 'awaitingChannelEnable')


def archive_settings_checkpoint(value):
    """Preserve the pre-navigation checkpoint before any Settings mutation."""
    raw = command(adb, 'exec-out', 'run-as', package, 'cat',
                  'files/acceptance-settings-checkpoint.json', timeout=15).stdout
    try:
        checkpoint = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RuntimeError('Settings checkpoint is incomplete or malformed; refusing UI mutation') from error
    if not isinstance(checkpoint, dict) or not isinstance(checkpoint.get('result'), dict):
        raise RuntimeError('Settings checkpoint has no saved running result')
    saved = checkpoint.get('result', {})
    if (type(checkpoint.get('version')) is not int or checkpoint['version'] != 1 or
            checkpoint.get('package') != package or checkpoint.get('build') != '10002' or
            type(checkpoint.get('schema')) is not int or checkpoint['schema'] != 3 or
            checkpoint.get('runId') != value['runId'] or checkpoint.get('stage') != value['stage'] or
            type(checkpoint.get('pid')) is not int or checkpoint['pid'] <= 0 or
            type(checkpoint.get('deadlineMs')) is not int or checkpoint['deadlineMs'] <= 0 or
            saved.get('runId') != value['runId'] or saved.get('stage') != value['stage'] or
            saved.get('status') != 'running' or saved.get('build') != '10002'):
        raise RuntimeError('Settings checkpoint does not match the active isolated run and stage')
    launch = checkpoint.get('launch')
    if (not isinstance(launch, dict) or type(launch.get('version')) is not int or launch.get('version') != 1 or
            launch.get('package') != package or launch.get('build') != value['build'] or
            launch.get('phase') != value.get('phase') or
            launch.get('nonce') != value.get('launchNonce') or
            launch.get('previousRunId') != value.get('previousRunId') or
            saved.get('launchNonce') != value.get('launchNonce') or
            saved.get('previousRunId') != value.get('previousRunId')):
        raise RuntimeError('Settings checkpoint does not match the active host launch nonce')
    destination = args.output / f"checkpoint-{value['runId']}-{value['stage']}.json"
    destination.write_bytes(raw)
    event('checkpoint-archived', runId=value['runId'], stage=value['stage'], pid=checkpoint['pid'])


report_path = 'files/acceptance-report.json'
report_probe_prefix = f'HAOXIGUAN_REPORT_PROBE_V1|{package}|{report_path}|'


def report_probe_script():
    """Read only the exact isolated private path; bad types never mean absent."""
    absent = f'printf "%s\\n" "{report_probe_prefix}ABSENT"'
    invalid = f'printf "%s\\n" "{report_probe_prefix}INVALID"; exit 2'
    exists = f'printf "%s\\n" "{report_probe_prefix}EXISTS"'
    return (
        f'if [ ! -d . ] || [ ! -r . ] || [ ! -x . ]; then {invalid}; '
        f'elif [ -L files ] || {{ [ -e files ] && [ ! -d files ]; }}; then {invalid}; '
        f'elif [ ! -d files ]; then {absent}; '
        f'elif [ ! -r files ] || [ ! -x files ]; then {invalid}; '
        f'elif [ -L {report_path} ]; then {invalid}; '
        f'elif [ -e {report_path} ]; then '
        f'if [ ! -f {report_path} ] || [ ! -r {report_path} ]; then {invalid}; fi; '
        f'{exists}; cat {report_path} || exit 2; '
        f'else {absent}; fi'
    )


def decode_report_probe(result):
    # exec-out does not propagate the remote exit status. Even shell -T is
    # accepted only with an exact package/path marker and empty stderr.
    if result.returncode != 0 or result.stderr:
        raise RuntimeError('isolated report probe has an ADB or remote read error')
    absent = (report_probe_prefix + 'ABSENT\n').encode()
    exists = (report_probe_prefix + 'EXISTS\n').encode()
    if result.stdout == absent:
        return None
    if not result.stdout.startswith(exists):
        raise RuntimeError('isolated report probe has an unknown status or identity')
    def unique_object(pairs):
        value = {}
        for name, item in pairs:
            if name in value:
                raise ValueError('duplicate report JSON key')
            value[name] = item
        return value
    def invalid_constant(value):
        raise ValueError('non-finite report JSON number')
    def finite_number(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError('non-finite report JSON number')
        return number
    try:
        value = json.loads(result.stdout[len(exists):].decode('utf-8'),
                           object_pairs_hook=unique_object, parse_constant=invalid_constant, parse_float=finite_number)
    except (ValueError, UnicodeDecodeError) as error:
        raise RuntimeError('isolated existing report is not strict JSON') from error
    if not isinstance(value, dict):
        raise RuntimeError('isolated existing report is not an object')
    return value


def valid_passed_predecessor(saved, build, previous):
    if (saved.get('package') != package or saved.get('status') != 'passed' or
            saved.get('runId') != previous or saved.get('build') not in ('10001', '10002') or
            type(saved.get('schema')) is not int or saved['schema'] != (2 if saved['build'] == '10001' else 3) or
            any(field in saved for field in ('error', 'stack', 'continuationRejected')) or
            not isinstance(saved.get('launchNonce'), str) or not re.fullmatch(r'[a-f0-9]{32}', saved['launchNonce']) or
            type(saved.get('ownerPid')) is not int or saved['ownerPid'] <= 0 or
            not isinstance(saved.get('entryId'), str) or not re.fullmatch(r'[a-f0-9]{32}', saved['entryId']) or
            saved.get('nativeCrypto') is not True or saved.get('keystore') is not True or
            type(saved.get('habits')) is not int or saved['habits'] != 3 or
            saved.get('backupConfigured') is not False or saved.get('syncConfigured') is not False):
        return False
    try:
        assert_engine_recreation(saved)
    except (AssertionError, KeyError, TypeError, ValueError):
        return False
    if build == 10001:
        return saved['build'] == '10001' and saved.get('phase') == 'create' and saved.get('previousRunId') is None
    if saved.get('phase') != 'reopen' or not isinstance(saved.get('previousRunId'), str) or not re.fullmatch(r'[0-9]+', saved['previousRunId']):
        return False
    if saved['build'] == '10002':
        try:
            assert_native_flags(saved)
        except (AssertionError, KeyError, TypeError):
            return False
    return True


def prepare_launch(build, phase, previous):
    """Authorize one of the existing four launches; never called for OS Back."""
    if build not in (10001, 10002) or phase not in ('create', 'reopen') or (
            (phase == 'create' and (build != 10001 or previous is not None)) or
            (phase == 'reopen' and (not isinstance(previous, str) or not re.fullmatch(r'[0-9]+', previous)))):
        raise ValueError('invalid host phase predecessor')
    nonce = uuid.uuid4().hex
    evidence = args.output/f'preflight-report-{build}-{phase}-{nonce}'
    try:
        prior = command(adb, 'shell', '-T', 'run-as', package, 'sh', '-c',
                        "'" + report_probe_script() + "'", check=False, timeout=15)
    except subprocess.TimeoutExpired as error:
        def raw(value): return value.encode('utf-8') if isinstance(value, str) else value or b''
        evidence.with_suffix('.stdout.bin').write_bytes(raw(error.stdout))
        evidence.with_suffix('.stderr.bin').write_bytes(raw(error.stderr))
        evidence.with_suffix('.metadata.json').write_text(json.dumps({
            'package':package, 'path':report_path, 'build':build, 'phase':phase,
            'previousRunId':previous, 'probeId':nonce, 'readCompleted':False,
            'type':'TimeoutExpired', 'timeout':error.timeout}, indent=2), encoding='utf-8')
        raise
    evidence.with_suffix('.stdout.bin').write_bytes(prior.stdout)
    evidence.with_suffix('.stderr.bin').write_bytes(prior.stderr)
    evidence.with_suffix('.metadata.json').write_text(json.dumps({
        'package': package, 'path': report_path, 'build': build, 'phase': phase,
        'previousRunId': previous, 'probeId': nonce, 'returncode': prior.returncode,
        'stdoutBytes': len(prior.stdout), 'stderrBytes': len(prior.stderr)}, indent=2), encoding='utf-8')
    saved = decode_report_probe(prior)
    if previous is None:
        if saved is not None:
            raise RuntimeError('initial launch refuses an existing acceptance report')
    else:
        if saved is None or not valid_passed_predecessor(saved, build, previous) or saved['launchNonce'] == nonce:
            raise RuntimeError('host launch refuses a failed, unfinished or unrelated predecessor')
    launch = {'version': 1, 'package': package, 'build': str(build), 'phase': phase,
              'previousRunId': previous, 'nonce': nonce}
    raw = json.dumps(launch).encode()
    # One mutation, no retries. Rename publishes the complete authorization.
    command(adb, 'shell', 'run-as', package, 'sh', '-c',
            "'mkdir -p files && cat > files/acceptance-launch.json.pending && mv files/acceptance-launch.json.pending files/acceptance-launch.json'",
            input=raw, timeout=15)
    (args.output/f"launch-{launch['nonce']}.json").write_bytes(raw)
    return launch['nonce']


def start_and_wait(build, phase, previous=None):
    require_emulator(f'{build}/{phase} launch')
    nonce = prepare_launch(build, phase, previous)
    event('launch', build=build, phase=phase, previous=previous, nonce=nonce)
    shell('am', 'start', '-n', activity)
    # Schema3 adds four real Settings round trips and two restore dialogs to
    # SAF and the bounded WorkManager check. Each Dart UI stage also has its
    # own 120s limit. Schema2 keeps its original persistence-only budget.
    deadline = time.monotonic() + (600 if build == 10002 else 240)
    active_run = None
    archived = set()
    while time.monotonic() < deadline:
        require_emulator(f'{build}/{phase} report')
        check_entry_ownership_failure(build, phase, nonce)
        report = command(adb, 'exec-out', 'run-as', package, 'cat',
                         'files/acceptance-report.json', check=False, timeout=15)
        try:
            value = json.loads(report.stdout)
            (args.output/'last-report.json').write_text(json.dumps(value, ensure_ascii=False, indent=2))
            if active_run is not None and (value.get('runId') != active_run or value.get('build') != str(build) or value.get('launchNonce') != nonce):
                event('logical-run-drift', expected=active_run, observed=value.get('runId'), build=value.get('build'))
                raise RuntimeError('logical run identity changed; refusing further UI mutations')
            if value.get('runId') != previous and value.get('build') == str(build):
                if value.get('launchNonce') != nonce:
                    if active_run is None:
                        time.sleep(2)
                        continue
                    raise RuntimeError('acceptance host launch nonce changed')
                if value.get('previousRunId') != previous or value.get('phase') != phase:
                    raise RuntimeError('acceptance report has a different host phase predecessor')
                run_id = value.get('runId')
                if not isinstance(run_id, str) or not re.fullmatch(r'[0-9]+', run_id):
                    if run_id is None and active_run is None:
                        continue
                    raise RuntimeError('acceptance report has no valid logical run identity')
                if active_run is None:
                    active_run = run_id
                    event('logical-run-bound', runId=run_id, build=build, phase=phase)
                key = (run_id, value.get('stage'), value.get('status'))
                if key not in archived:
                    stage = value.get('stage', value.get('status'))
                    status = value.get('status')
                    if status not in ('running', 'passed', 'failed') or not isinstance(stage, str) or not re.fullmatch(r'[A-Za-z]+', stage):
                        raise RuntimeError('acceptance report has an invalid stage')
                    (args.output/f'report-{run_id}-{stage}-{status}.json').write_bytes(report.stdout)
                    if value.get('status') == 'running' and value.get('stage') in notification_stages:
                        archive_settings_checkpoint(value)
                    archived.add(key)
                if value.get('status') == 'failed':
                    raise RuntimeError(json.dumps(value, ensure_ascii=False))
                if value.get('status') == 'passed':
                    assert_engine_recreation(value)
                    assert value['phase'] == phase, value
                    assert value['schema'] == (2 if build == 10001 else 3), value
                    if build == 10002:
                        assert_native_flags(value)
                    return value
                if not drive_native_ui(value):
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
        'ActivityTaskManager', 'FlutterActivity', 'FlutterActivityAndFragmentDelegate',
        'FlutterEngine', 'FlutterJNI', 'HaoxiguanAcceptanceEngine', 'libc', 'DEBUG', 'lowmemorykiller',
        'WM-WorkerWrapper', 'WM-SystemJobService', timeout=10).stdout))
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
        verify_device_api()
        # Keep evidence while the guest is alive; a final logcat cannot recover
        # anything once its ADB transport or emulator has died.
        runtime_log = (args.output/'runtime-live.log').open('wb')
        runtime_process = subprocess.Popen(
            adb_values('logcat', '-v', 'threadtime', 'flutter:V', 'AndroidRuntime:V',
             'HaoxiguanAcceptanceEngine:V',
             'ActivityManager:I', 'ActivityTaskManager:V', 'FlutterActivity:V',
             'FlutterActivityAndFragmentDelegate:V', 'FlutterEngine:V', 'FlutterJNI:V',
             'libc:W', 'DEBUG:I', 'lowmemorykiller:I',
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
        aapt = find_aapt(sdk)
        for build in (10001, 10002):
            apk = args.apks/f'acceptance-{build}.apk'
            assert apk.exists(), apk
            verify_fixture_apk(apk, build, aapt)
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
            original_pids = original_app_processes()
            event('force-stop', build=build, previousPids=sorted(original_pids), previousUsers=original_pids)
            shell('am', 'force-stop', package)
            wait_for_reopen(original_pids)
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
