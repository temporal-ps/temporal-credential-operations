# Demo: Temporal Proxy + Vault PKI + ESO Certificate Rotation

Spec: [`specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html`](../../../specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html)

Status: milestone 3 (CA rollover scripts, failure injection, rollback, alerts,
and timing settings). Milestones 1 and 2 (proxy path, Vault PKI, External
Secrets Operator (ESO), migration from the manual CA) are verified.

## What it runs

One k3d cluster (`tco-proxy-vault-eso`) with:

- `workers` and `callers` namespaces, each with a Temporal Proxy Deployment
  (two replicas) and a CLI probe that calls the Namespace through
  `temporal-proxy.<namespace>.svc.cluster.local:7233` every two seconds. The
  probe has no Temporal Cloud credentials; the proxy authenticates with mTLS.
- `observability`: Prometheus scraping every proxy replica, and Grafana with
  the **Temporal Proxy: Certificate Rotation** dashboard.
- `vault` (milestone 2): Vault in dev mode with a PKI mount `pki-temporal` and
  Kubernetes auth. Demo only: in-memory, HTTP, root token `root`, not exposed
  outside the cluster.
- `external-secrets` (milestone 2): ESO. In each client namespace a
  `VaultDynamicSecret` generator and an `ExternalSecret` write a new 30-minute
  leaf into Secret `temporal-cloud-leaf` every 10 minutes.

## Before you start

1. **Tools.** Docker, `openssl`, `jq`, `tcld`, and the Temporal CLI, plus
   `k3d`, `kubectl`, and `helm` at the versions pinned in the repository
   `.tool-versions`. With asdf, run `./scripts/setup-asdf-plugins.sh` then
   `asdf install` from the repository root. No local Vault CLI is needed:
   scripts run it inside the Vault Pod.
2. **A demo Temporal Cloud Namespace.** Use a Namespace dedicated to this demo.
   The scripts add and remove its accepted client CAs, including removing the
   bootstrap CA when they retire it, so no other client may depend on it. It
   must use mTLS authentication with your bootstrap CA accepted.
3. **A bootstrap client CA.** A CA certificate (PEM) and its private key,
   generated outside Vault. This stands in for the manually generated CA the
   demo migrates away from. Keep both files out of version control (`*.pem` and
   `*.key` are gitignored).
4. **A Temporal Cloud Operations API key** for a user or service account with
   an account-level role (Global Admin). Scripts use it from your shell only to
   read and change the Namespace's accepted client CAs; it is never placed in
   the cluster.
5. **Configure.** From the repository root:

   ```bash
   cp .env.example .env.local
   ```

   Set `TEMPORAL_CLOUD_OPS_API_KEY`, `TEMPORAL_DEMO_NAMESPACE_ADDRESS`
   (`<namespace>.<account>.tmprl.cloud:7233`), `TEMPORAL_DEMO_CA_CERT_FILE`,
   and `TEMPORAL_DEMO_CA_KEY_FILE` (absolute, or relative to the repository
   root).

   Verify the CA file is a CA certificate:

   ```bash
   openssl x509 -in <your-ca.pem> -noout -text | grep 'CA:TRUE'
   ```

   Expected: a `CA:TRUE` line. The Namespace's accepted client CAs in Temporal
   Cloud must include a CA with the same subject; otherwise Temporal Cloud
   rejects the handshake and the proxy exits at startup.

## Run

### Milestone 1: proxy path with the manual CA

```bash
./scripts/build-proxy-image.sh
```

Builds `temporal-proxy:64fae49` from source (hot reload is not yet in a tagged
release). Set `TEMPORAL_PROXY_SRC` to use a local checkout instead of cloning.
Verify: the script ends with `Built temporal-proxy:64fae49`.

```bash
./scripts/up.sh
```

Creates the cluster and deploys everything. Idempotent. Verify: every
`rollout status` line reports success.

```bash
./scripts/verify-m1.sh
```

Checks proxy readiness, successful probe calls with no failures in the last
minute, one leaf series per proxy replica in Prometheus matching the mounted
certificate, and zero TLS reload failures. Exits non-zero on the first failed
check.

```bash
./scripts/rotate-manual-leaf.sh
```

Signs a two-day client leaf with the bootstrap CA, replaces the Secret, and
waits until every replica reports the new leaf with no restart. Verify: ends
with `PASS hot reload`.

### Milestone 2: Vault PKI, ESO, and migration

```bash
./scripts/vault-eso-up.sh
```

Installs Vault and ESO from pinned Helm charts and configures the PKI mount,
the issue-only policy, and one Kubernetes auth role per client namespace.
Changes nothing in the proxies or Temporal Cloud. Verify: ends with a `PASS`
line per namespace showing a login with policies
`default,temporal-client-issue`.

```bash
./scripts/rollover/01-snapshot.sh
```

Records the accepted CA fingerprints, the Namespace resource version, the
proxies' current CA (the manual CA on the first run), and the expected proxy
count in ConfigMap `vault/rotation-state`. Read only against Temporal Cloud.
Verify: ends with `PASS the proxies' current CA is accepted by the Namespace`.

```bash
./scripts/rollover/02-create-issuer.sh
```

Creates Vault issuer `ca-<UTC timestamp>` with an internal key and exports its
public certificate to `.state/` (gitignored). On the first run it also creates
the `temporal-client` role pointing at it. Verify: ends with a `PASS` line
about the role.

```bash
./scripts/rollover/03-add-trust.sh
```

**Changes Temporal Cloud:** adds the new CA to the Namespace's accepted client
CAs (additive; removes nothing; fails on a concurrent change). Then completes a
call with a 5-minute test leaf from the new issuer, retrying while the change
propagates. Verify: ends with `PASS a test leaf from <issuer> is accepted`.

