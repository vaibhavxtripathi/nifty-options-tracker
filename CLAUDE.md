# Project: Live Nifty Options Tracker (Flutter)

A Flutter app: user signs in, searches a Nifty option, and watches live market
data stream over a WebSocket from Upstox. Read-only. No order placement, ever.

Full specification: `docs/SPEC.md`. Read the relevant phase section before
starting work. Do not guess at API shapes — every broker field name, endpoint
and enum you need is written down in `docs/SPEC.md §3`. If something you need
isn't there, stop and ask rather than inventing it.

## Working agreement

1. **Plan before code.** At the start of a phase, restate the goal, list the
   files you'll create or change and why, and wait for my approval. Use plan
   mode. Do not begin editing until I say go.
2. **One phase per session.** Never start the next phase unprompted, even if
   the current one finishes early.
3. **Explain as you go.** After implementing anything non-obvious — the tick
   decoder, the reconnect state machine, the conflation logic — write a short
   plain-English explanation of how it works and why it's built that way.
   Append it to `docs/DECISIONS.md`. I need to be able to defend every line of
   this codebase in an interview; code I can't explain is worse than no code.
4. **Ask rather than assume.** If a requirement is ambiguous, ask one specific
   question. Do not pick an interpretation silently.
5. **Small commits.** One logical change per commit, conventional-commit style
   (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`). Commit at the end of each
   phase at minimum.

## Definition of done (every phase)

- `flutter analyze` reports zero issues — warnings included, not just errors
- `flutter test` passes
- The phase's acceptance criteria in `docs/SPEC.md` are each demonstrably met
- `docs/DECISIONS.md` updated if anything non-obvious was built
- Committed

Never mark a phase complete with a failing analyzer. Fix it or tell me why it
can't be fixed.

## Architecture rules (non-negotiable)

- **Dependencies point inward.** `presentation/` → `domain/` ← `data/`.
  `domain/` imports nothing but `dart:core` and pure Dart packages — no
  Flutter, no Firebase, no http, no protobuf-generated types. The test: delete
  `presentation/` and everything else still compiles.
- **Two independent auth systems.** Firebase governs *who may open the app*.
  The Upstox token governs *whether market data flows*. Different trust
  domains, different lifetimes, different failure types. They never reference
  each other. A broker failure must never sign a user out.
- **No Scaffold outside `template.dart`.** Screens supply a body; the template
  owns all chrome. `grep -rn "Scaffold" lib/` should only match
  `template.dart`.
- **Decoding is pure.** Bytes → domain object, with no I/O, no state, no
  Flutter import. Unit conversion and null-guards happen at that boundary and
  nowhere else.
- **No business logic in widgets.** Widgets read state and render. Anything
  that computes, transforms, retries or subscribes lives below them.

## Hard prohibitions

- **Never write, print, log or commit a secret.** No token, app secret, API
  key or `.env` content in source, in logs, in test fixtures, in commit
  messages, or in `docs/`. If you need a value, reference the env var name.
- **Never commit `.env`.** It is gitignored from the first commit. Maintain
  `.env.example` with empty values instead.
- **Never implement order placement**, or any Upstox endpoint that mutates
  state, even as dead code, even commented out. Read-only endpoints only.
- **No `localStorage`/`sessionStorage`.** Irrelevant here; flagging in case of
  web experiments.
- **Don't hand-roll auth session persistence.** Firebase already persists and
  restores sessions. Gate routing on `authStateChanges()`.
- **Don't add packages I haven't approved.** Propose, with a one-line reason,
  and wait.

## Style

- Dart 3. `sealed` classes for closed hierarchies, `final class` for leaves.
- Prefer explicit types on public APIs; infer locally.
- Name things after what they are in the domain: `previousClose`, not `cp`.
  Broker field names stop at the mapping boundary.
- Comments explain *why*, never *what*. No comment that restates the code.
- No `print`. Use a single logger, and never log token values or raw auth
  responses.
