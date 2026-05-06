# Plan — Vendor plugin framework

This file captures the deep research backing the `vendor-plugin-framework` epic: where the codebase stands today, what a contract should look like, and how to migrate without regressing.

## 1. Current-state inventory

The codebase already has three concrete assistants — Claude Code, Codex (ChatGPT), Copilot CLI — implemented through similar but non-identical conventions. Each touches the following plugin points:

| Plugin point | Where it lives today | Current shape |
|---|---|---|
| Vendor identity | `Models/ValueObjects.swift` (`Vendor`) | String-backed `RawRepresentable` with static constants (`.claude`, `.codex`, `.copilot`). Forward-compatible. |
| Usage fetching | `Connectors/<Vendor>Connector.swift` | Actor conforming to `UsageConnector` (`fetchUsages() -> [VendorUsageEntry]`, `resolveActiveAccount() -> AccountEmail?`). |
| Credential locator | `Connectors/<Vendor>Auth.swift` (Codex, Copilot); `ClaudeCodeConnector` reads its own keychain inline | Per-vendor protocol + actor; **read-only** cascade across env, Keychain entries written by the vendor's CLI, and on-disk config files written by the vendor's CLI. The app never produces, refreshes, or rotates tokens. |
| Status / outages | `Connectors/<Vendor>StatusConnector.swift` | Actor conforming to `StatusConnector` (`fetchOutages() -> [Outage]`). |
| Active-account watcher | `Connectors/<Vendor>ActiveAccountMonitor.swift` | Actor with `start()` / `stop()`, polling the vendor's local config every ~15 s. |
| Branding | `App/VendorBranding.swift` (`brand(for:)` switch) | Per-vendor `Brand { assetName, displayName, tintHex }`; PDF template under `App/Resources/VendorBranding/`. |
| Logging stream | `Logging/Logger.swift` (`Loggers.copilot`, etc.) | One `FileLogger` per vendor + a vendor-agnostic app stream. |
| Wiring | `App/AppDelegate.swift` | Each connector and monitor is constructed and held in its own stored property. |
| Asset generation | `scripts/render-<vendor>-mark.swift` | One-shot SwiftPM script per vendor that converts the vendor's SVG logo into the PDF icon asset (`<vendor>-mark.pdf`) consumed by `VendorBranding`. PDF is used because it's vector — the menu bar renders it at any size without quality loss. |
| API research | (none) | Currently the only "research record" is the commit message of the connector that introduced the vendor. |

### Divergences worth noting

1. **Credential coupling.** Claude Code's credential lookup lives inside `ClaudeCodeConnector`; Codex and Copilot extracted dedicated locator actors. The contract mandates a separate locator so it can be mocked uniformly in tests, and so the read-only stance (no writes, no rotations) can be enforced at a single layer.
2. **Active-account semantics.** Claude monitors a single keychain-derived email, Codex monitors a config file emitting `AccountEmail`, Copilot monitors `gh hosts.yml` and emits a GitHub login wrapped in `AccountEmail`. The contract has to admit any local source — file, process, keychain — under one protocol.
3. **Branding switch.** `VendorBranding.brand(for:)` returns `nil` for unknown vendors, which the UI handles via fallback. A registry replaces the switch and removes the implicit "is this vendor known?" check from each call site.
4. **Logging registration.** Adding a new logger today means editing `Loggers` and `Logger.swift`. The contract should let a `VendorBundle` carry its own `FileLogger` factory so adding a vendor does not need cross-cutting edits.
5. **Metric synthesis.** Copilot synthesizes a 30-day `timeWindow` because the upstream API exposes only a reset date; Claude derives 5-hour and weekly windows; Codex derives daily and weekly. The contract should not hide that synthesis — the connector is free to compose any number of `UsageMetric` cases — but it must enforce the strict ISO 8601 contract on `resetAt` (already validated by `UsageMetric.encode(to:)` in DEBUG).
6. **`unknown` metric kind.** `UsageMetric.unknown(String)` is the forward-compat escape hatch; vendors should never emit it. Contract test: assert connector outputs contain only known kinds.

## 2. Proposed contract

### 2.1 `VendorBundle` value type

