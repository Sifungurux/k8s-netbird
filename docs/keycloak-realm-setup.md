# Keycloak – NetBird Realm & OIDC Client Setup
# Keycloak 22+ (Quarkus-based)
# Realm: netbird

## Overview

This guide covers:
1. Creating the `netbird` realm
2. Creating the `netbird` OIDC client
3. Configuring token claims (so NetBird gets user info it needs)
4. Creating test users
5. Wiring it all back into NetBird

---

## Step 1 – Create the `netbird` Realm

1. Log in to https://keycloak.netbird.192.168.50.57.nip.io/admin
2. Click the realm dropdown (top-left, shows "master") → **Create realm**
3. Set:
   - **Realm name:** `netbird`
   - **Enabled:** ON
4. Click **Create**

> All remaining steps are done inside the `netbird` realm.
> Make sure the realm selector shows `netbird` before proceeding.

---

## Step 2 – Create the NetBird OIDC Client

Navigate to: **Clients** → **Create client**

### General Settings tab
| Field | Value |
|---|---|
| Client type | OpenID Connect |
| Client ID | `netbird` |
| Name | NetBird |
| Description | NetBird zero-trust network |

Click **Next**

### Capability Config tab
| Field | Value |
|---|---|
| Client authentication | OFF (public client) |
| Authorization | OFF |
| Standard flow | ON |
| Direct access grants | OFF |
| **Device Authorization Grant** | **ON** ← critical for CLI peer enrollment |
| Implicit flow | OFF |
| Service accounts roles | OFF |

Click **Next**

### Login Settings tab
| Field | Value |
|---|---|
| Root URL | `https://app.netbird.192.168.50.57.nip.io` |
| Home URL | `https://app.netbird.192.168.50.57.nip.io` |
| Valid redirect URIs | `https://app.netbird.192.168.50.57.nip.io/*` and `http://localhost:53000` |
| Valid post logout redirect URIs | `https://app.netbird.192.168.50.57.nip.io/*` |
| Web origins | `https://app.netbird.192.168.50.57.nip.io` |

> **Note:** `http://localhost:53000` is required for CLI peer enrollment (`netbird up`).
> The netbird CLI uses the PKCE flow which opens a browser and listens on this local port for
> the OAuth callback. Without it, Keycloak rejects the auth request with "Invalid parameter: redirect_uri".

Click **Save**

---

## Step 3 – Configure Token Claims

### 3a – Add Audience Mapper (required)

This is the most commonly missed step. By default, Keycloak does **not** include the
client ID in the access token's `aud` (audience) claim for public clients. NetBird
management validates the `aud` claim on every API request — if it's missing, all API
calls return 401 even though login succeeds.

**Why:** The `aud` claim tells the resource server (NetBird management) that the token
was intended for it. Without it, management rejects the token as not addressed to it,
even if the signature and issuer are valid. This is standard OAuth2 audience validation.

Navigate to: **Clients** → `netbird` → **Client scopes** tab → click `netbird-dedicated`
→ **Add mapper** → **By configuration** → **Audience**

| Field | Value |
|---|---|
| Name | `netbird-audience` |
| Included Client Audience | `netbird` |
| Add to access token | **ON** |
| Add to ID token | OFF |

Click **Save**.

After this, every access token issued to the `netbird` client will contain `"aud": ["netbird"]`
and management will accept it.

### 3b – Ensure `email` and `profile` scopes are included

Navigate to: **Clients** → `netbird` → **Client scopes** tab

You should see `email` and `profile` in the **Assigned default client scopes** list.
If not, click **Add client scope** and add both as **Default**.

NetBird requires the following claims:
- `sub` (subject/user ID) — always present
- `email` — from `email` scope
- `name` — from `profile` scope

### 3c – Advanced token settings (optional)

Navigate to: **Clients** → `netbird` → **Advanced** tab → **Advanced settings**:

| Field | Value |
|---|---|
| Access Token Lifespan | 5 minutes (default is fine) |
| Device Authorization Grant Lifetime | 600 seconds (10 min — gives users time to auth on CLI) |

---

## Step 4 – Verify OIDC Discovery Endpoint

The discovery URL NetBird will use:

```
https://keycloak.netbird.192.168.50.57.nip.io/realms/netbird/.well-known/openid-configuration
```

Verify it returns JSON:
```bash
curl -sk --cacert /tmp/netbird-ca.crt \
  https://keycloak.netbird.192.168.50.57.nip.io/realms/netbird/.well-known/openid-configuration \
  | python3 -m json.tool | head -20
```

Key fields to confirm:
- `issuer`: `https://keycloak.netbird.192.168.50.57.nip.io/realms/netbird`
- `device_authorization_endpoint`: must be present
- `token_endpoint`: must be present

---

## Step 5 – Create Test Users

Navigate to: **Users** → **Create new user**

| Field | Value |
|---|---|
| Username | testuser1 |
| Email | testuser1@example.com |
| Email verified | ON |
| First name | Test |
| Last name | User |

Click **Create**, then go to the **Credentials** tab:
- Click **Set password**
- Set a password, toggle **Temporary** OFF
- Click **Save**

Repeat for any additional test users.

---

## Step 6 – Wire Keycloak into NetBird

The OIDC settings are already configured in `config/netbird-values-local.yaml` —
no manual update needed for the local PoC. This step applies when deploying to a
different environment with a different Keycloak URL.

---

## Step 7 – Validate the Integration

1. Open https://app.netbird.192.168.50.57.nip.io
2. You should be redirected to Keycloak login
3. Log in with a test user
4. You should land on the NetBird dashboard

For peer enrollment (device auth flow):
```bash
# On a Debian peer
netbird up --management-url https://api.netbird.example.com
# A URL + code will be printed — open it in a browser, log in via Keycloak
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dashboard redirect loops | `proxy: edge` not set in Keycloak | Ensure Keycloak Helm value `proxyHeaders: xforwarded` |
| `invalid_client` error | Wrong Client ID | Confirm `AUTH_CLIENT_ID: netbird` matches Keycloak client ID |
| Device auth code never works | Device Authorization Grant not enabled | Enable it on the client Capability Config tab |
| `401` on all API calls after login | `aud` claim missing from token | Add Audience mapper to `netbird-dedicated` scope (Step 3a) |
| `Invalid parameter: redirect_uri` on CLI enrollment | `http://localhost:53000` not in Valid Redirect URIs | Add `http://localhost:53000` to client Valid Redirect URIs |
| `Invalid parameter: redirect_uri` on dashboard login | Redirect URI uses wrong domain (old placeholder) | Update Valid Redirect URIs and Web Origins to use your actual domain |
| "Unauthenticated" error after successful Keycloak login | Web Origins wrong — browser blocked from exchanging auth code for token | Update Web Origins to `https://app.netbird.192.168.50.57.nip.io` (Step 2 Login Settings) |
| Token missing email claim | `email` scope not assigned | Add `email` scope as default on the client |
| Keycloak unreachable from NetBird pod | DNS issue in cluster | Verify nip.io resolves correctly inside cluster; check `SSL_CERT_FILE` env on management pod |
| Browser can't reach services after `netbird up` | NetBird intercepts DNS for its own domain | Add service hostnames to `/etc/hosts` — hosts file takes precedence over split-DNS |
