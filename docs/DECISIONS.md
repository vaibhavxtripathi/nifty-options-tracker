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

## 2026-09-10 — Phase 1 acceptance run: all §6 criteria pass

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
| cancelling the picker shows nothing | **pass** |
| sign in with Google | **pass** — after a Google account was added to the device; see below |

Gates: `flutter analyze` clean including warnings, 31 tests green,
`dart analyze tool/` clean, and `.env` / `tool/.session.json` /
`google-services.json` all confirmed still ignored.

**The invalid-credentials error appeared immediately.** Worth stating because it
is the production-side confirmation of the Riverpod 3 retry finding recorded
above: had sign-in been a `FutureProvider`, this would have been a spinner for
about twelve seconds followed by nothing useful.

### Google Sign-In needed a Google account on the device

On the first pass this could not be completed. Tapping "Continue with Google"
launched the Play Services flow correctly, but it ended on Google's own "We
weren't able to check for accounts connected to your phone number" — because the
emulator had **no Google account added to Android** (`dumpsys account` returned
nothing). No account exists, so no picker can be offered.

That was a device provisioning gap rather than an app defect, and it is worth
keeping in the record because the symptom is easy to misread as a broken
`serverClientId`. The distinguishing detail: a wrong client ID fails *earlier and
differently* — the flow either does not launch or returns a null `idToken` — so a
flow that launches and then complains about *accounts* is telling you about the
device, not the configuration.

**Resolved by adding a Google account to the device, after which Google sign-in
works.** That closes the last §6 criterion and confirms on-device what had until
then only been read out of the package source: `authenticate()` returns an
account whose `authentication.idToken` is non-null, and
`GoogleAuthProvider.credential(idToken: …)` — with no `accessToken`, which
google_sign_in v7 no longer provides — is accepted by Firebase and yields a
session. The Web client ID was the correct one; the Android ID in the same
`google-services.json` would have produced a null `idToken` here.

Cancellation behaves as §5.2 requires: dismissing the flow leaves no error banner
and no stuck spinner. It is also covered by a unit test asserting
`GoogleSignInExceptionCode.canceled` produces no failure and clears
`isSubmitting`.

**Note for Phase 6.** The demo recording has to be made on a device with a Google
account signed in, or the Google path cannot be shown at all. Worth knowing
before setting up a recording rather than during it.

## 2026-09-10 — Phase 2: `AppChrome` is a sealed variant, not `showNav`

§5.1 sketched the template as
`AppTemplate({title, body, actions, showNav = true})`, with the auth screens
passing `showNav: false`. Building it revealed that the boolean cannot express
what the app needs.

The spec also requires "a logout action present on every screen **by
construction**". But Phase 2 folds the splash and both auth screens into the
same template, and a logout button on the sign-in screen is nonsense — there is
nobody signed in to log out. So the template must vary two things
independently, which with booleans means `showNav` plus `showLogout`: four
states, of which only three are meaningful, and the meaningless fourth
("no nav, but do show logout") stays permanently representable.

Worse, "by construction" quietly becomes "by convention" — if logout is a flag,
a screen can forget to set it, which is exactly the failure that phrase exists
to rule out.

So chrome is a sealed hierarchy instead:

- `NoChrome` — splash. No app bar at all, because a screen whose entire job is
  to decide nothing must not flash chrome before the router picks a
  destination.
- `BareChrome` — sign-in, register. A title, and **no way to ask for a logout
  action**; the variant simply has no such field.
- `SignedInChrome` — search, and Phase 4's detail screen. Appends the logout
  button *itself*, after any screen-specific actions. No caller passes it and no
  caller can suppress it.

That last point is the whole argument. "Every signed-in screen has logout" is
now enforced by the type rather than remembered by the author, and the invalid
combination is unspeakable rather than merely unused. It also matches how
`AuthState` and `AppFailure` are already modelled, so a `switch` over chrome
stays exhaustiveness-checked — adding a fourth variant later becomes a compile
error in the template rather than a silently missing app bar.

`_LogoutAction` reads the auth controller directly rather than taking a
callback, for the same reason: a callback is one more thing a screen could
supply wrongly, or not at all.

