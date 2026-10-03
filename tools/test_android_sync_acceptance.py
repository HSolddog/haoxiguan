"""Host-only tests: no Flutter, Go, ADB, Android emulator or network is started."""
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


driver = load('native_sync_driver', 'run_android_sync_acceptance.py')
builder = load('native_sync_builder', 'build_android_sync_acceptance.py')
RUN_ID, FIRST_LAUNCH, SECOND_LAUNCH = 'a' * 32, '1' * 32, '2' * 32


def result(stdout=b'', code=0, stderr=b''):
    return subprocess.CompletedProcess(['adb'], code, stdout, stderr)


def complete_evidence():
    value = {key: 'a' * 64 for key in driver.FACT_DIGESTS}
    for group, metrics in driver.EVIDENCE_METRICS.items():
        value[group] = {'beforeSnapshotSha256': 'b' * 64, 'afterSnapshotSha256': 'b' * 64,
                        **{prefix + metric: 1 for metric in metrics for prefix in ('before', 'after')}}
    value['counts'] = dict(driver.EXPECTED_COUNTS)
    return value


def report(role='A', stage='boot', **fields):
    value = {'schemaVersion': 3, 'sdkInt': 35, 'packageName': driver.PACKAGES[role],
             'runId': RUN_ID, 'role': role, 'build': driver.BUILDS[role],
             'reportSequence': 1, 'launchId': FIRST_LAUNCH,
             'source': dict(driver.SOURCE), 'stage': stage, 'status': 'running', 'evidence': {}}
    if stage in driver.SAF_STAGES:
        value['documentName'] = driver.document_name(RUN_ID, role, stage)
    if stage == 'complete':
        value.update(status='passed', evidence=complete_evidence(), **{key: True for key in driver.RESULT_FLAGS})
    if stage == 'failed':
        value['status'] = 'failed'
    return {**value, **fields}


def process_list(pid=None, user='u0_a62', name=None):
    text = 'USER PID PPID VSZ RSS WCHAN ADDR S NAME\nroot 1 0 100 50 0 0 S /init\n'
    if pid is not None:
        text += f'{user} {pid} 1 100 50 0 0 S {name or driver.PACKAGES["A"]}\n'
    return text.encode()


def picker_tree(name, mode='save', owner='com.android.documentsui'):
    root = ET.Element('hierarchy')
    ET.SubElement(root, 'node', {'package': owner, 'enabled': 'true',
                               'class': 'android.widget.EditText', 'resource-id': 'android:id/title',
                               'text': name, 'bounds': '[10,20][200,60]', 'clickable': 'true'})
    ET.SubElement(root, 'node', {'package': owner, 'enabled': 'true',
                               'text': mode.upper(), 'clickable': 'true', 'bounds': '[210,20][300,60]'})
    return root


