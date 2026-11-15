# Demo: Temporal Proxy + Vault PKI + ESO Certificate Rotation

Proposal: [`spec.html`](../../../specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html).
Demo spec: [`demo-spec.html`](../../../specs/temporal-credential-operations/temporal-proxy-vault-eso/demo-spec.html).

Rotates the client certificate authority (CA) a Temporal Cloud Namespace
trusts, with no restarts and no failed calls. Vault PKI signs short-lived
client leaves, External Secrets Operator (ESO) delivers them, and Temporal
Proxy presents them to Temporal Cloud and reloads them as they change.

The demo tells the story in three parts:

1. **Today:** the proxies present a CA generated outside Vault.
2. **Move to Vault:** a one-time migration to leaves signed by Vault PKI.
3. **Rotate:** a complete CA rollover, plus what happens when something breaks.

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
2. **A demo Temporal Cloud Namespace** dedicated to this demo. The scripts add
   and remove its accepted client CAs, including removing your bootstrap CA,
   so no other client may depend on it. It must use mTLS authentication with
   your bootstrap CA accepted.
3. **A bootstrap client CA:** a CA certificate (PEM) and its private key,
   generated outside Vault. It stands in for the manually generated CA the demo
   migrates away from. `*.pem` and `*.key` files are gitignored.
4. **A Temporal Cloud Operations API key** for a user or service account with
   an account-level role (Global Admin). Scripts use it from your shell only;
   it is never placed in the cluster.
5. **Configure.** From the repository root:

   ```bash
   cp .env.example .env.local
   ```

   Set `TEMPORAL_CLOUD_OPS_API_KEY`, `TEMPORAL_DEMO_NAMESPACE_ADDRESS`
   (`<namespace>.<account>.tmprl.cloud:7233`), `TEMPORAL_DEMO_CA_CERT_FILE`,
   and `TEMPORAL_DEMO_CA_KEY_FILE`. Verify the CA file is a CA certificate:

   ```bash
   openssl x509 -in <your-ca.pem> -noout -text | grep 'CA:TRUE'
   ```

   Expected: a `CA:TRUE` line.

Run the commands below from this directory. Every script ends with its own
checks and exits non-zero if one fails.

## 1. Today: proxies with the manual CA

```bash
./scripts/build-proxy-image.sh
./scripts/up.sh
./scripts/verify-proxies.sh
```

Builds Temporal Proxy from a pinned commit (hot reload is not yet in a tagged
release), creates the cluster, and deploys the proxies with the bootstrap CA.
If the Namespace no longer accepts the bootstrap CA (a previous run retired
it), `up.sh` adds it back. Verify: `build-proxy-image.sh` ends with
`Built temporal-proxy:<commit>`, and `verify-proxies.sh` ends with
`Proxy path verified.`

Open the dashboard and tail the probes in another terminal:

```bash
./scripts/observe.sh
```

Grafana: <http://localhost:3000/d/temporal-proxy-rotation>.
Prometheus (including Alerts): <http://localhost:9090>.

## 2. Move to Vault (once per cluster)

```bash
./scripts/vault-eso-up.sh
./scripts/rollover/01-snapshot.sh
./scripts/rollover/02-create-issuer.sh
./scripts/rollover/03-add-trust.sh
./scripts/migrate-switch.sh
./scripts/verify-migration.sh
./scripts/rollover/05-verify.sh
./scripts/rollover/06-retire.sh
```

| Script | Does | Verify: ends with |
|---|---|---|
| `vault-eso-up.sh` | Installs Vault and ESO; PKI mount, issue-only policy, one Kubernetes auth role per client namespace | a `PASS` login line per namespace |
| `01-snapshot.sh` | Records the accepted CAs and the proxies' current CA in ConfigMap `vault/rotation-state` | `PASS the proxies' current CA is accepted` |
| `02-create-issuer.sh` | Creates Vault issuer `ca-<timestamp>` (key never leaves Vault) and the signing role | a `PASS` line about the role |
| `03-add-trust.sh` | **Temporal Cloud:** adds the Vault CA, then proves a leaf from it is accepted | `PASS a test leaf from <issuer> is accepted` |
| `migrate-switch.sh` | Applies ESO, then repoints the proxies at its Secret (the only rolling restart) | both `rollout status` lines succeed |
| `verify-migration.sh` | Every proxy on a Vault leaf, gate passing, probes clean | `Migration verified.` |
| `05-verify.sh` | Evaluates the retirement gate | `Gate passed.` |
| `06-retire.sh` | **Temporal Cloud:** removes the bootstrap CA, watches traffic | `Rollover complete: <namespace> trusts <fingerprint>` |

From here on, leaves renew with nothing to do. To watch it:

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
issuer, add trust, switch, verify, retire. About 6 minutes with the default
settings: about 2 for Temporal Cloud to accept the new CA, about 3 for routine
renewal to move every proxy to it, and about 1 to retire the old CA.
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

Run steps 0 to 4, then break one namespace's leaf delivery and try to retire:

```bash
./scripts/inject-eso-failure.sh callers
./scripts/rollover/06-retire.sh
```

Verify: `PASS callers: ExternalSecret Ready=False`, then `06-retire.sh` exits
non-zero with `FAIL gate: pre-switch leaf on callers/...` and removes nothing.
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
| `./scripts/rotate-manual-leaf.sh` | Hot reload while still on the manual CA (before part 2) | `PASS hot reload` |
| `./scripts/force-refresh.sh` | ESO reissuing every leaf now | a `PASS` line per namespace with old and new serial |
| `./scripts/check-issuer-expiry.sh` | The issuer is outside its rollover lead time | `PASS issuer <name> expires <date>` |

## Tear down

```bash
./scripts/down.sh
```

Deletes only the demo cluster. Temporal Cloud keeps whatever CAs the last
script left accepted; the next `up.sh` adds the bootstrap CA back if needed.
