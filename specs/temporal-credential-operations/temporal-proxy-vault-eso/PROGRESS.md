# Progress: Temporal Proxy + Vault PKI + ESO Rotation

**Spec Status:** IMPLEMENTING (milestone 3 in progress: scripts written, full rollover not yet run)
**Last Updated:** 2026-11-15

## Status Summary

Created 2026-11-13 by user direction. The demo runs CA rollover as
runbook scripts with self-verifying, idempotent steps and a metrics-based
retirement gate. The spec outlines the execution options without
recommending one: runbook scripts, a command-line tool, and a durable
RotateCredential Workflow across N Namespaces, all using the same step
contracts. Only the scripts are designed. Leaf
renewal is handled entirely by Vault PKI, External Secrets Operator (ESO), and
Temporal Proxy hot reload.

The demo runs on one k3d cluster (Vault dev mode, ESO, two Temporal Proxy
deployments, Prometheus, Grafana) against a real Temporal Cloud Namespace,
starting from a manually generated CA and migrating to a Vault issuer on the
first run.

## Milestone 1 Log

2026-11-13: Demo scaffold under
`demos/credentials-management/temporal-proxy-vault-eso/` (k3d config, proxy
image build from pinned commit 64fae49, proxy and CLI probe per client
namespace, Prometheus, Grafana dashboard, verify and hot-reload scripts).
`k3d 5.8.3` added to `.tool-versions`.

- Cluster, image import, Prometheus, and Grafana came up.
- Proxy needed `tls.ca` on the upstream (required with a client
  certificate); set to the system CA bundle. Probe needed a numeric UID.
- Initially blocked: the demo Namespace had an empty accepted client CA
  list and `authMethod: Restricted`, so Temporal Cloud reset the TLS
  handshake (reproduced from the host without the proxy). The Namespace was
  then configured for mTLS with the bootstrap CA accepted.
- **Milestone 1 verified** (`verify-proxies.sh`): 4 of 4 proxy replicas ready
  and reporting a loaded leaf whose NotAfter matches the mounted
  certificate; 28 probe calls per namespace per minute through Service DNS,
  0 failed; 0 TLS reload failures.
