# Product profile contract v2 — the shared `product_instance` engine

> Status: **v2, revised after two Fable subagent reviews** (2026-07-18). v1 was
> GO_WITH_CHANGES: the direction (generalize OpenClaw in place) survived, but v1
> made three load-bearing false claims. v2 fixes all blockers and records the
> auth decision. This is the design of record; the render/plan gate suite (below)
> is the executable enforcement.

## Principle (unchanged)

`modules/openclaw/` is ~90% product-agnostic. We **promote it in place** to a
single `modules/product_instance/` engine parameterized by a per-product
**profile**. Adding a product = a new profile, not a fork. Two guarantees so
OpenClaw (in prod) is not degraded: (1) the `openclaw` profile is
**behavior-preserving** — render byte-identical + `plan`-zero against real prod
state; (2) **no live instance is re-provisioned** — the engine affects new
provisions only, gated below.

## What v1 got WRONG (fixed in v2)

1. **"Wiring is terraform.py-only" — FALSE.** Product coupling also lives in:
   `config.py:62` `allowed_script_prefixes`, `control_plane.py:618-631`
   `_SCRIPT_REFRESH_PREAMBLE` (refreshes OPENCLAW bundles into `/opt/openclaw/scripts`
   on *every* dispatch), `admin_instances.py:66-82,554-576` `_ADMIN_OPERATIONS` +
   upgrade endpoint + `openclaw_versions` gate, `provisioning.py:83` readiness probe,
   and the **destroy path** (`terraform.py:205-238`, `provisioning.py:283-322`).
2. **"Per-instance OIDC exactly as designed" — FALSE.** It did not exist in code.
   **v2 deletes it entirely** — see Auth decision (HYBRID).
3. **No profile→scripts transport.** The behaviors that matter (restart, upgrade
   port alternation, env-var reservation, `IMAGE_REPO=odoopartners/openclaw`
   `upgrade.sh:39`) run in ~10 static SSM-bundle scripts the profile couldn't reach.
   **v2 adds the transport** below.

## Auth decision — HYBRID (shared edge-wall + portal-brokered handoff)

Decided by adversarial+investigative+decisive Fable review. **Rejected**:
literal shared session (Domain=.orquestio.com cookie readable by hostile tenant
subdomains); per-instance Zitadel OIDC (can't authorize without a Zitadel shadow
of `subscriptions`; needs a standing mgmt service account = one box compromise →
platform IdP compromise; keeps a human gate); basic-auth (UX + static secrets).

**Chosen**: ONE shared identity — the **existing** `PRYSMID_PORTAL_CUSTOMER` OIDC
app + portal session — is the only thing customers authenticate with. Instance
entry is brokered:

```
portal (Prysm:ID session)
  → POST api.orquestio.com/portal/instances/{id}/handoff   (get_current_customer + _verify_ownership; mints single-use ~60s code bound to instance_id + target host)
  → browser 302 → https://{host}/auth/handoff?code=...
  → instance nginx  location = /auth/handoff  → proxies to
  → GET api.orquestio.com/auth/edge/handoff    (validates code + X-Forwarded-Host against the instance's registered domains; reads gateway password from Secrets Manager ONLY; 302→/ with Set-Cookie: oc_session=SHA256(password); Path=/; HttpOnly; Secure; SameSite=Lax — NEVER a Domain attribute)
```

Consequences:
- **No human gate** (`human_gate_remaining=false`): reuses the existing OIDC app,
  never touches the Zitadel management API.
- **Hermes reuses OpenClaw's nginx wall VERBATIM** (`user_data.sh:273-455`):
  dashboard bound to **loopback with zero native auth** (loopback ⇒ no login page,
  no injection needed). OpenClaw keeps its Bearer-token injection.
- **UX improves**: logged-in customer clicks Open → lands authenticated.
- **Fail-static preserved**: valid `oc_session` cookies keep working during a
  control-plane outage; only NEW logins need the orchestrator. Branded `/login`
  password page stays as break-glass.
- The profile **auth schema collapses** to 4 fields (below). Per-product native
  auth (`HERMES_DASHBOARD_OIDC_*`, basic-auth) is **prohibited by contract**.

Invariants (contract-level): no component sets a `Domain=.orquestio.com` cookie;
the platform JWT / `jwt_secret` never reaches an instance host; instance nginx
strips inbound `Cookie` before proxying to the product; handoff codes are
one-shot (delete on redemption); the edge `/auth/edge/handoff` reads **only**
Secrets Manager (fixes the `portal_instances.py:170-178` stale-DB-fallback bug —
rotation never updates the DB column, so a DB fallback mints cookies from a
revoked password). Custom-domain host validation on handoff is security-critical
(skipping it = open redirect leaking session codes).

## Profile schema v2