**Verified, not assumed.** `test/architecture_test.dart` now asserts that
`Scaffold(` is constructed in exactly one file and that the file is
`template.dart`. That turns §6's `grep -rn "Scaffold" lib/` acceptance criterion
from something true on the day it was checked into something that fails the
build if it stops being true. It was checked for vacuity by temporarily adding a
second `Scaffold` to the search screen and confirming it went red — the same
discipline applied to the domain-purity test in Phase 1.

## 2026-09-10 — Cache invalidation is a boundary crossing, not an age

§3.2 says the instrument master is republished daily at ~08:30 IST, and §5.3
says to invalidate against that boundary. The obvious reading — "refetch if the
cache is more than 24 hours old" — is wrong in **both** directions, so the rule
is expressed as a boundary crossing instead:

> The cache is stale exactly when the most recent 08:30 IST publication at or
> before *now* falls after the moment the cache was written.

The two cases an age-based rule gets backwards, both of which now have tests:

- **A 31-minute-old cache can be stale.** Written at 08:00 IST, it holds
  *yesterday's* file. At 08:31 a new file exists and the cached one is a day
  behind — but an age rule calls it fresh and serves stale contracts all day.
- **A 14-hour-old cache can be fresh.** Written at 09:00 IST, it holds today's
  file and stays correct until tomorrow morning. An age rule would refetch
  32.5 MB at 23:00 to obtain a byte-identical result.

`isStale` and `lastRefreshBoundary` are pure functions with the clock passed in,
so both edges are testable without waiting for a real 08:30 to come around. IST
is UTC+05:30 with no daylight saving, so a fixed offset is correct year-round
and the app needs no timezone database.

**Two related choices.** The cache stores *already-mapped domain data* — rupee
strikes, ISO expiries — not raw broker rows, so the §3.2 hazards are resolved
once at the mapping boundary and cannot re-enter through a cache read. And it
carries a `schemaVersion`: a file written by an older build is discarded and
refetched rather than parsed into something subtly wrong, because a cache that
crashes on upgrade is a bad first launch.

**A stale cache beats an empty screen.** If the refetch fails but a stale cache
exists, the stale list is served. Contracts change once a day and only at the
edges, so yesterday's list is overwhelmingly still correct; refusing to show it
because the network blipped would be strictly worse for the user.

## 2026-09-10 — The retry decision, made per provider rather than inherited

The Phase 1 entry above ends by noting that Riverpod 3's automatic retry is
right for *idempotent reads that fail transiently* and wrong for *anything a
user is waiting on that failed because their input was wrong*, and says to carry
that into later phases. Phase 2 is the first place both kinds appear in one
file, so the decision is recorded per provider rather than inherited by
accident.

- **`contractsProvider` keeps the default retry, deliberately.** It reads a
  public 32.5 MB file over HTTP. Nothing the user typed can make it fail; the
  failures are transient — a flaky connection, a CDN hiccup — and an identical
  retry is exactly the right response. The user is not waiting on a decision
  they made, so backing off and trying again costs them nothing.
- **`searchResultsProvider` is a plain `Provider`.** Filtering an in-memory list
  is synchronous and cannot fail, so there is nothing to await and nothing that
  could ever be worth retrying.

This is the mirror image of `AuthController`, and the contrast is the point: the
same framework default is correct in one place and actively harmful in the
other. Inheriting it silently in either direction would be the bug.

**No debounce on the search field**, for a related reason. Debouncing exists to
avoid firing a request per keystroke, and §5.3 is explicit that there is no
request here to fire — the search is a synchronous filter over ~1,600 records
already in memory. A debounce would add lag to solve a problem the architecture
had already removed.

## 2026-09-10 — Phase 2 dependencies: `path_provider` and `dart:io`

Two choices worth stating, both taken to keep the dependency surface small.

**`path_provider` was added; it is the only new package in Phase 2.** §6's
"second launch uses cache with no network call" needs somewhere durable to
write, and nothing in `dart:io` can locate the Android app documents directory
without a platform channel. `shared_preferences` was rejected: it is a key/value
store, and putting a ~200 KB serialised list into one of its values is off-label
use that buys nothing over a file.

**The fetch uses `dart:io`'s `HttpClient` rather than `package:http`.**
`package:http` is already resolved transitively via Firebase, so promoting it
would have downloaded nothing — but `dart:io` is what Phase 0 step 2 already
proved against this exact endpoint, and Phase 3's WebSocket is `dart:io` too, so
the data layer stays on one networking stack. The testability argument for
`package:http` does not apply here either: the seam a test overrides is
`InstrumentMasterClient`, not the HTTP library beneath it.

