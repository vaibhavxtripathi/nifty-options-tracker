# Decisions

Running log of non-obvious choices and the alternatives rejected. Written in
plain English, because the point is to be able to defend this in an interview.

---

## 2026-09-09 — Broker switched from Upstox to Angel One SmartAPI

**What changed.** The original spec was written against Upstox. We moved to Angel
One because that is the API access we actually have. This is not a rename — four
load-bearing assumptions in the original design turned out to be false, and §3 of
the spec was rewritten against the official `angel-one/smartapi-python` SDK source
plus a live fetch of the instrument master.

**What we lost, honestly.** Upstox was the better API for this project, and it is
worth being able to say why:

1. **The analytics token is gone.** Upstox offered a long-lived token that removed
   daily re-authentication entirely. Angel One has no equivalent: login needs a
   TOTP code and every token expires at 05:00 IST the next day. So the app now
   carries a broker-session subsystem (§5.6) that the Upstox design did not need
   at all.
2. **The generated decoder is gone.** Upstox sent Protobuf, so `protoc` would have
   written the decoder for us. Angel One sends raw little-endian binary at fixed
   byte offsets, so the decoder is hand-written (§5.5). That moves the tick decoder
   from "generated, boring, safe" to the single highest-risk file in the codebase —
   every offset is a chance to be silently wrong, and a wrong offset produces a
   plausible-looking number rather than an error.
3. **Market status is gone.** Upstox opened each connection with a `market_info`
   frame, which let the app distinguish *market closed* from *connection broken*
   for free. Angel One sends nothing equivalent, so that distinction is now derived
   from the clock (09:15–15:30 IST, weekdays) — less trustworthy, since a holiday
   reads as an open market with a dead socket.

**What we gained.** Two things genuinely got simpler:

1. **No 302 redirect dance.** Upstox required an `HttpClient` GET with
   `followRedirects: false` to read a `Location` header before opening the socket —
   a known Dart pain point the spec budgeted real time for. Angel One's WebSocket
   accepts the four auth headers directly, so `feed_authorizer.dart` was deleted
   from the plan.
2. **Requests are plain JSON text.** Upstox required JSON-encoded *binary* request
   frames. Angel One takes text; only responses are binary.

**The trap that inverted.** Upstox sends prices in rupees and the spec warned in
bold *not* to scale them. Angel One sends integer paise, so everything must be
divided by 100 — including the `strike` field in the instrument master, which
arrives as the string `"2210000.000000"` for ₹22,100. This is the single easiest
way to ship a silently wrong app, which is why Phase 0 step 6 now requires checking
a decoded LTP against a real Angel One client before any code depends on it.

**Security posture got worse, and the README has to say so.** The Upstox analytics
token was a read-only market-data credential. Angel One issues no read-only
credential at all: the API key plus TOTP secret authenticate a **full trading
account**. The app is read-only by construction — it never calls a mutating
endpoint — but that is a property of our code, not of the credential. Since a
`.env` file ships as a Flutter asset inside the APK, anyone with the APK can
extract it. `CLAUDE.md`'s prohibition on order placement was strengthened
accordingly, and the Phase 6 security note is now the sharpest section of the
README rather than a nice-to-have.

**Two open choices, decided.**

- *Broker auth:* TOTP secret in `.env` with automatic login, over a manual
  code-entry screen. Rationale: "live data actually streams" is a graded criterion
  and a demo recording should not stall on a token that expired at 5 AM. The cost
  is a trading-capable secret on the device, which the README states plainly rather
  than hides.
- *Bonus fields:* Angel One's feed carries no Greeks, so the original "display
  delta/theta/IV" bonus is impossible. Replaced with what SNAP_QUOTE actually
  ships in the same packet — OI change %, circuit limits, 52-week range. Computing
  Greeks client-side via Black-Scholes was rejected: a subtly wrong Greek is worse
  than no Greek, and it is outside §2.

**Rejected alternative.** Building against a recorded fixture only, with no live
broker auth, was considered and rejected — it removes all credential risk but
fails the "live data actually streams" criterion outright.

---

## 2026-09-09 — Instrument master parsed off the UI isolate

Angel One publishes no filtered option-contract endpoint. `searchScrip` searches by
text but will not enumerate a chain, so the only complete source is
`OpenAPIScripMaster.json` — 145,599 instruments, of which 1,588 are Nifty options.

