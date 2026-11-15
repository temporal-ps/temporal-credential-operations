# Demo: Temporal Proxy + Vault PKI + ESO Certificate Rotation

Proposal: [`spec.html`](../../../specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html).
Demo spec: [`demo-spec.html`](../../../specs/temporal-credential-operations/temporal-proxy-vault-eso/demo-spec.html).

Rotates the client certificate authority (CA) a Temporal Cloud Namespace
trusts, with no restarts and no failed calls. Vault PKI signs short-lived
client leaves, External Secrets Operator (ESO) delivers them, and Temporal
Proxy presents them to Temporal Cloud and reloads them as they change.

The demo starts in the proposed state, with Vault issuing every leaf, and
shows two things:

1. **Renewal:** leaves renew every minute with no restarts and no Temporal
   Cloud change.
2. **Rotate:** a complete CA rollover, plus what happens when something breaks.

## What it runs

One local k3d cluster (`tco-proxy-vault-eso`):

| Namespace | Runs |
|---|---|
| `workers`, `callers` | Temporal Proxy (two replicas) and a CLI probe calling the Namespace through `temporal-proxy.<namespace>.svc.cluster.local:7233` every two seconds. The probe has no Temporal Cloud credentials. |
| `vault` | Vault in dev mode with PKI mount `pki-temporal` and Kubernetes auth. Demo only: in memory, HTTP, root token `root`, not exposed outside the cluster. |
| `external-secrets` | ESO. In each client namespace it writes a new leaf into Secret `temporal-cloud-leaf` every refresh interval. |
| `observability` | Prometheus with the certificate alerts, and Grafana with the **Temporal Proxy: Certificate Rotation** dashboard. |

## Before you start

1. **Tools.** Docker, `openssl`, `jq`, `tcld`, and the Temporal CLI, plus
   `k3d`, `kubectl`, and `helm` at the versions pinned in the repository
   `.tool-versions`. With asdf, run `./scripts/setup-asdf-plugins.sh` then
   `asdf install` from the repository root. No local Vault CLI is needed.
2. **A demo Temporal Cloud Namespace** dedicated to this demo, using mTLS
   authentication. The scripts own its accepted client CAs: `up.sh` on a new
   cluster replaces them with the cluster's first Vault issuer, and each
   rollover retires its old CA. No other client may depend on it.
3. **A Temporal Cloud Operations API key** for a user or service account with
   an account-level role (Global Admin). Scripts use it from your shell only;
   it is never placed in the cluster.
4. **Configure.** From the repository root:

   ```bash
   cp .env.example .env.local
   ```

   Set `TEMPORAL_CLOUD_OPS_API_KEY` and `TEMPORAL_DEMO_NAMESPACE_ADDRESS`
   (`<namespace>.<account>.tmprl.cloud:7233`).

Run the commands below from this directory. Every script ends with its own
checks and exits non-zero if one fails.

## 1. Bring it up on Vault

```bash
./scripts/build-proxy-image.sh
./scripts/up.sh
./scripts/verify-proxies.sh
```

Builds Temporal Proxy from a pinned commit (hot reload is not yet in a tagged
release), creates the cluster, and installs Vault and ESO. `bootstrap-issuer.sh`
(run by `up.sh`) creates the first Vault issuer and, on a new cluster,
**replaces the Namespace's accepted client CAs** with it, then proves a leaf
from it is accepted. The proxies start on ESO-delivered leaves.

Verify: `build-proxy-image.sh` ends with `Built temporal-proxy:<commit>`;
`up.sh` prints `PASS a test leaf from <issuer> is accepted by <namespace>`;
`verify-proxies.sh` ends with `Proxy path verified.` It reports how far each
proxy's loaded leaf trails the mounted one: up to about 200 seconds is normal
reload lag, because the Secret changes every minute.

Re-running `up.sh` on an existing cluster changes nothing in Temporal Cloud.
To start from scratch, run `./scripts/down.sh` first.

Open the dashboard and tail the probes in another terminal:

```bash
./scripts/observe.sh
```

Grafana: <http://localhost:3000/d/temporal-proxy-rotation>.
Prometheus (including Alerts): <http://localhost:9090>.

## 2. Watch renewal

Leaves renew with nothing to do:

```bash
./scripts/watch-renewals.sh 3
```

