#!/usr/bin/env python3
"""Exercise the candidate Mac app's real invitation parser; no network or pairing."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import uuid


def encode(value):
    raw = json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()
    return 'COPYBRIDGE1:' + base64.urlsafe_b64encode(raw).decode().rstrip('=')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, help='Candidate executable with --check-invitation FILE')
    parser.add_argument('--certificate-pem', required=True, help='Public test certificate; no private key')
    parser.add_argument('--url', required=True, help='Test invitation origin only; never contacted')
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    pem = Path(args.certificate_pem).read_text()
    der = base64.b64decode(''.join(line for line in pem.splitlines() if not line.startswith('-----')), validate=True)
    now = datetime.now(timezone.utc)
    invitation = {'version': 1, 'url': args.url, 'deviceId': str(uuid.uuid4()), 'deviceName': 'CopyBridge isolated parser fixture',
                  'certificatePem': pem, 'certificateSha256': hashlib.sha256(der).hexdigest(),
                  'token': secrets.token_hex(32), 'expiresAt': (now + timedelta(minutes=5)).isoformat()}
    cases = [('valid-full-entropy-invitation', encode(invitation), True)]
    replacements = [('expired', 'expiresAt', (now - timedelta(minutes=1)).isoformat()),
                    ('expiry-over-window-and-clock-tolerance', 'expiresAt', (now + timedelta(minutes=30)).isoformat()),
                    ('expiry-missing-timezone', 'expiresAt', (now + timedelta(minutes=5)).replace(tzinfo=None).isoformat()),
                    ('unsupported-version', 'version', 2), ('weak-six-digit-token', 'token', '123456'),
                    ('wrong-certificate-fingerprint', 'certificateSha256', '0' * 64),
                    ('invalid-device-id', 'deviceId', 'same-name-does-not-prove-identity'),
                    ('public-ip', 'url', 'https://8.8.8.8:43861'),
                    ('dns-origin', 'url', 'https://example.invalid:43861'),
                    ('plaintext-origin', 'url', 'http://192.168.1.100:43861'),
                    ('missing-explicit-port', 'url', 'https://192.168.1.100'),
                    ('embedded-credentials', 'url', 'https://user:password@192.168.1.100:43861'),
                    ('url-path', 'url', 'https://192.168.1.100:43861/other'),
                    ('url-query', 'url', 'https://192.168.1.100:43861?x=1'),
                    ('url-fragment', 'url', 'https://192.168.1.100:43861#x'),
                    ('malformed-certificate', 'certificatePem', 'not-a-certificate')]
    for name, key, value in replacements:
        cases.append((name, encode(dict(invitation, **{key: value})), False))
    for key in invitation:
        value = dict(invitation)
        del value[key]
        cases.append(('missing-' + key, encode(value), False))
    cases.extend([('oversized-invitation', 'COPYBRIDGE1:' + 'A' * 17000, False),
                  ('invalid-base64', 'COPYBRIDGE1:@@@', False),
                  ('wrong-prefix', 'NOTCOPYBRIDGE:' + encode(invitation).split(':', 1)[1], False)])
    results = []
    with tempfile.TemporaryDirectory(prefix='copybridge-invite-test-') as directory:
        path = Path(directory) / 'invitation.txt'
        profile = Path(directory) / 'profile'
        profile.mkdir(mode=0o700)
        for name, value, expected in cases:
            path.write_text(value)
            os.chmod(path, 0o600)
            result = subprocess.run([args.binary, '--data', str(profile), '--config', str(profile / 'not-configured.json'), '--check-invitation', str(path)], capture_output=True, timeout=15)
            # Never print or save the invitation, certificate, full app output or token.
            output = result.stdout + result.stderr
            try:
                response = json.loads(result.stdout)
            except (ValueError, UnicodeError):
                response = {}
            accepted = result.returncode == 0 and response.get('valid') is True
            leaked = invitation['token'].encode() in output or b'COPYBRIDGE1:' in output or b'BEGIN CERTIFICATE' in output
            passed = accepted == expected and not leaked
            if not expected:
                passed = passed and result.returncode != 0 and isinstance(response.get('error'), str)
            row = {'case': name, 'status': 'PASS' if passed else 'FAIL', 'expectedAccepted': expected,
                   'actualAccepted': accepted, 'exitCode': result.returncode, 'secretOutputDetected': leaked}
            results.append(row)
            print(json.dumps(row), flush=True)
    Path(args.report).write_text(json.dumps({'scope': 'actual Mac candidate parser only; no network/config/Keychain/clipboard operations', 'results': results}, indent=2) + '\n')
    return int(any(row['status'] == 'FAIL' for row in results))


if __name__ == '__main__':
    raise SystemExit(main())