Decoding that synchronously on the main isolate would visibly drop frames, so the
fetch-and-filter runs through `compute()` and only the ~1,600 surviving contracts
cross back. We cache the filtered list, never the raw file.

The alternative — fetching the full file and filtering lazily during search — was
rejected because it keeps 145k objects resident for the life of the app to serve a
list that never changes within a day.

---

## 2026-09-09 — Phase 0 verification harness under `tool/`

Seven throwaway Dart scripts, one per Phase 0 step, run against the live broker
before any app code exists. They are plain `dart:io` — no Flutter — so they run
with the Dart SDK alone and are deleted or ignored once Phase 1 starts. A minimal
root `pubspec.yaml` exists only to resolve `crypto`; Phase 1 replaces it.

**Why a shared `redact()` rather than "just be careful".** Every value that comes
from `.env` or a broker auth response passes through one function that prints a
length and the last four characters. `redactJson()` walks a decoded response and
masks by key name, so a whole auth body can be printed for debugging without a
token reaching the console. This is enforced at one chokepoint because the
alternative — remembering, at every print site, which field is sensitive — fails
exactly once and then the token is in a scrollback buffer forever.

**Why the session cache.** `tool/.session.json` (gitignored before it could ever
be written) holds the login tokens so steps 3–7 reuse one login. A TOTP code is
valid for a 30-second window and the login endpoint rate-limits, so
re-authenticating per script would make the later steps flaky for no benefit.

**Why the header ablation probes `getProfile`, not `loginByPassword`.** Phase 0
asks us to prove the nine-header set is genuinely required rather than
cargo-culted. Dropping a header from the *login* call would confound two
variables, because each retry also needs a fresh TOTP. Probing an authenticated
read-only endpoint with an already-issued JWT isolates the header check.

## 2026-09-09 — Phase 0 findings: §3.2 confirmed, one correction

Step 2 ran end to end against live data. Every claim in §3.2 held:

- 145,599 total instruments; **1,588** Nifty `OPTIDX`/`NFO` contracts — both
  exactly as specified.
- `strike` is paise as a decimal string. After ÷100 the range is ₹12,000–₹34,500,
  which is plausible for Nifty and confirms the divisor.
- `expiry` is `DDMMMYYYY`. `DateTime.parse` genuinely throws on `"06OCT2026"`,
  as warned. All 1,588 parsed with a manual parser; 18 distinct expiries.
- `token`, `strike`, `lotsize` and `tick_size` all arrive as quoted strings.
- There is no CE/PE field. Deriving from the symbol suffix yields 784 CE / 804 PE
  with zero unparseable symbols.

**Correction to §3.2: the file is 32.5 MB, not ~8 MB.** It decoded in 388 ms on
the desktop VM, which will be materially slower on a phone — so the `compute()`
decision recorded above is more strongly justified, not less. The spec's size
figure should be updated.

**Fixture scope.** `test/fixtures/nifty_options.json` holds the three nearest
expiries (2026-09-15 / 09-22 / 09-29) — 590 contracts, 177 KB — rather than all
1,588. Enough to exercise search, sorting and nearest-expiry selection without
committing megabytes of JSON that would never be read.

## 2026-09-09 — Phase 0 blocked at step 1: `AB1050` on login

`loginByPassword` returns `status:false`, `errorcode:AB1050`, *"Invalid totp and
client combination"*. This blocks steps 1 and 3–7, all of which need a session.

What was ruled out, so this is not re-litigated later:

- **The TOTP implementation is correct.** It reproduces all ten RFC 4226 HOTP
  vectors, the RFC 6238 `T=59` vector, and RFC 4648 base32 decoding.
- **Clock skew is ruled out.** The previous, current and next 30-second windows
  were all rejected identically.
- **Credential shapes are plausible.** The TOTP secret is valid base32 decoding
  to 32 bytes; the MPIN is 4 digits; the client code is 10 alphanumeric
  characters.
- A deliberately wrong `totp:000000` produces the *same* error as a correctly
  generated code, so the gateway is not distinguishing our code from garbage —
  consistent with the TOTP registration being absent or bound to a different app,
  rather than with our arithmetic being wrong.

Remaining candidates are all account-side: the MPIN differs from what the API
expects, the secret was rotated or belongs to another app, or the API key has no
active TOTP registration. Resolving this needs the SmartAPI console, not code.

---

## 2026-09-10 — Phase 0 steps 1, 3, 4, 5 verified live

