# Assistant onboarding and evolution workflow

## Goal

Industrialize the end-to-end process of **shipping any vendor-scoped change** in AI Usages Tracker — both adding support for a new AI assistant **and** evolving the integration of an existing one when the vendor's API drifts (additive enrichments, backward-incompatible refactors, or urgent emergency fixes when the vendor unilaterally breaks compatibility).

The workflow covers, end-to-end:

- LLM-guided implementation against the vendor plugin contract.
- Auditable PR review checklist, including doc dating and sanitization compliance.
- Nightly DMG build attached to a dedicated GitHub issue for non-author testers, with verbose vendor-debug logging and an in-app feedback affordance.
- Community-validation gate before merge.
- Officialization on the next tagged release (and explicit breaking-change call-out when applicable).

This workflow spans **days to weeks of wall-clock time**, not a single LLM session. Implementation, build, tester recruitment, validation, and merge each happen at different moments and frequently in different sessions or even different machines. The skill design must reflect that — there is no single prompt that drives the whole thing.

Two kinds of work share this lifecycle:

- **`type:new-assistant`** — adding a vendor not yet supported by the app.
- **`type:vendor-evolution`** — modifying an already-supported vendor's connector when its API evolves (qualified by a `kind:enrichment` / `kind:breaking` / `kind:urgent-fix` sub-label).

Both go through the same `phase:*` labels, the same skill family, the same nightly-build pipeline, and the same tester sign-off threshold. The skills branch on issue type only where the work genuinely differs (scaffolding vs in-place refactor; README update on first ship vs none on evolution; release notes wording; whether the urgency escape hatch on the threshold applies).

## Dependencies

- [Vendor plugin framework](vendor-plugin-framework.md) — the contract this workflow enforces.

## Scope

