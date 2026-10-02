"""Exercise an isolated non-root, read-only container and offline server restore."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--image', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
prefix = 'haoxiguan-acceptance-' + uuid.uuid4().hex[:12]
volume, container = prefix+'-data', prefix+'-server'
environment = os.environ.copy()
for selector in ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH']:
    environment.pop(selector, None)

def docker(*values, check=True):
    result = subprocess.run(['docker', '--host=unix:///var/run/docker.sock', *values],
                            check=False, capture_output=True, text=True, env=environment)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result

def free_port():
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        return reservation.getsockname()[1]

def request(port, path, body=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(f'http://127.0.0.1:{port}'+path,
                                  data=None if body is None else json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)

def healthy(port):
    for _ in range(100):
        try:
            if request(port, '/healthz')['status'] == 'ok':
                return
        except (OSError, urllib.error.URLError):
            time.sleep(0.1)
    raise TimeoutError('isolated container did not become healthy')

port = free_port()
args.output.parent.mkdir(parents=True, exist_ok=True)
try:
    docker('volume', 'create', volume)
    docker('run', '-d', '--name', container, '--read-only', '--cap-drop=ALL',
           '--security-opt=no-new-privileges', '--pids-limit=64', '--cpus=1', '--memory=1g',
           '-p', f'127.0.0.1:{port}:8787', '--mount', f'type=volume,src={volume},dst=/data', args.image)
    healthy(port)
    info = json.loads(docker('inspect', '--format', '{{json .Config.User}}', container).stdout)
    assert info == '65532:65532', info
    with tempfile.TemporaryDirectory(prefix='haoxiguan-container-invite-') as temporary:
        invitation = Path(temporary)/'invite.json'
        docker('exec', container, '/haoxiguan-server', 'create-user', '--db', '/data/haoxiguan.sqlite',
               '--name', 'synthetic-container', '--out', '/data/invite.json')
        docker('cp', container+':/data/invite.json', str(invitation))
        invitation.chmod(0o600)
        account = json.loads(invitation.read_text())
        tokens = request(port, '/v1/auth/enroll', {'invite': account['invite'], 'deviceName': 'synthetic test'})
        cipher = base64.b64encode(b'public-opaque-container-storage-fixture'*3).decode()
        result = request(port, '/v1/push', {'epoch': tokens['epoch'], 'operations': [{
            'opId': 'operation_container_0000001', 'entityId': 'entity_container_00000001',
            'baseRevision': 0, 'ciphertext': cipher, 'deleted': False}]}, tokens['accessToken'])
        assert result['results'][0]['revision'] == 1
        docker('stop', '--time', '15', container)
        docker('run', '--rm', '--read-only', '--cap-drop=ALL', '--mount', f'type=volume,src={volume},dst=/data',
               args.image, 'backup', '--db', '/data/haoxiguan.sqlite', '--out', '/data/backup.sqlite')
        docker('start', container)
        healthy(port)
        page = request(port, '/v1/pull?epoch='+tokens['epoch'], token=tokens['accessToken'])
        assert page['objects'][0]['ciphertext'] == cipher
        idle = docker('stats', '--no-stream', '--format', '{{.MemUsage}}', container).stdout.strip()
        docker('stop', '--time', '15', container)
        docker('rm', container)
        docker('run', '--rm', '--read-only', '--cap-drop=ALL', '--mount', f'type=volume,src={volume},dst=/data',
               args.image, 'rotate-epoch', '--db', '/data/backup.sqlite')
        docker('run', '-d', '--name', container, '--read-only', '--cap-drop=ALL',
               '--security-opt=no-new-privileges', '--cpus=1', '--memory=1g',
               '-p', f'127.0.0.1:{port}:8787', '--mount', f'type=volume,src={volume},dst=/data',
               args.image, 'serve', '--db', '/data/backup.sqlite', '--listen', '0.0.0.0:8787')
        healthy(port)
        try:
            request(port, '/v1/devices', token=tokens['accessToken'])
            raise AssertionError('restored server accepted obsolete authorization')
        except urllib.error.HTTPError as error:
            assert error.code == 401
        docker('exec', container, '/haoxiguan-server', 'invite', '--db', '/data/backup.sqlite',
               '--user', account['userId'], '--out', '/data/restored-invite.json')
        docker('cp', container+':/data/restored-invite.json', str(invitation))
        invite = json.loads(invitation.read_text())['invite']
        fresh = request(port, '/v1/auth/enroll', {'invite': invite, 'deviceName': 'reauthorized restore test'})
        assert fresh['epoch'] != tokens['epoch']
        page = request(port, '/v1/bootstrap?epoch='+fresh['epoch'], token=fresh['accessToken'])
        assert page['objects'][0]['ciphertext'] == cipher
        report = {'status': 'passed', 'uid': info, 'cpuLimit': 1, 'memoryLimitGiB': 1,
                  'readOnlyRoot': True, 'persistentRestart': True, 'consistentBackupRestore': True,
                  'restoredCredentialsRevoked': True, 'opaqueObjectPreserved': True,
                  'idleMemoryOnlyNotLoadBenchmark': idle}
        args.output.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report))
finally:
    docker('rm', '-f', container, check=False)
    docker('volume', 'rm', volume, check=False)
