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
starting on Vault: setup creates the first issuer and makes the dedicated
Namespace trust it. Milestones 1 and 2 below were built on an earlier design
that started from a manually generated CA and migrated; that stage was removed
on 2026-11-15 (see Feedback Items).

## Milestone 1 Log

2026-11-13: Demo scaffold under
`demos/credential-operations/temporal-proxy-vault-eso/` (k3d config, proxy
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
- [x] Run `up.sh` on a new cluster (2026-11-15): `bootstrap-issuer.sh`
      replaced the Namespace's two accepted CAs with `ca-20261115T054439Z`,
      a test leaf was accepted, and the proxies started on ESO leaves.
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
- 2026-11-15 (user): The demo does not need to show the customer's current
  handling, only the proposal. Design change: the demo starts on Vault.
  `up.sh` now installs Vault and ESO and runs `bootstrap-issuer.sh`, which
  creates the first issuer and, on a new cluster, replaces the dedicated
  Namespace's accepted CAs with it (`tcld accepted-client-ca set`). Proxies
  mount the ESO Secret from their first start. Removed: the bootstrap CA
  inputs, `bootstrap-manual.sh`, `migrate-switch.sh`, `rotate-manual-leaf.sh`,
  `verify-migration.sh`, `k8s/clients-vault`, and every manual-CA branch in
  the rollover scripts. `verify-proxies.sh` absorbs the ESO checks from
  `verify-migration.sh`. The proposal keeps its migration section (the
  customer's real path) and adds an open question: do clients present a leaf
  or the CA certificate itself? Verified on a new cluster: `up.sh` exit 0,
  `verify-proxies.sh` passes (4 of 4 proxies, 0 failed probe calls), and
  `watch-renewals.sh 3` passes (every replica loaded 3 renewals 8 to 28 s
  after each ESO refresh, no restarts, 0 of 115 probe calls failed per
  namespace). `verify-proxies.sh` now waits up to 60 s for Prometheus's first
  scrape of new Pods; without it, the first run right after `up.sh` saw 2 of
  4 proxies.
- 2026-11-15: `verify-proxies.sh` failed after migration with "gauge NotAfter
  != mounted certificate": with a 1-minute refresh the Secret changes faster
  than kubelet sync plus the proxy's poll, so proxies trail it by 59 to 157 s
  (sampled). It now allows up to 200 s of reload lag for the ESO Secret.
- 2026-11-15: First `demo-rollover.sh` stopped at preflight, changing
  nothing: the leaf-remaining check required more than 300 s while
  `LEAF_TTL` is 300 s, a leftover from the 30-minute default. It now defaults
  to one ESO refresh interval. Re-run passed in 186 s (add trust 18 s,
  verify 111 s, retire 39 s): `ca-20261115T054439Z` replaced by
  `ca-20261115T055218Z`, the Namespace trusts only the new CA, the old
  issuer refuses to sign, 0 of 92 probe calls failed per namespace across
  the rollover, no proxy restarts, no reload failures. Still to run: the
  failure-injection walkthrough and `rollback.sh`.
- 2026-11-15: Failure-injection walkthrough passed. Steps 0 to 4, then
  `inject-eso-failure.sh callers`, `force-refresh.sh workers` (now takes
  namespaces), workers moved in about 2 minutes, `06-retire.sh` refused and
  named only the two callers proxies and the callers Secret, removing
  nothing. Restore, `05-verify.sh` passed in about 1 minute, `06-retire.sh`
  completed; 0 of 122 probe calls failed per namespace. Bugs found and
  fixed on the way: `02-create-issuer.sh` reused the previous rollover's
  issuer on any second rollover and recorded state before its own check
  refused; `apply-settings.sh` expected exactly 4 alert rules; preflight
  did not wait for Prometheus's first scrape. Alert severities now follow
  impact (page: calls failing, no proxy serving; ticket: deadlines) and a
  page was added for "no proxy serving in a cluster". Renewal-stalled can
  go pending on a healthy but slow-reloading workers proxy: the demo's
  threshold (L - 2R = 180 s) does not allow for reload lag (up to about
  150 s). Accepted as a demo artifact (decision: keep 5-minute leaves and
  the current threshold); with production lifetimes the lag is negligible.
- 2026-11-15 (user): the proposal lacked a comparison with not using the
  proxy (redeploying and monitoring every Worker and Caller across clusters
  and regions, and deciding where the rollover runs), and should encourage
  evaluating the proxy with clear links. Conforming change: `spec.html`
  gains "With or without Temporal Proxy" with an evaluation callout and
  links, two Evolution rows (payload encryption, inbound authorization),
  and proxy references. TLS hot reload and its metrics shipped in Temporal
  Proxy v1.1.0, and v1.2.0 contains the demo's pinned commit, so the "hot
  reload not in a tagged release" risk became a Public Preview risk. Open: the demo and `demo-spec.html` still describe building
  from the pinned commit; moving them to v1.2.0 needs a rebuild and re-run.
- 2026-11-15 (user): make the outage case obvious in the README, alert both
  when a leaf is expiring and when it is past due, and alert on failed calls.
  Live run (callers delivery broken, left broken): renewal-stalled pending
  at 1m51s and firing at 2m54s; leaf expired at about 4m28s and every probe
  call failed with `tls: expired certificate` while the proxy Pods stayed
  Running. Neither page fired: `tmprl_proxy_router_forwarding_errors_total`
  stayed 0, and the proxy answered the calls `Unavailable` in
  `tmprl_proxy_server_requests_total`. Design change (proposal Alerts
  updated first): new page **Loaded leaf expired**; **Calls failing at the
  proxy** now fires on over 5% `Unavailable|Internal|Unknown` responses for
  1 minute instead of forwarding errors. Applied live: leaf expired fired on
  the first evaluation, calls failing fired 71 s later. After restore, with
  no proxy restarts: leaf expired cleared in about 2 minutes, every probe
  call succeeded in about 2.5 minutes, calls failing cleared in about 4.5
  minutes. Demo README gains
  "4. Simulate an outage" with the measured timeline.

## Roadmap

1. Proxy path on Vault from `up.sh`: Vault PKI, ESO, first issuer and
   trust, CLI probes, metrics, dashboard, observed renewals.
2. (Merged into 1 when the manual-CA stage was removed.)
3. Rollover scripts, failure injection, annotations.
4. Sample Workflow replacing the probes.
5. Runbook text from actual script output.
