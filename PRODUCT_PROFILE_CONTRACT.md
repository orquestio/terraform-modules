# Product profile contract — the shared `product_instance` engine

> Status: **DRAFT for review** (2026-07-18). This is the contract the shared
> per-tenant provisioning engine consumes. It exists to add products to Orquestio
> **without forking the module/pipeline/scripts** — OpenClaw's battle-tested code
> IS the engine; each product is a *profile* over it.

## Principle

The current `modules/openclaw/` is ~90% product-agnostic already (EBS/nvme mount,
EIP, dual Cloudflare DNS, AWS Backup, nginx/TLS+certbot skeleton, SSM script-bundle
fetch, `docker run` lifecycle, control-plane scripts). We **promote that code in
place** to a single `modules/product_instance/` engine parameterized by a
**profile**, and drive per-product differences (auth, ports, config format, run
command) through the profile — never through a fork.

Two hard guarantees so this **does not degrade OpenClaw** (which is in production):

1. **Behavior-preserving for OpenClaw.** The `openclaw` profile below reproduces
   today's rendered values byte-for-byte. Generalization is a no-op for OpenClaw.
2. **No live instance is re-provisioned.** `user_data` runs only on first boot;
   existing OpenClaw EC2s keep running untouched. The engine affects **new
   provisions only**, which are gated by (a) a render-diff vs today's module and
   (b) the existing `tests/unit/test_openclaw_*.py` golden-master invariants.

## Profile schema

A profile is a static object selected per product. Fields marked `⟵ blueprint`
already arrive through the fixed `terraform.py` interface (do not duplicate); the
rest are the engine's new parameters.

```yaml
profile:
  key: string                      # identity, e.g. "openclaw" | "hermes"

  container:
    name: string                   # docker --name, e.g. "openclaw-current"
    image: ⟵ blueprint.docker_image
    run_command: [string]          # argv after the image; {PORT} substituted
    ports:
      primary: int                 # human-facing UI port nginx fronts; == blueprint.container_port
      health: int                  # port that serves health_endpoint (may differ from primary)
      alt: int | null              # rolling-upgrade alternate host port (openclaw: 18790)
      extra: [int]                 # any other ports to publish on loopback
    health_endpoint: ⟵ blueprint.health_check_endpoint   # e.g. "/healthz"
    readiness_log_regex: string|"" # gate restart/upgrade on this log line ("" = skip)
    env_static: {string: string}   # HOME/TERM/TZ etc.
    reserved_env: [string]         # infra-owned names apply_env_vars must never set
    health_start_period: string    # docker --health-start-period
    extra_bind_mounts: [string]    # product quirks (host:container)

  data:
    mount_host: string             # host mount point of the EBS data volume
    volume_mounts: [string]        # host:container mounts (may reference {mount})
    config_dir: string             # dir holding the product config file
    config_file: string            # filename (relative to config_dir)
    config_format: enum(json|env|yaml)
    env_file: string               # --env-file path for user env vars
    config_seed: string            # path to the seed template rendered on first boot

  auth:
    strategy: enum(cookie-wall|oidc|basic)   # see "Auth strategies"

  scripts:
    dir: string                    # where control-plane scripts land, e.g. /opt/openclaw/scripts
    ssm_bundles: [string]          # /orquestio/prod/<NAME> params user_data fetches
    optional: [string]             # scripts only present for some strategies (e.g. rotate_password)

  password:
    read_command: ⟵ blueprint.password_read_command   # "reveal password" wizard
    mirror_secrets_manager: bool   # cookie-wall mirrors gateway pw to SM; oidc may not
```

## Reference profile — `openclaw` (reproduces today, verified against the module)

```yaml
key: openclaw
container:
  name: openclaw-current
  run_command: ["node","openclaw.mjs","gateway","--bind","lan","--port","{PORT}"]
  ports: { primary: 18789, health: 18789, alt: 18790, extra: [] }
  health_endpoint: /healthz
  readiness_log_regex: "http server listening"
  env_static: { HOME: /home/node, TERM: xterm-256color, TZ: UTC }
  reserved_env: [OPENCLAW_GATEWAY_PASSWORD, OPENCLAW_GATEWAY_TOKEN]
  health_start_period: 1200s
  extra_bind_mounts:
    - "/var/lib/openclaw/plugin-runtime-deps:/home/node/.openclaw/plugin-runtime-deps"  # issue #73647 cache-loop workaround
data:
  mount_host: /mnt/efs             # legacy name; ext4-on-EBS-gp3 behind it (see main.tf)
  volume_mounts:
    - "{mount}/config:/home/node/.openclaw"
    - "{mount}/workspace:/home/node/.openclaw/workspace"
  config_dir: /mnt/efs/config
  config_file: openclaw.json
  config_format: json
  env_file: /mnt/efs/config/container.env
  config_seed: seeds/openclaw.json.tmpl
auth:
  strategy: cookie-wall
scripts:
  dir: /opt/openclaw/scripts
  ssm_bundles: [OPENCLAW_SCRIPTS_B64, OPENCLAW_SEC_SCRIPTS_B64, OPENCLAW_BYO_SCRIPTS_B64, OPENCLAW_AI_SCRIPTS_B64]
  optional: [rotate_password.sh, restore_gateway_auth.sh, login.html]   # cookie-wall only
password:
  read_command: <existing blueprint value>
  mirror_secrets_manager: true
```

## Reference profile — `hermes` (the second consumer)