- **Hot reload verified** (`rotate-manual-leaf.sh`): after replacing the
  Secret with a new client leaf signed by the bootstrap CA, all 4 replicas
  reported the new NotAfter within about 61 seconds (kubelet sync plus the
  proxy's one-minute poll), with no Pod restarts and 0 probe failures
  during the reload.
- Known gap: probes start before proxies listen and log a few
  `connection refused` lines at startup.

## Milestone 2 Log

2026-11-13 (cluster clock 2026-11-14 UTC): Vault (chart 0.34.1, Vault 2.0.4,
dev mode) and ESO (chart 2.15.0) installed by `vault-eso-up.sh`. The Vault
CLI runs inside the Vault Pod, so operators need no local Vault install.

- Kubernetes auth: one Vault role per client namespace (`<ns>-pki`) bound to
  that namespace's `vault-pki-client` service account, audience `vault`.
  Verified each login yields only `default,temporal-client-issue`.
- `rollover/01-snapshot.sh` and `02-create-issuer.sh` written and run (both
  idempotent). Issuer `ca-20261114T043141Z` (EC P-256, internal key) created;
  first run also created role `temporal-client` pointing at it.
- ESO resources applied ahead of the switch into an unused Secret
  `temporal-cloud-leaf`: leaves are EC P-256, client-auth only, 30-minute
  TTL, chained to the new issuer. Proxies still mount the manual Secret.
- ESO forced refresh verified on 2.15.0: changing the `force-sync`
  annotation reissues the leaf within seconds (`force-refresh.sh`).
- Fixed a milestone 1 packaging gap: `.gitignore`'s `lib/` rule excluded
  `scripts/lib/common.sh`; added a negation. `.state/` (exported public
  issuer certificates) is ignored.
- `03-add-trust.sh` run with user approval (2026-11-13): the Namespace now
  accepts the manual CA (`d22f34b1…`) and `ca-20261114T043141Z`
  (`db702d89…`). A 5-minute test leaf from the new issuer completed a call
  within about a minute. Re-run skipped the add and re-verified.
- `migrate-switch.sh`: switched at 2026-11-14T04:43:50Z. One rolling restart
  per namespace; 0 probe failures since the switch.
- `verify-migration.sh` first failed: Prometheus returned 8 leaf series for 4 Ready
  Pods (the terminated Pods' series linger). The gate now evaluates only
  series from Pods Kubernetes reports as Ready; spec updated. Re-run passed:
  4 of 4 proxies on Vault leaves, no reload failures, probes clean.
- **Milestone 2 verified** (`watch-renewals.sh 3`, 04:44:57Z to 05:14:04Z):
  every proxy replica loaded 3 consecutive ESO-delivered leaves (refreshes at
  04:52:01, 05:02:01, 05:12:01) with no Pod restarts, no TLS reload
  failures, and 0 failed probe calls out of 793 per namespace.
- Measured delay from ESO refresh to proxy reload: 59s to 123s (median
  about 72s). This includes kubelet sync, the proxy's 1-minute poll, the
  15-second Prometheus scrape, and the script's 15-second poll. Size the
  gate wait as R + 3 minutes.

## Milestone 3 Log

2026-11-15:

- Probe failures after milestone 2 traced to the host sleeping: ESO could not
  refresh, the 30-minute leaves expired, Temporal Cloud returned
  `tls: expired certificate`, and restarted proxies failed to start because
  Temporal Proxy rejects an expired certificate at startup (up to 15
  restarts). Recovered at ESO's next refresh. Added a risk row, an
  implementation note, and a preflight check that refuses to start a rollover
  while a loaded leaf expires within 5 minutes.
- Scripts written: `00-preflight`, `04-switch`, `05-verify [--force-refresh]`,
  `06-retire`, `rollback`, `inject-eso-failure`, `check-issuer-expiry`,
  `demo-rollover` (steps 0 to 6 in one command), `apply-settings`. The gate is
  shared in `lib/common.sh`; `01-snapshot` records the old issuer;
  `bootstrap-manual.sh` re-adds the bootstrap CA when a previous run retired it.
  `06-retire` evaluates the gate itself, so it refuses and names stale proxies
  even when `05-verify` was skipped.
- Grafana annotations posted from inside the Grafana Pod (its admin password
  never leaves the cluster); dashboard shows them. Four Prometheus alert rules
  load (renewal stalled, reload failed, proxy missing, forwarding errors).
- Design change (user direction): demo timing moved to
  `demo-settings.env` and applied live by `apply-settings.sh`. Defaults changed
  from a 10-minute refresh with 30-minute leaves to a 1-minute refresh with
  5-minute leaves, so one routine rollover takes about 6 minutes. The gate's
  clock-skew allowance dropped from 120 to 5 seconds: at 120 seconds, a leaf
  issued just before the switch passed the gate. `05-verify` now polls the gate
  every 15 seconds from switch + R instead of sleeping a fixed 3 minutes.
- `watch-renewals.sh` counted a renewal only when NotAfter increased, which
  failed when the leaf lifetime was shortened; it now counts any change.
  Verified at the new defaults: every proxy loaded 2 consecutive renewals,
  6 to 55 seconds after each ESO refresh, no restarts, 0 failed probe calls.
- Verified read-only against the live demo: `00-preflight`,
  `check-issuer-expiry`, the shared gate, `apply-settings`.
- Not yet run (changes the demo Namespace): finishing the migration with
  `05-verify` and `06-retire`, `demo-rollover`, the failure-injection
  walkthrough, and `rollback`.

## Open Items

- [x] Demo Namespace configured for mTLS with the bootstrap CA accepted
      (2026-11-13). Preflight must check this.

- [x] ESO backend: real Vault in dev mode with Kubernetes auth. No AWS
      emulator and no ESO fake provider (2026-11-13): neither exercises
      Vault PKI issuance, which the rotation depends on.
- [x] The demo may remove the bootstrap CA: the demo Namespace is dedicated
      to the demo (2026-11-14, user direction).
- [ ] Milestone 3: `bootstrap-manual.sh` re-adds the bootstrap CA when a
      previous run retired it; `06-retire.sh` removes it like any old CA.
- [x] Sample traffic Workflow is Java (2026-11-13, user direction). The
      rotation is runbook scripts in this demo.
- [x] Temporal Proxy routing for Namespace-less system calls with one
      upstream works (`routing.system` = `routing.default`), milestone 1.
- [x] Proxy request series: `tmprl_proxy_server_requests_total{method,code}`
      and `tmprl_proxy_router_forwarding_errors_total{upstream,reason}`.
- [x] ESO forced refresh: `force-sync` annotation, verified on 2.15.0.
- [ ] Gather requirements before choosing an execution option: CA topology
      across Namespaces, Acme security team requirements, Namespace count,
      owning team.
- [ ] Answer the proposal's production-adoption questions (`spec.html`,
      Open Questions): client inventory, accepted-CA ownership versus
      Terraform Enterprise, Vault PKI placement, cross-cluster metrics,
      proxy placement.

## Feedback Items

- 2026-11-14 (user): "Once a year justifies a runbook" does not hold for
  about 50 Namespaces, and a distinct CA per Namespace is not assumed. Design
  change: the Position section is replaced by "Rollover execution options",
  which lists runbook scripts, a command-line tool, and a RotateCredential
  Workflow across N Namespaces with trade-offs and no recommendation. Only
  the scripts are designed until requirements are known.
- 2026-11-14 (user): Unlike the earlier Credential Supervisor design
  (`rotate/spec.md`), which watched Worker and Caller Deployments, the proxy
  means a RotateCredential Workflow supervises only credential material.
  Conforming clarification in the execution options section.
- 2026-11-14 (user): The spec must stand alone. Current state is summarized
  inline and links to other specs are removed. Added "What Temporal Proxy
  makes observable" (signals today vs. with the proxy, replacing expiry
  email) and alerts for a missing proxy and forwarding errors.
