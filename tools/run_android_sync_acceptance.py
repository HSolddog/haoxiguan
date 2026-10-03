"""Drive disposable Android SyncScreen clients against a real loopback Go relay.

Linux CI only. Invitations, TLS keys, database, configuration, UI XML and server
logs stay in a private temporary directory/device. Uploaded evidence contains
only validated protocol fields and bounded diagnostic metadata.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
PACKAGES = {
    'A': 'com.haoxiguan.haoxiguan.syncacceptance.a',
    'B': 'com.haoxiguan.haoxiguan.syncacceptance.b',
}
BUILDS = {'A': '11001', 'B': '11002'}
SOURCE = {
    'repository': 'SqliteHabitRepository', 'secretStore': 'DeviceSecretStore',
    'screen': 'SyncScreen', 'conflictDialog': 'SyncConflictDialog',
    'transport': 'HttpSyncTransport', 'platform': 'android',
}
RESULT_FLAGS = (
    'realSyncScreen', 'realTlsTransport', 'productionStorage',
    'recoverySafVerified', 'initialPreviewCancelled', 'initialPreviewConfirmed',
    'fullFactsTransferred', 'independentSameDayEntries', 'manualConflictMerged',
    'protectionIntegrity', 'sqliteReopened', 'keystoreProcessReopened',
    'disconnectedOfflineBackup',
)
SAF_STAGES = {
    'awaitingRecoverySave': 'save', 'awaitingRecoveryReadback': 'open',
    'awaitingRecoveryJoin': 'open', 'awaitingBackupSave': 'save',
    'awaitingBackupReadback': 'open',
}
ROLE_STAGES = {
    'A': ('awaitingRecoverySave', 'awaitingRecoveryReadback',
          'awaitingReplicaImport', 'awaitingConflictResolution', 'awaitingReopen',
          'awaitingBackupSave', 'awaitingBackupReadback', 'complete'),
    'B': ('awaitingSourceUpload', 'awaitingRecoveryJoin',
          'awaitingAChangesUploaded', 'awaitingConvergence', 'awaitingReopen',
          'awaitingBackupSave', 'awaitingBackupReadback', 'complete'),
}
CONTROL_PREREQUISITES = {
    ('B', 'awaitingSourceUpload'): ('A', 'awaitingReplicaImport'),
    ('A', 'awaitingReplicaImport'): ('B', 'awaitingAChangesUploaded'),
    ('B', 'awaitingAChangesUploaded'): ('A', 'awaitingConflictResolution'),
    ('A', 'awaitingConflictResolution'): ('B', 'awaitingConvergence'),
    ('B', 'awaitingConvergence'): ('A', 'awaitingReopen'),
}
CONFIG_FILE = 'files/sync_acceptance_config.json'
REPORT_FILE = 'files/sync_acceptance_result.json'
CONTROL_FILE = 'files/sync_acceptance_control.json'
FACT_DIGESTS = tuple(f'{phase}{kind}FactsSha256'
                    for phase in ('initial', 'converged', 'offline')
                    for kind in ('Expected', 'Actual'))
EVIDENCE_METRICS = {
    'cancel': ('BusinessRevision', 'ProtectionCount', 'SyncProtectionCount',
               'RemoteObjects', 'RemoteHighWater'),
    'restart': ('BusinessRevision', 'StateRevision', 'ProtectionCount', 'SyncProtectionCount'),
}
EXPECTED_COUNTS = {'habits': 3, 'plans': 6, 'entries': 10, 'notes': 4}
# Fixed source-level identifiers mirrored by tools/native_sync/diagnostics.dart.
# Neither device text nor exception messages can extend these allowlists.
FAILURE_CODES = frozenset((
    'none', 'native_sync_failure', 'fixture_initialization_failed', 'invalid_config',
    'invalid_loopback_endpoint', 'acknowledged_remote_facts_mismatch', 'android_required',
    'conflict_dialog_missing', 'conflict_original_not_protected', 'connection_form_missing',
    'converged_full_facts_mismatch', 'disconnect_changed_business_data', 'disconnect_dialog_missing',
    'framework_ui_failure', 'fresh_package_not_empty', 'incomplete_native_evidence',
    'independent_entries_not_retained', 'initial_full_facts_mismatch', 'initial_preview_missing',
    'invalid_remote_watermark', 'invalid_restart_state', 'join_form_missing',
    'joined_initial_review_missing', 'joined_review_candidates_mismatch', 'joined_review_dialog_missing',
    'joined_review_full_facts_mismatch', 'manual_merge_full_facts_mismatch', 'manual_note_input_missing',
    'native_binding_missing', 'native_entry_fields_mismatch', 'native_local_edit_failed',
    'native_note_conflict_missing', 'native_protections_missing', 'native_sqlite_open_failed',
    'note_conflict_candidates_mismatch', 'offline_backup_full_snapshot_mismatch',
    'offline_backup_open_cancelled', 'offline_backup_save_failed', 'offline_edit_changed_remote_or_reconnected',
    'offline_full_facts_mismatch', 'offline_native_record_failed', 'offline_record_reopen_mismatch',
    'package_mismatch', 'preview_cancel_changed_local', 'preview_cancel_changed_remote',
    'preview_local_facts_mismatch', 'preview_remote_facts_mismatch',
    'process_reopen_data_or_keystore_mismatch', 'production_enrollment_failed', 'production_sync_incomplete',
    'production_sync_screen_required', 'production_ui_action_timeout', 'protection_digest_mismatch',
    'recovery_dialog_missing', 'recovery_export_not_committed', 'recovery_readback_cancelled',
    'recovery_readback_mismatch', 'recovery_save_failed', 'restart_checkpoint_mismatch',
    'restart_flags_invalid', 'sdk_mismatch', 'second_preview_missing', 'source_baseline_mismatch',
    'source_remote_not_empty', 'sqlite_close_reopen_mismatch', 'stage_ack_timeout', 'ui_input_missing',
    'ui_target_missing', 'unexpected_repeat_preview', 'exception_format', 'exception_state',
    'exception_file_system', 'exception_platform', 'exception_tls', 'exception_socket',
    'exception_timeout', 'exception_flutter', 'exception_type', 'exception_assertion', 'exception_sync_api',
))
ACTION_IDS = frozenset((
    'boot', 'unknown_action', 'open_sqlite', 'seed_source', 'show_sync_screen', 'fill_endpoint',
    'read_connection_fields', 'fill_device_name', 'fill_invite', 'join_switch', 'fill_join_password',
    'enroll_device', 'load_binding', 'verify_binding', 'read_remote_watermark', 'export_recovery',
    'fill_recovery_password', 'fill_recovery_confirm', 'save_recovery', 'readback_recovery',
    'verify_recovery', 'initial_sync', 'inspect_initial_preview', 'cancel_initial_preview',
    'verify_cancelled_preview', 'confirm_initial_preview', 'open_initial_review', 'choose_remote_item',
    'apply_initial_review', 'verify_initial_review', 'add_local_entry', 'edit_local_note', 'immediate_sync',
    'open_note_conflict', 'choose_manual_note', 'fill_manual_note', 'apply_manual_note',
    'verify_conflict_protection', 'verify_convergence', 'close_sqlite', 'reopen_sqlite',
    'prepare_process_restart', 'verify_process_restart', 'disconnect_device', 'confirm_disconnect',
    'add_offline_entry', 'save_offline_backup', 'readback_offline_backup', 'verify_offline_backup',
    'verify_offline_remote', 'await_source_upload', 'await_replica_import', 'await_a_changes_uploaded',
    'await_conflict_resolution', 'await_convergence', 'await_reopen', 'complete', 'cleanup',
))
FRAMEWORK_FAILURES = frozenset(('none', 'layout_overflow', 'layout_constraint',
                              'widget_lifecycle', 'gesture', 'flutter_framework'))

# Reuse only the strict, side-effect-free process parser. The legacy driver's
# Android lifecycle, report schema, UI handling and mutable globals stay separate.
_spec = importlib.util.spec_from_file_location(
    '_sync_process_parser', Path(__file__).with_name('run_android_acceptance.py'))
_legacy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_legacy)
process_identities = _legacy.process_identities


def exact_int(value, expected=None):
    return type(value) is int and (expected is None or value == expected)


def document_name(run_id, role, stage):
    if stage.startswith('awaitingRecovery'):
        return f'sync-{run_id}.hgr'
    return f'sync-{run_id}-{role}.hgb'


def validate_evidence(value, complete):
    if not isinstance(value, dict):
        raise ValueError('native sync requires a structured evidence object')
    clean = {}

    def field(source, target, key, digest=False):
        if key not in source:
            if complete:
                raise ValueError('missing native sync evidence: ' + key)
            return
        item = source[key]
        if digest:
            if not isinstance(item, str) or not re.fullmatch(r'[0-9a-f]{64}', item):
                raise ValueError('invalid native sync SHA256 evidence')
        elif not exact_int(item) or item < 0:
            raise ValueError('native sync revision/count evidence must be nonnegative integers')
        target[key] = item

    for key in FACT_DIGESTS:
        field(value, clean, key, digest=True)
    for group, metrics in EVIDENCE_METRICS.items():
        if group not in value and not complete:
            continue
        source = value.get(group)
        if not isinstance(source, dict):
            raise ValueError('missing native sync evidence group: ' + group)
        target = {}
        for key in ('beforeSnapshotSha256', 'afterSnapshotSha256'):
            field(source, target, key, digest=True)
        for metric in metrics:
            for prefix in ('before', 'after'):
                field(source, target, prefix + metric)
        if complete:
            for metric in ('SnapshotSha256', *metrics):
                if target['before' + metric] != target['after' + metric]:
                    raise ValueError('native sync cancellation/restart changed protected evidence')
        clean[group] = target
    if 'counts' in value or complete:
        source = value.get('counts')
        if not isinstance(source, dict):
            raise ValueError('missing native sync fact counts')
        target = {}
        for key in EXPECTED_COUNTS:
            field(source, target, key)
        if complete and target != EXPECTED_COUNTS:
            raise ValueError('native sync facts do not match exhaustive baseline counts')
        clean['counts'] = target
    if complete:
        for phase in ('initial', 'converged', 'offline'):
            if clean[phase + 'ExpectedFactsSha256'] != clean[phase + 'ActualFactsSha256']:
                raise ValueError('native sync exhaustive fact digests do not match')
    return clean


def validate_report(value, role, run_id, sdk):
    """Reject stale/foreign/malformed reports before allowing any UI mutation.

    Return an explicit whitelist so future fixture fields cannot accidentally
    upload tokens, note text, password-dialog contents or error messages.
    """
    if role not in PACKAGES or not isinstance(value, dict):
        raise ValueError('invalid sync report object or role')
    expected = {'schemaVersion': 3, 'sdkInt': sdk, 'packageName': PACKAGES[role],
                'role': role, 'runId': run_id, 'build': BUILDS[role]}
    for key, wanted in expected.items():
        if type(value.get(key)) is not type(wanted) or value.get(key) != wanted:
            raise ValueError(f'sync report identity mismatch: {key}')
    if not exact_int(value.get('reportSequence')) or value['reportSequence'] <= 0:
        raise ValueError('sync report requires a positive reportSequence')
    if not isinstance(value.get('launchId'), str) or not re.fullmatch(
            r'[0-9a-f]{32}', value['launchId']):
        raise ValueError('sync report requires a fresh hexadecimal launchId')
    stage, status = value.get('stage'), value.get('status')
    if stage not in ROLE_STAGES[role] + ('boot', 'failed'):
        raise ValueError('unknown or wrong-role sync stage')
    if status not in ('running', 'passed', 'failed'):
        raise ValueError('unknown sync report status')
    if ((status == 'passed') != (stage == 'complete') or
            (status == 'failed') != (stage == 'failed')):
        raise ValueError('sync report stage/status mismatch')
    if value.get('source') != SOURCE:
        raise ValueError('sync report did not use the expected production sources')
    clean = {**expected, 'reportSequence': value['reportSequence'],
             'launchId': value['launchId'], 'stage': stage, 'status': status,
             'source': dict(SOURCE)}
    clean['evidence'] = validate_evidence(value.get('evidence'), status == 'passed')
    for flag in RESULT_FLAGS:
        if flag in value:
            if type(value[flag]) is not bool:
                raise ValueError(f'sync result must be a boolean: {flag}')
            clean[flag] = value[flag]
        if status == 'passed' and value.get(flag) is not True:
            raise ValueError(f'native sync result did not pass: {flag}')
    if stage in SAF_STAGES:
        wanted = document_name(run_id, role, stage)
        if value.get('documentName') != wanted:
            raise ValueError('SAF report document name does not match this run')
        clean['documentName'] = wanted
    if status == 'failed':
        code = value.get('errorCode', 'native_sync_failure')
        if not isinstance(code, str) or code not in FAILURE_CODES or code == 'none':
            raise ValueError('unknown native fixture failure code')
        clean['errorCode'] = code
    if 'diagnostic' in value:
        diagnostic = value['diagnostic']
        if not isinstance(diagnostic, dict):
            raise ValueError('invalid native fixture diagnostic object')
        allowed = {'failureCode': FAILURE_CODES,
                   'lastStage': set(ROLE_STAGES[role]) | {'boot'},
                   'lastAction': ACTION_IDS, 'frameworkFailure': FRAMEWORK_FAILURES}
        selected = {}
        for key, choices in allowed.items():
            item = diagnostic.get(key)
            if not isinstance(item, str) or item not in choices:
                raise ValueError('unknown native fixture diagnostic identifier')
            selected[key] = item
        if ((status == 'failed' and selected['failureCode'] != clean['errorCode']) or
                (status != 'failed' and selected['failureCode'] != 'none')):
            raise ValueError('native fixture failure code/status mismatch')
        clean['diagnostic'] = selected
    return clean


def start_owned(values, **kwargs):
    process = subprocess.Popen(values, start_new_session=True, **kwargs)
    # A new POSIX session's process group is exactly its initial child's PID.
    # Keep this ownership marker on the returned handle; never discover groups
    # by executable name, scan user processes, or signal another session.
    process._sync_owned_group = process.pid
    return process


def stop_process(process):
    if process is None:
        return
    group = getattr(process, '_sync_owned_group', None)
    owned_group = type(group) is int
    if owned_group and (group <= 1 or group != process.pid):
        raise ValueError('refusing an unowned process group')
    errors = []
    killed = False

    def signal_group(kind):
        try:
            os.killpg(group, kind)
        except ProcessLookupError:
            pass
        except OSError as error:
            errors.append(error)

    if owned_group:
        signal_group(signal.SIGTERM)
        if errors and process.poll() is None:
            process.terminate()  # Still reclaim the directly owned child.
    elif process.poll() is None:
        process.terminate()
    else:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if owned_group:
            signal_group(signal.SIGKILL)
            killed = True
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
    finally:
        # The session leader can exit while a compiler/emulator descendant is
        # still alive. Reclaim that same owned group even after leader exit.
        if owned_group and not killed:
            signal_group(signal.SIGKILL)
    if errors:
        raise RuntimeError('owned process group cleanup failed') from errors[0]


def run_owned(values, *, input=None, timeout=30, cwd=None, env=None):
    process = start_owned(values, cwd=cwd, env=env,
                          stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            stop_process(process)
        except Exception:
            pass  # Keep the original timeout as the primary failure.
        try:
            process.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            pass
        raise subprocess.TimeoutExpired(values, timeout) from None
    except BaseException:
        try:
            stop_process(process)
        except Exception:
            pass
        raise
    result = subprocess.CompletedProcess(values, process.returncode, stdout, stderr)
    stop_process(process)
    return result


class DisposableRelay:
    def __init__(self, directory, go):
        self.directory = Path(directory)
        self.go = go
        self.process = None
        self.log = None
        self.port = None

    def run(self, values, label, cwd=None, timeout=120):
        # Raw operator output is never printed or placed in uploaded evidence.
        try:
            result = run_owned(values, cwd=cwd, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f'{label} timed out') from None
        if result.returncode:
            raise RuntimeError(f'{label} failed with exit {result.returncode}')
        return result

    def start(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.directory.chmod(0o700)
        binary = self.directory / 'server'
        database = self.directory / 'data.sqlite'
        cert, key = self.directory / 'cert.pem', self.directory / 'key.pem'
        self.run([self.go, 'build', '-trimpath', '-o', str(binary),
                  './cmd/haoxiguan-server'], 'Go relay build', ROOT / 'server', 300)
        self.run([self.go, 'run', str(ROOT / 'tools/sync_test_certificate.go'),
                  str(cert), str(key)], 'localhost certificate generation')
        key.chmod(0o600)
        first, second = self.directory / 'first.json', self.directory / 'second.json'
        self.run([str(binary), 'create-user', '--db', str(database), '--name',
                  'synthetic-native-sync', '--out', str(first)], 'synthetic account')
        account = json.loads(first.read_text(encoding='utf-8'))
        self.run([str(binary), 'invite', '--db', str(database), '--user',
                  account['userId'], '--out', str(second)], 'second synthetic invite')
        self.invites = {'A': account['invite'],
                        'B': json.loads(second.read_text(encoding='utf-8'))['invite']}
        self.certificate = cert.read_text(encoding='utf-8')
        for path in (first, second, cert, key, database):
            path.chmod(0o600)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.port = reservation.getsockname()[1]
        self.endpoint = f'https://localhost:{self.port}'
        self.log = (self.directory / 'server.log').open('wb')
        self.process = start_owned([
            str(binary), 'serve', '--db', str(database), '--listen',
            f'127.0.0.1:{self.port}', '--tls-cert', str(cert), '--tls-key', str(key),
        ], stdout=self.log, stderr=subprocess.STDOUT)
        context = ssl.create_default_context(cafile=str(cert))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            self.require_alive()
            try:
                with urllib.request.urlopen(self.endpoint + '/healthz',
                                            context=context, timeout=2) as response:
                    if response.status == 200:
                        return
            except OSError:
                time.sleep(0.2)
        raise TimeoutError('loopback HTTPS relay did not become healthy')

    def require_alive(self):
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError('isolated HTTPS relay exited')

    def close(self):
        try:
            stop_process(self.process)
        finally:
            if self.log is not None:
                self.log.close()


class NativeSyncDriver:
    def __init__(self, args, directory, relay):
        self.args, self.directory, self.relay = args, Path(directory), relay
        self.output = args.output
        self.run_id = uuid.uuid4().hex
        self.serial = f'emulator-{args.port}'
        self.adb = str(args.sdk / 'platform-tools/adb')
        self.process = None
        self.log = None
        self.sdk_int = None
        self.reports = {}
        self.observed = set()
        self.stages = {}
        self.actions = set()
        self.sequences = {}
        self.reopen_launches = {}
        self.reopened = set()
        self.last_progress = {}
        self.last_running_stages = {}
        self.deadline = None
        self.foreground_role = None
        self.stage_indices = {}
        self.reverse_created = False

    def event(self, kind, **fields):
        with (self.output / 'driver-events.jsonl').open('a', encoding='utf-8') as file:
            file.write(json.dumps({'event': kind, 'time': time.monotonic(), **fields}) + '\n')

    def require_alive(self, stage):
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError(f'isolated emulator exited during {stage}')
        self.relay.require_alive()
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise TimeoutError('native sync total timeout')

    def execute(self, values, label, *, timeout=30, check=True, input=None, env=None):
        try:
            result = run_owned(values, input=input, env=env, timeout=timeout)
        except subprocess.TimeoutExpired:
            self.event('command-timeout', operation=label, timeout=timeout)
            raise RuntimeError(f'{label} timed out') from None
        if result.returncode:
            self.event('command-failed', operation=label, exit=result.returncode,
                       stdoutBytes=len(result.stdout), stderrBytes=len(result.stderr))
            if check:
                raise RuntimeError(f'{label} failed with exit {result.returncode}')
        return result

    def adb_values(self, *values):
        return [self.adb, '-s', self.serial, *values]

    def adb_command(self, *values, label='adb', **kwargs):
        return self.execute(self.adb_values(*values), label, **kwargs)

    def shell(self, *values, label='shell', **kwargs):
        return self.adb_command('shell', *values, label=label, **kwargs).stdout.decode('utf-8')

    def once(self, key, action):
        # A command may reach the guest even if its ADB connection then closes.
        # Mark before delivery and fail on errors; never replay a mutation.
        if key in self.actions:
            return False
        self.actions.add(key)
        action()
        return True

    def package(self, role):
        if role not in PACKAGES:
            raise ValueError('unowned Android package')
        return PACKAGES[role]

    def focus(self, role, reason):
        package = self.package(role)
        self.require_alive(reason)
        changed = self.once(('focus', role, reason), lambda: self.shell(
            'am', 'start', '-n', package + '/com.haoxiguan.haoxiguan.MainActivity',
            label='focus owned fixture', timeout=15))
        if changed:
            self.foreground_role = role
        return changed

    def write_private(self, role, path, value):
        if path not in (CONFIG_FILE, CONTROL_FILE):
            raise ValueError('unowned fixture control path')
        self.adb_command('shell', 'run-as', self.package(role), 'sh', '-c',
                         "'mkdir -p files && cat > " + path + "'", label='private fixture configuration',
                         input=json.dumps(value).encode('utf-8'), timeout=15)

    def check_unused_serial(self):
        # The only untargeted ADB action is this read-only pre-launch inventory.
        result = self.execute([self.adb, 'devices'], 'read device inventory', timeout=15)
        if any(line.split() and line.split()[0] == self.serial
               for line in result.stdout.decode('utf-8').splitlines()):
            raise RuntimeError('requested isolated emulator serial is already present')

    def start_emulator(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        android_user = self.directory / 'android-user'
        avd_home = android_user / 'avd'
        avd_home.mkdir(parents=True)
        env = {**os.environ, 'ANDROID_USER_HOME': str(android_user),
               'ANDROID_EMULATOR_HOME': str(android_user),
               'ANDROID_AVD_HOME': str(avd_home)}
        image = f'system-images;android-{self.args.api};default;x86_64'
        manager = self.args.sdk / 'cmdline-tools/latest/bin'
        self.execute([str(manager / 'sdkmanager'), 'emulator', 'platform-tools', image],
                     'install isolated emulator image', input=b'y\n' * 100,
                     timeout=600, env=env)
        self.check_unused_serial()
        self.execute([str(manager / 'avdmanager'), 'create', 'avd', '--force',
                      '--name', 'native-sync', '--package', image, '--device', 'pixel_4'],
                     'create isolated emulator', input=b'no\n', timeout=60, env=env)
        config = avd_home / 'native-sync.avd/config.ini'
        if config.exists():
            config.write_text(re.sub(r'disk.dataPartition.size=.*',
                                    'disk.dataPartition.size=2G', config.read_text()))
        # Emulator raw output stays private too; upload only exit metadata.
        self.log = (self.directory / 'emulator.log').open('wb')
        self.process = start_owned([
            str(self.args.sdk / 'emulator/emulator'), '-avd', 'native-sync',
            '-port', str(self.args.port), '-no-window', '-no-audio', '-no-snapshot',
            '-no-boot-anim', '-no-metrics', '-accel', 'on', '-gpu', 'swiftshader',
            '-memory', '2048', '-skin', '720x1280',
            '-prop', 'qemu.sf.lcd_density=320',
        ], env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            self.require_alive('boot')
            result = self.adb_command('shell', 'getprop', 'sys.boot_completed',
                                      label='boot readiness', check=False, timeout=10)
            if result.returncode == 0 and result.stdout.strip() == b'1':
                break
            time.sleep(2)
        else:
            raise TimeoutError('isolated emulator did not boot')
        self.verify_sdk()
        self.shell('input', 'keyevent', '82', label='unlock isolated emulator')
        self.shell('settings', 'put', 'system', 'screen_off_timeout', '2147483647',
                   label='keep isolated display active')
        self.shell('svc', 'power', 'stayon', 'true', label='keep isolated display active')
        for setting in ('window_animation_scale', 'transition_animation_scale',
                        'animator_duration_scale'):
            self.shell('settings', 'put', 'global', setting, '0', label='disable emulator animation')

    def verify_sdk(self):
        value = self.shell('getprop', 'ro.build.version.sdk', label='verify emulator SDK').strip()
        if not re.fullmatch(r'[0-9]+', value) or int(value) != self.args.api:
            raise RuntimeError('actual Android SDK does not match requested API')
        self.sdk_int = int(value)
        self.event('verified-sdk', sdkInt=self.sdk_int, serial=self.serial)

    def configure(self, role):
        package = self.package(role)
        apk = self.args.apks / f'sync-acceptance-{role.lower()}.apk'
        if not apk.is_file():
            raise RuntimeError('isolated sync APK is missing')
        self.adb_command('install', '-r', str(apk), label='install owned sync fixture', timeout=180)
        info = self.shell('dumpsys', 'package', package, label='verify owned package version')
        if not re.search(r'\bversionCode=' + BUILDS[role] + r'\b', info):
            raise RuntimeError('installed sync APK version does not match role')
        self.write_private(role, CONFIG_FILE, {
            'schemaVersion': 3, 'runId': self.run_id, 'sdkInt': self.sdk_int,
            'packageName': package, 'role': role,
            'endpoint': self.relay.endpoint,
            'publicCertificatePem': self.relay.certificate,
            'invite': self.relay.invites[role],
        })
        self.event('configured-fixture', role=role, packageName=package, build=BUILDS[role])

    def read_report(self, role):
        result = self.adb_command('exec-out', 'run-as', self.package(role), 'cat',
                                  REPORT_FILE, label='read sync report', check=False, timeout=10)
        if result.returncode:
            return None
        if len(result.stdout) > 32768:
            raise ValueError('sync report exceeds protocol size limit')
        try:
            value = json.loads(result.stdout)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Atomic-report replacement may be observed during an update.
            return None
        clean = validate_report(value, role, self.run_id, self.sdk_int)
        launch = clean['launchId']
        previous = self.reports.get(role)
        if previous is not None and previous['launchId'] != launch:
            if role not in self.reopen_launches or launch == self.reopen_launches[role]:
                raise ValueError('fixture restarted without an owned force-stop')
            if role in self.reopened:
                raise ValueError('fixture restarted more than once')
            self.reopened.add(role)
            self.event('new-process-report', role=role, launchId=launch)
        if role in self.reopen_launches and launch == self.reopen_launches[role]:
            return None  # The old private report survives a process stop.
        stage = clean['stage']
        if stage not in ('boot', 'failed'):
            index = ROLE_STAGES[role].index(stage)
            previous_index = self.stage_indices.get(role, -1)
            if index < previous_index or index > previous_index + 1:
                raise ValueError('sync fixture skipped or reversed a required native stage')
            self.stage_indices[role] = index
        elif stage == 'boot' and role in self.stage_indices and role not in self.reopened:
            raise ValueError('sync fixture returned to boot in the same process')
        key = (role, launch)
        old_sequence = self.sequences.get(key, 0)
        if clean['reportSequence'] < old_sequence:
            raise ValueError('sync report sequence moved backwards')
        if clean['reportSequence'] == old_sequence and previous != clean:
            raise ValueError('sync report changed without a new sequence')
        self.sequences[key] = clean['reportSequence']
        if previous != clean:
            if previous is None or (previous['stage'], previous['launchId']) != (stage, launch):
                self.last_progress[role] = time.monotonic()
            self.event('fixture-stage', role=role, stage=clean['stage'],
                       launchId=launch, sequence=clean['reportSequence'], status=clean['status'])
        self.reports[role] = clean
        if clean['status'] != 'failed':
            self.last_running_stages[role] = stage
        elif role in self.last_running_stages:
            # Preserve independently observed progress even for older fixtures
            # that have no diagnostic object. This contains only validated IDs.
            clean['lastValidatedStage'] = self.last_running_stages[role]
        self.observed.add((role, clean['stage']))
        (self.output / f'report-{role.lower()}.json').write_text(
            json.dumps(clean, indent=2) + '\n', encoding='utf-8')
        if clean['status'] == 'failed':
            raise RuntimeError(f'native sync fixture {role} failed')
        if clean['status'] == 'passed' and role not in self.reopened:
            raise ValueError('fixture passed without a fresh process report')
        return clean

    def process_snapshot(self):
        command = ('ps',) if self.sdk_int < 26 else ('ps', '-A')
        result = self.adb_command('shell', *command, label='read process identities', timeout=5)
        # The raw ps output may contain other process names; keep it private.
        return process_identities(result.stdout.decode('utf-8'))

    def original_processes(self, role):
        package = self.package(role)
        deadline, last = time.monotonic() + 15, None
        for _ in range(3):
            self.require_alive('original process snapshot')
            if time.monotonic() >= deadline:
                break
            try:
                rows = self.process_snapshot()
                owned = {pid: row['user'] for pid, row in rows.items()
                         if row['name'] == package or row['name'].startswith(package + ':')}
                if not owned:
                    raise ValueError('owned fixture process is absent before force-stop')
                return owned
            except (RuntimeError, ValueError, UnicodeDecodeError) as error:
                last = type(error).__name__
                self.event('process-read-failed', role=role, errorType=last)
                time.sleep(0.5)
        raise RuntimeError('cannot identify original fixture processes: ' + str(last))

    def wait_for_stop(self, role, original, timeout=45):
        if not original:
            raise ValueError('force-stop requires nonempty original process identities')
        deadline, stable = time.monotonic() + timeout, 0
        while time.monotonic() < deadline:
            self.require_alive('force-stop readiness')
            ready = False
            try:
                boot = self.adb_command('shell', 'getprop', 'sys.boot_completed',
                                        label='reopen boot readiness', check=False, timeout=5)
                service = self.adb_command('shell', 'service', 'check', 'activity',
                                           label='reopen activity readiness', check=False, timeout=5)
                rows = self.process_snapshot()
                ready = (boot.returncode == 0 and boot.stdout.strip() == b'1' and
                         service.returncode == 0 and b'Service activity: found' in service.stdout and
                         all(pid not in rows or rows[pid]['user'] != user
                             for pid, user in original.items()))
            except (RuntimeError, ValueError, UnicodeDecodeError):
                pass
            stable = stable + 1 if ready else 0
            self.event('force-stop-readiness', role=role, ready=ready, consecutive=stable,
                       previousPids=sorted(original))
            if stable == 2:
                return
            time.sleep(0.5)
        raise TimeoutError('original PID/USER identity did not disappear with a healthy framework')

    def reopen(self, role, report):
        if role in self.reopen_launches:
            return
        original = self.original_processes(role)
        self.reopen_launches[role] = report['launchId']
        self.event('force-stop', role=role, previousPids=sorted(original))
        self.shell('am', 'force-stop', self.package(role), label='force-stop owned fixture', timeout=15)
        self.wait_for_stop(role, original)
        self.focus(role, 'reopen')

    def acknowledge(self, role, report):
        stage = report['stage']
        self.focus(role, stage)
        payload = {'schemaVersion': 3, 'runId': self.run_id, 'stage': stage,
                   'sdkInt': self.sdk_int, 'packageName': self.package(role),
                   'launchId': report['launchId'], 'reportSequence': report['reportSequence']}
        self.once(('ack', role, stage), lambda: self.write_private(role, CONTROL_FILE, payload))

    def read_ui(self):
        # Never write XML/screenshots/logcat to evidence: a recovery dialog or
        # the SyncScreen connection form can contain synthetic credentials.
        path = '/sdcard/sync-acceptance-ui.xml'
        try:
            self.shell('uiautomator', 'dump', path, label='read native picker UI', timeout=25)
            xml = self.shell('cat', path, label='read native picker tree', timeout=10)
            return ET.fromstring(xml)
        finally:
            # Delete sensitive guest diagnostics, including on parser failure.
            self.shell('rm', '-f', path, label='remove private picker snapshot', timeout=10)

    def tap(self, node, key):
        bounds = re.fullmatch(r'\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]',
                              node.get('bounds', ''))
        if bounds is None:
            raise ValueError('native picker control has invalid bounds')
        left, top, right, bottom = map(int, bounds.groups())
        if right <= left or bottom <= top:
            raise ValueError('native picker control is not visible')
        return self.once(key, lambda: self.shell(
            'input', 'tap', str((left + right) // 2), str((top + bottom) // 2),
            label='tap owned native picker'))

    def picker(self, role, report):
        stage = report['stage']
        key = (role, stage, report['launchId'])
        state = self.stages.setdefault(key, {})
        if state.get('done') or self.foreground_role != role:
            return
        # Do not am-start over an already open DocumentsUI activity: the fixture
        # launched SAF itself. Control acknowledgements/initial launch selected
        # the correct foreground owner before that stage was entered.
        tree = self.read_ui()
        nodes = [node for node in tree.iter('node')
                 if node.get('package') in ('com.android.documentsui', 'com.google.android.documentsui')
                 and node.get('enabled') == 'true']
        if not nodes:
            return
        ime = self.shell('dumpsys', 'input_method', label='observe picker keyboard', timeout=10)
        if re.search(r'\bmInputShown=true\b', ime):
            phase = 'edited' if ('filename-set', *key) in self.actions else 'initial'
            self.once(('hide-ime', phase, *key), lambda: self.shell(
                'input', 'keyevent', '4', label='hide picker keyboard'))
            return

        def unique(predicate):
            matches = [node for node in nodes if predicate(node)]
            if len(matches) > 1:
                raise ValueError('ambiguous native picker control')
            return matches[0] if matches else None

        save = SAF_STAGES[stage] == 'save'
        if save:
            field = unique(lambda node: node.get('resource-id') == 'android:id/title'
                           and node.get('class', '').endswith('EditText'))
            if field is not None and field.get('text') != report['documentName']:
                # The production picker supplies its own timestamp name. Set an
                # exact synthetic filename using real Android input, once.
                self.tap(field, ('filename-focus', *key))
                if self.once(('filename-set', *key), lambda: self.set_filename(
                        report['documentName'], field.get('text', ''))):
                    return
                raise ValueError('native picker filename did not change after one edit')
            button = unique(lambda node: node.get('text', '').upper() == 'SAVE'
                            and node.get('clickable') == 'true')
            if button is not None:
                # Require the filename field to prove that this run owns output.
                if field is None or field.get('text') != report['documentName']:
                    return
                self.tap(button, ('save', *key))
                state['done'] = True
                self.event('saf-action', role=role, stage=stage, action='save')
                return
        else:
            layout = unique(lambda node: node.get('content-desc') == 'List view')
            if layout is not None and self.tap(layout, ('list', *key)):
                return
            button = unique(lambda node: node.get('text', '').upper() == 'OPEN'
                            and node.get('clickable') == 'true')
            if state.get('selected') and button is not None:
                self.tap(button, ('open', *key))
                state['done'] = True
                return
            item = unique(lambda node: node.get('text') == report['documentName']
                          and not node.get('class', '').endswith('EditText'))
            if item is not None:
                self.tap(item, ('select', *key))
                state['selected'] = True
                self.event('saf-action', role=role, stage=stage, action='select')
                return
        downloads = unique(lambda node: node.get('text') == 'Downloads')
        if downloads is not None and self.tap(downloads, ('downloads', *key)):
            return
        roots = unique(lambda node: node.get('content-desc') in ('Show roots', 'Show navigation drawer'))
        if roots is not None:
            self.tap(roots, ('roots', *key))

    def set_filename(self, name, previous):
        if not re.fullmatch(r'sync-[0-9a-f]{32}(?:-[AB])?\.(?:hgr|hgb)', name):
            raise ValueError('invalid synthetic SAF filename')
        self.shell('input', 'keyevent', '123', label='move picker filename cursor')
        if not isinstance(previous, str) or not 1 <= len(previous) <= 256:
            raise ValueError('native picker filename has an unexpected length')
        # Delete exactly the observed filename length after moving to its end.
        # This uses Android's stable keyevent command, without modifier/IME hacks.
        self.shell('input', 'keyevent', *(['67'] * len(previous)), label='clear picker filename')
        self.shell('input', 'text', name, label='set synthetic picker filename')

    def run_protocol(self):
        self.deadline = time.monotonic() + self.args.total_timeout
        self.adb_command('reverse', f'tcp:{self.relay.port}', f'tcp:{self.relay.port}',
                         label='reverse isolated HTTPS port', timeout=15)
        self.reverse_created = True
        for role in ('A', 'B'):
            self.configure(role)
        self.focus('B', 'initial')
        self.last_progress['B'] = time.monotonic()
        # B must be waiting before A takes foreground for its first SAF dialog.
        first_deadline = time.monotonic() + self.args.stage_timeout
        while time.monotonic() < first_deadline:
            self.require_alive('initial source gate')
            value = self.read_report('B')
            if value is not None and value['stage'] == 'awaitingSourceUpload':
                break
            time.sleep(1)
        else:
            raise TimeoutError('replica did not reach its source gate')
        self.focus('A', 'initial')
        self.last_progress['A'] = time.monotonic()
        while True:
            self.require_alive('sync protocol')
            for role in ('A', 'B'):
                value = self.read_report(role)
                if value is None:
                    if time.monotonic() - self.last_progress[role] > self.args.stage_timeout:
                        raise TimeoutError(f'fixture {role} did not produce a fresh report')
                    continue
                stage = value['stage']
                if stage in SAF_STAGES:
                    self.picker(role, value)
                elif (role, stage) in CONTROL_PREREQUISITES:
                    required = CONTROL_PREREQUISITES[(role, stage)]
                    if required in self.observed:
                        self.acknowledge(role, value)
                elif stage == 'awaitingReopen':
                    # Release B's convergence gate before stopping A; the last
                    # marker report must remain sufficient for that handshake.
                    if role == 'A' and ('B', 'awaitingConvergence') in self.observed:
                        other = self.reports['B']
                        self.acknowledge('B', other)
                    # Serialize the post-reopen backup pickers so the two owned
                    # clients never compete for the same DocumentsUI foreground.
                    if role == 'A' or self.reports.get('A', {}).get('status') == 'passed':
                        self.reopen(role, value)
                if value['status'] != 'passed' and time.monotonic() - self.last_progress[role] > self.args.stage_timeout:
                    raise TimeoutError(f'fixture {role} exceeded its stage timeout')
            if all(self.reports.get(role, {}).get('status') == 'passed' for role in PACKAGES):
                break
            time.sleep(1)
        results = [self.reports[role] for role in ('A', 'B')]
        for phase in ('initial', 'converged'):
            if results[0]['evidence'][phase + 'ActualFactsSha256'] != results[1]['evidence'][phase + 'ActualFactsSha256']:
                raise ValueError('independent native clients did not converge on the same complete facts')
        (self.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
        self.event('complete', sdkInt=self.sdk_int, runId=self.run_id,
                   packages=list(PACKAGES.values()), nativeSyncResults=len(RESULT_FLAGS))
        print(f'API {self.sdk_int}: real TLS SyncScreen, SAF, conflict merge, SQLite/Keystore reopen and offline backups passed')

    def close(self):
        # Each diagnostic is independent and cannot replace the primary failure.
        actions = [('emulator-status', lambda: self.event(
            'emulator-status', exit=None if self.process is None else self.process.poll())),
            ('remove-port-reverse', lambda: self.adb_command(
                'reverse', '--remove', f'tcp:{self.relay.port}',
                label='remove owned HTTPS reverse', timeout=5, check=False)
                if self.reverse_created else None),
            ('stop-emulator', lambda: stop_process(self.process)),
            ('close-emulator-log', lambda: self.log.close() if self.log is not None else None)]
        for label, action in actions:
            try:
                action()
            except Exception as error:
                try:
                    self.event('cleanup-failed', operation=label, errorType=type(error).__name__)
                except OSError:
                    pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api', type=int, required=True, choices=(35,))
    parser.add_argument('--apks', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=5556)
    parser.add_argument('--go', default=shutil.which('go'))
    parser.add_argument('--stage-timeout', type=int, default=180)
    parser.add_argument('--total-timeout', type=int, default=1200)
    args = parser.parse_args(argv)
    if sys.platform != 'linux':
        parser.error('native sync acceptance runs only on disposable Linux CI runners')
    if args.port < 5554 or args.port > 5682 or args.port % 2:
        parser.error('--port must be an even emulator console port from 5554 to 5682')
    if not args.go:
        parser.error('Go executable was not found on PATH')
    if not 30 <= args.stage_timeout <= 300 or not args.stage_timeout <= args.total_timeout <= 1800:
        parser.error('timeouts must be bounded: stage 30..300, total stage..1800 seconds')
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        parser.error('ANDROID_HOME or ANDROID_SDK_ROOT is required')
    args.sdk = Path(sdk)
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('--output must be empty so only sanitized evidence can be uploaded')
    args.output.mkdir(parents=True, exist_ok=True)
    args.output = args.output.resolve()
    args.apks = args.apks.resolve()
    # Temp root contains all generated account material, relay DB and AVD data.
    with tempfile.TemporaryDirectory(prefix='haoxiguan-native-sync-') as temporary:
        private = Path(temporary)
        private.chmod(0o700)
        relay = DisposableRelay(private / 'relay', args.go)
        driver = NativeSyncDriver(args, private / 'device', relay)
        try:
            relay.start()
            driver.start_emulator()
            driver.run_protocol()
        except BaseException as error:
            # Avoid exception messages/tracebacks, which can contain CLI output
            # or credentials after JSON/HTTP/Android failures.
            failure = {'errorType': type(error).__name__, 'runId': driver.run_id,
                       'sdkInt': driver.sdk_int,
                       'stages': {role: value['stage'] for role, value in driver.reports.items()},
                       'lastValidatedStages': dict(driver.last_running_stages),
                       'fixtureFailures': {role: {key: value[key] for key in
                            ('errorCode', 'diagnostic', 'lastValidatedStage') if key in value}
                            for role, value in driver.reports.items() if value['status'] == 'failed'},
                       'emulatorExit': None if driver.process is None else driver.process.poll()}
            try:
                (args.output / 'failure.json').write_text(json.dumps(failure, indent=2) + '\n')
            except OSError:
                pass
            print('Native sync acceptance failed; inspect sanitized protocol evidence', file=sys.stderr)
            return 1
        finally:
            driver.close()
            try:
                relay.close()
            except Exception as error:
                driver.event('cleanup-failed', operation='stop-relay', errorType=type(error).__name__)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
