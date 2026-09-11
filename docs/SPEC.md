# Specification — Live Nifty Options Tracker

## 1. Mission

A Flutter (Android) app with three screens:

1. **Auth** — Google Sign-In, plus email/password register and login.
2. **Search** — find a Nifty option by strike / expiry / CE-PE.
3. **Detail** — live LTP, OI, Bid, Ask, Bid Qty, Ask Qty, Volume, and % change
   from previous close, updating as ticks arrive.

Both Search and Detail are rendered inside a single shared UI shell
(`template.dart`). The WebSocket subscription opens when Detail is entered and
closes cleanly when it is left.

Market data comes from **Angel One SmartAPI** (§3).

This is a read-only market data viewer. It never places orders.

## 2. Graded criteria

The reviewer stated they will assess:

| Criterion | Where it is satisfied |
|---|---|
| Auth works end to end, session persists | Phase 1 |
| Search works | Phase 2 |
| Live data actually streams and updates | Phases 3–4 |
| `template.dart` genuinely shared by both screens | Phase 2 |
| Auth logic separated from UI | Phase 1 |
| WebSocket handling isolated from widget code | Phase 3 |
| Dropped connections, empty search, invalid login, token expiry | Phase 5 |
| Readability over cleverness | Throughout |

Optimise for these. Do not build things outside them.

## 3. Broker API reference — Angel One SmartAPI

Broker: **Angel One**, SmartAPI — REST for auth and instruments, WebSocket 2.0 for
streaming. All market-data APIs are free of cost.

> Everything in this section was verified against the official `angel-one/smartapi-python`
> SDK source and a live fetch of the instrument master on 2026-09-09. **Phase 0 exists to
> confirm each fact empirically before any app code depends on it.** If reality contradicts
> this section, reality wins — update this file and note it in `docs/DECISIONS.md`.

### 3.1 Authentication

Angel One has **no long-lived analytics token**. Session tokens are obtained by logging in
with a TOTP code and expire at **05:00 IST the following day**. This is a materially
different trust model from a static credential and drives §5.6.

```
POST https://apiconnect.angelone.in/rest/auth/angelbroking/user/v1/loginByPassword
Body: { "clientcode": "...", "password": "<MPIN>", "totp": "<6 digits>" }
```

Returns three tokens, all of which matter:

| Token | Use |
|---|---|
| `jwtToken` | `Authorization: Bearer` on REST + WebSocket handshake |
| `refreshToken` | renewing the session without a fresh TOTP |
| `feedToken` | **WebSocket only** — the streaming handshake rejects a request without it |

Refresh: `POST /rest/auth/angelbroking/jwt/v1/generateTokens` with `jwtToken` +
`refreshToken`.

**The TOTP code is generated locally** from a base32 secret issued once in the SmartAPI
console. The secret lives in `.env` as `ANGEL_TOTP_SECRET` and is never logged or committed.

> **Security reality, state it plainly.** Unlike a read-only analytics token, these
> credentials authenticate a full trading account. The app is read-only by construction —
> it never calls a mutating endpoint — but the credential itself is not scoped read-only.
> This is the honest trade-off Angel One forces, and §6 Phase 6 requires it in the README.

Every authenticated REST request carries this header set:

```
Content-type:     application/json
Accept:           application/json
X-PrivateKey:     {api_key}          <- REQUIRED
X-UserType:       USER
X-SourceID:       WEB                <- REQUIRED
X-ClientLocalIP:  {any valid local IP}
X-ClientPublicIP: {any valid public IP}
X-MACAddress:     {any valid MAC}    <- REQUIRED
Authorization:    Bearer {jwtToken}  <- REQUIRED
```

**Measured in Phase 0 (2026-09-10), correcting an earlier claim that all nine are
required.** Dropping each header in turn against `getProfile` shows only **four** are
enforced — `X-PrivateKey`, `X-SourceID`, `X-MACAddress` and `Authorization`. The
gateway answers a missing one with HTTP 400 and `errorcode AB1012`,
`"Required header '<name>' is missing"`. The other five (`Content-type`, `Accept`,
`X-UserType`, `X-ClientLocalIP`, `X-ClientPublicIP`) are accepted when absent.