`InstrumentMasterClient` exists as an interface for exactly one reason worth
naming — it lets a test **count fetches**. "Uses the cache with no network call"
is an assertion about something *not* happening, and a call count is the only
way to state that as a test rather than as an observation. It is the same
regression-guard shape Phase 1 used to pin the Riverpod retry behaviour.

## 2026-09-10 — Why the parser is a top-level function taking a String

`parseNiftyOptions` takes the raw JSON string and returns finished domain
objects, which looks like an awkward signature until you see what it is shaped
for: it is the function handed to `compute()`.

`compute()` spawns a background isolate and copies values across the boundary,
so the signature determines what gets copied. Taking the raw string and
filtering *inside* the isolate means the 32.5 MB payload and the 145,599
intermediate maps never leave it — only the ~1,600 surviving `OptionContract`s
are copied back. Decoding in the isolate but filtering after it would copy all
145k objects across and defeat the entire exercise.

That is also why every function in the file is pure and top-level with no
Flutter import: an isolate entry point cannot close over state, and the purity
is what makes the four §3.2 hazards testable against the recorded fixture with
no network and no device.

**A malformed row is skipped, not fatal.** One bad record out of 145,599 must
not empty the search screen, and the broker adds instrument types without
notice. But an *empty* result after filtering is treated as an error rather than
as "no matches": that means the §3.2 filter stopped matching, which is a schema
change, and failing loudly beats a search screen that silently returns nothing
forever.

## 2026-09-10 — Phase 2 acceptance run: all §6 criteria pass

Run on the `Medium_Phone` emulator (Android 16, API 36) from an installed debug
APK rather than a `flutter run` session, for the reason Phase 1 recorded:
force-stopping the app under `flutter run` kills the debug VM connection, so a
relaunch test done that way proves nothing.

| §6 criterion | Result |
|---|---|
| `grep -rn "Scaffold" lib/` matches only `template.dart` | **pass** — one construction site, in `template.dart`; also asserted by `architecture_test.dart` |
| searching a strike returns correctly sorted results | **pass** — `21900` returned that strike only, ordered 15 Sep → 22 Sep → 29 Sep → 6 Oct → 13 Oct, CE before PE at each |
| nearest expiry marked | **pass** — only the 15 Sep pair carried the "Nearest" chip; the four later expiries were correctly unmarked |
| empty-result state renders | **pass** — "No contracts match that search." with guidance, not an error |
| second launch uses cache with no network call | **pass** — see below |
| logout reachable from the search screen | **pass** — returns to sign-in, and the back gesture does not re-enter |

Gates: `flutter analyze` clean including warnings, 78 tests green (31 from
Phase 1 plus 47 new), `dart analyze tool/` clean.

**The cache criterion was proven in airplane mode, not by reading a log.** The
app was force-stopped, the radios were disabled *and* airplane mode enabled, and
only then cold-launched. The full contract list rendered. With no network there
is no fetch that could have succeeded, so the list can only have come from disk
— which is a stronger claim than any log line, since a log line proves what the
code *believed* it did.

The cache file confirms the isolate-filtering decision materially: 242 KB on
disk, against the 32.5 MB that was fetched. Only the filtered, already-mapped
contracts are persisted, exactly as intended.

**The device run exercised real data, not the fixture.** The 590-contract
Phase 0 fixture holds three expiries; the live app fetched and displayed five,
including 6 Oct and 13 Oct 2026. So the `DDMMMYYYY` parser, the ÷100 strike and
the CE/PE derivation were all confirmed against the full live instrument master
on-device, not only against the recorded slice the unit tests use.

**One thing worth noting for Phase 4.** The search screen currently renders
every contract when the query is blank — 1,588 rows through a `ListView.builder`,
which is lazy and showed no jank. If the detail screen later wants a heavier row,
this is the point to check again rather than assume.

## 2026-09-11 — Phase 0 completed: steps 6 and 7 captured live

The market reopened and the last two Phase 0 steps ran in-window, closing the
only dependency in the project that could not be manufactured at any other
hour.

**Step 6 verified every §3.4 offset against a live packet.** 379 bytes exactly,
mode 3, exchange type 2, and the 25-byte null-padded token round-tripped to
`"57379"`. All required fields populated.

