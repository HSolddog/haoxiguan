"""Run targeted Dart tests against a disposable official Nextcloud over TLS.

This runner requires Linux CI, Docker, Go and an already provisioned Flutter SDK.
It uses public synthetic credentials, a random container and an anonymous volume.
Both the container HTTP port and the Python TLS proxy bind IPv4 loopback only.
The generated CA is trusted by individual test clients, never the system store.
No host data directory is mounted, and no TLS key is retained in the artifacts.
"""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
IMAGE = 'nextcloud:33.0.9-apache'
VERSION = '33.0.9'
USER = 'testuser'
PASSWORD = 'public-synthetic-test-password'
OWNER_LABEL = 'org.haoxiguan.nextcloud-integration'
TEST_FILES = ['test/webdav_integration_test.dart', 'test/nextcloud_integration_test.dart']
OFFICIAL_IMAGE_SOURCES = {
    'officialImages': 'https://github.com/docker-library/official-images/blob/master/library/nextcloud',
    'imageSource': 'https://github.com/nextcloud/docker/tree/a1206d2467689ecb8597b7e5b753b49dda29b773/33/apache',
    'imageSourceCommit': 'a1206d2467689ecb8597b7e5b753b49dda29b773',
}
MAX_PROXY_BYTES = 70 * 1024 * 1024
HOP_HEADERS = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
               'te', 'trailer', 'transfer-encoding', 'upgrade'}


class RunnerFailure(RuntimeError):
    """Contains only an intentionally safe diagnostic, never command output."""


def redact(value, private_paths=()):
    text = str(value)
    for path in sorted((str(p) for p in private_paths if p), key=len, reverse=True):
        text = text.replace(path, '<private-path>')
        text = text.replace(path.replace('\\', '/'), '<private-path>')
    text = text.replace(PASSWORD, '<synthetic-password>')
    text = re.sub(r'(?im)^.*(?:authorization|set-cookie|cookie)\s*[:=].*$',
                  '<redacted-header>', text)
    text = re.sub(r'(?i)\b(?:basic|bearer)\s+[a-z0-9+/=._-]+', '<redacted-auth>', text)
    text = re.sub(r'(?i)[a-z]:[\\/](?:users|documents and settings)[\\/][^\s"\x27<>]+',
                  '<private-path>', text)
    return re.sub(r'/(?:home|Users)/[^\s"\x27<>]+', '<private-path>', text)


def source_evidence():
    commit = subprocess.run(
        ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'rev-parse', 'HEAD'],
        cwd=ROOT, capture_output=True, text=True, timeout=15, check=False,
    )
    if commit.returncode != 0 or not re.fullmatch(r'[0-9a-f]{40}', commit.stdout.strip()):
        raise RunnerFailure('source commit could not be recorded')
    files = set()
    for folder, suffixes in [('lib', {'.dart'}), ('test', {'.dart'}),
                             ('tools', {'.py', '.go', '.dart'})]:
        files.update(p for p in (ROOT / folder).rglob('*')
                     if p.is_file() and p.suffix in suffixes)
    files.update(ROOT / name for name in ['pubspec.yaml', 'pubspec.lock']
                 if (ROOT / name).is_file())
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(files)}
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True,
                                      separators=(',', ':')).encode()).hexdigest()
    return commit.stdout.strip(), digest, hashes


def command(args, *, timeout, stage, output=None, private_paths=(), env=None):
    try:
        result = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                encoding='utf-8', errors='replace',
                                timeout=timeout, env=env, check=False)
    except subprocess.TimeoutExpired as error:
        if output is not None:
            value = error.stdout or ''
            if isinstance(value, bytes):
                value = value.decode('utf-8', errors='replace')
            output.write_text(redact(value, private_paths), encoding='utf-8')
        raise RunnerFailure(f'{stage} exceeded its {timeout:g}s timeout') from None
    except OSError:
        raise RunnerFailure(f'{stage} executable could not be started') from None
    if output is not None:
        output.write_text(redact(result.stdout, private_paths), encoding='utf-8')
    if result.returncode != 0:
        raise RunnerFailure(f'{stage} failed with exit code {result.returncode}')
    return result.stdout


class TlsProxyHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        # Base handler logging includes request paths; retain method/status only.
        pass

    def forward(self):
        status = 502
        connection = None
        response_encoded = False
        response_gzip_etag = False
        response_strong_etag = False
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if (length < 0 or length > MAX_PROXY_BYTES
                    or self.headers.get('Transfer-Encoding') is not None
                    or not self.path.startswith('/') or self.path.startswith('//')):
                status = 400
                self.send_error(status, 'invalid isolated test request')
                return
            body = self.rfile.read(length)
            if len(body) != length:
                raise OSError('incomplete request')
            headers = {key: value for key, value in self.headers.items()
                       if key.lower() not in HOP_HEADERS}
            headers['Connection'] = 'close'
            connection = http.client.HTTPConnection('127.0.0.1', self.server.upstream_port,
                                                    timeout=15)
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            # Boolean representation diagnostics only: never retain headers,
            # credentials, ETag values or request URIs in the proxy evidence.
            encoding = response.getheader('Content-Encoding', '').strip().lower()
            tag = response.getheader('ETag', '')
            response_encoded = encoding not in {'', 'identity'}
            response_gzip_etag = tag.endswith('-gzip"')
            response_strong_etag = bool(re.fullmatch(r'"[\x21\x23-\x7e\x80-\xff]*"', tag))
            payload = response.read(MAX_PROXY_BYTES + 1)
            if len(payload) > MAX_PROXY_BYTES:
                raise OSError('oversized response')
            status = response.status
            self.send_response(status)
            for key, value in response.getheaders():
                if key.lower() not in HOP_HEADERS | {'content-length', 'server', 'date'}:
                    self.send_header(key, value)
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Connection', 'close')
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(payload)
        except (OSError, ValueError, http.client.HTTPException):
            # Never emit exception details: they may contain a request/header.
            self.send_error(502, 'isolated test upstream unavailable')
        finally:
            if connection is not None:
                connection.close()
            self.close_connection = True
            with self.server.log_lock:
                self.server.event_log.write(json.dumps({'method': self.command,
                    'status': status,
                    'probe': self.path.endswith('.probe'),
                    'requestBytes': length if 'length' in locals() else None,
                    'conditionalCreate': self.headers.get('If-None-Match') == '*',
                    'conditionalDelete': self.command == 'DELETE' and
                                         self.headers.get('If-Match') is not None,
                    'responseContentEncoded': response_encoded,
                    'responseEtagHasGzipSuffix': response_gzip_etag,
                    'responseStrongEtag': response_strong_etag,
                }) + '\n')
                self.server.event_log.flush()

    do_GET = do_HEAD = do_OPTIONS = do_PROPFIND = forward
    do_MKCOL = do_PUT = do_DELETE = forward


class TlsProxyServer(ThreadingHTTPServer):
    daemon_threads = True

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(15)
        # Defer TLS negotiation to the bounded worker, keeping accept/shutdown
        # responsive even when an untrusted client abandons the handshake.
        return self.tls_context.wrap_socket(sock, server_side=True,
                                            do_handshake_on_connect=False), address


def start_proxy(cert, key, event_log):
    server = TlsProxyServer(('127.0.0.1', 0), TlsProxyHandler)
    server.daemon_threads = True
    server.upstream_port = 0
    server.log_lock = threading.Lock()
    server.event_log = event_log
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(cert), str(key))
    server.tls_context = context
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


@contextmanager
def proxy_service(cert, key, log_file):
    with log_file.open('w', encoding='utf-8') as log:
        server, thread = start_proxy(cert, key, log)
        try:
            yield server
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


def loopback_opener(cert=None):
    handlers = [urllib.request.ProxyHandler({})]
    if cert is not None:
        handlers.append(urllib.request.HTTPSHandler(
            context=ssl.create_default_context(cafile=str(cert))))
    return urllib.request.build_opener(*handlers)


def wait_ready(port, endpoint, cert, timeout):
    deadline = time.monotonic() + timeout
    backend = loopback_opener()
    tls = loopback_opener(cert)
    authorization = base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
    while time.monotonic() < deadline:
        try:
            with backend.open(f'http://127.0.0.1:{port}/status.php', timeout=2) as response:
                status = json.loads(response.read(4096))
            if status.get('installed') is True and not status.get('maintenance'):
                request = urllib.request.Request(
                    endpoint, method='PROPFIND', headers={
                        'Authorization': f'Basic {authorization}', 'Depth': '0'})
                with tls.open(request, timeout=2) as response:
                    if response.status == 207:
                        return
        except (OSError, ValueError):
            pass
        time.sleep(0.5)
    raise RunnerFailure(f'isolated Nextcloud readiness exceeded its {timeout:g}s timeout')


