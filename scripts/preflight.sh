#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# preflight.sh -- validate that this account can run the resilience workshop.
#
# Run this BEFORE deploying anything. Every check is read-only; nothing here
# creates, modifies or deletes AWS resources.
#
#   ./scripts/preflight.sh
#
# Environment overrides:
#   PRIMARY_REGION   (default us-east-1)
#   SECONDARY_REGION (default us-west-2)
#   PROJECT_NAME     (default resilience-workshop)
# ---------------------------------------------------------------------------
set -euo pipefail

PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
PROJECT_NAME="${PROJECT_NAME:-resilience-workshop}"

# Instances clone this at boot. Keep the default identical to deploy.sh so the
# check reflects what an unmodified deployment would actually use.
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/Nik-1019/aws-multi-region-resilience-workshop.git}"

PRIMARY_STACK="${PROJECT_NAME}-primary"
SECONDARY_STACK="${PROJECT_NAME}-secondary"

# Service Quotas codes (stable across regions).
QUOTA_VPC_PER_REGION="L-F678F1CE"
QUOTA_EIP_PER_REGION="L-0263D0A3"

# --- presentation ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

MARK_PASS="${GREEN}✔${RESET}"
MARK_FAIL="${RED}✘${RESET}"
MARK_WARN="${YELLOW}!${RESET}"

# Results accumulate as "STATUS<TAB>CHECK<TAB>DETAIL<TAB>FIX" (bash 3.2 safe).
RESULTS=()
FAIL_COUNT=0
WARN_COUNT=0

record() {
  # record <PASS|FAIL|WARN> <check> <detail> [fix]
  RESULTS[${#RESULTS[@]}]="$1	$2	$3	${4:-}"
  case "$1" in
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
}

step() { printf "  %s%s%s\n" "$DIM" "$1" "$RESET"; }

header() {
  printf "\n%s%s AWS Resilience Workshop -- Pre-Flight Checks %s\n" "$BOLD" "$BLUE" "$RESET"
  printf "%s  regions: %s, %s   project: %s%s\n\n" \
    "$DIM" "$PRIMARY_REGION" "$SECONDARY_REGION" "$PROJECT_NAME" "$RESET"
}

# --- checks ----------------------------------------------------------------

check_cli() {
  step "checking AWS CLI..."
  if ! command -v aws >/dev/null 2>&1; then
    record FAIL "AWS CLI installed" "aws not found in PATH" \
      "Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    return 1
  fi
  local version
  version="$(aws --version 2>&1 | awk '{print $1}')"
  case "$version" in
    aws-cli/2.*) record PASS "AWS CLI installed" "$version" ;;
    aws-cli/1.*) record WARN "AWS CLI installed" "$version (v2 recommended)" \
                   "Upgrade to AWS CLI v2 for consistent output formatting." ;;
    *)           record PASS "AWS CLI installed" "$version" ;;
  esac
  return 0
}

check_dependencies() {
  step "checking local tooling..."
  local missing=""
  for tool in curl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    record FAIL "Required tools present" "missing:$missing" \
      "Install with your package manager (brew install$missing / dnf install$missing)."
  else
    record PASS "Required tools present" "curl found"
  fi
  if command -v jq >/dev/null 2>&1; then
    record PASS "jq available (optional)" "$(jq --version 2>/dev/null)"
  else
    record WARN "jq available (optional)" "not installed" \
      "heartbeat.sh falls back to a slower parser. brew install jq / dnf install jq"
  fi
}

check_credentials() {
  step "checking AWS credentials..."
  local identity
  if ! identity="$(aws sts get-caller-identity --output text \
                     --query '[Account,Arn]' 2>&1)"; then
    record FAIL "AWS credentials configured" "sts:GetCallerIdentity failed" \
      "Run 'aws configure' or export AWS_PROFILE / AWS_ACCESS_KEY_ID."
    return 1
  fi
  ACCOUNT_ID="$(printf '%s' "$identity" | awk '{print $1}')"
  local arn
  arn="$(printf '%s' "$identity" | awk '{print $2}')"
  record PASS "AWS credentials configured" "account $ACCOUNT_ID (${arn##*/})"
  return 0
}