The ÷100 divisor is confirmed by something better than a plausible-looking
number: **the offsets corroborate each other.** The decoded LTP of ₹10.60 sat
between the best bid (₹10.70) and the day's low (₹8.15), with a coherent
five-deep book either side and a ₹0.10 spread. A wrong divisor would have to be
wrong identically at offsets 43, 91–115 and 147+ to produce that consistency,
which is not how a single misplaced constant fails.

**Step 7 recorded `test/fixtures/feed_session.bin`** — 141 SNAP_QUOTE packets
over 180 seconds of real wall clock, 53.9 KB, verified to read back record-for-
record. The file was scanned for credential material before committing: zero
ASCII runs of 12 characters or more, every record mode-3 market data.

### The one-sided book could not be captured, and that is a finding

§3.5 trap 5 says an illiquid strike may have no resting orders on a side at all.
Step 7's "illiquid" pick produced a 4-buy/5-sell book — uneven, but not empty.

So a second script, `tool/08_record_thin.dart`, subscribed five deep strikes at
once — 15000PE, 16500PE, 18000PE, 31500CE and 34500CE, roughly 40% out of the
money — and kept only packets with an empty side. Over two minutes it saw
thirteen packets and kept **none**: every one of those strikes was quoted
five-deep on both sides.

That is worth recording rather than working around. Nifty index options are
liquid enough that a fully one-sided book is rare intraday; it is a near-expiry
and auction phenomenon, not an everyday one. The decoder must still handle it —
it does, and `tick_decoder_test.dart` covers it — but with **synthetic packets,
and the test says so in a comment**. Claiming fixture coverage that does not
exist would be worse than the gap.

## 2026-09-11 — The tick decoder, and how it avoids being confidently wrong

The highest-risk file in the project, for a reason that is easy to state and
easy to underestimate: Upstox would have sent Protobuf and `protoc` would have
written this file. Angel One sends raw little-endian bytes at fixed offsets, so
every field is hand-written and **a wrong offset does not throw**. It produces a
plausible number and poisons everything downstream silently.

Three things defend against that, and only the third is unusual.

1. **Offsets are named constants carrying the §3.4 table in a doc comment.** A
   bare `getInt64(115)` is unreviewable; `_Offsets.close` next to the table is
   checkable in seconds. Unused offsets were deleted rather than kept "for
   completeness" — a constant nothing reads is one that can drift out of step
   with the wire format without anything noticing.

2. **The tests decode the real recording**, not packets written by the same
   person who wrote the decoder. That distinction is the whole point: a
   synthetic-only test proves the author is self-consistent, not that the
   offsets match what Angel One sends. Both would encode the same
   misunderstanding.

3. **The expected values were extracted by an independent script.** Before
   writing a single assertion, the fixture was read with a short Python program
   that knows nothing about the Dart code, and the test asserts *those* numbers.
   Had the Dart decoder been used to generate its own expectations, the test
   would have asserted only that the decoder is deterministic.

**Verified non-vacuous.** Shifting the `close` offset by 8 bytes — one field,
the kind of error this file exists to prevent — turns three tests red. A decoder
test that cannot fail is worse than none, because it manufactures confidence in
precisely the place confidence is least warranted.

`close == 0 → null` lives on the entity rather than in the decoder, because it
is a property of the domain rather than of the wire format, and the nullable
return type is what forces every render site to decide what to show. The test
includes a vacuity check that the unguarded arithmetic really does produce a
non-finite double.

## 2026-09-11 — The book is scanned by flag, not by position

§3.4 says best-five entries 0–4 are buys and 5–9 are sells, and every packet in
the recording honoured that. The decoder reads the flag anyway.

The reasoning is that the flag is what the *protocol* defines as authoritative,
while the ordering is what the *server happened to send today*. An illiquid
strike is simultaneously where a surprising layout is most likely to appear and
the case nobody checks by hand — so trusting position would be reading the
layout instead of the data, in exactly the situation where they might differ.

A test puts the only sell in slot 0 and the only buy in slot 9 and asserts both
are read correctly. It fails immediately against a position-based decoder, which
is what makes the choice defensible rather than merely cautious.

Best bid is the **highest** buy and best ask the **lowest** sell, rather than
the first of each. Taking the first would reintroduce the same dependence on
server ordering that the flag scan exists to remove.

## 2026-09-11 — Three Phase 0 findings, turned into code