```swift
public struct VendorBundle: Sendable {
    public let vendor: Vendor
    public let branding: VendorBranding
    public let usage: any UsageConnector
    public let status: (any StatusConnector)?
    public let activeAccountMonitor: (any ActiveAccountMonitoring)?
    public let logger: FileLogger
    public let documentation: VendorDocumentation
}
```

- `branding` becomes a value type instead of a switch entry; assets live next to their bundle declaration.
- `status` and `activeAccountMonitor` are optional because not every vendor exposes either. The framework treats `nil` as "feature disabled for this vendor" rather than a partial implementation.
- `documentation` is a typed pointer to `docs/vendors/<vendor>.md` plus structured metadata (auth sources, supported plan variants) consumed by the onboarding workflow and the scaffolding tool.

### 2.2 Lifecycle protocol — `ActiveAccountMonitoring`

```swift
public protocol ActiveAccountMonitoring: Sendable {
    var vendor: Vendor { get }
    func start() async
    func stop() async
}
```

The callback signature stays vendor-specific (each monitor accepts its own `onActiveAccountChanged` closure during init), so the protocol only formalizes the lifecycle — wiring it into a single startup loop in `AppDelegate`.

### 2.3 Credential locator (not "auth provider")

The naming "auth provider" is misleading because the app never owns or manages credentials. The app's job is purely to **locate** credentials in storage that the vendor's own CLI already owns and secures (`claude` writes its keychain entry, `codex` writes `~/.config/codex/`, `gh` writes `~/.config/gh/hosts.yml` and the system keychain). The plugin contract reflects this read-only stance:

```swift
public protocol CredentialLocator: Sendable {
    associatedtype Credentials: Sendable
    /// Reads credentials from external sources owned by the vendor's CLI.
    /// The locator MUST NOT write, refresh, rotate, or persist tokens — those
    /// operations belong to the vendor's own tooling.
    func locate() async throws -> Credentials
}
```

Why an associated type instead of a concrete `Credentials` shape:

- Claude Code: OAuth access token from the macOS Keychain.
- Codex: API key + org id from `~/.config/codex/auth.json` or env.
- Copilot CLI: GitHub OAuth token with three-source cascade (`$GITHUB_TOKEN` → `gh` keychain entry decoded from `go-keyring-base64:` → `~/.config/gh/hosts.yml`), plus `tokenSource` provenance for diagnostic logs.

Forcing those into a common struct would either lose information or balloon into a lowest-common-denominator bag of optionals. The associated type keeps each connector's domain credential shape, while the contract ensures uniform invocation and testability.

The contract additionally requires:

