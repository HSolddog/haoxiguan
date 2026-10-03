"""C07: disposable real HTTPS load, abrupt restart and consistent restore.

Linux CI only. Uses the pinned local Docker socket, an already-built image and
the existing synthetic certificate generator. Never accepts an external URL.
Only resources with this run's random names are removed. No credentials, data
files or private keys are copied into the report/artifact directory.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlencode
import uuid


USERS, DEVICES, RECORDS, BATCH = 20, 3, 5000, 100
DB = '/data/haoxiguan.sqlite'
SNAPSHOT = '/data/snapshot.sqlite'
SOCKET = '/var/run/docker.sock'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ciphertext(user, index, revision=1):
    marker = f'synthetic:{user}:{index}:{revision}'.encode()
    return base64.b64encode(marker.ljust(1024, b'\0')).decode()


def operation(user, index, revision=1):
    return {'opId': f'capacity_operation_{user:03}_{index:06}_{revision}',
            'entityId': f'capacity_entity_{user:03}_{index:06}',
            'baseRevision': revision - 1,
            'ciphertext': ciphertext(user, index, revision),
            'deleted': revision == 3}


def summary(values):
    values = sorted(values)
    if not values:
        return {'samples': 0}
    return {'samples': len(values), 'p50Ms': round(values[int((len(values)-1)*.5)], 3),
            'p95Ms': round(values[int((len(values)-1)*.95)], 3),
            'maxMs': round(values[-1], 3)}


class LocalDockerConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__('localhost', timeout=15)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCKET)


class Harness:
    def __init__(self, image, output, temporary):
        self.image, self.output, self.temporary = image, output, temporary
        self.prefix = 'haoxiguan-https-capacity-' + uuid.uuid4().hex[:12]
        self.container = self.prefix + '-server'
        self.maintenance = self.prefix + '-maintenance'
        self.volume, self.network = self.prefix + '-data', self.prefix + '-net'
        self.env = os.environ.copy()
        for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS',
                    'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
            self.env.pop(key, None)
        self.started = time.monotonic()
        self.deadline = self.started + 25*60
        self.port = None
        self.db = DB
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.fault_window = threading.Event()
        self.restart_complete = threading.Event()
        self.first_update = threading.Event()
        self.metrics, self.samples = {}, []
        self.report = {
            'status': 'running', 'sourceCommit': os.environ.get('GITHUB_SHA', ''),
            'mode': 'real Go executable, HTTPS over isolated Docker bridge and loopback published port',
            'users': USERS, 'devicesPerUser': DEVICES, 'initialObjectsTotal': USERS*RECORDS,
            'ciphertextBytesPerObject': 1024, 'pushConcurrency': USERS,
            'bootstrapConcurrency': USERS*DEVICES, 'pushBatchSize': BATCH, 'pullPageSize': 200,
            'cpuLimit': 1, 'memoryLimitGiB': 1, 'readOnlyRoot': True,
            'user': '65532:65532', 'tlsCertificateAndHostnameVerified': True,
            'clientOutsideServerResourceLimit': True,
            'rateLimitsUnchanged': True, 'forwardedIPHeadersSent': False,
            'limits': ['synthetic opaque payloads; excludes client encryption/decryption',
                       'one shared source IP; no WAN latency or bandwidth simulation',
                       'sampled Docker memory includes page cache, not exact peak RSS',
                       'x86_64 CI observations are not ARM64 or production capacity promises',
                       'latencies are observations, without an invented pass threshold'],
            'phases': {}, 'diskBytes': {}, 'verification': {}}

    def docker(self, *args, check=True, timeout=90):
        result = subprocess.run(['docker', '--host=unix://' + SOCKET, *args],
                                env=self.env, capture_output=True, text=True,
                                timeout=timeout, check=False)
        if check and result.returncode:
            # Docker arguments contain paths and synthetic display names, never tokens.
            raise RuntimeError('Docker operation failed: ' + result.stderr.strip())
        return result

    def engine(self, method, path):
        connection = LocalDockerConnection()
        try:
            connection.request(method, path)
            response = connection.getresponse()
            body = response.read()
            return response.status, dict(response.getheaders()), body
        finally:
            connection.close()

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0 and not self.stop.is_set(), 'capacity run deadline/cancellation')
        return remaining

    def wait(self, seconds):
        require(seconds <= self.remaining(), 'retry would exceed capacity run deadline')
        require(not self.stop.wait(seconds), 'capacity run cancelled')

    def metric(self, phase, status, attempt_ms, total_ms=None):
        with self.lock:
            metric = self.metrics.setdefault(phase, {'httpStatuses': {}, 'attemptMs': [],
                                                    'successMs': [], 'logicalMs': []})
            metric['httpStatuses'][str(status)] = metric['httpStatuses'].get(str(status), 0) + 1
            metric['attemptMs'].append(attempt_ms)
            if total_ms is not None:
                metric['successMs'].append(attempt_ms)
                metric['logicalMs'].append(total_ms)

    def request(self, phase, path, body=None, device=None):
        began = time.monotonic()
        payload = None if body is None else json.dumps(body, separators=(',', ':')).encode()
        for attempt in range(24):
            require(time.monotonic()-began < 480, 'request exceeded bounded retry duration')
            headers = {'Content-Type': 'application/json'}
            if device is not None:
                if time.time() > device['accessExpiresAt'] - 120:
                    if self.fault_window.is_set():
                        # Refresh tokens are single-use. Never start a rotation
                        # whose response could be lost at the intentional crash.
                        require(time.time() < device['accessExpiresAt'] - 30,
                                'prepared fault credentials approached expiry')
                    else:
                        fresh = self.request('refresh', '/v1/auth/refresh',
                                             {'refreshToken': device['refreshToken']})
                        device.update(fresh)
                headers['Authorization'] = 'Bearer ' + device['accessToken']
            connection = http.client.HTTPSConnection(
                '127.0.0.1', self.port, context=self.tls, timeout=min(65, self.remaining()))
            started = time.monotonic()
            try:
                connection.request('GET' if payload is None else 'POST', path, payload, headers)
                response = connection.getresponse()
                raw = response.read()
                elapsed = (time.monotonic()-started)*1000
                if response.status == 429:
                    self.metric(phase, 429, elapsed)
                    delay = float(response.getheader('Retry-After', '30'))
                    require(0 < delay <= 60, 'unexpected Retry-After bound')
                    self.wait(delay)
                    continue
                require(200 <= response.status < 300,
                        f'{phase} unexpected HTTP status {response.status}')
                self.metric(phase, response.status, elapsed, (time.monotonic()-began)*1000)
                return json.loads(raw)
            except ssl.SSLCertVerificationError:
                raise
            except (OSError, http.client.HTTPException):
                self.metric(phase, 'transport_error', (time.monotonic()-started)*1000)
                if not self.fault_window.is_set() or path.startswith('/v1/auth/'):
                    raise
                self.wait(min(1 + attempt, 5))
            finally:
                connection.close()
        raise RuntimeError('bounded request retries exhausted')

    def healthy(self):
        for _ in range(60):
            try:
                result = self.request('health', '/healthz')
                require(result.get('status') == 'ok', 'invalid health response')
                return
            except (OSError, http.client.HTTPException):
                self.wait(.25)
        raise RuntimeError('isolated HTTPS service failed to become healthy')

    def common(self):
        return ['--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
                '--pids-limit=128', '--cpus=1', '--memory=1g', '--memory-swap=1g',
                '--env', 'GOMEMLIMIT=384MiB', '--env', 'TMPDIR=/data',
                '--mount', f'type=volume,src={self.volume},dst=/data']

    def start_server(self):
        self.docker('run', '-d', '--name', self.container, *self.common(),
                    '--network', self.network, '-p', '127.0.0.1::8787',
                    '--mount', f'type=bind,src={self.temporary / "certificate.pem"},dst=/certificate.pem,readonly',
                    '--mount', f'type=bind,src={self.temporary / "key.pem"},dst=/key.pem,readonly',
                    self.image, 'serve', '--db', self.db, '--listen', '0.0.0.0:8787',
                    '--tls-cert', '/certificate.pem', '--tls-key', '/key.pem')
        self.port = int(self.docker('port', self.container, '8787/tcp').stdout.strip().rsplit(':', 1)[1])
        config = json.loads(self.docker('inspect', self.container).stdout)[0]
        require(config['Config']['User'] == '65532:65532', 'unexpected server container UID')
        require(config['HostConfig']['Memory'] == 1024**3, 'memory limit not applied')
        require(config['HostConfig']['NanoCpus'] == 10**9, 'CPU limit not applied')
        self.healthy()

    def issue_invite(self, user=None, index=0):
        destination = f'/data/invite-{uuid.uuid4().hex}.json'
        command = ['create-user', '--name', f'synthetic-capacity-{index}'] if user is None else ['invite', '--user', user]
        self.docker('exec', self.container, '/haoxiguan-server', *command,
                    '--db', self.db, '--out', destination)
        local = self.temporary / 'invite.json'
        self.docker('cp', self.container + ':' + destination, str(local))
        local.chmod(0o600)
        result = json.loads(local.read_text())
        local.unlink()
        return result

    def disk(self, phase):
        sizes = {}
        for path in (DB, DB+'-wal', DB+'-shm', SNAPSHOT, SNAPSHOT+'-wal'):
            status, headers, _ = self.engine('HEAD', '/containers/' + self.container + '/archive?' + urlencode({'path': path}))
            if status == 404:
                sizes[path] = 0
            else:
                require(status == 200, 'Docker file-size diagnostic failed')
                lowered = {key.lower(): value for key, value in headers.items()}
                sizes[path] = json.loads(base64.b64decode(lowered['x-docker-container-path-stat']))['size']
        self.report['diskBytes'][phase] = sizes

    def sample(self, phase):
        status, _, raw = self.engine('GET', '/containers/' + self.container + '/stats?stream=false&one-shot=true')
        require(status == 200, 'Docker resource diagnostic failed')
        stats = json.loads(raw)
        value = {'phase': phase, 'elapsedSeconds': round(time.monotonic()-self.started, 3),
                 'memoryBytesIncludingPageCache': stats.get('memory_stats', {}).get('usage', 0),
                 'cpuUsageNs': stats.get('cpu_stats', {}).get('cpu_usage', {}).get('total_usage', 0)}
        with self.lock:
            self.samples.append(value)
        return value

    def observe(self):
        while not self.stop.wait(5):
            try:
                self.sample('periodic')
            except (OSError, http.client.HTTPException, RuntimeError):
                # Container transitions have explicit before/after samples below.
                pass

    def parallel(self, function, values, workers):
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(function, value) for value in values]
            try:
                return [future.result(timeout=self.remaining()) for future in futures]
            except BaseException:
                self.stop.set()
                raise

    def phase(self, name, action):
        print('capacity phase: ' + name, flush=True)
        self.report['currentPhase'] = name
        self.save()
        started = time.monotonic()
        result = action()
        self.report['phases'][name] = {'elapsedSeconds': round(time.monotonic()-started, 3)}
        self.disk(name)
        self.sample(name)
        self.save()
        return result

    def enroll(self):
        accounts = []
        for user in range(USERS):
            account = self.issue_invite(index=user)
            invites = [account['invite']]
            invites.extend(self.issue_invite(account['userId'])['invite'] for _ in range(DEVICES-1))
            accounts.append(invites)

        def enroll_user(item):
            user, invites = item
            return [self.request('enroll', '/v1/auth/enroll',
                                 {'invite': invite, 'deviceName': f'synthetic-{user}-{device}'})
                    for device, invite in enumerate(invites)]
        self.devices = self.parallel(enroll_user, list(enumerate(accounts)), USERS)

    def push(self, user, operations, phase):
        device = self.devices[user][0]
        result = self.request(phase, '/v1/push', {'epoch': device['epoch'], 'operations': operations}, device)
        expected = [(op['opId'], op['baseRevision']+1) for op in operations]
        received = [(op['opId'], op.get('revision')) for op in result['results'] if op['status'] == 'accepted']
        require(received == expected, 'write conflict, duplicate result or unexpected revision')

    def create_objects(self):
        def writer(user):
            for start in range(0, RECORDS, BATCH):
                self.push(user, [operation(user, i) for i in range(start, start+BATCH)], 'push')
        self.parallel(writer, range(USERS), USERS)

    def verify_device(self, item, changed=False, max_pages=None):
        user, device_index = item
        device = self.devices[user][device_index]
        cursor, high, count, pages = '', '', 0, 0
        expected_count = RECORDS + (110 if changed else 0)
        while True:
            query = urlencode({'epoch': device['epoch'], 'cursor': cursor, 'highWater': high, 'limit': 200})
            page = self.request('bootstrap' if not changed else 'recovered_bootstrap', '/v1/bootstrap?' + query, device=device)
            for obj in page['objects']:
                index = count if count < RECORDS else count-RECORDS if count < RECORDS+100 else count-RECORDS-100
                revision = 1 if count < RECORDS else 2 if count < RECORDS+100 else 3
                expected = operation(user, index, revision)
                require(count < expected_count and obj['entityId'] == expected['entityId']
                        and obj['revision'] == revision and obj['baseRevision'] == revision-1
                        and obj['ciphertext'] == expected['ciphertext'] and obj['deleted'] == expected['deleted']
                        and obj['encryptionEpoch'] == device['epoch'],
                        'lost, duplicated, reordered, corrupted or cross-account history')
                count += 1
            require(page['epoch'] == device['epoch'], 'unexpected server epoch')
            cursor, high, pages = page['cursor'], page['highWater'], pages+1
            if max_pages is not None and pages >= max_pages:
                return
            if not page['more']:
                break
        require(count == expected_count, 'incomplete bootstrap history')

    def interrupt_and_recover(self):
        # Each user's mutations are sequential. A known committed response for
        # user 0 is deliberately discarded; its exact opIds are replayed after
        # SIGKILL alongside interrupted peers. The report labels this injection.
        self.fault_window.set()

        def writer(user):
            for start in range(0, 100, 10):
                operations = [operation(user, i, 2) for i in range(start, start+10)]
                self.push(user, operations, 'concurrent_update')
                if user == 0 and start == 0:
                    self.first_update.set()
                    require(self.restart_complete.wait(90), 'restart did not complete')
                    self.push(user, operations, 'lost_response_replay')
            self.push(user, [operation(user, i, 3) for i in range(10)], 'concurrent_delete')

        with ThreadPoolExecutor(max_workers=USERS*2) as pool:
            futures = [pool.submit(writer, user) for user in range(USERS)]
            futures.extend(pool.submit(self.verify_device, (user, 1), False, 5) for user in range(USERS))
            try:
                require(self.first_update.wait(90), 'no mutation committed before interruption')
                active = sum(not future.done() for future in futures)
                require(active > 1, 'no concurrent load at interruption')
                self.sample('before_sigkill')
                began = time.monotonic()
                self.docker('kill', '--signal=KILL', self.container)
                exit_state = json.loads(self.docker('inspect', '--format', '{{json .State}}', self.container).stdout)
                require(exit_state['ExitCode'] == 137 and not exit_state['OOMKilled'], 'unexpected crash cause')
                self.docker('start', self.container)
                self.port = int(self.docker('port', self.container, '8787/tcp').stdout.strip().rsplit(':', 1)[1])
                self.healthy()
                self.report['verification']['abruptRestart'] = {
                    'signal': 'SIGKILL', 'count': 1, 'outstandingWorkers': active,
                    'recoverySeconds': round(time.monotonic()-began, 3),
                    'committedResponseDiscardedBeforeRestart': True}
                self.restart_complete.set()
                for future in futures:
                    future.result(timeout=self.remaining())
            except BaseException:
                self.stop.set()
                self.restart_complete.set()
                raise
            finally:
                self.fault_window.clear()

        # Replay acknowledged creations too: no extra change rows or revisions.
        for user in range(USERS):
            self.push(user, [operation(user, 0)], 'acknowledged_creation_replay')
        self.parallel(lambda item: self.verify_device(item, True),
                      [(user, 0) for user in range(USERS)], USERS)
        self.report['verification']['recoveredHistoryFullyVerified'] = True
        self.report['verification']['opIdReplayDidNotDuplicateChanges'] = True

    def prepare_fault_credentials(self):
        # Enroll/refresh deliberately retain their real per-IP rate limit. Rotate
        # before fault injection, since an ambiguous refresh must not be replayed.
        def refresh_user(user):
            for device in self.devices[user][:2]:
                device.update(self.request('refresh_before_fault', '/v1/auth/refresh',
                                           {'refreshToken': device['refreshToken']}))
        self.parallel(refresh_user, range(USERS), USERS)
        minimum = min(device['accessExpiresAt'] - time.time()
                      for group in self.devices for device in group[:2])
        require(minimum > 480, 'insufficient access lifetime for bounded interruption phase')
        self.report['verification']['faultCredentialMinimumLifetimeSeconds'] = round(minimum, 3)

    def backup_restore(self):
        self.docker('stop', '--time', '20', self.container)
        began = time.monotonic()
        self.docker('run', '--rm', '--name', self.maintenance, *self.common(), '--network=none',
                    self.image, 'backup', '--db', DB, '--out', SNAPSHOT, timeout=120)
        self.report['verification']['consistentBackupSeconds'] = round(time.monotonic()-began, 3)
        self.disk('consistent_backup')
        # Inspect only the completed consistent snapshot; never a copied live DB.
        local = self.temporary / 'snapshot.sqlite'
        self.docker('cp', self.container + ':' + SNAPSHOT, str(local), timeout=120)
        local.chmod(0o600)
        with sqlite3.connect(f'file:{local.as_posix()}?mode=ro', uri=True) as database:
            require(database.execute('PRAGMA quick_check').fetchall() == [('ok',)], 'snapshot integrity failed')
            counts = {table: database.execute('SELECT count(*) FROM '+table).fetchone()[0]
                      for table in ('objects', 'changes', 'operations', 'users', 'devices')}
        require(counts == {'objects': USERS*RECORDS, 'changes': USERS*(RECORDS+110),
                           'operations': USERS*(RECORDS+110), 'users': USERS, 'devices': USERS*DEVICES},
                'snapshot counts show lost or duplicate facts')
        local.unlink()
        self.report['verification']['snapshotQuickCheck'] = 'ok'
        self.report['verification']['snapshotCounts'] = counts
        self.docker('rm', self.container)
        self.db = SNAPSHOT
        self.start_server()
        self.parallel(lambda item: self.verify_device(item, True),
                      [(user, 0) for user in range(USERS)], USERS)
        self.report['verification']['restoredSnapshotHistoryFullyVerified'] = True
        self.report['verification']['restoreScope'] = 'isolated same-epoch backup reopen; production cross-machine/epoch rotation covered separately'

    def save(self):
        with self.lock:
            self.report['http'] = {
                phase: {'statuses': value['httpStatuses'].copy(),
                        'attemptLatency': summary(value['attemptMs']),
                        'successfulAttemptLatency': summary(value['successMs']),
                        'logicalRequestLatencyIncludingRetries': summary(value['logicalMs'])}
                for phase, value in self.metrics.items()}
            self.report['resourceSamples'] = list(self.samples)
            self.report['maxSampledMemoryBytesIncludingPageCache'] = max(
                (s['memoryBytesIncludingPageCache'] for s in self.samples), default=0)
        self.report['elapsedSeconds'] = round(time.monotonic()-self.started, 3)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(self.report, indent=2)+'\n')

    def run(self):
        observer = None
        try:
            image = json.loads(self.docker('image', 'inspect', self.image).stdout)[0]
            self.report['imageId'] = image['Id']
            self.report['architecture'] = image['Architecture']
            self.report['operatingSystem'] = image['Os']
            self.docker('volume', 'create', self.volume)
            self.docker('network', 'create', '--internal', self.network)
            network = json.loads(self.docker('network', 'inspect', self.network).stdout)[0]
            require(network['Internal'], 'test network must block external routing')
            self.report['dockerNetworkInternal'] = True
            certificate, key = self.temporary / 'certificate.pem', self.temporary / 'key.pem'
            subprocess.run(['go', 'run', str(Path(__file__).with_name('sync_test_certificate.go')),
                            str(certificate), str(key)], check=True, timeout=90, capture_output=True)
            # These one-day synthetic test materials are mounted as individual
            # files, readable by the unprivileged service, never uploaded.
            certificate.chmod(0o444)
            key.chmod(0o444)
            self.tls = ssl.create_default_context(cafile=str(certificate))
            self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
            self.start_server()
            self.report['idleResource'] = self.sample('idle_empty')
            self.disk('empty')
            observer = threading.Thread(target=self.observe, daemon=True)
            observer.start()
            self.phase('enroll_20_users_60_devices', self.enroll)
            self.phase('create_100000_objects', self.create_objects)
            self.phase('bootstrap_60_devices', lambda: self.parallel(
                self.verify_device, [(u, d) for u in range(USERS) for d in range(DEVICES)], USERS*DEVICES))
            self.report['verification']['all60BootstrapHistoriesFullyVerified'] = True
            self.phase('refresh_before_interruption', self.prepare_fault_credentials)
            self.phase('concurrent_update_delete_interruption_recovery', self.interrupt_and_recover)
            self.phase('consistent_backup_reopen', self.backup_restore)
            self.report['status'] = 'passed'
        except BaseException as error:
            self.report['status'] = 'failed'
            # Exception text intentionally excluded: no chance of credentials or
            # HTTP bodies reaching artifacts via a third-party exception message.
            self.report['failureType'] = type(error).__name__
            raise
        finally:
            self.stop.set()
            if observer is not None:
                observer.join(timeout=20)
            try:
                self.save()
            finally:
                for name in (self.container, self.maintenance):
                    self.docker('rm', '-f', name, check=False)
                self.docker('volume', 'rm', self.volume, check=False)
                self.docker('network', 'rm', self.network, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(os.name == 'posix' and Path(SOCKET).is_socket(), 'requires the local Linux Docker socket')
    with tempfile.TemporaryDirectory(prefix='haoxiguan-https-capacity-materials-') as temporary:
        Harness(args.image, args.output, Path(temporary)).run()


if __name__ == '__main__':
    main()
