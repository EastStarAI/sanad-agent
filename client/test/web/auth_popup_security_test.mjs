import assert from 'node:assert/strict';
import test from 'node:test';

const listeners = new Map();
const popup = {
  closed: false,
  focus() {},
  close() { this.closed = true; },
};

globalThis.window = {
  location: {origin: 'https://app.test'},
  screen: {width: 1440, height: 900},
  addEventListener(type, listener) { listeners.set(type, listener); },
  open() { return popup; },
};

await import('../../web/auth_popup.js');

function send({source = popup, origin = 'https://portal.test', data}) {
  listeners.get('message')({source, origin, data});
}

test('accepts only the exact popup source and Portal origin, once', () => {
  window.AuthPopup.openPopup('https://portal.test/authorize', 'sanad-auth', '');

  send({
    source: {},
    data: {type: 'sanad_authorization_code', code: 'wrong-source', state: 'tx'},
  });
  assert.equal(window.AuthPopup.takeAuthorizationMessage(), null);

  send({
    origin: 'https://attacker.test',
    data: {type: 'sanad_authorization_code', code: 'wrong-origin', state: 'tx'},
  });
  assert.equal(window.AuthPopup.takeAuthorizationMessage(), null);

  send({
    data: {type: 'unexpected', code: 'wrong-type', state: 'tx'},
  });
  assert.equal(window.AuthPopup.takeAuthorizationMessage(), null);

  send({
    data: {type: 'sanad_authorization_code', code: 'bound-code', state: 'tx-1'},
  });
  assert.deepEqual(
    JSON.parse(window.AuthPopup.takeAuthorizationMessage()),
    {code: 'bound-code', state: 'tx-1'},
  );
  assert.equal(window.AuthPopup.takeAuthorizationMessage(), null);
});

test('opening a fresh transaction clears any pending callback', () => {
  window.AuthPopup.openPopup('https://portal.test/authorize', 'sanad-auth', '');
  send({
    data: {type: 'sanad_authorization_code', code: 'stale-code', state: 'old-tx'},
  });
  window.AuthPopup.openPopup('https://portal.test/authorize', 'sanad-auth', '');
  assert.equal(window.AuthPopup.takeAuthorizationMessage(), null);
});
