# Temporal Credential Operations

Runbooks and runnable demos for operating a Temporal Cloud application's
credentials in production. Each topic is specified first, then delivered as a
runbook an operations team can follow and a demo that shows the runbook
working.

## Current topic: rotating the client CA Temporal Cloud trusts

Temporal Cloud authenticates clients with mTLS: each Namespace trusts a set
of client certificate authorities (CAs), and every Worker and Caller presents
a client certificate (a leaf) signed by one of them. Rotating that CA by hand
means generating new material, pasting it into secret stores, restarting
applications, and guessing when the old CA is safe to remove.

This repository shows a different arrangement:

- **Temporal Proxy** in each cluster is the only process holding a Temporal
  Cloud client certificate. Applications connect to the proxy and carry no
  Temporal Cloud credentials.
- **Vault PKI** holds the CA key and signs short-lived leaves.
- **External Secrets Operator (ESO)** delivers each new leaf to the proxy,
  which reloads it without a restart.
- **A scripted rollover** adds the new CA, switches Vault to it, waits until
  every proxy reports a new-CA leaf, and only then removes the old CA. The
  proxies' metrics, not operator judgment, decide when that is safe.

| | |
|---|---|
| Proposal | [`specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html`](specs/temporal-credential-operations/temporal-proxy-vault-eso/spec.html) (open in a browser): the approach, alternatives, open questions, and evolution, for evaluation |
| Demo spec | [`demo-spec.html`](specs/temporal-credential-operations/temporal-proxy-vault-eso/demo-spec.html): how the demo is built and what it proves |
| Progress | [`PROGRESS.md`](specs/temporal-credential-operations/temporal-proxy-vault-eso/PROGRESS.md) |
| Demo | [`demos/credentials-management/temporal-proxy-vault-eso/`](demos/credentials-management/temporal-proxy-vault-eso/README.md): a local k3d cluster with Vault, ESO, Temporal Proxy, Prometheus, and Grafana, against a real Temporal Cloud Namespace |
| Runbook | Not written yet: it will be written from the demo scripts' actual output |

## Try the demo

You need Docker, a Temporal Cloud Namespace dedicated to the demo, a CA
certificate and key it accepts, and a Temporal Cloud Operations API key.

```bash
cp .env.example .env.local    # then fill it in
```

Then follow the [demo README](demos/credentials-management/temporal-proxy-vault-eso/README.md).

## Repository layout

```text
specs/       Specifications: the approach and its trade-offs (HTML), plus a
             progress log per topic. See specs/README.md for the workflow.
demos/       Runnable demos, one directory per topic.
scripts/     Repository tooling (asdf plugin setup for .tool-versions).
.env.example Local settings template; copy to .env.local (gitignored).
```

Secrets, certificates, and keys never go in the repository: `.env.local`,
`*.pem`, and `*.key` are gitignored.
