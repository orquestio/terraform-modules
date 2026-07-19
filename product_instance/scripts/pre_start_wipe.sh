#!/bin/bash
# =============================================================================
# pre_start_wipe.sh — Wipe plugin-runtime-deps before starting OpenClaw
#
# Issue #1 mitigation (OpenClaw cache validator infinite-loop, upstream
# issue #73647 closed-as-not-planned). When the cache directory contains
# stale entries from a wedged container, the validator re-enters the loop
# the moment the new container boots. Wiping the dir before start guarantees
# a clean slate.
#
# Invoked by openclaw-watchdog.service when an unhealthy container is being
# recovered. Safe to call standalone — it only removes contents under
# /var/lib/openclaw/plugin-runtime-deps and never the dir itself.
#
# Why mindepth 1: the bind-mount target (the dir itself) MUST exist for the
# next `docker run -v` to succeed. We only nuke its contents.
# =============================================================================
set -euo pipefail

DEPS_DIR="/var/lib/openclaw/plugin-runtime-deps"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [pre_start_wipe.sh] $*"; }

if [ ! -d "$DEPS_DIR" ]; then
  log "no $DEPS_DIR; creating empty dir"
  mkdir -p "$DEPS_DIR"
  chown 1000:1000 "$DEPS_DIR"
  exit 0
fi

log "wiping contents of $DEPS_DIR"
find "$DEPS_DIR" -mindepth 1 -delete
chown 1000:1000 "$DEPS_DIR"
log "done"
