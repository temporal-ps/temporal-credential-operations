# AGENTS.md

This repository follows the specification workflow described in `/specs/README.md`.

## Repository Purpose

This repository contains a Temporal **operational engagement**: a set of
runbooks and demonstrations that illustrate how to operate a Temporal-backed
application in production. The setting is a commerce (order management)
Temporal application, used as a realistic backdrop for each operational
concern rather than as an end in itself.

This repository is expected to be shared with a customer. Treat everything
committed here — specs, runbooks, demos, scripts, README content — as
customer-facing material.

## Engagement Shape

The engagement is organized as a set of **Operational Concerns** (for
example: credential management). Each Operational Concern is
specified, then implemented, as:

1. **Spec** (`specs/temporal-credential-operations/<concern>/spec.html` +
   `PROGRESS.md`) — defines the problem, the approach, and the two
   deliverables below before any runbook or demo work begins.
2. **Runbook** (`runbooks/<concern>/`) — a step-by-step operational procedure
   a customer's platform or operations team can follow directly.
3. **Demo** (`demos/<concern>/`) — a runnable illustration that exercises the
   scenario the runbook describes, so the approach can be seen working rather
   than only read about.

Not every concern requires new application code — some demos may configure
or drive an existing service rather than introduce a new one. Check
`specs/temporal-credential-operations/<concern>/spec.html` for what a given
concern's demo actually needs before creating new application scaffolding.

## Internal Sources vs. Committed Output

This work is informed by internal Temporal reference material: internal
engineering knowledge bases, internal reference applications, and internal
skill/agent guidance on Temporal application structure, Kubernetes
deployment, and workshop-style runbook authoring.

That material may inform judgment calls, but it must never be named, linked,
path-referenced, or otherwise identifiable in anything committed to this
repository:

- Do not reference internal repository names, internal file paths, or
  internal tool names in specs, runbooks, demos, scripts, or comments.
- Do not use real customer names in committed material. Use `Acme` for the
  fictional company name in this repository, or a neutral label such as
  "the customer" when a name is unnecessary.
- Do not copy internal document text verbatim; restate the underlying
  technical substance in this engagement's own words and context.
- Fictional application/company names used for the commerce scenario should
  be original to this repository, not reused from internal reference
  material, unless the user explicitly says otherwise.
- If unsure whether something originated internally and is safe to include,
  ask rather than guess.
- Do not name Acme's internal teams. Use role labels instead: the
  fulfillment team, the infrastructure team, the Kubernetes team.
- Keep customer notes, discovery answers, and other sensitive working notes
  in the gitignored `.local/` directory, never elsewhere in the repository.

## Repository Orientation

Before doing repository work, orient from the repository's governing
sources. Scope the reading to the task, but do not skip this orientation:

1. Inspect `git status` so existing user changes are visible.
2. Read `/specs/README.md` for the workflow this repository follows.
3. For any Operational Concern you are touching, read
   `specs/temporal-credential-operations/<concern>/spec.html` and
   `PROGRESS.md` before reading or changing its runbook or demo.
4. Search `specs/`, `runbooks/`, and `demos/` for terminology, commands, or
   architecture decisions that the requested change might affect.
5. If a runbook, demo, or script appears to contradict its spec, report the
   conflict and follow the spec unless the user explicitly directs a design
   change.

## Working Role

Act as an implementer of a spec that has already been aligned on with the
user, not as its independent designer, unless the user explicitly asks for
design work. Your responsibility is faithful implementation of the approved
approach, consistency between spec/runbook/demo, and controlled evolution as
the engagement progresses through the workflow stages.

## Change Control

### Conforming Changes

A conforming change implements or improves a runbook, demo, or spec section
without altering the approach the spec already commits to. Examples:
improving prose, adding a missing command, adding cross-references, fixing
an inconsistency between the spec and the runbook, generating a demo script
from an already-approved design.

Conforming changes may proceed without renegotiating the spec.

### Design Changes

A design change alters the chosen approach, architecture, or scope of a
concern's deliverables. Examples: switching the primary tool/pattern the
runbook demonstrates, changing what the demo proves, adding or removing a
deliverable, changing which Operational Concerns are in scope for the
engagement.

For a design change:

1. Update the concern's `spec.html` first.
2. Clearly identify the changed decision and why.
3. Update `PROGRESS.md`, the runbook, and the demo only after the spec is
   internally consistent again.
4. Report all affected files.

Do not make design changes implicitly while drafting a runbook or demo.

## Missing Information

