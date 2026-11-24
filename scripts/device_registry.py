"""Reviewed device-only contracts. The stable dispatch name is not a batch identity."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re

REGISTRY_PATH = 'scripts/device_batches.json'
ROOT = Path(__file__).resolve().parents[1]
ACTIVE_SCOPE = 'device-active'
HOSTS = {'macos-15': 'arm64', 'macos-15-intel': 'x86_64'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


@dataclass(frozen=True)
class Batch:
    key: str
    version: str
    build: str
    product: str
    plan_sha256: str
    branch: str
    runner: str
    job_minutes: int
    prepare_minutes: int
    plan_path: str
    legacy_source: str = None

    @property
    def ref(self):
        return 'refs/heads/' + self.branch

    def route(self):
        return dict(batch=self.key, runner=self.runner, architecture=HOSTS[self.runner],
                    job_minutes=self.job_minutes, prepare_minutes=self.prepare_minutes)

    def check_plan(self, raw):
        require(hashlib.sha256(raw).hexdigest() == self.plan_sha256, 'Frozen device plan digest differs')
        plan = json.loads(raw)
        cases = plan['cases']
        require(plan['scope'] == 'development-targeted' and plan['branch'] == self.branch and
                isinstance(cases, list) and cases and all(set(c) == {'file', 'name'} and
                re.fullmatch(r'[\w/]+\.swift', c['file']) and re.fullmatch(r'\w+', c['name']) for c in cases)
                and len({(c['file'], c['name']) for c in cases}) == len(cases), 'Invalid bound case plan')


def load_registry(data):
    require(set(data) == {'schema', 'active', 'defaults', 'batches'} and data['schema'] == 1,
            'Unknown device registry format')
    batches = {}
    for key, row in data['batches'].items():
        b = Batch(key, **{**data['defaults'], **row})
        require(key != ACTIVE_SCOPE and re.fullmatch('[a-z][a-z0-9-]+', key) and
                re.fullmatch(r'\d+\.\d+\.\d+', b.version) and re.fullmatch('[1-9][0-9]*', b.build) and
                re.fullmatch('[0-9a-f]{40}', b.product) and re.fullmatch('[0-9a-f]{64}', b.plan_sha256) and
                (b.legacy_source is None or re.fullmatch('[0-9a-f]{40}', b.legacy_source)) and
                b.runner in HOSTS and re.fullmatch(r'[\w/-]+', b.branch) and
                re.fullmatch(r'scripts/[\w-]+\.json', b.plan_path) and
                type(b.job_minutes) is int and type(b.prepare_minutes) is int and
                1 <= b.prepare_minutes <= b.job_minutes <= 60, 'Invalid frozen device batch: ' + key)
        batches[key] = b
    active = data['active']
    require(active is None or (active in batches and not batches[active].legacy_source),
            'Active device batch must be frozen and non-legacy')
    return batches, active


BATCHES, ACTIVE = load_registry(json.loads((ROOT / REGISTRY_PATH).read_bytes()))
DEVICE_SCOPES = {key for key, batch in BATCHES.items() if batch.legacy_source} | {ACTIVE_SCOPE}


def dispatch_batch(scope):
    require(scope in DEVICE_SCOPES and (scope != ACTIVE_SCOPE or ACTIVE is not None),
            'No frozen batch approved for this device dispatch')
    return BATCHES[ACTIVE if scope == ACTIVE_SCOPE else scope]
