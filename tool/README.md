# Phase 0 verification harness

Throwaway scripts that prove the Angel One facts in `docs/SPEC.md` §3 against the
live API **before** any app code depends on them. Not part of the app; deleted or
left inert once Phase 1 begins.

Plain Dart — no Flutter needed:

```bash
dart pub get
dart tool/01_login.dart
```

| Script | Phase 0 step | Proves | Needs |
|---|---|---|---|
| `_shared.dart` | — | redaction, TOTP, headers, session cache | — |
| `01_login.dart` | 1 | TOTP login; all three tokens; which headers are genuinely required | `.env` |
| `02_instruments.dart` | 2 | §3.2 field shapes; writes `test/fixtures/nifty_options.json` | nothing (unauthenticated) |
| `03_ws_handshake.dart` | 3 | four-header handshake; no 302; rejection shape | session |
| `04_ping_proof.dart` | 4 | the 10s ping is mandatory (A/B: unpinged dies, pinged survives) | session |
| `05_refresh.dart` | 5 | `generateTokens` yields a *usable* jwt with no fresh TOTP | session |
| `06_snapquote.dart` | 6 | every §3.4 offset and the ÷100 divisor | session + **market hours** |
| `07_record.dart` | 7 | records `test/fixtures/feed_session.bin` | session + **market hours** |

Steps 6–7 need 09:15–15:30 IST on a weekday. Everything else runs any time.

## Secrets

Every value from `.env` or a broker auth response goes through `redact()` before
it is printed — length and last four characters only. `redactJson()` masks by key
name so a whole auth body can be printed safely. **Do not add a `print` that
bypasses these.**

`tool/.session.json` caches live tokens so steps 3–7 need one login rather than
one per script. It is gitignored. Delete it when you are done:

```bash
rm tool/.session.json
```