check_permissions() {
  step "checking EC2 permissions (dry run)..."
  local output=""
  # A dry-run that is *allowed* returns the DryRunOperation error; a denial
  # returns UnauthorizedOperation. Both exit non-zero, so inspect the message.
  output="$(aws ec2 create-tags --region "$PRIMARY_REGION" --dry-run \
              --resources vpc-00000000000000000 \
              --tags Key=preflight,Value=1 2>&1 || true)"
  case "$output" in
    *DryRunOperation*|*InvalidVpcID*)
      record PASS "EC2 write permission" "dry-run accepted" ;;
    *UnauthorizedOperation*|*AccessDenied*)
      record FAIL "EC2 write permission" "UnauthorizedOperation" \
        "Attach a policy allowing ec2:*, elasticloadbalancing:*, autoscaling:*, rds:*, iam:PassRole." ;;
    *)
      record WARN "EC2 write permission" "inconclusive response" \
        "Could not classify the dry-run result; deployment may still fail on permissions." ;;
  esac

  step "checking CloudFormation permissions..."
  if aws cloudformation list-stacks --region "$PRIMARY_REGION" \
       --max-items 1 >/dev/null 2>&1; then
    record PASS "CloudFormation access" "list-stacks succeeded"
  else
    record FAIL "CloudFormation access" "list-stacks denied" \
      "Grant cloudformation:* in $PRIMARY_REGION and $SECONDARY_REGION."
  fi

  step "checking RDS permissions..."
  if aws rds describe-db-instances --region "$PRIMARY_REGION" \
       --max-records 20 >/dev/null 2>&1; then
    record PASS "RDS access" "describe-db-instances succeeded"
  else
    record FAIL "RDS access" "describe-db-instances denied" \
      "Grant rds:* -- the workshop creates a database and a cross-region replica."
  fi
}

check_regions() {
  step "checking both regions are enabled..."
  local enabled
  if ! enabled="$(aws ec2 describe-regions \
                    --region-names "$PRIMARY_REGION" "$SECONDARY_REGION" \
                    --query 'Regions[].RegionName' --output text \
                    --region "$PRIMARY_REGION" 2>&1)"; then
    record FAIL "Both regions enabled" "describe-regions failed" \
      "Enable $PRIMARY_REGION and $SECONDARY_REGION in Account Settings > AWS Regions."
    return
  fi
  # --output text separates list values with TABs, so normalise to spaces
  # before matching -- otherwise " us-east-1 " never matches.
  enabled="$(printf '%s' "$enabled" | tr '\t\n' '  ')"

  local found=0
  for want in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
    case " $enabled " in
      *" $want "*) found=$((found + 1)) ;;
      *) record FAIL "Region $want enabled" "not returned by describe-regions" \
           "Enable $want: AWS console > Account > AWS Regions > Enable." ;;
    esac
  done
  if [ "$found" -eq 2 ]; then
    record PASS "Both regions enabled" "$PRIMARY_REGION, $SECONDARY_REGION"
  fi
}

check_git_repo() {
  # The only failure that yields a CREATE_COMPLETE stack serving nothing: the
  # ASG has no wait condition, so a repo the instances cannot clone still
  # reports a perfectly green deploy behind an ALB returning 503.
  step "checking the application repository is reachable..."
  local url="$GIT_REPO_URL" probe code

  case "$url" in
    *example/aws-resilience-workshop*|*://example.com/*)
      record FAIL "App repo reachable" "still the placeholder URL" \
        "EC2 instances clone this at boot. Deploy your own fork: GIT_REPO_URL=https://github.com/<you>/<repo>.git ./scripts/deploy.sh"
      return ;;
  esac

  case "$url" in
    http://*|https://*) ;;
    *)
      record WARN "App repo reachable" "cannot probe non-HTTP URL" \
        "Instances clone anonymously and have no SSH key. Verify: git ls-remote $url"
      return ;;
  esac

  # Probe git's smart-HTTP endpoint rather than the web page: it answers 200
  # only when an anonymous clone would actually succeed. Must be a GET -- HEAD
  # returns 405 on GitHub.
  probe="${url%.git}.git/info/refs?service=git-upload-pack"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -L "$probe" 2>/dev/null || echo 000)"

  case "$code" in
    200)
      record PASS "App repo reachable" "anonymous clone confirmed" ;;
    401|403|404)
      record FAIL "App repo reachable" "HTTP $code - private, or does not exist" \
        "Instances clone anonymously over the NAT gateway. Make the repo public, or the stack deploys green and serves nothing." ;;
    000)
      record FAIL "App repo reachable" "no response within 5s" \
        "Check the URL and your connectivity: curl -sv $probe" ;;
    *)
      record WARN "App repo reachable" "unexpected HTTP $code" \
        "Verify manually: git ls-remote $url" ;;
  esac
}

quota_value() {
  # quota_value <region> <service-code> <quota-code> ; echoes a number or ""
  aws service-quotas get-service-quota \
    --region "$1" --service-code "$2" --quota-code "$3" \
    --query 'Quota.Value' --output text 2>/dev/null || true
}

check_vpc_quota() {
  local region="$1" used limit
  step "checking VPC quota in $region..."
  if ! used="$(aws ec2 describe-vpcs --region "$region" \
                 --query 'length(Vpcs)' --output text 2>/dev/null)"; then
    record WARN "VPC quota ($region)" "could not list VPCs" \
      "Grant ec2:DescribeVpcs, or verify the quota manually."
    return
  fi
  limit="$(quota_value "$region" vpc "$QUOTA_VPC_PER_REGION")"
  case "$limit" in ''|None|*[!0-9.]*) limit=5 ;; esac
  limit="${limit%%.*}"

  if [ "$used" -lt "$limit" ]; then
    record PASS "VPC quota ($region)" "$used/$limit used, room for 1 more"
  else
    record FAIL "VPC quota ($region)" "$used/$limit used" \
      "Delete an unused VPC in $region or request a quota increase (quota $QUOTA_VPC_PER_REGION)."
  fi
}

