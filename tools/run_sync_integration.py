"""Provision a disposable real HTTPS Go relay and run Flutter E2EE tests.
Only generated synthetic invitations/certificates are used. No existing service
or database is touched. Secrets are kept in a private temporary directory.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--go', default=shutil.which('go'))
parser.add_argument('--flutter', default=shutil.which('flutter'))
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
assert args.go and args.flutter, 'Go and Flutter executables are required'

def run(values, **kwargs):
    return subprocess.run(values, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='haoxiguan-sync-e2e-') as temporary:
    directory = Path(temporary)
    binary, database = directory/('server.exe' if os.name == 'nt' else 'server'), directory/'data.sqlite'
    cert, key = directory/'cert.pem', directory/'key.pem'
    run([args.go, 'build', '-trimpath', '-o', str(binary), './cmd/haoxiguan-server'],
        cwd=root/'server')
    run([args.go, 'run', str(root/'tools'/'sync_test_certificate.go'), str(cert), str(key)])
    key.chmod(0o600)
    first, second = directory/'first.json', directory/'second.json'
    run([str(binary), 'create-user', '--db', str(database), '--name', 'synthetic-e2e', '--out', str(first)])
    account = json.loads(first.read_text())
    run([str(binary), 'invite', '--db', str(database), '--user', account['userId'], '--out', str(second)])
    invitations = directory/'invites.json'
    invitations.write_text(json.dumps({'userId': account['userId'], 'invites': [account['invite'], json.loads(second.read_text())['invite']]}))
    invitations.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    address = f'127.0.0.1:{port}'
    log = (directory/'server.log').open('wb')
    process = subprocess.Popen([str(binary), 'serve', '--db', str(database), '--listen', address,
                                '--tls-cert', str(cert), '--tls-key', str(key)], stdout=log, stderr=log)
    try:
        context = ssl.create_default_context(cafile=str(cert))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('synthetic test server exited')
            try:
                with urllib.request.urlopen(f'https://localhost:{port}/healthz', context=context, timeout=2) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.2)
        else:
            raise TimeoutError('synthetic HTTPS test server did not become healthy')
        run([args.flutter, 'test', '--no-pub', 'test/sync_integration_test.dart',
             f'--dart-define=TEST_SYNC_ENDPOINT=https://localhost:{port}',
             f'--dart-define=TEST_SYNC_CERT={cert}',
             f'--dart-define=TEST_SYNC_INVITES_FILE={invitations}',
             f'--dart-define=TEST_SYNC_OPERATOR={binary}',
             f'--dart-define=TEST_SYNC_DB={database}',
             f'--dart-define=TEST_SYNC_KEY={key}',
             f'--dart-define=TEST_SYNC_SERVER_PID={process.pid}',
             f'--dart-define=TEST_SYNC_LISTEN={address}'], cwd=root)
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
