#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# chaos.sh -- simulate a regional outage by cutting public traffic to the
# primary ALB, then put it back.
#
#   ./scripts/chaos.sh break     # revoke HTTP/HTTPS ingress on the primary ALB
#   ./scripts/chaos.sh restore   # re-add it
#   ./scripts/chaos.sh status    # show the current state
#
# Reads .workshop-config (written by deploy.sh) from the repository root.
# Nothing is destroyed: only two security group rules move.
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

die() { printf "%s✘ %s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }
info() { printf "%s%s%s\n" "$DIM" "$*" "$RESET"; }
ok() { printf "%s✔ %s%s\n" "$GREEN" "$*" "$RESET"; }

usage() {
  cat <<'EOF'
Usage: ./chaos.sh <command>

Commands:
  break       Block traffic to the primary ALB (simulates a regional outage)
  restore     Restore traffic to the primary ALB
  status      Show the current state of chaos injection

Options:
  -y, --yes   Skip the confirmation prompt (for scripted demos)
  -h, --help  Show this help
EOF
}

# --- configuration ---------------------------------------------------------
load_config() {
  [ -f "$CONFIG_FILE" ] || die "no .workshop-config found at $CONFIG_FILE
  Run ./scripts/deploy.sh first, or set WORKSHOP_CONFIG to its location."

  # shellcheck disable=SC1090
  . "$CONFIG_FILE"

  PRIMARY_STACK="${PRIMARY_STACK:-}"
  PRIMARY_REGION="${PRIMARY_REGION:-}"
  [ -n "$PRIMARY_STACK" ]  || die "PRIMARY_STACK missing from $CONFIG_FILE"
  [ -n "$PRIMARY_REGION" ] || die "PRIMARY_REGION missing from $CONFIG_FILE"
}

stack_output() {
  # stack_output <key> -- empty string when absent
  aws cloudformation describe-stacks \
    --stack-name "$PRIMARY_STACK" --region "$PRIMARY_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null || true
}

resolve_target() {
  info "reading stack ${PRIMARY_STACK} in ${PRIMARY_REGION}..."
  SG_ID="$(stack_output ALBSecurityGroupId)"
  case "$SG_ID" in
    ''|None) die "stack '$PRIMARY_STACK' not found in $PRIMARY_REGION, or it has
  no ALBSecurityGroupId output. Check the stack finished deploying." ;;
  esac
  ALB_DNS="$(stack_output ALBDNSName)"
  # Plain 'test && assign' would return 1 here and, under set -e, abort the
  # script the moment the ALB DNS name is present.
  if [ "$ALB_DNS" = "None" ]; then
    ALB_DNS=""
  fi
}

# --- rule inspection -------------------------------------------------------
open_ports() {
  # Echoes each public port (80/443) that currently allows 0.0.0.0/0.
  aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$PRIMARY_REGION" \
    --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']].FromPort" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -E '^(80|443)$' || true
}

is_broken() {
  [ -z "$(open_ports)" ]
}

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  printf "%s%s%s " "$BOLD" "$1" "$RESET"
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) printf "%sAborted -- nothing changed.%s\n" "$YELLOW" "$RESET"; return 1 ;;
  esac
}