Note the error text for the MAC header names it `X-MACaddress`, with different casing
from the documented `X-MACAddress`; HTTP header names are case-insensitive, so this is
cosmetic, but it is a hint that the gateway's validation list is hand-maintained.

**Send all nine anyway.** The enforced set is undocumented and could widen without
notice, the cost is a few bytes per request, and matching the official SDK's behaviour
is the defensive choice. The value of knowing which four are load-bearing is
diagnostic: when a request 400s, these are the ones to check first.

The IP/MAC headers are not validated for correctness — only presence, and only for the
MAC. Send stable placeholders; do not attempt real device fingerprinting.

### 3.2 Instrument master (powers the search screen)

```
GET https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json
```

Unauthenticated. Refreshed daily at **~08:30 IST**. Element shape, verified live:

```json
{
  "token": "40672",
  "symbol": "NIFTY06OCT2622100PE",
  "name": "NIFTY",
  "expiry": "06OCT2026",
  "strike": "2210000.000000",
  "lotsize": "65",
  "instrumenttype": "OPTIDX",
  "exch_seg": "NFO",
  "tick_size": "5.000000",
  "freeze_qty": "1801",
  "is_cas_enabled": false
}
```

Filter to Nifty options with `instrumenttype == "OPTIDX" && name == "NIFTY" &&
exch_seg == "NFO"`. As of writing that is **1,588 contracts out of 145,599 instruments**.

Four parsing hazards, all of which the mapper must handle at the boundary:

1. **`strike` is in paise as a decimal string.** `"2210000.000000"` is ₹22,100. Divide
   by 100.
2. **`expiry` is `DDMMMYYYY`, not ISO.** `"06OCT2026"` needs manual parsing — `DateTime.parse`
   throws on it. Month abbreviations are uppercase English.
3. **Every numeric field is a string.** `lotsize`, `strike`, `tick_size` all arrive quoted.
4. **There is no CE/PE field.** Derive the option type from the `symbol` suffix — the last
   two characters are `CE` or `PE`.

**Why the whole file and not a per-expiry endpoint.** Angel One publishes no option-contract
endpoint equivalent to a filtered query; `searchScrip` searches by text but does not
enumerate a chain. The master file is the only complete source. It is **~32.5 MB of JSON**
(measured live 2026-09-09 in Phase 0; an earlier estimate of ~8 MB was wrong) — large
enough to matter on a phone, small enough to parse once and cache. **Parse it off the UI
isolate** (`compute()`); a synchronous 145k-element `jsonDecode` will visibly jank the frame.
Record this as a deliberate decision in `docs/DECISIONS.md`.

Cache locally, invalidate against the 08:30 IST boundary.

### 3.3 Market data WebSocket 2.0

```
wss://smartapisocket.angelone.in/smart-stream
```

**Handshake.** Four headers, all required:

```
Authorization: Bearer {jwtToken}
x-api-key:     {api_key}
x-client-code: {client_code}
x-feed-token:  {feedToken}
```

There is **no 302 redirect** — this connects directly, so no `HttpClient` redirect
workaround is needed. Dart's `WebSocket.connect` accepts custom headers natively.

**Subscribe.** Request frames are **JSON text** (not binary — responses are binary, requests
are not):

```json
{
  "correlationID": "<unique per request>",
  "action": 1,
  "params": {
    "mode": 3,
    "tokenList": [ { "exchangeType": 2, "tokens": ["40672"] } ]
  }
}
```

`action`: `1` = subscribe, `0` = unsubscribe.
`mode`: `1` = LTP, `2` = QUOTE, `3` = SNAP_QUOTE, `4` = DEPTH.
`exchangeType`: NSE_CM `1`, **NSE_FO `2`** (Nifty options), BSE_CM `3`, BSE_FO `4`,
MCX_FO `5`, NCX_FO `7`, CDE_FO `13`.

