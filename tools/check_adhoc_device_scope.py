#!/usr/bin/env python3
"""Fail closed before publishing an Ad Hoc app; never print device identifiers."""
import argparse
import datetime
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_profile(profile, policy, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    require(policy['schemaVersion'] == 1, 'Unsupported device policy')
    require(profile.get('UUID') == policy['profileUUID'], 'Unexpected provisioning profile')
    require(profile.get('TeamIdentifier') == [policy['teamID']], 'Unexpected team')
    require(profile['CreationDate'] <= now < profile['ExpirationDate'], 'Profile outside validity period')
    require(not profile.get('ProvisionsAllDevices', False), 'Enterprise distribution is not allowed')
    entitlements = profile['Entitlements']
    require(entitlements.get('get-task-allow') is False, 'Development entitlement is not allowed')
    require(entitlements.get('application-identifier') == policy['teamID'] + '.' + policy['bundleID'],
            'Unexpected application identifier')
    devices = profile.get('ProvisionedDevices', [])
    require(len(devices) == len(set(devices)) == policy['deviceCount'], 'Incorrect allowed device count')
    digest = hashlib.sha256('\n'.join(sorted(devices)).encode()).hexdigest()
    require(digest == policy['deviceSetSHA256'], 'Allowed device set differs from approved set')
    certificates = {hashlib.sha256(cert).hexdigest() for cert in profile['DeveloperCertificates']}
    require(certificates == set(policy['certificateSHA256']), 'Unexpected profile certificate set')


def validate_entitlements(actual, allowed):
    for key in ['application-identifier', 'com.apple.developer.team-identifier']:
        require(actual.get(key) == allowed.get(key) and key in actual,
                'Required app entitlement differs from profile: ' + key)
    require(actual.get('get-task-allow', False) is False, 'App permits debugging')
    for key, value in actual.items():
        require(key in allowed, 'App entitlement absent from profile: ' + key)
        if key == 'keychain-access-groups':
            require(all(any(fnmatch.fnmatchcase(group, pattern) for pattern in allowed[key])
                        for group in value), 'Keychain entitlement exceeds profile')
        else:
            require(value == allowed[key], 'App entitlement differs from profile: ' + key)


def check_app(app, policy):
    profile = plistlib.loads(subprocess.check_output(
        ['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], stderr=subprocess.DEVNULL))
    validate_profile(profile, policy)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == policy['bundleID'], 'Unexpected app bundle')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    actual = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    validate_entitlements(actual, profile['Entitlements'])
    with tempfile.TemporaryDirectory(prefix='simstock-signing-check-') as directory:
        prefix = str(Path(directory) / 'certificate-')
        subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)],
                       check=True, capture_output=True)
        leaf = hashlib.sha256(Path(prefix + '0').read_bytes()).hexdigest()
        require(leaf in policy['certificateSHA256'], 'Actual signing certificate is not approved')
    return dict(status='passed', bundleID=policy['bundleID'], appVersion=info['CFBundleShortVersionString'],
                build=info['CFBundleVersion'], profileUUID=profile['UUID'],
                deviceCount=policy['deviceCount'], exactDeviceSet=True,
                signatureVerified=True, certificateVerified=True, entitlementsVerified=True,
                profileExpires=profile['ExpirationDate'].isoformat())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--policy', type=Path, default=Path(__file__).resolve().parents[1] / 'release/device-policy.json')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = check_app(args.app, json.loads(args.policy.read_text()))
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
