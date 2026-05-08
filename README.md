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
5. [Broker configuration](#5-broker-configuration)
6. [Build and run](#6-build-and-run)
7. [Deploying to Choreo](#7-deploying-to-choreo)
8. [API surface](#8-api-surface)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. System overview

Source systems POST FHIR notification bundles to the broker, which resolves
patient identity through the Client Registry (MPI), persists clinical
resources to a FHIR R4 server, and fans out `SubscriptionStatus` notifications
through a WebSub hub to subscribed client callback URLs. Patient-facing apps
authenticate through Asgardeo and exchange ID tokens for broker-scoped access
tokens. Every operation emits a FHIR `AuditEvent` to a peer
audit service.

The broker depends on four external services and two identity-provider applications:

| Service | Role |
|---------|------|
| FHIR R4 server | Persists `Subscription`, `Group`, `Communication`, and clinical resources |
| WebSub hub | Pub/sub fan-out of notifications to client callback URLs |
| Client Registry (CR) | FHIR-backed Master Patient Index — resolves source-system patient IDs to broker-scoped IDs |
| Audit service | FHIR `AuditEvent` sink for security/compliance logging |
| Asgardeo App 1 | OIDC IdP standing in for an IAL2 identity verification service — issues ID tokens to the patient-facing app for the broker's token-exchange (RFC 8693) flow |
| Asgardeo App 2 | OAuth 2.0 token issuer for API clients — mints the access tokens that authorize calls to `/fhir/Subscription` and notification-retrieval endpoints |

These peer services are deployed separately. Sections 4.1 – 4.5 cover the
recommended choices and how to wire each one into the broker config.

---

## 2. Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Ballerina](https://ballerina.io/downloads/) | 2201.12.11 (Swan Lake Update 12) | Build & run the broker |
| Java | 21+ | Ballerina runtime |
| Asgardeo tenant | free tier works | Identity provider |

---

## 3. Repository layout

```
reference-implementation-fhirsubscriptions-broker/   (this repo)
├── README.md                          # you are here
├── LICENSE
├── deployment/                        # Docker bring-up for the full stack
│   ├── docker-compose.yml
│   ├── start.sh
│   ├── README.md
│   ├── fhir-server/Dockerfile
│   ├── cr/{Dockerfile, Config.toml}
│   ├── audit/Dockerfile
│   └── broker/{Dockerfile, Config.toml.example}
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
    │   ├── tokens/                    # Token exchange via Asgardeo
    │   └── websub/                    # hub registration & publishing
    ├── openapi/broker-api.yaml        # OpenAPI 3.0 spec
    ├── resources/                     # local-dev TLS keys (gitignored)
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
clinical resources tagged per client) here. We use the WSO2 Open Healthcare
FHIR server.

```bash
git clone https://github.com/wso2/open-healthcare-prebuilt-services
cd open-healthcare-prebuilt-services/miscellaneous/fhir-server
bal run
```

Default URL: `http://localhost:9090/fhir/r4`

Set the resulting URL into `wso2healthcare.broker.fhir.fhirServerUrl`.

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
- `wso2healthcare.broker.mpi.crServiceUrl` — base URL ending in `/fhir/r4`
- `wso2healthcare.broker.mpi.crAuthToken` — bearer token if the CR is protected

### 4.4 Audit service

A standalone Ballerina service that persists FHIR `AuditEvent` resources is
expected at `auditServiceUrl`. Any HTTP service that accepts a FHIR
`AuditEvent` POST will work.

Default URL when run locally: `http://localhost:9098`.

Set `wso2healthcare.broker.audit.auditServiceUrl` to its base URL, and toggle
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

---

## 5. Broker configuration

All runtime config lives in `Config.toml`. From the `fhirsubscriptions-broker/`
directory:

```bash
cp Config.toml.example Config.toml
```

`Config.toml` is gitignored — never commit real secrets.

### Configuration hierarchy

Submodule keys live under `[wso2healthcare.broker.<module>]`. Top-level keys
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
entry under `[wso2healthcare.broker.auth.clientRegistry.<name>]`:

```toml
[wso2healthcare.broker.auth.clientRegistry.my-app]
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
[wso2healthcare.broker.fhir.systemUriRegistry]
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
5. **TLS**: leave `tlsCertPath` and `tlsKeyPath` unset — Choreo's gateway
   terminates TLS upstream.
6. **Endpoint**: expose the `/broker` and `/fhir` base paths.
7. After first deploy, copy the issued URL into:
   - `tokenAudience`
   - `brokerBaseUrl`
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
| GET | `/broker/subscriptions/{patientId}` | List callback URLs for a patient |
| GET | `/broker/clients/{patientId}` | List client IDs subscribed to a patient |

---

## 9. Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `error: configurable variable ... is not set` | Missing key in `Config.toml`, or the section header is wrong (must be `[wso2healthcare.broker.<module>]`) |
| `Connection refused` to FHIR server | FHIR server not running, or `fhirServerUrl` host/port is wrong |
| `401 Unauthorized` on `/fhir/Subscription` | Bearer token issuer/JWKS doesn't match `subscriptionAuthzIssuer`/`subscriptionAuthzJwksUrl` |
| `401` from token exchange | Asgardeo App 1 client ID/secret wrong, or wrong tenant in URLs |
| Notifications POST 200 but no subscriber callback | WebSub hub URL unreachable, or callback URL is HTTP while `allowHttpCallbacks = false` |
| MPI returns "patient not found" repeatedly | `crServiceUrl` wrong, or source system URI not in `systemUriRegistry` |
| Audit warnings on every request | `auditEnabled = true` but audit service unreachable — set `false` or fix the URL |
| Browser CORS errors | Frontend origin not in `allowedCorsOrigins` |

---

## License

See [LICENSE](LICENSE) at the repository root.
