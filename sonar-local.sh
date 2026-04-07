#!/usr/bin/env bash
# sonar-local.sh — Stand up SonarQube locally via Docker and scan a project.
#
# Usage:
#   ./sonar-local.sh [OPTIONS]
#
# Options:
#   -d, --dir <path>      Path to the project directory to scan (required for scanning)
#   -n, --name <name>     Project key / display name (defaults to the directory basename)
#   -p, --port <port>     Port to expose SonarQube on (default: 9000)
#   --skip-start          Skip starting Docker Compose (use an already-running instance)
#   --skip-scan           Start SonarQube only; do not run the scanner
#   --down                Stop and remove the SonarQube containers, then exit
#   -h, --help            Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SONAR_PORT=9000
PROJECT_DIR=""
PROJECT_NAME=""
SKIP_START=false
SKIP_SCAN=false
BRING_DOWN=false

COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-compose.yml"
SONAR_BASE_URL=""           # set after port is resolved
ADMIN_USER="admin"
ADMIN_DEFAULT_PASS="admin"
ADMIN_PASS=""               # generated at runtime

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "$(green "INFO") $*"; }
warn() { log "$(yellow "WARN") $*"; }
die()  { log "$(red "ERROR") $*" >&2; exit 1; }

usage() {
  # Print only the top header comment block (lines 2..first blank/non-comment line)
  awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"
  exit 0
}

generate_password() {
  # Generate a random 20-character alphanumeric password
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found. Please install it first."
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)    PROJECT_DIR="${2:?"--dir requires a path argument"}";  shift 2 ;;
      -n|--name)   PROJECT_NAME="${2:?"--name requires a name argument"}"; shift 2 ;;
      -p|--port)   SONAR_PORT="${2:?"--port requires a port number"}";    shift 2 ;;
      --skip-start) SKIP_START=true; shift ;;
      --skip-scan)  SKIP_SCAN=true;  shift ;;
      --down)       BRING_DOWN=true; shift ;;
      -h|--help)    usage ;;
      *) die "Unknown option: $1. Run with -h for help." ;;
    esac
  done

  SONAR_BASE_URL="http://localhost:${SONAR_PORT}"

  if [[ "$BRING_DOWN" == "false" && "$SKIP_SCAN" == "false" && -z "$PROJECT_DIR" ]]; then
    die "No project directory specified. Use -d <path> or --skip-scan to skip scanning."
  fi

  if [[ -n "$PROJECT_DIR" && ! -d "$PROJECT_DIR" ]]; then
    die "Project directory does not exist: $PROJECT_DIR"
  fi

  if [[ -z "$PROJECT_NAME" && -n "$PROJECT_DIR" ]]; then
    PROJECT_NAME="$(basename "$(cd "$PROJECT_DIR" && pwd)")"
  fi
}

# ---------------------------------------------------------------------------
# Docker / Compose helpers
# ---------------------------------------------------------------------------
compose_cmd() {
  # Support both "docker compose" (v2) and "docker-compose" (v1)
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    die "Neither 'docker compose' (v2) nor 'docker-compose' (v1) is available."
  fi
}

bring_down() {
  info "Stopping SonarQube containers..."
  SONAR_PORT="$SONAR_PORT" compose_cmd down
  green "SonarQube containers stopped."
  exit 0
}

start_sonarqube() {
  info "Starting SonarQube on port ${SONAR_PORT}..."
  SONAR_PORT="$SONAR_PORT" compose_cmd up -d
}

wait_for_sonarqube() {
  info "Waiting for SonarQube to become ready (this may take a minute)..."
  local max_wait=180
  local elapsed=0
  local interval=5

  until curl -sf "${SONAR_BASE_URL}/api/system/status" | grep -q '"status":"UP"'; do
    if [[ $elapsed -ge $max_wait ]]; then
      die "SonarQube did not become ready within ${max_wait}s. Check logs with: docker logs sonarqube"
    fi
    printf '.'
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  printf '\n'
  info "SonarQube is up!"
}

# ---------------------------------------------------------------------------
# SonarQube API helpers (all calls authenticated as admin)
# ---------------------------------------------------------------------------
sonar_api() {
  # sonar_api <method> <path> [extra curl args...]
  local method="$1"; shift
  local path="$1";   shift
  curl -sf -X "$method" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SONAR_BASE_URL}${path}" \
    "$@"
}