`⟵ tfvar` = already flows through the fixed 15-var terraform.py interface (do NOT
duplicate: only `docker_image` and `container_port` actually do). Everything else
is engine data, delivered either as an HCL profile (terraform-time) or via the
**profile→scripts transport** (runtime, for the bundle scripts).

```yaml
profile:
  key: string                         # "openclaw" | "hermes"
  image_repo: string                  # upgrade.sh IMAGE_REPO (e.g. odoopartners/openclaw)
  container:
    name: string                      # docker --name
    run_command: [string]             # argv after image; {PORT} substituted
    run_as: "uid:gid"                 # 1000:1000 for openclaw (chowned in 7+ places; wrong uid → crash-loop)
    ports:
      # NOTE: container_port ⟵ tfvar is the human UI upstream port; do NOT restate it.
      health: int                     # port serving health_endpoint (openclaw 18789; hermes 8642)
      alt: int|null                   # rolling-upgrade blue/green host port (openclaw 18790; null ⇒ single-port strategy)
      published: [string]             # exact -p specs (loopback binds)
    health_endpoint: string           # profile-owned; MUST be synced to blueprint.health_check_endpoint (openclaw /healthz, hermes /health)
    readiness:
      restart_regex: string           # restart.sh gate ('http server listening')
      upgrade_regex: string           # upgrade.sh gate ('\[gateway\] ready', ~85s later — protects traffic switch)
      ansi_strip: bool                # both greps sed-strip ANSI first
    docker_health: {interval,timeout,retries,max_time,start_period}  # 30s/5s/3/3s/1200s ; override-not-disable
    restart_health_timeout_s: int     # 300 (distinct from start_period 1200)
    env_static: [ "K=V", ... ]        # ORDERED list (map loses argv order): HOME,TERM,TZ,...
    reserved_env: [string]            # infra-owned names apply_env_vars must reject (consumed via transport)
    extra_bind_mounts: [string]       # openclaw: /var/lib/openclaw/plugin-runtime-deps quirk (issue #73647)
  data:
    mount_host: string                # /mnt/efs (legacy name, ext4-on-EBS-gp3)
    volume_mounts: [string]
    config_dir: string
    config_file: string               # openclaw.json | .env
    config_format: enum(json|env|yaml)
    env_file: string                  # --env-file (container.env)
    config_seed: {kind: inline_heredoc, normalizations: [timestamps], preserve_literals: [...]}   # NOT a template file; runtime bash heredoc, create-if-missing
    data_subdirs: [string]            # mkdir'd on boot (config, workspace, ...)
    ebs: {size_gib:20, type:gp3, iops:3000, throughput:125, encrypted:true}
    secrets_manager: {name_template: "orquestio/instances/{id}/gateway-password", tags:{...}}
    registry_auth: {ssm: "/orquestio/prod/DOCKERHUB_TOKEN"}
  auth:                               # HYBRID — collapsed
    ui_upstream_port: int             # what the nginx wall proxies to (openclaw 18789; hermes 9119)
    ui_bind: enum(loopback)           # MUST be loopback; non-loopback bind = contract violation
    injected_credential: enum(none | bearer:<secret-ref> | query-token)   # openclaw bearer(gw pw)+query-token; hermes none
    websocket_paths: [string]         # Upgrade-skip logic in the wall
  scripts:
    dir: string                       # /opt/<product>/scripts
    transport: "/opt/<product>/profile.env"   # user_data writes it; EVERY bundle script sources it
    ssm_bundles: [string]             # /orquestio/prod/<NAME>_SCRIPTS_B64
    inventory: [string]               # FULL list incl. oauth_flow/status/probe_model/disconnect_ai_provider/pre_start_wipe/update+delete_env_var/add+remove_custom_domain
    optional: [string]                # cookie-wall-only where applicable
  nginx:
    artifacts: [openclaw-upstream.conf, gateway-auth.conf, custom-domain-*.conf]   # names coupled to scripts
  domain:
    mode: enum(hardcode_orquestio | template)   # DECISION: v2 = hardcode_orquestio verbatim (engine supports one domain today; user_data.sh:121 allowedOrigins is behavior not cosmetics). Templating {domain} deferred as an explicit future behavior change.
  outputs_frozen: [ec2_instance_id, public_ip, dns_record_id, access_url, access_password]  # ALL profiles, non-null (apply() hard-subscripts; KeyError → destroys fresh infra)
```

`access_password` is redefined as an **internal machine credential** (nginx→product
injection + the atomic revocation lever via `rotate_password.sh`), not the
customer login. For Hermes (`injected_credential: none`) it still carries a
break-glass password for the `/login` fallback and satisfies the frozen output.

## Orchestrator wiring inventory (all must be profile-aware, one commit-set)

