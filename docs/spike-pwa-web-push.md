# Spike: PWA Web Push Notifications for Agent Events

## Executive Summary

This spike investigates adding Web Push notifications to the VK PWA so that users receive
browser-native push notifications when agent events occur (task complete, approval needed,
execution failed). The notification fires at the same points where desktop sound/OS notifications
currently fire via `NotificationService::notify`.

**Verdict: Feasible.** All components exist. The main risk is iOS subscription reliability.

---

## 1. `web-push` Crate Assessment

### Build Status
- **Compiles cleanly.** Tested `web-push = "0.10.4"` in a standalone project with `rustc 1.93.0-nightly`.
- **Latest version:** `0.11.0` is available on crates.io — worth checking for updated deps.

### API Surface
The crate provides everything needed:

| Feature | Support |
|---------|---------|
| VAPID key loading (PEM, DER, base64) | `VapidSignatureBuilder::from_pem()`, `from_der()`, `from_base64()` |
| Reusable key handle | `PartialVapidSignatureBuilder` (Clone, bind per-subscription) |
| Public key export | `get_public_key()` → `Vec<u8>` (uncompressed P-256 point) |
| Subscription info | `SubscriptionInfo { endpoint, keys: { p256dh, auth } }` — directly deserializable from browser JSON |
| Payload encryption | RFC 8188 AES-128-GCM via `ece` crate |
| HTTP status handling | 410 Gone → `EndpointNotValid`, 404 → `EndpointNotFound` |
| Content encoding | `Aes128Gcm` (modern) + `AesGcm` (legacy) |
| TTL, Urgency, Topic headers | Supported |

### Dependency Conflicts

| Dep | Server uses | web-push 0.10 uses | Impact |
|-----|------------|---------------------|--------|
| `http` | **v1.4.0** (axum 0.8) | **v0.2.12** | Two copies compiled. No interop needed since web-push is self-contained. |
| `base64` | v0.22 | v0.13 | Minor duplication |

These are **not build-breaking** — Cargo compiles both versions. The web-push types stay internal.

### HTTP Client Recommendation

The default `isahc-client` feature pulls in libcurl (heavy). **Recommended approach:**

```toml
web-push = { version = "0.10", default-features = false }
```

Then use `web-push::request_builder::build_request()` + `parse_response()` (both are public and
generic over body type) with the project's existing `reqwest` client. This avoids pulling in isahc
*or* hyper 0.14. Example:

```rust
let message = builder.build()?;
let request = web_push::request_builder::build_request::<Vec<u8>>(message);
// Convert http 0.2 Request → reqwest Request manually (endpoint, headers, body)
let resp = reqwest_client.post(endpoint).headers(headers).body(body).send().await?;
let status = resp.status();
let body = resp.bytes().await?;
web_push::request_builder::parse_response(
    http02::StatusCode::from_u16(status.as_u16()).unwrap(),
    body.to_vec(),
)?;
```

---

## 2. Trigger Points (Where Sound Currently Plays)

Notifications are triggered **server-side** via `NotificationService::notify(title, message)`.
Two call sites exist today:

| Trigger | Location | Event |
|---------|----------|-------|
| **Workspace completion** | `crates/services/src/services/container.rs:253` | Coding agent process completes or fails (not killed) |
| **Approval needed** | `crates/services/src/services/approvals/executor_approvals.rs:69` | Tool requires user approval |

`NotificationService` already branches on `config.sound_enabled` and `config.push_enabled`:

```rust
// crates/services/src/services/notification.rs:29-37
async fn send_notification(config: &NotificationConfig, title: &str, message: &str) {
    if config.sound_enabled {
        Self::play_sound_notification(&config.sound_file).await;
    }
    if config.push_enabled {
        Self::send_push_notification(title, message).await;  // ← currently OS-native only
    }
}
```

**Web Push fits here perfectly** — add a third branch `Self::send_web_push(title, message).await`
inside `send_notification`, or replace the current `send_push_notification` (which sends OS-native
toasts) to also fan out to Web Push subscriptions.

---

## 3. Service Worker & Vite Build Pipeline

### Current State
- **No service worker exists** in the codebase
- **No PWA plugins** in package.json (no `vite-plugin-pwa`, no workbox)
- **Manifest exists:** `frontend/public/site.webmanifest` with `display: standalone` (required for iOS)
- **Vite config** has no special SW handling (`frontend/vite.config.ts`)

### Recommended Approach: Static `sw.js` in `frontend/public/`

Files in `frontend/public/` are served as-is at the root by Vite (dev) and copied to `dist/` at
build time. A `frontend/public/sw.js` will be available at `/sw.js` — no plugin needed.

