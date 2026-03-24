#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
}

cd "${PROJECT_ROOT}"

if [[ -x "./scripts/check-internal-ports-policy.sh" ]]; then
  log "Running check-internal-ports-policy.sh"
  bash ./scripts/check-internal-ports-policy.sh
else
  log "check-internal-ports-policy.sh not found, skipping"
fi

if [[ -x "./scripts/check-secrets-hygiene.sh" ]]; then
  log "Running check-secrets-hygiene.sh"
  bash ./scripts/check-secrets-hygiene.sh
else
  log "check-secrets-hygiene.sh not found, skipping"
fi


log "Orchestration script completed"