Verify: ends with `PASS 3 renewals on every proxy replica with no restarts and
no errors.` (about 4 minutes with the default settings).

## 3. Rotate the CA

```bash
./scripts/demo-rollover.sh
```

Runs the whole rollover while you watch Grafana: preflight, snapshot, new
issuer, add trust, switch, verify, retire. About 3 to 6 minutes with the
default settings, most of it in two waits: Temporal Cloud accepting the new CA
(add trust), and routine renewal moving every proxy to it (verify). One run
took 186 s: 18 s to add trust, 111 s to verify, 39 s to retire.
**Changes Temporal Cloud** (adds one CA, removes one) and Vault. Verify: ends
with `Rollover complete in <seconds>s` and the time per step.

Add `--force-refresh` for an emergency rollover: ESO reissues every leaf right
after the switch instead of at its next refresh.

The same steps one at a time:

| Step | Script | Changes |
|---|---|---|
| 0 | `rollover/00-preflight.sh` | Nothing (health check) |
| 1 | `rollover/01-snapshot.sh` | ConfigMap `vault/rotation-state` |
| 2 | `rollover/02-create-issuer.sh` | Vault: new issuer |
| 3 | `rollover/03-add-trust.sh` | Temporal Cloud: adds the new CA |
| 4 | `rollover/04-switch.sh` | Vault: the role signs with the new issuer |
| 5 | `rollover/05-verify.sh [--force-refresh]` | Nothing (waits for the gate) |
| 6 | `rollover/06-retire.sh` | Temporal Cloud: removes the old CA; Vault: the old issuer stops signing |

### When delivery breaks

Run steps 0 to 4, then break the callers namespace's leaf delivery, move the
workers proxies to the new issuer right away, and try to retire:

```bash
./scripts/inject-eso-failure.sh callers
./scripts/force-refresh.sh workers
```

Wait about two minutes, until Grafana's **Leaf NotAfter** panel steps up for
the workers proxies only, then try to retire:

```bash
./scripts/rollover/06-retire.sh
```

Verify: `PASS callers: ExternalSecret Ready=False`, then `06-retire.sh` exits
non-zero with `FAIL gate: pre-switch leaf on callers/...` lines (and none for
workers) and removes nothing. Probe calls keep succeeding: the callers proxies
still hold a valid leaf, and the **Leaf renewal stalled** alert (ticket) goes
pending, then firing.

Repair it within the leaf lifetime (5 minutes by default), or the callers
proxies' leaves expire and their calls fail:

```bash
./scripts/inject-eso-failure.sh callers --restore
./scripts/rollover/05-verify.sh
./scripts/rollover/06-retire.sh
```

Verify: `PASS callers: ExternalSecret Ready and a new leaf delivered`, then
`Gate passed.`, then `Rollover complete`.

### Roll back

```bash
./scripts/rollover/rollback.sh
```

Steps back one stage per run and never removes the old CA. After the switch it
points the role back at the old issuer; run it again to remove the new CA from
the Namespace. Verify: `PASS role ... signs with <old issuer>`, then
`PASS accepted CAs equal the Snapshot`.

## Timing settings

`demo-settings.env` holds the timing values: ESO refresh interval (1m), leaf
lifetime (5m), the gate's clock-skew allowance, issuer lifetime and lead time,
and the probe watch after retirement. Edit it (or override in `.env.local`),
then apply to the running demo, with no cluster restart:

```bash
./scripts/apply-settings.sh
```

Verify: a `PASS` line for the Vault role, each `ExternalSecret`, and the alert
rules. Leaves already issued keep their old lifetime.

The leaf lifetime is also how long the demo survives ESO or Vault being
unavailable, including your machine sleeping. After a longer sleep, run
`./scripts/force-refresh.sh` before continuing; `00-preflight.sh` refuses to
start a rollover while a proxy's leaf is about to expire.

## Other checks

| Command | Shows | Verify |
|---|---|---|
| `./scripts/force-refresh.sh` | ESO reissuing every leaf now | a `PASS` line per namespace with old and new serial |
| `./scripts/check-issuer-expiry.sh` | The issuer is outside its rollover lead time | `PASS issuer <name> expires <date>` |

## Tear down

```bash
./scripts/down.sh
```

Deletes only the demo cluster. Temporal Cloud keeps whatever CAs the last
script left accepted; the next `up.sh` replaces them with the new cluster's
first issuer.
