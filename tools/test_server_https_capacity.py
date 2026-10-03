"""Host-only regressions for capacity routing/TLS and single-use authentication.

All sockets and HTTP connections are fakes. No Go, Docker or network is run.
"""
import ipaddress
import json
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import Mock, patch

import server_https_capacity as capacity


class CapacityRoutingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='capacity-host-test-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.harness = capacity.Harness('unused-fixture-image', root/'report.json', root)
        self.harness.subnets = [ipaddress.ip_network('172.28.0.0/16')]
        self.harness.tls = ssl.create_default_context()
        self.harness.address = '172.28.0.2'

    def config(self, address='172.28.0.2'):
        return {'NetworkSettings': {'Networks': {
            self.harness.network: {'IPAddress': address}}, 'Ports': {'8787/tcp': None}}}

    def test_connects_to_owned_ip_but_checks_localhost_certificate(self):
        context = Mock(check_hostname=True, verify_mode=ssl.CERT_REQUIRED)
        raw, secured = Mock(), Mock()
        context.wrap_socket.return_value = secured
        with patch.object(capacity.socket, 'create_connection', return_value=raw) as connect:
            connection = capacity.ContainerHTTPSConnection('172.28.0.2', context, timeout=7)
            connection.connect()
        connect.assert_called_once_with(('172.28.0.2', 8787), 7)
        context.wrap_socket.assert_called_once_with(raw, server_hostname='localhost')
        self.assertIs(connection.sock, secured)
        raw.close.assert_not_called()

    def test_certificate_rejection_closes_transport_without_downgrade(self):
        context = Mock(check_hostname=True, verify_mode=ssl.CERT_REQUIRED)
        context.wrap_socket.side_effect = ssl.SSLCertVerificationError('synthetic bad certificate')
        raw = Mock()
        with patch.object(capacity.socket, 'create_connection', return_value=raw) as connect:
            connection = capacity.ContainerHTTPSConnection('172.28.0.2', context, timeout=7)
            with self.assertRaises(ssl.SSLCertVerificationError):
                connection.connect()
        self.assertEqual(connect.call_count, 1)
        raw.close.assert_called_once()
        self.assertIsNone(connection.sock)

    def test_rejects_insecure_tls_contexts_before_connecting(self):
        for context in (Mock(check_hostname=False, verify_mode=ssl.CERT_REQUIRED),
                        Mock(check_hostname=False, verify_mode=ssl.CERT_NONE)):
            with self.subTest(context=context), self.assertRaises(RuntimeError):
                capacity.ContainerHTTPSConnection('172.28.0.2', context, timeout=7)

    def test_private_endpoint_can_change_after_restart(self):
        self.harness.refresh_endpoint(self.config())
        self.assertEqual(self.harness.address, '172.28.0.2')
        self.harness.refresh_endpoint(self.config('172.28.0.3'))
        self.assertEqual(self.harness.address, '172.28.0.3')

    def test_rejects_other_network_and_outside_addresses(self):
        for address in ('127.0.0.1', '8.8.8.8', '192.168.1.2'):
            with self.subTest(address=address), self.assertRaises(RuntimeError):
                self.harness.refresh_endpoint(self.config(address))
        config = self.config()
        config['NetworkSettings']['Networks']['unowned-network'] = {'IPAddress': '172.29.0.2'}
        with self.assertRaises(RuntimeError):
            self.harness.refresh_endpoint(config)

    def test_rejects_published_ports(self):
        config = self.config()
        config['NetworkSettings']['Ports']['8787/tcp'] = [{'HostIp': '127.0.0.1', 'HostPort': '8787'}]
        with self.assertRaises(RuntimeError):
            self.harness.refresh_endpoint(config)

    def test_ambiguous_one_time_authentication_is_never_replayed(self):
        self.harness.fault_window.set()
        for path, body in (('/v1/auth/refresh', {'refreshToken': 'synthetic'}),
                           ('/v1/auth/enroll', {'invite': 'synthetic'})):
            connection = Mock()
            connection.request.side_effect = ConnectionResetError('commit may have succeeded')
            with self.subTest(path=path), patch.object(
                    capacity, 'ContainerHTTPSConnection', return_value=connection) as factory:
                with self.assertRaises(ConnectionResetError):
                    self.harness.request('auth-probe', path, body)
                self.assertEqual(factory.call_count, 1)
                self.assertEqual(connection.request.call_count, 1)
                connection.close.assert_called_once()

    def test_idempotent_push_still_retries_during_controlled_restart(self):
        self.harness.fault_window.set()
        interrupted, recovered = Mock(), Mock()
        interrupted.request.side_effect = ConnectionResetError('interrupted request')
        recovered.getresponse.return_value.status = 200
        recovered.getresponse.return_value.read.return_value = json.dumps({'results': []}).encode()
        body = {'epoch': 'synthetic', 'operations': []}
        with patch.object(capacity, 'ContainerHTTPSConnection', side_effect=[interrupted, recovered]), \
                patch.object(self.harness, 'wait'):
            self.assertEqual(self.harness.request('push-probe', '/v1/push', body), {'results': []})
        self.assertEqual(interrupted.request.call_args, recovered.request.call_args)


if __name__ == '__main__':
    unittest.main()
