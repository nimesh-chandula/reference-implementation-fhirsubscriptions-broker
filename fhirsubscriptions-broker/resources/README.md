# resources/

This directory holds runtime certificates and signing keys referenced from
`Config.toml`. The actual `.key` / `.crt` files are gitignored — generate
your own and drop them here for local development.

| File | Purpose | Referenced by |
|------|---------|---------------|
| `broker-private.key` | RSA-2048 private key — broker signs subscription tokens | `subscriptionTokenPrivateKeyPath` |
| `broker-public.crt`  | Matching X.509 cert — published in token JWT header | `subscriptionTokenCertPath`        |
| `server.key`         | TLS private key for the local HTTPS listener (optional) | `tlsKeyPath` |
| `server.crt`         | TLS certificate for the local HTTPS listener (optional) | `tlsCertPath` |

Generation commands and the production (Choreo file-secret) layout are
documented in the top-level [README](../../README.md).
