#!/usr/bin/env bash
#
# build_and_release.sh
# ---------------------------------------------------------------------------
# Learnyst Multi-Tenant Mobile Build & Release Automation Pipeline
#
# Reads a client's white-label configuration from clients.json, stamps it
# into a dummy mobile project, "builds" an APK/AAB, and notifies a
# Slack / App Center style webhook when the build succeeds.
#
# Usage:
#   ./build_and_release.sh --client "AcademyX" --env "production" --version "2.1.0"
#
# Optional flags:
#   --mock-webhook      Do not hit the network; write the webhook payload to
#                        a file instead (useful for local/CI testing).
#   --strict-webhook     Treat a failed webhook notification as a fatal error.
#   -h | --help          Show usage.
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------------------------------------------------------
# Constants & exit codes
# --------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLIENTS_JSON="${SCRIPT_DIR}/config/clients.json"
readonly TEMPLATE_DIR="${SCRIPT_DIR}/templates/mobile-app-template"
readonly BUILDS_DIR="${SCRIPT_DIR}/builds"
readonly OUTPUT_DIR="${SCRIPT_DIR}/output"

readonly EXIT_USAGE=1
readonly EXIT_MISSING_DEP=2
readonly EXIT_CLIENT_NOT_FOUND=3
readonly EXIT_INVALID_CONFIG=4
readonly EXIT_BUILD_FAILED=5
readonly EXIT_WEBHOOK_FAILED=6

CLIENT_NAME=""
ENVIRONMENT=""
APP_VERSION=""
MOCK_WEBHOOK=false
STRICT_WEBHOOK=false
LOG_FILE=""

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    echo "${line}"
    if [[ -n "${LOG_FILE}" ]]; then
        echo "${line}" >> "${LOG_FILE}"
    fi
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

die() {
    local exit_code="$1"; shift
    error "$*"
    exit "${exit_code}"
}

# Prints the failing command + line number whenever a command fails under `set -e`.
on_error() {
    local exit_code=$?
    local line_no=$1
    error "Script aborted (exit ${exit_code}) at line ${line_no}. See log for details."
    exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") --client "<name>" --env "<production|staging>" --version "<x.y.z>" [options]

Required:
  --client   <name>       Client key as it appears in config/clients.json
  --env      <env>        Target environment (must exist under that client's "environments")
  --version  <x.y.z>       Semantic app version, used as versionName

Optional:
  --mock-webhook           Do not call the network; write the webhook payload to a file
  --strict-webhook          Exit non-zero if the release-notification webhook call fails
  -h, --help                Show this help message
EOF
}

# --------------------------------------------------------------------------
# 1. Argument parsing
# --------------------------------------------------------------------------
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit "${EXIT_USAGE}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --client)
                CLIENT_NAME="${2:-}"; shift 2 ;;
            --env)
                ENVIRONMENT="${2:-}"; shift 2 ;;
            --version)
                APP_VERSION="${2:-}"; shift 2 ;;
            --mock-webhook)
                MOCK_WEBHOOK=true; shift ;;
            --strict-webhook)
                STRICT_WEBHOOK=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "Unknown argument: $1" >&2
                usage
                exit "${EXIT_USAGE}" ;;
        esac
    done

    if [[ -z "${CLIENT_NAME}" || -z "${ENVIRONMENT}" || -z "${APP_VERSION}" ]]; then
        echo "Missing required argument(s)." >&2
        usage
        exit "${EXIT_USAGE}"
    fi

    if ! [[ "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "--version must look like a semantic version, e.g. 2.1.0 (got '${APP_VERSION}')" >&2
        exit "${EXIT_USAGE}"
    fi
}

# --------------------------------------------------------------------------
# Logging setup (so validation failures are captured too, not just the build)
# --------------------------------------------------------------------------
init_logging() {
    mkdir -p "${BUILDS_DIR}"
    local date_stamp
    date_stamp="$(date '+%Y-%m-%d')"
    LOG_FILE="${BUILDS_DIR}/${date_stamp}_${CLIENT_NAME}.log"
    : > "${LOG_FILE}"
    info "Log file: ${LOG_FILE}"
}

# --------------------------------------------------------------------------
# 2. Prerequisite checks
# --------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites..."
    local missing=()

    for cmd in git curl jq; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if [[ ! -f "${CLIENTS_JSON}" ]]; then
        die "${EXIT_MISSING_DEP}" "Client config file not found at ${CLIENTS_JSON}"
    fi

    if [[ ! -d "${TEMPLATE_DIR}" ]]; then
        die "${EXIT_MISSING_DEP}" "Mobile project template not found at ${TEMPLATE_DIR}"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "${EXIT_MISSING_DEP}" "Missing required build dependencies: ${missing[*]}. Please install them and re-run."
    fi

    info "All prerequisites satisfied (git, curl, jq available)."
}

