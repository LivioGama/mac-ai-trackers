# Vendor plugin framework

## Goal

Turn the codebase into a plugin-ready foundation so adding a new AI assistant follows a single, well-defined contract — auth retrieval, usage fetching, payload normalization to the persisted JSON shape, vendor branding, status fetching, and active-account monitoring — instead of being copy-pasted off the previous connector and drifting.

## Dependencies

None.

## Scope

- A `docs/VENDOR-PLUGIN-CONTRACT.md` spec describing every required plugin point (protocols, value objects, wiring) with cross-references to the existing Swift quality docs.
- A `VendorBundle` (or equivalent) value type that ties together a vendor's connector, status connector, active-account monitor, branding, and metadata so `AppDelegate` composes assistants from a registry rather than naming each one explicitly.
- A standardized **dated** API research document per assistant under `docs/vendors/<vendor>.md` covering: endpoints called, plan variants observed (free / paid / enterprise), payload shapes, time-window vs pay-as-you-go vs per-request semantics, reset cadences, error codes, and source references (community write-ups, official docs). Every claim is stamped with the date it was verified, so a future contributor noticing a drift can immediately tell what the API used to look like and when.
- Refactor of the three existing connectors (Claude Code, Codex, Copilot CLI) onto the new contract without behavioral changes or test-coverage loss.
- A skill-driven scaffolding flow (no shell script) that emits the boilerplate skeleton for a new assistant: connector actor, credential locator, status connector, active-account monitor, branding entry, vector PDF icon stub (`<vendor>-mark.pdf`), test fixtures. The actual scaffolding is performed by the implementation skill defined in the [new assistant onboarding workflow](new-assistant-onboarding-workflow.md) epic — this epic only locks down the **shape** the skill must produce.
- A **payload-sanitization contract** every connector and credential locator must satisfy: any payload (request body, response body, header, error message) emitted to a log MUST go through a vendor-specific sanitizer that strips confidential fields (tokens, API keys, raw cookies, refresh tokens, email-like patterns, account ids the vendor treats as secret). Sanitization is enforced at the logger boundary — not at the call site — so it cannot be bypassed by a future "just this once" debug log. The contract requires a unit test per connector that feeds a realistic full payload through the sanitizer and asserts none of the seeded secrets survive in the output.

**Out of scope**

- Runtime dynamic plugin loading (dlopen, external dylibs). The framework stays compile-time.
- Breaking the public JSON schema of `usages.json` or `usage-history/*.jsonl` — the contract must reuse the existing `UsageMetric` discriminator.
- Implementing any new vendor as part of this epic — it is purely a refactor + documentation effort.
- Generalizing storage, logging, or scheduler beyond what is needed to express the contract.

## Acceptance criteria

- `docs/VENDOR-PLUGIN-CONTRACT.md` exists, lists every plugin point, and is referenced from `CLAUDE.md`'s lazy-loaded context section.
- All existing assistants are exposed through the registry; `AppDelegate` no longer references concrete connector or monitor types one by one.
- Each existing assistant has a corresponding `docs/vendors/<vendor>.md` populated, with a top-level `Last verified: YYYY-MM-DD` header and per-section verification dates.
- A new assistant can be onboarded by adding files under predictable paths (connector, monitor, vendor doc, branding asset) plus one registry line — no edits to `AppDelegate`, `Loggers`, or other shared subsystems beyond their declared plugin points.
- The credential-locator abstraction never stores, encrypts, or persists tokens — it only reads them from external sources owned by the vendor's own CLI (env var, Keychain entry written by the vendor's CLI, or on-disk config file written by the vendor's CLI).
- Every connector ships a `PayloadSanitizing` implementation, a documented list of fields it considers confidential (in `docs/vendors/<vendor>.md`), and a leakage test that exercises that list against a realistic full payload.
- Test coverage for existing connectors is unchanged or higher after the refactor.

## Notes

- See `vendor-plugin-framework.plan.md` for the deep research (current-state inventory, proposed contract, dating discipline for vendor docs, migration plan, open questions).
- The contract must compose with `docs/SWIFT-VALUE-OBJECTS.md`, `docs/SWIFT-CONCURRENCY.md`, `docs/SWIFT-TESTABILITY.md`, `docs/SWIFT-ERROR-HANDLING.md`, and `docs/SWIFT-IO-ROBUSTNESS.md` — none of those rules are relaxed for plugin code.
- The `Vendor` value object is the natural primary key; it stays string-backed for forward compatibility (unknown vendors decode without throwing).
- The credential layer is intentionally a **locator**, not a manager: the app never produces, refreshes, or rotates tokens. Each vendor's own CLI (`claude`, `codex`, `gh`) remains fully responsible for credential lifecycle and security.