The feed connection is shaped by measurements rather than by the spec's original
text, and each one would be a bug if ignored.

**Backoff starts at the first retry, not after a few failures.** Phase 0 found
that opening sockets in quick succession gets refused — and that the refusal is
`HttpException: Connection closed before full header was received`, *the same
error an unauthenticated handshake produces*. There is no 429 and no
`Retry-After`. So a tight retry loop is not merely impolite; it is the thing
keeping the socket shut, while looking exactly like a credential problem. A test
asserts no immediate retry happens.

**That error is classified retryable, never fatal-auth.** This is the
highest-consequence line in the file. Mapping throttling onto a credential
failure would discard the broker session over a two-second delay, turning it
into a full re-login — and under the two-auth-systems rule a broker failure must
never be able to reach the app's sign-out. Two tests pin it: the throttle string
produces `FeedReconnecting`, and a genuine 401 produces `BrokerAuthFailure` and
explicitly *not* `AuthFailure`.

**Frames are discriminated by type, not content.** The server replies `"pong"`
as text and sends one on connect before any ping is sent. Market data is binary.
A handler assuming every frame is a packet would try to parse `"pong"` as one.

**The staleness watchdog is gated on the clock**, because Angel One sends no
segment-status frame. A quiet socket at 16:00 is a closed market, not a dead
connection, and reconnecting on that would be a retry loop that cannot succeed —
straight into the rate limit for nothing. Both sides of the gate are tested with
an *advancing* fake clock; a frozen one would make the market-closed case pass
because no time appeared to elapse rather than because the gate held, which is a
test passing for the wrong reason.

## 2026-09-11 — Conflation, and a subscription leak it found

§5.7: ingest every tick, render at ~10 Hz. **Conflate, do not debounce.** A
debounce waits for a quiet gap, and under a live feed that gap never arrives —
the screen would appear frozen during exactly the bursts a trader cares about.
Conflation emits the newest value on a schedule instead, so the render rate is
bounded and the displayed value is never stale by more than one interval. A test
drives continuous traffic at 20 ms intervals and asserts the screen keeps
updating, which is the case a debounce fails outright.

**Conflation is lossless *here specifically*, and the qualifier is the
interesting part.** Every SNAP_QUOTE packet is a complete snapshot rather than a
delta, so the newest tick contains everything a dropped one did. If this app
ever built candles or VWAP it would have to process every tick and conflate only
at the render boundary. The distinction is the difference between a safe
optimisation and silent data loss.

The first tick is emitted immediately rather than waiting out an interval: on
opening a screen, a 100 ms blank reads as "still loading" rather than "live", and
there is nothing to conflate when only one value has arrived.

**The lifecycle test found a real bug.** `stop()` awaited the upstream
subscription's cancellation *before* sending the unsubscribe frame, and that
future did not resolve — so the frame was never sent. In production that meant
every back-navigation leaving the server streaming a token nobody was reading:
precisely the socket leak §5.4 warns about, and one that "open Detail,
immediately pop, repeat rapidly" in Phase 5 would have surfaced as a mystery.

The fix stops the local side synchronously, then awaits the in-flight
*subscribe* before unsubscribing — because backing out faster than the subscribe
completes would otherwise make the removal a no-op, after which the subscribe
would land and stream forever. Tying the subscription to the stream's lifetime
is what makes "cleanly closed" structural; this bug is a reminder that
structural still has to be tested.

## 2026-09-11 — Config: two classes, and an honest security note

Phase 1 deferred the broker-credential decision to Phase 3. The answer is
`--dart-define`, in a **`BrokerConfig` separate from `AppConfig`**.

The separation is the two-auth-systems rule made structural. A single config
class holding both the Google client ID and the Angel One credentials would be
exactly the cross-reference CLAUDE.md forbids: any file wanting the client ID
would also hold a trading credential, and the architecture test that scans the
auth layer for broker vocabulary would need exceptions. Two classes cost one
file.

**The security position, stated plainly because the honest answer is
uncomfortable.** These credentials authenticate a *full trading account* — Angel
One issues no read-only market-data credential, which is the single biggest
thing lost in the move from Upstox. Neither `--dart-define` nor a bundled `.env`
protects them from anyone holding the APK: a dart-define is a compiled-in string
recoverable with `strings`, and a `.env` asset is a file recoverable by
unzipping. **Neither is encryption and neither should be described as security.**