**Use `SNAP_QUOTE` (mode 3).** It is the only mode carrying open interest *and* the
best-bid/ask book *and* previous close. LTP mode has none of them; QUOTE has close but no OI
and no book. This is requirements-driven, not preference.

**Keepalive is the client's job.** Send the literal text `"ping"` every **10 seconds**. This
is mandatory and is the single most common cause of "socket dies" reports.

**Measured in Phase 0 (2026-09-10), refining two details:**

- **The idle timeout is 120 seconds, not ~60.** An unpinged socket was closed at
  t+120s with WebSocket close **code 1001** and reason **`"Connection Idle Timeout"`**.
  A pinged socket survived 180s with no interruption. The close reason is explicit,
  so this failure is diagnosable from the close frame — do not let it get logged as a
  generic disconnect.
- **The server DOES reply.** Each `"ping"` is answered with a text frame `"pong"`,
  and one arrives on connect before any ping is sent. The earlier note that "Angel One
  does not pong" was wrong. This is useful: §5.4 can treat a missing pong as a liveness
  signal well before the 120-second close, rather than waiting for the socket to drop.

Note that `"pong"` frames are **text**, while market data is **binary**. A decoder that
assumes every frame is a packet will try to parse `"pong"` as one — discriminate on
frame type, not on arrival.

**Limits:** 1,000 tokens per session. DEPTH mode is capped at 50 tokens and NSE_CM only —
irrelevant here, but do not reach for mode 4.

**Connections are rate-limited, and the rejection is indistinguishable from an auth
failure.** Measured in Phase 0 (2026-09-10): opening three sockets in quick succession
from one client gets the third refused with
`HttpException: Connection closed before full header was received` — the *same* error
class an unauthenticated handshake produces. There is no `429`, no `Retry-After`, and
no distinguishing message.

Two consequences for §5.4:

1. **Reconnect must back off exponentially from the first retry**, not after several
   failures. A tight retry loop is itself the thing keeping the socket shut, and it
   will look exactly like a credential problem.
2. **Never classify this error as fatal-auth.** Signing the user out, or discarding the
   broker session, on an error that is really throttling would turn a two-second delay
   into a full re-login. Treat "connection closed before full header" as *retryable*.

**No `market_info` message.** Angel One sends no segment-status frame, so market-open cannot
be read off the socket. Derive it from the clock instead (09:15–15:30 IST, weekdays) and
treat that as the watchdog gate in §5.4.

### 3.4 SNAP_QUOTE binary payload

**Responses are raw little-endian binary at fixed byte offsets. There is no Protobuf and no
generated decoder** — the mapper hand-parses a `ByteData`. This is the largest single
difference from the Upstox design and the reason §5.5 carries more weight here.

Use `ByteData.view(bytes.buffer)` with `Endian.little` on every read.

| Offset | Type | Field |
|---|---|---|
| 0–1 | uint8 | subscription mode |
| 1–2 | uint8 | exchange type |
| 2–27 | utf8 | token (null-padded, 25 bytes) |
| 27–35 | int64 | sequence number |
| 35–43 | int64 | exchange timestamp (ms) |
| 43–51 | int64 | **last traded price** |
| 51–59 | int64 | last traded quantity |
| 59–67 | int64 | average traded price |
| 67–75 | int64 | **volume traded today** |
| 75–83 | float64 | total buy quantity |
| 83–91 | float64 | total sell quantity |
| 91–99 | int64 | open |
| 99–107 | int64 | high |
| 107–115 | int64 | low |
| 115–123 | int64 | **close (previous close)** |
| 123–131 | int64 | last traded timestamp |
| 131–139 | int64 | **open interest** |
| 139–147 | **float64** | OI change % — *corrected 2026-09-11; the table said int64* |
| 147–347 | — | **best five** — 10 entries × 20 bytes |
| 347–355 | int64 | upper circuit |
| 355–363 | int64 | lower circuit |
| 363–371 | int64 | 52-week high |
| 371–379 | int64 | 52-week low |

