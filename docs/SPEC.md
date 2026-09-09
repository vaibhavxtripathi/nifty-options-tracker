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

## 3. Broker API reference — Upstox

Broker: **Upstox**, API v3 for streaming, v2 for option contracts.
All trading and market-data APIs are free of cost.

> Everything in this section was verified against Upstox documentation but
> APIs change. **Phase 0 exists to confirm each fact empirically before any
> app code depends on it.** If reality contradicts this section, reality wins —
> update this file and note it in `docs/DECISIONS.md`.

### 3.1 Authentication

Two token types exist:

| Token | Lifetime | Use |
|---|---|---|
| Standard access token | Regenerated daily via OAuth | Full API |
| **Analytics token** | **Generated once, no daily re-auth** | Market Data + Realtime/Streaming |

**Use the analytics token.** It removes the entire daily-login subsystem. It
is generated once from the Upstox developer console and placed in config.

Note: the docs mention a registered static IP, but that condition attaches
only to the optional Portfolio / Account read-only extension — *not* to Market
Data or Streaming. Confirm this in Phase 0.

All authenticated requests use:

```
Authorization: Bearer {token}
Accept: application/json      // REST
Accept: */*                   // WebSocket handshake
```

### 3.2 Option contracts (powers the search screen)

```
GET https://api.upstox.com/v2/option/contract
    ?instrument_key=NSE_INDEX|Nifty 50
    [&expiry_date=YYYY-MM-DD]
```

URL-encode the instrument key (`NSE_INDEX%7CNifty%2050`).

Returns every Nifty option contract. Element shape:

```json
{
  "expiry": "2024-02-15",
  "instrument_key": "NSE_FO|37668",
  "exchange_token": "37668",
  "trading_symbol": "NIFTY 19700 CE 15 FEB 24",
  "tick_size": 5,
  "lot_size": 50,
  "instrument_type": "CE",
  "freeze_quantity": 1800,
  "underlying_key": "NSE_INDEX|Nifty 50",
  "underlying_type": "INDEX",
  "underlying_symbol": "NIFTY",
  "strike_price": 19700,
  "minimum_lot": 50,
  "weekly": true
}
```

`strike_price` is a real rupee value — no scaling. `expiry` is an ISO date
string. `trading_symbol` is already human-readable and is what the user
searches against.

**Why this and not the instrument dump.** Upstox also publishes
`https://assets.upstox.com/market-quote/instruments/exchange/complete.json.gz`
— roughly 50–60 MB unzipped, all segments, all exchanges. Downloading and
parsing that on a phone is slow, memory-hungry and mostly waste. The option
contracts endpoint returns only Nifty options, already structured. Record this
as a deliberate rejection in `docs/DECISIONS.md`.

Contracts refresh around 06:00 IST daily. Cache locally, invalidate against
that boundary.

### 3.3 Market data WebSocket (v3)

Confirm the exact endpoint URL from the current Upstox v3 docs in Phase 0.

**Handshake.** Connect with `Authorization: Bearer {token}` and `Accept: */*`.
The server responds **302**, redirecting to an authorized socket endpoint.

> **Known Dart problem.** `WebSocket.connect` does not follow the 302.
> Solve it explicitly: issue an `HttpClient` GET with `followRedirects: false`
> and the auth header, read the `Location` header, then `WebSocket.connect`
> to that URI. Prove this works in Phase 0 before building on it. Isolate it
> in one method so the workaround is visible and replaceable.

**Subscribe.** Request frames are **binary, not text** — JSON-encode, then
send the bytes.

```json
{
  "guid": "<unique per request>",
  "method": "sub",
  "data": { "mode": "full", "instrumentKeys": ["NSE_FO|45450"] }
}
```

Methods: `sub`, `unsub`, `change_mode`.
Modes: `ltpc`, `option_greeks`, `full`, `full_d30` (Plus only).

**Use `full` mode.** It is the only non-Plus mode carrying open interest *and*
the order book. `ltpc` has neither. This is a requirements-driven choice, not
a preference.

**Responses are Protobuf.** Download the Market Data v3 `.proto` from Upstox,
generate Dart with `protoc` + `protoc_plugin`. Do not hand-parse bytes — the
whole point of choosing Upstox is that the decoder is generated.

**Message sequence on connect:**

