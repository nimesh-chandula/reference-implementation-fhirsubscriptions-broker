# resources/

This directory holds runtime certificates referenced from `Config.toml`. The
actual `.key` / `.crt` files are gitignored — generate your own and drop them
here for local development.

| File | Purpose | Referenced by |
|------|---------|---------------|
| `server.key`         | TLS private key for the local HTTPS listener (optional) | `tlsKeyPath` |
| `server.crt`         | TLS certificate for the local HTTPS listener (optional) | `tlsCertPath` |

On Choreo the gateway terminates TLS upstream, so these can stay unset.
