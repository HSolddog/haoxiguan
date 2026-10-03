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


spec = importlib.util.spec_from_file_location('acceptance_driver', Path(__file__).with_name('run_android_acceptance.py'))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def result(stdout=b'', code=0, stderr=b''):
    return subprocess.CompletedProcess(['adb'], code, stdout, stderr)


class AndroidAcceptanceDriverTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        driver.args = SimpleNamespace(output=Path(self.directory.name), api=24)
        driver.adb = 'adb'
        driver.adb_serial = 'emulator-5580'
        driver.process = Mock(pid=123)
        driver.process.poll.return_value = None

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

    def test_reopen_waits_for_stopped_flag_and_two_consecutive_ready_reads(self):
        healthy = [result(b'1'), result(b'Service activity: found'), result(b'User 0: installed=true stopped=true')]
        replies = [result(code=1), healthy[1], healthy[2], *healthy,
                   healthy[0], healthy[1], result(b'User 0: stopped=false'), *healthy, *healthy]
        with patch.object(driver, 'command', side_effect=replies) as command, patch.object(driver.time, 'sleep'):
            driver.wait_for_reopen()
        self.assertEqual(command.call_count, 15)
        self.assertFalse(any('am' in call.args for call in command.call_args_list))
        self.assertEqual([event['consecutive'] for event in self.events()], [0, 1, 0, 1, 2])

    def test_reopen_wait_has_deadline_and_does_not_start_activity(self):
        with patch.object(driver, 'command', return_value=result(code=255)) as command, patch.object(driver.time, 'monotonic', side_effect=range(100)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                driver.wait_for_reopen(timeout=5)
        self.assertLessEqual(command.call_count, 9)
        self.assertFalse(any('am' in call.args for call in command.call_args_list))

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
