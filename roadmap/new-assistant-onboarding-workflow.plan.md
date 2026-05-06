# Plan — Assistant onboarding and evolution workflow

This file captures the deep research backing the workflow epic: why a GitHub issue is the system of record, why two issue types share one lifecycle, the phase-label flow that gates progress, the per-phase skill split, the issue forms, the maintainer-only gating Action, the build pipeline (with tester-debug logging and in-app feedback), and the validation protocol.

The epic file slug stays `new-assistant-onboarding-workflow` because slugs in `roadmap/` are filenames consumed by the existing roadmap tooling — the title, scope, and skills inside the plan all cover both new-assistant onboarding and vendor evolution.

## 0. Why temporality + an issue (not a PR) as system of record

Adding a new assistant — or evolving an existing one — takes days to weeks of wall-clock time. A pull request is the wrong durable container for that:

- A PR doesn't exist yet during the request / triage / approval phase. Testers should be able to subscribe before any code exists.
- A PR closes on merge, but the workflow continues — release is later, README and `docs/vendors/index.md` updates land afterward, the support is "officialized" only when shipped.
- A PR comment thread is not designed for a multi-stakeholder, multi-week conversation that mixes maintainer, contributor, and testers.

A **GitHub issue** is the right container: it's open from the first request to the final officialization, it carries structured fields via an issue form, it persists post-merge as the historical record (who proposed, who tested, on what build, on what plan), and it supports a state machine via labels.

Two design principles flow from this:

1. **Each phase is owned by exactly one skill**, triggered by a specific event, advancing exactly one `phase:*` label transition. No skill assumes prior session state — every skill rebuilds context by reading the issue (`gh issue view <n> --json …`) and the linked PR.
2. **The issue is the durable contract; the PR is transient.** The PR template is intentionally light; the issue form carries the structured information.

## 1. Phase-label lifecycle

A single mutex label `phase:<step>` lives on every issue carrying `type:new-assistant` or `type:vendor-evolution`. Exactly one phase label is set at any time. Transitions are unidirectional except for explicit rollback (e.g., `phase:review` back to `phase:implementing` if the review demands rework).

The phase set is identical for both issue types — the lifecycle does not branch at the label level. What branches is the **work performed at each phase**, controlled by the issue's type and (for vendor-evolution issues) its `kind:*` qualifier:

- `kind:enrichment` — backward-compatible additions (new fields, new metrics surfaced). Standard threshold (≥ 2 testers); no app version bump required.
- `kind:breaking` — backward-incompatible API change. Standard threshold; the next tagged release is bumped accordingly and the release notes carry an explicit "Breaking change for `<vendor>`" callout.
- `kind:urgent-fix` — vendor unilaterally broke compat, the connector is currently broken in the field. **Emergency escape hatch**: a single non-author tester confirmation on the latest build SHA is acceptable to merge; the issue stays open after release in `phase:released-pending-confirmations` (or simply at `phase:released` with a note) so additional tester ✅s arriving post-release backfill the validation. The release notes call out the urgency.

The "Owning skill" column below names the skill that **operates while the label is set** (i.e., the skill that consumes that phase, not the skill that transitions into it). The "Set by" column names who applies the label.

| Phase label | Set when | Owning skill (runs during this phase) | Set by |
|---|---|---|---|
| `phase:proposed` | Issue created via the issue form | (none — issue is awaiting triage) | Issue form default |
| `phase:approved` | Maintainer triages and accepts the request | `assistant-triage` (optional, helps draft the decision); then handed off to `assistant-implement` once the contributor begins | Maintainer |
| `phase:implementing` | Contributor begins work; draft PR may exist | `assistant-implement` | Maintainer (after contributor signals readiness) |
| `phase:review` | PR is opened and ready for review | `assistant-review` | Maintainer |
| `phase:testing` | Code review passed; testers can validate | `assistant-tester-followup` (signals readiness; does not transition out — maintainer does) | Maintainer |
| `phase:merge-ready` | Threshold of tester ✅ on the latest build SHA reached (≥ 2 non-author confirmations; ≥ 1 for `kind:urgent-fix`) | `assistant-merge` | Maintainer |
| `phase:merged` | PR squash-merged into main; awaiting tagged release | `assistant-release` (invoked once the release tag ships) | `assistant-merge` (set immediately after merge) |
| `phase:released` | Tagged release ships with the change; post-release artifacts updated; issue closes | (terminal state — no skill operates after release) | `assistant-release` |

A separate concept — **vendor doc re-verification** — happens long after `phase:released` and operates on a different artifact (the live vendor doc in `docs/vendors/`). It does not transition issue labels because the issue is closed by then; the re-verification skill produces its own follow-up PR.

## 2. Per-phase walk-through

Each phase entry below specifies: trigger event, the label transition, the owning skill, the inputs the skill reads (always from durable state — never assumed from prior session), the outputs, and the exit condition.

### 2.1 Proposed

- **Trigger**: anyone (tester, contributor, maintainer) opens an issue using one of the two issue forms — `new-assistant-request.yml` (for new vendors) or `vendor-evolution-request.yml` (for changes to an existing vendor).
- **Transition**: none → `phase:proposed`.
- **Skill**: none. The issue form sets the labels.
- **Outputs**: structured issue body with vendor name, proposer, known credential sources, known plan variants, links to vendor's API references.
- **Exit**: maintainer triages.

### 2.2 Approved (or closed)

- **Trigger**: maintainer reviews the proposal.
- **Transition**: `phase:proposed` → `phase:approved` (or issue closed with `wontfix` / `duplicate`).
- **Skill**: `assistant-triage` (optional helper, see §3.1) — the maintainer can also handle this manually.
- **Inputs**: the issue body, existing `docs/vendors/` (duplicate check), existing roadmap.
- **Outputs**: `phase:approved` label applied, comment summarizing the decision and any constraints (e.g., "OK but only if the API exposes per-plan reset dates").
- **Exit**: contributor can begin work.

### 2.3 Implementing

