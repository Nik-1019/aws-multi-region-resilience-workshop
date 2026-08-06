#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh -- guided two-region deployment for the resilience workshop.
#
#   ./scripts/deploy.sh
#
# Deploys primary.yaml to us-east-1, waits for it, then deploys secondary.yaml
# to us-west-2 with the primary database ARN so RDS builds a cross-region read
# replica. Writes .workshop-config for chaos.sh and cleanup.sh.
#
# Environment overrides:
#   PROJECT_NAME       (default resilience-workshop, max 19 characters)
#   PRIMARY_REGION     (default us-east-1)
#   SECONDARY_REGION   (default us-west-2)
#   GIT_REPO_URL       repo the instances clone at boot
#   INSTANCE_TYPE      (default t3.micro)
#   DB_INSTANCE_CLASS  (default db.t3.micro)
#   PILOT_LIGHT_SIZE   secondary ASG size, 0 or 1 (default 1)
#   DB_PASSWORD        skip the prompt (useful in CI)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${WORKSHOP_CONFIG:-${ROOT_DIR}/.workshop-config}"
TEMPLATE_DIR="${ROOT_DIR}/cloudformation"

PROJECT_NAME="${PROJECT_NAME:-resilience-workshop}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/Nik-1019/aws-multi-region-resilience-workshop.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
PILOT_LIGHT_SIZE="${PILOT_LIGHT_SIZE:-1}"
DB_NAME="${DB_NAME:-workshop}"
DB_USERNAME="${DB_USERNAME:-admin}"

PRIMARY_STACK="${PROJECT_NAME}-primary"
SECONDARY_STACK="${PROJECT_NAME}-secondary"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

die()  { printf "\n%s✘ %s%s\n\n" "$RED" "$*" "$RESET" >&2; exit 1; }
ok()   { printf "%s✔ %s%s\n" "$GREEN" "$*" "$RESET"; }
info() { printf "%s  %s%s\n" "$DIM" "$*" "$RESET"; }
step() { printf "\n%s%s>> %s%s\n" "$BOLD" "$BLUE" "$*" "$RESET"; }

# --- preconditions ---------------------------------------------------------
# AWS caps load balancer and target group names at 32 characters. Every such
# name is "${PROJECT_NAME}${SUFFIX}", and the longest suffix in either template
# is '-secondary-tg' (13 chars), so PROJECT_NAME has 19 characters to work
# with. Catching it here turns a 15-minute ROLLBACK_COMPLETE into an instant
# error -- CloudFormation only rejects the name once it tries to build the ALB.
MAX_PROJECT_NAME_LEN=19
case "$PROJECT_NAME" in
  *[!a-z0-9-]*|"") die "PROJECT_NAME '${PROJECT_NAME}' is invalid.
  Use lowercase letters, digits and hyphens only." ;;
  -*) die "PROJECT_NAME '${PROJECT_NAME}' is invalid.
  AWS rejects load balancer names that begin with a hyphen." ;;
