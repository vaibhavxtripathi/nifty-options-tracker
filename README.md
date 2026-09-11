# Live Nifty Options Tracker

A Flutter app: sign in, search a Nifty option contract, and watch live market
data stream over a WebSocket from Angel One SmartAPI.

**Read-only by construction. It never calls an order endpoint** — see
[Security](#7-security-note), which is the section worth reading first.

Android only. ~5,600 lines of Dart, 224 tests, zero analyzer issues including
warnings.

> **Demo recording:** _(to be added)_
>
> The app runs **outside market hours**. When the exchange is shut it replays a
> real recorded session — 141 packets captured live on 11 Sep 2026 — behind a
> permanent banner naming it as a recording. So the streaming behaviour is
> reviewable at any hour, on any day, without credentials.

---

## 1. What this is

Three screens and a market-data pipeline:

- **Auth** — Google Sign-In plus email/password, session persisted by Firebase.
- **Search** — the day's ~1,600 Nifty option contracts, filtered in memory.
- **Detail** — live SNAP_QUOTE data for one contract: price, change, the
  order book, spread, mid, volume, open interest, day range, circuit limits.

The interesting parts are underneath: a hand-written binary decoder for Angel
One's tick format, a connection state machine with backoff and a mandatory
keepalive, and a replay mode that makes all of it demonstrable when the market
is closed.

---

## 2. Requirement → file map

Where each strict must-have is satisfied.

| Requirement | File |
|---|---|
| Firebase auth, Google + email/password | [`lib/data/auth/firebase_auth_repository.dart`](lib/data/auth/firebase_auth_repository.dart) |
| Session persistence, gated on `authStateChanges()` | [`lib/presentation/auth/auth_providers.dart`](lib/presentation/auth/auth_providers.dart) |
| Auth logic separated from UI | [`lib/presentation/auth/auth_controller.dart`](lib/presentation/auth/auth_controller.dart) — screens render state, never call Firebase |
| Router auth guard | [`lib/app/routes.dart`](lib/app/routes.dart) — `resolveRedirect` is a pure function, unit-tested without a widget tree |
| Contract search | [`lib/data/contracts/contract_index.dart`](lib/data/contracts/contract_index.dart) |
| Instrument master fetch + daily cache | [`lib/data/contracts/contract_repository_impl.dart`](lib/data/contracts/contract_repository_impl.dart) |
| **The one shared template** | [`lib/presentation/shared/template.dart`](lib/presentation/shared/template.dart) — the only `Scaffold` in `lib/`, enforced by a test |
| **WebSocket isolated from widget code** | [`lib/data/broker/feed_connection.dart`](lib/data/broker/feed_connection.dart) — no Flutter import anywhere in `data/broker/`, enforced by a test |
| Binary tick decoder | [`lib/data/broker/tick_decoder.dart`](lib/data/broker/tick_decoder.dart) |
| Connection state machine, backoff, 10s ping | [`lib/data/broker/feed_connection.dart`](lib/data/broker/feed_connection.dart) |
| Broker session: TOTP, login, silent refresh | [`lib/data/broker/broker_session.dart`](lib/data/broker/broker_session.dart) |
| Subscription closed on back-navigation | [`lib/presentation/detail/detail_providers.dart`](lib/presentation/detail/detail_providers.dart) — `autoDispose.family`, proved with a log line |
| Stream conflation at ~10 Hz | [`lib/data/broker/conflate.dart`](lib/data/broker/conflate.dart) |
| Replay for closed markets | [`lib/data/broker/replay_feed_connection.dart`](lib/data/broker/replay_feed_connection.dart) |
| Architecture rules, enforced not documented | [`test/architecture_test.dart`](test/architecture_test.dart) |

---

## 3. Broker choice, and what it costs

**Angel One SmartAPI.** Free, and the API access actually available. The
original design targeted Upstox; moving cost four things worth naming, because
they shaped most of the code:

| | Upstox | Angel One |
|---|---|---|
| Credential | long-lived read-only analytics token | **full trading account**, expires 05:00 IST daily |
| Wire format | Protobuf — `protoc` writes the decoder | **raw little-endian at fixed offsets** — hand-written |
| Market status | `market_info` frame on connect | nothing — derived from the clock |
| Auth | static token | TOTP generated locally, every login |

The decoder is the real cost. A generated Protobuf decoder is boring and safe;
a hand-written one is the highest-risk file in the project, because **a wrong
offset does not throw** — it produces a plausible number that poisons
everything downstream. That risk is why Phase 0 recorded a real session before
any app code existed, and why the decoder is tested against those bytes rather
than against packets its own author invented.

That defence caught a genuine spec error: `§3.4` documents the OI-change field
as an `int64`; it is a **`float64`**, and read as an integer it renders as
`+4581235513960227840.00%`. Confirmed against two independent live captures.

**The rejected alternative** was building entirely against a recorded fixture
with no live broker integration. It removes all credential risk and fails the
brief — "live data actually streams" has to be true, not simulated. The app
does both: live when the market is open and credentials exist, replay when it
is shut, and a setup error if credentials are missing during market hours.

---

## 4. Architecture

**Dependencies point inward.** `presentation/` → `domain/` ← `data/`.
`domain/` imports nothing but `dart:core` and pure Dart. The test is that
deleting `presentation/` leaves everything else compiling.

```
lib/
├── app/                    router, theme, redirect rules
├── core/                   config, sealed failures, the one logger
├── domain/                 PURE DART — entities and repository interfaces
├── data/
│   ├── auth/               Firebase lives here and nowhere else
│   ├── broker/             sockets, TOTP, the decoder — no Flutter import
│   ├── contracts/          instrument master, cache, search index
│   └── demo/               the bundled recording
└── presentation/           auth, search, detail, and the shared template
```

### Two independent auth systems

**Firebase decides who may open the app. The Angel One session decides whether
market data flows.** They never reference each other.

This is not tidiness. Phase 0 measured that Angel One's WebSocket
**rate-limit rejection is byte-identical to an auth failure** — same exception,
same message, no status code to tell them apart. A classifier that mapped
broker trouble onto app auth would sign a user out of the entire app over a
two-second throttle.

So the failure hierarchy is sealed and the separation is structural: only
`AuthFailure` can sign anyone out, and `BrokerAuthFailure` structurally cannot
reach that path. A test scans the auth layer for broker vocabulary and fails
the build if any appears.

### Why Riverpod

One reason, and it is load-bearing:
`StreamProvider.autoDispose.family<MarketTick, String>` maps exactly onto "one
live subscription per instrument, torn down when nothing is watching it." The
graded requirement *the subscription is cleanly closed when the user backs out*
becomes **structural** — there is no code path that skips it, because there is
no code path that owns it.

---

## 5. Setup

### Angel One SmartAPI

1. Create an app at [smartapi.angelbroking.com](https://smartapi.angelbroking.com)
   to get an **API key**.
2. Note your **client code** (login ID) and **MPIN**.
3. Enable TOTP and save the **base32 secret** shown once during setup.

### Firebase

1. Create a project, enable **Google** and **Email/Password** sign-in.
2. Register an Android app and download `google-services.json` into
   `android/app/` (gitignored).
3. Register your debug **SHA-1 *and* SHA-256** fingerprints, then re-download.
4. The `serverClientId` must be the **Web** client ID, not the Android one —
   the Android ID yields a null `idToken` with no useful error.
5. Generate `lib/firebase_options.dart` (gitignored — see below) with the
   [FlutterFire CLI](https://firebase.google.com/docs/flutter/setup):
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```

Both `google-services.json` and `firebase_options.dart` are gitignored even
though the key inside them is Google's client-identifying kind, not a secret
meant to be kept private — the fix for that key is restricting it in
**Google Cloud Console → APIs & Services → Credentials** to this app's package
name + SHA-1 and to only the APIs it needs, not keeping the file off disk.
They're excluded anyway so a clone never ships one project's identifiers by
accident.

### Configuration

Credentials are passed at **build time**, never committed and never bundled as
a file. `.env.example` documents the variable names with empty values.

---

## 6. Running it

```bash
flutter pub get

# Without broker credentials — auth, search and replay all work.
flutter run

# With live market data.
flutter run \
  --dart-define=ANGEL_API_KEY=... \
  --dart-define=ANGEL_CLIENT_CODE=... \
  --dart-define=ANGEL_MPIN=... \
  --dart-define=ANGEL_TOTP_SECRET=...
```

### Replay mode — how to review this outside market hours

The feed source is decided by one rule:

```
market open + credentials     ->  LIVE
market open + no credentials  ->  a setup error naming the missing keys
market closed                 ->  REPLAY
```

A shut exchange is an expected condition nobody can fix, so the app replays a
real recorded session behind a permanent banner. Missing credentials during
market hours are a *fixable defect*, so they surface as an error — routing them
to replay would hide a broken integration behind something that looks like it
works.

**This means the app is fully reviewable with no Angel One account at all**,
on any day of the week.

---

## 7. Security note

**Read this before running it with real credentials.**

Angel One issues **no read-only market-data credential**. The API key, client
code, MPIN and TOTP secret together authenticate a **full trading account** —
the same credentials that can place orders.

This app never calls a mutating endpoint. There is no order code, not even
commented out, and `test/architecture_test.dart` fails the build if an order
endpoint name appears anywhere in `lib/`. But **that is a property of this
code, not of the credential.** Anyone holding those values holds trading
access, whatever this app chooses to do with them.

### What shipping them actually means

Gitignoring `.env` keeps credentials off GitHub. **It does not keep them off
the device.** A `.env` bundled as a Flutter asset ships inside the APK and can
be extracted by unzipping it. A `--dart-define` is a compiled-in string
constant, recoverable with `strings`. **Neither is encryption and neither
should be described as security.**

This app uses `--dart-define` on operational grounds only: it cannot be
committed by accident, and it keeps credentials out of the asset bundle so no
runtime code path or crash reporter can pick them up. That is a smaller attack
surface, not a secure one.

### What the production design would be

The broker session belongs **server-side, behind the Firebase session**. The
client authenticates to your backend with its Firebase token; the backend holds
the Angel One credentials, opens the upstream connection, and hands the client
only a **short-lived feed credential that cannot trade**. The trading
credential never reaches a device.

That is a backend this project does not have, and pretending otherwise would be
worse than saying so.

### What does ship in the APK

The bundled recording (`assets/demo/feed_session.bin`, 54 KB) is real market
data captured from a live session. It contains **no credential material** —
verified before committing and again by a test that fails the build if any run
of twelve or more printable characters appears in it. Binary market data
contains none; a JWT or an API key would trip it immediately.

---

## 8. Testing

```bash
flutter test          # 224 tests
flutter analyze       # zero issues, warnings included
```

**Everything runs without a network, credentials, or market hours.**

| Area | Tests | What it proves |
|---|---|---|
| `test/broker/` | 99 | decoder against 141 real recorded packets; TOTP against the RFC 4226/6238 vectors; backoff, ping cadence and resubscribe under a fake clock |
| `test/contracts/` | 46 | the four instrument-master parsing hazards; the 08:30 IST cache boundary; search ordering |
| `test/detail/` | 43 | feed-source policy; formatting including three-digit percentages; subscription-leak and recovery cases |
| `test/auth/` | 15 | failure mapping; that a failed sign-in calls the repository **exactly once** |
| `test/app/` | 9 | redirect rules, including that every redirect target is itself stable |
| `test/architecture_test.dart` | 12 | the architecture rules, enforced rather than documented |

Three testing choices worth explaining:

**The decoder is tested against real recorded bytes, and the expected values
were extracted by an independent script.** A decoder tested only against
packets its own author constructed proves the author is self-consistent, not
that the offsets match what the broker sends.

**Plausibility, not just round-trips.** The OI-change bug passed every
round-trip test, because the test and the decoder shared the same wrong
premise. The suite now range-checks every decoded value: the only thing wrong
with `4.6e18` is that no option has ever had that OI change.

**Tests are checked for vacuity.** The architecture test was verified to go red
by temporarily adding a second `Scaffold`; the decoder tests by shifting one
offset eight bytes. A green test that cannot fail manufactures confidence
exactly where it is least warranted.

---

## 9. Known limitations

Stated plainly, because the gaps are real.

- **Android only.** iOS is untested and unbuilt.
- **One instrument at a time.** The detail screen subscribes to a single token.
  The socket supports 1,000; the UI does not.
- **No tick persistence, so no chart.** Nothing is stored between sessions, so
  there is no history to plot. A chart would need either intraday candles from
  a different endpoint, or a tick store — both outside scope.
- **Replay streams the recorded instrument**, not whichever contract was
  tapped. A recording can only contain what was captured, and the banner names
  it rather than pretending otherwise.
- **No fully one-sided order book in any fixture.** §3.5 warns an illiquid
  strike may have nothing resting on a side. Two live captures across eleven
  deep strikes found none — every one was quoted five-deep on both sides. The
  decoder handles the empty case and is tested for it with **synthetic**
  packets, which the test says explicitly.
- **No three-digit percentage in any fixture, either.** ±200% is ordinary for
  an option; the widest move captured was −33%. The layout handles it and the
  test input is synthetic, again stated rather than implied.
- **Market status comes from the clock**, so a trading holiday reads as an open
  market with a silent socket. Angel One sends no segment-status frame.
- **The nav bar rebuilds on navigation**, because the template wraps per
  screen. Free at three screens; at ten this would be a `ShellRoute`.
- **No use-case layer.** At this size every use case would be a one-line
  pass-through to a repository — a forwarding address, not a seam. The seam
  that earns its keep is the repository interface in `domain/`. If one
  operation ever needs to orchestrate several repositories, that is the point
  to revisit, and it would be one class rather than a directory of them.

---

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md) — the full specification, corrected against
  reality where live testing disagreed with it.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — a running log of every non-obvious
  choice and the alternatives rejected, written to be defended rather than
  skimmed.