`--dart-define` wins on operational grounds only: it cannot be committed by
accident, and it keeps credentials out of the asset bundle so no runtime code
path or crash reporter can pick them up. The app is read-only *by construction*
and a test fails the build on any mutating endpoint — but that is a property of
this code, not of the credential. The README is where this gets said to a
reader rather than to a compiler.

An unconfigured build still runs: auth and contract search work without broker
credentials, and only the feed is unavailable. A hard failure would make the app
unlaunchable for a reviewer who has no Angel One account.

## 2026-09-11 — TOTP is tested against the RFCs, not against itself

Every other test in this project compares our code to our fixture or our
reasoning. The TOTP tests compare it to RFC 4226 and RFC 6238 — published ground
truth that exists entirely independently of this implementation. All ten HOTP
vectors and all five SHA-1 TOTP vectors pass.

That is worth the effort because a broken TOTP presents as `AB1050 Invalid totp
and client combination`, which is indistinguishable from a wrong secret, a
rotated secret, or an account with no TOTP registered. Phase 0 lost real time to
exactly that ambiguity and resolved it only by ruling the arithmetic out first.
These tests make that a permanent, instant answer rather than an investigation.

Two smaller choices follow from the same instinct. `generateHotp` is separated
from `generateTotp` so the counter-based RFC vectors can be asserted directly
rather than through a timestamp. And the base32 decoder reports the *position*
of an invalid character, never the character — because the character is part of
a secret, and an error message is a thing that gets logged.

The login path waits for the next time step when the current one has under three
seconds left. A code that expires mid-flight fails as `AB1050`, so two seconds of
latency buys the removal of an ambiguity that costs far more.

## 2026-09-11 — Phase 3 acceptance: all §6 criteria met

| §6 criterion | Result |
|---|---|
| unit tests decode the recorded fixture into correct `MarketTick`s | **pass** — all 141 packets, with values read out by an independent script |
| a known packet decodes to the Phase 0 LTP, proving ÷100 | **pass** — ₹10.75, corroborated by the book and day range |
| `close == 0` yields a null percent change | **pass** — plus a vacuity check that the unguarded maths is non-finite |
| a short packet is rejected rather than read past its end | **pass** — truncated, 51-byte LTP-mode, empty, and wrong-mode all rejected |
| a one-sided book yields a null `BookLevel` | **pass** — synthetic by necessity; see the step 7b finding above |
| a fake socket proves backoff, the 10s ping, and resubscribe | **pass** — 15 tests under a fake clock |
| replay emits ticks with realistic timing | **pass** — recorded gaps reproduced within 2 ms, with a guard proving the gaps are genuinely uneven |
| no Flutter import anywhere in `data/broker/` | **pass** — asserted by `architecture_test.dart` |

Gates: `flutter analyze` clean including warnings, **175 tests** green (95 of
them new in this phase), `dart analyze tool/` clean.

No UI work, per §6. The detail screen is Phase 4.

## 2026-09-11 — Replay when the market is shut, and only then

The app is handed to the client on a **Saturday**. The reviewer's headline
graded criterion is *"live data actually streams and updates"* (§2). Without
intervention they would open the detail screen, see a correct and honest
"market closed" state, and have no way to observe streaming at all.

The replay connection built in Phase 3 already solved this — it was tested,
reproduced the recorded timing within 2 ms, and was wired to nothing a user
could reach. Phase 4 wires it.

**The rule, and the part that was corrected during planning.** My first proposal
was "replay whenever live data is unavailable", which quietly included *missing
broker credentials*. That was wrong, and the correction is worth recording
because the reasoning generalises:

```
market open + credentials    -> LIVE
market open + no credentials -> a setup error naming the missing keys
market closed                -> REPLAY
```

A shut exchange is an **expected condition nobody can fix**, so a labelled
recording is the most useful honest answer. Absent credentials are a **fixable
defect**, and routing them to replay would hide a broken live integration behind
something that looks like it works — the reviewer would never learn the real
path was misconfigured, which is the opposite of what a demo is for.

The general principle: when adding a fallback, enumerate what reaches it and ask
of each condition whether it is *expected* or a *defect*. Defects get an error
naming what is missing. Only expected conditions get the fallback. Collapsing
the two because the code path is convenient is how a broken build ships looking
healthy.