def immutable_image(docker, output, timeout, private_paths):
    command([docker, 'pull', IMAGE], timeout=timeout, stage='official image pull',
            output=output / 'docker-pull.log', private_paths=private_paths)
    raw = command([docker, 'image', 'inspect', IMAGE], timeout=30,
                  stage='official image inspect')
    try:
        inspected = json.loads(raw)[0]
        digests = sorted(d for d in inspected['RepoDigests'] if re.fullmatch(
            r'(?:docker\.io/library/)?nextcloud@sha256:[0-9a-f]{64}', d))
        if not digests or not re.fullmatch(r'sha256:[0-9a-f]{64}', inspected['Id']):
            raise ValueError('missing immutable image identity')
        return {'tag': IMAGE, 'digest': digests[0], 'imageId': inspected['Id'],
                'architecture': inspected['Architecture'], 'os': inspected['Os']}
    except (ValueError, KeyError, IndexError, TypeError):
        raise RunnerFailure('pulled official image has no valid immutable identity') from None


def cleanup_container(docker, name, owner, output, private_paths=()):
    present = command([docker, 'container', 'ls', '--all', '--no-trunc',
                       '--filter', f'label={OWNER_LABEL}={owner}',
                       '--filter', f'name=^/{name}$', '--format', '{{.ID}}'],
                      timeout=15, stage='cleanup owned-container lookup').strip()
    if not present:
        return 'no-owned-container-remains'
    raw = command([docker, 'inspect', name], timeout=15, stage='cleanup ownership inspect')
    try:
        inspected = json.loads(raw)[0]
        if inspected['Config']['Labels'].get(OWNER_LABEL) != owner:
            raise ValueError('unowned container')
        container_id = inspected['Id']
        if not re.fullmatch(r'[0-9a-f]{64}', container_id):
            raise ValueError('invalid container id')
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        raise RunnerFailure('cleanup refused: container ownership did not match this run') from None
    command([docker, 'rm', '--force', '--volumes', container_id], timeout=30,
            stage='owned container and anonymous volume cleanup',
            output=output / 'cleanup.log', private_paths=private_paths)
    return 'owned-container-and-anonymous-volumes-removed'


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    owner = uuid.uuid4().hex
    name = f'haoxiguan-nextcloud-{owner}'
    report = {
        'startedAtUtc': datetime.now(timezone.utc).isoformat(),
        'service': {'tag': IMAGE, 'expectedVersion': VERSION, **OFFICIAL_IMAGE_SOURCES},
        'listen': 'IPv4 loopback only',
        'tls': 'generated certificate trusted by test clients only',
        'storage': 'disposable anonymous Docker volume; no host data mount',
        'testFiles': TEST_FILES, 'testExecuted': False, 'result': 'starting',
        'cleanup': 'not-needed',
        'timeoutsSeconds': {'pull': args.pull_timeout, 'startup': args.startup_timeout,
                            'tests': args.test_timeout, 'certificate': 60},
    }
    private_paths = [ROOT, output, os.environ.get('HOME'), os.environ.get('USERPROFILE')]
    container_creation_attempted = False
    exit_code = 1
    try:
        commit, digest, hashes = source_evidence()
        report.update(sourceCommit=commit, sourceSha256=digest)
        (output / 'source-files.json').write_text(
            json.dumps(hashes, indent=2) + '\n', encoding='utf-8')
        if sys.platform != 'linux':
            raise RunnerFailure('Nextcloud container integration requires disposable Linux CI')
        if not args.docker or not args.go or not args.flutter:
            raise RunnerFailure('Docker, Go and Flutter executables are required')
        image = immutable_image(args.docker, output, args.pull_timeout, private_paths)
        report['service'].update(image)
        with tempfile.TemporaryDirectory(prefix='haoxiguan-nextcloud-e2e-') as temp_name:
            private_paths.append(temp_name)
            directory = Path(temp_name)
            cert, key = directory / 'cert.pem', directory / 'key.pem'
            command([args.go, 'run', str(ROOT / 'tools' / 'sync_test_certificate.go'),
                     str(cert), str(key)], timeout=60, stage='test certificate generation',
                    output=output / 'certificate.log', private_paths=private_paths)
            key.chmod(0o600)
            with proxy_service(cert, key, output / 'proxy.log') as proxy:
                tls_port = proxy.server_address[1]
                endpoint = f'https://127.0.0.1:{tls_port}/remote.php/dav/files/{USER}/'
                # Register ownership before starting, so partial startup failures are cleaned up.
                container_creation_attempted = True
                command([args.docker, 'create', '--name', name,
                         '--label', f'{OWNER_LABEL}={owner}',
                         '--publish', '127.0.0.1::80',
                         '--env', f'NEXTCLOUD_ADMIN_USER={USER}',
                         '--env', f'NEXTCLOUD_ADMIN_PASSWORD={PASSWORD}',
                         '--env', 'SQLITE_DATABASE=nextcloud',
                         '--env', 'NEXTCLOUD_TRUSTED_DOMAINS=127.0.0.1',
                         '--env', f'OVERWRITEHOST=127.0.0.1:{tls_port}',
                         '--env', 'OVERWRITEPROTOCOL=https', image['digest']],
                        timeout=60, stage='isolated container creation',
                        output=output / 'container-create.log', private_paths=private_paths)
                command([args.docker, 'start', name], timeout=30,
                        stage='isolated container start')
                binding = command([args.docker, 'port', name, '80/tcp'], timeout=15,
                                  stage='loopback port inspection').strip()
                if not re.fullmatch(r'127\.0\.0\.1:[0-9]{1,5}', binding):
                    raise RunnerFailure('isolated container port was not exclusively IPv4 loopback')
                proxy.upstream_port = int(binding.rsplit(':', 1)[1])
                wait_ready(proxy.upstream_port, endpoint, cert, args.startup_timeout)
                status_raw = command([args.docker, 'exec', '--user', 'www-data', name,
                                      'php', 'occ', 'status', '--output=json'], timeout=30,
                                     stage='installed Nextcloud version inspection')
                try:
                    status = json.loads(status_raw)
                    if status['installed'] is not True or status['versionstring'] != VERSION:
                        raise ValueError('unexpected version')
                except (ValueError, KeyError, TypeError):
                    raise RunnerFailure('installed Nextcloud version differs from the pinned version') from None
                report['service']['actualVersion'] = status['versionstring']
                (output / 'service.json').write_text(
                    json.dumps(report['service'], indent=2) + '\n', encoding='utf-8')
                evidence = output / 'sqlite-evidence'
                evidence.mkdir(exist_ok=True)
                environment = os.environ.copy()
                environment.update(HAOXIGUAN_NEXTCLOUD_EVIDENCE=str(evidence),
                                   NO_PROXY='127.0.0.1,localhost',
                                   no_proxy='127.0.0.1,localhost')
                report['testExecuted'] = True
                command([args.flutter, 'test', '--no-pub', '--reporter=expanded',
                         *TEST_FILES, f'--dart-define=TEST_DAV_ENDPOINT={endpoint}',
                         f'--dart-define=TEST_DAV_CERT={cert}',
                         f'--dart-define=TEST_DAV_USER={USER}',
                         f'--dart-define=TEST_DAV_PASSWORD={PASSWORD}'],
                        timeout=args.test_timeout, stage='targeted Nextcloud Dart tests',
                        output=output / 'test.log', private_paths=private_paths, env=environment)
                report['result'] = 'passed'
                exit_code = 0
    except RunnerFailure as error:
        report.update(result='failed', error=str(error))
    except Exception as error:
        # Unexpected messages may carry private paths, headers, or credentials.
        report.update(result='failed', error=f'{type(error).__name__}: isolated runner failed')
    finally:
        if container_creation_attempted:
            try:
                command([args.docker, 'logs', name], timeout=15, stage='container log capture',
                        output=output / 'nextcloud.log', private_paths=private_paths)
            except RunnerFailure as error:
                report['logCaptureError'] = str(error)
            try:
                report['cleanup'] = cleanup_container(
                    args.docker, name, owner, output, private_paths)
            except RunnerFailure as error:
                report.update(result='failed', cleanup='failed', cleanupError=str(error))
                exit_code = 1
        report['exitCode'] = exit_code
        report['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
        (output / 'results.json').write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ['result', 'testExecuted', 'cleanup', 'exitCode']}),
          flush=True)
    return exit_code


def bounded_timeout(value):
    number = float(value)
    if not 1 <= number <= 900:
        raise argparse.ArgumentTypeError('timeout must be between 1 and 900 seconds')
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docker', default=shutil.which('docker'))
    parser.add_argument('--go', default=shutil.which('go'))
    parser.add_argument('--flutter', default=shutil.which('flutter'))
    parser.add_argument('--output', type=Path, default=ROOT / 'build' / 'nextcloud-integration')
    parser.add_argument('--pull-timeout', type=bounded_timeout, default=300)
    parser.add_argument('--startup-timeout', type=bounded_timeout, default=300)
    parser.add_argument('--test-timeout', type=bounded_timeout, default=600)
    return run(parser.parse_args())


if __name__ == '__main__':
    sys.exit(main())