> **Correction (2026-09-11, Phase 4).** Offset 139 is a **float64**, not an
> int64. Read as an integer it yields ~4.6e18 and renders as
> `+4581235513960227840.00%`; read as a float64 it is −5.82 to +2.11 across two
> independent live captures. Found on-device, not by a test — every assertion
> aimed at the field had been written from the same wrong premise as the
> decoder.

**Best-five entry (20 bytes each, 10 entries from offset 147).** Entries 0–4 are buy,
entries 5–9 are sell:

| Offset within entry | Type | Field |
|---|---|---|
| 0–2 | uint16 | flag — `1` = buy, `0` = sell |
| 2–10 | int64 | quantity |
| 10–18 | int64 | price |
| 18–20 | uint16 | number of orders |

Do not trust position alone — **read the flag**. Best bid is the first buy entry; best ask
is the first sell entry.

Field mapping for the required display:

| Required | Source | Note |
|---|---|---|
| LTP | offset 43 | ÷100 |
| Previous close | offset 115 | ÷100; denominator for % change |
| Bid / Bid Qty | first best-five entry with flag 1 | price ÷100 |
| Ask / Ask Qty | first best-five entry with flag 0 | price ÷100 |
| Volume | offset 67 | contracts, no scaling |
| Open interest | offset 131 | contracts, no scaling |
| % change | computed | `(ltp - close) / close * 100` |

**Bonus, free in the same packet:** OI change %, upper/lower circuit, 52-week high/low, and
day OHLC. Displaying circuit limits and OI change reads as domain fluency and costs no extra
request. Add in Phase 4 only if the required fields are already solid.

### 3.5 Data traps

1. **Prices are integers in paise — divide by 100.** `ltp: 21375` is ₹213.75. This is the
   exact inverse of the Upstox convention; do not carry over "never scale" instincts.
   Quantities, volume and open interest are **not** scaled.
2. **Quantity/volume fields are int64.** Dart's `getInt64` returns `int` natively on mobile
   (64-bit), so no `fixnum` bridge is needed — but the conversion and scaling still happen
   once, at the mapping boundary, and never above it.
3. **`close` can be zero.** A newly listed strike has no previous close, and deep OTM options
   can settle at zero. `(ltp - close) / close` then yields `Infinity` or `NaN`. The domain
   model must expose `double?` and return `null`; the UI renders `—`. Cover this with a test.
4. **Options move violently.** ±200% in a day is normal. Do not build a layout or colour
   scale that assumes equity-sized moves, and make sure three-digit percentages don't break
   the row.
5. **Best-five can be empty or one-sided.** An illiquid strike may have no resting sell
   orders at all. Never assume an entry exists for either side; scan by flag and return
   `BookLevel?`.
6. **Bid/ask spreads can be enormous** on far OTM strikes — bid 0.05, ask 0.60. Showing
   spread and mid is two lines and signals domain awareness.
7. **Packet length varies by mode.** A SNAP_QUOTE packet is 379 bytes; LTP is 51. Validate
   length before reading offsets — a short packet must be rejected, never read past its end.
8. **The socket dies without a client ping** — at exactly 120s idle, with close code
   1001 and reason `"Connection Idle Timeout"` (measured, Phase 0). It presents as
   "worked for two minutes, then nothing" and is not a network fault. It is not
   silent if you read the close frame, so surface `closeCode`/`closeReason` in
   logging rather than reporting a bare disconnect.

## 4. Architecture

### 4.1 Layers

`presentation/` → `domain/` ← `data/`. `domain/` is pure Dart.

No use-case layer. At this size every use case would be a one-line
pass-through to a repository; the indirection would add files without adding a
seam. This is a deliberate decision — record it in `docs/DECISIONS.md`.

### 4.2 Structure