# --------------------------------------------------------------------------
# 3. Read & validate client configuration
# --------------------------------------------------------------------------
CLIENT_JSON=""     # holds the resolved client object as JSON
APP_NAME=""
BUNDLE_ID=""
THEME_COLOR=""
LOGO_PATH=""
WEBHOOK_URL=""
API_BASE_URL=""

validate_client_config() {
    info "Looking up configuration for client '${CLIENT_NAME}'..."

    CLIENT_JSON="$(jq -c --arg name "${CLIENT_NAME}" \
        '.clients[] | select(.name == $name)' "${CLIENTS_JSON}")"

    if [[ -z "${CLIENT_JSON}" ]]; then
        die "${EXIT_CLIENT_NOT_FOUND}" "No client named '${CLIENT_NAME}' found in ${CLIENTS_JSON}"
    fi

    # Environment must exist for this client
    local env_exists
    env_exists="$(echo "${CLIENT_JSON}" | jq --arg env "${ENVIRONMENT}" 'has("environments") and (.environments | has($env))')"
    if [[ "${env_exists}" != "true" ]]; then
        die "${EXIT_CLIENT_NOT_FOUND}" "Environment '${ENVIRONMENT}' is not configured for client '${CLIENT_NAME}'"
    fi

    # Required top-level fields. Missing OR empty string counts as invalid.
    local required_fields=("app_name" "bundle_id" "theme_color" "logo_path" "webhook_url")
    local field value
    for field in "${required_fields[@]}"; do
        value="$(echo "${CLIENT_JSON}" | jq -r --arg f "${field}" '.[$f] // empty')"
        if [[ -z "${value}" ]]; then
            die "${EXIT_INVALID_CONFIG}" "Client '${CLIENT_NAME}' is missing required config value: '${field}'"
        fi
    done

    API_BASE_URL="$(echo "${CLIENT_JSON}" | jq -r --arg env "${ENVIRONMENT}" '.environments[$env].api_base_url // empty')"
    if [[ -z "${API_BASE_URL}" ]]; then
        die "${EXIT_INVALID_CONFIG}" "Client '${CLIENT_NAME}' is missing 'api_base_url' for environment '${ENVIRONMENT}'"
    fi

    APP_NAME="$(echo "${CLIENT_JSON}" | jq -r '.app_name')"
    BUNDLE_ID="$(echo "${CLIENT_JSON}" | jq -r '.bundle_id')"
    THEME_COLOR="$(echo "${CLIENT_JSON}" | jq -r '.theme_color')"
    LOGO_PATH="$(echo "${CLIENT_JSON}" | jq -r '.logo_path')"
    WEBHOOK_URL="$(echo "${CLIENT_JSON}" | jq -r '.webhook_url')"

    info "Config OK -> app_name='${APP_NAME}' bundle_id='${BUNDLE_ID}' api_base_url='${API_BASE_URL}'"
}

# --------------------------------------------------------------------------
# 4. Prepare workspace: copy template, stamp in client values
# --------------------------------------------------------------------------
WORKSPACE_DIR=""

prepare_workspace() {
    local slug="${CLIENT_NAME}_${ENVIRONMENT}_${APP_VERSION}"
    WORKSPACE_DIR="${OUTPUT_DIR}/${slug}"

    info "Preparing build workspace at ${WORKSPACE_DIR}"
    rm -rf "${WORKSPACE_DIR}"
    mkdir -p "${WORKSPACE_DIR}"
    cp -R "${TEMPLATE_DIR}/." "${WORKSPACE_DIR}/"

    # versionCode: derive a monotonically increasing-ish integer from the
    # semantic version (major*10000 + minor*100 + patch), fine for a dummy pipeline.
    IFS='.' read -r maj min patch <<< "${APP_VERSION}"
    local version_code=$(( maj * 10000 + min * 100 + patch ))

    info "Stamping client configuration into project files..."
    local file
    while IFS= read -r -d '' file; do
        sed -i \
            -e "s|__APP_NAME__|${APP_NAME}|g" \
            -e "s|__BUNDLE_ID__|${BUNDLE_ID}|g" \
            -e "s|__API_BASE_URL__|${API_BASE_URL}|g" \
            -e "s|__THEME_COLOR__|${THEME_COLOR}|g" \
            -e "s|__LOGO_PATH__|${LOGO_PATH}|g" \
            -e "s|__VERSION__|${APP_VERSION}|g" \
            -e "s|__VERSION_CODE__|${version_code}|g" \
            "${file}"
    done < <(find "${WORKSPACE_DIR}" -type f -print0)

    # Sanity check: no placeholder tokens should remain
    if grep -R "__[A-Z_]*__" "${WORKSPACE_DIR}" >/dev/null 2>&1; then
        die "${EXIT_INVALID_CONFIG}" "Unresolved placeholder(s) left in project files. Check clients.json for missing fields."
    fi

    info "Workspace ready: bundle ID, app name, API endpoint, and theme color applied."
}

