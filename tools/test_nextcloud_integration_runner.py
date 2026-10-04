"""Targeted runner safety/failure checks; no Docker, Go or SDK is executed."""
from contextlib import contextmanager
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tools import run_nextcloud_integration as runner


class NextcloudRunnerTests(unittest.TestCase):
    def test_subprocess_failure_log_redacts_headers_credentials_and_private_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'test.log'
            output = ('Authorization: Basic dGVzdDpwYXNzd29yZA==\n'
                      'Set-Cookie: private-session\n'
                      f'{runner.PASSWORD}\nC:\\Users\\private\\secret.txt\n'
                      '/home/private-user/secret.txt\n'
                      f'{temporary}/key.pem\n')
            result = subprocess.CompletedProcess(['synthetic-tool'], 7, output)
            with patch.object(runner.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(runner.RunnerFailure, 'exit code 7'):
                    runner.command(['synthetic-tool'], timeout=5, stage='targeted test',
                                   output=log, private_paths=[temporary])
            saved = log.read_text(encoding='utf-8')
            for secret in ['dGVzdDpwYXNzd29yZA', 'private-session', runner.PASSWORD,
                           'private-user', 'secret.txt', temporary]:
                self.assertNotIn(secret, saved)

    def test_timeout_partial_log_is_redacted_and_diagnostic_has_no_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'timeout.log'
            error = subprocess.TimeoutExpired(['private/executable', 'private-token'], 5,
                                              output=b'Authorization: Bearer private-token\n')
            with patch.object(runner.subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(runner.RunnerFailure, 'exceeded its 5s timeout') as caught:
                    runner.command(['private/executable', 'private-token'], timeout=5,
                                   stage='targeted test', output=log)
            self.assertNotIn('private', str(caught.exception))
            self.assertNotIn('private-token', log.read_text(encoding='utf-8'))

    def test_cleanup_refuses_a_container_with_another_owner(self):
        calls = []
        def fake_command(args, **kwargs):
            calls.append(args)
            if args[1:3] == ['container', 'ls']:
                return 'a' * 64
            return json.dumps([{'Id': 'a' * 64, 'Config': {
                'Labels': {runner.OWNER_LABEL: 'someone-else'}}}])

        with patch.object(runner, 'command', side_effect=fake_command):
            with self.assertRaisesRegex(runner.RunnerFailure, 'ownership did not match'):
                runner.cleanup_container('docker', 'our-random-container', 'our-owner', Path('.'))
        self.assertFalse(any('rm' in args for args in calls))

    def test_missing_owned_container_is_a_successful_cleanup_noop(self):
        with patch.object(runner, 'command', return_value='') as command:
            result = runner.cleanup_container('docker', 'our-random-container',
                                              'our-owner', Path('.'))
        self.assertEqual(result, 'no-owned-container-remains')
        self.assertEqual(command.call_count, 1)
        args = command.call_args.args[0]
        self.assertIn('name=^/our-random-container$', args)
        self.assertIn(f'label={runner.OWNER_LABEL}=our-owner', args)

    def _run_fixture(self, output, *, failure_stage=None, cleanup_failure=False,
                     linux=True):
        commands = []
        state = {}
        immutable_digest = 'nextcloud@sha256:' + 'b' * 64
        container_id = 'a' * 64

        @contextmanager
        def fake_proxy(*_args):
            yield SimpleNamespace(server_address=('127.0.0.1', 24443), upstream_port=0)

        def fake_command(args, **kwargs):
            commands.append((args, kwargs))
            stage = kwargs['stage']
            if stage == 'isolated container creation':
                label = args[args.index('--label') + 1]
                state['owner'] = label.split('=', 1)[1]
            if stage == failure_stage:
                raise runner.RunnerFailure(f'{stage} exceeded its 5s timeout')
            if cleanup_failure and stage == 'owned container and anonymous volume cleanup':
                raise runner.RunnerFailure('owned cleanup failed with exit code 1')
            if stage == 'test certificate generation':
                Path(args[-2]).write_text('public mock certificate', encoding='utf-8')
                Path(args[-1]).write_text('mock private key never retained', encoding='utf-8')
            if stage == 'loopback port inspection':
                return '127.0.0.1:18080\n'
            if stage == 'installed Nextcloud version inspection':
                return json.dumps({'installed': True, 'versionstring': runner.VERSION})
            if stage == 'cleanup owned-container lookup':
                return container_id
            if stage == 'cleanup ownership inspect':
                return json.dumps([{'Id': container_id, 'Config': {
                    'Labels': {runner.OWNER_LABEL: state['owner']}}}])
            return ''

        arguments = SimpleNamespace(output=output, docker='synthetic-docker',
                                    go='synthetic-go', flutter='synthetic-flutter',
                                    pull_timeout=300, startup_timeout=600,
                                    test_timeout=900)
        with (patch.object(runner, 'source_evidence',
                           return_value=('c' * 40, 'd' * 64, {'lib/example.dart': 'e' * 64})),
              patch.object(runner.sys, 'platform', 'linux' if linux else 'win32'),
              patch.object(runner, 'immutable_image', return_value={
                  'tag': runner.IMAGE, 'digest': immutable_digest,
                  'imageId': 'sha256:' + 'f' * 64, 'os': 'linux', 'architecture': 'amd64'}),
              patch.object(runner, 'proxy_service', side_effect=fake_proxy),
              patch.object(runner, 'wait_ready'),
              patch.object(runner, 'command', side_effect=fake_command),
              patch('sys.stdout', new=io.StringIO())):
            result = runner.run(arguments)
        report = json.loads((output / 'results.json').read_text(encoding='utf-8'))
        return result, report, commands

    def test_success_starts_digest_on_loopback_runs_both_targets_and_removes_only_own_volume(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'evidence'
            result, report, commands = self._run_fixture(output)
            self.assertEqual(result, 0)
            self.assertEqual(report['result'], 'passed')
            self.assertTrue(report['testExecuted'])
            self.assertEqual(report['service']['actualVersion'], runner.VERSION)
            self.assertEqual(report['sourceCommit'], 'c' * 40)
            self.assertEqual(report['sourceSha256'], 'd' * 64)
            create = next(args for args, k in commands if k['stage'] == 'isolated container creation')
            self.assertEqual(create[create.index('--publish') + 1], '127.0.0.1::80')
            self.assertEqual(create[-1], 'nextcloud@sha256:' + 'b' * 64)
            self.assertNotIn('--mount', create)
            self.assertNotIn('--volume', create)
            test, options = next((args, k) for args, k in commands
                                 if k['stage'] == 'targeted Nextcloud Dart tests')
            self.assertTrue(all(file in test for file in runner.TEST_FILES))
            self.assertEqual(options['timeout'], 900)
            self.assertEqual(options['env']['NO_PROXY'], '127.0.0.1,localhost')
            remove = next(args for args, k in commands
                          if k['stage'] == 'owned container and anonymous volume cleanup')
            self.assertEqual(remove, ['synthetic-docker', 'rm', '--force', '--volumes', 'a' * 64])
            self.assertFalse(any('prune' in args for args, _ in commands))
            self.assertFalse(any(p.name in {'key.pem', 'cert.pem'} for p in output.rglob('*')))

    def test_creation_timeout_still_cleans_owned_container_and_records_no_test_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, commands = self._run_fixture(
                Path(temporary), failure_stage='isolated container creation')
        self.assertEqual(result, 1)
        self.assertEqual(report['result'], 'failed')
        self.assertFalse(report['testExecuted'])
        self.assertEqual(report['cleanup'], 'owned-container-and-anonymous-volumes-removed')
        self.assertTrue(any('rm' in args for args, _ in commands))

    def test_test_timeout_records_execution_and_cleans_owned_container(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, _ = self._run_fixture(
                Path(temporary), failure_stage='targeted Nextcloud Dart tests')
        self.assertEqual(result, 1)
        self.assertTrue(report['testExecuted'])
        self.assertIn('timeout', report['error'])
        self.assertEqual(report['cleanup'], 'owned-container-and-anonymous-volumes-removed')

    def test_cleanup_failure_prevents_a_passed_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, _ = self._run_fixture(Path(temporary), cleanup_failure=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['result'], 'failed')
        self.assertEqual(report['cleanup'], 'failed')

    def test_windows_preflight_records_block_without_starting_local_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, commands = self._run_fixture(Path(temporary), linux=False)
        self.assertEqual(result, 1)
        self.assertEqual(commands, [])
        self.assertFalse(report['testExecuted'])
        self.assertIn('Linux CI', report['error'])

    def test_timeout_cli_is_bounded(self):
        self.assertEqual(runner.bounded_timeout('900'), 900)
        for value in ['0', '901', 'nan', 'inf']:
            with self.assertRaises(Exception):
                runner.bounded_timeout(value)


if __name__ == '__main__':
    unittest.main()