```
lib/
├── main.dart                       # bootstrap only
├── app/
│   ├── app.dart                    # MaterialApp.router
│   ├── router.dart                 # GoRouter + auth redirect guard
│   └── theme.dart
├── core/
│   ├── config/app_config.dart      # typed access to injected config
│   ├── error/failures.dart         # sealed AppFailure hierarchy
│   └── logging/logger.dart
├── domain/                         # PURE DART — no Flutter imports
│   ├── entities/
│   │   ├── option_contract.dart    # key, symbol, strike, expiry, CE/PE, lot
│   │   ├── market_tick.dart        # immutable, rupee-denominated
│   │   ├── book_level.dart
│   │   └── market_status.dart      # open / closed / unknown per segment
│   └── repositories/
│       ├── auth_repository.dart          # abstract
│       └── market_data_repository.dart   # abstract
├── data/
│   ├── auth/firebase_auth_repository.dart
│   ├── broker/
│   │   ├── angel_client.dart           # REST: login, refresh, headers
│   │   ├── broker_session.dart         # jwt/feed/refresh tokens + TOTP + 05:00 expiry
│   │   ├── feed_connection.dart        # socket lifecycle + state machine + 10s ping
│   │   ├── feed_frames.dart            # sub/unsub JSON frame builders
│   │   ├── tick_decoder.dart           # PURE: ByteData → MarketTick
│   │   ├── replay_feed_connection.dart # fixture playback
│   │   └── instrument_master.dart      # scrip master fetch + off-isolate parse
│   ├── contracts/
│   │   ├── contract_repository.dart    # fetch + cache + invalidate
│   │   └── contract_index.dart         # in-memory search
│   └── market_data_repository_impl.dart
└── presentation/
    ├── shared/template.dart        # THE shared shell
    ├── auth/
    ├── search/
    └── detail/
```

### 4.3 State management

Riverpod.

The load-bearing reason: `StreamProvider.autoDispose.family<MarketTick, String>`
keyed by instrument key maps exactly onto "one live subscription per
instrument, torn down when nothing is watching it." Combined with
`ref.onDispose(() => repo.unsubscribe(key))`, the graded requirement — *the
subscription is cleanly closed when the user backs out* — becomes structural.
There is no code path that skips it, so it cannot be forgotten.

Pin whatever `flutter pub add riverpod flutter_riverpod` resolves to and check
its migration notes; Riverpod has moved through major versions quickly.

### 4.4 Error model

```dart
sealed class AppFailure { const AppFailure(this.message); final String message; }

final class AuthFailure          extends AppFailure { ... }
final class BrokerAuthFailure    extends AppFailure { ... }  // 401 / expired
final class FeedFailure          extends AppFailure { ... }  // socket dropped
final class ContractFailure      extends AppFailure { ... }  // fetch / parse
final class NetworkFailure       extends AppFailure { ... }
```
  
Sealed so `switch` is exhaustiveness-checked. Adding a failure type later
becomes a compile error at every render site — an unhandled error state cannot
ship.

The separation is also behavioural: a `BrokerAuthFailure` shows "reconnecting
to market data" and the user stays signed in. Only `AuthFailure` signs anyone
out.

## 5. Subsystem requirements

### 5.1 `template.dart`

One file. Exports `AppTemplate`:

```dart
AppTemplate({
  required String title,
  required Widget body,
  List<Widget>? actions,
  bool showNav = true,
})
```

Returns a fully dressed `Scaffold`: app bar with a dummy logo as leading,
title, actions, a **logout action present on every screen by construction**,
bottom navigation, and consistent background and padding.

Both Search and Detail pass a body into it. Neither constructs a `Scaffold`.
Verify with `grep -rn "Scaffold" lib/` — one match only.

Known limitation to note in the README: wrapping per-screen means the nav bar
rebuilds on navigation. Free at two screens; at ten you'd hoist persistent
chrome into a `ShellRoute`.

### 5.2 Auth

Firebase Auth. Google Sign-In plus email/password register and login.

`google_sign_in` v7+ is a rewrite — check the current package README, not
older tutorials. Known changes: `GoogleSignIn.instance` is a singleton;
`initialize()` must be awaited exactly once before any other call; `signIn()`
became `authenticate()`; `signInSilently()` became
`attemptLightweightAuthentication()`; there is no `currentUser`; cancellation
throws `GoogleSignInException` with code `canceled` rather than returning null.

