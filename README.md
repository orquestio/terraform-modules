# Orquestio Terraform Modules

Shared Terraform modules for Orquestio infrastructure and per-tenant instance provisioning.

## Modules

- **`openclaw/`** — Per-tenant OpenClaw instance (EC2 + EIP + BYO custom domain via certbot/nginx).

## Consumers

- `orquestio/infrastructure` — base infra apply, uploads scripts tar.gz to SSM.
- `orquestio/orchestrator` — per-tenant Terraform workspace (one state per instance).

Both consumers include this repo as a git submodule. Pin by tag for production.

## Versioning

Semver. Tag releases (`v0.1.0`, `v0.2.0`, ...). Consumers track a specific tag — never `main` in prod.
