import copy
import datetime
import hashlib
import unittest

from check_adhoc_device_scope import validate_entitlements, validate_profile


class AdHocScopeTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 27)
        self.devices = ['synthetic-ipad-a', 'synthetic-ipad-b', 'synthetic-ipad-c']
        self.entitlements = {'application-identifier': 'TEAM.app',
                             'com.apple.developer.team-identifier': 'TEAM',
                             'get-task-allow': False, 'keychain-access-groups': ['TEAM.*']}
        self.profile = dict(UUID='manual-profile', TeamIdentifier=['TEAM'],
                            CreationDate=self.now - datetime.timedelta(days=1),
                            ExpirationDate=self.now + datetime.timedelta(days=1),
                            Entitlements=self.entitlements, ProvisionedDevices=self.devices,
                            DeveloperCertificates=[b'synthetic-certificate'])
        self.policy = dict(schemaVersion=1, profileUUID='manual-profile', teamID='TEAM', bundleID='app',
                           deviceCount=3, deviceSetSHA256=hashlib.sha256('\n'.join(self.devices).encode()).hexdigest(),
                           certificateSHA256=[hashlib.sha256(b'synthetic-certificate').hexdigest()])

    def test_exact_set_accepts_order_change(self):
        self.profile['ProvisionedDevices'] = list(reversed(self.devices))
        validate_profile(self.profile, self.policy, self.now)

    def test_extra_missing_substituted_or_duplicate_device_fails(self):
        for devices in [self.devices + ['phone'], self.devices[:2],
                        self.devices[:2] + ['another-ipad'], [self.devices[0]] * 3]:
            with self.subTest(devices=len(devices)), self.assertRaises(ValueError):
                self.profile['ProvisionedDevices'] = devices
                validate_profile(self.profile, self.policy, self.now)

    def test_wrong_profile_team_certificate_or_distribution_fails(self):
        for key, value in [('UUID', 'managed-profile'), ('TeamIdentifier', ['OTHER']),
                           ('DeveloperCertificates', [b'other']), ('ProvisionsAllDevices', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                profile = copy.deepcopy(self.profile); profile[key] = value
                validate_profile(profile, self.policy, self.now)

    def test_expired_future_development_or_wrong_app_fails(self):
        for key, value in [('ExpirationDate', self.now), ('CreationDate', self.now + datetime.timedelta(seconds=1))]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                profile = copy.deepcopy(self.profile); profile[key] = value
                validate_profile(profile, self.policy, self.now)
        for key, value in [('get-task-allow', True), ('application-identifier', 'TEAM.other')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                profile = copy.deepcopy(self.profile); profile['Entitlements'][key] = value
                validate_profile(profile, self.policy, self.now)

    def test_signed_entitlements_must_stay_within_profile(self):
        actual = dict(self.entitlements, **{'keychain-access-groups': ['TEAM.app']})
        validate_entitlements(actual, self.entitlements)
        for key, value in [('get-task-allow', True), ('keychain-access-groups', ['OTHER.app']),
                           ('application-identifier', 'TEAM.other'), ('unexpected-capability', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_entitlements(dict(actual, **{key: value}), self.entitlements)
        del actual['application-identifier']
        with self.assertRaises(ValueError):
            validate_entitlements(actual, self.entitlements)


if __name__ == '__main__':
    unittest.main()