`resolveFeedSource` is a pure function in `domain/` taking the market status and
the configuration, so all three branches are unit-tested without a clock or a
socket, and "why am I seeing replay?" has exactly one place to read the answer.

### The banner is part of the feature, not decoration

A recording that ticks convincingly is **indistinguishable from a live feed**
unless the app says otherwise. So the banner is pinned above the content, cannot
be dismissed, and names three things: that it is a replay, when it was recorded,
and **which instrument** — because replay streams what was captured rather than
whichever row was tapped. Letting a reader believe the recording matched their
selection would be the dishonest version of this feature.

`ReplayFeed` carries `recordedAt` in the type rather than looking it up
separately, because a banner reading "replay" is ambiguous while one reading
"recorded 11 Sep 13:55" cannot be misread as live.

### What ships in the APK

The fixture moved from `test/fixtures/` to `assets/demo/` — `test/` is not
bundled, and the replay needs it at runtime. That means **real Angel One market
data ships inside the handover build**, which was a decision to take explicitly
rather than quietly: it was scanned before committing and again by an
architecture test, which fails the build if any run of twelve or more printable
characters appears in it. Binary market data contains none; a JWT, an API key or
a base32 secret would all trip it.

**No `ANGEL_*` credential ships in the APK.** Those arrive by `--dart-define` at
build time and a build without them is still fully usable — auth, search, and
replay all work. That is what makes the app reviewable by someone who has no
Angel One account at all.

## 2026-09-11 — Conflation extracted, so the demo cannot diverge from production

Phase 3 put the §5.7 conflation inside `MarketDataRepositoryImpl`. Phase 4 needs
the same shaping on the replay path, and copying it would have been the obvious
mistake: two implementations drift, and the one that drifts is the demo — the
version a reviewer actually watches.

So it is now a standalone `conflate` transformer shared by the live path, the
replay path and the repository. **A demo that rendered differently from
production would be demonstrating the wrong thing**, and the only way to
guarantee it does not is to make the two the same code.

The transformer keeps the properties that mattered: the first value is emitted
immediately (a 100 ms blank on open reads as "still loading" rather than
"live"), a burst collapses to one emission per interval with the newest value
winning, a pending value is flushed on close rather than swallowed, and errors
pass straight through rather than being conflated away.

## 2026-09-11 — `autoDispose.family`, and why §4.3 called it load-bearing

`tickProvider` is a `StreamProvider.autoDispose.family<MarketTick, String>`.
§4.3 named this the load-bearing reason for choosing Riverpod, and Phase 4 is
where that claim gets cashed.

One live subscription per instrument, torn down when nothing watches it, maps
exactly onto the provider's lifetime. So the graded requirement — *the
subscription is cleanly closed when the user backs out* — is **structural**:
there is no code path that skips it, because there is no code path that owns it.
The `ref.onDispose` carries the unsubscribe and the log line §6 criterion 2 asks
for, and the replay branch stops its timer the same way, so a closed screen
never leaves one running behind it.

This is the same guarantee the Phase 3 subscription-leak bug violated by hand.
Structural is better than careful, but the Phase 3 fix is the reminder that
structural still has to be tested.

## 2026-09-11 — Formatting is pure, because that is where the layout breaks

§7 rules out widget tests, so anything that could break a layout lives in pure
functions and is tested directly.

**Three-digit percentages** (§6 criterion 4) are the case §3.5 trap 4 warns
about: ±200% in a day is *ordinary* for an option, not an edge case. The
formatter is width-agnostic and `PriceHeader` uses a `Wrap` rather than a fixed
`Row`, so "+212.50%" moves to its own line instead of overflowing. The test
inputs are **synthetic, and say so**: two live captures on 11 Sep — one liquid
strike and six near-expiry OTM calls — reached only −33%, so no recorded fixture
contains a three-digit move. That is the same posture taken for the one-sided
book in Phase 3, and for the same reason: claiming fixture coverage that does
not exist is worse than naming the gap.

**Absent values render an em dash, never a zero.** `₹0.00` reads as a real quote
at zero, which is a different and wrong claim from "there is no quote". This
covers the null percent change when `close == 0` and the empty book side from
§3.5 trap 5 — criterion 5 falls out of the formatter rather than out of the
widget.