```js
// frontend/public/sw.js
self.addEventListener('push', (event) => {
  const data = event.data?.json() ?? {};
  const title = data.title || 'Vibe Kanban';
  const options = {
    body: data.body || '',
    icon: '/favicon-vk-light.svg',
    badge: '/favicon-vk-light.svg',
    tag: data.tag || 'vk-notification',
    data: { url: data.url || '/' },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = event.notification.data?.url || '/';
  event.waitUntil(clients.openWindow(url));
});
```

**Dev proxy note:** The Vite dev server proxies `/api/*` to the backend. The `/sw.js` file is served
directly by Vite from `public/`, so no proxy config needed. In production, the Rust backend serves
the built frontend assets (including `sw.js`) from the embedded dist.

### Frontend Registration (minimal)

```typescript
// In a hook or context, e.g. usePushNotifications.ts
async function subscribeToPush(vapidPublicKey: string) {
  const reg = await navigator.serviceWorker.register('/sw.js');
  const sub = await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(vapidPublicKey),
  });
  await fetch('/api/push/subscribe', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(sub.toJSON()),
  });
}
```

---

## 4. DB Migration Assessment

### Current Migration System
- **Engine:** SQLite
- **Location:** `crates/db/migrations/`
- **Naming convention:** `YYYYMMDDHHMMSS_description.sql` (e.g., `20260203000000_add_archive_script_to_repos.sql`)
- **69 migrations** exist
- **ID columns:** BLOB (UUIDs stored as 16-byte blobs)
- **Timestamps:** TEXT with `datetime('now', 'subsec')` default

### Proposed Migration: `20260222000000_add_web_push_tables.sql`

```sql
-- VAPID key pair, generated once on first server start
CREATE TABLE push_vapid_keys (
    id         BLOB PRIMARY KEY,
    public_key BLOB NOT NULL,     -- 65-byte uncompressed P-256 public key
    private_key BLOB NOT NULL,    -- 32-byte P-256 private key (or PEM TEXT)
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
);

-- Browser push subscriptions
CREATE TABLE push_subscriptions (
    id           BLOB PRIMARY KEY,
    endpoint     TEXT NOT NULL,
    p256dh       TEXT NOT NULL,     -- base64url-encoded
    auth         TEXT NOT NULL,     -- base64url-encoded
    created_at   TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
    UNIQUE(endpoint)               -- one subscription per browser endpoint
);

CREATE INDEX idx_push_subscriptions_endpoint ON push_subscriptions(endpoint);
```

**Design notes:**
- `push_vapid_keys` will have exactly one row. A table (vs config) keeps it in the DB migration
  flow and avoids mixing with the JSON config system.
- `workspace_id` column on subscriptions is **omitted for v1** — all subscriptions receive all
  notifications. Can be added later for per-workspace filtering.
- `UNIQUE(endpoint)` prevents duplicate subscriptions from the same browser.

---

## 5. iOS Compatibility & Platform Matrix

### Browser Support

| Platform | Min Version | Notes |
|----------|------------|-------|
| Chrome Desktop | 50+ | Full support |
| Firefox Desktop | 44+ | Full support |
| Safari macOS | 16.1+ (full: 18.0+) | Standard Web Push |
| Safari iOS | **16.4+** | **Home Screen PWA only** |
| Chrome/Firefox Android | Current | Full support |
| Edge | 17+ | Full support |

### iOS-Specific Requirements & Gotchas

1. **Home Screen install required** — in-browser Safari does NOT support push
2. **`display: "standalone"` in manifest** — already set in `site.webmanifest` ✓
3. **User gesture required** — `Notification.requestPermission()` must be called from a tap handler
4. **VAPID subject must be strictly formatted** — `mailto:user@example.com` (no spaces, no brackets). Apple's `web.push.apple.com` returns `403 BadJwtToken` otherwise
5. **Payload size limit: 2 KB** (vs 4 KB on Chrome/Firefox) — keep payloads small
6. **`userVisibleOnly: true`** required — no silent push on any platform
7. **No Apple Developer account needed** — standard VAPID self-hosting works
8. **No `pushsubscriptionchange` event on Safari** — can't auto-recover from subscription loss

### Known iOS Reliability Issues (Risk)

- Subscriptions silently become invalid after device restarts or time
- Notifications may stop after 3-4 deliveries (reported on Apple Developer Forums)
- No programmatic way to detect subscription invalidation client-side
- **Mitigation:** Handle 410 Gone server-side (remove stale subscriptions), implement client-side
  re-subscription on app focus, prompt users to re-enable if subscription appears dead

### Declarative Web Push (iOS 18.4+, Future)

Safari 18.4 introduces Declarative Web Push — no service worker required. Payload format:
```json
{
  "web_push": 8030,
  "notification": {
    "title": "Task Complete",
    "body": "Your coding task finished successfully",
    "navigate": "/workspace/123"
  }
}
```
This is a future optimization. For now, the standard SW-based approach covers iOS 16.4+ through
current versions.

