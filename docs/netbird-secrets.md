# NetBird Secrets & Shared Keys

## Overview

NetBird uses two types of shared secrets in the local PoC setup:

| Secret | Where used | Purpose |
|---|---|---|
| `DataStoreEncryptionKey` | management.json | Encrypts the SQLite datastore at rest |
| `Relay.Secret` / `NB_AUTH_SECRET` | management.json + relay env | Relay authentication (must match) |

---

## Relay Secret (`NB_AUTH_SECRET`)

### What it does

The relay secret is a pre-shared key (PSK) shared between the management server and the
relay server. It is used for time-based credential generation:

```
1. Peer connects to management and requests relay access
2. Management generates short-lived HMAC credentials using the secret
3. Peer presents those credentials to the relay
4. Relay verifies the credentials using the same secret
5. If valid → peer is allowed to relay traffic through the relay server
```

The secret never leaves the cluster — peers only receive short-lived derived credentials,
not the secret itself. This is the same pattern used by TURN servers (RFC 8489).

### How to generate

```bash
openssl rand -base64 24
```

The output must be set identically in two places:

**`netbird-values-local.yaml` — management.json:**
```json
"Relay": {
  "Addresses": ["rels://api.netbird.192.168.50.57.nip.io:443/relay"],
  "CredentialsTTL": "24h",
  "Secret": "<your-generated-secret>"
}
```

**`netbird-values-local.yaml` — relay env:**
```yaml
relay:
  env:
    NB_AUTH_SECRET: "<same-secret>"
```

If these don't match, peers will be issued credentials that the relay rejects —
they will connect to the relay TCP endpoint but immediately be dropped.

### PoC vs Production

| Environment | Approach |
|---|---|
| PoC (local k3d) | Secret in values file (acceptable — cluster is not exposed) |
| Production | Create a Kubernetes Secret, reference via `envFromSecret` in relay and mount into management configmap |

**Production example:**
```bash
kubectl create secret generic netbird-relay-secret \
  -n netbird \
  --from-literal=NB_AUTH_SECRET=$(openssl rand -base64 24)
```

Then in values:
```yaml
relay:
  envFromSecret:
    NB_AUTH_SECRET: netbird-relay-secret/NB_AUTH_SECRET
```

And use the same secret value when generating `management.json`.

---

## DataStore Encryption Key

Encrypts the NetBird SQLite database at rest. Generated once at deploy time:

```bash
openssl rand -base64 32
```

Set in `management.json`:
```json
"DataStoreEncryptionKey": "<your-generated-key>"
```

> **Important:** If you lose this key the database cannot be decrypted.
> For production, store it in a secrets manager (1Password, Vault, etc.).
> For the PoC, the value in `netbird-values-local.yaml` is the only copy — don't lose it.

---

## Rotating Secrets

### Relay secret rotation
1. Generate a new secret: `openssl rand -base64 24`
2. Update both `Relay.Secret` in management.json and `NB_AUTH_SECRET` in relay env simultaneously
3. Redeploy: `make netbird-deploy`
4. Connected peers will re-authenticate on next relay connection attempt

### DataStore key rotation
Not supported without re-encrypting the database. For the PoC this is not needed.