esac
if [ "${#PROJECT_NAME}" -gt "$MAX_PROJECT_NAME_LEN" ]; then
  die "PROJECT_NAME '${PROJECT_NAME}' is ${#PROJECT_NAME} characters -- the maximum is ${MAX_PROJECT_NAME_LEN}.
  It would produce the target group name '${PROJECT_NAME}-secondary-tg'
  (${#PROJECT_NAME} + 13 = $(( ${#PROJECT_NAME} + 13 )) chars), and AWS caps load balancer and
  target group names at 32. Shorten it, e.g. PROJECT_NAME=$(printf '%s' "$PROJECT_NAME" | cut -c1-${MAX_PROJECT_NAME_LEN})"
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Run ./scripts/preflight.sh first."
[ -f "${TEMPLATE_DIR}/primary.yaml" ]   || die "missing ${TEMPLATE_DIR}/primary.yaml"
[ -f "${TEMPLATE_DIR}/secondary.yaml" ] || die "missing ${TEMPLATE_DIR}/secondary.yaml"

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS credentials are not configured. Run 'aws configure'."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# --- password --------------------------------------------------------------
generate_password() {
  # 24 alphanumeric characters: always inside the RDS-safe character set.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24
  fi
}

validate_password() {
  local pw="$1"
  case "${#pw}" in
    [0-7]) return 1 ;;
  esac
  [ "${#pw}" -ge 8 ] && [ "${#pw}" -le 41 ] || return 1
  # RDS rejects / @ " and whitespace in master passwords.
  case "$pw" in
    *[/@\"\ ]*) return 1 ;;
  esac
  return 0
}

resolve_password() {
  if [ -n "${DB_PASSWORD:-}" ]; then
    validate_password "$DB_PASSWORD" \
      || die "DB_PASSWORD must be 8-41 characters and must not contain / @ \" or spaces."
    ok "using DB_PASSWORD from the environment"
    return
  fi

  printf "\n%sDatabase master password%s\n" "$BOLD" "$RESET"
  printf "%s  8-41 characters, no / @ \" or spaces. Press Enter to generate one.%s\n" \
    "$DIM" "$RESET"
  printf "  Password: "
  stty -echo 2>/dev/null || true
  read -r entered || entered=""
  stty echo 2>/dev/null || true
  printf "\n"

  if [ -z "$entered" ]; then
    DB_PASSWORD="$(generate_password)"
    validate_password "$DB_PASSWORD" || die "failed to generate a valid password"
    ok "generated a random 24-character password (saved to .workshop-config)"
  else
    validate_password "$entered" \
      || die "password must be 8-41 characters and must not contain / @ \" or spaces."
    DB_PASSWORD="$entered"
    ok "password accepted"
  fi
}

# --- CloudFormation helpers ------------------------------------------------
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$2" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true
}

stack_output() {
  # stack_output <stack> <region> <key>
  aws cloudformation describe-stacks --stack-name "$1" --region "$2" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" \
    --output text 2>/dev/null || true
}

show_recent_events() {
  # Events come back newest-first, and a failed create immediately starts a
  # rollback -- so the newest events are all DELETE_*, and a small --max-items
  # window filters the actual cause out entirely. Pull a deep window, drop the
  # "cancelled" noise CloudFormation attaches to sibling resources, then
  # reverse so the earliest failure (the root cause) is printed first.
  local events
  events="$(aws cloudformation describe-stack-events --stack-name "$1" --region "$2" \
    --max-items 200 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED` || ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output text 2>/dev/null || true)"

  events="$(printf '%s\n' "$events" \
    | grep -v 'Resource creation cancelled' \
    | grep -v 'Resource update cancelled' \
    | grep -v '^[[:space:]]*$' || true)"

  if [ -z "$events" ]; then
    printf "\n%sNo explicit failure events found. Inspect the stack in the console:%s\n" \
      "$YELLOW" "$RESET"
    printf "  https://%s.console.aws.amazon.com/cloudformation/home?region=%s#/stacks\n" "$2" "$2"
    return
  fi

  printf "\n%sWhy it failed (earliest failure first):%s\n" "$YELLOW" "$RESET"
  printf '%s\n' "$events" \
    | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' \
    | head -n 5 \
    | sed 's/^/    /'
}

wait_with_progress() {
  # wait_with_progress <waiter> <stack> <region>
  #
  # aws cloudformation wait blocks silently for 10-30 minutes, which is
  # indistinguishable from a hang when a room of people is watching. Run the
  # waiter in the background and report progress every 30 seconds.
  local waiter="$1" stack="$2" region="$3"
  local pid elapsed=0 mins secs status statuses total finished

  aws cloudformation wait "$waiter" --stack-name "$stack" --region "$region" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    [ "$((elapsed % 30))" -eq 0 ] || continue

    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    status="$(stack_status "$stack" "$region")"
    statuses="$(aws cloudformation list-stack-resources --stack-name "$stack" \
                  --region "$region" --query 'StackResourceSummaries[].ResourceStatus' \
                  --output text 2>/dev/null || true)"

    if [ -n "$statuses" ]; then
      total="$(printf '%s' "$statuses" | tr '\t' '\n' | grep -c . || true)"
      finished="$(printf '%s' "$statuses" | tr '\t' '\n' | grep -c '_COMPLETE$' || true)"
      printf "%s    [%dm%02ds] %s -- %s/%s resources done%s\n" \
        "$DIM" "$mins" "$secs" "${status:-working}" "$finished" "$total" "$RESET"
    else
      printf "%s    [%dm%02ds] %s%s\n" "$DIM" "$mins" "$secs" "${status:-working}" "$RESET"
    fi
  done

  if wait "$pid"; then
    return 0
  fi
  return 1
}

deploy_stack() {
  # deploy_stack <stack> <region> <template> <param...>
  local stack="$1" region="$2" template="$3"
  shift 3

  local status action wait_for
  status="$(stack_status "$stack" "$region")"

  case "$status" in
    ROLLBACK_COMPLETE|REVIEW_IN_PROGRESS)
      info "stack is in $status and cannot be updated -- deleting it first"
      aws cloudformation delete-stack --stack-name "$stack" --region "$region" >/dev/null
      wait_with_progress stack-delete-complete "$stack" "$region" \
        || die "could not delete the failed $stack stack; remove it in the console and retry"
      status="" ;;
    *_IN_PROGRESS)
      die "stack $stack is currently $status. Wait for it to settle, then retry." ;;
  esac

  if [ -z "$status" ] || [ "$status" = "None" ] || [ "$status" = "DELETE_COMPLETE" ]; then
    action=create-stack
    wait_for=stack-create-complete
  else
    action=update-stack
    wait_for=stack-update-complete
  fi

  info "$action $stack in $region"

  local output
  if ! output="$(aws cloudformation "$action" \
        --stack-name "$stack" \
        --region "$region" \
        --template-body "file://${template}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --tags "Key=workshop,Value=${PROJECT_NAME}" \
        --parameters "$@" 2>&1)"; then
    case "$output" in
      *"No updates are to be performed"*)
        ok "$stack is already up to date"
        return 0 ;;
      *)
        printf "%s\n" "$output" >&2
        die "failed to submit $action for $stack" ;;
    esac
  fi

  info "waiting for $stack to reach a stable state (progress every 30s)..."
  if ! wait_with_progress "$wait_for" "$stack" "$region"; then
    show_recent_events "$stack" "$region"
    die "stack $stack did not complete successfully (status: $(stack_status "$stack" "$region"))"
  fi

  ok "$stack is $(stack_status "$stack" "$region")"
}

