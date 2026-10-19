#!/usr/bin/env python3
"""Real CopyBridge HTTPS contract checks; never run against a concurrent paired client."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import ssl
import stat
import subprocess
import time
from urllib.parse import urlsplit
import uuid


def secret_file(path):
    path = Path(path).expanduser()
    with path.open('rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Token file must be owned by this user and mode 0600 or stricter')
        return stream.read(16385).decode('utf-8').strip()


class Client:
    def __init__(self, config, token=None):
        url = urlsplit(config['url'])
        if url.scheme != 'https' or not url.hostname or url.username or url.path not in ('', '/') or url.query or url.fragment:
            raise ValueError('Expected an HTTPS origin with no embedded credentials')
        self.host, self.port = url.hostname, url.port or 443
        self.pin = config['certificateSha256'].lower()
        if len(self.pin) != 64 or any(c not in '0123456789abcdef' for c in self.pin):
            raise ValueError('certificateSha256 must be 64 hexadecimal characters')
        self.context = ssl.create_default_context(cafile=str(Path(config['certificatePem']).expanduser()))
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.token = secret_file(config['tokenFile']) if token is None else token
        if not self.token or len(self.token) > 16384 or '\n' in self.token or '\r' in self.token:
            raise ValueError('Invalid token file')
        self.epoch = None

    def request(self, method, path, body=None, auth='valid', epoch=None, raw=False):
        headers = {}
        if auth != 'missing':
            headers['Authorization'] = 'Bearer ' + (self.token if auth == 'valid' else 'fixture-invalid-token')
        if epoch or self.epoch:
            headers['X-Connection-Epoch'] = epoch or self.epoch
        if body is not None:
            body = body if raw else json.dumps(body, ensure_ascii=False).encode('utf-8')
            headers['Content-Type'] = 'application/octet-stream' if raw else 'application/json'
            headers['Content-Length'] = str(len(body))
        connection = http.client.HTTPSConnection(self.host, self.port, context=self.context, timeout=15)
        try:
            connection.connect()  # CERT_REQUIRED, certificate chain AND hostname verification.
            actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
            if actual != self.pin:
                raise ssl.SSLError('TLS_PIN_MISMATCH')  # Before credentials or body leave this process.
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read(65537)
            if len(data) > 65536:
                raise AssertionError('Response exceeds 64 KiB')
            try:
                result = json.loads(data)
            except (ValueError, UnicodeError):
                result = {}
            return response.status, result
        finally:
            connection.close()


def ok(response, state=None):
    status, body = response
    assert 200 <= status < 300, f'HTTP {status}, error={safe_error(body)}'
    if state:
        assert body.get('state') == state, f'Expected state {state}'
    return body


def safe_error(body):
    value = body.get('error', '') if isinstance(body, dict) else ''
    return value if isinstance(value, str) and len(value) < 80 and all(c.isupper() or c == '_' for c in value) else 'REDACTED'


def rejected(response, errors=()):
    status, body = response
    assert 400 <= status < 500, f'Expected rejection, HTTP {status}'
    assert safe_error(body) not in ('', 'REDACTED'), 'Expected structured error code'
    if errors:
        assert body['error'] in errors, f'Unexpected error {safe_error(body)}'
    return body


class Suite:
    def __init__(self, client, config, args):
        self.client, self.config, self.args = client, config, args
        self.session, self.handshake = str(uuid.uuid4()), str(uuid.uuid4())
        self.seq, self.results, self.ids = 0, [], []
        self.started_at = datetime.now(timezone.utc).isoformat()

    def run_case(self, name, function):
        started = time.monotonic()
        started_at = datetime.now(timezone.utc).isoformat()
        first_id = len(self.ids)
        try:
            function()
            result = {'case': name, 'status': 'PASS'}
        except Exception as error:
            # No server body, clipboard content, paths, URL or token in diagnostics.
            result = {'case': name, 'status': 'FAIL', 'exception': type(error).__name__}
            if isinstance(error, AssertionError):
                result['reason'] = str(error)
        result['elapsedSeconds'] = round(time.monotonic() - started, 4)
        result['startTime'] = started_at
        result['transferIds'] = self.ids[first_id:]
        self.results.append(result)
        print(json.dumps(result), flush=True)

    def blocked(self, name, reason):
        self.results.append({'case': name, 'status': 'BLOCKED', 'reason': reason})

    def state(self):
        return ok(self.client.request('GET', '/v1/receiver-state'))

    def hello(self):
        request = {'protocolVersion': 1, 'deviceId': self.config['deviceId'], 'sourceSessionId': self.session,
                   'handshakeId': self.handshake, 'lastIssuedSourceSeq': self.seq}
        first = ok(self.client.request('POST', '/v1/hello', request))
        second = ok(self.client.request('POST', '/v1/hello', request))
        assert first['connectionEpoch'] == second['connectionEpoch'], 'HELLO retry changed epoch'
        self.client.epoch = first['connectionEpoch']
        self.seq = max(self.seq, first['seqFloor'])
        assert first.get('outgoing') is None, 'HELLO replayed pre-existing clipboard'

    def head(self, generation=None):
        self.seq += 1
        ident = str(uuid.uuid4())
        self.ids.append(ident)
        return {'connectionEpoch': self.client.epoch, 'sourceSessionId': self.session,
                'sourceSeq': self.seq, 'transferId': ident,
                'receiverGenAtCopy': self.state()['receiverGeneration'] if generation is None else generation}

    def offer(self, head, data=b'CopyBridge fixture\n', **changes):
        item = {'itemId': 'f1', 'name': 'fixture.txt', 'mime': 'text/plain',
                'sizeBytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        item.update(changes)
        return dict(head, kind='text', items=[item])

    def put(self, head, data):
        return self.client.request('PUT', f"/v1/transfers/{head['transferId']}/items/f1", data, raw=True)

    def complete(self, head):
        return self.client.request('POST', f"/v1/transfers/{head['transferId']}/complete", {})

    def accepted(self, head, offer=None):
        ok(self.client.request('POST', '/v1/head', head), 'Announced')
        if offer:
            ok(self.client.request('POST', '/v1/offers', offer), 'Offered')

    def wrong_pin(self):
        original = self.client.pin
        self.client.pin = '0' * 64 if original != '0' * 64 else '1' * 64
        try:
            try:
                self.client.request('GET', '/v1/receiver-state')
            except ssl.SSLError as error:
                assert 'TLS_PIN_MISMATCH' in str(error), 'TLS failed before exercising exact fingerprint check'
            else:
                raise AssertionError('Wrong certificate fingerprint was accepted')
        finally:
            self.client.pin = original

    def duplicate(self):
        head = self.head()
        self.accepted(head)
        ok(self.client.request('POST', '/v1/head', head), 'Announced')
        rejected(self.client.request('POST', '/v1/head', dict(head, receiverGenAtCopy=head['receiverGenAtCopy'] + 1)), ('IDEMPOTENCY_CONFLICT',))
        offer = self.offer(head)
        ok(self.client.request('POST', '/v1/offers', offer), 'Offered')
        ok(self.client.request('POST', '/v1/offers', offer), 'Offered')
        changed = self.offer(head, name='changed.txt')
        rejected(self.client.request('POST', '/v1/offers', changed), ('IDEMPOTENCY_CONFLICT',))

    def stale_sequence(self):
        old, new = self.head(), self.head()
        self.accepted(new)
        rejected(self.client.request('POST', '/v1/head', old))
        rejected(self.complete(old))

    def cancelled_ready(self):
        data = b'CopyBridge cancelled fixture'
        head = self.head()
        self.accepted(head, self.offer(head, data))
        ok(self.put(head, data), 'Ready')
        route = f"/v1/transfers/{head['transferId']}/cancel"
        ok(self.client.request('POST', route, {}), 'Cancelled')
        ok(self.client.request('POST', route, {}), 'Cancelled')
        rejected(self.complete(head))

    def uuid_case_binding(self):
        head = self.head()
        self.accepted(head)
        self.seq += 1
        changed = dict(head, transferId=head['transferId'].upper(), sourceSeq=self.seq)
        rejected(self.client.request('POST', '/v1/head', changed), ('IDEMPOTENCY_CONFLICT',))

    def superscript_devices(self):
        for name in ('COM¹.png', 'LPT².png', 'COM³.png'):
            head = self.head()
            offer = self.offer(head, name=name, mime='image/png')
            offer['kind'] = 'file'
            self.accepted(head)
            rejected(self.client.request('POST', '/v1/offers', offer), ('INVALID_FILENAME',))

    def invalid_generation(self):
        head = self.head(generation=self.state()['receiverGeneration'] + 1)
        rejected(self.client.request('POST', '/v1/head', head), ('LOCAL_CLIPBOARD_CHANGED',))
        changed = dict(head, receiverGenAtCopy=self.state()['receiverGeneration'])
        rejected(self.client.request('POST', '/v1/head', changed), ('IDEMPOTENCY_CONFLICT',))

    def integrity(self, mismatch):
        data = b'CopyBridge integrity fixture'
        head = self.head()
        offer = self.offer(head, data, **({'sha256': '0' * 64} if mismatch == 'hash' else {'sizeBytes': len(data) + 1}))
        self.accepted(head, offer)
        rejected(self.put(head, data), ('HASH_MISMATCH',) if mismatch == 'hash' else ())
        rejected(self.complete(head))

    def invalid_name(self, name):
        head = self.head()
        offer = self.offer(head, name=name, mime='image/png')
        offer['kind'] = 'file'
        self.accepted(head)
        rejected(self.client.request('POST', '/v1/offers', offer))

    def size_boundary(self, size, accept):
        head = self.head()
        offer = self.offer(head, name='fixture.mp4', mime='video/mp4', sizeBytes=size)
        offer['kind'] = 'file'
        self.accepted(head)
        response = self.client.request('POST', '/v1/offers', offer)
        if accept:
            ok(response, 'Offered')
        else:
            rejected(response, ('SIZE_LIMIT',))
        ok(self.client.request('POST', f"/v1/transfers/{head['transferId']}/cancel", {}))

    def superseded(self):
        data = b'CopyBridge superseded fixture'
        old = self.head()
        self.accepted(old, self.offer(old, data))
        ok(self.put(old, data), 'Ready')
        new = self.head()
        self.accepted(new)
        rejected(self.complete(old))

    def local_copy(self):
        before = self.state()['receiverGeneration']
        subprocess.run([self.args.local_copy_hook], input=b'CopyBridge LOCAL fixture\n', stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True, timeout=15)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.state()['receiverGeneration'] > before:
                return
            time.sleep(0.15)
        raise AssertionError('Local copy did not advance receiverGeneration')

    def local_race(self):
        head = self.head()
        self.local_copy()
        rejected(self.client.request('POST', '/v1/head', head), ('LOCAL_CLIPBOARD_CHANGED',))
        rejected(self.client.request('POST', '/v1/head', dict(head, receiverGenAtCopy=self.state()['receiverGeneration'])), ('IDEMPOTENCY_CONFLICT',))
        pending = self.head()
        data = b'CopyBridge pending fixture'
        self.accepted(pending, self.offer(pending, data))
        ok(self.put(pending, data), 'Ready')
        self.local_copy()
        rejected(self.complete(pending))

    def publish(self):
        data = ('CopyBridge generated fixture ' + self.session + '\n中文 😀\tline2').encode('utf-8')
        head = self.head()
        self.accepted(head, self.offer(head, data))
        ok(self.put(head, data), 'Ready')
        with ThreadPoolExecutor(max_workers=3) as pool:
            completions = list(pool.map(lambda _: self.complete(head), range(3)))
        published = [ok(response, 'Published') for response in completions]
        assert len({item['publishedAt'] for item in published}) == 1, 'Concurrent COMPLETE republished fixture'
        first = published[0]
        assert first['currentlyOnClipboard'] is True, 'Published fixture is not current'
        second = ok(self.complete(head), 'Published')
        assert second['publishedAt'] == first['publishedAt'], 'Duplicate COMPLETE republished'
        assert second['receiverGeneration'] == first['receiverGeneration'], 'Own write advanced generation'
        if self.args.local_copy_hook:
            self.local_copy()
            third = ok(self.complete(head), 'Published')
            assert third['publishedAt'] == first['publishedAt'], 'Old COMPLETE republished'
            assert third['currentlyOnClipboard'] is False, 'Old COMPLETE replaced local copy'
        else:
            self.blocked('duplicate-complete-after-local-copy', 'No parent-coordinated local fixture hook')

    def run(self):
        self.run_case('exact-certificate-fingerprint-rejection', self.wrong_pin)
        for auth in ('missing', 'invalid'):
            self.run_case('authentication-' + auth, lambda auth=auth: rejected(self.client.request('GET', '/v1/receiver-state', auth=auth), ('AUTH_FAILED',)))
        self.run_case('authentication-before-oversized-body', lambda: rejected(self.client.request('POST', '/v1/offers', b'x' * 65537, auth='invalid', raw=True), ('AUTH_FAILED',)))
        self.run_case('hello-idempotent-no-replay', self.hello)
        if not self.client.epoch:
            return
        self.run_case('old-epoch-rejection', lambda: rejected(self.client.request('GET', '/v1/receiver-state', epoch=str(uuid.uuid4())), ('SESSION_REVOKED',)))
        cases = [('uuid-case-binding', self.uuid_case_binding), ('superscript-device-filenames', self.superscript_devices), ('cancelled-ready-cannot-publish', self.cancelled_ready), ('duplicate-head-offer-immutable', self.duplicate), ('stale-sequence', self.stale_sequence),
                 ('invalid-generation-cannot-rebind', self.invalid_generation), ('hash-mismatch', lambda: self.integrity('hash')),
                 ('offer-length-mismatch', lambda: self.integrity('length')), ('superseded-ready-cannot-publish', self.superseded)]
        for name, function in cases:
            self.run_case(name, function)
        for name in ('../escape.png', '/absolute.png', 'C:\\escape.png', 'CON.png', 'file.png:stream', 'trailing.png.', 'trailing.png '):
            self.run_case('filename-boundary-' + str(len(self.results)), lambda name=name: self.invalid_name(name))
        for size in (2147483647, 2147483648, 2147483649):
            self.run_case(f'file-size-metadata-{size}', lambda size=size: self.size_boundary(size, size <= 2147483648))
        if self.args.local_copy_hook:
            self.run_case('real-local-generation-and-late-head', self.local_race)
        else:
            self.blocked('real-local-generation-and-late-head', 'No parent-coordinated local fixture hook')
        if self.args.allow_publish:
            self.run_case('real-generated-text-publish-idempotence', self.publish)
        else:
            self.blocked('real-generated-text-publish-idempotence', 'Requires explicit --allow-publish')
        for ident in self.ids:
            self.client.request('POST', f'/v1/transfers/{ident}/cancel', {})
        # A fresh logical handshake invalidates any delayed test requests. It does not clear the clipboard.
        self.handshake = str(uuid.uuid4())
        self.run_case('final-session-revocation', self.hello)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='JSON containing URL, deviceId, certificateSha256, certificatePem, tokenFile')
    parser.add_argument('--pair-token-file', help='Protected bootstrap file for fresh isolated test profile only; writes a NEW tokenFile')
    parser.add_argument('--isolated-session', action='store_true', help='Confirm paired Mac client is stopped and this session may be replaced')
    parser.add_argument('--allow-publish', action='store_true', help='Allow generated text fixture publication to Windows clipboard')
    parser.add_argument('--local-copy-hook', help='Parent-approved executable: fixture text on stdin; must write Windows interactive clipboard, no output')
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    if not args.isolated_session:
        parser.error('--isolated-session is required; this test changes the logical pairing session')
    config = json.loads(Path(args.config).read_text())
    if args.pair_token_file:
        if Path(config['tokenFile']).expanduser().exists():
            raise ValueError('Isolated tokenFile already exists; omit pairing flag to reuse it')
        client = Client(config, token='isolated-pairing-bootstrap')
        bootstrap = secret_file(args.pair_token_file)
        if bootstrap.startswith('{'):
            bootstrap = json.loads(bootstrap)['token']
        result = ok(client.request('POST', '/v1/pair', {'deviceId': config['deviceId'], 'token': bootstrap}, auth='missing'))
        token = result['token']
        if not isinstance(token, str) or not token or len(token) > 16384 or '\n' in token or '\r' in token:
            raise ValueError('Invalid isolated pairing response')
        fd = os.open(str(Path(config['tokenFile']).expanduser()), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(token + '\n')
        client.token = token
    else:
        client = Client(config)
    suite = Suite(client, config, args)
    try:
        suite.run()
    finally:
        Path(args.report).write_text(json.dumps({'scope': 'real HTTPS protocol; not GUI target acceptance', 'runId': suite.session, 'startTime': suite.started_at, 'certificateSha256': config['certificateSha256'], 'results': suite.results}, ensure_ascii=False, indent=2) + '\n')
    return int(any(result['status'] == 'FAIL' for result in suite.results))


if __name__ == '__main__':
    raise SystemExit(main())
