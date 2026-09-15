import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'distribute_testflight.py'
spec = importlib.util.spec_from_file_location('delivery', PATH)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Fake:
    def __init__(self):
        self.writes = []
        self.assigned = set()
        self.individual = set()
        self.reviewed = False
        self.external = 'READY_FOR_BETA_SUBMISSION'
        self.groups = [{'id': 'internal', 'attributes': {'isInternalGroup': True}},
                       {'id': 'external', 'attributes': {'isInternalGroup': False}}]
        self.app = {'id': 'app', 'attributes': {'bundleId': m.BUNDLE}}
        self.build = {'id': 'build', 'attributes': {'version': '1052.1', 'processingState': 'VALID',
                      'expired': False, 'buildAudienceType': 'APP_STORE_ELIGIBLE'}}

    def all(self, path):
        if path.startswith('/v1/apps?'):
            return [self.app]
        if path.startswith('/v1/builds?'):
            return [self.build]
        if path.startswith('/v1/apps/app/betaGroups'):
            return self.groups
        if path.startswith('/v1/betaTesters?'):
            return [{'id': x, 'attributes': {'state': 'ACCEPTED'}} for x in ['one', 'two', 'three']]
        if '/relationships/individualTesters' in path:
            return [{'id': x} for x in self.individual]
        if '/relationships/betaTesters' in path:
            return [{'id': 'one' if '/internal/' in path else 'two'}]
        if '/relationships/builds' in path:
            group = path.split('/')[3]
            return [{'id': 'build'}] if group in self.assigned else []
        if '/betaBuildLocalizations' in path:
            return [{'id': 'notes', 'attributes': {'locale': 'en-US', 'whatsNew': 'Reviewed notes'}}]
        if path.startswith('/v1/betaAppReviewSubmissions?'):
            return [{'id': 'review'}] if self.reviewed else []
        raise AssertionError(path)

    def request(self, method, path, payload=None):
        if method == 'GET':
            if path.endswith('/preReleaseVersion'):
                return {'data': {'attributes': {'version': '0.7.1', 'platform': 'IOS'}}}
            if path.endswith('/buildBetaDetail'):
                return {'data': {'id': 'detail', 'attributes': {'autoNotifyEnabled': True,
                        'internalBuildState': 'IN_BETA_TESTING', 'externalBuildState': self.external}}}
            raise AssertionError(path)
        self.writes.append((method, path, payload))
        if '/betaGroups/' in path:
            self.assigned.add(path.split('/')[3])
        elif path.endswith('/relationships/individualTesters'):
            self.individual.update(row['id'] for row in payload['data'])
        elif path == '/v1/betaAppReviewSubmissions':
            self.reviewed = True
            self.external = 'WAITING_FOR_BETA_REVIEW'
        elif path == '/v1/buildBetaNotifications':
            self.external = 'IN_BETA_TESTING'
        else:
            raise AssertionError(path)
        return {}


class DeliveryTests(unittest.TestCase):
    def test_read_only_inspection_never_changes_access(self):
        client = Fake()
        result = m.deliver(client, client.app, client.build, {}, False)
        self.assertEqual(result['testers'], 3)
        self.assertEqual(result['covered_testers'], 0)
        self.assertEqual(client.writes, [])

    def test_assigns_existing_groups_and_only_uncovered_individuals(self):
        client = Fake()
        result = m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
        self.assertEqual(client.assigned, {'internal', 'external'})
        self.assertEqual(client.individual, {'three'})
        self.assertTrue(result['all_assigned'])
        self.assertFalse(result['all_available'])
        self.assertTrue(client.reviewed)
        self.assertNotIn('email', json.dumps(result))

    def test_repeated_delivery_does_not_duplicate_assignments_or_review(self):
        client = Fake()
        m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
        previous = list(client.writes)
        m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
        self.assertEqual(client.writes, previous)

    def test_notifications_only_after_external_approval(self):
        client = Fake()
        client.external = 'READY_FOR_BETA_TESTING'
        result = m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
        self.assertTrue(result['all_available'])
        self.assertEqual(result['notification'], 'notification_requested')
        before = len(client.writes)
        m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
        self.assertEqual(len(client.writes), before)

    def test_processing_or_internal_only_build_cannot_be_distributed(self):
        for key, value in [('processingState', 'PROCESSING'), ('expired', True),
                           ('buildAudienceType', 'INTERNAL_ONLY')]:
            with self.subTest(key=key):
                client = Fake()
                client.build['attributes'][key] = value
                with self.assertRaises(ValueError):
                    m.deliver(client, client.app, client.build, {'en-US': 'Reviewed notes'}, True)
                self.assertEqual(client.writes, [])

    def test_wrong_marketing_version_and_ambiguous_app_fail_closed(self):
        client = Fake()
        with self.assertRaises(ValueError):
            m.locate(client, '9.9.9', '1052.1')
        with self.assertRaises(ValueError):
            m.one([client.app, client.app], 'app')

    def test_url_boundary_rejects_foreign_hosts_and_credentials(self):
        for url in ['https://example.com/v1/builds', 'https://api.appstoreconnect.apple.com.evil/v1/apps',
                    'https://user@api.appstoreconnect.apple.com/v1/apps', '//evil/v1/apps',
                    'https://api.appstoreconnect.apple.com/v1/apps#secret']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                m.safe_url(url)
        self.assertEqual(m.safe_url('/v1/apps'), m.ORIGIN + '/v1/apps')

    def test_read_only_client_rejects_writes_before_signing(self):
        client = m.Client(Path('/absent'), 'key', 'issuer', False)
        with self.assertRaises(ValueError):
            client.request('POST', '/v1/buildBetaNotifications', {})

    def test_pagination_fails_on_cycle_or_foreign_next_link(self):
        for next_link in ['/v1/apps', 'https://example.com/v1/apps']:
            client = m.Client(Path('/absent'), '', '', False)
            client.request = lambda *args: {'data': [], 'links': {'next': next_link}}
            with self.assertRaises(ValueError):
                client.all('/v1/apps')

    def test_jose_signature_matches_openssl_and_invalid_der_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / 'key.pem'
            subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(key)],
                           check=True, capture_output=True)
            jwt = m.token(key, 'ABCDEFGHIJ', '00000000-0000-0000-0000-000000000001')
            header, claims, signature = jwt.split('.')
            raw = m.base64.urlsafe_b64decode(signature + '==')
            self.assertEqual(len(raw), 64)
            payload = json.loads(m.base64.urlsafe_b64decode(claims + '=='))
            self.assertEqual(payload['exp'] - payload['iat'], 600)
            integers = []
            for value in [raw[:32], raw[32:]]:
                value = value.lstrip(b'\0')
                if value[0] & 0x80:
                    value = b'\0' + value
                integers.append(b'\x02' + bytes([len(value)]) + value)
            inner = b''.join(integers)
            der = b'\x30' + bytes([len(inner)]) + inner
            sigfile = Path(directory) / 'sig'
            sigfile.write_bytes(der)
            pub = Path(directory) / 'pub.pem'
            subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(pub)], check=True, capture_output=True)
            verified = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(pub), '-signature', str(sigfile)],
                                      input=f'{header}.{claims}'.encode(), capture_output=True)
            self.assertEqual(verified.returncode, 0)
            self.assertEqual(m.raw_signature(der), raw)
        for invalid in [b'', b'\x30\x00', der + b'\0', b'\x30\x06\x02\x01\x80\x02\x01\x01']:
            with self.assertRaises(ValueError):
                m.raw_signature(invalid)


if __name__ == '__main__':
    unittest.main()
