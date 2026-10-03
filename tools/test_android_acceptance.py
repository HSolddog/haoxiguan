"""Host-only regression tests; no SDK, Android device, or network is touched."""
import importlib.util
import io
import json
from pathlib import Path
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


def process_list(*pids):
    # Actual Android 7 toolbox output has an unlabelled state before NAME.
    return ('USER PID PPID VSIZE RSS WCHAN PC NAME\nroot 1 0 100 50 0 0000000000 S /init\n' + ''.join(
        f'u0_a62 {pid} 1 100 50 0 0000000000 S {driver.package}\n' for pid in pids)).encode()


def ui_xml(label, checked=None, owner='com.android.settings', title='好习惯隔离验收'):
    root = ET.Element('hierarchy')
    screen = ET.SubElement(root, 'node', {'package': owner})
    ET.SubElement(screen, 'node', {'package': owner, 'text': title})
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
        report = {'build': '10002', 'runId': 'new', 'status': 'failed', 'error': 'Keystore failure'}
        with patch.object(driver, 'shell') as shell, patch.object(driver, 'command', return_value=result(json.dumps(report).encode())):
            with self.assertRaisesRegex(RuntimeError, 'Keystore failure'):
                driver.start_and_wait(10002, 'reopen', 'old')
        shell.assert_called_once_with('am', 'start', '-n', driver.activity)

    def test_native_upgrade_flags_remain_mandatory(self):
        fields = ('safExportReadback', 'safOpenDecrypt', 'safSizeLimit',
                  'nativeReminderScheduling', 'workManagerRenewal', 'periodicTasksRegistered')
        for missing in fields:
            report = {'build': '10002', 'runId': 'new', 'status': 'passed', 'phase': 'reopen', 'schema': 3,
                      **{field: field != missing for field in fields}}
            with self.subTest(missing=missing), patch.object(driver, 'shell'), patch.object(driver, 'command', return_value=result(json.dumps(report).encode())):
                with self.assertRaises(AssertionError):
                    driver.start_and_wait(10002, 'reopen', 'old')

    def test_stale_report_cannot_satisfy_reopen(self):
        report = {'build': '10001', 'runId': 'old', 'status': 'passed', 'phase': 'reopen', 'schema': 2}
        with patch.object(driver, 'shell'), patch.object(driver, 'command', return_value=result(json.dumps(report).encode())), patch.object(driver.time, 'monotonic', side_effect=[0, 0, 1, 241]), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.start_and_wait(10001, 'reopen', 'old')


if __name__ == '__main__':
    unittest.main()