# --- config file -----------------------------------------------------------
write_config() {
  # Written 0600: it holds the database master password.
  umask 077
  cat > "$CONFIG_FILE" <<EOF
# Generated by scripts/deploy.sh on $(date -u +%FT%TZ)
# Contains the database master password -- keep this file out of version control.

PROJECT_NAME="${PROJECT_NAME}"
ACCOUNT_ID="${ACCOUNT_ID}"

PRIMARY_STACK="${PRIMARY_STACK}"
PRIMARY_REGION="${PRIMARY_REGION}"
PRIMARY_ALB_DNS="${PRIMARY_ALB_DNS}"
PRIMARY_ALB_URL="http://${PRIMARY_ALB_DNS}"
PRIMARY_ALB_SG="${PRIMARY_ALB_SG}"
PRIMARY_RDS_ARN="${PRIMARY_RDS_ARN}"
PRIMARY_RDS_ENDPOINT="${PRIMARY_RDS_ENDPOINT}"

SECONDARY_STACK="${SECONDARY_STACK}"
SECONDARY_REGION="${SECONDARY_REGION}"
SECONDARY_ALB_DNS="${SECONDARY_ALB_DNS}"
SECONDARY_ALB_URL="http://${SECONDARY_ALB_DNS}"
SECONDARY_ALB_SG="${SECONDARY_ALB_SG}"
SECONDARY_RDS_ENDPOINT="${SECONDARY_RDS_ENDPOINT}"

DB_NAME="${DB_NAME}"
DB_USERNAME="${DB_USERNAME}"
DB_PASSWORD="${DB_PASSWORD}"

# Filled in by hand after you create the distribution and health checks
# during the workshop; cleanup.sh removes whatever is listed here.
CLOUDFRONT_DISTRIBUTION_ID=""
CLOUDFRONT_URL=""
ROUTE53_HEALTH_CHECK_IDS=""

DEPLOYED_AT="$(date -u +%FT%TZ)"
ESTIMATED_HOURLY_COST="0.18"
EOF
  chmod 600 "$CONFIG_FILE"
}

# --- main ------------------------------------------------------------------
printf "\n%s%s AWS Multi-Region Resilience Workshop -- deploy %s\n" "$BOLD" "$BLUE" "$RESET"
printf "%s  account %s   primary %s   secondary %s%s\n" \
  "$DIM" "$ACCOUNT_ID" "$PRIMARY_REGION" "$SECONDARY_REGION" "$RESET"

if [ -f "$CONFIG_FILE" ]; then
  printf "\n%s! %s already exists and will be overwritten.%s\n" \
    "$YELLOW" "$CONFIG_FILE" "$RESET"
fi

resolve_password