1. `market_info` — segment statuses, e.g. `{"NSE_FO": "NORMAL_OPEN"}`
2. a snapshot of current data
3. live ticks

Message 1 is valuable: it lets the app distinguish *market closed* from
*connection broken*. Surface that state explicitly in the UI.

**Keepalive:** the server sends ping frames; standard clients auto-pong. No
manual heartbeat needed. Still keep a staleness watchdog — see §5.4.

**Limits:** 2 concurrent connections per user on the normal tier. Close before
reconnecting or you will exhaust this and lock yourself out.

### 3.4 `full` mode payload

```json
{
  "type": "live_feed",
  "feeds": {
    "NSE_FO|45450": {
      "fullFeed": {
        "marketFF": {
          "ltpc": { "ltp": 213.75, "ltt": "1740727891235",
                    "ltq": "150", "cp": 494.05 },
          "marketLevel": {
            "bidAskQuote": [
              { "bidQ": "75", "bidP": 213.45, "askQ": "525", "askP": 213.9 }
            ]
          },
          "optionGreeks": { "delta": 0.4952, "theta": -8.4067,
                            "gamma": 0.0007, "vega": 16.769, "rho": 3.8673 },
          "marketOHLC": { "ohlc": [ { "interval": "1d", "open": 400,
                            "high": 400, "low": 208.7, "close": 213.75 } ] },
          "atp": 272.9, "vtt": "779625", "oi": 210000,
          "iv": 0.1313, "tbq": 46050, "tsq": 41850
        }
      }
    }
  },
  "currentTs": "1740727891739"
}
```

Field mapping for the required display:

| Required | Source | Note |
|---|---|---|
| LTP | `ltpc.ltp` | rupees |
| Previous close | `ltpc.cp` | rupees; denominator for % change |
| Bid / Bid Qty | `bidAskQuote[0].bidP` / `.bidQ` | top of book |
| Ask / Ask Qty | `bidAskQuote[0].askP` / `.askQ` | top of book |
| Volume | `vtt` | volume traded today, contracts |
| Open interest | `oi` | |
| % change | computed | `(ltp - cp) / cp * 100` |

**Bonus, free:** `full` mode also carries delta, theta, gamma, vega, rho and
IV. Displaying delta, theta and IV costs no extra request and reads as domain
fluency to a reviewer who trades. Add it in Phase 4 only if the required
fields are already solid.

### 3.5 Data traps

