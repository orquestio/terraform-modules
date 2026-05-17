#!/bin/bash
# =============================================================================
# config_sync.sh — Idempotent normalization of openclaw.json invariants
#
# Called from upgrade.sh (and any other lifecycle script that needs it) BEFORE
# the new container starts. Self-heals config keys we manage on the platform
# side regardless of when the instance was bootstrapped.
#
# Bundled in OPENCLAW_SEC_SCRIPTS_B64 (the "config-mutation" bundle) because
# OPENCLAW_SCRIPTS_B64 hit its 8KB SSM Advanced tier ceiling — see
# infrastructure/base/ssm_params.tf and incident 2026-05-17.
#
# Invariants enforced:
#   update.checkOnStart=false — suppress upstream's native update banner.
#     Only Orquestio portal upgrades use curated ARM64 images + burn-in;
#     the native banner would steer customers off the curated path.
#
# Exit codes:
#   0 — all invariants conform (no-op or successfully patched)
#   1 — failure (logged; caller decides whether to abort)
#
# Idempotent. Safe to invoke from multiple hooks (cron, restart, upgrade).
# =============================================================================
set -euo pipefail

CFG="${1:-/mnt/efs/config/openclaw.json}"

if [ ! -f "$CFG" ]; then
  echo "[config-sync] $CFG not found; nothing to do" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[config-sync] python3 not available; skipping" >&2
  exit 0
fi

python3 - "$CFG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

changed = []

# Invariant: update.checkOnStart must be False
upd = cfg.setdefault("update", {})
if upd.get("checkOnStart") is not False:
    upd["checkOnStart"] = False
    changed.append("update.checkOnStart=false")

# Future invariants get appended here as additional setdefault/check pairs.

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"[config-sync] patched: {', '.join(changed)}")
else:
    print("[config-sync] all invariants conform; no changes")
PYEOF