---

## 6. Proposed API Surface

### REST Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/push/vapid-public-key` | Returns `{ "publicKey": "<base64url>" }` |
| `POST` | `/api/push/subscribe` | Store subscription. Body: `{ "endpoint", "keys": { "p256dh", "auth" } }` |
| `DELETE` | `/api/push/subscribe` | Remove subscription. Body: `{ "endpoint" }` |

### Internal Service

```rust
pub struct WebPushService {
    vapid_builder: PartialVapidSignatureBuilder,  // Cloneable, holds VAPID private key
    db_pool: SqlitePool,
    http_client: reqwest::Client,
}

impl WebPushService {
    /// Initialize: load or generate VAPID keys
    pub async fn init(pool: &SqlitePool) -> Result<Self>;

    /// Send push to all active subscriptions. Removes stale ones (410 Gone).
    pub async fn send(&self, event: PushEvent);
}

pub struct PushEvent {
    pub title: String,
    pub body: String,
    pub tag: Option<String>,    // For notification dedup/replacement
    pub url: Option<String>,    // Deep link on click
}
```

### Push Payload Format (SW receives this)

```json
{
  "title": "Task Complete: Fix login bug",
  "body": "✅ Completed successfully\nBranch: vk/fix-login\nExecutor: claude_code",
  "tag": "workspace-<id>",
  "url": "/workspace/<id>"
}
```

Keep total JSON under **2 KB** (Safari limit).

---

## 7. Integration Point

The change to `NotificationService` is minimal:

```rust
// notification.rs — updated send_notification
async fn send_notification(config: &NotificationConfig, title: &str, message: &str) {
    if config.sound_enabled {
        Self::play_sound_notification(&config.sound_file).await;
    }
    if config.push_enabled {
        Self::send_push_notification(title, message).await;  // OS-native toast
    }
    // NEW: Web Push — always attempt if subscriptions exist
    if let Some(web_push) = &self.web_push_service {
        web_push.send(PushEvent {
            title: title.to_string(),
            body: message.to_string(),
            tag: None,
            url: None,
        }).await;
    }
}
```

Web Push is independent of the `push_enabled` config flag (which controls OS-native toasts).
A separate frontend toggle or the existing `push_enabled` flag can gate it — TBD during implementation.

---

## 8. Implementation Checklist

1. **DB migration** — `push_vapid_keys` + `push_subscriptions` tables
2. **VAPID key lifecycle** — Generate on first boot, persist in DB, load on subsequent boots
3. **`WebPushService`** — Rust service wrapping `web-push` crate + reqwest adapter
4. **API routes** — `GET /api/push/vapid-public-key`, `POST/DELETE /api/push/subscribe`
5. **Service worker** — `frontend/public/sw.js` (push handler + notification click)
6. **Frontend hook** — `usePushNotifications` — register SW, subscribe, POST to backend
7. **Settings UI** — Toggle in notification settings (alongside existing sound toggle)
8. **Integration** — Wire `WebPushService` into `NotificationService`
9. **Stale subscription cleanup** — Handle 410 Gone, optionally periodic sweep

---

## 9. Open Questions

1. **Should Web Push reuse `push_enabled` config flag or get its own toggle?** Recommendation: own
   toggle (`web_push_enabled`) since OS toasts and browser push are distinct channels.
2. **Per-workspace subscriptions?** v1 skips this (all subscriptions get all notifications).
   Can add `workspace_id` column later.
3. **`web-push` v0.11 vs v0.10?** Check if v0.11 updates `http` to v1.x — would eliminate the
   duplicate dependency.
4. **Rate limiting push sends?** If many subscriptions exist, batch sends with concurrency limit.
5. **VAPID subject email?** Needs a configurable `mailto:` for the VAPID JWT `sub` claim.
   Could default to `mailto:noreply@localhost` for local installs.

---

## References

- [pimeys/rust-web-push](https://github.com/pimeys/rust-web-push) — Rust web-push crate
- [Can I Use: Push API](https://caniuse.com/push-api) — Browser compatibility
- [WebKit: Meet Declarative Web Push](https://webkit.org/blog/16535/meet-declarative-web-push/) — Safari 18.4+
- [Isala: Push Notifications Without Firebase](https://isala.me/blog/web-push-notifications-without-firebase/) — Self-hosted VAPID
- [Apple Forums: PWA Push Issues](https://developer.apple.com/forums/thread/728796) — iOS reliability issues
- [Firebase SDK #8010: iOS Unregisters Spontaneously](https://github.com/firebase/firebase-js-sdk/issues/8010) — Subscription loss