Credentials were corrected (the earlier `AB1050` was account-side, as suspected —
the TOTP secret in `.env` is now 26 characters rather than 52). Login succeeds and
returns all three tokens. Four of the seven Phase 0 steps now pass against the live
API; steps 6–7 await market hours.

### §3.1 corrected: only four of the nine headers are enforced

The spec claimed the gateway "rejects requests with any missing". Measured by
dropping each header in turn against the read-only `getProfile`, only four are
actually enforced:

| Header | Result |
|---|---|
| `X-PrivateKey` | **required** — HTTP 400, `AB1012` |
| `X-SourceID` | **required** — HTTP 400, `AB1012` |
| `X-MACAddress` | **required** — HTTP 400, `AB1012` |
| `Authorization` | **required** — HTTP 200 but `"Token missing"` |
| `Content-type`, `Accept`, `X-UserType`, `X-ClientLocalIP`, `X-ClientPublicIP` | accepted when absent |

**We still send all nine.** The enforced set is undocumented and could widen without
notice; matching the official SDK costs a few bytes. The value of the measurement is
diagnostic — when a request 400s, those four are where to look. Note the gateway's
error text spells the MAC header `X-MACaddress`, differing in case from its own
documentation; harmless, since HTTP header names are case-insensitive, but a hint
that the validation list is hand-maintained.

Also worth recording: a missing `Authorization` returns **HTTP 200** with
`"Token missing"` in the body, not a 401. Any error handling that keys off the
status code alone will read that as success. §4.4 must classify on the body's
`status` field, not the HTTP code.

### §3.3 refined: the idle timeout is 120s, and the server *does* pong

The A/B test is unambiguous. Unpinged, the socket was closed at **t+120s** with
close **code 1001**, reason **`"Connection Idle Timeout"`**. Pinged every 10s, it
survived the full 180s window with no interruption.

Two corrections to the spec:

1. **120 seconds, not ~60.** The original figure would have led to a needlessly
   aggressive keepalive.
2. **Angel One does reply to pings.** Every `"ping"` is answered with a text
   `"pong"`, and one arrives on connect before any ping is sent. The spec's claim
   that "Upstox auto-ponged; Angel One does not" was wrong.

The pong reply is more useful than it first appears: §5.4 can treat a missing pong
as a liveness signal seconds after it should have arrived, rather than waiting out
the full 120-second timeout. It also means the frame handler must discriminate on
**type** — pongs are text, market data is binary — because a decoder that assumes
every frame is a packet will try to parse `"pong"` as one.

**A methodology note, because it nearly produced a false result.** The first run of
this test held the unpinged arm for exactly 120s and scored it as "survived": the
server's close arrived in the same tick the hold window expired, so the death was
recorded after the arm had already been judged. The window is now 240s with a short
grace period after it, and the arm returns early the moment death is observed. A
test whose timing coincides with the phenomenon it measures is worse than no test —
it reports a confident wrong answer.

### New, undocumented: WebSocket connections are rate-limited

Not in §3 at all, and it cost the most time today. Opening three sockets in quick
succession gets the third refused with `HttpException: Connection closed before full
header was received` — **the same error an unauthenticated handshake produces**.
There is no 429, no `Retry-After`, and no distinguishing message.

This was initially misread as a broken handshake, then as HTTP connection-pool
interference. An ordering experiment settled it: a clean first connect succeeded, a
connect immediately after an HTTP GET to the same host also succeeded, and only the
third connection in the sequence failed. The variable is connection *count over a
short window*, not the preceding request.

Two consequences, now written into §3.3:

1. **Reconnect must back off exponentially from the first retry.** A tight retry
   loop is itself what keeps the socket shut, and it looks exactly like a
   credential problem.
2. **Never classify this error as fatal-auth.** Signing the user out — or discarding
   the broker session — over throttling would turn a two-second delay into a full
   re-login. Per the two-auth-systems rule, a broker hiccup must never touch the
   Firebase session; this is a concrete case where a naive classifier would.

`tool/03_ws_handshake.dart` accordingly no longer makes an HTTP probe before its
handshake (the successful upgrade already proves there is no redirect, since Dart
does not follow redirects during an upgrade), and it waits 20s before the negative
test so a throttled rejection cannot masquerade as a credential rejection.

### §3.1 confirmed: silent refresh works

`generateTokens` accepts the `jwtToken` + `refreshToken` pair with **no TOTP** and
returns a new JWT that differs from the old one and authenticates a real read-only
request — verified by calling `getProfile` with it, not merely by checking it was
non-empty. A fresh `feedToken` comes back too, so a reconnect after refresh has a
valid token for the socket handshake. §5.6 can renew silently and never re-prompt
mid-session.

