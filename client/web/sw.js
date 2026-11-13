'use strict';

/**
 * Sanad web notification service worker (Plan 174d).
 *
 * Ownership: this file is the only service worker the Sanad web build
 * registers. Flutter 3.47 generates `flutter_service_worker.js` as a
 * self-unregistering tombstone with no offline cache, so the push listener is
 * owned here instead of patched into generated output. See
 * docs/technical/web_push_delivery.md for the decision and its offline
 * consequences.
 *
 * Two laws govern this file:
 * 1. While a Sanad tab is visible, the page is authoritative: the worker only
 *    forwards the canonical envelope and shows nothing. The page decides with
 *    the same display policy it uses for socket delivery.
 * 2. With no visible tab, the notification is rendered from the payload alone:
 *    the Agent already redacted and localized it, so the worker never invents
 *    copy and never reads conversation state.
 */

const CACHE_NAME = 'sanad-web-push-v1';
const POLICY_URL = '/__sanad_web_push_policy';
const CLICK_MESSAGE = 'sanad.notification-click';
const PUSH_MESSAGE = 'sanad.push';
const SUBSCRIPTION_CHANGED_MESSAGE = 'sanad.subscription-changed';

/** The notification kinds the Agent owns; an unknown kind is not displayed. */
const KNOWN_KINDS = new Set([
  'permission_request',
  'user_question',
  'blocked',
  'failed',
  'completed',
  'background_task_done',
  'scheduled_result',
  'provider_quota',
]);

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Legacy Flutter offline workers cached the app shell. This worker does
    // not, so the old caches are removed instead of left to serve stale assets.
    try {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => name !== CACHE_NAME && name.startsWith('flutter'))
          .map((name) => caches.delete(name)),
      );
    } catch (error) {
      console.warn('Sanad worker could not clear legacy caches:', error);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('push', (event) => {
  event.waitUntil(handlePush(event));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(handleNotificationClick(event));
});

/**
 * The browser may rotate the push endpoint. Re-subscribe with the same VAPID
 * key and hand the new endpoint to an open page, which owns the authenticated
 * registration. With no open page the next startup re-registers the endpoint.
 */
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(handleSubscriptionChange(event));
});

async function handlePush(event) {
  const data = readPushData(event.data);
  if (data == null) return;

  const notification = notificationBlock(data);
  if (notification == null) return;

  const instruction = readString(notification.instruction) || 'dispatch';
  const { sessionId } = readTarget(data, null);
  const kind = readString(notification.kind);
  const tag = sessionId && kind ? tagForNotification(notification, sessionId, kind) : null;

  if (instruction === 'withdraw') {
    if (tag != null) await closeByTag(tag);
    return;
  }

  if (sessionId == null || kind == null || !KNOWN_KINDS.has(kind)) return;
  if (isExpired(notification.expires_at)) return;

  const policy = await readDisplayPolicy();
  if (policy != null && (policy.enabled === false || muted(policy, kind))) return;

  const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const visible = clients.filter((client) => client.visibilityState === 'visible');
  if (visible.length > 0) {
    // Foreground authority: a wake-up, not a notification.
    for (const client of visible) {
      client.postMessage({ type: PUSH_MESSAGE, envelope: data });
    }
    return;
  }

  const title = readString(notification.title);
  const body = readString(notification.body);
  if (title == null && body == null) return;

  // No action buttons: browsers cap the set differently, so a three-way
  // approval cannot be shown without hiding a decision. The banner wakes the
  // user and the click opens the exact session, where the in-app prompt owns
  // the decision.
  const options = {
    body: body || '',
    tag: tag || `sanad:${sessionId}:${kind}`,
    renotify: false,
    // Every Agent kind is high urgency, and the browser decides whether it can
    // honour that: a browser without `requireInteraction` ignores the field, so
    // the banner stays as urgent as the platform allows and never invents a
    // quieter default.
    requireInteraction: isInterruptive(notification.urgency),
    data: { envelope: data },
  };

  try {
    await self.registration.showNotification(title || 'Sanad', options);
  } catch (error) {
    console.warn('Sanad worker could not show a notification:', error);
  }
}

async function handleNotificationClick(event) {
  const data = asObject(event.notification.data) || {};
  const envelope = asObject(data.envelope);
  const presented = asObject(data.payload);
  const actionId = typeof event.action === 'string' && event.action.length > 0
    ? event.action
    : null;
  const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });

  if (clients.length > 0) {
    const client = clients.find((candidate) => candidate.url.startsWith(self.registration.scope)) || clients[0];
    try {
      await client.focus();
    } catch (error) {
      console.warn('Sanad worker could not focus a window:', error);
    }
    client.postMessage({
      type: CLICK_MESSAGE,
      envelope: envelope,
      payload: data.payload || null,
      action: actionId,
    });
    return;
  }

  // No page to receive an action. The app is opened at the exact session and
  // the user answers in context; a notification action is never replayed from a
  // URL, because a URL is not proof that the user pressed the button.
  const target = readTarget(envelope, presented);
  const url = new URL(self.registration.scope);
  if (target.sessionId != null) {
    url.searchParams.set('sanad_session_id', target.sessionId);
    if (target.requestId != null) url.searchParams.set('sanad_request_id', target.requestId);
  }
  await self.clients.openWindow(url.toString());
}

