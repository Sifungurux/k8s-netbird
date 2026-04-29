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

1. Log in to https://keycloak.netbird.kirk-pedersen.dk/admin
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
| Root URL | `https://app.netbird.kirk-pedersen.dk` |
| Home URL | `https://app.netbird.kirk-pedersen.dk` |
| Valid redirect URIs | `https://app.netbird.kirk-pedersen.dk/*` |
| Valid post logout redirect URIs | `https://app.netbird.kirk-pedersen.dk/*` |
| Web origins | `https://app.netbird.kirk-pedersen.dk` |

Click **Save**

---

## Step 3 – Configure Token Settings

Navigate to: **Clients** → `netbird` → **Settings** tab → scroll to **Access settings**

Then go to the **Advanced** tab → **Advanced settings** section:

| Field | Value |
|---|---|
| Access Token Lifespan | 5 minutes (default is fine) |
| Device Authorization Grant Lifetime | 600 seconds (10 min, gives users time to auth) |

### Ensure `email` scope is included

Navigate to: **Clients** → `netbird` → **Client scopes** tab

You should see `email` and `profile` in the **Assigned default client scopes** list.
If not, click **Add client scope** and add both `email` and `profile` as **Default**.

NetBird requires the following claims in the ID token:
- `sub` (subject/user ID) — always present
- `email` — from `email` scope
- `name` — from `profile` scope

---

## Step 4 – Verify OIDC Discovery Endpoint

The discovery URL NetBird will use:

```
https://keycloak.netbird.kirk-pedersen.dk/realms/netbird/.well-known/openid-configuration
```

Verify it returns JSON:
```bash
curl -s https://keycloak.netbird.kirk-pedersen.dk/realms/netbird/.well-known/openid-configuration | python3 -m json.tool | head -20
```

Key fields to confirm:
- `issuer`: `https://keycloak.netbird.kirk-pedersen.dk/realms/netbird`
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

Update `netbird-values.yaml` with the OIDC settings:

```yaml
management:
  oidcConfigEndpoint: "https://keycloak.netbird.kirk-pedersen.dk/realms/netbird/.well-known/openid-configuration"

dashboard:
  authClientId: "netbird"
  authAuthority: "https://keycloak.netbird.kirk-pedersen.dk/realms/netbird"
  useAuth0: false
```

Apply the update:
```bash
helm upgrade netbird netbird/netbird \
  -n netbird \
  -f netbird-values.yaml
```

---

## Step 7 – Validate the Integration

1. Open https://app.netbird.kirk-pedersen.dk
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
| Dashboard redirect loops | `proxy: edge` not set in Keycloak | Ensure Keycloak Helm value `proxy: edge` |
| `invalid_client` error | Wrong Client ID | Confirm `authClientId: netbird` matches Keycloak client ID |
| Device auth code never works | Device Authorization Grant not enabled | Enable it on the client Capability Config tab |
| Token missing email claim | `email` scope not assigned | Add `email` scope as default on the client |
| CORS errors in browser | Web Origins not set | Add `https://app.netbird.kirk-pedersen.dk` to Web Origins |
| Keycloak unreachable from NetBird pod | DNS issue in cluster | Verify `keycloak.keycloak.svc.cluster.local` resolves, or use external URL |
