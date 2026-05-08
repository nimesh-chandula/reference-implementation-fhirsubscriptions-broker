# Docker bring-up

One command boots the broker plus all four peer services (FHIR server, Client
Registry, Audit, and the WebSubHub stack at
`~/Documents/websubhub-deployment/docker/kafka/`).

## Layout

```
deployment/
├── docker-compose.yml          # FHIR + CR + Audit + Broker
├── start.sh                    # boots WebSubHub + this stack
├── fhir-server/Dockerfile      # clones wso2/open-healthcare-prebuilt-services
├── cr/
│   ├── Dockerfile              # clones wso2/reference-implementation-openhie@main
│   └── Config.toml             # H2 override + intra-network audit URL
├── audit/Dockerfile            # clones wso2/open-healthcare-prebuilt-services
└── broker/
    ├── Dockerfile              # builds this repo's fhirsubscriptions-broker/
    └── Config.toml.example     # copy to Config.toml and fill Asgardeo creds
```

## Ports (host)

| Service     | URL                                              |
| ----------- | ------------------------------------------------ |
| FHIR server | <http://localhost:9090/fhir/r4/metadata>         |
| CR          | <http://localhost:9093/fhir/r4/metadata>         |
| Audit       | <http://localhost:9098>                          |
| Broker      | <http://localhost:9091/broker/registry>          |
| WebSubHub   | <https://dev.websubhub.com:8443/hub>             |

Inside the `broker-net` compose network, services reach each other by name:
`http://fhir-server:9090`, `http://cr:9093`, `http://audit:9093`,
`http://broker:9091`. The broker reaches WebSubHub via `host-gateway` (see
`extra_hosts` in `docker-compose.yml`).

## First-run setup

1. **Hosts file** — add to your OS hosts file (required by WebSubHub's NGINX):

   ```
   127.0.0.1 dev.websubhub.com
   ```

   On Windows: `C:\Windows\System32\drivers\etc\hosts` (admin).
   On macOS/Linux: `/etc/hosts` (sudo).

2. **Broker config** — copy and fill in Asgardeo credentials:

   ```bash
   cp deployment/broker/Config.toml.example deployment/broker/Config.toml
   # edit Asgardeo URLs, client id/secret, etc.
   ```

3. **Bring up the stack:**

   ```bash
   cd deployment
   ./start.sh
   ```

   Builds are slow the first time (Ballerina pulls Central deps for each
   service); subsequent runs hit the docker layer cache.

## Environment variables

| Var            | Default                                                  | Purpose                                                         |
| -------------- | -------------------------------------------------------- | --------------------------------------------------------------- |
| `WEBSUBHUB_DIR`| `~/Documents/websubhub-deployment/docker/kafka`           | Path to the WebSubHub Kafka compose stack.                      |

Build-time overrides (per-service `GIT_REF` build args) are set in
`docker-compose.yml`; pin a different ref by editing that file.

## Verifying

```bash
curl http://localhost:9090/fhir/r4/metadata           # FHIR CapabilityStatement
curl http://localhost:9093/fhir/r4/metadata           # CR
curl http://localhost:9091/broker/registry            # broker → []
curl -k https://dev.websubhub.com:8443/hub            # WebSubHub reachable

docker compose -f deployment/docker-compose.yml exec broker \
  wget -qO- http://cr:9093/fhir/r4/metadata           # intra-network DNS
```

## Stopping

```bash
# Broker stack
docker compose -f deployment/docker-compose.yml down

# WebSubHub stack
docker compose -f "$WEBSUBHUB_DIR/docker-compose.yml" down
```

Add `-v` to either to wipe volumes.

## Gotchas

- **WebSubHub stack is untouched.** `start.sh` shells out to its existing
  `docker-compose.yml` — we never modify that repo. Cross-stack reach is via
  `extra_hosts: host-gateway`, not a shared network.
- **Two Ballerina distros.** The CR uses `2201.13.1`; FHIR/audit/broker use
  `2201.12.11`. Each Dockerfile pins its own base image.
- **Asgardeo placeholders.** The broker fetches Asgardeo JWKS at startup and
  will fail unless you've filled real values into `broker/Config.toml`.
- **`allowHttpCallbacks = true`** in the broker config is local-dev only —
  flip to `false` for production.
- **`disableHubTlsVerification = true`** bypasses the WebSubHub self-signed
  cert; same caveat.
- **Port 9093** is shared by CR and Audit *internally*. That's safe because
  containers have separate network namespaces. They're exposed on different
  host ports (9093 and 9098).