# --------------------------------------------------------------------------
# 5. Simulate the Android build
# --------------------------------------------------------------------------
APK_PATH=""
AAB_PATH=""
BUILD_ID=""

simulate_build() {
    BUILD_ID="$(date '+%Y%m%d%H%M%S')-${CLIENT_NAME}"

    info "===== Starting build ${BUILD_ID} ====="
    info "Client:      ${CLIENT_NAME}"
    info "Environment: ${ENVIRONMENT}"
    info "Version:     ${APP_VERSION}"

    info "[1/5] Cleaning previous build artifacts..."
    sleep 0.2

    info "[2/5] Resolving dependencies for ${BUNDLE_ID}..."
    sleep 0.2

    info "[3/5] Compiling sources against ${API_BASE_URL}..."
    sleep 0.2

    info "[4/5] Applying theme color ${THEME_COLOR} and branding assets (${LOGO_PATH})..."
    sleep 0.2

    info "[5/5] Packaging release artifacts..."
    APK_PATH="${WORKSPACE_DIR}/${CLIENT_NAME}-${APP_VERSION}-${ENVIRONMENT}.apk"
    AAB_PATH="${WORKSPACE_DIR}/${CLIENT_NAME}-${APP_VERSION}-${ENVIRONMENT}.aab"

    {
        echo "DUMMY APK ARTIFACT"
        echo "client=${CLIENT_NAME}"
        echo "bundle_id=${BUNDLE_ID}"
        echo "version=${APP_VERSION}"
        echo "env=${ENVIRONMENT}"
        echo "built_at=$(date -Iseconds)"
    } > "${APK_PATH}"

    {
        echo "DUMMY AAB ARTIFACT"
        echo "client=${CLIENT_NAME}"
        echo "bundle_id=${BUNDLE_ID}"
        echo "version=${APP_VERSION}"
        echo "env=${ENVIRONMENT}"
        echo "built_at=$(date -Iseconds)"
    } > "${AAB_PATH}"

    if [[ ! -s "${APK_PATH}" || ! -s "${AAB_PATH}" ]]; then
        die "${EXIT_BUILD_FAILED}" "Build artifacts were not produced correctly."
    fi

    local apk_checksum
    apk_checksum="$(sha256sum "${APK_PATH}" | awk '{print $1}')"

    info "Build succeeded."
    info "APK: ${APK_PATH}"
    info "AAB: ${AAB_PATH}"
    info "APK SHA256: ${apk_checksum}"
    info "===== Build ${BUILD_ID} complete ====="
}

# --------------------------------------------------------------------------
# 6. Notify webhook (Slack / App Center style)
# --------------------------------------------------------------------------
notify_webhook() {
    local payload
    payload=$(jq -n \
        --arg client "${CLIENT_NAME}" \
        --arg env "${ENVIRONMENT}" \
        --arg version "${APP_VERSION}" \
        --arg build_id "${BUILD_ID}" \
        --arg apk "${APK_PATH}" \
        --arg aab "${AAB_PATH}" \
        --arg ts "$(date -Iseconds)" \
        '{
            text: ("✅ Build succeeded for " + $client + " (" + $env + ") v" + $version),
            client: $client,
            environment: $env,
            version: $version,
            build_id: $build_id,
            artifacts: { apk: $apk, aab: $aab },
            timestamp: $ts
        }')

    if [[ "${MOCK_WEBHOOK}" == "true" ]]; then
        local mock_path="${WORKSPACE_DIR}/webhook_payload.json"
        echo "${payload}" | jq '.' > "${mock_path}"
        info "MOCK_WEBHOOK enabled - payload written to ${mock_path} (no network call made)."
        return 0
    fi

    info "Notifying webhook at ${WEBHOOK_URL}..."
    local http_status
    set +e
    http_status="$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 10 \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "${payload}" \
        "${WEBHOOK_URL}")"
    local curl_exit=$?
    set -e

    if [[ ${curl_exit} -ne 0 ]]; then
        warn "Webhook call failed to execute (curl exit code ${curl_exit})."
        if [[ "${STRICT_WEBHOOK}" == "true" ]]; then
            die "${EXIT_WEBHOOK_FAILED}" "Aborting due to --strict-webhook."
        fi
        return 0
    fi

    if [[ "${http_status}" =~ ^2[0-9][0-9]$ ]]; then
        info "Webhook notified successfully (HTTP ${http_status})."
    else
        warn "Webhook responded with HTTP ${http_status}."
        if [[ "${STRICT_WEBHOOK}" == "true" ]]; then
            die "${EXIT_WEBHOOK_FAILED}" "Aborting due to --strict-webhook."
        fi
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_logging
    check_prerequisites
    validate_client_config
    prepare_workspace
    simulate_build
    notify_webhook
    info "Release pipeline finished for ${CLIENT_NAME} (${ENVIRONMENT}) v${APP_VERSION}."
}

main "$@"
