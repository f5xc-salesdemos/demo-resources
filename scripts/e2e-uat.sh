#!/usr/bin/env bash
set -uo pipefail

# End-to-End UAT for Demo Resources
# Deploys all three components, wires outputs, runs smoke tests, tears down.
# Usage: ./e2e-uat.sh <subscription-id> [--skip-teardown]
#
# Prerequisites:
#   - az login (authenticated)
#   - terraform >= 1.5
#   - SSH key at ~/.ssh/id_ed25519.pub
#
# Exit codes: 0 = all pass, 1 = failures detected

SUBSCRIPTION_ID="${1:?Usage: $0 <subscription-id> [--skip-teardown]}"
SKIP_TEARDOWN=false
[ "${2:-}" = "--skip-teardown" ] && SKIP_TEARDOWN=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
COMPONENTS_DEPLOYED=""

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m  %s (expected=%s got=%s)\n' "$name" "$expected" "$actual"
  fi
}

teardown() {
  if [ "$SKIP_TEARDOWN" = true ]; then
    log "Skipping teardown (--skip-teardown)"
    return
  fi
  log "Tearing down all components..."
  for component in traffic-generator cdn-simulator origin-server; do
    local tf_dir
    tf_dir="$(dirname "$REPO_ROOT")/$component/terraform"
    if [ -f "$tf_dir/terraform.tfstate" ]; then
      log "Destroying $component..."
      if (cd "$tf_dir" && terraform destroy -input=false -auto-approve >/dev/null 2>&1); then
        log "$component destroyed"
      else
        log "$component destroy failed"
      fi
    fi
  done
}

trap teardown EXIT

log "E2E UAT starting"
log "Subscription: $SUBSCRIPTION_ID"

# --- Phase 1: Deploy Origin Server ---
log "Phase 1: Deploying origin-server"
ORIGIN_DIR="$(dirname "$REPO_ROOT")/origin-server/terraform"
if [ -d "$ORIGIN_DIR" ]; then
  printf 'subscription_id = "%s"\n' "$SUBSCRIPTION_ID" > "$ORIGIN_DIR/terraform.tfvars"
  (cd "$ORIGIN_DIR" && terraform init -input=false >/dev/null 2>&1 && terraform apply -input=false -auto-approve >/dev/null 2>&1)
  ORIGIN_IP=$(cd "$ORIGIN_DIR" && terraform output -raw public_ip 2>/dev/null)
  check "origin-deploy" "true" "$([ -n "$ORIGIN_IP" ] && echo true || echo false)"
  COMPONENTS_DEPLOYED="origin-server"
  log "Origin server IP: $ORIGIN_IP"

  log "Waiting for origin-server cloud-init (up to 15 min)..."
  WAITED=0
  while [ "$WAITED" -lt 900 ]; do
    if curl -sS --connect-timeout 5 --max-time 10 "http://$ORIGIN_IP/health" 2>/dev/null | grep -q '"healthy"'; then
      break
    fi
    sleep 15
    WAITED=$((WAITED + 15))
  done
  HEALTH=$(curl -sS --max-time 10 "http://$ORIGIN_IP/health" 2>/dev/null)
  check "origin-health" "true" "$(echo "$HEALTH" | grep -q '"healthy"' && echo true || echo false)"

  log "Running origin-server smoke test..."
  ORIGIN_SMOKE="$(dirname "$REPO_ROOT")/origin-server/tests/smoke-test.sh"
  if [ -x "$ORIGIN_SMOKE" ]; then
    SMOKE_RESULT=$("$ORIGIN_SMOKE" "$ORIGIN_IP" 2>&1 | tail -1)
    check "origin-smoke" "SMOKE TEST: PASSED" "$SMOKE_RESULT"
  else
    check "origin-smoke-exists" "true" "false"
  fi
else
  check "origin-dir-exists" "true" "false"
fi