async function handleSubscriptionChange(event) {
  const previous = event.oldSubscription;
  const applicationServerKey = previous && previous.options && previous.options.applicationServerKey;
  if (!applicationServerKey) return;

  let subscription;
  try {
    subscription = await self.registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey,
    });
  } catch (error) {
    console.warn('Sanad worker could not refresh the push subscription:', error);
    return;
  }

  const serialized = {
    endpoint: subscription.endpoint,
    keys: {
      p256dh: arrayBufferToBase64(subscription.getKey('p256dh')),
      auth: arrayBufferToBase64(subscription.getKey('auth')),
    },
  };
  const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  for (const client of clients) {
    client.postMessage({ type: SUBSCRIPTION_CHANGED_MESSAGE, subscription: serialized });
  }
}

/**
 * The browser reports the identity of the notification the user clicked, which
 * must be the same identity the page used when it raised the notification. The
 * page derives it from the Client collapse key with FNV-1a; this mirrors that
 * derivation exactly so replacement works across both raisers.
 */
function tagForNotification(notification, sessionId, kind) {
  const candidate = readString(notification.collapse_key);
  const canonical = `ask\u0000${sessionId}\u0000${kind}`;
  return String(notificationId(candidate === canonical ? candidate : canonical));
}

function notificationId(collapseKey) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < collapseKey.length; index += 1) {
    hash ^= collapseKey.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash & 0x7fffffff;
}

async function closeByTag(tag) {
  try {
    const notifications = await self.registration.getNotifications({ tag });
    for (const notification of notifications) notification.close();
  } catch (error) {
    console.warn('Sanad worker could not withdraw a notification:', error);
  }
}

async function readDisplayPolicy() {
  try {
    const cache = await caches.open(CACHE_NAME);
    const response = await cache.match(POLICY_URL);
    if (!response) return null;
    return await response.json();
  } catch (_) {
    return null;
  }
}

function muted(policy, kind) {
  return Array.isArray(policy.muted_kinds) && policy.muted_kinds.includes(kind);
}

function readPushData(data) {
  if (!data) return null;
  try {
    const parsed = JSON.parse(data.text());
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (_) {
    return null;
  }
}

/** Accepts the canonical envelope and a bare notification payload. */
function notificationBlock(data) {
  if (!data || typeof data !== 'object') return null;
  const payload = data.payload;
  if (payload && typeof payload === 'object') {
    if (payload.notification && typeof payload.notification === 'object') return payload.notification;
    return payload;
  }
  if (data.notification && typeof data.notification === 'object') return data.notification;
  return data;
}

/**
 * The session and request a notification points at.
 *
 * Three shapes reach this worker, and each one carries its identity somewhere
 * else:
 * - the family `device_event` envelope: `session_id` beside a nested
 *   `payload.notification` block;
 * - the documented transport body: `session_id` beside its `notification`
 *   block;
 * - a bare instruction block: no sibling identity at all, only
 *   `deep_link.session_id`.
 *
 * The order mirrors the Client's `NotificationPayload.fromEvent`, so the page
 * and the worker open the same session for the same notification. Reading a
 * single sibling field made the closed-tab path silently do nothing for the
 * shapes the product actually sends.
 */
function readTarget(data, presented) {
  const block = notificationBlock(data);
  const payload = asObject(data && data.payload);
  const shown = asObject(presented);
  return {
    sessionId: firstString(
      deepLinkValue(block, 'session_id'),
      block && block.session_id,
      deepLinkValue(payload, 'session_id'),
      payload && payload.session_id,
      deepLinkValue(data, 'session_id'),
      data && data.session_id,
      shown && shown.session_id,
    ),
    requestId: firstString(
      deepLinkValue(block, 'request_id'),
      block && block.request_id,
      deepLinkValue(payload, 'request_id'),
      payload && payload.request_id,
      deepLinkValue(data, 'request_id'),
      data && data.request_id,
      shown && shown.request_id,
    ),
  };
}

function deepLinkValue(source, key) {
  const deepLink = asObject(source && source.deep_link);
  return deepLink && deepLink[key];
}

function firstString(...values) {
  for (const value of values) {
    const read = readString(value);
    if (read != null) return read;
  }
  return null;
}

/** A payload object, or the JSON string a page-raised notification stores. */
function asObject(value) {
  if (value && typeof value === 'object') return value;
  if (typeof value !== 'string') return null;
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (_) {
    return null;
  }
}

/**
 * Whether the Agent marked this notification as an interruption.
 *
 * Urgency is an attribute of the kind and every Agent kind defaults to high, so
 * an absent or unknown value keeps the product default rather than going quiet:
 * only an explicit `low` or `normal` lowers the banner.
 */
function isInterruptive(urgency) {
  const value = readString(urgency);
  if (value == null) return true;
  return value !== 'low' && value !== 'normal';
}

function isExpired(expiresAt) {
  const raw = readString(expiresAt);
  if (raw == null) return false;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) && parsed <= Date.now();
}

function readString(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function arrayBufferToBase64(buffer) {
  if (!buffer) return null;
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let index = 0; index < bytes.length; index += 1) {
    binary += String.fromCharCode(bytes[index]);
  }
  return self.btoa(binary);
}
