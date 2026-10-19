#!/usr/bin/env python3
"""v0.2 integration checks against a parent-approved isolated candidate only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
import uuid

from check_server import Client, Suite, ok, rejected

FIELDS = ('macToWindows', 'windowsToMac', 'text', 'image', 'file', 'paused')
DEFAULTS = {name: name != 'paused' for name in FIELDS}


class SettingsSuite(Suite):
    def settings(self):
        value = ok(self.client.request('GET', '/v1/settings'))
        assert type(value.get('revision')) is int and value['revision'] >= 1, 'Invalid settings revision'
        assert all(type(value.get(name)) is bool for name in FIELDS), 'Missing or nonboolean setting'
        return {key: value[key] for key in ('revision', *FIELDS)}

    def update(self, **changes):
        before = self.settings()
        request = {name: changes.get(name, before[name]) for name in FIELDS}
        request['expectedRevision'] = before['revision']
        after = ok(self.client.request('POST', '/v1/settings', request))
        assert after['revision'] == before['revision'] + 1, 'Successful update must increment revision exactly once'
        assert all(after[name] == request[name] for name in FIELDS), 'Update applied incomplete settings'
        assert self.settings() == after, 'POST/GET settings disagree'
        return after

    def connect(self):
        self.handshake = str(uuid.uuid4())
        self.hello()

    def authentication(self):
        before = self.settings()
        request = {'expectedRevision': before['revision'], **DEFAULTS}
        for auth in ('missing', 'invalid'):
            for method, body in (('GET', None), ('POST', request)):
                response = self.client.request(method, '/v1/settings', body, auth=auth)
                assert response[0] == 401, 'Unauthenticated settings request did not return 401'
                rejected(response, ('AUTH_FAILED',))
        assert self.settings() == before, 'Unauthenticated request changed settings'

    def missing_fields(self):
        before = self.settings()
        complete = {'expectedRevision': before['revision'], **{name: before[name] for name in FIELDS}}
        for field in complete:
            request = dict(complete)
            del request[field]
            response = self.client.request('POST', '/v1/settings', request)
            assert response[0] == 400, 'Missing field was not rejected with 400'
            rejected(response)
            assert self.settings() == before, 'Invalid request changed settings'

    def wrong_types(self):
        before = self.settings()
        complete = {'expectedRevision': before['revision'], **{name: before[name] for name in FIELDS}}
        for field in complete:
            for invalid in (None, 'true', [], {}):
                response = self.client.request('POST', '/v1/settings', dict(complete, **{field: invalid}))
                assert response[0] == 400, 'Wrong field type was not rejected with 400'
                rejected(response)
        for field, invalid in [('expectedRevision', True), ('expectedRevision', 1.5), ('text', 1)]:
            response = self.client.request('POST', '/v1/settings', dict(complete, **{field: invalid}))
            assert response[0] == 400, 'Boolean/integer trust boundary accepted wrong type'
            rejected(response)
        assert self.settings() == before, 'Wrong-type request changed settings'

    def conflict(self):
        before = self.settings()
        after = self.update(text=not before['text'])
        stale = {'expectedRevision': before['revision'], **{name: not after[name] for name in FIELDS}}
        response = self.client.request('POST', '/v1/settings', stale)
        assert response[0] == 409, 'Stale revision was not rejected with 409'
        rejected(response, ('SETTINGS_CONFLICT',))
        assert self.settings() == after, 'Stale request partially overwrote current settings'

    def simultaneous_updates(self):
        before = self.settings()
        common = {'expectedRevision': before['revision'], **{name: before[name] for name in FIELDS}}
        requests = [dict(common, text=not before['text']), dict(common, file=not before['file'])]
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda body: self.client.request('POST', '/v1/settings', body), requests))
        assert sum(200 <= status < 300 for status, _ in responses) == 1, 'Concurrent writes did not have exactly one winner'
        winner = next(body for status, body in responses if 200 <= status < 300)
        rejected(next(response for response in responses if response[0] == 409), ('SETTINGS_CONFLICT',))
        assert self.settings() == winner, 'Concurrent write leaked losing values'
        assert winner['revision'] == before['revision'] + 1, 'Concurrent write incremented revision twice'

    def pause_resume(self):
        self.update(**DEFAULTS)
        self.connect()
        old_epoch = self.client.epoch
        paused = self.update(paused=True)
        self.client.epoch = None  # GET and POST settings must work without a live epoch.
        assert self.settings() == paused, 'Paused settings are not readable'
        rejected(self.client.request('GET', '/v1/receiver-state', epoch=old_epoch))
        response = self.client.request('POST', '/v1/hello', {'protocolVersion': 1, 'deviceId': self.config['deviceId'],
                   'sourceSessionId': self.session, 'handshakeId': str(uuid.uuid4()), 'lastIssuedSourceSeq': self.seq})
        rejected(response)
        self.update(paused=False)
        self.connect()
        assert self.client.epoch != old_epoch, 'Resume reused revoked epoch'
        assert self.state().get('outgoing') is None, 'Resume replayed existing clipboard'

    def forward_direction(self):
        self.update(**dict(DEFAULTS, macToWindows=False))
        self.connect()
        rejected(self.client.request('POST', '/v1/head', self.head()), ('DIRECTION_DISABLED', 'SYNC_DISABLED'))
        self.update(macToWindows=True)
        self.connect()
        self.accepted(self.head())  # Positive control: service is functional, not generically rejecting.

    def disabled_type(self, kind):
        self.update(**dict(DEFAULTS, **{kind: False}))
        self.connect()
        head = self.head()
        self.accepted(head)
        data = b'CopyBridge generated nonpublication fixture'
        metadata = self.offer(head, data)
        metadata['kind'] = kind
        metadata['items'][0].update(name={'text': 'fixture.txt', 'image': 'fixture.png', 'file': 'fixture.bin'}[kind],
                                   mime={'text': 'text/plain', 'image': 'image/png', 'file': 'application/octet-stream'}[kind])
        rejected(self.client.request('POST', '/v1/offers', metadata), ('TYPE_DISABLED', 'SYNC_DISABLED'))
        # No fake PNG is uploaded or published; this case checks only rejection before payload acceptance.
        self.update(**{kind: True})
        self.connect()
        next_head = self.head()
        self.accepted(next_head)
        metadata.update(next_head)
        ok(self.client.request('POST', '/v1/offers', metadata), 'Offered')

    def settings_revoke_ready(self):
        self.update(**DEFAULTS)
        self.connect()
        data = b'CopyBridge ready candidate; must never publish'
        head = self.head()
        self.accepted(head, self.offer(head, data))
        ok(self.put(head, data), 'Ready')
        self.update(text=False)
        rejected(self.complete(head))
        self.connect()
        rejected(self.complete(head))  # A new header epoch must not revive an old task.

    def reverse_off_keeps_local_priority(self):
        self.update(**dict(DEFAULTS, windowsToMac=False))
        self.connect()
        old_head = self.head()
        old_generation = old_head['receiverGenAtCopy']
        self.local_copy()  # Uses parent-approved synthetic fixture only.
        state = self.state()
        assert state['receiverGeneration'] > old_generation, 'Reverse disabled also disabled local-copy protection'
        assert state.get('outgoing') is None, 'Reverse-disabled local copy still became an outgoing transfer'
        rejected(self.client.request('POST', '/v1/head', old_head), ('LOCAL_CLIPBOARD_CHANGED',))

    def persistence(self):
        desired = self.update(macToWindows=False, windowsToMac=True, text=False, image=True, file=False, paused=True)
        subprocess.run([self.args.restart_hook], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
        self.client.epoch = None
        deadline = time.monotonic() + 15
        while True:
            try:
                actual = self.settings()
                break
            except (OSError, ConnectionError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.3)
        assert actual == desired, 'Settings or revision did not persist across candidate restart'
        self.update(**DEFAULTS)
        self.connect()

    def run(self):
        self.run_case('settings-schema-without-epoch', lambda: setattr(self, 'initial_settings', self.settings()))
        if self.results[-1]['status'] != 'PASS':
            return
        original = self.initial_settings
        try:
            for name, method in [('settings-auth-before-read-write', self.authentication),
                                 ('settings-complete-fields-required', self.missing_fields),
                                 ('settings-strict-types', self.wrong_types),
                                 ('settings-stale-revision-is-atomic', self.conflict),
                                 ('settings-concurrent-writers-one-winner', self.simultaneous_updates),
                                 ('settings-paused-access-and-resume', self.pause_resume),
                                 ('settings-forward-direction-enforced', self.forward_direction),
                                 ('settings-change-revokes-ready-task', self.settings_revoke_ready)]:
                self.run_case(name, method)
            for kind in ('text', 'image', 'file'):
                self.run_case('settings-disabled-' + kind + '-rejected-before-upload', lambda kind=kind: self.disabled_type(kind))
            if self.args.local_copy_hook:
                self.run_case('settings-reverse-off-retains-local-copy-priority', self.reverse_off_keeps_local_priority)
            else:
                self.blocked('settings-reverse-off-retains-local-copy-priority', 'Parent-approved generated local-copy hook not supplied')
            if self.args.restart_hook:
                self.run_case('settings-persist-through-candidate-restart', self.persistence)
            else:
                self.blocked('settings-persist-through-candidate-restart', 'Parent-approved isolated candidate restart hook not supplied')
        finally:
            self.run_case('restore-original-isolated-settings', lambda: self.update(**{name: original[name] for name in FIELDS}))
        self.blocked('dual-client-paused-polling-and-settings-ui', 'Requires actual Mac client plus parent GUI acceptance; protocol alone cannot prove polling/UI')
        self.blocked('disk-write-failure-does-not-apply', 'Requires controlled isolated storage-failure fixture; no real disk exhaustion attempted')
        self.blocked('failed-pair-preserves-old-mac-config', 'Requires disposable paired candidate profile; no normal Keychain or profile touched')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--isolated-session', action='store_true')
    parser.add_argument('--local-copy-hook')
    parser.add_argument('--restart-hook')
    args = parser.parse_args()
    if not args.isolated_session:
        parser.error('--isolated-session required; this suite mutates settings and revokes candidate epochs')
    config = json.loads(Path(args.config).read_text())
    suite = SettingsSuite(Client(config), config, args)
    try:
        suite.run()
    finally:
        Path(args.report).write_text(json.dumps({'scope': 'v0.2 actual isolated server settings; not GUI/pairing acceptance',
             'runId': suite.session, 'startTime': suite.started_at, 'certificateSha256': config['certificateSha256'],
             'results': suite.results}, ensure_ascii=False, indent=2) + '\n')
    return int(any(item['status'] == 'FAIL' for item in suite.results))


if __name__ == '__main__':
    raise SystemExit(main())