- Sources must be injectable: `environment: [String: String]`, `fileManager: FileManager`, `processRunner: ProcessRunning`, `keychainAccessor: KeychainReading` — never direct calls to `ProcessInfo.processInfo` or `SecKeychain*` from the locator implementation.
- Locators MUST NOT call `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`, write to vendor config files, or shell out to `<vendor> auth login` — read paths only. A SwiftLint custom rule should flag these symbols inside any `*CredentialLocator.swift` file.
- Errors are enum cases with associated values per `docs/SWIFT-ERROR-HANDLING.md`, and they distinguish "not logged in" (vendor's CLI never wrote credentials) from "found but unreadable" (file exists but malformed) — the first is a normal user state, the second is a bug or a vendor schema change worth surfacing.

This contract is already compatible with all three existing assistants:

| Vendor | Today's type | Migration |
|---|---|---|
| Claude Code | inline keychain reads inside `ClaudeCodeConnector` | Extract `ClaudeCredentialLocator` actor; connector consumes it. |
| Codex | `CodexAuthProviding` actor | Rename to `CodexCredentialLocator`; signature already matches. |
| Copilot CLI | `CopilotAuthProviding` actor | Rename to `CopilotCredentialLocator`; signature already matches. |

### 2.4 Registry

```swift
public enum VendorRegistry {
    public static let bundles: [VendorBundle] = [
        ClaudeCodePlugin.bundle,
        CodexPlugin.bundle,
        CopilotCLIPlugin.bundle,
    ]
}
```

`AppDelegate` becomes:

```swift
let bundles = VendorRegistry.bundles
let poller = UsagePoller(
    connectors: bundles.map(\.usage),
    statusConnectors: bundles.compactMap(\.status),
    fileManager: fileManager,
    refreshState: refreshState,
    preferences: Self.sharedPreferences
)
for bundle in bundles {
    await bundle.activeAccountMonitor?.start()
}
```

No more named per-vendor properties.

### 2.5 Payload sanitization and verbose-vendor logging

Two related concerns sit in the same plugin point:

- **Always-on sanitization.** Every payload (request body, response body, headers, error messages) flows through a vendor-specific sanitizer before reaching any log file, regardless of log level. This is a contract invariant, not a debug-mode feature — there is no code path that produces "raw" logs.
- **Verbose vendor mode** (consumed by the workflow epic). One vendor at a time can be in tester-debug mode, in which the connector emits at `.debug` level the *sanitized* payloads of every API exchange. This is what nightly builds attached to a `type:new-assistant` PR enable for the vendor under test, so testers can attach those logs to their sign-off.

#### Sanitization protocol

```swift
public protocol PayloadSanitizing: Sendable {
    /// Returns a copy of `payload` with confidential fields stripped or masked.
    /// MUST be idempotent and side-effect free.
    func sanitize(_ payload: Data) -> Data
    func sanitize(_ headers: [String: String]) -> [String: String]
    func sanitize(_ message: String) -> String
}
```

Each `VendorBundle` carries its own `sanitizer: any PayloadSanitizing`. The connector NEVER calls the logger directly with a raw payload — it goes through a thin `LoggingProxy` that pipes everything through `bundle.sanitizer` first. Concretely, the proxy is the only API the connector uses for logging payloads, so a future contributor cannot accidentally bypass it.

Sanitization rules per vendor:

- Default-deny on credentials. Any header named `Authorization`, `Cookie`, `X-Api-Key`, `X-Auth-Token` (case-insensitive) is replaced with the literal `<redacted>`. This default is shared across vendors, baked into a `BaseHeaderSanitizer` the per-vendor sanitizer composes with its own rules.
- Per-vendor field list captured in `docs/vendors/<vendor>.md` (Sanitized fields section). Examples:
  - Claude: `oauth_token`, `refresh_token`, `account.email`, `account.id`.
  - Codex: `api_key`, `org_id` (treated as secret by some plans), `email`.
  - Copilot: `token`, `expires_at` (low-risk but indirectly identifies sessions), `tracking_id`.
- Email-like patterns matched generically (`[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+`) and replaced with `<email>` — the `Sanitized fields` list says when to suppress this default for fields the vendor explicitly publishes (e.g. an "owner email" field that's part of the public API and the user already shared by submitting the issue).

#### Leakage test (mandatory per connector)

```swift
func testSanitizerStripsAllSeededSecrets() throws {
    let payload = realisticFullPayloadFromVendorDoc()
    let secrets = ["sk-test-deadbeef", "ghu_xxx", "fred@example.com", ...]
    let sanitized = sut.sanitize(payload)
    let asString = String(data: sanitized, encoding: .utf8) ?? ""
    for secret in secrets {
        XCTAssertFalse(asString.contains(secret),
                       "Sanitizer leaked secret '\(secret)' in output")
    }
}
```

The test reads its seeded full payload from a fixture in `Tests/Fixtures/<vendor>-full-payload.json` — the same fixture re-used to test parsing. When the `Sanitized fields` list is updated in the vendor doc, this fixture is updated too.

#### Verbose-vendor mode activation

The runtime selects "verbose for vendor X" via a single read-only string injected at startup. Two sources, in order:

1. Environment variable `AI_TRACKER_VENDOR_DEBUG=<vendor-slug>` — wins over everything; useful for power-users running the standard build with a tester-debug log on demand.
2. A baked default written into the bundle's `Info.plist` at build time by the workflow's nightly build (`AITrackerVendorDebug` key). This is what the nightly DMG attached to a `type:new-assistant` PR sets, automatically scoped to the vendor under test.

In production builds with neither source set, the connector logs at the regular level — no payloads. This means a stable release **never** ships with verbose vendor logging by accident; it requires either the user explicitly setting the env var or building from a `type:new-assistant` PR's CI.

Concretely:

- `VendorRegistry.bundles` are unaware of the verbose setting. The wiring layer (whatever today is `Loggers`) reads the env/Info.plist at startup, computes "the verbose vendor", and exposes a `LoggingProxy` configured for that one vendor at `.debug`. All other vendors retain their normal proxy.
- The `LoggingProxy` formats payload entries deterministically (one log line per HTTP exchange: method, URL, sanitized headers, sanitized request body, status code, sanitized response body, latency). Deterministic formatting matters because testers will attach raw log files; structured lines make triage by the maintainer feasible.

### 2.6 Asset & branding registration

Each plugin declares a `VendorBranding` literal:

```swift
public extension VendorBranding {
    static let copilot = VendorBranding(
        vendor: .copilot,
        displayName: "Copilot CLI",
        tintHex: "24292F",
        assetName: "copilot-mark"
    )
}
```

The renamed `VendorBranding` value object lives in the lib target so connectors and the UI both reference it. The current switch in `App/VendorBranding.swift` becomes a lookup against `VendorRegistry`. The vector PDF icon (`<vendor>-mark.pdf`) stays on disk under `App/Resources/VendorBranding/`; the conversion-from-SVG script (`scripts/render-<vendor>-mark.swift`) is parameterized.

### 2.7 Required vendor documentation — a dated snapshot

`docs/vendors/<vendor>.md` is a mandatory sibling deliverable. It captures the API research that today only survives in a single PR commit message. **Critically, this doc is treated as a dated snapshot of how the vendor's API behaves at a given moment, not as a forever-true reference.** Vendor APIs drift silently — endpoints change shape, "unlimited" flags get re-purposed, calendar dates become full ISO datetimes. When that drift breaks the connector months later, the historical snapshot is the only way to compare what the API used to look like against what it does now, and to scope the impact of the change. Without it, every drift becomes archeology.

#### Dating discipline

- **Top-of-file header**, immediately under the H1, machine-parseable:
  ```markdown
  > **Last verified:** 2026-05-06 by @fcamblor on Claude Code Pro plan
  ```
  Updated whenever the doc is re-validated against the live API. The reviewer checklist for any PR touching the connector requires bumping this date; a stale doc is a contract violation.

- **Per-section verification dates.** Each section that captures a payload, plan variant, or behavior carries its own `_verified: YYYY-MM-DD_` line. This matters because some sections age faster than others — endpoints may stay stable for years while plan-variant payloads change every quarter.

- **Sample payloads are dated and tagged with their plan.** Every captured response includes a fenced block prefixed with `<!-- captured: YYYY-MM-DD, plan: Pro, login: redacted -->`. Sensitive fields are redacted but the structure, types, and field presence are preserved. Multiple snapshots over time can coexist — old ones get a `(superseded by YYYY-MM-DD)` annotation rather than being deleted, so the drift trail is visible.

- **External sources include retrieval dates.** Community gists, blog posts, GitHub issues — every link is followed by `(retrieved YYYY-MM-DD)`. URLs rot and content gets edited; the retrieval date pins what we actually read.

#### Required sections

- **Endpoints.** Full URL(s), HTTP method, headers (auth, user-agent, plan-specific), timeout we use, response content-type. Each entry dated.
- **Credential sources.** Cascade order (env var → keychain → file), exact paths and keys, fallback ordering rationale. Names of the vendor CLIs that own each source. Dated because vendor CLIs rename their files.
- **Sanitized fields.** Exhaustive list of payload fields stripped from logs: tokens, API keys, refresh tokens, raw cookies, secret account ids, email-like patterns. Each entry includes its location in the payload (e.g. `Authorization` header value, `data.user.token`, `errors[*].context.cookie`) and the redaction style used (full removal vs `***` placeholder vs prefix preserved). This list drives the leakage test. **A field added to the payload upstream that isn't on this list is by default a sanitization gap.** The doc therefore re-asserts this list at every `Last verified` bump — when the doc is re-verified and a new field appears in the captured sample, the contributor must classify it as either safe-to-log or to-be-sanitized, never both nor "ignored".
- **Plan variants observed.** Free / Pro / Team / Enterprise — each with a representative dated sanitized payload and the fields the connector reads. Explicit note when a variant is **assumed** but not yet **verified by a tester** — that distinction is the cornerstone of the onboarding workflow's tester gate.
- **Metric semantics.** For each `UsageMetric` the connector emits, mapping from raw payload fields to the Swift case (timeWindow / payAsYouGo). Includes reset cadence (rolling window vs calendar boundary), unit (requests, dollars, percent remaining vs consumed), and edge cases (free-tier overage, "unlimited" flags, monthly vs weekly billing). Each mapping dated.
- **Time semantics.** Whether the API returns ISO 8601 datetimes or calendar dates — and whether the connector promotes calendar dates to UTC midnight. This is exactly the kind of detail that flipped silently between Copilot's early days and today; the doc must capture which form was observed on which date.
- **Error catalog.** HTTP status codes seen in the wild and the connector's response (degrade, retry, surface). Dated.
- **Known unknowns.** Explicit list of behaviors the contributor could not verify directly (e.g., enterprise plans without a tester to confirm). The onboarding workflow's tester gate fills these in over time.
- **Source references.** Community write-ups, official docs, GitHub gists used as evidence — links + retrieval date.
- **Change log.** Append-only list of `YYYY-MM-DD — what changed in the API or in our understanding of it`. The first entry is "initial capture". Subsequent entries fill in as drift is discovered. This is the section a future contributor reads first when debugging an "it used to work" report.

A skeleton template at `docs/vendors/_TEMPLATE.md` enforces the section list and the dating placeholders.

#### Future re-verification

Re-dating the file is part of normal PR hygiene whenever the connector is touched, but the framework should also support a deliberate "I just re-verified the live API against the doc" pass — useful when the user reports a drift. A future skill (`assistant-reverify`, see the onboarding workflow plan) automates this, but the data shape lives in the spec defined here.

## 3. Migration plan

The refactor must not regress behavior or tests. Suggested ordering:

1. Land the spec and `_TEMPLATE.md` in `docs/`. No code changes.
2. Introduce `VendorBundle`, `VendorBranding` value object, `ActiveAccountMonitoring`, and `VendorRegistry` with a feature-flag-free cut-over: each new type is added, then call sites migrate.
3. Refactor Claude Code first (most divergent, biggest payoff): extract `ClaudeCredentialLocator`, define `ClaudeCodePlugin.bundle`, wire it through the registry. Tests must pass at every commit.
4. Refactor Codex and Copilot to mirror Claude. Both are simpler because their locators already exist under their old `*Auth` names — this is mostly a rename + protocol conformance.
5. Replace the `VendorBranding` switch with a registry lookup, and `Loggers` named properties with bundle-owned `FileLogger`s.
6. Backfill `docs/vendors/<vendor>.md` for the three existing assistants. This locks down the historical research that today only lives in commit messages.
7. Add a "contract conformance" XCTest that walks `VendorRegistry.bundles` and asserts every metric kind is `.timeWindow` or `.payAsYouGo` (no `.unknown`), every `resetAt` parses as a strict ISO 8601 datetime, every branding entry resolves to an existing PDF asset, and every documentation pointer points at an existing file.
8. Update `CLAUDE.md`'s lazy-loaded context list to mention `docs/VENDOR-PLUGIN-CONTRACT.md`.

## 4. Scaffolding

Scaffolding is **skill-only** — there is no shell script. The implementation skill defined in the [new-assistant-onboarding-workflow](new-assistant-onboarding-workflow.md) epic creates every required file directly via `Write` / `Edit` tools, using the contract spec as its template source. Reasons:

- A shell script duplicates the contract structure in a second place that drifts from `docs/VENDOR-PLUGIN-CONTRACT.md`.
- The skill already needs to read the contract to perform code review later in the workflow; reusing it for scaffolding keeps a single source of truth.
- Token-replacement-based scaffolding produces dead-looking boilerplate that contributors then have to humanize anyway. Skill-driven scaffolding can write the right code from the start, informed by the live conversation context (which auth sources the vendor exposes, etc.).

This epic only **specifies the shape** the skill must emit (file layout, registry registration, branding entry). The mechanics of "how the skill drives it across multiple sessions" are owned by the workflow epic.

## 5. Risks and open questions

- **Contract churn.** Locking in the contract now means future vendors that need exotic credential storage (OAuth device flow, multi-tenant cookies) might require contract evolution. Mitigation: keep `CredentialLocator` generic via an associated `Credentials` type so each vendor carries its own shape; the read-only invariant remains regardless of the credential type.
- **Read-only invariant enforcement.** Nothing in the type system prevents a future locator from calling `SecItemAdd` or writing to a vendor's config file. Mitigation: a SwiftLint custom rule flags those symbols inside `*CredentialLocator.swift` files, and a contract conformance test inspects the file imports.
- **Active-account "absent" semantics.** Some vendors (e.g., Copilot) have a single global login; others (Claude) can have many accounts. The contract treats account discovery as a connector concern (`fetchUsages` returns `[VendorUsageEntry]`) and active-account-tracking as the optional monitor's job. Make sure the spec calls this out so a reader doesn't assume one-active-per-vendor.
- **Logger registration.** The per-vendor `FileLogger` opens a separate log file. Reading log retention behavior from `LogCleaner` must continue to discover bundle-owned loggers automatically — the registry is the natural source.
- **`MetricKind.unknown` slipping in.** A connector that produces `.unknown` accidentally (because its API changed) would silently round-trip. The contract conformance test catches this on CI.
- **Vendor doc drift.** API shapes drift silently and the doc is the only artifact that captures the historical baseline. The maintenance burden is on each PR that touches a connector — the PR template (workflow epic) enforces "if you touch the connector, you bump `Last verified` and append a Change log entry". A dated re-verification skill complements PR-time discipline for opportunistic spot checks.
- **Sanitization gaps.** A new field added by the vendor's API will land in logs unsanitized unless the connector (or its sanitizer) is updated. Mitigation: the leakage test fixture is bumped at every `Last verified` re-verification; the doc's "Sanitized fields" section is the contract; `assistant-tester-followup` re-checks attached logs against the doc's list and flags unknown fields. Worst-case fallback: the verbose mode is opt-in (env var or nightly-build-only), so a stable release never leaks even if a sanitization rule is missing — only the testers (who self-selected and self-attached the log) are exposed.
- **Verbose log size.** A connector logging every HTTP exchange in verbose mode produces large files quickly. Mitigation: existing log-rotation (5 MB cap, one backup) applies; the verbose mode is per-vendor and short-lived (only during `phase:testing`).

## 6. Deliverables checklist

- [ ] `docs/VENDOR-PLUGIN-CONTRACT.md`
- [ ] `docs/vendors/_TEMPLATE.md` with dating placeholders and the Change log section
- [ ] `docs/vendors/claude.md`, `docs/vendors/codex.md`, `docs/vendors/copilot.md`, each with a `Last verified` header and a seeded Change log
- [ ] `VendorBundle`, `VendorBranding` value object, `ActiveAccountMonitoring`, `CredentialLocator` protocol, `PayloadSanitizing` protocol, `LoggingProxy` (sanitization-enforcing logger wrapper), `VendorRegistry` types
- [ ] Rename `CodexAuth* → CodexCredentialLocator*`, `CopilotAuth* → CopilotCredentialLocator*`, extract `ClaudeCredentialLocator`
- [ ] Per-vendor `PayloadSanitizing` implementation + leakage test fixture (`Tests/Fixtures/<vendor>-full-payload.json`)
- [ ] Verbose-vendor mode wiring: `AI_TRACKER_VENDOR_DEBUG` env var + `AITrackerVendorDebug` Info.plist key resolution
- [ ] SwiftLint custom rule blocking writes inside `*CredentialLocator.swift`
- [ ] SwiftLint custom rule blocking direct logger calls with payload data — every payload-bearing log call MUST go through `LoggingProxy`
- [ ] Refactored `ClaudeCodePlugin`, `CodexPlugin`, `CopilotCLIPlugin` modules exposing `static let bundle: VendorBundle`
- [ ] Contract conformance XCTest (no `MetricKind.unknown`, strict ISO 8601 `resetAt`, branding asset present, vendor doc present and dated)
- [ ] `CLAUDE.md` lazy-loaded context update
