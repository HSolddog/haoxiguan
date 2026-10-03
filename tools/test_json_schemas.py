"""Validate published backup contracts with the independent Draft 2020-12 tool.

Run: python tools/test_json_schemas.py
All references resolve from checked-in schemas. No remote retrieval is allowed.
"""
import base64
import copy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource
from referencing.exceptions import NoSuchResource

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / 'docs/schemas'
SCHEMA_NAMES = (
    'logical-snapshot-v7', 'backup-encrypted-v1',
    'backup-plaintext-v1', 'backup-decrypted-v1',
)


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def no_remote_reference(uri):
    raise NoSuchResource(ref=uri)


class JsonSchemaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schemas = {
            name: read_json(SCHEMA_DIR / f'{name}.schema.json')
            for name in SCHEMA_NAMES
        }
        cls.registry = Registry(retrieve=no_remote_reference).with_resources(
            (schema['$id'], Resource.from_contents(schema))
            for schema in cls.schemas.values()
        )
        cls.checker = FormatChecker()
        # An absent optional date-time dependency must not silently skip formats.
        if not {'date', 'date-time'} <= cls.checker.checkers.keys():
            raise RuntimeError('Install tools/json-schema-test-requirements.txt')
        cls.validators = {
            name: Draft202012Validator(
                schema, registry=cls.registry, format_checker=cls.checker,
            ) for name, schema in cls.schemas.items()
        }
        cls.examples = {
            name: read_json(SCHEMA_DIR / 'examples' / f'{name}.json')
            for name in SCHEMA_NAMES
        }
        cls.positive_cases = 0
        cls.negative_cases = 0

    @classmethod
    def tearDownClass(cls):
        print('SCHEMA_CASES ' + json.dumps({
            'schemas': len(cls.schemas),
            'positive': cls.positive_cases,
            'negative': cls.negative_cases,
        }, sort_keys=True))

    def valid(self, name, value):
        errors = list(self.validators[name].iter_errors(value))
        self.assertEqual(
            [], [list(error.absolute_path) for error in errors],
            'Unexpected structural rejection; inspect the schema path',
        )
        type(self).positive_cases += 1

    def invalid(self, name, value):
        self.assertTrue(
            list(self.validators[name].iter_errors(value)),
            'The malformed contract was accepted',
        )
        type(self).negative_cases += 1

    def test_schemas_pass_official_metaschema(self):
        for name, schema in self.schemas.items():
            with self.subTest(name=name):
                Draft202012Validator.check_schema(schema)
                self.assertEqual(
                    schema['$schema'],
                    'https://json-schema.org/draft/2020-12/schema',
                )

    def test_actual_dart_exports_and_existing_cross_language_vector(self):
        for name, example in self.examples.items():
            with self.subTest(name=name):
                self.valid(name, example)
        vector = read_json(ROOT / 'test/fixtures/backup-v1-vector.json')
        self.valid('logical-snapshot-v7', vector['snapshot'])
        self.valid('backup-encrypted-v1', vector['envelope'])
        self.valid('logical-snapshot-v7', {'version': 7, 'habits': []})

    def test_actual_exported_business_data_and_manifest_agree(self):
        snapshot = self.examples['logical-snapshot-v7']
        plaintext = self.examples['backup-plaintext-v1']
        inner = self.examples['backup-decrypted-v1']
        self.assertEqual(snapshot, plaintext['data'])
        self.assertEqual(snapshot, inner['data'])
        self.assertEqual(7, inner['manifest']['dataSchemaVersion'])
        self.assertEqual(len(snapshot['habits']), inner['manifest']['habitCount'])
        self.assertEqual(snapshot['vaultId'], inner['manifest']['sourceVaultId'])
        self.assertEqual({'boolean', 'count', 'duration'}, {
            habit['recordType'] for habit in snapshot['habits']
        })
        for name in ('backup-encrypted-v1',):
            envelope = self.examples[name]
            cipher = base64.b64decode(envelope['payload'], validate=True)
            self.assertEqual(envelope['payload'], base64.b64encode(cipher).decode())
            self.assertTrue(16 <= len(cipher) <= 36 * 1024 * 1024 + 16)
            self.assertEqual(hashlib.sha256(cipher).hexdigest(), envelope['payloadSha256'])

    def test_unknown_root_habit_and_category_extensions_are_preserved(self):
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        snapshot['externalExtension'] = {'unexpected': [None, 5, '公开合成字段']}
        snapshot['habits'][0]['externalExtension'] = {'source': 'legacy'}
        snapshot['categories'][0]['externalExtension'] = {'tag': 'legacy'}
        snapshot['habits'][0]['categoryInfo']['externalExtension'] = None
        before = copy.deepcopy(snapshot)
        self.valid('logical-snapshot-v7', snapshot)
        self.assertEqual(before, snapshot)

    def test_legacy_ids_local_times_and_long_text_export_remain_valid(self):
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        habit = snapshot['habits'][0]
        habit['id'] = 'seed-reading'
        habit['title'] = '旧' * 81
        habit['notes']['2026-10-02'] = '旧' * 2001
        habit['pausedAt'] = '2026-10-02T09:30:00.000'
        habit['completions']['2026-10-01'] = '2026-10-01 09:30:00.000'
        habit['entries'][0]['recordedAtUtc'] = None
        habit['entries'][0]['legacyTimestamp'] = '2026-10-01 09:30:00.000'
        habit['entries'][0]['source'] = 'legacy'
        habit['entries'][0]['timezoneId'] = 'unknownLegacy'
        habit['entries'][0]['utcOffsetMinutes'] = None
        self.valid('logical-snapshot-v7', snapshot)
        habit['entries'][0]['recordedAtUtc'] = '2026-10-01T12:00:00+08:00'
        self.valid('logical-snapshot-v7', snapshot)

    def test_missing_and_nullable_compatible_metadata(self):
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        snapshot['categories'] = None
        habit = snapshot['habits'][0]
        for name in ('categoryId', 'sortKey', 'categoryInfo'):
            habit[name] = None
        self.valid('logical-snapshot-v7', snapshot)
        inner = copy.deepcopy(self.examples['backup-decrypted-v1'])
        del inner['manifest']['createdAtUtc']
        inner['manifest']['sourceVaultId'] = None
        inner['manifest']['unknownLegacyManifest'] = {'retained': True}
        self.valid('backup-decrypted-v1', inner)

    def test_current_structure_is_distinct_from_legacy_and_future_snapshots(self):
        for version in (5, 8, '7', True):
            with self.subTest(version=version):
                self.invalid('logical-snapshot-v7', {'version': version, 'habits': []})
        self.invalid('logical-snapshot-v7', {'version': 7, 'habits': {}})
        self.invalid('logical-snapshot-v7', {'habits': []})

    def test_model_field_types_and_ranges(self):
        changes = (
            ('scale', 2), ('recordType', 'timer'), ('unit', ''),
            ('dailyTarget', 0), ('weekdays', []), ('weekdays', [0]),
            ('plans', []), ('sortKey', 9007199254740992),
        )
        for key, value in changes:
            with self.subTest(key=key, value=value):
                snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
                snapshot['habits'][0][key] = value
                self.invalid('logical-snapshot-v7', snapshot)
        for key, value in (('value', 0), ('value', 1.5), ('revision', 0),
                           ('utcOffsetMinutes', 1441)):
            with self.subTest(record_key=key):
                snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
                snapshot['habits'][0]['entries'][0][key] = value
                self.invalid('logical-snapshot-v7', snapshot)

    def test_canonical_records_and_plans_do_not_emit_unknown_fields(self):
        for collection in ('entries', 'plans'):
            with self.subTest(collection=collection):
                snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
                snapshot['habits'][0][collection][0]['unknownField'] = 3
                self.invalid('logical-snapshot-v7', snapshot)

    def test_format_assertion_rejects_bad_calendar_and_non_utc_current_time(self):
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        snapshot['habits'][0]['entries'][0]['date'] = '2026-02-30'
        self.invalid('logical-snapshot-v7', snapshot)
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        snapshot['habits'][0]['completions']['not-a-date'] = '2026-10-01T00:00:00'
        self.invalid('logical-snapshot-v7', snapshot)
        for value in ('2026-10-03T00:00:00+08:00', 'not-a-timeZ'):
            with self.subTest(value=value):
                plaintext = copy.deepcopy(self.examples['backup-plaintext-v1'])
                plaintext['createdAtUtc'] = value
                self.invalid('backup-plaintext-v1', plaintext)

    def test_encrypted_wrapper_is_strict_before_crypto(self):
        mutations = (
            ('format', 'unknown'), ('formatVersion', 2), ('encrypted', False),
            ('appVersion', 'x' * 65), ('payload', 'AAAA!'),
            ('payloadSha256', 'X' * 64), ('unknownField', 1),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                envelope = copy.deepcopy(self.examples['backup-encrypted-v1'])
                envelope[key] = value
                self.invalid('backup-encrypted-v1', envelope)
        for key, value in (('salt', 'A' * 21 + 'B=='), ('nonce', 'A' * 31),
                           ('suite', 'unknown')):
            with self.subTest(crypto_key=key):
                envelope = copy.deepcopy(self.examples['backup-encrypted-v1'])
                envelope['crypto'][key] = value
                self.invalid('backup-encrypted-v1', envelope)
        for key in ('memoryKiB', 'iterations', 'parallelism'):
            with self.subTest(kdf_key=key):
                envelope = copy.deepcopy(self.examples['backup-encrypted-v1'])
                envelope['crypto']['kdfParams'][key] += 1
                self.invalid('backup-encrypted-v1', envelope)
        for key in ('salt', 'nonce', 'payload', 'payloadSha256'):
            with self.subTest(newline_key=key):
                envelope = copy.deepcopy(self.examples['backup-encrypted-v1'])
                container = envelope['crypto'] if key in ('salt', 'nonce') else envelope
                container[key] += '\n'
                self.invalid('backup-encrypted-v1', envelope)

    def test_plaintext_wrapper_does_not_invent_encrypted_fields(self):
        for key, value in (('encrypted', True), ('manifest', {}),
                           ('appVersion', '1.2.0'), ('formatVersion', 7)):
            with self.subTest(key=key):
                plaintext = copy.deepcopy(self.examples['backup-plaintext-v1'])
                plaintext[key] = value
                self.invalid('backup-plaintext-v1', plaintext)
        plaintext = copy.deepcopy(self.examples['backup-plaintext-v1'])
        del plaintext['createdAtUtc']
        self.invalid('backup-plaintext-v1', plaintext)

    def test_schema_does_not_claim_crypto_business_or_numeric_encoding_checks(self):
        # Valid structure can still contain a false digest or mismatching count.
        envelope = copy.deepcopy(self.examples['backup-encrypted-v1'])
        envelope['payloadSha256'] = '0' * 64
        self.valid('backup-encrypted-v1', envelope)
        inner = copy.deepcopy(self.examples['backup-decrypted-v1'])
        inner['manifest']['habitCount'] = 0
        self.valid('backup-decrypted-v1', inner)
        snapshot = copy.deepcopy(self.examples['logical-snapshot-v7'])
        snapshot['habits'].append(copy.deepcopy(snapshot['habits'][0]))
        self.valid('logical-snapshot-v7', snapshot)
        # JSON Schema mathematical integer semantics differ from Dart is int.
        self.valid('logical-snapshot-v7', {'version': 7.0, 'habits': []})


if __name__ == '__main__':
    unittest.main(verbosity=2)