When required information is absent:

- Do not invent customer environment details, Temporal product behavior, or
  tool capabilities you have not verified.
- Insert `TODO(author): ...` when a human decision is required.
- Insert `OPEN QUESTION: ...` when the design requires resolution before
  implementation can proceed.
- State assumptions explicitly when the task permits assumptions.
- Prefer a visible gap over a plausible but unverified addition — this is
  especially important for runbook commands and demo scripts, which readers
  will run as-is.

## Documentation Style

Use clear, direct Markdown.

- Specs describe and justify an approach; runbooks instruct; demos show.
  Don't blur the three — a runbook step is an instruction, not a
  justification, and belongs in imperative voice with a verifiable outcome.
- Every runbook command a reader is expected to run should state how to
  verify it worked.
- Use tables for compact comparisons (design decisions, risks).
- Spell out an acronym in full on first use, with the acronym in parentheses
  immediately after.
- Avoid promotional or inflated language — this reads as engineering
  material, not marketing.

## Spec Format

Specs are HTML (`spec.html`), copied from `specs/TEMPLATE.html` and styled
by the shared `specs/assets/spec.css`, which follows the Temporal
documentation site's palette. Keep styling in that stylesheet, not inline.
Use Mermaid (pinned version from a CDN, as in the template) for diagrams.
`PROGRESS.md`, runbooks, and demo READMEs stay Markdown.

`spec.html` is the customer-facing proposal: it must let the customer's
operations team evaluate the approach, so it covers the problem, the
proposed design, alternatives, risks, open questions, and evolution, not
demo mechanics. Demo design that outgrows the spec's Deliverables section
goes in `demo-spec.html` beside it.

Some older specs are still `spec.md`. Convert a spec to HTML the next time
it receives a substantive change, and delete the Markdown file in the same
change.

## File Organization

Expected paths:

```text
specs/README.md
specs/TEMPLATE.html
specs/assets/spec.css
specs/temporal-credential-operations/<concern>/spec.html
specs/temporal-credential-operations/<concern>/demo-spec.html   # optional
specs/temporal-credential-operations/<concern>/PROGRESS.md
runbooks/<concern>/...
demos/<concern>/...
```

A concern with more than one distinct approach worth demoing separately
nests one subfolder per approach instead of becoming multiple top-level
concerns:

```text
specs/temporal-credential-operations/<concern>/<approach>/spec.html
specs/temporal-credential-operations/<concern>/<approach>/PROGRESS.md
runbooks/<concern>/<approach>/...
demos/<concern>/<approach>/...
```

Prefer updating the canonical file over adding a new version with suffixes
such as `-new`, `-final`, `-revised`, `-v2`.

## Safe Editing Procedure

Before modifying a concern's files:

1. Read `specs/temporal-credential-operations/<concern>/spec.html` and `PROGRESS.md`.
2. Read the runbook/demo files directly affected by the task.
3. Classify the requested work as a conforming change or design change.
4. Make the smallest coherent change.
5. Review the diff for drift from the spec.

After modifying files:

1. Verify the runbook, demo, and spec still agree with each other.
2. Verify no internal repository names, internal paths, or internal tool
   names were introduced (see Validation below).
3. Report any remaining inconsistencies.
4. Do not claim validation succeeded unless the checks were actually
   performed.

## Validation

For content changes, perform at least these checks:

```bash
git diff --check
git grep -n -I -i -w -f .local/denylist.txt || true
```

The grep reads terms that must never appear in committed files (internal
source names, Acme team names, account identifiers) from the gitignored
`.local/denylist.txt`, so the terms themselves are never committed. Add new
terms to that file as they come up. Without that file the check cannot run;
ask the user for it rather than skipping the check. If Markdown linting or link checking is configured in the
repository, run those checks as well.

Do not rewrite unrelated content solely to satisfy personal stylistic
preferences.

## Git Safety

- Inspect `git status` before editing.
- Do not discard or overwrite existing user changes.
- Do not reset, clean, or force-checkout files unless explicitly directed.
- Keep changes scoped to the requested task.
- Do not amend existing commits unless explicitly directed.
- Do not commit or push unless the user explicitly requests it.
- Summarize changed files and unresolved TODOs at completion.

## Final Response

At completion, report:

1. Files created or modified.
2. Whether the change was conforming or a design change.
3. Validation performed.
4. Any TODOs, open questions, assumptions, or unresolved conflicts.

Do not claim that content is approved, authoritative, or customer-ready
unless the user has said so.
