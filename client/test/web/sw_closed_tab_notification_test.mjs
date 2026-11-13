import assert from 'node:assert/strict';
import test from 'node:test';

/**
 * Executes the owned service worker (Plan 174d) with no browser and no visible
 * client, for every payload shape the product actually sends.
 *
 * The worker is imported as source, so what runs here is the file the build
 * copies. Nothing in this harness stands in for the product's own payloads:
 * each shape below is written to match the Agent instruction contract
 * (`docs/technical/communication_protocols.md` §7.2) or the Client's own
 * presentation payload.
 */

const SESSION = 'session-1';
const REQUEST = 'request-1';
const TITLE = 'Review the local changes';
const BODY = 'Approval requested: shell_execute: git status';

const listeners = new Map();
const shown = [];
const opened = [];
const closedTags = [];
const consoleMessages = [];
const liveNotifications = new Map();
let windows = [];

globalThis.self = globalThis;
self.addEventListener = (type, listener) => listeners.set(type, listener);
self.skipWaiting = () => {};
self.clients = {
  async matchAll() {
    return windows;
  },
  async openWindow(url) {
    opened.push(url);
  },
};
self.registration = {
  scope: 'https://app.test/',
  async showNotification(title, options) {
    shown.push({title, options});
    liveNotifications.set(options.tag, {
      tag: options.tag,
      close() {
        closedTags.push(options.tag);
      },
    });
  },
  async getNotifications(filter = {}) {
    if (filter.tag) {
      const found = liveNotifications.get(filter.tag);
      return found ? [found] : [];
    }
    return [...liveNotifications.values()];
  },
};
globalThis.caches = {
  async open() {
    return {
      async match() {
        return null;
      },
      async put() {},
    };
  },
};
// The worker's only diagnostic surface; captured so a copy leak is detectable.
for (const level of ['log', 'info', 'warn', 'debug']) {
  console[level] = (...args) => consoleMessages.push(args.map(String).join(' '));
}

await import('../../web/sw.js');

function reset() {
  shown.length = 0;
  opened.length = 0;
  closedTags.length = 0;
  consoleMessages.length = 0;
  liveNotifications.clear();
  windows = [];
}

async function dispatch(type, event) {
  const pending = [];
  listeners.get(type)({...event, waitUntil: (promise) => pending.push(promise)});
  await Promise.all(pending);
}

async function push(payload) {
  await dispatch('push', {data: {text: () => JSON.stringify(payload)}});
}

async function click(notificationData) {
  await dispatch('notificationclick', {
    notification: {data: notificationData, close() {}},
    action: '',
  });
}

/** The Agent instruction block: the shape both wrappers carry. */
function instruction({sessionId = SESSION, requestId = REQUEST, kind = 'permission_request', urgency = 'high'} = {}) {
  return {
    instruction: 'dispatch',
    step: 'origin',
    event_id: 'evt-ask-1',
    request_id: requestId,
    kind,
    urgency,
    target: {scope: 'client_instance', client_instance_id: 'client-1'},
    locale: 'en',
    title: TITLE,
    body: BODY,
    actions: [
      {id: 'allow_once', label: 'Allow once'},
      {id: 'deny', label: 'Deny'},
    ],
    deep_link: {
      session_id: sessionId,
      ...(requestId == null ? {} : {request_id: requestId}),
    },
    collapse_key: `${sessionId}:${kind}`,
    created_at: '2026-11-13T10:00:00.000Z',
    expires_at: '2099-01-01T00:00:00.000Z',
  };
}

/** The family `device_event` envelope: top-level identity plus a nested block. */
function familyEnvelope(block = instruction(), {envelopeSessionId = SESSION} = {}) {
  return {
    event: 'notification.dispatch',
    event_id: 'evt-instruction-1',
    delivery: {scope: 'platform_family', platform_family: 'sanad_client'},
    ...(envelopeSessionId == null ? {} : {session_id: envelopeSessionId}),
    payload: {
      protocol: 'sanad.notification',
      version: 1,
      ...(envelopeSessionId == null ? {} : {session_id: envelopeSessionId}),
      notification: block,
    },
  };
}

/** The documented transport body: the Agent payload as the relay carries it. */
function transportBody(block = instruction(), {bodySessionId = SESSION} = {}) {
  return {
    protocol: 'sanad.notification',
    version: 1,
    ...(bodySessionId == null ? {} : {session_id: bodySessionId}),
    notification: block,
  };
}

/** The Client's own presentation payload, flat and with no envelope. */
function presentationPayload({sessionId = SESSION, requestId = REQUEST} = {}) {
  return {
    v: 1,
    event_id: 'evt-ask-1',
    kind: 'permission_request',
    urgency: 'high',
    session_id: sessionId,
    ...(requestId == null ? {} : {request_id: requestId}),
    collapse_key: `${sessionId}:permission_request`,
    title: TITLE,
    body: BODY,
    actions: [],
  };
}

/** The same derivation as `NotificationCollapseKey.notificationId`. */
function notificationId(collapseKey) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < collapseKey.length; index += 1) {
    hash ^= collapseKey.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash & 0x7fffffff;
}

