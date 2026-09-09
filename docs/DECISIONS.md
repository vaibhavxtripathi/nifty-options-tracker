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