class SyncReportTest(unittest.TestCase):
    def test_all_thirteen_native_results_are_required_and_exact_booleans(self):
        self.assertEqual(len(driver.RESULT_FLAGS), 13)
        for role in ('A', 'B'):
            good = report(role, 'complete')
            driver.validate_report(good, role, RUN_ID, 35)
            for key in driver.RESULT_FLAGS:
                for bad in (False, 1, 'true', None):
                    with self.subTest(role=role, key=key, bad=bad), self.assertRaises(ValueError):
                        driver.validate_report({**good, key: bad}, role, RUN_ID, 35)
                with self.subTest(role=role, missing=key), self.assertRaises(ValueError):
                    driver.validate_report({k: v for k, v in good.items() if k != key}, role, RUN_ID, 35)

    def test_identity_sdk_schema_package_build_role_and_run_are_strict(self):
        for key, bad in [('schemaVersion', True), ('schemaVersion', 2), ('sdkInt', '35'),
                         ('sdkInt', 33), ('packageName', 'com.haoxiguan.haoxiguan'),
                         ('role', 'B'), ('runId', 'old'), ('build', 11001)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                driver.validate_report(report(**{key: bad}), 'A', RUN_ID, 35)

    def test_launch_sequence_status_and_stage_are_strict(self):
        for fields in ({'launchId': ''}, {'launchId': '\u0661' * 32},
                       {'launchId': 'A' * 32}, {'reportSequence': True},
                       {'reportSequence': 0}, {'status': 'unknown'},
                       {'stage': 'awaitingRecoveryJoin'}, {'stage': 'anything'},
                       {'stage': 'complete'}, {'status': 'failed'},
                       {'stage': 'failed'}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                driver.validate_report({**report(), **fields}, 'A', RUN_ID, 35)

    def test_production_source_report_must_match_every_component(self):
        for key in driver.SOURCE:
            with self.subTest(key=key), self.assertRaises(ValueError):
                driver.validate_report(report(source={**driver.SOURCE, key: 'fake'}), 'A', RUN_ID, 35)
        with self.assertRaises(ValueError):
            driver.validate_report(report(source={**driver.SOURCE, 'mock': False}), 'A', RUN_ID, 35)

    def test_saf_only_accepts_this_runs_exact_document(self):
        for role, stages in [('A', ('awaitingRecoverySave', 'awaitingRecoveryReadback', 'awaitingBackupSave')),
                             ('B', ('awaitingRecoveryJoin', 'awaitingBackupReadback'))]:
            for stage in stages:
                good = report(role, stage)
                driver.validate_report(good, role, RUN_ID, 35)
                for bad in ('../private.key', 'other.hgr', f'sync-{RUN_ID}-C.hgb'):
                    with self.subTest(role=role, stage=stage, name=bad), self.assertRaises(ValueError):
                        driver.validate_report({**good, 'documentName': bad}, role, RUN_ID, 35)

    def test_sensitive_future_fields_and_original_error_text_are_never_archived(self):
        value = report(stage='failed', invite='SECRET-INVITE', token='SECRET-TOKEN',
                       password='SECRET-PASSWORD', error='SECRET-NOTE', errorCode='production_enrollment_failed')
        clean = driver.validate_report(value, 'A', RUN_ID, 35)
        self.assertEqual(clean['errorCode'], 'production_enrollment_failed')
        self.assertNotIn('SECRET', json.dumps(clean))
        self.assertEqual(set(clean), {'schemaVersion', 'sdkInt', 'packageName', 'runId',
                                     'role', 'build', 'reportSequence', 'launchId', 'source',
                                     'stage', 'status', 'errorCode', 'evidence'})

    def test_failure_and_action_allowlists_exactly_match_frozen_dart_protocol(self):
        source = (driver.ROOT / 'tools/native_sync/diagnostics.dart').read_text(encoding='utf-8')
        for name, values in [('syncAcceptanceFailureCodes', driver.FAILURE_CODES),
                             ('syncAcceptanceActionIds', driver.ACTION_IDS),
                             ('syncAcceptanceFrameworkFailures', driver.FRAMEWORK_FAILURES)]:
            block = re.search(r'const ' + name + r'\s*=\s*<String>\{(.*?)\};', source, re.S)
            self.assertIsNotNone(block)
            self.assertEqual(set(re.findall(r"'([^']*)'", block.group(1))), set(values))
        stages = re.search(r'const syncAcceptanceDiagnosticStages\s*=\s*<String>\{(.*?)\};', source, re.S)
        self.assertEqual(set(re.findall(r"'([^']*)'", stages.group(1))),
                         set(driver.ROLE_STAGES['A']) | set(driver.ROLE_STAGES['B']) | {'boot'})

    def test_fixed_diagnostic_values_survive_without_any_ui_or_credential_fields(self):
        value = report(stage='failed', errorCode='production_enrollment_failed', diagnostic={
            'failureCode': 'production_enrollment_failed', 'lastStage': 'boot',
            'lastAction': 'verify_binding', 'frameworkFailure': 'none',
            'password': 'SECRET', 'message': 'SECRET', 'selector': 'SECRET'})
        clean = driver.validate_report(value, 'A', RUN_ID, 35)
        self.assertEqual(clean['diagnostic'], {'failureCode': 'production_enrollment_failed',
                         'lastStage': 'boot', 'lastAction': 'verify_binding', 'frameworkFailure': 'none'})
        self.assertNotIn('SECRET', json.dumps(clean))

    def test_unknown_diagnostic_values_or_wrong_role_stage_are_rejected(self):
        good = {'failureCode': 'production_enrollment_failed', 'lastStage': 'boot',
                'lastAction': 'verify_binding', 'frameworkFailure': 'none'}
        for key, bad in [('failureCode', 'SECRET'), ('lastStage', 'awaitingRecoveryJoin'),
                         ('lastAction', 'SECRET'), ('frameworkFailure', 'SECRET')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                driver.validate_report(report(stage='failed', errorCode='production_enrollment_failed',
                        diagnostic={**good, key: bad}), 'A', RUN_ID, 35)
        for bad in ('SECRET', 'none', [], None):
            with self.subTest(errorCode=bad), self.assertRaises(ValueError):
                driver.validate_report(report(stage='failed', errorCode=bad), 'A', RUN_ID, 35)

    def test_failed_diagnostic_must_match_failure_status_and_top_level_code(self):
        with self.assertRaises(ValueError):
            driver.validate_report(report(stage='failed', errorCode='production_enrollment_failed',
                    diagnostic={'failureCode': 'native_sync_failure', 'lastStage': 'boot',
                                'lastAction': 'verify_binding', 'frameworkFailure': 'none'}), 'A', RUN_ID, 35)
        with self.assertRaises(ValueError):
            driver.validate_report(report(diagnostic={'failureCode': 'production_enrollment_failed',
                    'lastStage': 'boot', 'lastAction': 'verify_binding', 'frameworkFailure': 'none'}), 'A', RUN_ID, 35)

    def test_complete_reports_require_exhaustive_evidence_with_identical_before_after(self):
        for key in complete_evidence():
            value = complete_evidence()
            del value[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)
        for group, metrics in driver.EVIDENCE_METRICS.items():
            for metric in ('SnapshotSha256', *metrics):
                value = complete_evidence()
                key = 'after' + metric
                value[group][key] = 'c' * 64 if metric == 'SnapshotSha256' else 2
                with self.subTest(group=group, metric=metric), self.assertRaises(ValueError):
                    driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)

    def test_evidence_digests_counts_and_revisions_use_strict_safe_types(self):
        for bad in (True, -1, '1', 1.0, None):
            value = complete_evidence()
            value['restart']['afterBusinessRevision'] = bad
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)
        for bad in ('secret', 'A' * 64, 'a' * 63, '../file'):
            value = complete_evidence()
            value['initialActualFactsSha256'] = bad
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)
        value = complete_evidence()
        value['counts']['entries'] = 9
        with self.assertRaises(ValueError):
            driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)

    def test_evidence_whitelist_discards_nested_secrets(self):
        value = complete_evidence()
        value['token'] = 'SECRET'
        value['cancel']['password'] = 'SECRET'
        value['restart']['note'] = 'SECRET'
        value['counts']['invite'] = 'SECRET'
        clean = driver.validate_report(report(stage='complete', evidence=value), 'A', RUN_ID, 35)
        self.assertNotIn('SECRET', json.dumps(clean))


class NativeSyncDriverTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        directory = Path(self.directory.name)
        self.args = SimpleNamespace(output=directory, sdk=Path('/sdk'), api=35,
                                    port=5580, apks=directory / 'apks',
                                    stage_timeout=180, total_timeout=1200)
        self.relay = Mock(port=45678, endpoint='https://localhost:45678',
                          certificate='PUBLIC-CERTIFICATE', invites={'A': 'SECRET-A', 'B': 'SECRET-B'})
        self.driver = driver.NativeSyncDriver(self.args, directory / 'private', self.relay)
        self.driver.run_id = RUN_ID
        self.driver.sdk_int = 35
        self.driver.process = Mock(pid=123)
        self.driver.process.poll.return_value = None

    def events(self):
        file = self.args.output / 'driver-events.jsonl'
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def test_every_adb_operation_targets_only_this_serial(self):
        with patch.object(driver, 'run_owned', return_value=result()) as run:
            self.driver.adb_command('shell', 'am', 'force-stop', driver.PACKAGES['A'])
        self.assertEqual(run.call_args.args[0], [self.driver.adb, '-s',
                         'emulator-5580', 'shell', 'am', 'force-stop', driver.PACKAGES['A']])

    def test_existing_serial_is_rejected_including_offline(self):
        for status in ('device', 'offline'):
            with self.subTest(status=status), patch.object(driver, 'run_owned', return_value=result(
                    f'List of devices attached\nemulator-5580\t{status}\n'.encode())):
                with self.assertRaises(RuntimeError):
                    self.driver.check_unused_serial()
        with patch.object(driver, 'run_owned', return_value=result(
                b'List of devices attached\nother-device\tdevice\n')) as run:
            self.driver.check_unused_serial()
        self.assertEqual(run.call_args.args[0], [self.driver.adb, 'devices'])

    def test_mutations_marked_before_delivery_are_not_replayed_after_closed_adb(self):
        with patch.object(driver, 'run_owned', return_value=result(
                b'SECRET-TOKEN', 255, b'SECRET-INVITE')) as run:
            with self.assertRaises(RuntimeError):
                self.driver.focus('A', 'initial')
            self.assertFalse(self.driver.focus('A', 'initial'))
        run.assert_called_once()
        self.assertNotIn('SECRET', json.dumps(self.events()))

    def test_private_config_is_delivered_by_stdin_only_to_owned_files(self):
        config = {'invite': 'SECRET-INVITE', 'endpoint': 'https://localhost:45678'}
        with patch.object(self.driver, 'adb_command', return_value=result()) as call:
            self.driver.write_private('B', driver.CONFIG_FILE, config)
        self.assertEqual(call.call_args.args, ('shell', 'run-as', driver.PACKAGES['B'],
                         'sh', '-c', "'mkdir -p files && cat > files/sync_acceptance_config.json'"))
        self.assertEqual(json.loads(call.call_args.kwargs['input']), config)
        self.assertNotIn('SECRET', str(call.call_args.args))
        for role, path in [('C', driver.CONFIG_FILE), ('A', '../key')]:
            with self.subTest(role=role, path=path), self.assertRaises(ValueError):
                self.driver.write_private(role, path, config)

    def test_sdk_is_independently_read_before_protocol(self):
        with patch.object(self.driver, 'shell', return_value='35\n'):
            self.driver.verify_sdk()
        self.assertEqual(self.driver.sdk_int, 35)
        for value in ('33', '35.0', '\u0663\u0665', ''):
            with self.subTest(value=value), patch.object(self.driver, 'shell', return_value=value), self.assertRaises(RuntimeError):
                self.driver.verify_sdk()

    def test_control_payload_exactly_matches_role_stage_sdk_and_run_and_is_once(self):
        value = report('B', 'awaitingSourceUpload')
        with patch.object(self.driver, 'shell', return_value='') as shell, patch.object(
                self.driver, 'write_private') as write:
            self.driver.acknowledge('B', value)
            self.driver.acknowledge('B', value)
        shell.assert_called_once()
        write.assert_called_once_with('B', driver.CONTROL_FILE, {
            'schemaVersion': 3, 'runId': RUN_ID, 'stage': 'awaitingSourceUpload',
            'sdkInt': 35, 'packageName': driver.PACKAGES['B'],
            'launchId': FIRST_LAUNCH, 'reportSequence': 1})

    def test_foreign_reports_fail_before_driving_ui_and_are_not_written(self):
        value = report(invite='SECRET', sdkInt=24)
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(value).encode())):
            with self.assertRaises(ValueError):
                self.driver.read_report('A')
        self.assertFalse((self.args.output / 'report-a.json').exists())

    def test_report_evidence_whitelist_discards_sensitive_unknown_fields(self):
        value = report(invite='SECRET-INVITE', noteText='SECRET-NOTE')
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(value).encode())):
            self.driver.read_report('A')
        self.assertNotIn('SECRET', (self.args.output / 'report-a.json').read_text())

    def test_failure_keeps_last_independently_observed_stage_and_safe_code(self):
        values = [report(), report(stage='failed', reportSequence=2,
                                  errorCode='production_enrollment_failed')]
        with patch.object(self.driver, 'adb_command', side_effect=[result(json.dumps(value).encode()) for value in values]):
            self.driver.read_report('A')
            with self.assertRaises(RuntimeError):
                self.driver.read_report('A')
        saved = json.loads((self.args.output / 'report-a.json').read_text())
        self.assertEqual(saved['errorCode'], 'production_enrollment_failed')
        self.assertEqual(saved['lastValidatedStage'], 'boot')
        self.assertEqual(self.driver.last_running_stages, {'A': 'boot'})

    def test_sequence_cannot_reverse_or_rewrite_same_sequence(self):
        value = report(reportSequence=2)
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(value).encode())):
            self.driver.read_report('A')
        for bad in (report(), report(reportSequence=2, realTlsTransport=True)):
            with self.subTest(bad=bad), patch.object(self.driver, 'adb_command', return_value=result(json.dumps(bad).encode())), self.assertRaises(ValueError):
                self.driver.read_report('A')

    def test_repeated_boot_sequence_does_not_extend_stage_deadline(self):
        with patch.object(self.driver, 'adb_command', side_effect=[result(json.dumps(report()).encode()),
                result(json.dumps(report(reportSequence=2)).encode())]), patch.object(driver.time, 'monotonic', side_effect=range(100)):
            self.driver.read_report('A')
            started = self.driver.last_progress['A']
            self.driver.read_report('A')
        self.assertEqual(started, self.driver.last_progress['A'])

    def test_required_stages_cannot_be_skipped(self):
        for stage in ('awaitingReplicaImport', 'awaitingReopen', 'complete'):
            with self.subTest(stage=stage), patch.object(self.driver, 'adb_command', return_value=result(json.dumps(report(stage=stage)).encode())), self.assertRaises(ValueError):
                self.driver.read_report('A')

    def test_unowned_restart_cannot_satisfy_process_reopen(self):
        self.driver.reports['A'] = report()
        value = report(launchId=SECOND_LAUNCH)
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(value).encode())), self.assertRaises(ValueError):
            self.driver.read_report('A')

    def test_stale_report_cannot_satisfy_reopen_and_only_one_new_launch_is_allowed(self):
        old = report(stage='awaitingReopen')
        self.driver.reports['A'] = old
        self.driver.reopen_launches['A'] = FIRST_LAUNCH
        self.driver.stage_indices['A'] = driver.ROLE_STAGES['A'].index('awaitingReopen')
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(old).encode())):
            self.assertIsNone(self.driver.read_report('A'))
        fresh = report(stage='awaitingBackupSave', launchId=SECOND_LAUNCH)
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(fresh).encode())):
            self.driver.read_report('A')
        self.assertIn('A', self.driver.reopened)
        third = report(stage='awaitingBackupSave', launchId='3' * 32)
        with patch.object(self.driver, 'adb_command', return_value=result(json.dumps(third).encode())), self.assertRaises(ValueError):
            self.driver.read_report('A')

    def test_same_pid_and_user_still_blocks_when_process_name_changes(self):
        def adb(*values, **kwargs):
            if 'getprop' in values:
                return result(b'1')
            if 'service' in values:
                return result(b'Service activity: found')
            return result(process_list(2976, name='worker pool'))
        with patch.object(self.driver, 'adb_command', side_effect=adb), patch.object(
                driver.time, 'monotonic', side_effect=range(100)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                self.driver.wait_for_stop('A', {2976: 'u0_a62'}, timeout=15)
        self.assertFalse(any(value.get('ready') for value in self.events()))

    def test_recycled_pid_under_different_user_is_a_new_identity_after_two_healthy_reads(self):
        replies = [result(b'1'), result(b'Service activity: found'), result(process_list(2976, user='u0_a99'))]
        with patch.object(self.driver, 'adb_command', side_effect=replies * 2), patch.object(driver.time, 'sleep'):
            self.driver.wait_for_stop('A', {2976: 'u0_a62'})
        self.assertEqual([value['consecutive'] for value in self.events()], [1, 2])

    def test_invalid_process_snapshot_breaks_consecutive_readiness(self):
        good = [result(b'1'), result(b'Service activity: found'), result(process_list())]
        bad = [result(b'1'), result(b'Service activity: found'), result(b'bad header')]
        with patch.object(self.driver, 'adb_command', side_effect=good + bad + good + good), patch.object(driver.time, 'sleep'):
            self.driver.wait_for_stop('A', {2976: 'u0_a62'})
        self.assertEqual([value['consecutive'] for value in self.events()], [1, 0, 1, 2])

    def test_force_stop_requires_original_process_and_is_never_replayed(self):
        value = report(stage='awaitingReopen')
        with patch.object(self.driver, 'original_processes', return_value={2976: 'u0_a62'}) as original, patch.object(
                self.driver, 'wait_for_stop') as wait, patch.object(self.driver, 'shell', return_value='') as shell:
            self.driver.reopen('A', value)
            self.driver.reopen('A', value)
        original.assert_called_once_with('A')
        wait.assert_called_once_with('A', {2976: 'u0_a62'})
        self.assertEqual([call.args[:2] for call in shell.call_args_list],
                         [('am', 'force-stop'), ('am', 'start')])

    def test_exited_emulator_fails_before_foreground_launch(self):
        self.driver.process.poll.return_value = -9
        with patch.object(self.driver, 'shell') as shell, self.assertRaises(RuntimeError):
            self.driver.focus('A', 'initial')
        shell.assert_not_called()

    def test_saf_save_uses_exact_enabled_documentsui_controls_once(self):
        self.driver.foreground_role = 'A'
        value = report(stage='awaitingRecoverySave')
        tree = picker_tree(value['documentName'])
        with patch.object(self.driver, 'read_ui', return_value=tree), patch.object(
                self.driver, 'shell', return_value='') as shell:
            self.driver.picker('A', value)
            self.driver.picker('A', value)
        taps = [call.args for call in shell.call_args_list if call.args[0] == 'input']
        self.assertEqual(taps, [('input', 'tap', '255', '40')])

    def test_foreign_or_background_picker_is_not_driven(self):
        value = report(stage='awaitingRecoverySave')
        with patch.object(self.driver, 'read_ui') as read:
            self.driver.picker('A', value)
        read.assert_not_called()
        self.driver.foreground_role = 'A'
        with patch.object(self.driver, 'read_ui', return_value=picker_tree(value['documentName'], owner='other.app')), patch.object(
                self.driver, 'shell') as shell:
            self.driver.picker('A', value)
        shell.assert_not_called()

    def test_filename_edit_is_one_delivery_and_is_observed_before_save(self):
        self.driver.foreground_role = 'A'
        value = report(stage='awaitingRecoverySave')
        tree = picker_tree('old.hgr')
        with patch.object(self.driver, 'read_ui', return_value=tree), patch.object(
                self.driver, 'shell', return_value='') as shell:
            self.driver.picker('A', value)
            with self.assertRaises(ValueError):
                self.driver.picker('A', value)
        input_calls = [call.args for call in shell.call_args_list if call.args[0] == 'input']
        self.assertEqual(len([call for call in input_calls if call[1] == 'text']), 1)
        self.assertEqual(input_calls[-1], ('input', 'text', value['documentName']))
        self.assertEqual(input_calls[2], ('input', 'keyevent', *(['67'] * len('old.hgr'))))

    def test_ui_snapshot_is_removed_even_after_xml_parse_error_and_not_archived(self):
        def shell(*values, **kwargs):
            return '<SECRET-invalid' if values[0] == 'cat' else ''
        with patch.object(self.driver, 'shell', side_effect=shell) as call, self.assertRaises(ET.ParseError):
            self.driver.read_ui()
        self.assertEqual(call.call_args.args, ('rm', '-f', '/sdcard/sync-acceptance-ui.xml'))
        self.assertFalse(any(path.suffix in ('.xml', '.png') for path in self.args.output.iterdir()))

    def test_keyboard_can_hide_once_before_and_once_after_filename_edit(self):
        self.driver.foreground_role = 'A'
        value = report(stage='awaitingRecoverySave')
        current = ['old.hgr', True]
        def shell(*values, **kwargs):
            if values[0] == 'dumpsys':
                return 'mInputShown=true' if current[1] else ''
            return ''
        with patch.object(self.driver, 'read_ui', side_effect=lambda: picker_tree(current[0])), patch.object(
                self.driver, 'shell', side_effect=shell) as shell_call:
            self.driver.picker('A', value)
            self.driver.picker('A', value)  # stale IME observation must not replay Back
            current[1] = False
            self.driver.picker('A', value)  # filename edit opens the IME again
            current[:] = [value['documentName'], True]
            self.driver.picker('A', value)
            self.driver.picker('A', value)
            current[1] = False
            self.driver.picker('A', value)
        backs = [call for call in shell_call.call_args_list if call.args == ('input', 'keyevent', '4')]
        self.assertEqual(len(backs), 2)
        self.assertEqual(self.events()[-1]['action'], 'save')

    def test_stale_save_edittext_is_not_mistaken_for_an_open_document(self):
        self.driver.foreground_role = 'A'
        value = report(stage='awaitingRecoveryReadback')
        with patch.object(self.driver, 'read_ui', return_value=picker_tree(value['documentName'])), patch.object(
                self.driver, 'shell', return_value='') as shell:
            self.driver.picker('A', value)
        self.assertFalse(any(call.args[0] == 'input' for call in shell.call_args_list))

    def simulate_protocol(self, different_convergence=False):
        indices = {'A': 0, 'B': 0}
        reopens, controls, pickers = [], [], []
        reads = [0]
        def adb(*values, **kwargs):
            if values[0] != 'exec-out':
                return result()
            reads[0] += 1
            if reads[0] > 100:
                raise AssertionError('host handshake stopped making progress')
            role = next(role for role, package in driver.PACKAGES.items() if package == values[2])
            stage = driver.ROLE_STAGES[role][indices[role]]
            value = report(role, stage, reportSequence=indices[role] + 1,
                           launchId=SECOND_LAUNCH if role in reopens else FIRST_LAUNCH)
            if stage == 'complete' and different_convergence and role == 'B':
                value['evidence']['convergedActualFactsSha256'] = 'c' * 64
                value['evidence']['convergedExpectedFactsSha256'] = 'c' * 64
            return result(json.dumps(value).encode())
        def write(role, path, payload):
            stage = driver.ROLE_STAGES[role][indices[role]]
            prerequisite = driver.CONTROL_PREREQUISITES[(role, stage)]
            self.assertIn(prerequisite, self.driver.observed)
            self.assertEqual(path, driver.CONTROL_FILE)
            self.assertEqual(payload['stage'], stage)
            self.assertEqual(payload['reportSequence'], indices[role] + 1)
            self.assertEqual(payload['launchId'], FIRST_LAUNCH)
            controls.append((role, stage))
            indices[role] += 1
        def picker(role, value):
            self.assertEqual(self.driver.foreground_role, role)
            pickers.append((role, value['stage']))
            indices[role] += 1
        def reopen(role, value):
            if role in reopens:
                return
            if role == 'B':
                self.assertEqual(self.driver.reports['A']['status'], 'passed')
            reopens.append(role)
            self.driver.reopen_launches[role] = value['launchId']
            self.driver.foreground_role = role
            indices[role] += 1
        with patch.object(self.driver, 'configure'), patch.object(self.driver, 'adb_command', side_effect=adb), patch.object(
                self.driver, 'shell', return_value=''), patch.object(self.driver, 'write_private', side_effect=write), patch.object(
                self.driver, 'picker', side_effect=picker), patch.object(self.driver, 'reopen', side_effect=reopen), patch.object(
                driver.time, 'sleep'), patch.object(driver.time, 'monotonic', side_effect=range(10000)), patch('builtins.print'):
            self.driver.run_protocol()
        return reopens, controls, pickers

    def test_full_dual_client_protocol_requires_all_cross_device_gates_and_serializes_backups(self):
        reopens, controls, pickers = self.simulate_protocol()
        self.assertEqual(reopens, ['A', 'B'])
        self.assertEqual(len(controls), 5)
        self.assertEqual(len(set(controls)), 5)
        self.assertEqual(len(pickers), 7)
        self.assertEqual(pickers[-4:], [('A', 'awaitingBackupSave'), ('A', 'awaitingBackupReadback'),
                                       ('B', 'awaitingBackupSave'), ('B', 'awaitingBackupReadback')])
        results = json.loads((self.args.output / 'results.json').read_text())
        self.assertEqual({item['packageName'] for item in results}, set(driver.PACKAGES.values()))
        self.assertTrue(all(all(item[key] is True for key in driver.RESULT_FLAGS) for item in results))
        self.assertEqual(self.driver.reopened, {'A', 'B'})

    def test_two_independent_clients_must_agree_on_the_complete_converged_facts(self):
        with self.assertRaises(ValueError):
            self.simulate_protocol(different_convergence=True)
        self.assertFalse((self.args.output / 'results.json').exists())

    def test_cleanup_failure_does_not_replace_original_exception_and_closes_log(self):
        self.driver.reverse_created = True
        self.driver.log = io.BytesIO()
        primary = RuntimeError('primary failure')
        with patch.object(self.driver, 'adb_command', side_effect=RuntimeError('SECRET')):
            try:
                try:
                    raise primary
                finally:
                    self.driver.close()
            except RuntimeError as error:
                self.assertIs(error, primary)
        self.driver.process.terminate.assert_called_once()
        self.assertTrue(self.driver.log.closed)
        self.assertNotIn('SECRET', json.dumps(self.events()))

    def test_windows_runner_is_blocked_before_any_sdk_go_or_network_action(self):
        # sys is shared with shutil: Linux Python 3.12 has no _winapi module.
        # Isolate executable discovery too so the simulated Windows guard tests
        # our driver without accidentally calling shutil's Windows-only code.
        with patch.object(driver.sys, 'platform', 'win32'), patch.object(driver.shutil, 'which', return_value='synthetic-go'), patch.object(driver.sys, 'stderr', io.StringIO()), patch.object(driver, 'run_owned') as run, patch.object(
                driver.DisposableRelay, 'start') as relay, patch.object(driver.NativeSyncDriver, 'start_emulator') as emulator:
            with self.assertRaises(SystemExit):
                driver.main(['--api', '35', '--apks', '.', '--output', str(self.args.output)])
        run.assert_not_called()
        relay.assert_not_called()
        emulator.assert_not_called()


class OwnedProcessGroupTest(unittest.TestCase):
    def setUp(self):
        self.process = Mock(pid=43210, returncode=0)
        self.process.poll.return_value = 0
        self.process.communicate.return_value = (b'out', b'err')
        self.killpg = patch.object(driver.os, 'killpg', create=True).start()
        self.addCleanup(patch.stopall)
        patch.object(driver.signal, 'SIGKILL', 9, create=True).start()

    def test_owned_launch_creates_a_separate_session_and_records_exact_group(self):
        with patch.object(driver.subprocess, 'Popen', return_value=self.process) as spawn:
            owned = driver.start_owned(['synthetic-command'], stdout=subprocess.PIPE)
        self.assertEqual(owned._sync_owned_group, self.process.pid)
        self.assertIs(spawn.call_args.kwargs['start_new_session'], True)

    def test_completed_command_still_reclaims_its_owned_descendants(self):
        with patch.object(driver.subprocess, 'Popen', return_value=self.process) as spawn:
            completed = driver.run_owned(['synthetic-command'], input=b'SECRET', timeout=7)
        spawn.assert_called_once()
        self.assertEqual(completed.stdout, b'out')
        self.assertEqual(self.killpg.call_args_list[0].args, (43210, driver.signal.SIGTERM))
        self.assertEqual(self.killpg.call_args_list[1].args, (43210, 9))

    def test_timeout_reclaims_only_the_owned_group_without_restarting_the_command(self):
        self.process.communicate.side_effect = [subprocess.TimeoutExpired(['synthetic-command'], 7), (b'', b'')]
        with patch.object(driver.subprocess, 'Popen', return_value=self.process) as spawn, self.assertRaises(subprocess.TimeoutExpired):
            driver.run_owned(['synthetic-command'], timeout=7)
        spawn.assert_called_once()
        self.assertEqual([call.args[0] for call in self.killpg.call_args_list], [43210, 43210])

    def test_group_cleanup_error_preserves_timeout_and_reclaims_direct_child(self):
        self.killpg.side_effect = PermissionError('synthetic cleanup failure')
        self.process.poll.return_value = None
        self.process.communicate.side_effect = [subprocess.TimeoutExpired(['synthetic-command'], 7), (b'', b'')]
        with patch.object(driver.subprocess, 'Popen', return_value=self.process), self.assertRaises(subprocess.TimeoutExpired):
            driver.run_owned(['synthetic-command'], timeout=7)
        self.process.terminate.assert_called_once()

    def test_different_group_is_never_signaled(self):
        self.process._sync_owned_group = 43211
        with self.assertRaises(ValueError):
            driver.stop_process(self.process)
        self.killpg.assert_not_called()


class SyncBuildRestorationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / 'android/app/build.gradle.kts'
        self.manifest = self.root / 'android/app/src/main/AndroidManifest.xml'
        self.repository = self.root / 'lib/data/sqlite_habit_repository.dart'
        self.baseline = self.root / 'tools/fixtures/schema2_repository.dart.txt'
        for path in (self.app, self.manifest, self.repository, self.baseline):
            path.parent.mkdir(parents=True, exist_ok=True)
        self.app.write_bytes(b'\xef\xbb\xbfapplicationId = "com.haoxiguan.haoxiguan"\r\n')
        self.manifest.write_bytes('<application android:label="好习惯">\r\n<activity android:name=".MainActivity" /></application>\r\n'.encode())
        self.repository.write_bytes(b'int get schemaVersion => 3;\r\n')
        self.baseline.write_bytes(b'int get schemaVersion => 2;\r\nFROZEN\r\n')
        self.originals = {path: path.read_bytes() for path in (self.app, self.manifest, self.repository, self.baseline)}

    def assert_restored(self):
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original)

    def test_success_uses_two_isolated_debug_packages_and_restores_every_byte(self):
        builds = []
        def run(values, **kwargs):
            builds.append((values, self.app.read_bytes(), self.manifest.read_bytes(), self.repository.read_bytes()))
            self.assertIn('--debug', values)
            self.assertNotIn('--release', values)
            self.assertIn('tools/android_sync_acceptance.dart', values)
            apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(str(len(builds)).encode())
            return result()
        with patch.object(builder.subprocess, 'run', side_effect=run):
            builder.build('flutter', self.root)
        self.assert_restored()
        for index, role in enumerate(('A', 'B')):
            values, app, manifest, repository = builds[index]
            self.assertIn(builder.PACKAGES[role].encode(), app)
            self.assertIn(f'Haoxiguan Sync Acceptance {role}'.encode(), manifest)
            self.assertIn(b'android:name="com.haoxiguan.haoxiguan.MainActivity"', manifest)
            self.assertEqual(repository, self.originals[self.repository])
            self.assertFalse(any('INVITE' in value or 'PASSWORD' in value for value in values))
        self.assertEqual((self.root / 'build/sync-acceptance/sync-acceptance-a.apk').read_bytes(), b'1')
        self.assertEqual((self.root / 'build/sync-acceptance/sync-acceptance-b.apk').read_bytes(), b'2')

    def test_build_or_copy_failure_restores_bytes_including_second_role_failure(self):
        for failure_call in (1, 2):
            count = [0]
            def run(values, **kwargs):
                count[0] += 1
                if count[0] == failure_call:
                    raise subprocess.CalledProcessError(1, values)
            with self.subTest(failure_call=failure_call), patch.object(builder.subprocess, 'run', side_effect=run), patch.object(builder.shutil, 'copy2'):
                with self.assertRaises(subprocess.CalledProcessError):
                    builder.build('flutter', self.root)
                self.assert_restored()
        with patch.object(builder.subprocess, 'run'), patch.object(builder.shutil, 'copy2', side_effect=OSError('copy failure')):
            with self.assertRaises(OSError):
                builder.build('flutter', self.root)
            self.assert_restored()

    def test_wrong_product_id_or_schema_is_rejected_before_mutating_sources(self):
        for path, bad in [(self.app, b'applicationId = "other.package"'),
                          (self.repository, b'int get schemaVersion => 2;')]:
            original = path.read_bytes()
            path.write_bytes(bad)
            snapshots = {p: p.read_bytes() for p in self.originals}
            with self.subTest(path=path), patch.object(builder.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    builder.build('flutter', self.root)
                run.assert_not_called()
                for p, content in snapshots.items():
                    self.assertEqual(p.read_bytes(), content)
            path.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
