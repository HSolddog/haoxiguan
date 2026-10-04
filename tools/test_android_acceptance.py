"""Host-only regression tests; no SDK, Android device, or network is touched."""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location('acceptance_driver', Path(__file__).with_name('run_android_acceptance.py'))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def result(stdout=b'', code=0, stderr=b''):
    return subprocess.CompletedProcess(['adb'], code, stdout, stderr)


def probe_result(saved=None, code=0, stderr=b''):
    return result((driver.report_probe_prefix + ('ABSENT\n' if saved is None else 'EXISTS\n')).encode() +
                  (b'' if saved is None else json.dumps(saved).encode()), code=code, stderr=stderr)


def engine_proof(value):
    host = {'package': driver.package, 'build': value['build'], 'pid': value['ownerPid'],
            'engineId': 'c'*32, 'hostId': 'd'*32, 'attachCount': 1,
            'attached': True, 'uiDisplayed': True, 'executingDart': True}
    return {'runId': value['runId'], 'nonce': value['launchNonce'], 'entryId': value['entryId'],
            'requestId': 'f'*32, 'before': host, 'after': {**host, 'hostId': 'e'*32, 'attachCount': 2,
                'requestId': 'f'*32, 'requestHostId': host['hostId'], 'requestOutcome': 'executed'},
            'firstRunningReportUnchanged': True,
            'semanticsResend': {'method': 'existingTreeDetachAttach', 'views': [
                {'rootId': 0, 'nodeIds': [0, 1], 'completeNodeCount': 2, 'nodeIdsPreserved': True}]}}


def passed_predecessor(build='10001', phase='reopen', run_id='122'):
    value = {'package': driver.package, 'build': build, 'phase': phase, 'status': 'passed', 'runId': run_id,
             'schema': 2 if build == '10001' else 3, 'launchNonce': 'a' * 32,
             'ownerPid': 11, 'entryId': 'b' * 32, 'previousRunId': None if phase == 'create' else '121',
             'habits': 3, 'nativeCrypto': True, 'keystore': True, 'backupConfigured': False, 'syncConfigured': False}
    value.update({'nativeEngineRecreation': True, 'nativeEngineRecreationEvidence': engine_proof(value)})
    if build == '10002':
        value.update({'notificationApiLevel': 24, 'nativeChannelDiagnosis': 'notApplicable', 'nativeChannelRecovery': 'notApplicable',
                      **{field: True for field in ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit',
                         'nativeReminderScheduling', 'workManagerRenewal', 'periodicTasksRegistered',
                         'nativeDeniedHabitSaved', 'nativeAppPermissionDiagnosis', 'nativeAppPermissionRecovery',
                         'nativeRestorePreviewCancel', 'nativeRestoreProtection', 'nativeRestoreConfirm', 'nativeRestoreReopen')}})
    return value


def process_list(*pids):
    # Actual Android 7 toolbox output has an unlabelled state before NAME.
    return ('USER PID PPID VSIZE RSS WCHAN PC NAME\nroot 1 0 100 50 0 0000000000 S /init\n' + ''.join(
        f'u0_a62 {pid} 1 100 50 0 0000000000 S {driver.package}\n' for pid in pids)).encode()


def ui_xml(label, checked=None, owner='com.android.settings', title='好习惯隔离验收'):
    root = ET.Element('hierarchy')
    screen = ET.SubElement(root, 'node', {'package': owner})
    title_attributes = {'package': owner, 'text': title}
    if title == '习惯提醒':
        title_attributes['resource-id'] = 'com.android.settings:id/collapsing_toolbar'
    ET.SubElement(screen, 'node', title_attributes)
    row = ET.SubElement(screen, 'node', {'package': owner, 'clickable': 'true'})
    ET.SubElement(row, 'node', {'package': owner, 'text': label, 'enabled': 'true',
                              'clickable': 'true', 'bounds': '[10,20][100,70]'})
    if checked is not None:
        ET.SubElement(row, 'node', {'package': owner, 'class': 'android.widget.Switch',
                                  'resource-id': 'android:id/switch_widget',
                                  'checkable': 'true', 'checked': checked, 'enabled': 'true',
                                  'bounds': '[110,20][150,70]'})
    return ET.tostring(root, encoding='unicode')


class AndroidAcceptanceDriverTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        driver.args = SimpleNamespace(output=Path(self.directory.name), api=24)
        driver.adb = 'adb'
        driver.adb_serial = 'emulator-5580'
        driver.process = Mock(pid=123)
        driver.process.poll.return_value = None
        driver.ui_stages.clear()
        driver.device_api = 24
        self.launch_patch = patch.object(driver, 'prepare_launch', return_value='a' * 32)
        self.launch_patch.start()
        self.addCleanup(self.launch_patch.stop)

    def events(self):
        return [json.loads(line) for line in (driver.args.output/'driver-events.jsonl').read_text().splitlines()]

    def test_adb_commands_always_target_the_isolated_serial(self):
        with patch.object(driver.subprocess, 'run', return_value=result()) as run:
            driver.command('adb', 'shell', 'am', 'force-stop', driver.package)
        self.assertEqual(run.call_args.args[0], ['adb', '-s', 'emulator-5580', 'shell', 'am', 'force-stop', driver.package])
        self.assertEqual(driver.adb_values('logcat'), ['adb', '-s', 'emulator-5580', 'logcat'])

    def test_existing_target_device_is_rejected_even_when_offline(self):
        for status in ('device', 'offline'):
            with self.subTest(status=status), patch.object(driver.subprocess, 'run', return_value=result(f'List of devices attached\nemulator-5580\t{status}\n'.encode())):
                with self.assertRaisesRegex(RuntimeError, 'already present'):
                    driver.require_unused_serial()

    def test_other_devices_are_only_enumerated_never_selected(self):
        with patch.object(driver.subprocess, 'run', return_value=result(b'List of devices attached\nphysical-phone\tdevice\n')) as run:
            driver.require_unused_serial()
        self.assertEqual(run.call_args.args[0], ['adb', 'devices'])
        self.assertEqual(driver.adb_values('shell', 'getprop')[:3], ['adb', '-s', 'emulator-5580'])

    def test_closed_mutating_command_is_never_replayed(self):
        for code in (1, 255):
            with self.subTest(code=code), patch.object(driver.subprocess, 'run', return_value=result(code=code, stderr=b'error: closed\n')) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    driver.shell('am', 'start', '-n', driver.activity)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(self.events()[-1]['stderr'], 'error: closed\n')

    def test_transient_read_255_is_bounded_and_can_recover(self):
        with patch.object(driver.subprocess, 'run', side_effect=[result(code=255), result(b'ready')]) as run, patch.object(driver.time, 'sleep'):
            self.assertEqual(driver.shell('getprop', 'sys.boot_completed'), 'ready')
            self.assertEqual(run.call_count, 2)

    def test_persistent_read_255_fails_after_three_attempts(self):
        with patch.object(driver.subprocess, 'run', return_value=result(code=255)) as run, patch.object(driver.time, 'sleep'):
            with self.assertRaises(subprocess.CalledProcessError):
                driver.shell('getprop', 'sys.boot_completed')
            self.assertEqual(run.call_count, 3)

    def test_reopen_waits_for_old_pid_exit_and_two_consecutive_ready_reads(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(process_list())]
        replies = [result(code=1), healthy[1], healthy[2], *healthy,
                   healthy[0], healthy[1], result(process_list(2976)), *healthy, *healthy]
        with patch.object(driver, 'command', side_effect=replies) as command, patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen({2976: 'u0_a62'})
        self.assertEqual(command.call_count, 15)
        self.assertFalse(any('am' in call.args for call in command.call_args_list))
        self.assertEqual([event['consecutive'] for event in self.events()], [0, 1, 0, 1, 2])

    def test_reopen_wait_has_deadline_and_does_not_start_activity(self):
        with patch.object(driver, 'command', return_value=result(code=255)) as command, patch.object(driver.time, 'monotonic', side_effect=range(100)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.wait_for_reopen({2976: 'u0_a62'}, timeout=5)
        self.assertLessEqual(command.call_count, 9)
        self.assertFalse(any('am' in call.args for call in command.call_args_list))

    def test_background_replacement_pid_does_not_block_reopen(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(process_list(3525))]
        with patch.object(driver, 'command', side_effect=healthy * 2) as command, patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen({2976: 'u0_a62'})
        self.assertEqual(command.call_count, 6)
        self.assertEqual(self.events()[-1]['previousPids'], [2976])
        self.assertEqual(self.events()[-1]['currentPids'], [1, 3525])

    def test_original_pid_still_alive_fails_even_if_a_new_pid_exists(self):
        def command(*values, **kwargs):
            if 'getprop' in values:
                return result(b'1')
            if 'service' in values:
                return result(b'Service activity: found')
            return result(process_list(2976, 3525))
        with patch.object(driver, 'command', side_effect=command), patch.object(driver.time, 'monotonic', side_effect=range(100)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.wait_for_reopen({2976: 'u0_a62'}, timeout=15)
        self.assertFalse(any(event['ready'] for event in self.events()))

    def test_failed_or_malformed_reads_never_count_as_pid_disappearance(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(process_list(3525))]
        for broken in (result(process_list(), code=255), result(b''), result(b'USER PID NAME\n'),
                       result(b'USER PID NAME\nu0_a62'), result(b'closed transport')):
            with self.subTest(broken=broken.stdout):
                replies = [*healthy, healthy[0], healthy[1], broken, *healthy, *healthy]
                with patch.object(driver, 'command', side_effect=replies) as command, patch.object(driver.time, 'sleep'):
                    driver.wait_for_reopen({2976: 'u0_a62'})
                self.assertEqual(command.call_count, 12)
                events = self.events()[-4:]
                self.assertEqual([e['consecutive'] for e in events], [1, 0, 1, 2])
                self.assertIsNone(events[1]['currentPids'])
                self.assertTrue(events[1]['readError'])

    def test_reopen_requires_original_process_identity(self):
        with patch.object(driver, 'command') as command:
            with self.assertRaises(ValueError):
                driver.wait_for_reopen(set())
        command.assert_not_called()

    def test_timed_out_read_resets_the_consecutive_ready_observations(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(process_list(3525))]
        replies = [*healthy, subprocess.TimeoutExpired(['adb', 'getprop'], 5), *healthy, *healthy]
        with patch.object(driver, 'command', side_effect=replies), patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen({2976: 'u0_a62'})
        self.assertEqual([e['consecutive'] for e in self.events()], [1, 0, 1, 2])
        self.assertIsNone(self.events()[1]['currentPids'])

    def test_process_parser_tracks_exact_app_and_colon_process_names(self):
        text = (process_list(2976).decode() +
                f'u0_a62 3525 1 100 50 0 0000000000 S {driver.package}:worker\n' +
                f'u0_a62 4000 1 100 50 0 0000000000 S {driver.package}.other\n')
        self.assertEqual(driver.app_process_ids(text), {2976, 3525})
        modern = f'USER PID PPID VSZ RSS WCHAN ADDR S NAME\nu0_a62 2976 1 100 50 0 0000000000 S {driver.package}\n'
        self.assertEqual(driver.app_process_ids(modern), {2976})
        with self.assertRaises(ValueError):
            driver.app_process_ids('UID PID PPID C STIME TTY TIME CMD\nroot 1 0 0 00:00 ? 00:00 /init\n')
        self.assertEqual(driver.process_list_command(), ('ps',))
        driver.args.api = 35
        self.assertEqual(driver.process_list_command(), ('ps', '-A'))

    def test_android7_missing_or_invalid_unlabelled_state_is_not_an_empty_pid_set(self):
        header = 'USER PID PPID VSIZE RSS WCHAN PC NAME\n'
        for state in ('', 'SS', '0'):
            with self.subTest(state=state), self.assertRaises(ValueError):
                driver.app_process_ids(header + f'u0_a62 2976 1 100 50 0 0000000000 {state} {driver.package}\n')

    def test_android7_legal_empty_wchan_and_spaced_name_preserve_identities(self):
        text = (process_list().decode() +
                f'u0_a62 2976 1 100 50            0000000000 S {driver.package}\n' +
                'root 40 1 100 50 futex_wait 0000000000 S worker pool\n')
        self.assertEqual(driver.app_process_ids(text), {2976})
        self.assertEqual(driver.process_identities(text)[40]['name'], 'worker pool')
        modern = 'USER PID PPID VSZ RSS WCHAN ADDR S NAME\nroot 40 1 100 50 - 0 S worker pool\n'
        self.assertEqual(driver.process_identities(modern)[40]['name'], 'worker pool')

    def test_duplicate_pid_and_nonterminal_name_column_are_rejected(self):
        for text in (process_list(2976, 2976).decode(), 'USER PID NAME S\nroot 1 /init S\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                driver.process_identities(text)

    def test_original_process_snapshot_retries_reads_and_preserves_raw_failure(self):
        broken = b'USER PID NAME\nroot \xff /init\n'
        with patch.object(driver, 'command', side_effect=[result(broken), result(process_list(2976))]) as command, patch.object(driver.time, 'sleep'):
            self.assertEqual(driver.original_app_processes(), {2976: 'u0_a62'})
        self.assertEqual(command.call_count, 2)
        raw = list(driver.args.output.glob('processes-*-before-stop.txt'))
        self.assertIn(broken, [p.read_bytes() for p in raw])
        self.assertFalse(any('am' in call.args for call in command.call_args_list))

    def test_original_snapshot_permanent_failure_is_bounded(self):
        with patch.object(driver, 'command', return_value=result(b'broken')) as command, patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'could not identify'):
                driver.original_app_processes()
        self.assertEqual(command.call_count, 3)

    def test_timed_out_process_read_preserves_partial_original_bytes(self):
        failure = subprocess.TimeoutExpired(['adb', 'ps'], 5, output=b'USER PID', stderr=b'closed')
        with patch.object(driver, 'command', side_effect=failure), self.assertRaises(subprocess.TimeoutExpired):
            driver.read_process_snapshot('timeout', 5)
        self.assertEqual(next(driver.args.output.glob('processes-*-timeout.txt')).read_bytes(), b'USER PID')
        self.assertEqual(next(driver.args.output.glob('processes-*-timeout.stderr.txt')).read_bytes(), b'closed')

    def test_modern_malformed_columns_cannot_imply_original_process_exit(self):
        header = 'USER PID PPID VSZ RSS WCHAN ADDR S NAME\n'
        for row in ('root 1 BAD BAD BAD 0 NOTHEX SS /init',
                    'root 1 0 100 50 0000000000 S /init with spaces',
                    '\x00 2976 1 100 50 0 0 S /init',
                    'root 1 \u0661 100 50 0 0 S /init'):
            with self.subTest(row=row), self.assertRaises(ValueError):
                driver.process_identities(header + row)

    def test_android7_fields_match_official_ascii_and_widths(self):
        header = 'USER PID PPID VSIZE RSS WCHAN PC NAME\n'
        for row in ('root \u0661 0 100 50 0 0000000000 S /init',
                    'root 1 0 100 50 0 000000000 S /init',
                    'root 1 0 100 50 toolongsymbol 0000000000 S /init'):
            with self.subTest(row=row), self.assertRaises(ValueError):
                driver.process_identities(header + row)

    def test_same_pid_user_still_blocks_if_name_changes(self):
        renamed = process_list(2976).replace(driver.package.encode(), b'worker pool')
        def command(*values, **kwargs):
            if 'getprop' in values:
                return result(b'1')
            if 'service' in values:
                return result(b'Service activity: found')
            return result(renamed)
        with patch.object(driver, 'command', side_effect=command), patch.object(driver.time, 'monotonic', side_effect=range(100)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.wait_for_reopen({2976: 'u0_a62'}, timeout=15)
        self.assertFalse(any(e.get('ready') for e in self.events()))

    def test_pid_reused_by_another_user_is_not_original_identity(self):
        reused = process_list(2976).replace(b'u0_a62', b'u0_a99')
        healthy = [result(b'1'), result(b'Service activity: found'), result(reused)]
        with patch.object(driver, 'command', side_effect=healthy * 2), patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen({2976: 'u0_a62'})
        self.assertEqual(self.events()[-1]['consecutive'], 2)

    def test_invalid_utf8_read_cannot_change_original_user_identity(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(process_list())]
        corrupt = result(process_list(2976).replace(b'u0_a62', b'u0_a\xff2'))
        with patch.object(driver, 'command', side_effect=[healthy[0], healthy[1], corrupt, *healthy, *healthy]), patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen({2976: 'u0_a62'})
        self.assertEqual([e['consecutive'] for e in self.events()], [0, 1, 2])

    def test_device_api_is_read_and_must_match_requested_image(self):
        with patch.object(driver, 'shell', return_value='24\n'):
            driver.verify_device_api()
        self.assertEqual(driver.device_api, 24)
        for value in ('35', 'unknown', ''):
            with self.subTest(value=value), patch.object(driver, 'shell', return_value=value), self.assertRaises(RuntimeError):
                driver.verify_device_api()

    def image_metadata(self):
        driver.sdk = Path(self.directory.name)/'sdk'
        image = 'system-images;android-35;google_apis_ps16k;x86_64'
        directory = driver.sdk/image.replace(';', '/')
        directory.mkdir(parents=True, exist_ok=True)
        (directory/'package.xml').write_bytes(b'<package revision="5"/>\n')
        (directory/'source.properties').write_bytes(b'AndroidVersion.ApiLevel=35\nSystemImage.Abi=x86_64\n')
        driver.args.expected_page_size = 16384
        driver.device_api = 35
        driver.device_page_size = None
        return image

    def test_page_size_requires_actual_exact_read_and_preserves_image_metadata(self):
        image = self.image_metadata()
        with patch.object(driver, 'command', return_value=result(b'16384\n')) as command, patch.object(driver, 'shell', return_value='35'):
            driver.verify_page_size(image)
        self.assertEqual(command.call_args.args, ('adb', 'shell', 'getconf', 'PAGE_SIZE'))
        self.assertEqual((driver.args.output/'device-page-size.txt').read_bytes(), b'16384\n')
        self.assertEqual((driver.args.output/'system-image-package.xml').read_bytes(), b'<package revision="5"/>\n')
        self.assertEqual(json.loads((driver.args.output/'device-environment.json').read_text())['pageSize'], 16384)
        self.assertEqual(driver.device_page_size, 16384)
        self.assertEqual(self.events()[-1]['image'], image)

    def test_wrong_failed_ambiguous_or_noisy_page_size_cannot_pass(self):
        image = self.image_metadata()
        for reply in (result(b'4096\n'), result(b'16384\n', code=1), result(b'16384\n', stderr=b'error\n'),
                      result(b'16384 4096\n'), result(b'warning\n16384\n'), result(b' 16384\n'), result(b'')):
            with self.subTest(reply=reply), patch.object(driver, 'command', return_value=reply), patch.object(driver, 'shell') as shell:
                with self.assertRaisesRegex(RuntimeError, 'APK installation refused'):
                    driver.verify_page_size(image)
                self.assertEqual((driver.args.output/'device-page-size.txt').read_bytes(), reply.stdout)
                self.assertEqual((driver.args.output/'device-page-size.stderr.txt').read_bytes(), reply.stderr)
                shell.assert_not_called()
        self.assertIsNone(driver.device_page_size)

    def test_page_size_timeout_keeps_raw_partial_output(self):
        image = self.image_metadata()
        failure = subprocess.TimeoutExpired(['adb'], 15, output=b'163', stderr=b'closed')
        with patch.object(driver, 'command', side_effect=failure), self.assertRaises(subprocess.TimeoutExpired):
            driver.verify_page_size(image)
        self.assertEqual((driver.args.output/'device-page-size.txt').read_bytes(), b'163')
        self.assertEqual((driver.args.output/'device-page-size.stderr.txt').read_bytes(), b'closed')

    def test_16k_target_cannot_omit_the_runtime_gate_or_use_an_old_api(self):
        base = ['--api', '35', '--apks', self.directory.name, '--output', self.directory.name,
                '--image-target', 'google_apis_ps16k']
        for values in (base, base + ['--expected-page-size', '4096'],
                       [value if value != '35' else '24' for value in base] + ['--expected-page-size', '16384']):
            with self.subTest(values=values), patch.dict(os.environ, {}, clear=True), patch.object(driver.subprocess, 'run') as run:
                with patch('sys.stderr', new=io.StringIO()), self.assertRaises(SystemExit):
                    driver.main(values)
                run.assert_not_called()

    def test_main_rejects_a_4k_guest_before_any_apk_or_product_installation(self):
        self.image_metadata()
        env = {'ANDROID_HOME': str(driver.sdk)}
        def reply(*values, **kwargs):
            return result(b'4096\n' if 'getconf' in values else b'1\n')
        def cleanup(process, log, *others):
            log.close()
        with patch.dict(os.environ, env), patch.object(driver.Path, 'cwd', return_value=Path(self.directory.name)), \
                patch.object(driver.subprocess, 'run'), patch.object(driver.subprocess, 'Popen', return_value=driver.process), \
                patch.object(driver, 'command', side_effect=reply) as command, \
                patch.object(driver, 'require_unused_serial'), patch.object(driver, 'shell', return_value='35'), \
                patch.object(driver, 'find_aapt') as aapt, patch.object(driver, 'verify_product_startup') as product, \
                patch.object(driver, 'collect_diagnostics', side_effect=cleanup):
            with self.assertRaisesRegex(RuntimeError, 'APK installation refused'):
                driver.main(['--api', '35', '--apks', self.directory.name, '--output', self.directory.name,
                             '--image-target', 'google_apis_ps16k', '--expected-page-size', '16384'])
        aapt.assert_not_called()
        product.assert_not_called()
        self.assertFalse(any('install' in call.args for call in command.call_args_list))
        self.assertEqual((driver.args.output/'device-page-size.txt').read_bytes(), b'4096\n')

    def product_badging(self):
        raw = (Path(driver.__file__).resolve().parent.parent/'pubspec.yaml').read_text(encoding='utf-8')
        name, code = re.findall(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)\s*$', raw, re.MULTILINE)[0]
        return (f"package: name='{driver.product_package}' versionCode='{code}' versionName='{name}'\n"
                f"application-label:'{driver.product_label}'\napplication-debuggable\n"
                f"launchable-activity: name='{driver.product_package}.MainActivity' label='{driver.product_label}'\n")

    def test_product_apk_requires_current_source_identity_and_never_accepts_fixture(self):
        apk = Path(self.directory.name)/'product.apk'
        apk.write_bytes(b'synthetic-apk')
        badging = self.product_badging()
        with patch.object(driver, 'command', return_value=result(badging.encode())):
            identity = driver.verify_product_apk(apk, 'aapt')
        self.assertEqual(identity['package'], driver.product_package)
        self.assertRegex(identity['sha256'], r'^[0-9a-f]{64}$')
        rejected = (badging.replace(driver.product_package, driver.package),
                    badging.replace(driver.product_label, 'Other app'),
                    re.sub(r"versionCode='[0-9]+'", "versionCode='10002'", badging),
                    re.sub(r"versionName='[^']+'", "versionName='0.0.0'", badging),
                    badging.replace('application-debuggable\n', ''), badging.replace('.MainActivity', '.OtherActivity'),
                    badging + f"application-label:'{driver.product_label}'\n")
        for other in rejected:
            with self.subTest(badging=other), patch.object(driver, 'command', return_value=result(other.encode())), self.assertRaises(ValueError):
                driver.verify_product_apk(apk, 'aapt')
        self.assertEqual(len(self.events()), 1)

    def product_response(self, *values, **kwargs):
        if 'install' in values:
            return result(b'Performing Streamed Install\nSuccess\n')
        if 'start' in values:
            return result(f'Status: ok\nActivity: {driver.product_package}/.MainActivity\nComplete\n'.encode())
        if 'ps' in values:
            return result(process_list(3001).replace(driver.package.encode(), driver.product_package.encode()))
        if 'logcat' in values:
            return result(b'07-13 10:30:00.000 3001 3001 I flutter : first frame\n')
        if 'activities' in values:
            return result(f'  topResumedActivity=ActivityRecord{{abc u0 {driver.product_package}/.MainActivity t3}}\n'.encode())
        if 'screencap' in values:
            return result(b'png')
        self.fail(f'unexpected product command: {values}')

    def test_product_startup_requires_launch_pid_crash_check_resumed_activity_and_evidence(self):
        driver.device_page_size = 16384
        identity = {'package': driver.product_package}
        with patch.object(driver, 'verify_product_apk', return_value=identity), \
                patch.object(driver, 'command', side_effect=self.product_response) as command, \
                patch.object(driver.time, 'sleep'), patch.object(driver, 'shell') as shell:
            driver.verify_product_startup(Path('product.apk'), 'aapt')
        saved = json.loads((driver.args.output/'product-startup.json').read_text())
        self.assertEqual(saved['pageSize'], 16384)
        self.assertEqual([row['pid'] for row in saved['observations']], [3001, 3001, 3001])
        self.assertFalse(saved['nativeCrashObserved'])
        self.assertEqual((driver.args.output/'product-startup.png').read_bytes(), b'png')
        shell.assert_called_once_with('am', 'force-stop', driver.product_package)
        self.assertEqual(sum('--pid=3001' in call.args for call in command.call_args_list), 3)

    def test_product_startup_rejects_failed_launch_crash_pid_replacement_or_wrong_foreground(self):
        cases = {
            'install': result(b'Failure [INSTALL_FAILED_INVALID_APK]\n'),
            'start': result(b'Error: Activity class does not exist.\n'),
            'logcat': result(b'Fatal signal 11 (SIGSEGV), pid 3001\n'),
            'ps': result(process_list(3001).replace(driver.package.encode(), b'other.application')),
            'activities': result(b'topResumedActivity=ActivityRecord{abc u0 other.application/.MainActivity t3}\n'),
        }
        for broken, value in cases.items():
            def reply(*values, **kwargs):
                return value if broken in values else self.product_response(*values, **kwargs)
            with self.subTest(broken=broken), patch.object(driver, 'verify_product_apk', return_value={}), \
                    patch.object(driver, 'command', side_effect=reply), patch.object(driver.time, 'sleep'), \
                    patch.object(driver, 'shell') as shell, self.assertRaises(RuntimeError):
                driver.verify_product_startup(Path('product.apk'), 'aapt')
            shell.assert_not_called()
            self.assertFalse((driver.args.output/'product-startup.json').exists())

    def test_product_pid_restart_cannot_pass_as_stable_startup(self):
        snapshots = 0
        def reply(*values, **kwargs):
            nonlocal snapshots
            if 'ps' in values:
                snapshots += 1
                return result(process_list(3000 + snapshots).replace(driver.package.encode(), driver.product_package.encode()))
            return self.product_response(*values, **kwargs)
        with patch.object(driver, 'verify_product_apk', return_value={}), patch.object(driver, 'command', side_effect=reply), \
                patch.object(driver.time, 'sleep'), patch.object(driver, 'shell') as shell:
            with self.assertRaisesRegex(RuntimeError, 'original application process'):
                driver.verify_product_startup(Path('product.apk'), 'aapt')
        shell.assert_not_called()

    def test_actual_apk_identity_is_closed_to_the_isolated_label_package_and_build(self):
        apk = Path(self.directory.name)/'acceptance-10002.apk'
        aapt = Path(self.directory.name)/'sdk/build-tools/36.0.0/aapt'
        badging = ("package: name='com.haoxiguan.haoxiguan.acceptance' versionCode='10002' versionName='1.2.0'\n"
                   "application-label:'好习惯隔离验收'\n")
        with patch.object(driver, 'command', return_value=result(badging.encode('utf-8'))) as command:
            driver.verify_fixture_apk(apk, 10002, aapt)
        self.assertEqual(command.call_args.args, (str(aapt), 'dump', 'badging', str(apk)))
        self.assertEqual((driver.args.output/'apk-10002-badging.txt').read_text(encoding='utf-8'), badging)
        self.assertEqual(self.events()[-1]['package'], 'com.haoxiguan.haoxiguan.acceptance')
        rejected = (badging.replace('.acceptance', ''), badging.replace('10002', '10001'),
                    badging.replace('好习惯隔离验收', '好习惯'), badging.replace('好习惯隔离验收', 'Other app'),
                    badging + "application-label:'好习惯隔离验收'\n", badging.splitlines()[0] + '\n')
        for other in rejected:
            with self.subTest(badging=other), patch.object(driver, 'command', return_value=result(other.encode('utf-8'))):
                with self.assertRaisesRegex(ValueError, 'exact isolated package'):
                    driver.verify_fixture_apk(apk, 10002, 'aapt')
        self.assertEqual(len(self.events()), 1)

    def test_fixture_identity_requires_sdk_aapt(self):
        sdk = Path(self.directory.name)/'sdk'
        with self.assertRaisesRegex(RuntimeError, 'aapt is required'):
            driver.find_aapt(sdk)
        aapt = sdk/'build-tools/36.0.0/aapt'
        aapt.parent.mkdir(parents=True)
        aapt.touch()
        self.assertEqual(driver.find_aapt(sdk), aapt)

    def test_native_flags_are_strict_and_channel_applicability_matches_actual_sdk(self):
        fields = ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit', 'nativeReminderScheduling',
                  'workManagerRenewal', 'periodicTasksRegistered', 'nativeDeniedHabitSaved',
                  'nativeAppPermissionDiagnosis', 'nativeAppPermissionRecovery', 'nativeRestorePreviewCancel',
                  'nativeRestoreProtection', 'nativeRestoreConfirm', 'nativeRestoreReopen')
        for api in (24, 35, 36):
            driver.args.api = driver.device_api = api
            report = {**{key: True for key in fields}, 'notificationApiLevel': api,
                      'nativeChannelDiagnosis': True if api >= 26 else 'notApplicable',
                      'nativeChannelRecovery': True if api >= 26 else 'notApplicable'}
            driver.assert_native_flags(report)
            for key in fields + ('notificationApiLevel', 'nativeChannelDiagnosis', 'nativeChannelRecovery'):
                for bad in (False, 1, 'true', None):
                    with self.subTest(api=api, key=key, bad=bad), self.assertRaises(AssertionError):
                        driver.assert_native_flags({**report, key: bad})

    def test_notification_switch_is_tapped_once_then_observed_and_acknowledged(self):
        report = {'runId': '123', 'stage': 'awaitingNotificationDeny'}
        before = ui_xml('Block all', 'false')
        after = ui_xml('Block all', 'true')
        app = ui_xml('native fixture', owner=driver.package)
        current = [before]
        def shell(*values, **kwargs):
            return current[0] if values[0] == 'cat' else ''
        with patch.object(driver, 'shell', side_effect=shell) as shell_call, patch.object(driver, 'command', return_value=result()) as command:
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)  # stale tree must not replay toggle
            current[0] = after
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)  # one Back to App info
            current[0] = app
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)  # stale report must not repeat ack
        inputs = [call.args for call in shell_call.call_args_list if call.args[0] == 'input']
        self.assertEqual(inputs, [('input', 'tap', '130', '45'), ('input', 'keyevent', '4')])
        command.assert_called_once()
        self.assertEqual(json.loads(command.call_args.kwargs['input']),
                         {'runId': '123', 'stage': 'awaitingNotificationDeny', 'apiLevel': 24})
        self.assertEqual(command.call_args.args[-1], "'cat > files/acceptance-control.json'")

    def test_modern_app_and_channel_use_allow_switch_direction(self):
        driver.args.api = driver.device_api = 35
        for stage, label, title in [('awaitingNotificationGrant', 'All 好习惯隔离验收 notifications', '好习惯隔离验收'),
                                    ('awaitingChannelEnable', 'Show notifications', '习惯提醒')]:
            xml = ui_xml(label, 'false', title=title)
            with self.subTest(stage=stage), patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell:
                driver.drive_native_ui({'runId': '123', 'stage': stage})
            self.assertIn(('input', 'tap', '130', '45'), [c.args for c in shell.call_args_list])

    def test_unknown_app_or_nonsettings_switch_is_never_tapped(self):
        for owner, title in [('com.other.app', '好习惯隔离验收'), ('com.android.settings', 'Other app'),
                             ('com.android.settings', '好习惯')]:
            xml = ui_xml('Block all', 'false', owner=owner, title=title)
            with self.subTest(owner=owner), patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell:
                driver.drive_native_ui({'runId': '123', 'stage': 'awaitingNotificationDeny'})
            self.assertFalse(any(c.args[0] == 'input' for c in shell.call_args_list))

    def test_captured_android7_isolated_app_info_enters_notifications_exactly_once(self):
        xml = (Path(__file__).parent/'fixtures/native-settings-api24-app-info.xml').read_text(encoding='utf-8')
        report = {'runId': '1791030108309507', 'stage': 'awaitingNotificationDeny'}
        with patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell:
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)
        self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'],
                         [('input', 'tap', '123', '943')])
        self.assertFalse(driver.ui_stages[(report['runId'], report['stage'])].get('verified'))

    def test_captured_android15_isolated_switch_requires_observed_denial_before_ack(self):
        driver.args.api = driver.device_api = 35
        xml = (Path(__file__).parent/'fixtures/native-settings-api35-notifications.xml').read_text(encoding='utf-8')
        tree = ET.fromstring(xml)
        switches = [node for node in tree.iter('node') if node.get('resource-id') == 'android:id/switch_widget']
        self.assertEqual(len(switches), 1)
        self.assertEqual(switches[0].get('checked'), 'true')
        switches[0].set('checked', 'false')
        denied = ET.tostring(tree, encoding='unicode')
        app = ui_xml('native fixture', owner=driver.package)
        current = [xml]
        report = {'runId': '1791030162080999', 'stage': 'awaitingNotificationDeny'}
        with patch.object(driver, 'shell', side_effect=lambda *v, **kw: current[0] if v[0] == 'cat' else '') as shell, \
                patch.object(driver, 'command', return_value=result()) as command:
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)
            command.assert_not_called()
            current[0] = denied
            driver.drive_native_ui(report)
            command.assert_not_called()
            driver.drive_native_ui(report)
            current[0] = app
            driver.drive_native_ui(report)
            driver.drive_native_ui(report)
        self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'],
                         [('input', 'tap', '596', '790'), ('input', 'keyevent', '4')])
        command.assert_called_once()
        self.assertEqual(json.loads(command.call_args.kwargs['input']),
                         {'runId': '1791030162080999', 'stage': 'awaitingNotificationDeny', 'apiLevel': 35})
        self.assertEqual([item['event'] for item in self.events()],
                         ['notification-ui-tap', 'notification-ui-state', 'notification-ui-ack'])

    def test_captured_settings_for_a_different_label_never_receives_a_tap_or_ack(self):
        for api, name in [(24, 'native-settings-api24-app-info.xml'), (35, 'native-settings-api35-notifications.xml'),
                          (36, 'native-settings-api36-notifications.xml')]:
            driver.args.api = driver.device_api = api
            source = (Path(__file__).parent/'fixtures'/name).read_text(encoding='utf-8')
            for other in ('好习惯', 'Other app'):
                xml = source.replace('好习惯隔离验收', other)
                with self.subTest(api=api, label=other), \
                        patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell, \
                        patch.object(driver, 'command') as command:
                    driver.drive_native_ui({'runId': '123', 'stage': 'awaitingNotificationDeny'})
                self.assertFalse(any(c.args[0] == 'input' for c in shell.call_args_list))
                command.assert_not_called()

    def test_captured_android16_has_no_header_and_still_checks_deny_and_grant(self):
        driver.args.api = driver.device_api = 36
        source = (Path(__file__).parent/'fixtures/native-settings-api36-notifications.xml').read_text(encoding='utf-8')
        tree = ET.fromstring(source)
        self.assertFalse(any(node.get('text') == '好习惯隔离验收' for node in tree.iter('node')))
        switch = next(node for node in tree.iter('node') if node.get('resource-id') == 'android:id/switch_widget')
        app = ui_xml('native fixture', owner=driver.package)
        for stage, before, desired in [('awaitingNotificationDeny', 'true', 'false'),
                                       ('awaitingNotificationGrant', 'false', 'true')]:
            switch.set('checked', before)
            current = [ET.tostring(tree, encoding='unicode')]
            report = {'runId': '1791030128478865', 'stage': stage}
            with self.subTest(stage=stage), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: current[0] if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command', return_value=result()) as command:
                driver.drive_native_ui(report)
                driver.drive_native_ui(report)
                command.assert_not_called()
                switch.set('checked', desired)
                current[0] = ET.tostring(tree, encoding='unicode')
                driver.drive_native_ui(report)
                command.assert_not_called()
                driver.drive_native_ui(report)
                current[0] = app
                driver.drive_native_ui(report)
                driver.drive_native_ui(report)
            self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'],
                             [('input', 'tap', '596', '715'), ('input', 'keyevent', '4')])
            command.assert_called_once()
            self.assertEqual(json.loads(command.call_args.kwargs['input']),
                             {'runId': '1791030128478865', 'stage': stage, 'apiLevel': 36})

    def test_captured_android16_channel_title_requires_readback_and_app_return_before_ack(self):
        driver.args.api = driver.device_api = 36
        source = (Path(__file__).parent/'fixtures/native-settings-api36-channel.xml').read_text(encoding='utf-8')
        captured = ET.fromstring(source)
        self.assertFalse(any(node.get('package') == 'com.android.settings' and
                             node.get('text') == '习惯提醒' for node in captured.iter('node')))
        self.assertTrue(driver.settings_channel_title(captured, '习惯提醒'))
        captured_switches = [node for node in captured.iter('node')
                             if node.get('resource-id') == 'android:id/switch_widget']
        self.assertEqual(len(captured_switches), 1)
        self.assertEqual(captured_switches[0].get('checked'), 'true')
        self.assertEqual(captured_switches[0].get('enabled'), 'true')
        app = ui_xml('native fixture', owner=driver.package)
        for stage, before, desired in [('awaitingChannelDisable', 'true', 'false'),
                                       ('awaitingChannelEnable', 'false', 'true')]:
            tree = ET.fromstring(source)
            switch = next(node for node in tree.iter('node')
                          if node.get('resource-id') == 'android:id/switch_widget')
            switch.set('checked', before)
            current = [source if before == 'true' else ET.tostring(tree, encoding='unicode')]
            report = {'runId': '1791061413488295', 'stage': stage}
            with self.subTest(stage=stage), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: current[0] if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command', return_value=result()) as command:
                driver.drive_native_ui(report)
                driver.drive_native_ui(report)  # A stale checked state cannot replay the tap.
                self.assertFalse(driver.ui_stages[(report['runId'], stage)].get('verified'))
                command.assert_not_called()
                switch.set('checked', desired)
                current[0] = ET.tostring(tree, encoding='unicode')
                driver.drive_native_ui(report)
                command.assert_not_called()
                driver.drive_native_ui(report)  # Only now return from Settings.
                current[0] = ui_xml('native fixture', owner='com.other.app')
                driver.drive_native_ui(report)
                command.assert_not_called()
                current[0] = app
                driver.drive_native_ui(report)
                driver.drive_native_ui(report)
            self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'],
                             [('input', 'tap', '596', '735'), ('input', 'keyevent', '4')])
            command.assert_called_once()
            self.assertEqual(json.loads(command.call_args.kwargs['input']),
                             {'runId': report['runId'], 'stage': stage, 'apiLevel': 36})
            self.assertEqual(command.call_args.args[3], driver.package)

    def test_channel_title_accepts_only_one_exact_settings_toolbar(self):
        driver.args.api = driver.device_api = 36
        source = (Path(__file__).parent/'fixtures/native-settings-api36-channel.xml').read_text(encoding='utf-8')
        for title_values in [('习惯提醒', ''), ('', '习惯提醒'), ('习惯提醒', '习惯提醒')]:
            tree = ET.fromstring(source)
            title = next(node for node in tree.iter('node')
                         if node.get('resource-id') == 'com.android.settings:id/collapsing_toolbar')
            title.set('text', title_values[0])
            title.set('content-desc', title_values[1])
            with self.subTest(title_values=title_values):
                self.assertTrue(driver.settings_channel_title(tree, '习惯提醒'))
        for defect in ('wrong-package', 'wrong-container', 'wrong-title', 'conflicting-title',
                       'arbitrary-description', 'duplicate-container', 'duplicate-other-title'):
            tree = ET.fromstring(source)
            title = next(node for node in tree.iter('node')
                         if node.get('resource-id') == 'com.android.settings:id/collapsing_toolbar')
            if defect == 'wrong-package':
                title.set('package', 'com.other.app')
            elif defect == 'wrong-container':
                title.set('resource-id', 'com.android.settings:id/preference')
            elif defect == 'wrong-title':
                title.set('content-desc', 'Other channel')
            elif defect == 'conflicting-title':
                title.set('text', 'Other channel')
            elif defect == 'arbitrary-description':
                title.set('content-desc', 'Other channel')
                ET.SubElement(tree, 'node', {'package': 'com.android.settings',
                                           'content-desc': '习惯提醒', 'text': '习惯提醒'})
            else:
                duplicate = ET.SubElement(tree, 'node', dict(title.attrib))
                if defect == 'duplicate-other-title':
                    duplicate.set('content-desc', 'Other channel')
            xml = ET.tostring(tree, encoding='unicode')
            with self.subTest(defect=defect), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command') as command:
                self.assertFalse(driver.settings_channel_title(tree, '习惯提醒'))
                driver.drive_native_ui({'runId': '123', 'stage': 'awaitingChannelDisable'})
            self.assertFalse(any(c.args[0] == 'input' for c in shell.call_args_list))
            command.assert_not_called()
        self.assertFalse((driver.args.output/'driver-events.jsonl').exists())

    def test_channel_title_fallback_reads_only_the_unique_toolbar_direct_text_title(self):
        # Synthetic legacy representation derived from pinned AOSP layout/code;
        # the original API35 channel title hierarchy was not captured.
        driver.args.api = driver.device_api = 35
        source = (Path(__file__).parent/'fixtures/native-settings-api36-channel.xml').read_text(encoding='utf-8')

        def fallback_tree():
            tree = ET.fromstring(source)
            title_bar = next(node for node in tree.iter('node')
                             if node.get('resource-id') == 'com.android.settings:id/collapsing_toolbar')
            title_bar.set('text', '')
            title_bar.set('content-desc', '')
            toolbar = next(node for node in title_bar
                           if node.get('resource-id') == 'com.android.settings:id/action_bar')
            title = ET.SubElement(toolbar, 'node', {'package': 'com.android.settings',
                                                  'class': 'android.widget.TextView',
                                                  'text': '习惯提醒', 'content-desc': ''})
            return tree, title_bar, toolbar, title

        for toolbar_class in ('android.view.ViewGroup', 'android.widget.Toolbar'):
            tree, title_bar, toolbar, title = fallback_tree()
            toolbar.set('class', toolbar_class)
            xml = ET.tostring(tree, encoding='unicode')
            report = {'runId': '123', 'stage': 'awaitingChannelDisable'}
            driver.ui_stages.clear()
            with self.subTest(toolbar_class=toolbar_class), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command') as command:
                self.assertTrue(driver.settings_channel_title(tree, '习惯提醒'))
                driver.drive_native_ui(report)
                driver.drive_native_ui(report)
            self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'],
                             [('input', 'tap', '596', '735')])
            self.assertFalse(driver.ui_stages[('123', report['stage'])].get('verified'))
            command.assert_not_called()
        for defect in ('wrong-toolbar-id', 'wrong-toolbar-package', 'wrong-toolbar-class',
                       'nested-toolbar', 'duplicate-toolbar', 'wrong-title-package',
                       'wrong-title-class', 'wrong-title-text', 'description-only',
                       'nested-title', 'outside-title', 'duplicate-title',
                       'conflicting-title-description', 'nonempty-wrong-container-title',
                       'duplicate-container'):
            tree, title_bar, toolbar, title = fallback_tree()
            if defect == 'wrong-toolbar-id':
                toolbar.set('resource-id', 'com.android.settings:id/other_toolbar')
            elif defect == 'wrong-toolbar-package':
                toolbar.set('package', 'com.other.app')
            elif defect == 'wrong-toolbar-class':
                toolbar.set('class', 'android.widget.LinearLayout')
            elif defect == 'nested-toolbar':
                title_bar.remove(toolbar)
                ET.SubElement(title_bar, 'node', {'package': 'com.android.settings'}).append(toolbar)
            elif defect == 'duplicate-toolbar':
                ET.SubElement(title_bar, 'node', dict(toolbar.attrib))
            elif defect == 'wrong-title-package':
                title.set('package', 'com.other.app')
            elif defect == 'wrong-title-class':
                title.set('class', 'android.widget.Button')
            elif defect == 'wrong-title-text':
                title.set('text', 'Other channel')
            elif defect == 'description-only':
                title.set('text', '')
                title.set('content-desc', '习惯提醒')
            elif defect in ('nested-title', 'outside-title'):
                toolbar.remove(title)
                parent = toolbar if defect == 'nested-title' else tree
                ET.SubElement(parent, 'node', {'package': 'com.android.settings'}).append(title)
            elif defect == 'duplicate-title':
                ET.SubElement(toolbar, 'node', dict(title.attrib))
            elif defect == 'conflicting-title-description':
                title.set('content-desc', 'Other channel')
            elif defect == 'nonempty-wrong-container-title':
                title_bar.set('text', 'Other channel')
            else:
                ET.SubElement(tree, 'node', dict(title_bar.attrib))
            xml = ET.tostring(tree, encoding='unicode')
            driver.ui_stages.clear()
            with self.subTest(defect=defect), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command') as command:
                self.assertFalse(driver.settings_channel_title(tree, '习惯提醒'))
                driver.drive_native_ui({'runId': '123', 'stage': 'awaitingChannelDisable'})
            self.assertFalse(any(c.args[0] == 'input' for c in shell.call_args_list))
            command.assert_not_called()

    def test_captured_channel_still_rejects_ambiguous_disabled_or_unknown_switches(self):
        driver.args.api = driver.device_api = 36
        source = (Path(__file__).parent/'fixtures/native-settings-api36-channel.xml').read_text(encoding='utf-8')
        for defect in ('duplicate', 'disabled', 'missing-checked', 'unknown-checked'):
            tree = ET.fromstring(source)
            switch = next(node for node in tree.iter('node')
                          if node.get('resource-id') == 'android:id/switch_widget')
            if defect == 'duplicate':
                parents = {child: parent for parent in tree.iter() for child in parent}
                ET.SubElement(parents[switch], 'node', dict(switch.attrib))
            elif defect == 'disabled':
                switch.set('enabled', 'false')
            elif defect == 'missing-checked':
                switch.attrib.pop('checked')
            else:
                switch.set('checked', 'unknown')
            xml = ET.tostring(tree, encoding='unicode')
            with self.subTest(defect=defect), \
                    patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell, \
                    patch.object(driver, 'command') as command, self.assertRaises(ValueError):
                driver.drive_native_ui({'runId': '123', 'stage': 'awaitingChannelDisable'})
            self.assertFalse(any(c.args[0] == 'input' for c in shell.call_args_list))
            command.assert_not_called()
        self.assertFalse((driver.args.output/'driver-events.jsonl').exists())

    def test_label_without_own_switch_cannot_borrow_another_rows_switch(self):
        root = ET.fromstring(ui_xml('Block all', 'false'))
        row = root.find('./node/node[@clickable="true"]')
        switch = next(n for n in row if n.get('checkable') == 'true')
        row.remove(switch)
        other = ET.SubElement(root.find('./node'), 'node', {'clickable': 'true'})
        other.append(switch)
        self.assertIsNone(driver.settings_switch(root, 'Block all'))

    def test_restore_requires_exact_enabled_app_button_and_never_replays(self):
        for stage, label in [('awaitingRestoreCancel', '取消'), ('awaitingRestoreConfirm', '保护当前数据并恢复')]:
            xml = ui_xml(label, owner=driver.package)
            with self.subTest(stage=stage), patch.object(driver, 'shell', side_effect=lambda *v, **kw: xml if v[0] == 'cat' else '') as shell:
                driver.drive_native_ui({'runId': '123', 'stage': stage})
                driver.drive_native_ui({'runId': '123', 'stage': stage})
            self.assertEqual([c.args for c in shell.call_args_list if c.args[0] == 'input'], [('input', 'tap', '55', '45')])

    def test_exited_emulator_fails_before_any_launch(self):
        driver.process.poll.return_value = -9
        with patch.object(driver, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'status -9'):
                driver.start_and_wait(10001, 'reopen', 'previous')
            command.assert_not_called()
        self.assertEqual(self.events()[-1]['exit'], -9)

    def test_cleanup_screenshot_error_keeps_primary_failure_and_closes_handles(self):
        primary = RuntimeError('original launch failure')
        emulator_log, live_log = io.BytesIO(), io.BytesIO()
        live_process = Mock()
        live_process.poll.return_value = None

        def command(*values, **kwargs):
            if 'screencap' in values:
                raise subprocess.CalledProcessError(255, values, stderr=b'error: closed')
            return result(b'log')

        with patch.object(driver, 'command', side_effect=command):
            try:
                try:
                    raise primary
                finally:
                    driver.collect_diagnostics(driver.process, emulator_log, live_process, live_log)
            except RuntimeError as caught:
                self.assertIs(caught, primary)
        driver.process.terminate.assert_called_once()
        live_process.terminate.assert_called_once()
        self.assertTrue(emulator_log.closed)
        self.assertTrue(live_log.closed)
        self.assertEqual(self.events()[-1]['diagnostic'], 'last-screen')

    def test_cleanup_persistent_adb_failure_still_terminates_emulator(self):
        log = io.BytesIO()
        with patch.object(driver, 'command', side_effect=subprocess.TimeoutExpired(['adb'], 5)):
            driver.collect_diagnostics(driver.process, log)
        driver.process.terminate.assert_called_once()
        self.assertTrue(log.closed)
        self.assertEqual(len([e for e in self.events() if e['event'] == 'diagnostic-failed']), 3)

    def test_app_report_failure_is_not_retried_as_infrastructure(self):
        report = {'build': '10002', 'runId': '123', 'status': 'failed', 'error': 'Keystore failure',
                  'launchNonce': 'a' * 32, 'phase': 'reopen', 'previousRunId': 'old'}
        with patch.object(driver, 'shell') as shell, patch.object(driver, 'command', return_value=result(json.dumps(report).encode())):
            with self.assertRaisesRegex(RuntimeError, 'Keystore failure'):
                driver.start_and_wait(10002, 'reopen', 'old')
        shell.assert_called_once_with('am', 'start', '-n', driver.activity)

    def test_native_upgrade_flags_remain_mandatory(self):
        fields = ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit',
                  'nativeReminderScheduling', 'workManagerRenewal', 'periodicTasksRegistered')
        for missing in fields:
            report = passed_predecessor('10002', run_id='123')
            report.update({'previousRunId': 'old', missing: False})
            with self.subTest(missing=missing), patch.object(driver, 'shell'), patch.object(driver, 'command', return_value=result(json.dumps(report).encode())):
                with self.assertRaises(AssertionError):
                    driver.start_and_wait(10002, 'reopen', 'old')

    def test_stale_report_cannot_satisfy_reopen(self):
        report = {'build': '10001', 'runId': 'old', 'status': 'passed', 'phase': 'reopen', 'schema': 2}
        with patch.object(driver, 'shell'), patch.object(driver, 'command', return_value=result(json.dumps(report).encode())), patch.object(driver.time, 'monotonic', side_effect=[0, 0, 1, 241]), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.start_and_wait(10001, 'reopen', 'old')

    def test_permission_kill_cannot_change_logical_run_or_replay_ui(self):
        waiting = {'build': '10002', 'runId': '123', 'status': 'running', 'stage': 'awaitingNotificationDeny',
                   'launchNonce': 'a' * 32, 'phase': 'reopen', 'previousRunId': '122'}
        restarted = {**waiting, 'runId': '456', 'stage': 'awaitingDocumentSave'}
        with patch.object(driver, 'shell') as shell, \
                patch.object(driver, 'command', side_effect=[result(json.dumps(waiting).encode()), result(json.dumps(restarted).encode())]), \
                patch.object(driver, 'archive_settings_checkpoint') as archive, \
                patch.object(driver, 'drive_native_ui', return_value=True) as ui, \
                patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'logical run identity changed'):
                driver.start_and_wait(10002, 'reopen', '122')
        shell.assert_called_once_with('am', 'start', '-n', driver.activity)
        archive.assert_called_once_with(waiting)
        ui.assert_called_once_with(waiting)
        self.assertTrue((driver.args.output/'report-123-awaitingNotificationDeny-running.json').exists())

    def test_same_run_continuation_preserves_first_report_and_checkpoint_once(self):
        waiting = {'build': '10002', 'runId': '123', 'status': 'running', 'stage': 'awaitingNotificationDeny',
                   'launchNonce': 'a' * 32, 'phase': 'reopen', 'previousRunId': '122'}
        resumed = {**waiting, 'notificationProcessResumes': [{'pid': 2}]}
        completed = passed_predecessor('10002', run_id='123')
        completed['previousRunId'] = '122'
        with patch.object(driver, 'shell'), \
                patch.object(driver, 'command', side_effect=[result(json.dumps(v).encode()) for v in [waiting, resumed, completed]]), \
                patch.object(driver, 'archive_settings_checkpoint') as archive, \
                patch.object(driver, 'drive_native_ui', return_value=True), patch.object(driver.time, 'sleep'):
            self.assertEqual(driver.start_and_wait(10002, 'reopen', '122'), completed)
        archive.assert_called_once_with(waiting)
        self.assertEqual(json.loads((driver.args.output/'report-123-awaitingNotificationDeny-running.json').read_text()), waiting)

    def test_checkpoint_archive_rejects_wrong_package_before_mutation(self):
        waiting = {'build': '10002', 'runId': '123', 'stage': 'awaitingNotificationDeny', 'status': 'running',
                   'launchNonce': 'a' * 32, 'phase': 'reopen', 'previousRunId': '122'}
        checkpoint = {'version': 1, 'package': driver.package, 'build': '10002', 'schema': 3,
                      'launch': {'version': 1, 'package': driver.package, 'build': '10002', 'phase': 'reopen',
                                 'nonce': 'a' * 32, 'previousRunId': '122'},
                      'runId': '123', 'stage': waiting['stage'], 'pid': 11, 'deadlineMs': 123456789, 'result': waiting}
        for field, bad in [('package', 'com.other.app'), ('runId', '456'), ('stage', 'awaitingNotificationGrant'),
                           ('version', True), ('schema', '3'), ('pid', 0), ('deadlineMs', True)]:
            with self.subTest(field=field), patch.object(driver, 'command', return_value=result(json.dumps({**checkpoint, field: bad}).encode())):
                with self.assertRaisesRegex(RuntimeError, 'checkpoint does not match'):
                    driver.archive_settings_checkpoint(waiting)
        raw = json.dumps(checkpoint).encode()
        with patch.object(driver, 'command', return_value=result(raw)):
            driver.archive_settings_checkpoint(waiting)
        self.assertEqual((driver.args.output/'checkpoint-123-awaitingNotificationDeny.json').read_bytes(), raw)


    def test_host_nonce_is_written_once_before_launch_and_bound_to_passed_predecessor(self):
        self.launch_patch.stop()
        saved = passed_predecessor()
        with patch.object(driver, 'command', side_effect=[probe_result(saved), result()]) as command:
            nonce = driver.prepare_launch(10002, 'reopen', '122')
        self.assertRegex(nonce, r'^[a-f0-9]{32}$')
        self.assertEqual(command.call_count, 2)
        self.assertIn('mkdir -p files', command.call_args.args[-1])
        launch = json.loads(command.call_args.kwargs['input'])
        self.assertEqual(launch['previousRunId'], '122')
        self.assertEqual(launch['nonce'], nonce)
        self.assertIn('mv files/acceptance-launch.json.pending files/acceptance-launch.json', command.call_args.args[-1])
        self.assertEqual(json.loads((driver.args.output/f'launch-{nonce}.json').read_text()), launch)

    def test_failed_unfinished_or_wrong_phase_predecessor_cannot_receive_new_nonce(self):
        self.launch_patch.stop()
        for saved in [
            {'build': '10001', 'phase': 'reopen', 'status': status, 'runId': '122'}
            for status in ('failed', 'running')
        ] + [{'build': '10001', 'phase': 'create', 'status': 'passed', 'runId': '122'}]:
            with self.subTest(saved=saved), patch.object(driver, 'command', return_value=probe_result(saved)) as command:
                with self.assertRaisesRegex(RuntimeError, 'refuses'):
                    driver.prepare_launch(10002, 'reopen', '122')
                command.assert_called_once()

    def test_fresh_install_has_no_report_and_creates_files_in_its_single_publish(self):
        self.launch_patch.stop()
        with patch.object(driver, 'command', side_effect=[probe_result(), result()]) as command:
            nonce = driver.prepare_launch(10001, 'create', None)
        self.assertRegex(nonce, r'^[a-f0-9]{32}$')
        self.assertEqual(command.call_count, 2)
        self.assertIn('mkdir -p files', command.call_args.args[-1])
        self.assertIsNone(json.loads(command.call_args.kwargs['input'])['previousRunId'])

    def test_same_run_nonce_drift_stops_before_second_ui_mutation(self):
        waiting = {'build': '10002', 'phase': 'reopen', 'previousRunId': '122', 'launchNonce': 'a' * 32,
                   'runId': '123', 'status': 'running', 'stage': 'awaitingNotificationDeny'}
        drift = {**waiting, 'launchNonce': 'b' * 32}
        with patch.object(driver, 'shell'), patch.object(driver, 'command', side_effect=[result(json.dumps(v).encode()) for v in [waiting, drift]]), \
                patch.object(driver, 'archive_settings_checkpoint'), patch.object(driver, 'drive_native_ui', return_value=True) as ui, patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'logical run identity changed'):
                driver.start_and_wait(10002, 'reopen', '122')
        ui.assert_called_once_with(waiting)

    def test_checkpoint_nonce_mismatch_is_rejected_before_settings_mutation(self):
        waiting = {'build': '10002', 'runId': '123', 'stage': 'awaitingNotificationDeny', 'status': 'running',
                   'phase': 'reopen', 'launchNonce': 'a' * 32, 'previousRunId': '122'}
        checkpoint = {'version': 1, 'package': driver.package, 'build': '10002', 'schema': 3,
                      'runId': '123', 'stage': waiting['stage'], 'pid': 11, 'deadlineMs': 123456789, 'result': waiting,
                      'launch': {'version': 1, 'package': driver.package, 'build': '10002', 'phase': 'reopen',
                                 'nonce': 'b' * 32, 'previousRunId': '122'}}
        with patch.object(driver, 'command', return_value=result(json.dumps(checkpoint).encode())):
            with self.assertRaisesRegex(RuntimeError, 'host launch nonce'):
                driver.archive_settings_checkpoint(waiting)
        checkpoint['launch']['nonce'] = 'a' * 32
        checkpoint['launch']['version'] = True
        with patch.object(driver, 'command', return_value=result(json.dumps(checkpoint).encode())):
            with self.assertRaisesRegex(RuntimeError, 'host launch nonce'):
                driver.archive_settings_checkpoint(waiting)
        self.assertFalse((driver.args.output/'checkpoint-123-awaitingNotificationDeny.json').exists())

    def test_running_and_failed_raw_reports_at_the_same_stage_do_not_overwrite(self):
        waiting = {'build': '10002', 'runId': '123', 'status': 'running', 'stage': 'awaitingNotificationDeny',
                   'phase': 'reopen', 'launchNonce': 'a' * 32, 'previousRunId': '122'}
        failed = {**waiting, 'status': 'failed', 'error': 'original SQL mismatch'}
        first_raw, failed_raw = [json.dumps(v).encode() for v in (waiting, failed)]
        with patch.object(driver, 'shell'), patch.object(driver, 'command', side_effect=[result(first_raw), result(failed_raw)]), \
                patch.object(driver, 'archive_settings_checkpoint') as archive, patch.object(driver, 'drive_native_ui', return_value=True) as ui, patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'original SQL mismatch'):
                driver.start_and_wait(10002, 'reopen', '122')
        self.assertEqual((driver.args.output/'report-123-awaitingNotificationDeny-running.json').read_bytes(), first_raw)
        self.assertEqual((driver.args.output/'report-123-awaitingNotificationDeny-failed.json').read_bytes(), failed_raw)
        archive.assert_called_once_with(waiting)
        ui.assert_called_once_with(waiting)

    def test_exec_out_zero_with_missing_file_error_is_unknown_not_absent(self):
        self.launch_patch.stop()
        raw = b'cat: files/acceptance-report.json: No such file or directory\n'
        with patch.object(driver, 'command', return_value=result(raw)) as command:
            with self.assertRaisesRegex(RuntimeError, 'unknown status'):
                driver.prepare_launch(10001, 'create', None)
        command.assert_called_once()
        self.assertEqual(command.call_args.args[:6], ('adb', 'shell', '-T', 'run-as', driver.package, 'sh'))
        self.assertEqual(next(driver.args.output.glob('preflight-*.stdout.bin')).read_bytes(), raw)
        self.assertFalse(list(driver.args.output.glob('launch-*.json')))

    def test_probe_absent_requires_exact_identity_empty_stderr_and_success(self):
        absent = probe_result().stdout
        self.assertIsNone(driver.decode_report_probe(result(absent)))
        for bad in [result(absent, code=1), result(absent, stderr=b'unknown warning'), result(b''),
                    result(absent + b'unknown\n'), result(b'unknown\n' + absent),
                    result(absent.replace(driver.package.encode(), b'com.other.app')),
                    result(absent.replace(b'files/acceptance-report.json', b'other.json')),
                    result(absent.replace(b'ABSENT', b'INVALID'))]:
            with self.subTest(raw=bad.stdout, code=bad.returncode, stderr=bad.stderr):
                with self.assertRaises(RuntimeError): driver.decode_report_probe(bad)

    def test_probe_existing_requires_one_strict_object_without_duplicate_keys_or_nonfinite_values(self):
        marker = (driver.report_probe_prefix + 'EXISTS\n').encode()
        self.assertEqual(driver.decode_report_probe(result(marker + b'{"status":"failed","error":"first"}')),
                         {'status': 'failed', 'error': 'first'})
        for body in [b'', b'null', b'[]', b'{"runId":"1","runId":"2"}', b'{"x":NaN}', b'{"x":Infinity}',
                     b'{"x":1e999}', b'{"x":-1e999}',
                     b'{"x":{"status":"passed","status":"failed"}}', b'{}\nunknown', b'\xff', marker+b'{}']:
            with self.subTest(body=body), self.assertRaises(RuntimeError):
                driver.decode_report_probe(result(marker + body))

    def test_all_existing_four_phase_predecessors_remain_valid(self):
        self.launch_patch.stop()
        for build, saved in [(10001, passed_predecessor(phase='create')),
                             (10002, passed_predecessor()), (10002, passed_predecessor(build='10002'))]:
            with self.subTest(build=build, savedBuild=saved['build']), patch.object(driver, 'command', side_effect=[probe_result(saved), result()]) as command:
                nonce = driver.prepare_launch(build, 'reopen', '122')
                self.assertRegex(nonce, r'^[a-f0-9]{32}$')
                self.assertEqual(command.call_count, 2)

    def test_passed_predecessor_rejects_wrong_identity_schema_types_or_terminal_error(self):
        self.launch_patch.stop()
        saved = passed_predecessor()
        for field, value in [('package', 'com.other.app'), ('schema', True), ('schema', 3), ('runId', '123'),
                             ('status', 'running'), ('phase', 'create'), ('error', None), ('stack', ''),
                             ('ownerPid', True), ('entryId', 'unknown'), ('launchNonce', 'unknown'),
                             ('previousRunId', None), ('nativeCrypto', 1), ('habits', True)]:
            with self.subTest(field=field), patch.object(driver, 'command', return_value=probe_result({**saved, field:value})) as command:
                with self.assertRaisesRegex(RuntimeError, 'refuses'):
                    driver.prepare_launch(10002, 'reopen', '122')
                command.assert_called_once()
        with patch.object(driver, 'command', return_value=probe_result()) as command:
            with self.assertRaisesRegex(RuntimeError, 'refuses'):
                driver.prepare_launch(10002, 'reopen', '122')
            command.assert_called_once()

    def test_existing_failed_first_report_is_preserved_and_no_nonce_is_published(self):
        self.launch_patch.stop()
        failed = {'status':'failed','error':'first SQL failure','stack':'first stack'}
        raw = probe_result(failed).stdout
        with patch.object(driver, 'command', return_value=result(raw)) as command:
            with self.assertRaisesRegex(RuntimeError, 'refuses'):
                driver.prepare_launch(10001, 'create', None)
        command.assert_called_once()
        self.assertEqual(next(driver.args.output.glob('preflight-*.stdout.bin')).read_bytes(), raw)
        self.assertFalse(list(driver.args.output.glob('launch-*.json')))

    def test_readonly_probe_shell_handles_real_missing_directory_and_bad_file_types(self):
        shell = shutil.which('sh')
        if shell is None:
            git = shutil.which('git')
            candidates = [] if git is None else [Path(git).parent.parent/'usr'/'bin'/'sh.exe', Path(git).parent.parent/'bin'/'bash.exe']
            shell = next((str(p) for p in candidates if p.is_file()), None)
        if shell is None:
            self.skipTest('POSIX shell unavailable; Linux native CI runs real filesystem probe checks')
        root = driver.args.output/'shell-probe'
        root.mkdir()
        probe_environment = dict(os.environ)
        probe_environment['PATH'] = str(Path(shell).parent) + os.pathsep + probe_environment.get('PATH', '')
        def run(): return subprocess.run([shell, '-c', driver.report_probe_script()], cwd=root,
                                         env=probe_environment, capture_output=True, timeout=5)
        self.assertIsNone(driver.decode_report_probe(run()))
        files = root/'files'
        files.write_text('bad directory type')
        with self.assertRaises(RuntimeError): driver.decode_report_probe(run())
        files.unlink(); files.mkdir()
        self.assertIsNone(driver.decode_report_probe(run()))
        path = files/'acceptance-report.json'
        path.mkdir()
        with self.assertRaises(RuntimeError): driver.decode_report_probe(run())
        path.rmdir()
        saved = passed_predecessor()
        path.write_text(json.dumps(saved))
        self.assertEqual(driver.decode_report_probe(run()), saved)
        if os.name != 'nt':
            path.unlink(); path.symlink_to(files/'missing-target')
            with self.assertRaises(RuntimeError): driver.decode_report_probe(run())
            path.unlink(); files.rmdir(); files.symlink_to(root/'missing-directory')
            with self.assertRaises(RuntimeError): driver.decode_report_probe(run())

    def test_engine_proof_requires_complete_preserved_semantics_root(self):
        valid = passed_predecessor('10001', 'create')
        driver.assert_engine_recreation(valid)
        for tree in (None, {}, {'method': 'other', 'views': []},
                     {'method': 'existingTreeDetachAttach', 'views': []},
                     *({'method': 'existingTreeDetachAttach', 'views': [view]} for view in (
                         {'rootId': True, 'nodeIds': [0], 'completeNodeCount': 1, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [1], 'completeNodeCount': 1, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0, 0], 'completeNodeCount': 2, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0, True], 'completeNodeCount': 2, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0, -1], 'completeNodeCount': 2, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0], 'completeNodeCount': True, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0], 'completeNodeCount': 2, 'nodeIdsPreserved': True},
                         {'rootId': 0, 'nodeIds': [0], 'completeNodeCount': 1, 'nodeIdsPreserved': False}))):
            with self.subTest(tree=tree):
                changed = json.loads(json.dumps(valid))
                changed['nativeEngineRecreationEvidence']['semanticsResend'] = tree
                with self.assertRaises(AssertionError):
                    driver.assert_engine_recreation(changed)
                self.assertFalse(driver.valid_passed_predecessor(changed, 10001, changed['runId']))

    def test_semantics_failure_stops_ui_before_any_mutation_and_keeps_first_report(self):
        observation = {'package': driver.package, 'build': '10002', 'phase': 'reopen',
                       'nonce': 'a'*32, 'pid': 11, 'entryId': 'b'*32,
                       'reason': 'semantics notification has no visible current host'}
        line = 'ACCEPTANCE_SEMANTICS_FAILURE ' + json.dumps(observation)
        (driver.args.output/'runtime-live.log').write_text(line+'\n', encoding='utf-8')
        first = b'{"status":"running","runId":"123"}'
        retained = driver.args.output/'first-report.json'
        retained.write_bytes(first)
        with patch.object(driver, 'command') as command, patch.object(driver, 'drive_native_ui') as ui:
            with self.assertRaisesRegex(RuntimeError, 'semantics could not bind'):
                driver.check_entry_ownership_failure(10002, 'reopen', 'a'*32)
            command.assert_not_called()
            ui.assert_not_called()
        self.assertEqual(retained.read_bytes(), first)
        self.assertEqual((driver.args.output/('semantics-binding-failure-'+'a'*32+'.txt')).read_text(encoding='utf-8'), line+'\n')
        self.assertEqual(self.events()[-1]['event'], 'semantics-binding-failure')
        driver.check_entry_ownership_failure(10002, 'reopen', 'c'*32)

    def test_engine_recreation_requires_exact_executed_native_request(self):
        saved = passed_predecessor()
        driver.assert_engine_recreation(saved)
        corruptions = [('nativeEngineRecreation', False), ('firstRunningReportUnchanged', False),
                       ('requestOutcome', 'abandoned'), ('requestOutcome', 'queued'),
                       ('requestId', '0'*32), ('requestHostId', '0'*32), ('engineId', '0'*32),
                       ('hostId', 'd'*32), ('attachCount', 1), ('pid', 12), ('uiDisplayed', False),
                       ('attached', False), ('executingDart', False), ('package', 'other'), ('build', '10002')]
        for field, value in corruptions:
            candidate = json.loads(json.dumps(saved))
            proof = candidate['nativeEngineRecreationEvidence']
            if field == 'nativeEngineRecreation': candidate[field] = value
            elif field == 'firstRunningReportUnchanged': proof[field] = value
            else: proof['after'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(AssertionError):
                driver.assert_engine_recreation(candidate)

    def test_schema2_predecessor_cannot_skip_the_same_engine_gate(self):
        candidate = passed_predecessor(phase='create')
        self.assertTrue(driver.valid_passed_predecessor(candidate, 10001, '122'))
        for field in ('nativeEngineRecreation', 'nativeEngineRecreationEvidence'):
            damaged = {name:value for name,value in candidate.items() if name != field}
            self.assertFalse(driver.valid_passed_predecessor(damaged, 10001, '122'))

    def test_engine_origin_can_continue_only_along_verified_same_run_sql_pid_chain(self):
        saved = passed_predecessor('10002')
        saved.update({'ownerPid': 13, 'entryId': '0'*32, 'notificationProcessResumes': [
            {'runId':'122', 'previousPid':11, 'pid':12, 'databaseDifferencePaths':[], 'completeModelUnchanged':True},
            {'runId':'122', 'previousPid':12, 'pid':13, 'databaseDifferencePaths':[], 'completeModelUnchanged':True}]})
        driver.assert_engine_recreation(saved)
        for field,value in [('runId','other'),('previousPid',11),('pid',True),('pid',12),
                            ('databaseDifferencePaths',['tables.habits']),('completeModelUnchanged',False)]:
            candidate = json.loads(json.dumps(saved))
            candidate['notificationProcessResumes'][1][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                driver.assert_engine_recreation(candidate)

    def test_unresponsive_entry_is_immediate_failure_before_any_report_or_ui_mutation(self):
        observation = {'package':driver.package,'build':'10001','phase':'create','nonce':'a'*32,
                       'pid':11,'entryId':'b'*32,'reportWritten':False,'businessOpened':False,
                       'reason':'retained owner did not respond to the bounded challenge'}
        raw = '10-03 21:03:27 flutter: ACCEPTANCE_ENTRY_OWNERSHIP_FAILURE ' + json.dumps(observation) + '\n'
        (driver.args.output/'runtime-live.log').write_text(raw, encoding='utf-8')
        with patch.object(driver, 'require_emulator'), patch.object(driver, 'shell') as shell, \
                patch.object(driver, 'command') as command, patch.object(driver, 'drive_native_ui') as ui:
            with self.assertRaisesRegex(RuntimeError, 'entry owner did not respond'):
                driver.start_and_wait(10001, 'create')
        shell.assert_called_once_with('am', 'start', '-n', driver.activity)
        command.assert_not_called()
        ui.assert_not_called()
        self.assertEqual((driver.args.output/('entry-ownership-failure-'+'a'*32+'.txt')).read_text(), raw)
        self.assertEqual(self.events()[-1]['event'], 'entry-ownership-failure')

    def test_entry_failure_scope_is_closed_and_other_nonce_is_ignored(self):
        observation = {'package':driver.package,'build':'10001','phase':'create','nonce':'a'*32,
                       'pid':11,'entryId':'b'*32,'reportWritten':False,'businessOpened':False,
                       'reason':'retained owner did not respond to the bounded challenge'}
        runtime = driver.args.output/'runtime-live.log'
        runtime.write_text('ACCEPTANCE_SPECTATOR {"ownerReply":true}\n', encoding='utf-8')
        driver.check_entry_ownership_failure(10001, 'create', 'a'*32)
        runtime.write_text('ACCEPTANCE_ENTRY_OWNERSHIP_FAILURE '+json.dumps({**observation,'nonce':'c'*32}), encoding='utf-8')
        driver.check_entry_ownership_failure(10001, 'create', 'a'*32)
        for field,value in [('package','other'),('build','10002'),('phase','reopen'),('pid',True),
                            ('entryId','bad'),('reportWritten',True),('businessOpened',True),('reason','unknown')]:
            runtime.write_text('ACCEPTANCE_ENTRY_OWNERSHIP_FAILURE '+json.dumps({**observation,field:value}), encoding='utf-8')
            with self.subTest(field=field), self.assertRaisesRegex(RuntimeError,'wrong identity'):
                driver.check_entry_ownership_failure(10001, 'create', 'a'*32)
        runtime.write_text('ACCEPTANCE_ENTRY_OWNERSHIP_FAILURE broken', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'malformed'):
            driver.check_entry_ownership_failure(10001, 'create', 'a'*32)

    def test_probe_timeout_preserves_partial_output_without_publishing_or_retrying(self):
        self.launch_patch.stop()
        error = subprocess.TimeoutExpired(['adb'], 15, output=b'partial probe', stderr=b'partial stderr')
        with patch.object(driver, 'command', side_effect=error) as command:
            with self.assertRaises(subprocess.TimeoutExpired):
                driver.prepare_launch(10001, 'create', None)
        command.assert_called_once()
        self.assertEqual(next(driver.args.output.glob('preflight-*.stdout.bin')).read_bytes(), b'partial probe')
        self.assertEqual(next(driver.args.output.glob('preflight-*.stderr.bin')).read_bytes(), b'partial stderr')
        self.assertFalse(json.loads(next(driver.args.output.glob('preflight-*.metadata.json')).read_text())['readCompleted'])
        self.assertFalse(list(driver.args.output.glob('launch-*.json')))


if __name__ == '__main__':
    unittest.main()