change_default_password() {
  info "Checking whether the default admin password needs to be changed..."

  # /api/authentication/validate always returns HTTP 200; validity is in the body.
  # Check whether admin:admin (the factory default) is still active.
  local default_valid
  default_valid=$(curl -s \
    -u "${ADMIN_USER}:${ADMIN_DEFAULT_PASS}" \
    "${SONAR_BASE_URL}/api/authentication/validate" | grep -o '"valid":true' || true)

  if [[ "$default_valid" == '"valid":true' ]]; then
    ADMIN_PASS="$(generate_password)"
    info "Rotating default admin password..."
    curl -sf -X POST \
      -u "${ADMIN_USER}:${ADMIN_DEFAULT_PASS}" \
      "${SONAR_BASE_URL}/api/users/change_password" \
      --data-urlencode "login=${ADMIN_USER}" \
      --data-urlencode "password=${ADMIN_PASS}" \
      --data-urlencode "previousPassword=${ADMIN_DEFAULT_PASS}" \
      >/dev/null
    info "Admin password rotated successfully."
    return
  fi

  # Default password no longer works — use SONAR_ADMIN_PASSWORD env var or prompt.
  if [[ -n "${SONAR_ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASS="$SONAR_ADMIN_PASSWORD"
    info "Using admin password from SONAR_ADMIN_PASSWORD environment variable."
  else
    warn "Default admin password has already been changed."
    printf "Enter the current admin password: "
    read -r -s ADMIN_PASS
    printf '\n'
  fi

  # Validate the supplied password immediately so we fail fast.
  local valid
  valid=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SONAR_BASE_URL}/api/authentication/validate" | grep -o '"valid":true' || true)
  [[ "$valid" == '"valid":true' ]] || die "Admin credentials are invalid. Aborting."
  info "Admin credentials validated."
}

ensure_project() {
  info "Ensuring project '${PROJECT_NAME}' exists..."

  local exists
  exists=$(sonar_api GET "/api/projects/search?projects=${PROJECT_NAME}" \
    | grep -o "\"key\":\"${PROJECT_NAME}\"" || true)

  if [[ -z "$exists" ]]; then
    info "Creating project '${PROJECT_NAME}'..."
    sonar_api POST "/api/projects/create" \
      --data-urlencode "project=${PROJECT_NAME}" \
      --data-urlencode "name=${PROJECT_NAME}" \
      --data-urlencode "visibility=private" \
      >/dev/null
    info "Project created."
  else
    info "Project already exists."
  fi
}

create_token() {
  # Returns the token value via stdout
  local token_name
  token_name="${PROJECT_NAME}-ci-$(date +%s)"
  info "Creating analysis token '${token_name}'..."
  local response
  response=$(sonar_api POST "/api/user_tokens/generate" \
    --data-urlencode "name=${token_name}" \
    --data-urlencode "type=PROJECT_ANALYSIS_TOKEN" \
    --data-urlencode "projectKey=${PROJECT_NAME}")

  local token
  if command -v jq >/dev/null 2>&1; then
    token=$(printf '%s' "$response" | jq -r '.token')
  else
    token=$(printf '%s' "$response" | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')
  fi

  [[ -n "$token" ]] || die "Failed to extract analysis token from API response."
  printf '%s' "$token"
}

# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------
run_scanner() {
  local token="$1"
  local abs_dir
  abs_dir="$(cd "$PROJECT_DIR" && pwd)"

  info "Running sonar-scanner on '${abs_dir}'..."

  # Use the official sonar-scanner-cli Docker image so no local install needed.
  docker run --rm \
    --network host \
    -v "${abs_dir}:/usr/src" \
    sonarsource/sonar-scanner-cli \
    -Dsonar.projectKey="${PROJECT_NAME}" \
    -Dsonar.projectName="${PROJECT_NAME}" \
    -Dsonar.sources=/usr/src \
    -Dsonar.host.url="${SONAR_BASE_URL}" \
    -Dsonar.token="${token}"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local token="$1"
  echo ""
  bold "============================================================"
  bold " SonarQube Local — Summary"
  bold "============================================================"
  printf "  %-22s %s\n" "SonarQube URL:"    "${SONAR_BASE_URL}"
  printf "  %-22s %s\n" "Admin username:"   "${ADMIN_USER}"
  printf "  %-22s %s\n" "Admin password:"   "${ADMIN_PASS}"
  if [[ -n "$token" ]]; then
    printf "  %-22s %s\n" "Project key:"    "${PROJECT_NAME}"
    printf "  %-22s %s\n" "Analysis token:" "${token}"
  fi
  bold "============================================================"
  echo ""
  if [[ -n "$token" ]]; then
    green "View results: ${SONAR_BASE_URL}/dashboard?id=${PROJECT_NAME}"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  require_command curl
  require_command docker

  if [[ "$BRING_DOWN" == "true" ]]; then
    bring_down
  fi

  if [[ "$SKIP_START" == "false" ]]; then
    start_sonarqube
  fi

  wait_for_sonarqube
  change_default_password

  local scan_token=""

  if [[ "$SKIP_SCAN" == "false" ]]; then
    ensure_project
    scan_token="$(create_token)"
    run_scanner "$scan_token"
  fi

  print_summary "$scan_token"
}

main "$@"
