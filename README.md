# FHIR Subscriptions Broker — Reference Implementation

Reference implementation of a brokered model for delivering FHIR encounter
notifications across CMS-Aligned Networks, meeting the July 4, 2026 CMS
Interoperability Framework requirement.

A FHIR R4 notification broker for use inside a Qualified Health Information
Network (QHIN). It ingests FHIR notification bundles from source systems
(hospitals, HIEs, labs), unifies patient identity through a Master Patient
Index, and delivers filtered notifications to subscribed client applications
via a WebSub hub.

The broker is the central component of a multi-service ecosystem. Running it
end-to-end requires several peer services — this README walks through setting
up each of them.

- **Reference spec:** [CMS FHIR Subscriptions Broker](https://github.com/jmandel/cms-fhir-subscriptions-broker/blob/main/index.md)
- **Implementation:** Ballerina package in [`fhirsubscriptions-broker/`](fhirsubscriptions-broker/)
- **OpenAPI:** [`fhirsubscriptions-broker/openapi/broker-api.yaml`](fhirsubscriptions-broker/openapi/broker-api.yaml)

---

## Table of Contents

1. [System overview](#1-system-overview)
2. [Prerequisites](#2-prerequisites)
3. [Repository layout](#3-repository-layout)
4. [Peer service setup](#4-peer-service-setup)
   - [FHIR R4 server](#41-fhir-r4-server)
   - [WebSub hub](#42-websub-hub)
   - [Client Registry / MPI](#43-client-registry--mpi)
   - [Audit service](#44-audit-service)
   - [Asgardeo (identity provider)](#45-asgardeo-identity-provider)
   - [Subscription token signing keys](#46-subscription-token-signing-keys)
5. [Broker configuration](#5-broker-configuration)
6. [Build and run](#6-build-and-run)
7. [Deploying to Choreo](#7-deploying-to-choreo)
8. [API surface](#8-api-surface)
9. [Verifying the deployment](#9-verifying-the-deployment)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. System overview

```
   Source HIEs / Hospitals                  Patient-facing app
            |                                       |
            | FHIR Bundle                  ID token / client assertion
            v                                       v
   +------------------+                  +----------------------+
   |  Notification    |                  |  /broker/auth/token  |
   |  /broker/        |                  |  (token exchange)    |
   |  notification    |                  +----------+-----------+
   +--------+---------+                             |
            |                                       |
            v                                       v
   +-------------------------------------------------------+
   |                  FHIR Notification Broker             |
   |                                                       |
   |  Identity   Subscriptions   Notification   Tokens     |
   |  resolve     manage         routing        issue      |
   +---+---------------+----------------+----------------+-+
       |               |                |                |
       v               v                v                v
   +--------+    +-----------+    +-----------+    +---------+
   |  CR/   |    |   FHIR    |    |  WebSub   |    | Audit   |
   |  MPI   |    |  server   |    |   Hub     |    | service |
   +--------+    +-----------+    +-----------+    +---------+
                                       |
                                       v
                                Subscriber callbacks
```

The broker depends on four external services and one identity provider:

| Service | Role |
|---------|------|
| FHIR R4 server | Persists `Subscription`, `Group`, `Communication`, and clinical resources |
| WebSub hub | Pub/sub fan-out of notifications to client callback URLs |
| Client Registry (CR) | FHIR-backed Master Patient Index — resolves source-system patient IDs to broker-scoped IDs |
| Audit service | FHIR `AuditEvent` sink for security/compliance logging |
| Asgardeo | OAuth 2.0 / OIDC identity provider — supplies ID tokens for token exchange and access tokens for client authorization |

These peer services are deployed separately. Sections 4.1 – 4.5 cover the
recommended choices and how to wire each one into the broker config.

---

## 2. Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Ballerina](https://ballerina.io/downloads/) | 2201.12.11 (Swan Lake Update 12) | Build & run the broker |
| Java | 21+ | Ballerina runtime |
| OpenSSL | any recent | Generate token-signing keys |
| `curl` / Postman | — | Smoke tests |
| Asgardeo tenant | free tier works | Identity provider |

---

## 3. Repository layout

```
reference-implementation-fhirsubscriptions-broker/   (this repo)
├── README.md                          # you are here
└── fhirsubscriptions-broker/          # Ballerina package
    ├── Ballerina.toml
    ├── Config.toml.example            # config template (copy to Config.toml)
    ├── Dependencies.toml
    ├── main.bal                       # /broker + /fhir HTTP services
    ├── notification_handler.bal       # FHIR bundle ingestion pipeline
    ├── fhir_subscription_handler.bal
    ├── notification_retrieval_handler.bal
    ├── registry_handler.bal           # client registry CRUD
    ├── modules/
    │   ├── audit/                     # AuditEvent emission to audit-service
    │   ├── auth/                      # JWT/JWKS validation, patient-level authz
    │   ├── common/                    # shared types, in-memory state
    │   ├── fhir/                      # FHIR client + Subscription/Group helpers
    │   ├── mpi/                       # CR/MPI client (resolve, $match, register)
    │   ├── tokens/                    # SMART permission tickets, RFC 8693 exchange
    │   └── websub/                    # hub registration & publishing
    ├── openapi/broker-api.yaml        # OpenAPI 3.0 spec
    ├── resources/                     # local-dev TLS + signing keys (gitignored)
    └── .choreo/component.yaml         # Choreo deployment manifest
```

> All `bal` commands and `Config.toml` paths in the rest of this README are
> resolved **relative to** the `fhirsubscriptions-broker/` directory.

---

## 4. Peer service setup

The broker can be exercised against any FHIR R4 server, any WebSub hub, and
any FHIR-based MPI. The defaults below target the WSO2 Healthcare Open Source
stack — substitute equivalents if you have them.

### 4.1 FHIR R4 server

The broker stores FHIR resources (Subscription, Group, Communication, plus
clinical resources tagged per client) here.

**Option A — WSO2 Open Healthcare FHIR Server**:

```bash
git clone https://github.com/wso2/open-healthcare-prebuilt-services
cd open-healthcare-prebuilt-services/fhir-server
bal run
```

Default URL: `http://localhost:9090/fhir/r4`

**Option B — HAPI FHIR JPA Server** (Docker):

```bash
docker run -p 8080:8080 hapiproject/hapi:latest
# URL: http://localhost:8080/fhir
```

Set the resulting URL into `nimesh_chandula.broker.fhir.fhirServerUrl`.

### 4.2 WebSub hub

The broker publishes notifications to a WebSub hub, which fans them out to
subscriber callback URLs.

**WSO2 Product-Integrator-WebSubHub**:

```bash
git clone https://github.com/wso2/product-integrator-websubhub
cd product-integrator-websubhub
./gradlew build
java -jar distribution/target/wso2websubhub-*.zip
```

Default URL: `http://localhost:9090/hub`

The broker registers topics on the hub when subscriptions are created and
publishes `SubscriptionStatus` notifications when matching events arrive.
Set the hub URL into `webSubHubUrl`.

### 4.3 Client Registry / MPI

The Client Registry holds the FHIR-backed Master Patient Index. It exposes:
- `GET /Patient?identifier={system}|{value}` — direct lookup
- `POST /Patient/$match` — demographic matching
- `POST /Patient` — register a new broker-scoped patient

Any FHIR R4 server with `$match` support can play this role.

Set:
- `nimesh_chandula.broker.mpi.crServiceUrl` — base URL ending in `/fhir/r4`
- `nimesh_chandula.broker.mpi.crAuthToken` — bearer token if the CR is protected

### 4.4 Audit service

A standalone Ballerina service that persists FHIR `AuditEvent` resources is
expected at `auditServiceUrl`. Any HTTP service that accepts a FHIR
`AuditEvent` POST will work.

Default URL when run locally: `http://localhost:9098`.

Set `nimesh_chandula.broker.audit.auditServiceUrl` to its base URL, and toggle
`auditEnabled = true` once it is reachable. Until then, leave `auditEnabled
= false` so failed audit posts don't show up as warnings.

### 4.5 Asgardeo (identity provider)

The broker uses **two** Asgardeo applications. Sign up at
[asgardeo.io](https://asgardeo.io) (free tier works) and create a tenant.

#### App 1 — Token Exchange

Used by the broker to exchange a patient's ID token (issued by Asgardeo at
login) for a broker-scoped access token (RFC 8693).

1. Asgardeo Console → Applications → New → **Standard-Based Application** → OIDC
2. Note the Client ID and Client Secret
3. Add scopes: `system/Subscription.crud`, `system/Patient.read` (or whatever
   set you wish to expose to patient-facing apps)
4. Configure as needed for your patient-facing app's redirect URIs

Map to broker config:
```
asgardeoTokenExchangeUrl       = "https://api.asgardeo.io/t/<tenant>/oauth2/token"
asgardeoTokenExchangeClientId  = "<App 1 client id>"
asgardeoTokenExchangeClientSecret = "<App 1 client secret>"   # via secret store
asgardeoJwksUrl                = "https://api.asgardeo.io/t/<tenant>/oauth2/jwks"
asgardeoIssuer                 = "https://api.asgardeo.io/t/<tenant>/oauth2/token"
asgardeoUserInfoUrl            = "https://api.asgardeo.io/t/<tenant>/oauth2/userinfo"
```

#### App 2 — Subscription Authorization

Used to authenticate API clients that hit `/fhir/Subscription` and the
notification-retrieval endpoints. Clients obtain access tokens from this app.

1. Asgardeo Console → Applications → New → **M2M Application** (or any app
   that issues access tokens with the scopes you need)
2. The broker validates incoming bearer tokens against this app's JWKS

Map to broker config:
```
subscriptionAuthzJwksUrl = "https://api.asgardeo.io/t/<tenant>/oauth2/jwks"
subscriptionAuthzIssuer  = "https://api.asgardeo.io/t/<tenant>/oauth2/token"
```

> Asgardeo stands in here for a production-grade IAL2 identity verification
> provider. The protocol (OIDC + RFC 8693) is unchanged if you swap it.

### 4.6 Subscription token signing keys

The broker mints its own signed JWTs (RS256) for clients after token exchange.
Generate the key pair once (run from inside `fhirsubscriptions-broker/`):

```bash
openssl genpkey -algorithm RSA \
  -out resources/broker-private.key -pkeyopt rsa_keygen_bits:2048

openssl req -new -x509 \
  -key resources/broker-private.key \
  -out resources/broker-public.crt \
  -days 3650 -subj "/CN=fhir-broker"
```

Map the paths into broker config:
```
subscriptionTokenPrivateKeyPath = "resources/broker-private.key"
subscriptionTokenCertPath       = "resources/broker-public.crt"
subscriptionTokenIssuer         = "https://<your-broker-host>"
```

In Choreo, upload both as **file secrets** and point the paths at
`/etc/choreo-secrets/broker-private.key` and `.../broker-public.crt`.

---

## 5. Broker configuration

All runtime config lives in `Config.toml`. From the `fhirsubscriptions-broker/`
directory:

```bash
cp Config.toml.example Config.toml
```

`Config.toml` is gitignored — never commit real secrets.

### Configuration hierarchy

Submodule keys live under `[nimesh_chandula.broker.<module>]`. Top-level keys
belong to `main.bal`. You can override any value with environment variables
via Ballerina's [configurable mechanism](https://ballerina.io/learn/by-example/configurable-variables/)
using `BAL_CONFIG_FILES` or `BAL_CONFIG_DATA`.

### Key configuration values

| Key | Section | Description |
|-----|---------|-------------|
| `brokerPort` | top-level | HTTP(S) port (default 9091) |
| `webSubHubUrl` | top-level | WebSub hub endpoint |
| `tlsCertPath`, `tlsKeyPath` | top-level | TLS cert/key (omit on Choreo) |
| `allowedCorsOrigins` | top-level | Browser origins allowed to call the broker |
| `auditServiceUrl`, `auditEnabled` | `audit` | Audit service base URL + toggle |
| `tokenAudience` | `auth` | Expected `aud` claim in client assertions |
| `subscriptionTokenPrivateKeyPath` | `auth` | RSA key path for signing |
| `subscriptionTokenCertPath` | `auth` | RSA cert path |
| `subscriptionTokenIssuer` | `auth` | `iss` claim broker stamps on its tokens |
| `requireNotificationAuthz` | `auth` | Enforce token validation on retrieval/proxy endpoints |
| `subscriptionAuthzJwksUrl` | `auth` | JWKS for client access tokens (Asgardeo App 2) |
| `subscriptionAuthzIssuer` | `auth` | Expected issuer for client access tokens |
| `authzEnabled` | `auth` | Patient-level access control on/off |
| `asgardeoJwksUrl` | `auth` | JWKS for ID tokens (Asgardeo App 1) |
| `asgardeoIssuer` | `auth` | Expected issuer for ID tokens |
| `asgardeoUserInfoUrl` | `auth` | UserInfo endpoint for demographic enrichment |
| `clientRegistry` | `auth` | Map of registered backend clients (see below) |
| `asgardeoTokenExchangeUrl` | `tokens` | Asgardeo App 1 token endpoint |
| `asgardeoTokenExchangeClientId/Secret` | `tokens` | Asgardeo App 1 credentials |
| `asgardeoTokenExchangeScopes` | `tokens` | Default scopes broker requests |
| `crServiceUrl` | `mpi` | Client Registry base URL |
| `crAuthToken` | `mpi` | Bearer token for CR (if any) |
| `fhirServerUrl` | `fhir` | FHIR R4 server base URL |
| `brokerBaseUrl` | `fhir` | Public URL used in resource references |
| `allowHttpCallbacks` | `fhir` | Allow non-TLS subscriber callbacks (false in prod) |

### Client registry entries

Each backend client app authenticating with a JWT client assertion needs an
entry under `[nimesh_chandula.broker.auth.clientRegistry.<name>]`:

```toml
[nimesh_chandula.broker.auth.clientRegistry.my-app]
issuer = "https://my-app.example.com"
jwksUri = "https://my-app.example.com/.well-known/jwks.json"
allowedScopes = [
  "system/Subscription.crud",
  "system/Patient.read",
  "system/Encounter.read",
]
```

Patient-facing apps using the Asgardeo token-exchange flow do **not** need an
entry here — they authenticate via Asgardeo, not a client assertion.

### System URI registry (optional)

Maps source-system FHIR `identifier.system` URIs to short MPI system IDs:

```toml
[nimesh_chandula.broker.fhir.systemUriRegistry]
"http://hospital-h1.org/patient-ids" = "H001"
"http://hospital-h2.org/patient-ids" = "H002"
```

---

## 6. Build and run

All commands below run from inside the `fhirsubscriptions-broker/` directory.

### Local build

```bash
cd fhirsubscriptions-broker
bal build
```

Produces `target/bin/broker.jar`.

### Local run

```bash
bal run
# or, against an explicit config file:
BAL_CONFIG_FILES=Config.toml bal run target/bin/broker.jar
```

### Bring-up order

For the first run, start services in this order so dependencies are reachable:

1. **FHIR server** (port 9090)
2. **WebSub hub** (port 9090 by default — change one of these ports)
3. **Client Registry / MPI**
4. **Audit service** (port 9098) — optional; otherwise set `auditEnabled = false`
5. **Broker** (port 9091)

### Health check

```bash
curl http://localhost:9091/broker/registry
# → list of registered clients (may be [])
```

---

## 7. Deploying to Choreo

The broker ships with [`fhirsubscriptions-broker/.choreo/component.yaml`](fhirsubscriptions-broker/.choreo/component.yaml)
pinning the `/broker` and `/fhir` base paths.

1. Push this repo to GitHub.
2. In Choreo, create a **Service** component pointing at the
   `fhirsubscriptions-broker/` directory.
3. Build with the Ballerina buildpack (autodetected).
4. **Configs and Secrets**: paste your `Config.toml` block, with secrets
   (Asgardeo client secret, CR auth token) attached as separate Choreo
   Secrets that the build references.
5. **File secrets**: upload `broker-private.key` and `broker-public.crt` to
   `/etc/choreo-secrets/`. Update the paths in config to match.
6. **TLS**: leave `tlsCertPath` and `tlsKeyPath` unset — Choreo's gateway
   terminates TLS upstream.
7. **Endpoint**: expose the `/broker` and `/fhir` base paths.
8. After first deploy, copy the issued URL into:
   - `tokenAudience`
   - `brokerBaseUrl`
   - `subscriptionTokenIssuer`
   - `allowedCorsOrigins`

Repeat the Choreo deployment process separately for the audit service, FHIR
server, and WebSub hub — wire each Choreo-issued URL into the broker config.

---

## 8. API surface

Full spec: [`fhirsubscriptions-broker/openapi/broker-api.yaml`](fhirsubscriptions-broker/openapi/broker-api.yaml).

### Notification ingestion (no auth — trusted intra-QHIN)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/broker/notification` | Receive a FHIR Bundle from a source system |

### Token endpoint

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/broker/auth/token` | SMART permission tickets, RFC 8693 token exchange, refresh tokens |

### FHIR Subscription (R4 + R5 `$events`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/fhir/Subscription` | Create or merge a FHIR Subscription |
| GET | `/fhir/Subscription/{id}/$events` | R5-style retrieval of historical notifications |

### Resource proxy (with patient-level authz)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/fhir/{resourceType}/{id}` | Authorized read-through to the FHIR server |

### Client registry administration

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/broker/registry` | List registered clients |
| POST | `/broker/registry/register` | Register a client dynamically |
| DELETE | `/broker/registry/{name}` | Remove a dynamically registered client |

### Manual subscribe / introspection

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/broker/subscribe` | Subscribe a callback URL to a topic (testing) |
| GET | `/broker/subscriptions/{patientId}` | List callback URLs for a patient |
| GET | `/broker/clients/{patientId}` | List client IDs subscribed to a patient |

---

## 9. Verifying the deployment

### Smoke test — register a client

```bash
curl -X POST http://localhost:9091/broker/registry/register \
  -H "Content-Type: application/json" \
  -d '{
        "name": "test-app",
        "issuer": "https://test-app.example.com",
        "jwksUri": "https://test-app.example.com/.well-known/jwks.json",
        "allowedScopes": ["system/Subscription.crud", "system/Patient.read"]
      }'
```

### Smoke test — POST a notification bundle

Drop a FHIR Bundle containing a `Patient` and one or more clinical resources
to `/broker/notification`. The response summarizes how many patients were
resolved and how many notifications fanned out.

### Smoke test — observe a fan-out

1. Create a Subscription via `POST /fhir/Subscription` (with a bearer token
   from Asgardeo App 2) pointing at any HTTP echo service as the callback.
2. POST a notification matching that patient.
3. Watch the echo service receive a `SubscriptionStatus` ping.

---

## 10. Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `error: configurable variable ... is not set` | Missing key in `Config.toml`, or the section header is wrong (must be `[nimesh_chandula.broker.<module>]`) |
| `Connection refused` to FHIR server | FHIR server not running, or `fhirServerUrl` host/port is wrong |
| `401 Unauthorized` on `/fhir/Subscription` | Bearer token issuer/JWKS doesn't match `subscriptionAuthzIssuer`/`subscriptionAuthzJwksUrl` |
| `401` from token exchange | Asgardeo App 1 client ID/secret wrong, or wrong tenant in URLs |
| Notifications POST 200 but no subscriber callback | WebSub hub URL unreachable, or callback URL is HTTP while `allowHttpCallbacks = false` |
| MPI returns "patient not found" repeatedly | `crServiceUrl` wrong, or source system URI not in `systemUriRegistry` |
| Audit warnings on every request | `auditEnabled = true` but audit service unreachable — set `false` or fix the URL |
| Browser CORS errors | Frontend origin not in `allowedCorsOrigins` |

For deeper diagnosis enable verbose logging and inspect:

```bash
bal run -- --b7a.log.level=DEBUG
```

---

## License

See [LICENSE](LICENSE) at the repository root.
