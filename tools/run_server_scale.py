"""Run the explicitly compiled Go capacity test in a disposable 1 CPU/1 GiB container.
The input image must already exist; only this script's unique container/volume are removed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--image', required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
binary = args.binary.resolve()
assert binary.is_file() and binary.stat().st_mode & 0o005 == 0o005, 'test binary must be readable/executable by UID 65532'
environment = os.environ.copy()
for selector in ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH']:
    environment.pop(selector, None)

def docker(*values, check=True):
    result = subprocess.run(['docker', '--host=unix:///var/run/docker.sock', *values],
                            env=environment, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

prefix = 'haoxiguan-scale-' + uuid.uuid4().hex[:12]
container, volume = prefix+'-test', prefix+'-data'
docker('image', 'inspect', args.image)
try:
    docker('volume', 'create', volume)
    docker('create', '--name', container, '--read-only', '--network=none', '--cap-drop=ALL',
           '--security-opt=no-new-privileges', '--pids-limit=64', '--cpus=1', '--memory=1g',
           '--env', 'GOMEMLIMIT=384MiB', '--env', 'TMPDIR=/data',
           '--env', 'HAOXIGUAN_SCALE_OUTPUT=/data/capacity-report.json',
           '--mount', f'type=volume,src={volume},dst=/data',
           '--mount', f'type=bind,src={binary},dst=/capacity,readonly', '--entrypoint', '/capacity',
           args.image, '-test.run=^TestSmallServerCapacity$', '-test.v', '-test.timeout=12m')
    result = docker('start', '-a', container, check=False)
    exit_code = int(docker('inspect', '--format', '{{.State.ExitCode}}', container).stdout)
    if exit_code:
        raise RuntimeError(result.stdout + result.stderr)
    with tempfile.TemporaryDirectory(prefix='haoxiguan-capacity-report-') as directory:
        destination = Path(directory)/'report.json'
        docker('cp', container+':/data/capacity-report.json', str(destination))
        report = json.loads(destination.read_text())
        report.update({'cpuLimit': 1, 'memoryLimitGiB': 1, 'readOnlyRoot': True,
                       'network': 'none', 'user': '65532:65532'})
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
finally:
    docker('rm', '-f', container, check=False)
    docker('volume', 'rm', volume, check=False)