### §3.3 confirmed: no unsolicited frames

A connected socket that has not subscribed receives nothing in 5s beyond the initial
pong. Angel One sends no segment-status message, so market-open cannot be read off
the socket — it must come from the clock, as §3.3 says.

## 2026-09-10 — Recording container format for `feed_session.bin`

Nothing in the spec pins down how the recorded session is stored, so:

```
file   := header record*
header := magic "ANGLFEED" (8B) | version uint16 | reserved uint16
record := epochMillis int64 | length uint32 | payload[length]
```

All little-endian, matching the feed itself. **Why store timestamps rather than just
the packets:** the replay connection in §5.7 needs to reproduce *timing*, not only
content. Conflation logic and any "is the feed stalled" watchdog are meaningless
against packets replayed as fast as they can be read — the bursts and the idle gaps
are the part worth keeping. Storing arrival time per record lets replay re-emit each
payload after the original inter-arrival delay.

Text frames (`"pong"`) are deliberately **not** recorded. They are transport
keepalive, not market data, and a replay source should emit what the decoder
consumes.

The recorder subscribes to two tokens in one session — a near-ATM strike and a
far-OTM one — so §3.5 trap 5 (one-sided or empty book) gets a real fixture rather
than a hand-written one. If the far-OTM strike turns out not to trade at all during
the capture, the script says so explicitly rather than silently producing a fixture
that lacks the case it was meant to cover.

---

## 2026-09-10 — Phase 1: no use-case layer

§4.1 asks for this to be recorded explicitly, so: there is no `usecases/`
directory and there will not be one.

At this size every use case would be a one-line pass-through — `SignIn(repo)`
calling `repo.signInWithEmail(...)` and returning the result unchanged. That is
not a seam, it is a forwarding address. It adds a file and an injection site per
operation while giving nothing that could be tested or substituted independently
of the repository behind it.

The seam that actually earns its keep here is the **repository interface**:
`AuthRepository` lives in `domain/`, its Firebase implementation lives in
`data/`, and everything above the interface is written against the abstraction.
That is the boundary a test overrides and the boundary a provider swap would
cross.

Where a use-case layer does pay is when one operation orchestrates several
repositories, or carries policy belonging to neither the UI nor any single data
source. If Phase 3 needs "resolve a contract, then open a feed, then reconcile
with the broker session", that is the point to revisit — and it would be one
class, not a directory of them.

## 2026-09-10 — Riverpod 3 retries failed providers, so auth actions are not providers

The most consequential thing found while building Phase 1, because the failure
mode is silent and looks like a UI bug rather than a state-management one.

**What Riverpod 3 does.** `ProviderContainer.defaultRetry` applies to every
provider unless overridden. When a provider body throws, it re-runs it — up to
**ten times**, with exponential backoff from 200 ms to 6.4 s. It declines to
retry only `Error`s and `ProviderException`s; a plain `Exception` is retried.

**Why that breaks auth.** `FirebaseAuthException` is an `Exception`. So the
natural-looking implementation —

```dart
final signInProvider = FutureProvider.family((ref, creds) =>
    repo.signInWithEmail(email: creds.email, password: creds.password));
```

— responds to a wrong password by retrying that wrong password ten times over
roughly twelve seconds. The user watches a spinner. The "invalid credentials"
state §5.2 requires never renders, because `AsyncError` is not reached until the
retries are exhausted. Worse, it hammers the identity provider with known-bad
credentials and would walk straight into `too-many-requests`.

**What we do instead.** Sign-in, registration and sign-out are imperative methods
on an `AuthController extends Notifier`, which catch `AppFailure` and place it in
state. Nothing throws out of a provider body, so the retry machinery is never
engaged on a code path where retrying is both useless and actively harmful.

`authStateProvider` remains a `StreamProvider`, which is correct: it observes a
stream that does not throw.

**The regression guard.** `test/auth/auth_controller_test.dart` asserts the
repository is called **exactly once** for a failed sign-in. If someone later
converts these to `FutureProvider`s, that count becomes 10 and the test fails
with the reason attached.

The general principle worth carrying into Phase 3: automatic retry is right for
*idempotent reads that fail transiently* — a quote fetch, an instrument master
download — and wrong for anything a user is waiting on that failed because their
input was wrong. Phase 0 found the mirror image on the broker side, where a tight
reconnect loop is what *keeps* the socket shut.