const expectedTag = String(notificationId(`ask\u0000${SESSION}\u0000permission_request`));

function openedUrl() {
  assert.equal(opened.length, 1, 'the click must open exactly one window');
  return new URL(opened[0]);
}

function assertOpensTarget(url, {requestId = REQUEST} = {}) {
  assert.equal(url.origin, 'https://app.test');
  assert.equal(url.searchParams.get('sanad_session_id'), SESSION);
  if (requestId == null) {
    assert.equal(url.searchParams.has('sanad_request_id'), false);
  } else {
    assert.equal(url.searchParams.get('sanad_request_id'), requestId);
  }
}

function assertNoCopyLogged() {
  const leaked = consoleMessages.filter(
    (message) => message.includes(TITLE) || message.includes(BODY),
  );
  assert.deepEqual(leaked, [], 'the worker must never log notification copy');
}

test('the family device_event envelope raises one notification and opens its session', async () => {
  reset();
  const envelope = familyEnvelope();

  await push(envelope);

  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, TITLE);
  assert.equal(shown[0].options.body, BODY);
  assert.equal(shown[0].options.tag, expectedTag);
  assert.equal(shown[0].options.requireInteraction, true, 'high urgency keeps the banner');

  await click({envelope});

  assertOpensTarget(openedUrl());
  assertNoCopyLogged();
});

test('the documented transport body raises one notification and opens its session', async () => {
  reset();
  const body = transportBody();

  await push(body);

  assert.equal(shown.length, 1);
  assert.equal(shown[0].options.tag, expectedTag);

  await click({envelope: body});

  assertOpensTarget(openedUrl());
  assertNoCopyLogged();
});

test('the bare instruction raises one notification and opens its session', async () => {
  reset();
  const bare = instruction();
  assert.equal(bare.session_id, undefined, 'the block really has no sibling identity');

  await push(bare);

  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, TITLE);
  assert.equal(shown[0].options.tag, expectedTag);

  await click({envelope: bare});

  assertOpensTarget(openedUrl());
  assertNoCopyLogged();
});

test('a payload that carries only deep_link identity still resolves', async () => {
  reset();
  const envelope = familyEnvelope(instruction(), {envelopeSessionId: null});
  assert.equal(envelope.session_id, undefined);
  assert.equal(envelope.payload.session_id, undefined);

  await push(envelope);

  assert.equal(shown.length, 1, 'the deep link is the session identity');
  assert.equal(shown[0].options.tag, expectedTag);

  await click({envelope});

  assertOpensTarget(openedUrl());
});

test('a notification with no request opens the session without a request', async () => {
  reset();
  const bare = instruction({kind: 'completed', requestId: null});

  await push(bare);

  assert.equal(shown.length, 1);
  assert.equal(shown[0].options.tag, String(notificationId(`ask\u0000${SESSION}\u0000completed`)));

  await click({envelope: bare});

  assertOpensTarget(openedUrl(), {requestId: null});
});

test('a page-raised presentation payload opens its own session', async () => {
  reset();

  await click({payload: JSON.stringify(presentationPayload())});

  assertOpensTarget(openedUrl());
});

test('an unknown kind is never displayed', async () => {
  reset();

  await push(familyEnvelope(instruction({kind: 'connection_lost'})));
  await push(transportBody(instruction({kind: 'task_progress'})));

  assert.equal(shown.length, 0);
  assert.equal(opened.length, 0);
});

test('an expired instruction is never displayed', async () => {
  reset();
  const expired = instruction();
  expired.expires_at = '2020-01-01T00:00:00.000Z';

  await push(familyEnvelope(expired));
  await push(transportBody(expired));
  await push(expired);

  assert.equal(shown.length, 0);
});

test('a withdrawal closes the notification instead of raising one', async () => {
  reset();
  await push(familyEnvelope());
  assert.equal(shown.length, 1);

  const withdrawal = instruction();
  withdrawal.instruction = 'withdraw';
  withdrawal.reason = 'resolved';
  delete withdrawal.title;
  delete withdrawal.body;

  await push(familyEnvelope(withdrawal));
  assert.equal(shown.length, 1, 'a withdrawal never raises a banner');
  assert.deepEqual(closedTags, [expectedTag]);

  const bareWithdrawal = {...withdrawal};
  await push(bareWithdrawal);
  assert.deepEqual(closedTags, [expectedTag, expectedTag]);
});

test('a visible tab receives the wake-up and shows nothing', async () => {
  reset();
  const received = [];
  windows = [
    {
      url: 'https://app.test/#/chat',
      visibilityState: 'visible',
      postMessage(message) {
        received.push(message);
      },
    },
  ];

  await push(familyEnvelope());
  await push(transportBody());
  await push(instruction());

  assert.equal(shown.length, 0, 'the page is authoritative while it is visible');
  assert.equal(received.length, 3);
  assert.equal(received[0].type, 'sanad.push');
  assert.equal(received[2].envelope.kind, 'permission_request');
});

test('an explicit low urgency does not force the banner to stay', async () => {
  reset();

  await push(familyEnvelope(instruction({urgency: 'low'})));

  assert.equal(shown.length, 1);
  assert.equal(shown[0].options.requireInteraction, false);
});