- 2026-11-14 (user): Anyone should be able to clone the repository, fill in
  `.env.local`, and run the demo. Design change: the demo requires a
  Temporal Cloud Namespace dedicated to it, and the scripts own its accepted
  CAs, so the bootstrap CA is retired like any old CA and re-added on a
  later run. `--retire-bootstrap-ca` and the related blocker and question are
  removed. Inputs renamed to `TEMPORAL_DEMO_NAMESPACE_ADDRESS`,
  `TEMPORAL_DEMO_CA_CERT_FILE`, `TEMPORAL_DEMO_CA_KEY_FILE`; the Ops API key
  needs an account-level role (Global Admin). Repository-root `.env.example`
  and the demo README describe the setup.

- 2026-11-15 (user): The spec had become a specification of the demo, but
  the concern is a proposed implementation that Acme's operations team must
  be able to evaluate. Design change: the previous `spec.html` is now
  `demo-spec.html` (demo topology, components, scripts, demo-only values,
  validation). A new `spec.html` is the proposal: current state, production
  architecture, lifecycles, rollover step contracts, retirement gate,
  migration, security model, design alternatives, production parameters,
  execution options, evolution, risks, and open questions. New open
  questions surfaced in the proposal: client inventory, ownership of
  accepted client CAs versus Terraform Enterprise, Vault PKI placement,
  cross-cluster metrics for the gate, and proxy placement.
- 2026-11-15 (user): If the rollover runner becomes a RotateCredential
  Workflow, its Activities should call the Temporal Cloud Ops API, Vault,
  Kubernetes, and metrics APIs directly rather than shelling out to `tcld`,
  the Vault CLI, or `kubectl`. Conforming clarification in the proposal's
  execution options and evolution sections.

## Roadmap

1. Proxy path with manual CA, CLI probes, metrics, dashboard.
2. Vault PKI, ESO, migration run, observed renewals.
3. Rollover scripts, failure injection, annotations.
4. Sample Workflow replacing the probes.
5. Runbook text from actual script output.