**Treat user cancellation as a no-op, not an error.** Dismissing the account
picker is normal behaviour and must not show an error banner.

Android setup gotchas: register debug SHA-1 *and* SHA-256 in Firebase and
re-download `google-services.json`. A null `idToken` almost always means the
server client ID wasn't set — and it is the **Web** client ID from the Firebase
console, not the Android one.

Session persistence is Firebase's job. Gate the router on `authStateChanges()`.
Do not write tokens to `SharedPreferences`.

Error states to surface: invalid credentials, email already in use, weak
password, network failure. Cancellation silent.

### 5.3 Contract index

1. Fetch the instrument master once per day (§3.2).
2. **Parse and filter off the UI isolate** via `compute()` — 145k elements is
   enough JSON to drop frames if decoded synchronously. Filter to Nifty
   `OPTIDX` before anything crosses back to the main isolate; cache the ~1,600
   that survive, never the whole file.
3. Map to `OptionContract` domain objects at the boundary — this is where the
   ÷100 strike, the `DDMMMYYYY` expiry and the CE/PE suffix are resolved, and
   the only place they are.
4. Persist the filtered list locally with a fetch timestamp.
5. Invalidate against the 08:30 IST refresh boundary.
6. Search filters the cached list in memory — synchronous, no network, no
   debounce needed because there is no request to debounce.

Sort results by expiry ascending, then strike. Mark the nearest expiry. A
trader searching "24500" wants this week's contract first, not one four months
out.

Empty-result state is graded. Handle it explicitly.

### 5.4 Feed connection

A long-lived service, not something owned by a widget. Explicit state machine:

```
disconnected → connecting → connected → subscribed
                   ↑                        │
                   └───── reconnecting ←────┘
                              │
                              ↓ (retries exhausted)
                            failed
```

Every UI state derives from this mechanically.

Responsibilities:

- **Own the socket**, opened with the four-header handshake (§3.3).
- **Own the 10-second ping.** Mandatory client-side keepalive. A missed ping
  kills the connection after roughly a minute, and the failure looks exactly
  like a network fault, so the timer belongs here and nowhere else.
- **Own the desired subscription set.** The server does not remember
  subscriptions across a reconnect. On reconnect, re-apply desired state —
  never assume it survived.
- **Staleness watchdog.** A half-open TCP connection reports healthy and
  silently delivers nothing. If no message has arrived for N seconds *while the
  market is open*, treat the connection as dead and reconnect. Angel One sends
  no segment-status frame, so gate on the **clock** — 09:15–15:30 IST on a
  weekday — so a closed market isn't mistaken for a dead socket.
- **Exponential backoff with jitter**, capped. Jitter matters: without it,
  every client reconnects in lockstep after a broker blip and you have built a
  thundering herd.
- **Close before reconnecting.** Do not leak sockets across retries.
- **Re-authenticate on token expiry.** Tokens die at 05:00 IST. A handshake
  rejected with 401 is a `BrokerAuthFailure`: refresh the session (§5.6) and
  retry once before surfacing failure. The user stays signed in throughout.
- **App lifecycle.** `AppLifecycleListener`: disconnect on background,
  reconnect on resume. Otherwise you stream to a screen nobody is looking at,
  and the OS will suspend it unpredictably anyway.

No Flutter widget imports in this file.

### 5.5 Tick decoder

Pure function: `Uint8List` → `MarketTick`. No I/O, no state, no Flutter import.

This is the highest-risk file in the project. Upstox would have given a generated
protobuf decoder; Angel One gives raw little-endian bytes at fixed offsets, so
every field is a hand-written `ByteData` read and every offset is a chance to be
silently wrong. Write it carefully, and test it against a recorded fixture.

Does all five of these, once, at this boundary:
- **validate length before reading** — reject a short packet, never read past its end
- integer paise → rupee `double` (÷100) for prices only, never for quantities
- byte offsets → domain field names
- best-five scanned **by flag**, not by position → null-safe `BookLevel?` per side
- `close == 0` → `changePercent` returns `null`