```bash
./scripts/migrate-switch.sh
```

Applies the ESO resources, waits until each `temporal-cloud-leaf` Secret holds
a leaf from the new issuer, then repoints the proxies at it (one rolling
restart). Verify: both `rollout status` lines report success.

```bash
./scripts/verify-m2.sh
```

Checks that every proxy mounts the ESO Secret, the leaves chain to the new
issuer, the gate passes (every Ready proxy on a post-switch leaf, no reload
failures), and probes are succeeding. Verify: ends with
`Milestone 2 migration verified`.

```bash
./scripts/watch-renewals.sh 3
```

Waits for three automatic renewals on every proxy (about 4 minutes with the
default settings) and logs
how long each reload took after its ESO refresh. Verify: ends with
`PASS 3 renewals on every proxy replica with no restarts and no errors.`

```bash
./scripts/force-refresh.sh
```

Optional: makes ESO reissue both leaves now by changing the `force-sync`
annotation. Verify: a `PASS` line per namespace with the old and new serial.

### Milestone 3: CA rollover

Finish the migration first, if this cluster has not retired the bootstrap CA:

```bash
./scripts/rollover/05-verify.sh
./scripts/rollover/06-retire.sh
```

`05-verify.sh` evaluates the retirement gate until it passes. Verify: ends with
`Gate passed`. `06-retire.sh` **changes Temporal Cloud:** it re-checks the gate,
removes the old CA (here the bootstrap CA) from the Namespace, and watches
probe traffic. Verify: ends with `Rollover complete: <namespace> trusts <fingerprint>`.

Then run a whole rollover in one command while watching Grafana:

```bash
./scripts/demo-rollover.sh
```

Runs steps 0 to 6 and prints how long each took. With the default settings it
takes about 6 minutes: about 2 minutes for Temporal Cloud to accept the new
CA, about 3 for routine renewal to move every proxy to it, and about 1 to
retire the old CA. Add `--force-refresh` for an emergency rollover that makes
ESO reissue every leaf immediately after the switch. **Changes Temporal Cloud**
(adds one CA, removes one) and Vault. Verify: ends with
`Rollover complete in <seconds>s` and a timing per step.

The same steps one at a time, each ending with its own `PASS` lines:

| Step | Script | Changes |
|---|---|---|
| 0 | `rollover/00-preflight.sh` | Nothing (health check) |
| 1 | `rollover/01-snapshot.sh` | ConfigMap `vault/rotation-state` |
| 2 | `rollover/02-create-issuer.sh` | Vault: new issuer |
| 3 | `rollover/03-add-trust.sh` | Temporal Cloud: adds the new CA |
| 4 | `rollover/04-switch.sh` | Vault: role signs with the new issuer |
| 5 | `rollover/05-verify.sh [--force-refresh]` | Nothing (waits for the gate) |
| 6 | `rollover/06-retire.sh` | Temporal Cloud: removes the old CA; Vault: old issuer stops signing |

Show the gate catching a broken delivery chain. After step 4, break one
namespace's ESO delivery:

```bash
./scripts/inject-eso-failure.sh callers
./scripts/rollover/06-retire.sh
```

Verify: `inject-eso-failure.sh` ends with `PASS callers: ExternalSecret
Ready=False`, and `06-retire.sh` exits non-zero with `FAIL gate: pre-switch
leaf on callers/...` lines and removes nothing. Repair it within the leaf
lifetime (5 minutes by default), or the callers proxies' leaves expire and
their calls fail:

```bash
./scripts/inject-eso-failure.sh callers --restore
./scripts/rollover/05-verify.sh
./scripts/rollover/06-retire.sh
```

Verify: `PASS callers: ExternalSecret Ready and a new leaf delivered`, then
`Gate passed`, then `Rollover complete`.

Roll back instead of retiring:

```bash
./scripts/rollover/rollback.sh
```

Steps back one stage per run and never removes the old CA: after the switch it
points the role back at the old issuer (phase `trusted`); run again to remove
the new CA from the Namespace (phase `rolled-back`). Verify: `PASS role ...
signs with <old issuer>`, then `PASS accepted CAs equal the Snapshot`.

Standing checks: the Prometheus alerts (renewal stalled, reload failed, proxy
missing, forwarding errors) appear under Alerts at <http://localhost:9090>
while `observe.sh` runs, and

```bash
./scripts/check-issuer-expiry.sh
```

fails when the current issuer expires within `ISSUER_LEAD_DAYS`. Verify: `PASS
issuer <name> expires <date>`.

### Timing settings

`demo-settings.env` holds the demo's timing values: ESO refresh interval (1m),
leaf lifetime (5m), the gate's clock-skew allowance, issuer lifetime and lead
time, and the probe watch after retirement. Override any of them in
`.env.local`, then apply them to the running demo:

```bash
./scripts/apply-settings.sh
```

Patches the Vault role and each `ExternalSecret`, and re-renders the alert
rules (restarting only Prometheus). Leaves already issued keep their old
lifetime. Verify: a `PASS` line for the role, each `ExternalSecret`, and the
alert rules.

The leaf lifetime is also how long the demo survives ESO or Vault being
unavailable, including your machine sleeping. After a longer sleep, run
`./scripts/force-refresh.sh` before continuing; `00-preflight.sh` refuses to
start a rollover while any proxy's leaf is about to expire.

### Observe and tear down

```bash
./scripts/observe.sh
```

Port-forwards Grafana to <http://localhost:3000/d/temporal-proxy-rotation> and
Prometheus to <http://localhost:9090>, and tails the probes.

```bash
./scripts/down.sh
```

Deletes only the demo cluster. It does not touch Temporal Cloud: CAs added by
`03-add-trust.sh` stay in the Namespace's accepted list until removed.