1. **Prices are rupees, not paise.** `ltp: 213.75` is ₹213.75. Do not scale.
   (Some Indian brokers send paise — Upstox does not. Don't port that habit.)
2. **Quantity and time fields are int64.** `ltt`, `ltq`, `vtt`, `bidQ`, `askQ`
   arrive as `Int64` from the `fixnum` package via generated protobuf code,
   not as `int`. Convert explicitly at the mapping boundary; never let an
   `Int64` reach the UI.
3. **`cp` can be zero.** A newly listed strike has no previous close, and deep
   OTM options can settle at zero. `(ltp - cp) / cp` then yields `Infinity` or
   `NaN`. The domain model must expose `double?` and return `null`; the UI
   renders `—`. Cover this with a test.
4. **Options move violently.** ±200% in a day is normal. Do not build a
   layout or a colour scale that assumes equity-sized moves, and make sure
   three-digit percentages don't break the row.
5. **`bidAskQuote` may be empty or short.** Never index `[0]` without
   checking. An illiquid strike can have no resting orders on one side.
6. **Bid/ask spreads can be enormous** on far OTM strikes — bid 0.05, ask
   0.60. Showing spread and mid is two lines and signals domain awareness.

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
│   │   ├── upstox_client.dart          # REST: option contracts
│   │   ├── feed_authorizer.dart        # the 302 → Location workaround
│   │   ├── feed_connection.dart        # socket lifecycle + state machine
│   │   ├── feed_frames.dart            # sub/unsub frame builders
│   │   ├── tick_mapper.dart            # PURE: protobuf → MarketTick
│   │   ├── replay_feed_connection.dart # fixture playback
│   │   └── generated/                  # protoc output — do not hand-edit
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

1. Fetch option contracts once per day (§3.2).
2. Map to `OptionContract` domain objects at the boundary.
3. Persist locally with a fetch timestamp.
4. Invalidate against the 06:00 IST refresh boundary.
5. Search filters the cached list in memory — synchronous, no network, no
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

- **Own the socket**, via the 302 authorizer (§3.3).
- **Own the desired subscription set.** The server does not remember
  subscriptions across a reconnect. On reconnect, re-apply desired state —
  never assume it survived.
- **Staleness watchdog.** The server auto-pings, but a half-open TCP
  connection reports healthy and silently delivers nothing. If no message has
  arrived for N seconds *while the market segment is open*, treat the
  connection as dead and reconnect. Gate on market-open (§3.3 message 1) so a
  quiet market isn't mistaken for a dead socket.
- **Exponential backoff with jitter**, capped. Jitter matters: without it,
  every client reconnects in lockstep after a broker blip and you have built a
  thundering herd.
- **Close before reconnecting.** 2-connection cap.
- **App lifecycle.** `AppLifecycleListener`: disconnect on background,
  reconnect on resume. Otherwise you stream to a screen nobody is looking at,
  and the OS will suspend it unpredictably anyway.

No Flutter widget imports in this file.

### 5.5 Tick mapper

Pure function: generated protobuf message → `MarketTick`. No I/O, no state, no
Flutter import.

Does all four of these, once, at this boundary:
- `Int64` → `int`
- broker field names → domain names
- empty/short `bidAskQuote` → null-safe `BookLevel?`
- `cp == 0` → `changePercent` returns `null`

Because it is pure, it tests against a stored fixture with no network and **no
dependence on market hours**. That is the point.

### 5.6 Stream shaping

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

1. Confirm the analytics token works and that no static-IP restriction applies
   to market data or streaming.
2. `GET /v2/option/contract` for Nifty 50 — confirm response shape matches
   §3.2. Save one real response to `test/fixtures/option_contracts.json`.
3. Confirm the v3 WebSocket endpoint URL from current docs.
4. **Solve the 302 redirect in Dart.** `HttpClient` with
   `followRedirects: false` → read `Location` → `WebSocket.connect`. Prove
   ticks arrive.
5. Generate Dart protobuf bindings from the v3 `.proto`. Confirm they decode a
   real frame.
6. Subscribe in `full` mode to one liquid near-ATM option **during market
   hours** and confirm every field in §3.4's mapping table is populated.
7. **Record a live session** — raw frames plus arrival timestamps — to
   `test/fixtures/feed_session.bin`. This is the single most important
   artifact in the project.

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

`.gitignore` and `.env.example` committed in the first commit.

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

Feed authorizer, connection state machine, subscribe/unsubscribe frames, tick
mapper, replay connection. Tests against Phase 0 fixtures.

No UI work in this phase.

**Acceptance:** unit tests decode the recorded fixture into correct
`MarketTick`s; `cp == 0` yields `null` percent change; a fake socket test
proves backoff sequence and resubscribe-on-reconnect; replay mode emits ticks
with realistic timing; no Flutter import anywhere in `data/broker/`.

### Phase 4 — Detail screen (3–4 h)

Detail screen inside the template. All required fields from §3.4, plus spread
and mid. Conflated stream per §5.6. Loading, error, disconnected and
market-closed states. Subscription torn down on pop via `autoDispose`.

Greeks and IV only if everything above is solid.

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
3. Broker choice and why (free; analytics token removes daily re-auth;
   Protobuf means a generated decoder rather than hand-parsed bytes; rejected
   alternatives and the honest trade-off)
4. Architecture — layer rule, structure, the two-auth-systems model
5. Setup — Upstox app + analytics token, Firebase config, `.env.example`
6. Running it — including replay mode for outside market hours
7. **Security note** — the analytics token is a service credential. A `.env`
   file ships as a Flutter asset inside the APK; gitignoring keeps it off
   GitHub, not off the device. State the production design: token issued
   server-side behind the Firebase session, client receives only a
   short-lived credential.
8. Testing — what's covered, how to run without live data
9. Known limitations — Android only; single instrument at a time; no tick
   persistence; no use-case layer, and why

Sections 7 and 9 are the differentiators. Almost nobody writes them.

## 7. Out of scope — do not build

Order placement or any mutating endpoint. Option chain view. Tick persistence.
Custom design system. Pixel-perfect UI. iOS. Web. A use-case layer. Widget
tests. Coverage targets.

If a change isn't traceable to §2, it isn't in scope.