Because it is pure, it tests against a stored fixture with no network and **no
dependence on market hours**. That is the point.

### 5.6 Broker session

Separate from the feed, and separate again from Firebase. Owns:

- TOTP generation from `ANGEL_TOTP_SECRET`
- `loginByPassword` → `jwtToken`, `refreshToken`, `feedToken`
- proactive refresh before the 05:00 IST expiry, and reactive refresh on a 401
- exposing the current tokens to the REST client and the feed

**It never touches Firebase, and Firebase never touches it.** A broker
credential failure surfaces as `BrokerAuthFailure` and must never sign the user
out of the app — the two-auth-systems rule in `CLAUDE.md` is what this section
enforces in practice.

Never log a token, a TOTP code, or a raw login response.

### 5.7 Stream shaping

Ingest every tick. Render at ~10 Hz.

**Conflate, do not debounce.** Debounce waits for a quiet gap; under a live
feed the gap never arrives and the screen appears frozen. Conflation emits the
most recent value on a schedule.

Conflation is lossless *here specifically* because each `full` payload is a
complete snapshot, not a delta — the newest message contains everything a
dropped one did. If this app ever built candles or volume-weighted metrics it
would have to process every tick and conflate only at the render boundary.
Write that reasoning into `docs/DECISIONS.md`; it is the kind of thing that
gets asked about.

## 6. Phases

Each phase is one Claude Code session. Do not start the next unprompted.

### Phase 0 — Retire external risk (no Flutter yet)

**Everything else depends on facts in §3 being true. Verify them first, in a
throwaway Dart script under `tool/`, before any app code exists.**

1. **Log in.** Generate a TOTP from `ANGEL_TOTP_SECRET`, call
   `loginByPassword`, and confirm all three tokens come back. Confirm the full
   header set in §3.1 is genuinely required — drop one and observe the
   rejection, so the requirement is proven rather than cargo-culted.
2. Fetch the instrument master, filter to Nifty `OPTIDX`, and confirm the field
   shapes in §3.2 — especially the ÷100 strike and the `DDMMMYYYY` expiry.
   Save a **trimmed** slice (Nifty options only, not all 145k instruments) to
   `test/fixtures/nifty_options.json`.
3. Confirm the WebSocket endpoint and that the four-header handshake connects.
4. **Prove the 10-second ping is mandatory.** Hold a connection open *without*
   pinging and confirm it dies within ~a minute; then hold one *with* pinging
   and confirm it survives. This is the failure mode most likely to burn a day
   later, so make it a known quantity now.
5. Confirm a token refresh via `generateTokens` returns a usable new `jwtToken`
   without a fresh TOTP.
6. Subscribe in `SNAP_QUOTE` mode to one liquid near-ATM option **during market
   hours** and confirm every field in §3.4's mapping table is populated. Verify
   the ÷100 scaling against the live LTP shown in any Angel One client — a
   decimal-place error here is silent and poisons everything downstream.
7. **Record a live session** — raw binary frames plus arrival timestamps — to
   `test/fixtures/feed_session.bin`. This is the single most important
   artifact in the project. Record an illiquid far-OTM strike too, so the
   one-sided-book path in §3.5 has a real fixture.

**Acceptance:** ticks print to console; fixtures committed; §3 corrected
against reality; findings in `docs/DECISIONS.md`.

**Do not proceed until ticks are printing.** If the broker turns out to be a
dead end, this is the hour to discover it.

> Market data flows 09:15–15:30 IST, weekdays only. Steps 6–7 must happen in
> that window. Everything after Phase 0 can be built at any hour *because* of
> step 7.

### Phase 1 — Skeleton + auth (4–5 h)

Flutter project, folder structure per §4.2, analyzer config, Firebase,
Google Sign-In, email/password register + login, session persistence via
`authStateChanges()`, logout, GoRouter with auth guard.

`.gitignore` and `.env.example` are already committed — extend `.env.example`
if config grows, and never let a real value into it.