- A **dedicated GitHub issue** is the system of record for the entire vendor-scoped lifecycle (request → approval → implementation → review → testing → merge → release). The PR is one artifact referenced by the issue; the issue persists before the PR exists and after it is merged.
- **Two issue forms** under `.github/ISSUE_TEMPLATE/`:
  - `new-assistant-request.yml` for new vendors (vendor name, proposer, known credential sources, known plan variants, links to vendor's API references).
  - `vendor-evolution-request.yml` for changes to an existing vendor (vendor slug, kind of change, observed drift, app-version-bump impact).
- **Phase progression is gated by a single mutex label** `phase:<step>` on the issue, identical for both kinds. Only the maintainer can transition phase labels — enforced by a GitHub Action that validates label changes and reverts unauthorized transitions.
- A `docs/ASSISTANT-ONBOARDING.md` spec describing every phase: trigger event, current label, owning skill, inputs, outputs, exit condition. The spec is the single source of truth; every skill, the issue form, and the PR template reference it.
- A **family of complementary skills** — not a single monolithic skill — each scoped to one phase transition. Skills are named `assistant-*` (not `new-assistant-*`) because they handle both kinds of work; the implementation skill in particular branches on issue type to either scaffold a new vendor or refactor an existing one. A short meta-skill reads the issue's `type:*` and `phase:*` labels and routes the user to the right sub-skill.
- A reusable PR template at `.github/PULL_REQUEST_TEMPLATE/assistant-change.md` (lighter than before — most of the structured information lives on the issue, the PR template only carries technical-review checkboxes and a "Closes #<issue>" link).
- A GitHub Actions workflow that builds an ad-hoc-signed **DMG** for any PR linked to either a `type:new-assistant` or a `type:vendor-evolution` issue, and posts the build pointer **on the issue** so testers don't have to dig through PR comments. The PR also gets a build comment for reviewers. Skeptical readers follow `docs/CHECKOUT-AND-BUILD.md` to clone and build locally — no ZIP.
- A reviewer checklist (`docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md`) covering documentation clarity (including "is the dating discipline applied?"), contract compliance, test coverage, tester-feedback completeness, and per-issue-type addenda (new-vendor: branding asset and registry registration; vendor-evolution: Change-log entry, superseded samples preserved, app-version bump if breaking).
- A documented tester-validation protocol: testers comment on the **issue** (not the PR) using a magic sentinel; default threshold **≥ 2 distinct non-author testers** ✅; the issue body keeps a running tally maintained by the follow-up skill. An **emergency escape hatch** applies for `kind:urgent-fix` issues (vendor unilaterally broke compat, the connector is currently broken in production): a single non-author confirmation is acceptable to merge, with the issue staying open for follow-up confirmations after release.
- **Tester-debug build mode**: the nightly DMG attached to a `type:new-assistant` PR is built with verbose logging enabled for the vendor under test (and only that vendor). Payloads are logged in full but sanitized — confidential fields stripped at the logger boundary per the contract from the [vendor plugin framework](vendor-plugin-framework.md) epic. Testers attach the resulting log file to their sign-off comment so the maintainer can debug the implementation against real subscriptions without the testers having to hand-redact secrets.
- **In-app tester feedback**: the same nightly DMG ships with a tester-only banner in the popover that opens a feedback sheet, pre-fills the sign-off template (build SHA, vendor slug, macOS version, checklist), and on submission opens the GitHub issue in the browser with the comment body URL-encoded plus reveals the connector log in Finder so the tester can drag-attach it. No GitHub authentication required. The banner is invisible in stable releases by construction (it depends on Info.plist keys only present on tester-debug builds). The legacy manual-comment path stays documented as a fallback.
- **Build provenance everywhere**: the commit SHA is threaded through the DMG filename (`AI-Usages-Tracker-<vendor-slug>-<sha8>.dmg`), baked into the bundle's Info.plist (`AITrackerBuildCommit`, full SHA), called out in the sticky build comment, and required in the tester sign-off so a confirmation cannot be silently mis-attributed to a different build.

**Out of scope**

- Apple Developer ID signing or notarization. Builds remain ad-hoc signed; the build-from-source path is the trust escape hatch.
- Shipping a ZIP alongside the DMG. The DMG is the only prebuilt artifact; everything else is "clone and build".
- A scaffold shell script. Skills do the scaffolding directly.
- Custom GitHub issue types (Enterprise feature). The issue form + `type:new-assistant` label cover the same need on every plan.
- Automated payment-tier detection. Testers self-declare their plan in their feedback comment.
- A merge bot that auto-merges once the threshold is met. Merge stays manual; the workflow only surfaces readiness.
- A separate forum / chat for tester recruitment — recruitment happens on the issue and any community channel the maintainer chooses.

## Acceptance criteria

- `docs/ASSISTANT-ONBOARDING.md` exists, describes every phase including its trigger event, the `phase:*` label transition, and the owning skill, with explicit per-issue-type branches where new-assistant and vendor-evolution diverge. Referenced from the lazy-loaded section of `CLAUDE.md`.
- Both issue forms exist under `.github/ISSUE_TEMPLATE/`: `new-assistant-request.yml` (applies `type:new-assistant` + `phase:proposed`) and `vendor-evolution-request.yml` (applies `type:vendor-evolution` + `phase:proposed`). The `kind:*` label for vendor-evolution issues is applied during triage by the `assistant-triage` skill, which reads the form's `kind` dropdown value — GitHub issue forms can only apply static labels from their frontmatter, so dynamic per-submission labels are necessarily a triage-time concern.
- A GitHub Actions workflow validates every `phase:*` label change on issues carrying `type:new-assistant` or `type:vendor-evolution` against a maintainers list. Unauthorized changes are reverted automatically.
- The skill family is in place under `.claude/skills/` as `assistant-*`, each skill scoped to one phase transition (triage, implementation, review, tester follow-up, merge, release/officialization, re-verification). Each skill reads the issue's `type:*` + `phase:*` labels, branches its behavior accordingly, performs its work, and applies the next phase label via `gh issue edit`.
- A meta-skill `assistant` reads the issue's `type:*` + `phase:*` labels and routes the user to the right sub-skill rather than acting itself.
- A push on a PR linked to either issue type triggers the build workflow with the tester-debug flag, the commit SHA, and the issue URL baked into the bundle's Info.plist. The DMG filename includes the vendor slug and the short SHA. The workflow posts (or updates) a sticky comment on the issue and a sibling reviewer comment on the PR.
- `docs/CHECKOUT-AND-BUILD.md` exists and walks a non-developer reader through cloning the PR branch, building locally, and running the app — short enough that a skeptical tester can follow it without prior Swift experience.
- Every PR for an assistant change uses `.github/PULL_REQUEST_TEMPLATE/assistant-change.md` and starts with `Closes #<issue>` so closing the PR feeds back into the issue lifecycle.
- A reviewer can audit a PR against `docs/REVIEW-CHECKLIST-ASSISTANT-CHANGE.md`, which covers contract compliance, doc clarity, test coverage, tester-feedback completeness, and per-issue-type addenda.
- On `type:new-assistant` release: README's "Supported assistants" section is updated. On `type:vendor-evolution` release with `kind:breaking`: the GitHub release notes carry an explicit "Breaking change for `<vendor>`" callout and the next release tag is a major bump (or a clearly-noted minor bump if the project chooses lenient SemVer for app releases). On both: the issue transitions to `phase:released` and closes.

## Notes

- See `new-assistant-onboarding-workflow.plan.md` for deep research: phase-label lifecycle, per-phase skill split, issue form + gating action, build-pipeline design, tester sign-off mechanics, risks.
- Skills orchestrate but never bypass review — the threshold of human ✅ confirmations remains a hard gate enforced by the maintainer-only label transition.
- The temporality is the central design constraint: each skill must be invocable cold, with no in-memory state from previous sessions, by re-reading the issue's current `phase:*` label and the linked PR state.
- The issue is the durable contract; the PR is a transient artifact that comes and goes within the issue's lifecycle.