- **Trigger**: contributor begins work; signals readiness in the issue.
- **Transition**: `phase:approved` → `phase:implementing` (maintainer-applied).
- **Skill**: `assistant-implement` (see §3.2). Branches on issue type.
- **Inputs**: the issue body (vendor metadata for new-assistant, or vendor slug + observed drift for vendor-evolution), `docs/VENDOR-PLUGIN-CONTRACT.md`, `docs/vendors/_TEMPLATE.md`, the existing `docs/vendors/<vendor>.md` (for vendor-evolution only).
- **Outputs**, by issue type:
  - **`type:new-assistant`** — connector / credential locator / status / monitor implementations, vector icon asset (`<vendor>-mark.pdf` rendered from the vendor's SVG logo), freshly written dated `docs/vendors/<vendor>.md`, `VendorRegistry` line, tests passing locally, draft PR opened with `Closes #<issue>`.
  - **`type:vendor-evolution`** — targeted refactor of the existing connector / locator / sanitizer; **bumped** `Last verified` and per-section dates in the existing `docs/vendors/<vendor>.md`; **new dated samples** appended (old samples kept and annotated `superseded by YYYY-MM-DD`); **Change log entry** describing what drifted and what now changes in the connector; updated leakage test fixture if new fields appeared; updated tests for the new payload shape; for `kind:breaking`, a min-app-version annotation in the vendor doc and a `BREAKING:` prefix in the eventual release notes; draft PR opened with `Closes #<issue>` and the kind label echoed in the title (e.g. `feat(<vendor>)!: …` for breaking).
- **Exit**: PR moved out of draft; contributor asks the maintainer to advance to `phase:review`.

### 2.4 Review

- **Trigger**: PR is ready for review.
- **Transition**: `phase:implementing` → `phase:review` (maintainer-applied).
- **Skill**: `assistant-review` (see §3.3).
- **Inputs**: the PR diff, `docs/vendors/<vendor>.md`, the contract spec, the reviewer checklist, the issue body.
- **Outputs**: a PR review comment grouped by checklist section. Documentation track is read first, before the diff (the vendor doc must stand on its own).
- **Exit**: review approves → maintainer transitions to `phase:testing`. Review requests changes → label may rollback to `phase:implementing`.

### 2.5 Testing

- **Trigger**: review passed; CI build is fresh on the PR.
- **Transition**: `phase:review` → `phase:testing` (maintainer-applied).
- **Skill**: `assistant-tester-followup` (see §3.4) — invoked each time a tester comment arrives, especially if incomplete.
- **Inputs**: the issue's tester sign-off comments (each ideally with an attached connector log), the latest sticky build comment (also posted on the issue), the build SHA, the vendor doc's `Sanitized fields` section.
- **Outputs**: a running tally on the issue (maintained by editing a sticky tally comment on the issue), follow-up questions for incomplete confirmations, audit notes on attached logs (any secret leak found gets flagged as a sanitization gap, blocking the merge), an explicit "ready / not yet" verdict.
- **Exit**: ≥ 2 non-author testers ✅ on the latest build SHA + every attached log audited clean → maintainer transitions to `phase:merge-ready`.

The DMG attached during this phase is built with the **tester-debug flag** set to the vendor under test (cf. §6.4) **and** the **in-app feedback banner** wired to the right issue (cf. §6.5). Testers have two paths to submit feedback:

- **Path A — recommended, in-app.** Click the tester banner in the app's popover; the feedback sheet pre-fills everything the template needs (build SHA from the bundle, vendor slug, macOS version, checklist boxes). On submit, the app opens the issue URL in the browser with the comment body URL-encoded + reveals the connector log file in Finder so the tester drag-drops it into the GitHub composer.
- **Path B — fallback, manual.** Tester downloads the connector log under `~/.cache/ai-usages-tracker/<vendor>-usages-connector.log`, copies the sign-off template from the issue's sticky build comment, fills it manually, attaches the log file, posts. Same end-state as Path A.

The follow-up skill (§3.4) audits the resulting comment regardless of path against the vendor doc's `Sanitized fields` list before counting the confirmation.

#### Sign-off comment template

Posted by testers on the **issue** (not the PR), as a single comment per tester (whether produced by Path A or hand-written via Path B). The follow-up skill scans for the `✅ tester-confirm` sentinel.

```
✅ tester-confirm

Plan: <Free | Pro | Team | Enterprise | Other: …>
macOS: <14.x | 15.x | 26.x>
Build SHA: <8 chars> (full: <40 chars>)
Submission path: <in-app | manual>
Verified:
- [x] Active account is detected correctly
- [x] At least one usage metric matches the vendor's own dashboard within reasonable tolerance
- [x] Reset date displayed in the popover matches the vendor's reported reset
- [ ] Optional: outage banner appears when the vendor reports an incident
Connector log attached: yes — <attached file in this comment>
Notes: <free-form>
```

The full SHA (40 chars) is included alongside the short form so the maintainer can git-checkout the exact build at audit time without ambiguity. Path A pre-fills both forms automatically from the bundle's `AITrackerBuildCommit` Info.plist key; Path B testers copy them from the sticky build comment.

Counting rules:

- Author of the sign-off must differ from the PR author.
- The build SHA must match the latest sticky build comment (a rebase invalidates older confirmations; testers re-confirm on the new build).
- A sign-off without an attached connector log is **incomplete** — the follow-up skill replies asking for it before counting. Exception: a tester explicitly states the verbose mode is producing no output (which itself is a bug to investigate before merge).
- A sanitization gap detected in the attached log blocks the count regardless of how many other confirmations exist; the connector must be fixed and a fresh DMG built first.

Threshold for merge: **≥ 2 distinct non-author testers** with valid sign-offs on the latest build, with audited-clean attached logs.

### 2.6 Merge-ready

- **Trigger**: tester threshold reached + reviewer checklist green.
- **Transition**: `phase:testing` → `phase:merge-ready` (maintainer-applied).
- **Skill**: `assistant-merge` (see §3.5) — re-verifies gates before acting.
- **Inputs**: the issue, the PR, the latest tester tally.
- **Outputs**: PR squash-merged with the standard commit convention; issue moves to `phase:merged`.
- **Exit**: PR is merged.

### 2.7 Merged

- **Trigger**: PR squash-merged.
- **Transition**: `phase:merge-ready` → `phase:merged` (set by `assistant-merge` immediately after the merge).
- **Skill**: `assistant-merge` finishes here; `assistant-release` takes over once a tagged release happens.
- **Outputs**: PR closed, "Closes #<issue>" GitHub auto-link still resolved (issue stays open until `phase:released`).
- **Exit**: a tagged release `v*.*.*` ships.

### 2.8 Released (and issue closes)

- **Trigger**: a tagged release ships including the new vendor's commits.
- **Transition**: `phase:merged` → `phase:released`.
- **Skill**: `assistant-release` (see §3.6).
- **Inputs**: the issue, the released tag.
- **Outputs**: `README.md` "Supported assistants" updated, `docs/vendors/index.md` row added (if it exists), GitHub release notes amended to credit testers by handle, **issue closed** with `phase:released` as the final state.
- **Exit**: the issue is closed and serves as the historical record of the onboarding.

### 2.9 Re-verify (long after, on demand)

Decoupled from the original onboarding issue lifecycle — that issue is closed at this point. The re-verify skill itself does not transition any phase label.

- **Trigger**: contributor or maintainer suspects API drift (metric value looks wrong; connector errors out; `Last verified` in the vendor doc is months old).
- **Skill**: `assistant-reverify` (see §3.7).
- **Outputs**, depending on what the re-verification finds:
  - **Doc-only refresh** (the live API still matches the connector; only the doc was stale) — bumped `Last verified` header and per-section dates, fresh dated samples appended, older samples annotated `superseded by <today>`, Change log entry. Lands as a small standalone doc PR. No new issue required — nothing about the connector changes, so the testers / DMG / sanitization-audit gate would add no value.
  - **Drift requiring connector changes** — the skill stops short of writing connector code. It files (or instructs the maintainer to file) a `type:vendor-evolution` issue using `vendor-evolution-request.yml`, pre-fills the drift summary and evidence from what it just observed, and proposes the appropriate `kind:*` (`enrichment` / `breaking` / `urgent-fix` if the connector is currently broken in the field). The change then re-enters the normal workflow at `phase:proposed` and benefits from the testers / DMG / sanitization-audit gate like any other vendor evolution.

Routing all connector-affecting drifts back through `type:vendor-evolution` keeps a single path for code changes that touch a vendor: the `assistant-reverify` skill is a discovery tool, not an alternative merge path. This matches the risk called out in §8 ("Vendor evolution without an issue … bypasses the workflow entirely").

## 3. Skill family

`.claude/rules/skill-authoring.md` mandates that operational artifacts reference specs rather than duplicating them. Each skill below points at `docs/ASSISTANT-ONBOARDING.md` (phase ↔ label ↔ skill map) and `docs/VENDOR-PLUGIN-CONTRACT.md` (technical contract), and includes the conflict-resolution clause.

Common shape every skill follows:

1. Argument: an issue number (or `--vendor <slug>` for `reverify`).
2. Read durable state: `gh issue view`, `gh pr view` (if a PR is linked), the contract spec, the vendor doc.
3. Verify the current `phase:*` label matches what the skill expects. If it doesn't, refuse and tell the user which skill should run instead.
4. Perform the work.
5. Apply the next `phase:*` label (or, for skills that don't transition, post a tally / report comment).
6. Hand off explicitly: name the next skill the user should invoke when the next event happens.

Skills never poll, never run in the background. They run when the maintainer invokes them in response to an event.

### 3.0 `assistant` (meta router)

```
---
name: assistant
description: Routes to the correct sub-skill of the assistant family based on the issue's type:* and phase:* labels. Use when the user mentions a vendor onboarding or evolution and is unsure which skill to run.
model: sonnet
---

Read `docs/ASSISTANT-ONBOARDING.md`; it owns the type ↔ phase ↔ skill map.

Argument: issue number.

Read the issue. Identify both:
  - issue type: `type:new-assistant` vs `type:vendor-evolution`
  - phase: `phase:*` label

Name the matching sub-skill (every sub-skill handles both issue types — they
read the type themselves and adapt — so the router is type-agnostic at this
level). Stop. Do not perform work yourself. The user invokes the named
sub-skill explicitly.
```

### 3.1 `assistant-triage` (optional)

```
---
name: assistant-triage
description: Help the maintainer triage a phase:proposed assistant issue (new-assistant or vendor-evolution) — duplicate check, scope sanity check, decision draft. Use when reviewing an incoming proposal.
model: sonnet
---

Argument: issue number.

Phase A — Verify current label is phase:proposed; refuse otherwise.
Phase B — Read the issue body; cross-check `docs/vendors/` for duplicates and the
          current roadmap for conflicting work.
Phase C — For type:vendor-evolution issues, read the `Kind of change` dropdown
          value from the issue body and apply the matching `kind:*` label
          (`kind:enrichment` / `kind:breaking` / `kind:urgent-fix`) via
          `gh issue edit --add-label`. Issue forms can only apply static labels
          from their frontmatter, so this dynamic label necessarily lives in
          the triage step. For type:new-assistant issues, no kind label applies.
Phase D — Draft a decision comment with explicit constraints (auth sources expected,
          plan variants required to be covered by testers, branding asset acceptable
          sources). Do not apply the phase label — the maintainer applies
          phase:approved (or closes the issue) after reading the draft.
```

### 3.2 `assistant-implement`

Owns phase 2.3 and prepares 2.4. Invoked by the contributor (typically the maintainer wearing a contributor hat, but could be anyone). Branches on the issue's `type:*` label.

```
---
name: assistant-implement
description: Scaffold (new-assistant) or refactor (vendor-evolution), document, test, and open a draft PR. Use when the issue is at phase:approved or phase:implementing and the contributor is starting or resuming work.
model: opus
---

Prerequisites: docs/VENDOR-PLUGIN-CONTRACT.md, docs/ASSISTANT-ONBOARDING.md,
docs/vendors/_TEMPLATE.md, the Swift quality docs in CLAUDE.md.

Argument: issue number.

Phase A — Read the issue. Verify phase is :approved or :implementing.
          Read `type:*` and (if present) `kind:*` labels — every later phase
          branches on those.

Phase B — Mine the issue's structured fields. For type:new-assistant: vendor
          slug, display name, tint hex, credential sources, plan variants,
          reference links. For type:vendor-evolution: target vendor slug,
          observed drift summary, kind (enrichment / breaking / urgent-fix),
          app-version-bump impact. Ask only what's missing.

Phase C — Existence check.
          - type:new-assistant → `docs/vendors/<slug>.md` MUST NOT exist; refuse
            otherwise (point at the vendor-evolution form).
          - type:vendor-evolution → `docs/vendors/<slug>.md` MUST exist and be
            registered in VendorRegistry; refuse otherwise (point at the
            new-assistant form).

Phase D — API research / API re-research.
          - type:new-assistant → write `docs/vendors/<slug>.md` from the
            template with `Last verified: <today>`, per-section dates, sources
            with retrieval dates, Change log seeded with "initial capture".
          - type:vendor-evolution → bump the existing doc's `Last verified` to
            <today>; capture fresh dated payload samples; mark older samples
            `superseded by <today>` (do NOT delete them); update the
            Sanitized fields list if new payload fields appeared; append a
            Change log entry describing what drifted in the API and what is
            about to change in our connector. For kind:breaking, also annotate
            "Min app version: <next-version>" in the doc.
          The user must approve this draft before phase E.

Phase E — Code work.
          - type:new-assistant → scaffold inline (Write/Edit), no shell script:
            connector / credential locator / status / monitor / branding /
            VendorRegistry entry / test fixtures / vector PDF icon
            (`<slug>-mark.pdf`).
          - type:vendor-evolution → locate the existing files for <slug> and
            apply the targeted refactor; do not touch unrelated vendors. For
            kind:breaking, prefer keeping a graceful-degradation path in the
            connector (e.g., return a `lastError` describing "incompatible API
            version" rather than crashing) so old app versions running in the
            field stop logging useful metrics but don't crash.

Phase F — Implement against the contract. After each plugin point, run targeted
          XCTest. Forbidden: MetricKind.unknown in connector output; try? on
          correctness-affecting ops; SecItem* writes in the credential locator.

Phase G — Tests.
          - type:new-assistant → credential cascade, payload happy path, every
            documented plan variant, HTTP error codes, metric calculation,
            date normalization, sanitization leakage.
          - type:vendor-evolution → existing test suite still passes; new tests
            cover the new payload shape; sanitization leakage test fixture
            updated for any new field; for kind:breaking, an explicit test
            verifies the graceful-degradation behavior on the legacy payload
            shape (so we know exactly what old in-the-field versions will see).

Phase H — Open the draft PR via `gh pr create --draft --template assistant-change.md`.
          The PR body starts with `Closes #<issue>`. Title convention:
            type:new-assistant       → `feat(<slug>): support <Display Name> usage tracking`
            type:vendor-evolution    → `feat(<slug>): <one-line drift summary>`
            kind:breaking            → use `feat(<slug>)!:` (Conventional Commits
                                       breaking marker) and prepend `BREAKING:`
                                       to the body summary.
          No label transition yet.

Phase I — Hand off: tell the maintainer to flip to phase:review when the PR is
          out of draft. Name the `assistant-review` skill for the next step.
```

### 3.3 `assistant-review`

Owns phase 2.4 readiness check.

```
---
name: assistant-review
description: Review an open assistant PR against the dual-track checklist (dated documentation first, then code), with per-issue-type addenda for new vendors vs evolution. Use when the issue is at phase:review.
model: opus
---

Argument: issue number.

Phase A — Read the issue. Verify phase:review. Find the linked PR.
Phase B — Documentation track FIRST. Read `docs/vendors/<slug>.md` standalone,
          before opening the diff. Verify Last verified header, per-section dates,
          dated samples with plan tags, change log seeded, doc-stands-alone test.
Phase C — Code track. Run the contract conformance test. Walk the reviewer
          checklist on the diff.
Phase D — Post a single PR review with findings grouped by checklist section.
          Approve only if every box is green. Refuse to apply phase:testing
          yourself — the maintainer applies it after seeing the approved review.
```

### 3.4 `assistant-tester-followup`

Owns phase 2.5 reporting. Does not transition labels.

```
---
name: assistant-tester-followup
description: Tally tester sign-off comments on a phase:testing issue, validate them against the latest build SHA, audit any attached connector logs for sanitization gaps, and draft follow-ups for incomplete confirmations. Use whenever a tester comments.
model: sonnet
---

Argument: issue number.

Phase A — Verify phase:testing. Read the issue comments. Find the latest sticky
          build comment to get the current build SHA.
Phase B — Scan comments for the `✅ tester-confirm` sentinel. Validate each:
          author ≠ PR author; build SHA matches latest; required boxes filled;
          a connector log file is attached.
Phase C — For each attached log file: read it (or guide the user to fetch and read
          it). Cross-check against `docs/vendors/<vendor>.md` Sanitized fields
          section: every field listed there must be redacted in the log; any
          obvious secret pattern (long base64-ish strings, tokens, emails NOT
          declared as public in the vendor doc) raises a sanitization-gap alert.
          A sanitization gap blocks the confirmation count and surfaces as a
          high-priority comment for the maintainer — the connector code must be
          fixed and a fresh DMG built before that confirmation can be re-counted.
Phase D — Compute the required threshold from the issue's labels:
          - type:vendor-evolution + kind:urgent-fix → threshold = 1
          - all other cases (type:new-assistant, kind:enrichment, kind:breaking)
            → threshold = 2
          Update or create the sticky tally comment on the issue
          (`Tester confirmations: N/<threshold> ✅`), list valid confirmations,
          list incomplete comments with the exact follow-up question for each,
          list flagged sanitization gaps (if any) with the offending log line
          excerpts quoted **with the suspected secret itself replaced by
          `<redacted>` in the comment** so the issue thread itself never
          republishes a leak.
Phase E — If N ≥ threshold and no sanitization gap is open, recommend the
          maintainer apply phase:merge-ready. Do not apply the label yourself.
```

### 3.5 `assistant-merge`

Owns phases 2.6 → 2.7.

```
---
name: assistant-merge
description: Verify gates one last time and squash-merge an assistant PR (new-assistant or vendor-evolution). Use when the issue is at phase:merge-ready.
model: sonnet
---

Argument: issue number.

Phase A — Verify phase:merge-ready. Re-run the tester tally and the reviewer
          checklist. Refuse if any gate is not green.
          Special case: type:vendor-evolution + kind:urgent-fix accepts a
          tally of 1 non-author tester ✅; the regular threshold of 2 still
          applies for kind:enrichment and kind:breaking.
Phase B — Squash-merge with the standard commit convention. For kind:breaking
          ensure the title carries the `!` Conventional Commits breaking marker.
Phase C — Apply phase:merged. Comment on the issue summarizing the merge,
          stating that the issue stays open until the next tagged release.
          For kind:urgent-fix, also note "Issue will stay at phase:released
          for follow-up tester confirmations" so post-release ✅s land at the
          right place.
```

### 3.6 `assistant-release`

Owns phase 2.8. Branches on issue type for the post-merge officialization.

```
---
name: assistant-release
description: Officialize a merged assistant change by updating README (new-assistant only), docs/vendors/index, and crediting testers in release notes; close the issue. Use after a tagged release ships the work.
model: sonnet
---

Argument: issue number, released tag.

Phase A — Verify phase:merged. Confirm the released tag actually contains the
          merge commit. Read the issue's type:* and kind:* labels.
Phase B — Update artifacts based on type.
          - type:new-assistant → append the new vendor to README's
            "Supported assistants" section; add a row to
            `docs/vendors/index.md` if it exists.
          - type:vendor-evolution → no README change (the vendor is already
            listed). If kind:breaking, ensure the README's compatibility note
            (or `docs/vendors/<vendor>.md`'s "Min app version" annotation)
            is reflected wherever users decide which version to install.
Phase C — Amend the GitHub release notes.
          - All types → credit testers by handle.
          - kind:breaking → prepend `BREAKING: <vendor> connector requires
            <next-version>+` to the release notes; explain what changed and
            what users on older versions will see (typically: lastError
            replacing live metrics until they update).
          - kind:urgent-fix → call out the urgent context: which subset of
            users was affected, since when, and what the fix does.
Phase D — Apply phase:released and close the issue with a thank-you comment
          listing the testers. For kind:urgent-fix where additional tester
          ✅ are still expected, leave the issue OPEN at phase:released for
          a few days, then close manually once the maintainer is confident.
```

### 3.7 `assistant-reverify`

Decoupled from the issue lifecycle — operates on the live vendor doc.

```
---
name: assistant-reverify
description: Re-verify a vendor's API behavior against its docs/vendors/<vendor>.md snapshot, bump dates, append a Change log entry, and either open a doc-only PR (no drift impact) or file a type:vendor-evolution issue (drift forces connector changes). Use when API drift is suspected.
model: opus
---

Argument: vendor slug.

Phase A — Read existing `docs/vendors/<vendor>.md`. Note Last verified.
Phase B — Live capture (or guide the user to). Sanitize, date today.
Phase C — Diff vs the dated samples in the doc. Identify field/type/semantic drift.
Phase D — Bump Last verified. Add new samples. Mark old ones superseded — never
          delete (the historical trail is the value). Append Change log entry.
Phase E — Decide the follow-up path based on the diff.
          - No drift, or drift with no impact on the connector → open a small
            doc-only PR with the refreshed dates/samples/changelog. Stop here.
          - Drift forcing connector changes → DO NOT write connector code from
            this skill and DO NOT open a code PR directly. File (or instruct the
            maintainer to file) a `type:vendor-evolution` issue via
            `vendor-evolution-request.yml`, pre-filled with the drift summary,
            the captured dated samples, and the proposed `kind:*`
            (`enrichment` / `breaking` / `urgent-fix` if the connector is
            currently broken in the field). The doc PR from phase D can either
            be merged independently first or rolled into the implementation PR
            opened later by `assistant-implement` — the maintainer decides.
            From there, `assistant-implement` and the rest of the workflow take
            over so the connector change goes through the testers / DMG /
            sanitization-audit gate like any other vendor evolution.
          Never bundle re-verification with an old, already-closed onboarding PR.
```

## 4. Issue form

`.github/ISSUE_TEMPLATE/new-assistant-request.yml`:

```yaml
name: New AI assistant — request support
description: Request that AI Usages Tracker adds support for a new AI assistant.
title: "[new-assistant] <vendor display name>"
labels: ["type:new-assistant", "phase:proposed"]
body:
  - type: input
    id: vendor-slug
    attributes:
      label: Vendor slug (kebab-case, English)
      description: Used as the file basename in `docs/vendors/<slug>.md`.
      placeholder: "cursor"
    validations:
      required: true
  - type: input
    id: display-name
    attributes:
      label: Display name
      placeholder: "Cursor"
    validations:
      required: true
  - type: input
    id: tint-hex
    attributes:
      label: Brand tint (6-digit hex, no #)
      placeholder: "DA7756"
    validations:
      required: true
  - type: textarea
    id: credential-sources
    attributes:
      label: Known credential sources
      description: Where does the vendor's CLI store credentials? (env var, keychain, on-disk config). The app reads these — it never writes them.
      placeholder: |
        - $CURSOR_TOKEN env var
        - macOS keychain entry "cursor:auth"
        - ~/.config/cursor/auth.json
    validations:
      required: true
  - type: textarea
    id: plan-variants
    attributes:
      label: Known plan variants
      description: List every subscription tier we know about. The tester gate must cover every "verified" variant; "assumed" ones go in the doc's Known unknowns section.
      placeholder: |
        - Hobby (free) — verified
        - Pro — verified
        - Business — assumed
    validations:
      required: true
  - type: textarea
    id: api-references
    attributes:
      label: API references (with retrieval dates)
      description: Links to vendor docs, community gists, GitHub issues that document the API.
      placeholder: |
        - https://cursor.sh/docs/api/usage (retrieved 2026-05-06)
        - https://gist.github.com/… (retrieved 2026-05-06)
    validations:
      required: true
  - type: input
    id: branding-asset
    attributes:
      label: Branding asset source
      description: SVG/PDF source for the vendor mark. Octicons / Simple-Icons / vendor-provided. Must be license-compatible.
    validations:
      required: true
  - type: checkboxes
    id: contract-acknowledgement
    attributes:
      label: Contract acknowledgement
      options:
        - label: I understand the app reads credentials but never writes, refreshes, or rotates them.
          required: true
        - label: I understand merge requires ≥ 2 non-author testers ✅ on the latest build SHA.
          required: true
```

The form sets `type:new-assistant` and `phase:proposed` automatically. Submitting the form is equivalent to invoking the workflow's first phase.

### 4.2 Vendor-evolution form

`.github/ISSUE_TEMPLATE/vendor-evolution-request.yml`:

```yaml
name: Vendor evolution — API drift, enrichment, or urgent fix
description: Report or propose a change to an already-supported AI assistant when its API evolves.
title: "[evolution] <vendor display name>: <one-line drift summary>"
labels: ["type:vendor-evolution", "phase:proposed"]
body:
  - type: dropdown
    id: vendor-slug
    attributes:
      label: Vendor
      description: Which already-supported assistant is this about?
      options:
        - claude
        - codex
        - copilot
        # The list is maintained alongside `VendorRegistry`; the issue form
        # lists exactly the vendors `docs/vendors/<slug>.md` exists for.
    validations:
      required: true
  - type: dropdown
    id: kind
    attributes:
      label: Kind of change
      description: Drives the threshold and release-notes treatment.
      options:
        - "kind:enrichment — backward-compatible additions (new metrics, new fields, new plan variant)"
        - "kind:breaking — backward-incompatible API change requiring an app version bump"
        - "kind:urgent-fix — the vendor unilaterally broke compat; the connector is currently broken in the field"
    validations:
      required: true
  - type: textarea
    id: drift-summary
    attributes:
      label: What changed (or appears to have changed) on the vendor's side
      description: Be specific. Field renamed? New field appeared? Endpoint moved? Plan-variant payload restructured? Reset semantics flipped?
      placeholder: |
        - The `quota_remaining` field disappeared.
        - A new `quota_window` object replaces it with `start`, `end`, `used`.
        - First observed: 2026-04-30 by @somebody on Pro plan.
    validations:
      required: true
  - type: textarea
    id: evidence
    attributes:
      label: Evidence
      description: Sanitized payload samples, links to vendor changelog, community issues, your own log lines (with secrets stripped). Each item dated.
      placeholder: |
        - Captured payload (Pro, 2026-05-01): https://gist.github.com/... (retrieved 2026-05-06)
        - Vendor changelog post: https://... (retrieved 2026-05-06)
        - Open question: behavior on Free plan unverified
    validations:
      required: true
  - type: dropdown
    id: app-version-impact
    attributes:
      label: App version impact
      description: For kind:breaking only — what happens to users running an older app version when this lands?
      options:
        - "Users on older versions will keep seeing live metrics (no impact)."
        - "Users on older versions will see a `lastError` until they update; no crash."
        - "Users on older versions will crash or hang (must be avoided — the implement skill enforces graceful degradation)."
        - "Not applicable (kind:enrichment / kind:urgent-fix)."
    validations:
      required: true
  - type: input
    id: affected-since
    attributes:
      label: Affected since (kind:urgent-fix only)
      description: When did the field start being affected by the broken vendor API?
      placeholder: "2026-05-04 ~14:00 UTC"
  - type: checkboxes
    id: contract-acknowledgement
    attributes:
      label: Contract acknowledgement
      options:
        - label: I understand the existing `docs/vendors/<vendor>.md` will be re-dated and superseded samples kept (not deleted), with a Change log entry summarizing the drift.
          required: true
        - label: I understand merge requires ≥ 2 non-author testers ✅ for kind:enrichment / kind:breaking, and ≥ 1 for kind:urgent-fix (with follow-up confirmations expected post-release).
          required: true
```

The form sets `type:vendor-evolution` and `phase:proposed` automatically. The triage skill (§3.1) is responsible for adding the `kind:*` label corresponding to the dropdown selection — kept as a separate label so workflows and skills can filter on it cleanly.

## 5. Maintainer-only gating action

`.github/workflows/phase-label-gate.yml`:

```yaml
name: Phase label gate

on:
  issues:
    types: [labeled, unlabeled]

permissions:
  issues: write
  contents: read

# Serialize label events per issue so two near-simultaneous transitions
# don't race against each other's permission check + revert. `cancel-in-progress: false`
# means events queue and each one is validated, rather than a later event
# cancelling the verification of an earlier one.
concurrency:
  group: phase-label-gate-${{ github.event.issue.number }}
  cancel-in-progress: false

jobs:
  validate:
    # Skip events triggered by the gate's own revert action — otherwise the
    # `gh issue edit` below re-fires `labeled`/`unlabeled` with the bot as
    # actor, the bot has no admin/maintain permission, and the gate would
    # revert its own revert in a loop, posting a comment each iteration.
    if: >
      startsWith(github.event.label.name, 'phase:')
      && github.event.sender.type != 'Bot'
    runs-on: ubuntu-latest
    steps:
      - name: Check actor permission
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ACTOR: ${{ github.actor }}
          REPO: ${{ github.repository }}
          ISSUE: ${{ github.event.issue.number }}
          LABEL: ${{ github.event.label.name }}
          ACTION: ${{ github.event.action }}
        run: |
          permission=$(gh api "repos/${REPO}/collaborators/${ACTOR}/permission" \
            --jq '.permission' 2>/dev/null || echo "none")
          case "$permission" in
            admin|maintain)
              echo "Actor ${ACTOR} has ${permission} permission — allowed"
              ;;
            *)
              echo "::error::Actor ${ACTOR} (permission=${permission}) cannot change phase:* labels — reverting"
              if [ "${ACTION}" = "labeled" ]; then
                gh issue edit "${ISSUE}" --remove-label "${LABEL}"
              else
                gh issue edit "${ISSUE}" --add-label "${LABEL}"
              fi
              gh issue comment "${ISSUE}" --body \
                "@${ACTOR} only repo maintainers can change \`phase:*\` labels. The change has been reverted."
              exit 1
              ;;
          esac
```

The `github.event.sender.type != 'Bot'` guard is the loop-breaker: when the gate's own `gh issue edit` re-fires the workflow, the sender is `github-actions[bot]` and the job is skipped before any permission check or revert runs.

The action ensures the gating is **enforced**, not just convention. Any non-maintainer label change is reverted within seconds and called out publicly on the issue.

The mutex invariant (exactly one `phase:*` label at a time) is a separate light-weight check the action also performs: when applying a `phase:*` label, it lists current labels and removes any other `phase:*` label.

## 6. Build pipeline

The build pipeline is **CI-driven and skill-free** — no skill manages it. The DMG is the only prebuilt artifact; the trust escape hatch for skeptical readers is "clone the branch and build it yourself" (`docs/CHECKOUT-AND-BUILD.md`).

### 6.1 Workflow file `.github/workflows/assistant-build.yml`

```yaml
name: Assistant change nightly build

on:
  pull_request:
    types: [labeled, synchronize, opened, reopened, ready_for_review]
  workflow_dispatch:

concurrency:
  group: assistant-build-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  build:
    # Fire when the PR closes a type:new-assistant or type:vendor-evolution
    # issue, OR when an explicit build label is present. The link is detected
    # by parsing the PR body for `Closes #<n>` and querying that issue's labels.
    if: github.event.pull_request.draft == false
    runs-on: macos-15
    timeout-minutes: 30
    permissions:
      contents: read
      pull-requests: write
      issues: write
    steps:
      # 1. Check the linked issue carries `type:new-assistant` OR
      #    `type:vendor-evolution`; extract the vendor slug from the issue body.
      #    Skip the build entirely otherwise.
      # 2. Compute SHA8 = first 8 chars of github.event.pull_request.head.sha.
      # 3. Reuse release.yml prep: select Xcode 26, strip SwiftLint plugin.
      # 4. Run ./scripts/build-app-bundle.sh with these env vars:
      #      VENDOR_DEBUG=<slug>
      #      BUILD_COMMIT=<full SHA>
      #      ONBOARDING_ISSUE_URL=https://github.com/<repo>/issues/<n>
      #    The build script bakes them into the .app's Info.plist as
      #      AITrackerVendorDebug          = <slug>
      #      AITrackerBuildCommit          = <full SHA>
      #      AITrackerOnboardingIssueURL   = https://github.com/<repo>/issues/<n>
      # 5. Package the .app into a DMG named
      #      AI-Usages-Tracker-<slug>-<sha8>.dmg
      #    Compute SHA-256 of the DMG.
      # 6. Upload as workflow artifact.
      # 7. Post or update a sticky comment on BOTH the PR (for reviewer) AND
      #    the linked issue (for testers).
```

The DMG filename embeds both the vendor slug and the short SHA so a tester downloading multiple builds across rebases can tell them apart at a glance, and the maintainer auditing a sign-off can correlate the filename against the SHA in the comment without opening the bundle. The full SHA inside `AITrackerBuildCommit` is what the in-app feedback banner reads; the short SHA in the filename is what humans see.

### 6.2 Sticky comment shape (issue and PR)

Same body in both places, distinguished only by sentinel. The issue version mentions the connector log path; the PR version tones it down (reviewers don't need that).

Issue body:

```
<!-- assistant-build:sticky -->
🛠 Build for commit `<SHA-8>` — vendor-debug enabled for `<vendor-slug>`

Full commit: `<SHA-40>`
PR: #<n>

- [Download AI-Usages-Tracker-<vendor-slug>-<SHA-8>.dmg](…) — SHA-256 `…`

Builds are ad-hoc signed only. First launch: right-click → Open to bypass Gatekeeper.

### Submitting feedback

**Recommended:** open the app, click the "🧪 Tester feedback" banner in the popover.
The form pre-fills the build SHA, vendor, and macOS version, and on submit it
opens this issue in your browser with the comment pre-written + reveals the
connector log in Finder so you can drag-attach it.

**Manual fallback:** copy the sign-off template (below), fill it in, attach the
log file from `~/.cache/ai-usages-tracker/<vendor-slug>-usages-connector.log`.

The build sanitizes secrets (tokens, API keys, emails) before writing to the log;
if you spot anything that looks confidential, flag it in your comment without
quoting the value — it's a bug we want to fix before merge.

Don't trust this prebuilt DMG? Build it yourself in 5 minutes — see
[`docs/CHECKOUT-AND-BUILD.md`](…).
```

PR body (lighter, reviewer-oriented):

```
<!-- assistant-build:sticky -->
🛠 Build for commit `<SHA-8>` (vendor-debug enabled for `<vendor-slug>`)

Full commit: `<SHA-40>`

- [Download AI-Usages-Tracker-<vendor-slug>-<SHA-8>.dmg](…) — SHA-256 `…`

For tester instructions see the linked issue.
```

The duplication (issue + PR) is intentional: testers should not have to dig through the PR thread; reviewers shouldn't have to switch to the issue. The cost is one extra `gh issue comment` per CI run.

### 6.3 The "build it yourself" doc

`docs/CHECKOUT-AND-BUILD.md` is the trust anchor. Targets a non-developer reader with Xcode but no Swift experience. Five short sections:

1. **Prerequisites** — Xcode (version pinned by `Package.swift`), macOS 15+, `git`. Pointers to install Xcode for readers who don't have it.
2. **Get the source** — `gh pr checkout <pr#>`, or "Code → Download ZIP" from GitHub for users without `gh`.
3. **Build** — exact command (`./scripts/build-app-bundle.sh`). Mention the `VENDOR_DEBUG=<slug>` env var for users who want to reproduce the tester-debug log mode locally.
4. **Run** — launch the `.app` from `dist/`, including the right-click → Open Gatekeeper bypass.
5. **Compare** — optional `shasum -a 256` against the SHA in the sticky comment. Documented as best-effort: Swift release builds aren't strictly bit-for-bit reproducible.

Anything CI-specific (SwiftLint plugin stripping, GH Actions step list) stays in the workflow file or in `docs/DEVELOPMENT.md`.

### 6.4 Tester-debug build mode

Active only on builds produced by the new-assistant CI workflow (and reproducible locally with `VENDOR_DEBUG=<slug> ./scripts/build-app-bundle.sh`).

**What it does**

- Bakes the vendor slug into the produced `.app`'s `Info.plist` under the key `AITrackerVendorDebug`.
- At runtime, the logging subsystem reads that key (with `AI_TRACKER_VENDOR_DEBUG` env var as override) and routes the named vendor's connector through a `LoggingProxy` configured for `.debug` level + payload logging. Every other vendor stays at the regular level.
- Every payload (request body, response body, headers, error messages) flows through the connector's `PayloadSanitizing` implementation before reaching the log file. Sanitization is enforced at the proxy boundary per the contract from the [vendor plugin framework](vendor-plugin-framework.md) epic — there is no code path that produces "raw" logs even in tester-debug mode.
- The resulting log lands in the existing per-vendor connector log (`~/.cache/ai-usages-tracker/<vendor-slug>-usages-connector.log`), subject to the existing 5 MB rotation.

**What it does NOT do**

- It does not enable verbose logging for any vendor other than the one named.
- It does not bypass sanitization.
- It does not ship in stable releases. A user opening a stable release's Info.plist will not find an `AITrackerVendorDebug` key; the env-var override is the only way to activate verbose mode in a stable build, and that is intentional (power-user / debug path).

**Why this design**

- **Build-time activation, runtime override.** Putting the slug in `Info.plist` means a tester downloading the DMG just runs the app — no env vars, no flags. The env-var override exists for the maintainer reproducing a tester's bug locally without rebuilding.
- **Sanitization is mandatory, never optional.** Logs are the entire point of this mode, but the project doesn't trust contributors (or itself) to remember to redact each new field. The `LoggingProxy` is the choke point.
- **Per-vendor scoping.** A user happens to be running with three accounts on different vendors in the same DMG; only the vendor under test gets verbose logs. This both reduces noise and limits accidental data exposure to the vendor the tester opted into testing.
- **Reusing the existing connector log file.** No new file path to document, no new log rotation policy to configure.

### 6.5 In-app tester feedback

Active under the same conditions as tester-debug build mode. Reduces tester friction from "find the issue, copy the template, find the log file, drag-attach, submit" to "click banner, click submit, drag log".

#### Activation conditions

The feedback affordance is visible iff **all three** Info.plist keys are present in the running bundle:

- `AITrackerVendorDebug` — vendor slug under test
- `AITrackerBuildCommit` — full commit SHA (40 chars)
- `AITrackerOnboardingIssueURL` — fully-qualified GitHub issue URL

If any is missing, the feedback UI does not exist in the running app — there is no toggle, no settings entry, nothing. This guarantees that stable releases (none of the three keys baked) cannot expose the feature accidentally. The same triple is what the build script writes when invoked with `VENDOR_DEBUG`, `BUILD_COMMIT`, `ONBOARDING_ISSUE_URL` env vars.

#### UI surface

A small banner inside the popover, just above the vendor cards, when activation conditions are met:

```
🧪 You're running a tester build for <vendor-display>.
[Submit feedback →]
```

Visual styling subordinate to the usage content (it's a tester nudge, not a CTA competing with the metrics). Dismissible per-launch (a Close button on the banner only hides it for the current popover session — no persisted preference, since the build is short-lived by definition).

Clicking "Submit feedback" opens a sheet hosted by the popover (or a small detached window — implementation detail that fits whichever pattern the existing settings flow uses).

#### Form

Fields, top to bottom:

- **Build** (read-only): displays `<vendor-slug>` + the short SHA + a "Copy full SHA" affordance. Sourced from Info.plist; not editable.
- **Plan** (dropdown): Free / Pro / Team / Enterprise / Other (with a free-text field for Other).
- **macOS** (read-only, auto-detected): `ProcessInfo.operatingSystemVersionString` formatted to match the sign-off template.
- **Verified checklist**: matches the sign-off template's Verified items, each as a SwiftUI `Toggle`.
- **Connector log**: shows the log file path + size + a "Reveal in Finder" button. If the file is missing or empty, a non-blocking warning surfaces the situation but submission is still allowed (with the comment line `Connector log attached: no — file empty/missing`).
- **Notes** (free-form text, optional): translates to the `Notes:` line of the template.

A live-rendered preview of the resulting Markdown comment is shown below the form so the tester sees exactly what they're about to post.

#### Submit flow

The "Submit" button performs three actions in sequence (none of them GitHub-API-dependent):

1. Generates the comment body from the form and copies it to the system pasteboard via `NSPasteboard.general` (`declareTypes([.string], owner: nil)` + `setString(_:forType: .string)`). GitHub does **not** support pre-filling a comment body on an existing issue via a `?body=` query parameter — that pattern only works for the new-issue URL (`/issues/new?body=…`). The clipboard hand-off is the simplest reliable bridge that does not require a GitHub token.
2. `NSWorkspace.shared.open(url)` opens the user's default browser at `<AITrackerOnboardingIssueURL>#issuecomment-new` (the fragment scrolls to the comment composer on a logged-in browser session) so the tester just lands at the right place and pastes.
3. `NSWorkspace.shared.activateFileViewerSelecting([logFileURL])` reveals the log file in Finder, ready to drag into the GitHub composer.

A confirmation panel then displays the next step in plain language:
"Your browser opened the issue. Paste the comment (already on your clipboard) into the comment field, drag the highlighted log file from Finder onto it, then click **Comment**."

The app does not track whether the comment was actually posted; the issue + the follow-up skill are the system of record for that.

#### Why no GitHub API integration in v1

- **No credential handling.** The app does not currently store any user credential it produces; introducing a GitHub PAT keychain entry just for tester-debug builds adds a security surface for marginal UX gain.
- **No auto-upload of the log.** GitHub's REST API does not expose a documented "attach a file to an issue comment" endpoint without going through gist + linking, which means an extra public artifact the tester didn't necessarily intend.
- **Browser handoff is ergonomic enough.** The hard parts (template formatting, SHA, log file location, encoding) are all handled by the app; the tester does the equivalent of "click Comment" in the browser, which is the same gesture they'd do anyway.

A v2 with optional API-based posting (PAT pasted once into Settings, kept in Keychain, used to post the comment + upload the log via gist) is plausible but explicitly out of scope here.

#### Privacy posture

The form re-asserts the same sanitization invariant the connector enforces: the log file is already sanitized at write time. The app does not re-scan the log before submission — that would be a second source of truth for what counts as confidential, and discrepancies between the connector's sanitizer and a UI-side scanner would be subtle and dangerous. The single source of truth stays the connector's `PayloadSanitizing` implementation.

A short reminder appears next to the "Reveal in Finder" button: "The log is sanitized — but if anything looks confidential, edit the file before drag-attaching, and flag it in your notes so we fix the sanitizer."

## 7. Reviewer checklist (sketch)

`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md`, referenced by the PR template and read by `assistant-review`:

```
## Issue linkage
- [ ] PR body starts with `Closes #<issue>` and links an issue carrying
      `type:new-assistant` or `type:vendor-evolution`.
- [ ] Issue is currently at `phase:review`.
- [ ] (vendor-evolution only) `kind:*` label is present and matches the change.

## Contract
- [ ] Bundle registered in VendorRegistry; AppDelegate untouched.
- [ ] Credential locator implements `CredentialLocator`, read-only — no SecItem*
      writes, no writes to vendor config files.
- [ ] No MetricKind.unknown in the connector output (contract test passes).
- [ ] resetAt values are strict ISO 8601 datetimes (DEBUG assertion holds).
- [ ] Active-account monitor implements ActiveAccountMonitoring.start/stop.

## Documentation (dated snapshot)
- [ ] `docs/vendors/<vendor>.md` carries `Last verified: YYYY-MM-DD` and per-section
      verification dates **bumped in this PR**.
- [ ] Sample payloads tagged with capture date and plan; superseded samples kept
      with annotation, never deleted.
- [ ] External source links carry retrieval dates.
- [ ] (new-assistant) Change log seeded with the initial-capture entry.
- [ ] (vendor-evolution) Change log entry added describing the drift, what
      changed in our connector, and any kind:breaking implications.
- [ ] (vendor-evolution + kind:breaking) `Min app version: <next-version>`
      annotation present in the doc.
- [ ] A reader unfamiliar with the codebase could reproduce the connector from this
      doc alone.

## Tests
- [ ] Credential cascade covered (env / keychain / file each individually + cascade).
- [ ] Each documented plan variant has a representative response fixture.
- [ ] HTTP error codes seen in the wild are tested (4xx / 5xx).
- [ ] Date normalization tested (calendar date → UTC midnight if applicable).

## Sanitization
- [ ] `PayloadSanitizing` implementation present for the connector.
- [ ] `docs/vendors/<vendor>.md` Sanitized fields section is exhaustive vs the
      observed payload (every field captured in the dated samples is either safe
      to log or listed as redacted).
- [ ] Leakage test fixture (`Tests/Fixtures/<vendor>-full-payload.json`) seeded
      with realistic-looking secrets; the test asserts none survive sanitization.
- [ ] No connector log call passes a raw payload — every payload-bearing log
      entry routes through `LoggingProxy`.

## Build & validation (after phase:testing)
- [ ] DMG present in the issue's sticky build comment, filename matches
      `AI-Usages-Tracker-<vendor>-<sha8>.dmg`, SHA-256 listed, full commit SHA
      called out, vendor-debug slug shown.
- [ ] Tester threshold met on the latest build SHA — ≥ 2 non-author confirmations
      for new-assistant / kind:enrichment / kind:breaking; ≥ 1 for kind:urgent-fix
      (with follow-up confirmations expected post-release).
- [ ] Every counted confirmation lists the matching short SHA + full SHA in the
      sign-off body.
- [ ] Each counted confirmation has an attached connector log audited clean of
      secret leakage.
- [ ] Build-from-source path verified by the reviewer (optional spot check).
- [ ] In-app feedback banner verified to appear in the tester DMG and to be
      absent from a stable build of the same commit (smoke test).

## Per-type addenda

### type:new-assistant
- [ ] Vector PDF icon (`<vendor>-mark.pdf`) renders cleanly in light + dark menu bars.
- [ ] tintHex matches vendor brand reasonably; readable on both bars.
- [ ] VendorRegistry registration in place; AppDelegate untouched.

### type:vendor-evolution
- [ ] Targeted refactor — only files for the affected vendor (and shared
      infrastructure if genuinely needed) are changed.
- [ ] Existing tests for the connector still pass; new tests cover the new
      payload shape.
- [ ] Sanitization leakage test fixture updated for any new field.
- [ ] (kind:breaking) Graceful-degradation path verified: an old app build
      hitting the new payload shape does not crash; it surfaces a
      `lastError` describing "incompatible API" and stops emitting metrics.

## Post-release follow-ups (handled by assistant-release)
- [ ] (new-assistant) README "Supported assistants" updated.
- [ ] (vendor-evolution) `docs/vendors/index.md` row reflects the new
      Last verified date if the index exists.
- [ ] GitHub release notes credit testers by handle.
- [ ] (kind:breaking) Release notes prefixed `BREAKING:` with min-version
      requirement called out.
- [ ] (kind:urgent-fix) Release notes call out the urgent context and
      affected-since timeline.

```

## 8. Risks and open questions

- **Multi-day temporality.** Defining constraint. Each skill must be invocable cold and rebuild context from the issue + linked PR. Mitigation: the meta-skill always starts with `gh issue view`; sub-skills verify the current `phase:*` label before doing anything.
- **Issue / PR drift.** Two artifacts means two places where state can disagree. Mitigation: the issue is the system of record; the PR template is intentionally light and starts with `Closes #<issue>`; build comments are duplicated on both deliberately so neither side becomes the source of truth on its own.
- **Maintainer bottleneck.** Every `phase:*` transition requires the maintainer. That's the design intent — quality gates over throughput — but it means the maintainer is in the critical path. Mitigation: the skills do the boring work (tally, drafting comments) so the maintainer's time goes to decisions, not bookkeeping.
- **Gating action bypass.** A repo admin can technically still misuse phase labels. The action's value is preventing accidental or unauthorized changes from contributors / collaborators with `triage` or `write` access, not from admins acting in bad faith.
- **Mutex on phase labels.** If two label events fire concurrently the gating action could race. Mitigated by keeping the mutex check inside the same workflow that validates permissions and by `concurrency: cancel-in-progress: false` on the gate action so events queue rather than skip.
- **Tester recruitment latency.** Some vendors have small audiences; getting two confirmations may take days/weeks. The workflow does not pressure-merge — the issue simply waits at `phase:testing`. The README should call this out so contributors know the timeline up front.
- **Plan-variant coverage gap.** A tester on Free plan does not validate Paid behavior. The threshold of ≥ 2 testers is a floor; the reviewer checklist asks the maintainer to weigh whether all documented "verified" plan variants are covered before transitioning to `phase:merge-ready`. "Known unknowns" in the vendor doc capture variants left unverified.
- **Sticky-comment duplication on PR + issue.** Two posting points means twice the room for race conditions. Mitigated by `concurrency: cancel-in-progress: true` on the build workflow and the sentinel-driven find-or-create pattern.
- **Vendor doc maintenance over time.** Mitigation: the contract-side rule "if you touch the connector, you bump `Last verified` and append a Change log entry" + the optional `assistant-reverify` skill.
- **Build reproducibility.** Swift release builds aren't strictly bit-for-bit reproducible. The "verify SHA-256" step in `docs/CHECKOUT-AND-BUILD.md` is documented as best-effort. The trust path is "you read the source and you built it"; SHA matching is a bonus.
- **Tester accidentally pastes raw log into the issue.** Even with sanitization at the source, a tester might quote a snippet that happens to contain a borderline value the sanitizer missed. The follow-up skill replies inline with `<redacted>` in any quoted secret pattern when posting its audit comment, but the original tester comment is still public. Mitigation: the issue template up front + the sticky build comment both explicitly tell the tester to attach the log as a *file* (not paste it), and to flag anything that looks confidential rather than quote it. If a leak does land in a comment, the maintainer edits or deletes the comment and bumps `Last verified` after fixing the sanitizer.
- **Verbose mode noise.** A connector logging every HTTP exchange in tester-debug mode produces large files quickly. Mitigated by per-vendor scoping (only the vendor under test) + existing 5 MB rotation + the short-lived nature of `phase:testing` (days, not months).
- **Stable release accidentally ships with `AITrackerVendorDebug` set.** Mitigation: the release workflow (`release.yml`) explicitly does NOT pass `VENDOR_DEBUG` / `BUILD_COMMIT` / `ONBOARDING_ISSUE_URL`, and a unit test on the produced bundle's Info.plist asserts all three keys are absent. Tagged releases never carry tester-debug mode and never expose the in-app feedback banner.
- **In-app feedback banner shipped to the wrong issue.** If the build script is invoked with a stale or wrong `ONBOARDING_ISSUE_URL`, testers would post on an unrelated issue. Mitigation: the CI workflow derives the URL from the linked issue (the one referenced by `Closes #<n>` in the PR body) so the tooling is the source of truth, not human input. The build script refuses to bake the URL if it doesn't match the form `https://github.com/<repo>/issues/<n>`.
- **`?body=` URL too long for very chatty notes.** GitHub silently truncates URL-encoded comment bodies past ~8 KB. Mitigation: the form's free-form Notes field is character-capped (~2 KB) with a hint, the rest of the template is bounded by construction. If a tester really needs to share a long note, they fall back to the manual path or post a follow-up comment.
- **Tester clicks Submit but never finishes in the browser.** No way to detect this from the app — the issue simply doesn't get a comment. Mitigation: the meta-skill / follow-up skill remind the maintainer that "no comment = no confirmation"; the app does not pretend a submission was successful just because the browser opened.
- **Urgent-fix path abuse.** A contributor labels something `kind:urgent-fix` to bypass the 2-tester threshold when it isn't actually urgent. Mitigation: the issue form requires "Affected since" with a timestamp; the triage skill's draft asks the maintainer to validate that the field is actually broken in production (vs "vendor announced a deprecation 6 months out"). Only the maintainer can apply the kind label via the triage step, so a contributor cannot force the path through self-labeling.
- **Old-version users invisibly broken after a kind:breaking release.** Users on N-1 keep running their old binary, which now hits an incompatible vendor API and silently surfaces `lastError`. They might not notice for a while. Mitigation: the connector's degradation path produces a specific `lastError.type = "incompatible_api"` that the popover can present as "this assistant requires updating AI Usages Tracker"; the release notes carry the BREAKING callout; if the project ever gains an in-app update channel, this is where it would surface.
- **Vendor evolution without an issue.** A maintainer hot-fixing a small drift in a regular PR (no issue) bypasses the workflow entirely — no testers, no DMG, no Change log entry forced. Mitigation: the reviewer checklist for the regular PR template (separate from `assistant-change.md`) reminds reviewers to redirect connector-touching PRs through the assistant workflow; SwiftLint or a CI-side check could refuse a PR that modifies `Sources/.../Connectors/<Vendor>*.swift` without an associated issue link, but that's heavier than what this epic prescribes.
- **`docs/vendors/<slug>.md` getting deleted by mistake during evolution.** The dating-discipline rule "superseded samples kept, never deleted" is easy to violate accidentally. Mitigation: the implement skill is explicit that older samples must be annotated `superseded by <today>`; the review checklist surfaces "superseded samples preserved" as a checkbox; a CI check that diffs the doc and refuses to remove dated payload blocks could be added if violations recur.

## 9. Deliverables checklist

- [ ] `docs/ASSISTANT-ONBOARDING.md` — phase ↔ label ↔ skill map, with per-issue-type branching documented
- [ ] `docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md`
- [ ] `docs/CHECKOUT-AND-BUILD.md` — non-developer-friendly clone + build path
- [ ] `.github/ISSUE_TEMPLATE/new-assistant-request.yml`
- [ ] `.github/ISSUE_TEMPLATE/vendor-evolution-request.yml`
- [ ] `.github/ISSUE_TEMPLATE/config.yml` (route other issues away from these templates)
- [ ] `.github/PULL_REQUEST_TEMPLATE/assistant-change.md` (light, links the issue)
- [ ] `.github/workflows/phase-label-gate.yml` — maintainer-only `phase:*` enforcement (covers both issue types)
- [ ] `.github/workflows/assistant-build.yml` — DMG only, sticky comment on issue + PR; triggered by either issue type
- [ ] `.claude/skills/assistant/SKILL.md` (meta router — reads type:* AND phase:*)
- [ ] `.claude/skills/assistant-triage/SKILL.md` (optional helper, applies the kind:* label for vendor-evolution)
- [ ] `.claude/skills/assistant-implement/SKILL.md` (branches on type)
- [ ] `.claude/skills/assistant-review/SKILL.md`
- [ ] `.claude/skills/assistant-tester-followup/SKILL.md` (knows about the kind:urgent-fix threshold exception)
- [ ] `.claude/skills/assistant-merge/SKILL.md` (knows about the kind:urgent-fix threshold exception)
- [ ] `.claude/skills/assistant-release/SKILL.md` (branches on type for README + release notes treatment)
- [ ] `.claude/skills/assistant-reverify/SKILL.md` (doc-only refresh, no PR — when vendor doc needs re-dating without code change)
- [ ] DMG packaging step added to `scripts/build-app-bundle.sh` (or sibling script), DMG filename pattern `AI-Usages-Tracker-<vendor>-<sha8>.dmg`
- [ ] `VENDOR_DEBUG=<slug>`, `BUILD_COMMIT=<sha>`, `ONBOARDING_ISSUE_URL=<url>` env-var support in the build script that bakes `AITrackerVendorDebug`, `AITrackerBuildCommit`, `AITrackerOnboardingIssueURL` into the produced bundle's Info.plist
- [ ] Release-workflow guard: a unit/CI check asserts all three keys are absent from any tagged release bundle
- [ ] In-app tester feedback banner + form (SwiftUI) — only visible when all three Info.plist keys are present
- [ ] Browser-handoff submit flow: copy comment body to `NSPasteboard`, `NSWorkspace.shared.open(url)` to the issue, reveal log file in Finder (no `?body=` pre-fill — GitHub does not honor it on existing issues)
- [ ] `CLAUDE.md` lazy-loaded context update (mention `docs/ASSISTANT-ONBOARDING.md`)
- [ ] README "Supported assistants" section restructured to be append-friendly
- [ ] Labels created in the repo:
  - Type labels: `type:new-assistant`, `type:vendor-evolution`
  - Kind labels (vendor-evolution only): `kind:enrichment`, `kind:breaking`, `kind:urgent-fix`
  - Phase labels: `phase:proposed`, `phase:approved`, `phase:implementing`, `phase:review`, `phase:testing`, `phase:merge-ready`, `phase:merged`, `phase:released`
