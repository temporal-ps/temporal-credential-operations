# Specifications Directory

This directory contains the specs that drive the
temporal-credential-operations engagement.
Each spec covers one **Operational Concern** — a production-operations topic
(for example, credential management) that gets a runbook and a
demo once its spec is approved.

See `AGENTS.md` at the repository root for the full engagement shape and the
constraint that internal reference material must never be named or linked in
committed content.

## Spec Format

Specs are HTML pages (`spec.html`) built from `TEMPLATE.html` and styled by
`assets/spec.css`. Open a spec directly in a browser; no build step is
needed. Diagrams are hand-written inline SVG styled by the `.dg` classes in
`spec.css`, so they follow the light and dark themes. Do not use Mermaid.
`PROGRESS.md` stays Markdown.

## Workflow

```
1. DRAFT          → Author writes spec.html using TEMPLATE.html
2. REVIEW         → Reviewer reads spec.html, leaves feedback in PROGRESS.md
3. APPROVED       → Approach is settled; runbook/demo work may begin
4. IMPLEMENTING   → Runbook and demo are authored per the spec's phases
5. VALIDATING     → Runbook steps and demo are run end-to-end and confirmed
6. COMPLETE       → Runbook and demo ship; lessons captured in PROGRESS.md
```

A concern should not move to IMPLEMENTING while it still has unresolved
"Questions for Reviewer" in its `spec.html` — resolve those first, even if the
resolution is "explicitly deferred, see below."

## Directory Structure

```
specs/
├── TEMPLATE.html                   # Copy this to start a new concern
├── assets/spec.css                 # Shared spec stylesheet (Temporal docs palette)
├── README.md                       # This file
└── temporal-credential-operations/
    └── <concern-name>/
        ├── spec.html               # What, why, and the approach
        ├── demo-spec.html          # Optional: how the demo is built
        └── PROGRESS.md             # Status, review feedback, roadmap
```

`spec.html` is written for the customer team that will evaluate and operate
the approach: the problem, the proposal, alternatives, risks, open
questions, and how it can evolve. When the demo needs more design than the
spec's Deliverables section can hold (topology, components, scripts,
demo-only values), put it in `demo-spec.html` and link the two. The spec
governs where they differ.

When a concern has more than one distinct approach worth demoing separately
(for example, two different tools that solve the same operational problem),
nest one subfolder per approach instead of spinning up separate top-level
concerns:

```
specs/temporal-credential-operations/<concern-name>/
├── <approach-a>/
│   ├── spec.html
│   └── PROGRESS.md
└── <approach-b>/
    ├── spec.html
    └── PROGRESS.md
```

Runbooks and demos live outside `specs/`, mirroring whichever layout the
spec used — `runbooks/<concern-name>/` and `demos/<concern-name>/`, or
`runbooks/<concern-name>/<approach>/` and `demos/<concern-name>/<approach>/`
— once a spec reaches APPROVED.

## Creating a New Concern

1. Copy the template:
   ```bash
   mkdir -p specs/temporal-credential-operations/<concern-name>
   cp specs/TEMPLATE.html specs/temporal-credential-operations/<concern-name>/spec.html
   # or, for a concern with multiple approaches:
   mkdir -p specs/temporal-credential-operations/<concern-name>/<approach-name>
   cp specs/TEMPLATE.html specs/temporal-credential-operations/<concern-name>/<approach-name>/spec.html
   ```
2. Fill in each section of `spec.html` — start with the Executive Summary,
   then Goals & Success Criteria, then work through to the Deliverables
   section, which is where the runbook and demo get scoped concretely.
3. Create `PROGRESS.md` alongside it, tracking review status and open
   items.
4. Request review before any runbook or demo work begins.

## Spec Checklist (For Author)

Before requesting review, ensure:

- [ ] Executive summary is clear to someone unfamiliar with this concern
- [ ] Goals are measurable and specific
- [ ] Acceptance criteria are testable, not vague
- [ ] Design decisions explain the "why," with alternatives considered
- [ ] The Runbook deliverable states its audience and a concrete outline
- [ ] The Demo deliverable states what it proves and what it does not
- [ ] Risks are identified — no "this will definitely work"
- [ ] Open questions are explicit, not hidden
- [ ] No internal repository names, paths, or tool names appear anywhere

## Reviewer Checklist

When reviewing a spec:

1. **Clarity:** Is the operational problem and its stakes understandable?
2. **Scope:** Is this one coherent concern, not several bundled together?
3. **Risks:** Are the failure modes a customer would actually hit named?
4. **Runbook fit:** Will a platform/ops reader be able to execute this as
   written, or does it assume undocumented context?
5. **Demo fit:** Does the demo actually exercise the runbook's scenario, or
   just adjacent functionality?
6. **Leakage:** Does anything here name or imply an internal-only source?

Leave feedback in `PROGRESS.md` under Feedback Items.

## Current Concerns

### Credential Operations: Temporal Proxy + Vault PKI + ESO

- **Spec:** `specs/temporal-credential-operations/temporal-proxy-vault-eso/`
  (`spec.html` is the proposal; `demo-spec.html` specifies the demo)
- **Demo:** `demos/credential-operations/temporal-proxy-vault-eso/`
- **Goal:** Rotate the client certificate authority (CA) Temporal Cloud
  trusts, with Vault PKI signing short-lived leaves, External Secrets
  Operator (ESO) delivering them, and Temporal Proxy presenting them with hot
  reload. Shown on a local k3d cluster against a real Temporal Cloud
  Namespace, with Grafana showing each rotation.

## Tips

- **Be specific:** name the exact CRD, metric, or CLI command, not "some
  autoscaler" or "some metric."
- **Think about the reader:** a runbook is read under production pressure —
  every step needs a way to check it worked.
- **One concern per spec:** resist bundling related-but-distinct concerns;
  it's easier to scope, review, and demo independently.
- **Question everything:** list assumptions and open questions explicitly
  rather than resolving them silently.