step "Deploying PRIMARY stack to ${PRIMARY_REGION}"
info "expect roughly 10-15 minutes (RDS is the slow part)"
deploy_stack "$PRIMARY_STACK" "$PRIMARY_REGION" "${TEMPLATE_DIR}/primary.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=InstanceType,ParameterValue=${INSTANCE_TYPE}" \
  "ParameterKey=DBInstanceClass,ParameterValue=${DB_INSTANCE_CLASS}" \
  "ParameterKey=DBName,ParameterValue=${DB_NAME}" \
  "ParameterKey=DBUsername,ParameterValue=${DB_USERNAME}" \
  "ParameterKey=DBPassword,ParameterValue=${DB_PASSWORD}" \
  "ParameterKey=GitRepoURL,ParameterValue=${GIT_REPO_URL}" \
  "ParameterKey=GitBranch,ParameterValue=${GIT_BRANCH}"

PRIMARY_ALB_DNS="$(stack_output "$PRIMARY_STACK" "$PRIMARY_REGION" ALBDNSName)"
PRIMARY_ALB_SG="$(stack_output "$PRIMARY_STACK" "$PRIMARY_REGION" ALBSecurityGroupId)"
PRIMARY_RDS_ARN="$(stack_output "$PRIMARY_STACK" "$PRIMARY_REGION" RDSArn)"
PRIMARY_RDS_ENDPOINT="$(stack_output "$PRIMARY_STACK" "$PRIMARY_REGION" RDSEndpoint)"

case "$PRIMARY_RDS_ARN" in
  ''|None) die "could not read RDSArn from $PRIMARY_STACK -- the secondary stack needs it." ;;
esac
info "primary RDS ARN: ${PRIMARY_RDS_ARN}"

step "Deploying SECONDARY stack to ${SECONDARY_REGION}"
info "the cross-region read replica adds another 15-25 minutes"
deploy_stack "$SECONDARY_STACK" "$SECONDARY_REGION" "${TEMPLATE_DIR}/secondary.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=PrimaryRegion,ParameterValue=${PRIMARY_REGION}" \
  "ParameterKey=InstanceType,ParameterValue=${INSTANCE_TYPE}" \
  "ParameterKey=PilotLightSize,ParameterValue=${PILOT_LIGHT_SIZE}" \
  "ParameterKey=DBInstanceClass,ParameterValue=${DB_INSTANCE_CLASS}" \
  "ParameterKey=SourceDBInstanceArn,ParameterValue=${PRIMARY_RDS_ARN}" \
  "ParameterKey=DBName,ParameterValue=${DB_NAME}" \
  "ParameterKey=DBUsername,ParameterValue=${DB_USERNAME}" \
  "ParameterKey=DBPassword,ParameterValue=${DB_PASSWORD}" \
  "ParameterKey=GitRepoURL,ParameterValue=${GIT_REPO_URL}" \
  "ParameterKey=GitBranch,ParameterValue=${GIT_BRANCH}"

SECONDARY_ALB_DNS="$(stack_output "$SECONDARY_STACK" "$SECONDARY_REGION" ALBDNSName)"
SECONDARY_ALB_SG="$(stack_output "$SECONDARY_STACK" "$SECONDARY_REGION" ALBSecurityGroupId)"
SECONDARY_RDS_ENDPOINT="$(stack_output "$SECONDARY_STACK" "$SECONDARY_REGION" RDSReplicaEndpoint)"

step "Writing ${CONFIG_FILE}"
write_config
ok "configuration saved (mode 600)"

printf "\n%s%s Both stacks deployed! %s\n\n" "$BOLD" "$GREEN" "$RESET"
printf "  %sPrimary ALB:%s    http://%s\n" "$BOLD" "$RESET" "$PRIMARY_ALB_DNS"
printf "  %sSecondary ALB:%s  http://%s\n" "$BOLD" "$RESET" "$SECONDARY_ALB_DNS"
printf "  %sPrimary RDS:%s    %s\n" "$BOLD" "$RESET" "$PRIMARY_RDS_ENDPOINT"
printf "  %sReplica RDS:%s    %s\n" "$BOLD" "$RESET" "$SECONDARY_RDS_ENDPOINT"

printf "\n%sNext steps%s\n" "$BOLD" "$RESET"
printf "  1. Instances need a couple of minutes to finish bootstrapping.\n"
printf "  2. Watch traffic:   ./scripts/heartbeat.sh http://%s\n" "$PRIMARY_ALB_DNS"
printf "  3. Break a region:  ./scripts/chaos.sh break\n"
printf "  4. Put it back:     ./scripts/chaos.sh restore\n"
printf "  5. %sWhen finished:   ./scripts/cleanup.sh%s\n" "$YELLOW" "$RESET"
printf "\n%sThis deployment costs roughly \$0.18/hour while it runs.%s\n\n" "$YELLOW" "$RESET"