**Quantities use Indian digit grouping**: 710190 renders as 7,10,190, not
710,190. The app shows Indian market data to a reader who thinks in lakhs, and
western grouping of a six-figure open-interest number reads as foreign.

## 2026-09-11 — §3.4 corrected: OI change is a float64, and how it was missed

The detail screen rendered **`+4581235513960227840.00%`** the first time it ran
on a device. §3.4's table lists offset 139 as an `int64`, the decoder believed
it, and 4.6e18 is what that field contains when read as an integer. As a
`float64` it reads −5.82 to +2.11 across two independent live captures — a
plausible OI change.

The spec was wrong. `docs/SPEC.md §3.4` is corrected.

**The interesting part is why 29 passing tests did not catch it.** Every
assertion aimed at that field had been written from the same premise as the
decoder — that the field is an integer — so the test and the code agreed with
each other while both disagreed with reality. This is the exact failure mode the
Phase 3 entry claimed to have defended against by decoding a *real* fixture
rather than synthetic packets, and the defence turned out to be incomplete: the
fixture was real, but nothing asked whether the decoded *value* made sense.

A round-trip test cannot find an error of this shape. The question it answers is
"did we read back the bytes we wrote", and here the bytes were read back
perfectly — as the wrong type. Only a **plausibility** test can find it, because
the only thing wrong with 4.6e18 is that no option has ever had that OI change.

So the suite now asserts ranges rather than only values:

- every decoded double is finite and under 1e9 — a blanket guard that trips on
  any future offset error large enough to matter, with no per-field assertion
- day OHLC is internally consistent (`high >= low`, LTP inside the range)
- circuit limits bracket the traded price

Reverting the fix turns two of these red.

**One of those checks immediately found real data I had assumed away.** The OHLC
assertion failed on the illiquid strike, which reports `high == low == open == 0`
while still carrying an LTP of ₹0.60 — because it has not traded *today* and the
LTP is from an earlier session. That is not a decode error; it is what an
untraded contract looks like, and asserting a day range over it would have been
asserting that every contract trades every day. The check now skips a zero high
and says why.

**Two general lessons worth keeping.** First, a fixture makes a test *real* but
does not make it *sufficient* — "we decoded the recording" and "the recording
decoded into sensible numbers" are different claims, and only the second would
have caught this. Second, the field was one of the §3.4 *bonus* fields, which is
precisely why it survived: the required fields were checked against Phase 0's
live step-6 output, and this one never was.

## 2026-09-11 — The logger reaches logcat in debug builds

§6 Phase 4 asks that back-navigation unsubscribing be **proved with a log
line**. It could not be: `developer.log` reaches the VM service — DevTools and
`flutter run` — but not logcat, so nothing was visible when checking an
installed APK with `adb logcat`. A proof nobody can read is not a proof.

`Log._emit` now also calls `debugPrint` under `kDebugMode`. Release builds stay
silent, the `avoid_print` ban is untouched (`debugPrint` is not `print`), and
the single-chokepoint rule still holds — this is the one place a message reaches
stdout, and the same no-credential-material rule applies there.

Verified on device: pressing back prints
`[nifty] Replay stopped; screen closed` at the moment of navigation.

## 2026-09-11 — Phase 4 acceptance: all §6 criteria met

Run on the `Medium_Phone` emulator from an installed debug APK, **with the
market closed** — deliberately, because that is the client's actual condition
at handover.

| §6 criterion | Result |
|---|---|
| values update live (or under replay) | **pass** — bid ₹10.75→₹10.80, spread ₹0.10→₹0.05, volume 7,10,190→7,10,255 across successive captures |
| back-navigation unsubscribes, proved with a log line | **pass** — `[nifty] Replay stopped; screen closed` in logcat on back |
| market-closed distinguishable from disconnected | **pass** — separate `FeedState` branches; closed carries a labelled replay, dropped shows reconnecting |
| three-digit percentages do not break the layout | **pass** — `Wrap` rather than `Row`; formatter tested to ±9900%, inputs synthetic and stated as such |
| an illiquid strike with a one-sided book renders | **pass** — em dash per side, spread and mid null, no crash |

Gates: `flutter analyze` clean including warnings, **214 tests** green,
`dart analyze tool/` clean.

The replay banner reads
`REPLAY · Recorded 11 Sep 13:55 · NIFTY22SEP2624150CE · market closed`
throughout, so the streaming on screen cannot be mistaken for live data.