# --- commands --------------------------------------------------------------
cmd_break() {
  resolve_target

  if is_broken; then
    printf "%s! Primary ALB is already blocked -- nothing to do.%s\n" "$YELLOW" "$RESET"
    return 0
  fi

  printf "\n%s%sAbout to break the PRIMARY region%s\n" "$BOLD" "$RED" "$RESET"
  printf "  stack:          %s (%s)\n" "$PRIMARY_STACK" "$PRIMARY_REGION"
  printf "  security group: %s\n" "$SG_ID"
  [ -n "$ALB_DNS" ] && printf "  ALB:            %s\n" "$ALB_DNS" || true
  printf "  effect:         HTTP/HTTPS ingress from 0.0.0.0/0 is revoked\n\n"

  confirm "Are you sure you want to break the primary region? (y/N)" || return 0

  local port revoked=0
  for port in 80 443; do
    if aws ec2 revoke-security-group-ingress \
         --group-id "$SG_ID" --region "$PRIMARY_REGION" \
         --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null 2>&1; then
      info "  revoked tcp/$port from 0.0.0.0/0"
      revoked=$((revoked + 1))
    else
      info "  tcp/$port was already closed"
    fi
  done

  [ "$revoked" -gt 0 ] || printf "%s! No rules changed -- was it already broken?%s\n" \
    "$YELLOW" "$RESET"

  printf "\n%s%sChaos injected - Primary ALB is now unreachable%s\n" \
    "$BOLD" "$RED" "$RESET"
  printf "%sWatch the heartbeat monitor: traffic should shift to the secondary region.%s\n" \
    "$DIM" "$RESET"
  printf "%sUndo with: ./scripts/chaos.sh restore%s\n\n" "$DIM" "$RESET"
}

cmd_restore() {
  resolve_target

  local port restored=0
  for port in 80 443; do
    if aws ec2 authorize-security-group-ingress \
         --group-id "$SG_ID" --region "$PRIMARY_REGION" \
         --ip-permissions \
           "IpProtocol=tcp,FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=0.0.0.0/0,Description=restored by chaos.sh}]" \
         >/dev/null 2>&1; then
      info "  authorized tcp/$port from 0.0.0.0/0"
      restored=$((restored + 1))
    else
      info "  tcp/$port was already open"
    fi
  done

  printf "\n%s%sChaos restored - Primary ALB is healthy again%s\n" \
    "$BOLD" "$GREEN" "$RESET"
  [ -n "$ALB_DNS" ] && printf "%sIt can take a few seconds for clients and CloudFront to notice.%s\n" \
    "$DIM" "$RESET" || true
  printf "\n"
}

cmd_status() {
  resolve_target

  printf "\n%sChaos status%s\n" "$BOLD" "$RESET"
  printf "  stack:          %s (%s)\n" "$PRIMARY_STACK" "$PRIMARY_REGION"
  printf "  security group: %s\n" "$SG_ID"
  [ -n "$ALB_DNS" ] && printf "  ALB:            %s\n" "$ALB_DNS" || true

  local ports
  ports="$(open_ports | tr '\n' ' ' | sed 's/ *$//')"

  if [ -z "$ports" ]; then
    printf "  ingress:        %sblocked%s (no public 80/443 rules)\n" "$RED" "$RESET"
    printf "\n  %s%sCHAOS ACTIVE - primary region is cut off%s\n" "$BOLD" "$RED" "$RESET"
  else
    printf "  ingress:        %sopen%s (tcp %s from 0.0.0.0/0)\n" "$GREEN" "$RESET" "$ports"
    printf "\n  %s%sNORMAL - primary region is reachable%s\n" "$BOLD" "$GREEN" "$RESET"
  fi

  # A live probe tells participants what the internet actually sees.
  if [ -n "$ALB_DNS" ] && command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://${ALB_DNS}/health" 2>/dev/null || true)"
    case "$code" in
      200) printf "  live probe:     %sHTTP 200%s from the primary ALB\n" "$GREEN" "$RESET" ;;
      ''|000) printf "  live probe:     %sno response%s (connection refused or timed out)\n" "$BLUE" "$RESET" ;;
      *)   printf "  live probe:     HTTP %s\n" "$code" ;;
    esac
  fi
  printf "\n"
}

# --- entry point -----------------------------------------------------------
COMMAND=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    break|restore|status) COMMAND="$1" ;;
    *) printf "chaos: unknown argument '%s'\n\n" "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$COMMAND" ] || { usage >&2; exit 2; }
command -v aws >/dev/null 2>&1 || die "AWS CLI not found in PATH"

load_config

case "$COMMAND" in
  break)   cmd_break ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
esac