## 2026-09-10 — Auth state has three cases, not two

`AuthState` is `AuthUnknown | AuthSignedOut | AuthSignedIn`. The third case is
the whole reason the acceptance criterion "kill and relaunch and remain signed
in" passes.

Firebase restores a persisted session **asynchronously**. For the first frames
after launch, `authStateChanges()` has emitted nothing — the user is not signed
out, it is simply not yet known whether they are. Modelling that as a boolean
forces "not yet known" to collapse into "signed out", and the router then sends
every cold start to `/sign-in`, only to bounce back to `/home` once Firebase
reports.

The result is a visible flash of the sign-in form on every launch. Functionally
the session *was* restored, but it looks exactly like persistence being broken,
and it is the kind of thing that reads as a bug in a demo.

So `AuthUnknown` parks on a splash route and decides nothing. Only a definite
answer moves the user.

The redirect rules are a pure function — `resolveRedirect(state:, location:)` in
`lib/app/routes.dart` — taking no Flutter or GoRouter types. That keeps the part
of routing carrying actual logic testable without pumping a widget tree or
standing up Firebase. `test/app/routes_test.dart` covers the unknown case
directly, and additionally asserts that **every** redirect target is itself
stable: if `resolveRedirect` sends a user somewhere that also redirects, that is
an infinite navigation loop, and the test proves the fixed point is reached in
one hop.

Note also `refreshListenable`. GoRouter evaluates `redirect` on navigation; it
does not watch Riverpod. Without bridging auth state to a `Listenable`, signing
out would leave the user sitting on a screen they are no longer entitled to see
until they happened to navigate.

## 2026-09-10 — google_sign_in v7: idToken only, and cancellation is not an error

§5.2 warned that v7 is a rewrite. Confirmed against the package source rather
than tutorials, since the migration is recent enough that most published examples
are wrong:

- `GoogleSignIn.instance` is a singleton and `initialize()` must be awaited once
  before any other call. It therefore lives in `main()`, not in the repository —
  a repository can be constructed more than once, which makes it the wrong owner
  for a once-per-process guarantee.
- `signIn()` became `authenticate()`. There is no `currentUser`.
- **`GoogleSignInAuthentication` exposes `idToken` and nothing else.** The
  `accessToken` that older code passes to `GoogleAuthProvider.credential` no
  longer exists on it. This is fine: `GoogleAuthProvider.credential` asserts only
  that *one* of `idToken` / `accessToken` is non-null, so the idToken-only path is
  valid — verified in
  `firebase_auth_platform_interface/lib/src/providers/google_auth.dart`.
- Cancellation **throws** `GoogleSignInException` with
  `code == GoogleSignInExceptionCode.canceled` — an enum value, not the string
  `'canceled'` — rather than returning null as v6 did.

**Cancellation is modelled as a null return, not an exception.** §5.2 requires
that dismissing the picker shows nothing at all, and the cheapest way to
guarantee that is to make the "user changed their mind" path structurally unable
to reach the error handler: `signInWithGoogle()` returns `AppUser?`, and the
repository converts the cancellation exception to `null` at the boundary. A
caller cannot render a banner for a case that never produces a failure object.

**A null `idToken` gets its own error path** rather than falling into the generic
handler. Per §5.2 it almost always means `serverClientId` was given the Android
OAuth client ID instead of the Web one, and the symptom is otherwise a sign-in
that fails with nothing useful in the message.

## 2026-09-10 — Architecture rules are tested, not just documented

`test/architecture_test.dart` reads the source and asserts the CLAUDE.md rules:
`domain/` imports nothing but `dart:` and its own relative files; `domain/` never
imports `data/` or `presentation/`; `data/` never imports `presentation/`; no
`print` in `lib/`; no hard-coded credential-shaped literal; no mutating broker
endpoint anywhere; and the Firebase auth layer contains no broker vocabulary.

A convention that lives only in a document drifts the first time someone is in a
hurry. These fail the build instead, which is the difference between a rule and a
preference.

The broker-coupling test deserves its own note, because it enforces the
two-auth-systems rule in practice. It scans `data/auth/` and `presentation/auth/`
for broker vocabulary (`angel`, `smartapi`, `jwtToken`, `feedToken`, `totp`, …)
in non-comment lines. Phase 0 established why that separation is load-bearing
rather than tidy: Angel One's WebSocket rate-limit rejection is byte-identical to
an auth failure, so any code path letting broker trouble reach Firebase's
sign-out would log the user out of the app over a two-second throttle.

