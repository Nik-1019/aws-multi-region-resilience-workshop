#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh -- tear the workshop down in reverse order of creation.
#
#   ./scripts/cleanup.sh          # confirm each resource
#   ./scripts/cleanup.sh --yes    # no prompts (careful)
#
# Order matters: CloudFront and Route 53 first, then the secondary stack (its
# read replica must go before the source database), then the primary stack.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${WORKSHOP_CONFIG:-${ROOT_DIR}/.workshop-config}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

die()  { printf "\n%s✘ %s%s\n\n" "$RED" "$*" "$RESET" >&2; exit 1; }
ok()   { printf "%s✔ %s%s\n" "$GREEN" "$*" "$RESET"; }
skip() { printf "%s- %s%s\n" "$DIM" "$*" "$RESET"; }
warn() { printf "%s! %s%s\n" "$YELLOW" "$*" "$RESET"; }
info() { printf "%s  %s%s\n" "$DIM" "$*" "$RESET"; }
step() { printf "\n%s%s>> %s%s\n" "$BOLD" "$BLUE" "$*" "$RESET"; }

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      printf "Usage: ./cleanup.sh [--yes]\n\nDeletes every resource this workshop created.\n"
      exit 0 ;;
    *) die "unknown argument '$arg'" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found in PATH"

TMPDIR_WORK="$(mktemp -d 2>/dev/null || mktemp -d -t workshop)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

DELETED_COUNT=0

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf "%s%s%s " "$BOLD" "$1" "$RESET"
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# --- configuration ---------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-resilience-workshop}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
CLOUDFRONT_DISTRIBUTION_ID=""
ROUTE53_HEALTH_CHECK_IDS=""
DEPLOYED_AT=""
ESTIMATED_HOURLY_COST="0.18"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  info "loaded $CONFIG_FILE"
else
  warn "no .workshop-config found -- falling back to default names"
fi

PRIMARY_STACK="${PRIMARY_STACK:-${PROJECT_NAME}-primary}"
SECONDARY_STACK="${SECONDARY_STACK:-${PROJECT_NAME}-secondary}"

printf "\n%s%s AWS Resilience Workshop -- cleanup %s\n" "$BOLD" "$BLUE" "$RESET"
printf "%s  %s (%s) and %s (%s)%s\n" "$DIM" \
  "$PRIMARY_STACK" "$PRIMARY_REGION" "$SECONDARY_STACK" "$SECONDARY_REGION" "$RESET"

if [ "$ASSUME_YES" -eq 0 ]; then
  printf "\n%sThis permanently deletes the workshop infrastructure, including the\n" "$YELLOW"
  printf "database and all of its data. There is no final snapshot.%s\n\n" "$RESET"
  confirm "Continue? (y/N)" || { printf "Nothing was deleted.\n"; exit 0; }
fi

# --- 1. CloudFront ---------------------------------------------------------
disable_distribution() {
  local dist_id="$1" etag config_file body_file

  config_file="${TMPDIR_WORK}/dist-${dist_id}.json"
  body_file="${TMPDIR_WORK}/dist-${dist_id}-config.json"

  if ! aws cloudfront get-distribution-config --id "$dist_id" \
        --output json > "$config_file" 2>/dev/null; then
    skip "distribution $dist_id not found (already deleted?)"
    return 1
  fi

  local enabled
  if command -v jq >/dev/null 2>&1; then
    etag="$(jq -r '.ETag' "$config_file")"
    enabled="$(jq -r '.DistributionConfig.Enabled' "$config_file")"
    jq '.DistributionConfig | .Enabled = false' "$config_file" > "$body_file"
  elif command -v python3 >/dev/null 2>&1; then
    etag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$config_file")"
    enabled="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["DistributionConfig"]["Enabled"]).lower())' "$config_file")"
    python3 - "$config_file" "$body_file" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
cfg = doc["DistributionConfig"]
cfg["Enabled"] = False
json.dump(cfg, open(sys.argv[2], "w"))
PY
  else
    warn "neither jq nor python3 is available -- disable and delete distribution $dist_id by hand"
    return 1
  fi

  if [ "$enabled" = "true" ]; then
    info "disabling distribution $dist_id"
    aws cloudfront update-distribution --id "$dist_id" --if-match "$etag" \
      --distribution-config "file://${body_file}" >/dev/null \
      || { warn "could not disable $dist_id"; return 1; }
  else
    info "distribution $dist_id is already disabled"
  fi

  info "waiting for the distribution to finish deploying (up to ~15 minutes)"
  aws cloudfront wait distribution-deployed --id "$dist_id" \
    || warn "wait timed out; the delete below may need a retry"
  return 0
}

cleanup_cloudfront() {
  step "CloudFront distribution"

  if [ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
    skip "no CLOUDFRONT_DISTRIBUTION_ID in .workshop-config -- nothing to delete"
    info "if you created one during the workshop, add its id to the config and re-run"
    return
  fi

  confirm "Delete CloudFront distribution ${CLOUDFRONT_DISTRIBUTION_ID}? (y/N)" || {
    skip "keeping the CloudFront distribution"
    return
  }

  disable_distribution "$CLOUDFRONT_DISTRIBUTION_ID" || return

  local etag
  etag="$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID" \
            --query ETag --output text 2>/dev/null || true)"
  if [ -z "$etag" ] || [ "$etag" = "None" ]; then
    warn "could not read the distribution ETag -- delete it manually"
    return
  fi

  if aws cloudfront delete-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" \
       --if-match "$etag" 2>/dev/null; then
    ok "deleted CloudFront distribution $CLOUDFRONT_DISTRIBUTION_ID"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    warn "delete failed -- distributions can take a few minutes to become deletable"
  fi
}