```yaml
key: hermes
container:
  name: hermes-current
  run_command: ["gateway","run"]                 # confirm exact argv on the arm64 image
  ports: { primary: 9119, health: 8642, alt: null, extra: [8642] }   # dashboard 9119, API+/health 8642
  health_endpoint: /health
  readiness_log_regex: ""                          # confirm a readiness line exists; else skip
  env_static: { HERMES_DASHBOARD: "1", HERMES_DASHBOARD_PORT: "9119", TZ: UTC }
  reserved_env: [HERMES_DASHBOARD_OIDC_ISSUER, HERMES_DASHBOARD_OIDC_CLIENT_ID, HERMES_DASHBOARD_BASIC_AUTH_PASSWORD]
  health_start_period: 300s
  extra_bind_mounts: []                            # no plugin-runtime-deps quirk
data:
  mount_host: /mnt/efs
  volume_mounts:
    - "{mount}/data:/opt/data"
  config_dir: /mnt/efs/data
  config_file: .env                                # + config.yaml
  config_format: env
  env_file: /mnt/efs/data/container.env
  config_seed: seeds/hermes.env.tmpl
auth:
  strategy: oidc
scripts:
  dir: /opt/hermes/scripts
  ssm_bundles: [HERMES_SCRIPTS_B64, HERMES_BYO_SCRIPTS_B64, HERMES_AI_SCRIPTS_B64]
  optional: []
password:
  read_command: <basic-auth break-glass read>
  mirror_secrets_manager: true
```

Items still to confirm on the real arm64 image (tracked, not invented): exact
`gateway run` argv, the `/health` path, and whether a readiness log line exists.

## Auth strategies — the main extension point

The engine's nginx + config-seed + env wiring branch on `auth.strategy`:

| strategy | nginx | in-container | provisioning hook |
|---|---|---|---|
| `cookie-wall` | SHA-256 cookie map + `login.html` + `?token=` rewrite + `/orquestio-logout` | token-mode config; `reserved_env` gateway pw/token; SM mirror | none |
| `oidc` | plain TLS reverse proxy to `primary`; `/health`→`health` port | `.env` OIDC issuer+client_id; basic-auth break-glass | **per-instance OIDC app in Prysm:ID/Zitadel** (create on provision, delete on destroy) |
| `basic` | nginx `auth_basic` OR native basic-auth env | basic-auth creds from `access_password` | none |

`cookie-wall` keeps OpenClaw's UX exactly. `oidc` gives Hermes native Prysm:ID
without the cookie hack. No lossy one-size-fits-all — each product keeps its UX.

## Wiring — how the profile reaches the module (fixed `terraform.py`)

`terraform.py:_prepare_workspace` copies **one** module dir and passes a **fixed**
tfvar set. So:

- Static profiles live **inside** the engine: `product_instance/profiles/<key>.json`,
  selected by a single new tfvar `profile`.
- `terraform.py` change is minimal + additive + backward-compatible: add
  `profile` to the generated `main.tf` var + module call + `terraform.tfvars.json`
  **only when the blueprint carries a non-null `profile`**. A new nullable
  blueprint column `profile TEXT` drives it. OpenClaw's row stays
  `terraform_module='modules/openclaw'`, `profile=NULL` → generated `main.tf`
  unchanged → old module untouched. Hermes:
  `terraform_module='modules/product_instance'`, `profile='hermes'`.
- Per-instance secrets that can't be static (OIDC `client_id`) keep flowing via
  the per-instance SSM param `/orquestio/prod/instances/{id}/*`, read in
  `user_data` — exactly as already designed. The profile only holds static shape.

Transition, zero prod risk:
1. Land `product_instance/` (engine) + `profiles/openclaw.json` + `profiles/hermes.json`.
2. Add the `profile` column + the gated `terraform.py` change.
3. Point the **Hermes** blueprint at `product_instance` (greenfield — OpenClaw untouched).
4. Prove equivalence, then flip the **OpenClaw** blueprint to
   `product_instance`+`profile=openclaw` in a later, separately-tested step.

## Behavior-preservation gate (render-diff)

Before OpenClaw is flipped: render `product_instance` with `profile=openclaw` and
diff the produced `user_data`, `docker run` invocation, nginx config, and
`openclaw.json` seed against today's `modules/openclaw/` output for a fixed set of
inputs. Must be equivalent (modulo intentional, documented normalizations). The
existing golden-master tests ride along: `test_openclaw_scripts_invariants`,
`test_openclaw_config_schema`, `test_openclaw_pin_coherence`,
`test_user_data_fetches_all_ssm_params`, `test_openclaw_auth_proxy_invariants`.

## What stays product-specific (correctly not shared)

- The config **seed template** (`openclaw.json` vs `hermes .env`/`config.yaml`).
- The `configure_ai_models` **mapping** (writes JSON vs YAML/env) — one script,
  branches on `config_format`.
- `cookie-wall`-only scripts (`rotate_password`, `restore_gateway_auth`, `login.html`).
- The OpenClaw `plugin-runtime-deps` bind-mount quirk (an `extra_bind_mounts` entry,
  absent for Hermes).

## Next step after this contract is agreed

Build `modules/product_instance/` by moving `modules/openclaw/`'s logic in and
replacing its hardcoded product values with `var.profile` lookups; add the two
profiles; wire the gated `terraform.py` change; run the render-diff. Hermes then
onboards as `profile=hermes` with the auth=`oidc` branch + per-instance Zitadel hook.