check_eip_quota() {
  local region="$1" used limit
  step "checking Elastic IP quota in $region..."
  if ! used="$(aws ec2 describe-addresses --region "$region" \
                 --query 'length(Addresses)' --output text 2>/dev/null)"; then
    record WARN "EIP quota ($region)" "could not list addresses" \
      "Grant ec2:DescribeAddresses, or verify the quota manually."
    return
  fi
  limit="$(quota_value "$region" ec2 "$QUOTA_EIP_PER_REGION")"
  case "$limit" in ''|None|*[!0-9.]*) limit=5 ;; esac
  limit="${limit%%.*}"

  # The stack needs exactly one EIP for its NAT Gateway.
  if [ "$used" -lt "$limit" ]; then
    record PASS "EIP quota ($region)" "$used/$limit used, room for the NAT gateway"
  else
    record FAIL "EIP quota ($region)" "$used/$limit used, NAT gateway needs 1" \
      "Release an unused Elastic IP in $region or raise quota $QUOTA_EIP_PER_REGION."
  fi
}

check_stack_absent() {
  local stack="$1" region="$2" status
  step "checking for an existing $stack stack in $region..."
  status="$(aws cloudformation describe-stacks --stack-name "$stack" \
              --region "$region" --query 'Stacks[0].StackStatus' \
              --output text 2>/dev/null || true)"
  case "$status" in
    ""|None)
      record PASS "No conflicting stack ($stack)" "not present in $region" ;;
    DELETE_COMPLETE)
      record PASS "No conflicting stack ($stack)" "previous stack deleted" ;;
    ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
      record FAIL "No conflicting stack ($stack)" "exists in $status" \
        "Delete it first: aws cloudformation delete-stack --stack-name $stack --region $region" ;;
    *)
      record FAIL "No conflicting stack ($stack)" "already exists ($status)" \
        "Run ./scripts/cleanup.sh, or set PROJECT_NAME to a different prefix." ;;
  esac
}

# --- report ----------------------------------------------------------------

print_table() {
  local width=78
  local line
  line="$(printf '%*s' "$width" '' | tr ' ' '-')"

  printf "\n  %s\n" "$line"
  printf "  %s%-4s %-34s %s%s\n" "$BOLD" "" "CHECK" "RESULT" "$RESET"
  printf "  %s\n" "$line"

  local entry status check detail fix mark
  for entry in "${RESULTS[@]}"; do
    status="${entry%%	*}"
    entry="${entry#*	}"
    check="${entry%%	*}"
    entry="${entry#*	}"
    detail="${entry%%	*}"
    fix="${entry#*	}"

    case "$status" in
      PASS) mark="$MARK_PASS" ;;
      FAIL) mark="$MARK_FAIL" ;;
      *)    mark="$MARK_WARN" ;;
    esac

    printf "  [%s]  %-34s %s\n" "$mark" "$check" "$detail"
    if [ -n "$fix" ] && [ "$status" != "PASS" ]; then
      printf "       %s-> %s%s\n" "$DIM" "$fix" "$RESET"
    fi
  done
  printf "  %s\n" "$line"
}

print_summary() {
  local total="${#RESULTS[@]}"
  local passed=$((total - FAIL_COUNT - WARN_COUNT))

  printf "\n  %d checks: %s%d passed%s" "$total" "$GREEN" "$passed" "$RESET"
  [ "$WARN_COUNT" -gt 0 ] && printf ", %s%d warning(s)%s" "$YELLOW" "$WARN_COUNT" "$RESET" || true
  [ "$FAIL_COUNT" -gt 0 ] && printf ", %s%d failed%s" "$RED" "$FAIL_COUNT" "$RESET" || true
  printf "\n\n"

  if [ "$FAIL_COUNT" -eq 0 ]; then
    printf "  %s%sReady to deploy!%s  Next: ./scripts/deploy.sh\n\n" \
      "$BOLD" "$GREEN" "$RESET"
    return 0
  fi

  printf "  %s%sFix %d issue(s) before proceeding.%s\n\n" \
    "$BOLD" "$RED" "$FAIL_COUNT" "$RESET"
  return 1
}

# --- main ------------------------------------------------------------------

main() {
  header

  # Without the CLI or credentials every later check is meaningless -- report
  # what we have and stop rather than printing a wall of cascading failures.
  if ! check_cli; then
    print_table
    print_summary || true
    exit 1
  fi

  check_dependencies

  if ! check_credentials; then
    print_table
    print_summary || true
    exit 1
  fi

  check_permissions
  check_regions
  check_git_repo

  for region in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
    check_vpc_quota "$region"
    check_eip_quota "$region"
  done

  check_stack_absent "$PRIMARY_STACK" "$PRIMARY_REGION"
  check_stack_absent "$SECONDARY_STACK" "$SECONDARY_REGION"

  print_table
  print_summary
}

main "$@"