# --- Phase 2: Deploy CDN Simulator ---
log "Phase 2: Deploying cdn-simulator"
CDN_DIR="$(dirname "$REPO_ROOT")/cdn-simulator/terraform"
if [ -d "$CDN_DIR" ] && [ -n "${ORIGIN_IP:-}" ]; then
  printf 'subscription_id = "%s"\norigin_server   = "http://%s"\norigin_host     = "%s:80"\n' \
    "$SUBSCRIPTION_ID" "$ORIGIN_IP" "$ORIGIN_IP" > "$CDN_DIR/terraform.tfvars"
  (cd "$CDN_DIR" && terraform init -input=false >/dev/null 2>&1 && terraform apply -input=false -auto-approve >/dev/null 2>&1)
  CDN_IP=$(cd "$CDN_DIR" && terraform output -raw public_ip 2>/dev/null)
  check "cdn-deploy" "true" "$([ -n "$CDN_IP" ] && echo true || echo false)"
  COMPONENTS_DEPLOYED="$COMPONENTS_DEPLOYED cdn-simulator"
  log "CDN simulator IP: $CDN_IP"

  log "Waiting for cdn-simulator cloud-init (up to 5 min)..."
  WAITED=0
  while [ "$WAITED" -lt 300 ]; do
    if curl -sS --connect-timeout 5 --max-time 10 "http://$CDN_IP/health" 2>/dev/null | grep -q '"healthy"'; then
      break
    fi
    sleep 10
    WAITED=$((WAITED + 10))
  done
  CDN_HEALTH=$(curl -sS --max-time 10 "http://$CDN_IP/health" 2>/dev/null)
  check "cdn-health" "true" "$(echo "$CDN_HEALTH" | grep -q '"healthy"' && echo true || echo false)"

  log "Running cdn-simulator smoke test..."
  CDN_SMOKE="$(dirname "$REPO_ROOT")/cdn-simulator/scripts/smoke-test.sh"
  if [ -x "$CDN_SMOKE" ]; then
    SMOKE_RESULT=$("$CDN_SMOKE" "$CDN_IP" 2>&1 | tail -1)
    check "cdn-smoke" "SMOKE TEST: PASSED" "$SMOKE_RESULT"
  else
    check "cdn-smoke-exists" "true" "false"
  fi
else
  check "cdn-deploy-skipped" "true" "$([ -z "${ORIGIN_IP:-}" ] && echo true || echo false)"
fi

# --- Phase 3: Deploy Traffic Generator ---
log "Phase 3: Deploying traffic-generator"
TG_DIR="$(dirname "$REPO_ROOT")/traffic-generator/terraform"
if [ -d "$TG_DIR" ] && [ -n "${ORIGIN_IP:-}" ]; then
  printf 'subscription_id = "%s"\ntarget_fqdn     = "%s"\n' \
    "$SUBSCRIPTION_ID" "$ORIGIN_IP" > "$TG_DIR/terraform.tfvars"
  (cd "$TG_DIR" && terraform init -input=false >/dev/null 2>&1 && terraform apply -input=false -auto-approve >/dev/null 2>&1)
  TG_IP=$(cd "$TG_DIR" && terraform output -raw public_ip 2>/dev/null)
  check "tg-deploy" "true" "$([ -n "$TG_IP" ] && echo true || echo false)"
  COMPONENTS_DEPLOYED="$COMPONENTS_DEPLOYED traffic-generator"
  log "Traffic generator IP: $TG_IP"

  log "Waiting for traffic-generator cloud-init (up to 25 min)..."
  WAITED=0
  while [ "$WAITED" -lt 1500 ]; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "azureuser@$TG_IP" \
      "cloud-init status" 2>/dev/null | grep -q "done"; then
      break
    fi
    sleep 30
    WAITED=$((WAITED + 30))
  done
  CLOUD_STATUS=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "azureuser@$TG_IP" "cloud-init status" 2>/dev/null | grep -o "done" || echo "not_done")
  check "tg-cloud-init" "done" "$CLOUD_STATUS"

  log "Running traffic-generator smoke test..."
  TG_SMOKE="$(dirname "$REPO_ROOT")/traffic-generator/scripts/smoke-test.sh"
  if [ -x "$TG_SMOKE" ]; then
    SMOKE_RESULT=$("$TG_SMOKE" "$TG_IP" 2>&1 | tail -1)
    check "tg-smoke" "SMOKE TEST: PASSED" "$SMOKE_RESULT"
  else
    check "tg-smoke-exists" "true" "false"
  fi
else
  check "tg-deploy-skipped" "true" "$([ -z "${ORIGIN_IP:-}" ] && echo true || echo false)"
fi

# --- Results ---
echo ""
echo "============================================"
echo "  E2E UAT RESULTS: $PASS passed, $FAIL failed"
echo "  Components deployed: $COMPONENTS_DEPLOYED"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