- `terraform.py`: `_prepare_workspace` + `apply` tfvars + **`destroy()` reconstruction (:205-238)** + `provisioning._build_destroy_tfvars (:283-322)` — all gated on the same blueprint `profile` value. Test: every var in the generated `main.tf` is satisfiable from `_build_destroy_tfvars`. Failure prevented: post-flip `TerraformDestroyValidationError` reverts state→'running' and destroys silently no-op → **leaks EC2/EIP/EBS/Backup**.
- `config.py:62` `allowed_script_prefixes` ← derive from `profile.scripts.dir`.
- `control_plane.py:618-631` `_SCRIPT_REFRESH_PREAMBLE` ← refresh the profile's `ssm_bundles` into the profile's `dir` (today hardcodes OPENCLAW→/opt/openclaw/scripts on every dispatch).
- `admin_instances.py:66-82,554-576` `_ADMIN_OPERATIONS` + upgrade endpoint ← profile-scoped (cookie-wall-only ops hidden on non-cookie-wall); `openclaw_versions` gate ← per-product analogue.
- `provisioning.py:83` readiness probe path ← profile-driven.
- **Deployment order**: `product_instance` must land in the orchestrator terraform-submodule bump + image rebuild BEFORE any blueprint points at it (else `shutil.copytree` FileNotFoundError at provision AND in the cleanup handler).

## Gate suite (build_plan step 2 — build FIRST, against the existing module)

Renderer PROVEN (scratchpad/gate-harness/render): reproduces the module's
`user_data_base64` expression via tofu builtins (no providers). Current openclaw
golden captured: **16316/16384 bytes — only 68 bytes headroom**, so the engine
must NOT inflate user_data (the profile→scripts transport lives on host, outside
user_data). Full suite:
(a) render-diff of the 4 artifacts + variables/outputs schema, byte-equal;
(b) `plan`-zero against a COPY of a real prod tfstate under the engine (catches
resource-address renames that would destroy `aws_ebs_volume.data`, `lifecycle
ignore_changes` loss, provider-constraint drift vs pinned cloudflare ~>4.0);
(c) plan-JSON structural diff for a fresh provision;
(d) destroy-path exercise of an old-state instance through the new module;
(e) post-comment-strip user_data byte-count < 16384;
(f) render matrix with ≥2 distinct port/domain/instance_id tuples (openclaw's
18789==18789 degeneracy hides substitution bugs);
(g) re-anchor the five `test_openclaw_*` golden-master suites onto the engine's
RENDERED openclaw-profile output (else they go vacuous, not red, after promotion).

## Reference profiles

`openclaw` and `hermes` profile values are in `profiles/openclaw.json` and
`profiles/hermes.json` (authored alongside the engine). openclaw reproduces
today; hermes: `run_command=[gateway,run]`, `container_port=9119` (dashboard, ⟵
tfvar), `ports.health=8642`, `health_endpoint=/health`, `ui_bind=loopback`,
`injected_credential=none`, `env_static` includes `HERMES_DASHBOARD_HOST=127.0.0.1`
+ `HERMES_DASHBOARD=1` + (API server disabled or `API_SERVER_HOST=127.0.0.1` +
keyed), host-network/sidecar topology, `alt=null` ⇒ stop/replace upgrade window
(SLO-accepted for a starter product), and a Hermes `rotate_password`-equivalent
(cookie-map rewrite + nginx reload) for invalidation parity. Pin:
`nousresearch/hermes-agent:v2026.7.7.2` (multi-arch confirmed).

## Build order (from the review's build_plan)

1. This contract (done). 2. Gate harness. 3. Profile→scripts transport (refactor
bundle scripts to source `/opt/<product>/profile.env`; verify byte-identical on
OpenClaw; ship as a fleet bundle update). 4. `modules/product_instance` (move
openclaw logic verbatim, preserve resource ADDRESSES + the `ignore_changes` block
+ force_detach/force_destroy + comment-strip + 5 outputs) + `profiles/openclaw.json`;
gate suite green. 5. Orchestrator profile-gating (one commit-set) + submodule bump
+ handoff broker; verify OpenClaw (profile=NULL) unchanged in staging. 6. **Subagent
CODE review**, then flip OpenClaw blueprint→product_instance+profile=openclaw
(staging→prod) with destroy+upgrade verification. 7. Hermes prereqs (OIDC-free
auth via the shared wall; HERMES_*_SCRIPTS_B64 bundles published BEFORE provision;
rotate-equivalent). 8. Live-boot hermes arm64 once to confirm loopback dashboard
reachability from host nginx. 9. `profiles/hermes.json` + greenfield staging
blueprint + full E2E (buy→provision→click-Open handoff→env(reserved rejected)→
upgrade→custom domain→destroy). 10. Production Hermes + verify prod==workspace +
canonical repos; schedule deferred pre-existing-bug fixes (password_read_command
vs token seed; login.html await bug).