The purity test was checked for vacuity by temporarily adding
`import 'package:flutter/material.dart'` to `domain/entities/app_user.dart` and
confirming it failed. A green architecture test that cannot go red is worse than
none, since it manufactures confidence.

## 2026-09-10 — Config via --dart-define rather than a bundled .env

Phase 1 needs one configuration value, the Google **Web** OAuth client ID, and it
is not a secret — an OAuth client ID is a public identifier, and the same value
already ships inside `google-services.json`.

`flutter_dotenv` was **not** added. Phase 1 does not need `.env` at all, and
adding a dependency before the phase requiring it means choosing its API before
knowing the constraints. `AppConfig.fromEnvironment()` reads
`String.fromEnvironment`, which is compile-time and needs no asset.

This decision must be revisited in Phase 3, and the honest position recorded then
rather than assumed now: the Angel One credentials are genuinely secret and
authenticate a full trading account. Neither a `--dart-define` nor a bundled
`.env` asset protects them from anyone holding the APK — a dart-define is a
compiled-in string constant, trivially recoverable. The choice there is about
which is *less bad* operationally, not about achieving secrecy, and the README
security note is where that gets stated plainly.

## 2026-09-10 — Phase 1 acceptance run, and the one criterion not fully verified

Run against Firebase project `nifty-options-tracker-vt` on the `Medium_Phone`
emulator (Android 16, API 36), from an installed debug APK rather than a
`flutter run` session — force-stopping the app under `flutter run` kills the
debug VM connection, so the relaunch test has to be done on a standalone
install to mean anything.

| §6 criterion | Result |
|---|---|
| register with email | **pass** — account created, guard redirected `/register` → `/home` |
| log in with email | **pass** |
| kill and relaunch, stay signed in | **pass** — force-stop, cold launch, straight to `/home`, no sign-in flash |
| log out returns to auth | **pass** — back gesture then exits the app rather than re-entering `/home` |
| invalid credentials renders | **pass** — "Incorrect email or password." |
| email already in use renders | **pass** |
| weak password renders | **pass** — caught client-side before the round trip |
| network failure renders | **pass** — radios off, "No connection.", mapped to `NetworkFailure` not `AuthFailure` |
| cancelling the picker shows nothing | **partial** — see below |
| sign in with Google | **not verified** — see below |

Gates: `flutter analyze` clean including warnings, 31 tests green,
`dart analyze tool/` clean, and `.env` / `tool/.session.json` /
`google-services.json` all confirmed still ignored.

**The invalid-credentials error appeared immediately.** Worth stating because it
is the production-side confirmation of the Riverpod 3 retry finding recorded
above: had sign-in been a `FutureProvider`, this would have been a spinner for
about twelve seconds followed by nothing useful.

### Google Sign-In could not be completed, and why that is a device limit

Tapping "Continue with Google" launches the Play Services flow correctly — the
`serverClientId` and the registered debug SHA-1 are both being accepted, since a
wrong value fails earlier and differently. But the flow then ends on Google's own
"We weren't able to check for accounts connected to your phone number", because
**the emulator has no Google account added to Android** (`dumpsys account`
returns nothing). There is no account for a picker to offer.

This is a device provisioning gap, not an app defect, and it cannot be scripted:
adding an account needs a real Google password typed into the device.

What *was* verified from it: abandoning that flow and returning to the app leaves
**no error banner and no stuck spinner** — the sign-in screen is clean. That is
the behaviour §5.2 requires of a cancellation, and the cancellation path itself
is covered by a unit test asserting `GoogleSignInExceptionCode.canceled` produces
no failure and clears `isSubmitting`.

What remains unproven on a real device: that a *completed* Google sign-in yields
a non-null `idToken` and a Firebase session. The idToken-only credential path is
verified against the package source and by the assert in
`GoogleAuthProvider.credential`, but source-reading is not a device run, and this
is exactly the place §5.2 warns the Android/Web client ID mix-up shows up.

**To close this out**, add a Google account to the emulator (Settings → Passwords
& accounts → Add account) or run on a physical device, then repeat: tap Continue
with Google, dismiss the picker once — expect no banner — then complete it and
expect `/home`. Recorded rather than quietly marked pass, because "signs in with
Google" is a §6 acceptance criterion and an unverified pass is worse than a
stated gap.
