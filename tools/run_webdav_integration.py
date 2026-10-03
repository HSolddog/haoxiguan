"""Run the existing Dart WebDAV integration against disposable WsgiDAV TLS.

Only a generated temporary directory is served, on IPv4 loopback. The public
synthetic credentials below are not user credentials. The generated certificate
is trusted by individual test clients; the system certificate store is untouched.
Artifacts contain logs/results only, never the generated TLS private key.
"""
import argparse
import base64
from datetime import datetime, timezone
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
USER = 'testuser'
PASSWORD = 'public-synthetic-test-password'


def serve(directory, port, cert, key):
    from cheroot import wsgi
    from cheroot.ssl.builtin import BuiltinSSLAdapter
    from wsgidav.wsgidav_app import WsgiDAVApp

    app = WsgiDAVApp({
        'provider_mapping': {'/': str(directory)},
        'http_authenticator': {
            'domain_controller': None,
            'accept_basic': True,
            'accept_digest': False,
            'default_to_digest': False,
        },
        'simple_dc': {
            'user_mapping': {'*': {USER: {'password': PASSWORD}}},
        },
        'verbose': 1,
        'logging': {'enable': True},
    })
    server = wsgi.Server(('127.0.0.1', port), app, numthreads=5)
    server.ssl_adapter = BuiltinSSLAdapter(str(cert), str(key))
    try:
        server.start()
    finally:
        server.stop()


def wait_ready(process, endpoint, cert):
    context = ssl.create_default_context(cafile=str(cert))
    authorization = base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
    # Proxy variables must not route this temporary loopback request elsewhere.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('isolated WsgiDAV exited before readiness')
        try:
            request = urllib.request.Request(
                endpoint,
                method='PROPFIND',
                headers={'Authorization': f'Basic {authorization}', 'Depth': '0'},
            )
            with opener.open(request, timeout=2) as response:
                if response.status == 207:
                    return
        except OSError:
            time.sleep(0.2)
    raise TimeoutError('isolated HTTPS WebDAV did not become ready')


def run(args):
    if not args.go or not args.flutter:
        raise RuntimeError('Go and Flutter executables are required')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    versions = {
        name: importlib.metadata.version(name) for name in ('WsgiDAV', 'cheroot')
    }
    if versions != {'WsgiDAV': '4.3.3', 'cheroot': '11.1.2'}:
        raise RuntimeError('install the pinned tools/webdav-test-requirements.txt')
    report = {
        'startedAtUtc': datetime.now(timezone.utc).isoformat(),
        'sourceCommit': subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True,
        ).strip(),
        'service': versions,
        'listen': 'IPv4 loopback only',
        'tls': 'generated certificate trusted by test clients only',
        'testFile': 'test/webdav_integration_test.dart',
        'testExecuted': False,
        'result': 'starting',
    }
    try:
        with tempfile.TemporaryDirectory(prefix='haoxiguan-webdav-e2e-') as name:
            directory = Path(name)
            storage = directory / 'storage'
            storage.mkdir()
            cert, key = directory / 'cert.pem', directory / 'key.pem'
            subprocess.run(
                [args.go, 'run', str(ROOT / 'tools' / 'sync_test_certificate.go'),
                 str(cert), str(key)], check=True, cwd=ROOT, timeout=60,
            )
            if os.name != 'nt':
                key.chmod(0o600)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            endpoint = f'https://127.0.0.1:{port}/'
            with (output / 'server.log').open('wb') as log:
                process = subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()),
                     '--serve', str(storage), '--port', str(port),
                     '--cert', str(cert), '--key', str(key)],
                    cwd=directory, stdout=log, stderr=log,
                )
                try:
                    wait_ready(process, endpoint, cert)
                    report['testExecuted'] = True
                    result = subprocess.run(
                        [args.flutter, 'test', '--no-pub', '--reporter=expanded',
                         'test/webdav_integration_test.dart',
                         f'--dart-define=TEST_DAV_ENDPOINT={endpoint}',
                         f'--dart-define=TEST_DAV_CERT={cert}'],
                        cwd=ROOT, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True,
                        encoding='utf-8', errors='replace', timeout=300,
                    )
                    (output / 'test.log').write_text(result.stdout, encoding='utf-8')
                    print(result.stdout, end='', flush=True)
                    report['exitCode'] = result.returncode
                    report['result'] = 'passed' if result.returncode == 0 else 'failed'
                    return result.returncode
                finally:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
    except Exception as error:
        report['result'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        report['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
        (output / 'results.json').write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8',
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go', default=shutil.which('go'))
    parser.add_argument('--flutter', default=shutil.which('flutter'))
    parser.add_argument('--output', type=Path, default=ROOT / 'build' / 'webdav-integration')
    parser.add_argument('--serve', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--port', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--cert', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--key', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve is not None:
        serve(args.serve, args.port, args.cert, args.key)
        return 0
    return run(args)


if __name__ == '__main__':
    sys.exit(main())