**Acceptance:** sign in with Google; register and log in with email; kill and
relaunch the app and remain signed in; log out and return to auth; all four
error states from §5.2 render; cancelling the Google picker shows nothing.

### Phase 2 — Shell + search (3–4 h)

`template.dart` per §5.1. Contract fetch, mapping, cache, invalidation.
In-memory search index. Search screen inside the template.

**Acceptance:** `grep -rn "Scaffold" lib/` matches only `template.dart`;
searching a strike returns correctly sorted results; nearest expiry marked;
empty-result state renders; second launch uses cache with no network call;
logout reachable from the search screen.

### Phase 3 — Feed (5–6 h)

Broker session (login, TOTP, refresh), connection state machine with the
10-second ping, subscribe/unsubscribe frames, tick decoder, replay connection.
Tests against Phase 0 fixtures.

No UI work in this phase.

**Acceptance:** unit tests decode the recorded fixture into correct
`MarketTick`s; a known packet decodes to the LTP verified in Phase 0 step 6,
proving the ÷100 scaling; `close == 0` yields `null` percent change; a short
packet is rejected rather than read past its end; a one-sided book yields a
null `BookLevel` on the empty side; a fake socket test proves the backoff
sequence, the 10-second ping, and resubscribe-on-reconnect; replay mode emits
ticks with realistic timing; no Flutter import anywhere in `data/broker/`.

### Phase 4 — Detail screen (3–4 h)

Detail screen inside the template. All required fields from §3.4, plus spread
and mid. Conflated stream per §5.7. Loading, error, disconnected and
market-closed states. Subscription torn down on pop via `autoDispose`.

OI change %, circuit limits and 52-week range only if everything above is
solid. Angel One's feed carries no Greeks — do not compute or display them.

**Acceptance:** values update live (or under replay); back-navigation
unsubscribes — prove it with a log line; market-closed state distinguishable
from disconnected; three-digit percentages don't break the layout; an
illiquid strike with a one-sided book renders without crashing.

### Phase 5 — Hardening (2–3 h)

Deliberately break things and fix what falls over:

- kill wifi mid-stream, restore it
- background the app for two minutes, resume
- invalidate the token, observe recovery
- search for a strike that doesn't exist
- log in with wrong credentials
- open Detail, immediately pop, repeat rapidly — confirm no socket leak
- rotate the device on every screen

**Acceptance:** each recovers to a correct state with a clear message. No
unhandled exception reaches the user.

### Phase 6 — README + recording (2 h)

README sections, in order:

1. What this is + demo recording link
2. **Requirement → file map** — a table pointing at the exact path satisfying
   each strict must-have. Makes the reviewer's job trivial.
3. Broker choice and why (free; what Angel One costs you — daily TOTP login
   instead of a static token, and a hand-written binary decoder instead of a
   generated one; the rejected alternative and the honest trade-off)
4. Architecture — layer rule, structure, the two-auth-systems model
5. Setup — Angel One SmartAPI app, API key + client code + TOTP secret,
   Firebase config, `.env.example`
6. Running it — including replay mode for outside market hours
7. **Security note** — the sharpest section in the README, and the one most
   worth writing honestly. Angel One issues no read-only credential: the API
   key and TOTP secret authenticate a **full trading account**. This app never
   calls a mutating endpoint, but that is a property of the code, not of the
   credential. A `.env` file ships as a Flutter asset inside the APK, so
   gitignoring keeps it off GitHub, not off the device — anyone with the APK
   can extract it. State the production design plainly: the broker session
   belongs server-side behind the Firebase session, with the client receiving
   only a short-lived feed credential it cannot trade with.
8. Testing — what's covered, how to run without live data
9. Known limitations — Android only; single instrument at a time; no tick
   persistence; no use-case layer, and why

Sections 7 and 9 are the differentiators. Almost nobody writes them.

## 7. Out of scope — do not build

Order placement or any mutating endpoint. Option chain view. Tick persistence.
Custom design system. Pixel-perfect UI. iOS. Web. A use-case layer. Widget
tests. Coverage targets.

If a change isn't traceable to §2, it isn't in scope.