# --- 2. Route 53 health checks --------------------------------------------
cleanup_health_checks() {
  step "Route 53 health checks"

  if [ -z "$ROUTE53_HEALTH_CHECK_IDS" ]; then
    skip "no ROUTE53_HEALTH_CHECK_IDS in .workshop-config -- nothing to delete"
    return
  fi

  local hc
  for hc in $ROUTE53_HEALTH_CHECK_IDS; do
    confirm "Delete health check ${hc}? (y/N)" || { skip "keeping $hc"; continue; }
    if aws route53 delete-health-check --health-check-id "$hc" 2>/dev/null; then
      ok "deleted health check $hc"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      warn "could not delete $hc -- it may still be referenced by a DNS record"
    fi
  done
}

# --- 3 & 4. CloudFormation stacks -----------------------------------------
delete_stack() {
  # delete_stack <stack> <region> <label>
  local stack="$1" region="$2" label="$3" status

  step "$label stack ($stack in $region)"

  status="$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
              --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"

  case "$status" in
    ''|None|DELETE_COMPLETE)
      skip "stack not present"
      return ;;
  esac

  info "current status: $status"
  confirm "Delete stack ${stack}? (y/N)" || { skip "keeping $stack"; return; }

  aws cloudformation delete-stack --stack-name "$stack" --region "$region" >/dev/null \
    || { warn "delete-stack call failed for $stack"; return; }

  info "waiting for deletion (10-20 minutes -- RDS and NAT gateways are slow)"
  if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region"; then
    ok "deleted $stack"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    warn "stack $stack did not delete cleanly. Recent failures:"
    aws cloudformation describe-stack-events --stack-name "$stack" --region "$region" \
      --max-items 10 \
      --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
      --output text 2>/dev/null | head -n 10 || true
    warn "fix the listed resources, then re-run ./scripts/cleanup.sh"
  fi
}

# --- 5. leftovers ----------------------------------------------------------
check_leftovers() {
  step "Checking for leftovers"

  local region found=0 snapshots
  for region in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
    snapshots="$(aws rds describe-db-snapshots --region "$region" \
                   --snapshot-type manual \
                   --query "DBSnapshots[?contains(DBSnapshotIdentifier, '${PROJECT_NAME}')].DBSnapshotIdentifier" \
                   --output text 2>/dev/null || true)"
    if [ -n "$snapshots" ] && [ "$snapshots" != "None" ]; then
      warn "manual RDS snapshots still in $region (these cost money):"
      printf "    %s\n" "$snapshots"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    ok "no stray workshop snapshots found"
  fi
}

# --- cost estimate ---------------------------------------------------------
epoch_from_iso() {
  # Portable-ish ISO-8601 -> epoch seconds. Empty output when unparseable.
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' \
      "$iso" 2>/dev/null && return 0
  fi
  return 1
}

print_cost() {
  local started now hours charge
  if [ -n "$DEPLOYED_AT" ] && started="$(epoch_from_iso "$DEPLOYED_AT")"; then
    now="$(date -u +%s)"
    hours="$(awk -v a="$started" -v b="$now" 'BEGIN { printf "%.1f", (b-a)/3600 }')"
    charge="$(awk -v h="$hours" -v r="$ESTIMATED_HOURLY_COST" 'BEGIN { printf "%.2f", h*r }')"
    printf "\n%s%sAll resources cleaned up. Estimated charges for this session: ~\$%s%s\n" \
      "$BOLD" "$GREEN" "$charge" "$RESET"
    info "based on ${hours}h at \$${ESTIMATED_HOURLY_COST}/hr since ${DEPLOYED_AT}"
  else
    printf "\n%s%sAll resources cleaned up. Estimated charges for this session: ~\$0.50%s\n" \
      "$BOLD" "$GREEN" "$RESET"
    info "no deployment timestamp available; assuming a short session"
  fi
  printf "%sVerify in Billing > Cost Explorer -- charges can take a few hours to appear.%s\n\n" \
    "$DIM" "$RESET"
}

# --- main ------------------------------------------------------------------
cleanup_cloudfront
cleanup_health_checks
delete_stack "$SECONDARY_STACK" "$SECONDARY_REGION" "Secondary"
delete_stack "$PRIMARY_STACK" "$PRIMARY_REGION" "Primary"
check_leftovers

printf "\n%s%d resource group(s) deleted.%s\n" "$DIM" "$DELETED_COUNT" "$RESET"

if [ -f "$CONFIG_FILE" ]; then
  if confirm "Remove ${CONFIG_FILE}? (y/N)"; then
    rm -f "$CONFIG_FILE"
    ok "removed $CONFIG_FILE"
  else
    skip "keeping $CONFIG_FILE"
  fi
fi

print_cost
