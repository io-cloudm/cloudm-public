#!/usr/bin/env bash
#
# Performs GCP project, service account and API configuration for CloudM Migrate.
#
# Bash / Google Cloud Shell equivalent of the PowerShell setup script.
# Creates or selects a GCP project, creates a service account and JSON key,
# grants roles/owner on the project, and enables the GCP APIs required by the
# chosen scope. Finishes by printing the domain-wide delegation step that
# still has to be done by hand.
#
# Designed to run in Google Cloud Shell, where gcloud is already installed and
# authenticated. It also runs on any Linux or macOS machine with the gcloud CLI
# installed and initialised.
#
# Usage:
#   ./gcp_configuration.sh PROJECT_ID SERVICE_ACCOUNT_ID SCOPE [OUTPUT_PATH]
#
# Examples:
#   ./gcp_configuration.sh test-cloudm-io-migrate test-service-account-1 Standard
#   ./gcp_configuration.sh test-cloudm-io-migrate test-service-account-1 Vault
#   ./gcp_configuration.sh test-cloudm-io-migrate test-service-account-1 Standard ~/gcpconfig
#   ./gcp_configuration.sh --dry-run my-project-id my-service-acct All
#
# Key format: this script produces a JSON key. In CloudM Migrate set the Google
# authentication method to JSON (not P12) on the connection that uses it.

set -euo pipefail

# Never let gcloud block waiting for input. Some reads, notably the org policy
# check, will otherwise prompt to enable an API and retry, and because that
# prompt is written to stderr which we discard, the script would appear to hang
# with no visible question. Declining the default is the behaviour we want:
# the call fails, and the caller treats the failure as "could not determine".
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

readonly DEFAULT_OUTPUT_PATH="${HOME}/cloudm/gcpconfig"
readonly ID_PATTERN='^[a-z][a-z0-9-]{4,28}[a-z0-9]$'
readonly VALID_SCOPES=(All Standard SourceLimited DestinationLimited Vault Storage)
readonly OWNER_ROLE="roles/owner"
readonly POLL_TIMEOUT_SECONDS=180
readonly POLL_INTERVAL_SECONDS=5

PROJECT_ID=""
SERVICE_ACCOUNT_ID=""
SCOPE="Standard"
OUTPUT_PATH="${DEFAULT_OUTPUT_PATH}"
DRY_RUN=false
INCLUDE_CHAT=false
LOG_PATH=""

# Values discovered as the script runs. Set as globals rather than returned so
# that the log output of a function is never captured as its return value.
PROJECT_NUMBER=""
SERVICE_ACCOUNT_EMAIL=""
SERVICE_ACCOUNT_CLIENT_ID=""
SERVICE_ACCOUNT_KEY_PATH=""

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    readonly C_HIGHLIGHT=$'\033[30;43m'
    readonly C_ERROR=$'\033[31m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_HIGHLIGHT=""
    readonly C_ERROR=""
    readonly C_RESET=""
fi

write_log() {
    local message="$1"
    local highlight="${2:-false}"

    if [[ -n "${LOG_PATH}" ]]; then
        printf '[%s] - %s\n' "$(date '+%d/%m/%Y %H:%M:%S')" "${message}" >>"${LOG_PATH}"
    fi

    if [[ "${highlight}" == "true" ]]; then
        printf '%s%s%s\n' "${C_HIGHLIGHT}" "${message}" "${C_RESET}"
    else
        printf '%s\n' "${message}"
    fi
}

fail() {
    local message="$1"

    if [[ -n "${LOG_PATH}" ]]; then
        printf '[%s] - ERROR: %s\n' "$(date '+%d/%m/%Y %H:%M:%S')" "${message}" >>"${LOG_PATH}"
    fi

    printf '%s%s%s\n' "${C_ERROR}" "ERROR: ${message}" "${C_RESET}" >&2
    exit 1
}

blank_line() {
    printf '\n'
}

# Emits an OSC 8 terminal hyperlink, which attaches a long url to a short piece
# of clickable text. Needed because the delegation url runs to about 1,500
# characters, and a url that wraps over a dozen terminal lines is not reliably
# clickable. Cloud Shell's terminal supports this. Anything that is not a
# terminal, including a piped or redirected run, gets the raw url instead.
write_hyperlink() {
    local url="$1"
    local label="$2"

    if [[ -n "${LOG_PATH}" ]]; then
        printf '[%s] - %s\n' "$(date '+%d/%m/%Y %H:%M:%S')" "${url}" >>"${LOG_PATH}"
    fi

    if [[ -t 1 ]]; then
        printf '\033]8;;%s\a%s\033]8;;\a\n' "${url}" "${label}"
    else
        printf '%s\n' "${url}"
    fi
}

# Wraps gcloud so that --dry-run can print the call instead of making it.
run_gcloud() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '  [dry-run] gcloud %s\n' "$*"
        return 0
    fi

    gcloud "$@"
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Configures a GCP project, service account and APIs for CloudM Migrate.

Usage:
  gcp_configuration.sh [OPTIONS] [PROJECT_ID] SERVICE_ACCOUNT_ID SCOPE [OUTPUT_PATH]

Arguments:
  PROJECT_ID           Optional. A unique string of 6 to 30 lowercase letters,
                       digits or hyphens. Must start with a letter and must not
                       end with a hyphen. Created if it does not already exist.
                       If omitted, the active gcloud project is used.
  SERVICE_ACCOUNT_ID   6 to 30 lowercase letters, digits or hyphens. Must start
                       with a letter and must not end with a hyphen. Reused if
                       it already exists, and issued a fresh key.
  SCOPE                One of: All, Standard, SourceLimited, DestinationLimited,
                       Vault, Storage.
  OUTPUT_PATH          Optional. Where to write the JSON key and log.
                       Defaults to ~/cloudm/gcpconfig.

Options:
  --dry-run            Validate inputs and print the gcloud calls without
                       making any changes.
  --include-chat       Also grant the Google Chat scopes and enable the Chat
                       API, for migrations that include Google Chat. The Chat
                       app itself still has to be configured by hand, and the
                       script prints those steps at the end.
  -h, --help           Show this help.
USAGE
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --include-chat)
                INCLUDE_CHAT=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                fail "Unknown option: $1"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # Two arguments means the project comes from the active gcloud config. The
    # count alone disambiguates, so there is no guessing about which value is
    # which. Note the Cloud Shell tutorial project picker does NOT set the gcloud
    # project, so the tutorial always passes the project explicitly and this form
    # is for command line use.
    case ${#positional[@]} in
        2)
            PROJECT_ID=""
            SERVICE_ACCOUNT_ID="${positional[0]}"
            SCOPE="${positional[1]}"
            ;;
        3)
            PROJECT_ID="${positional[0]}"
            SERVICE_ACCOUNT_ID="${positional[1]}"
            SCOPE="${positional[2]}"
            ;;
        4)
            PROJECT_ID="${positional[0]}"
            SERVICE_ACCOUNT_ID="${positional[1]}"
            SCOPE="${positional[2]}"
            OUTPUT_PATH="${positional[3]}"
            ;;
        *)
            usage >&2
            blank_line >&2
            fail "Expected 2 to 4 arguments, got ${#positional[@]}"
            ;;
    esac
}

# Falls back to the active gcloud project when none was passed.
resolve_project() {
    if [[ -n "${PROJECT_ID}" ]]; then
        return 0
    fi

    PROJECT_ID="$(gcloud config get-value project </dev/null 2>/dev/null || true)"

    if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
        fail "No project id was given and no active gcloud project is set. Either pass the project id as the first argument, or run 'gcloud config set project PROJECT_ID' first."
    fi

    write_log "Using the active gcloud project: '${PROJECT_ID}'"
}

validate_project_id() {
    if [[ ! "${PROJECT_ID}" =~ ${ID_PATTERN} ]]; then
        fail "ProjectId '${PROJECT_ID}' is invalid. It must be 6 to 30 lowercase letters, digits or hyphens, must start with a letter and must not end with a hyphen."
    fi
}

validate_args() {
    # The project id is validated separately, after it has possibly been
    # resolved from the active gcloud config.
    if [[ -n "${PROJECT_ID}" ]]; then
        validate_project_id
    fi

    if [[ ! "${SERVICE_ACCOUNT_ID}" =~ ${ID_PATTERN} ]]; then
        fail "ServiceAccountId '${SERVICE_ACCOUNT_ID}' is invalid. It must be 6 to 30 lowercase letters, digits or hyphens, must start with a letter and must not end with a hyphen."
    fi

    # PowerShell's ValidateSet is case-insensitive, so accept any casing and
    # normalise to the canonical value the case statements expect.
    local supplied_lower candidate candidate_lower matched=""
    supplied_lower="$(printf '%s' "${SCOPE}" | tr '[:upper:]' '[:lower:]')"

    for candidate in "${VALID_SCOPES[@]}"; do
        candidate_lower="$(printf '%s' "${candidate}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${supplied_lower}" == "${candidate_lower}" ]]; then
            matched="${candidate}"
            break
        fi
    done

    if [[ -z "${matched}" ]]; then
        fail "Scope '${SCOPE}' is invalid. It must be one of: ${VALID_SCOPES[*]}"
    fi

    SCOPE="${matched}"
}

# ----------------------------------------------------------------------------
# Scopes and APIs
#
# These lists are also maintained in the PowerShell setup script and in
# support.cloudm.io article 14395636657436. Adding a scope or an API means
# updating all three, or they drift.
# ----------------------------------------------------------------------------

readonly BASE_SCOPES=(
    "https://www.googleapis.com/auth/gmail.settings.basic"
    "https://www.googleapis.com/auth/gmail.settings.sharing"
    "https://sites.google.com/feeds/"
    "https://www.google.com/m8/feeds"
    "https://www.googleapis.com/auth/admin.directory.group"
    "https://www.googleapis.com/auth/admin.directory.user"
    "https://www.googleapis.com/auth/admin.directory.resource.calendar"
    "https://www.googleapis.com/auth/apps.groups.migration"
    "https://www.googleapis.com/auth/calendar"
    "https://www.googleapis.com/auth/drive"
    "https://www.googleapis.com/auth/drive.appdata"
    "https://www.googleapis.com/auth/email.migration"
    "https://www.googleapis.com/auth/tasks"
    # Needed to use forms.googleapis.com, which is enabled below. Listed in
    # support.cloudm.io article 14395636657436, in this position.
    "https://www.googleapis.com/auth/forms"
    "https://www.googleapis.com/auth/contacts"
    "https://www.googleapis.com/auth/contacts.other.readonly"
    "https://www.googleapis.com/auth/contacts.readonly"
    "https://www.googleapis.com/auth/directory.readonly"
    "https://www.googleapis.com/auth/user.addresses.read"
    "https://www.googleapis.com/auth/user.birthday.read"
    "https://www.googleapis.com/auth/user.emails.read"
    "https://www.googleapis.com/auth/user.gender.read"
    "https://www.googleapis.com/auth/user.organization.read"
    "https://www.googleapis.com/auth/user.phonenumbers.read"
    "https://www.googleapis.com/auth/userinfo.email"
    "https://www.googleapis.com/auth/userinfo.profile"
)

readonly SOURCE_LIMITED_SCOPES=(
    "https://www.googleapis.com/auth/gmail.labels"
    "https://www.googleapis.com/auth/gmail.readonly"
)

readonly DESTINATION_LIMITED_SCOPES=(
    "https://www.googleapis.com/auth/gmail.labels"
    "https://www.googleapis.com/auth/gmail.insert"
)

readonly STANDARD_SCOPES=(
    "https://mail.google.com/"
)

readonly VAULT_SCOPES=(
    "https://www.googleapis.com/auth/ediscovery"
    "https://www.googleapis.com/auth/ediscovery.readonly"
    "https://www.googleapis.com/auth/devstorage.read_write"
)

readonly BASE_APIS=(
    "admin.googleapis.com"
    "contacts.googleapis.com"
    "drive.googleapis.com"
    "gmail.googleapis.com"
    "calendar-json.googleapis.com"
    "groupsmigration.googleapis.com"
    "tasks.googleapis.com"
    "people.googleapis.com"
    "forms.googleapis.com"
)

readonly CLOUD_STORAGE_APIS=(
    "storage-api.googleapis.com"
    "storage-component.googleapis.com"
    "storage.googleapis.com"
)

readonly VAULT_APIS=(
    "vault.googleapis.com"
)

# Google Chat, added by --include-chat. Taken from the scope list in
# support.cloudm.io article 14395636657436. Additive to whichever scope was
# chosen rather than a scope of its own, because a Chat migration is a Standard
# or Vault migration that also moves Chat.
readonly CHAT_SCOPES=(
    "https://www.googleapis.com/auth/chat.admin.memberships"
    "https://www.googleapis.com/auth/chat.admin.spaces"
    "https://www.googleapis.com/auth/chat.admin.spaces.readonly"
    "https://www.googleapis.com/auth/chat.bot"
    "https://www.googleapis.com/auth/chat.customemojis"
    "https://www.googleapis.com/auth/chat.import"
    "https://www.googleapis.com/auth/chat.memberships"
    "https://www.googleapis.com/auth/chat.memberships.app"
    "https://www.googleapis.com/auth/chat.messages"
    "https://www.googleapis.com/auth/chat.spaces"
)

readonly CHAT_APIS=(
    "chat.googleapis.com"
)

# Populates the SCOPES_TO_USE global for the requested scope.
build_scopes_list() {
    case "${SCOPE}" in
        Standard)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${STANDARD_SCOPES[@]}")
            ;;
        SourceLimited)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${SOURCE_LIMITED_SCOPES[@]}")
            ;;
        DestinationLimited)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${DESTINATION_LIMITED_SCOPES[@]}")
            ;;
        Vault)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${VAULT_SCOPES[@]}" "${STANDARD_SCOPES[@]}")
            ;;
        Storage)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${STANDARD_SCOPES[@]}")
            ;;
        *)
            SCOPES_TO_USE=("${BASE_SCOPES[@]}" "${VAULT_SCOPES[@]}" "${STANDARD_SCOPES[@]}")
            ;;
    esac

    if [[ "${INCLUDE_CHAT}" == "true" ]]; then
        SCOPES_TO_USE+=("${CHAT_SCOPES[@]}")
    fi
}

# Populates the APIS_TO_ENABLE global for the requested scope.
build_api_list() {
    case "${SCOPE}" in
        Standard|SourceLimited|DestinationLimited)
            APIS_TO_ENABLE=("${BASE_APIS[@]}")
            ;;
        Vault)
            APIS_TO_ENABLE=("${BASE_APIS[@]}" "${VAULT_APIS[@]}" "${CLOUD_STORAGE_APIS[@]}")
            ;;
        Storage)
            APIS_TO_ENABLE=("${BASE_APIS[@]}" "${CLOUD_STORAGE_APIS[@]}")
            ;;
        *)
            APIS_TO_ENABLE=("${BASE_APIS[@]}" "${VAULT_APIS[@]}" "${CLOUD_STORAGE_APIS[@]}")
            ;;
    esac

    if [[ "${INCLUDE_CHAT}" == "true" ]]; then
        APIS_TO_ENABLE+=("${CHAT_APIS[@]}")
    fi
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

create_output_path() {
    umask 077
    mkdir -p "${OUTPUT_PATH}"
    LOG_PATH="${OUTPUT_PATH}/gcp_config.log"
}

check_prerequisites() {
    write_log "Checking prerequisites..."

    if ! command -v gcloud >/dev/null 2>&1; then
        fail "The gcloud CLI was not found. Run this script in Google Cloud Shell, or install the Google Cloud SDK from https://cloud.google.com/sdk/docs/install"
    fi

    local account
    account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"

    if [[ -z "${account}" ]]; then
        fail "No active gcloud account. Run 'gcloud auth login' first. In Cloud Shell, click Authorize when prompted."
    fi

    write_log "Authenticated as: '${account}'"

    if [[ "${CLOUD_SHELL:-}" == "true" ]]; then
        write_log "Running in Google Cloud Shell"
    fi
}

# Best effort only. Reports the org policy that most commonly blocks this
# script, but a user without orgpolicy.policy.get cannot read it, so a failure
# here is not treated as fatal.
warn_on_key_creation_policy() {
    local constraint="constraints/iam.disableServiceAccountKeyCreation"
    local enforced

    enforced="$(gcloud org-policies describe "${constraint}" \
        --project="${PROJECT_ID}" --effective --format='value(spec.rules.enforce)' \
        </dev/null 2>/dev/null || true)"

    if [[ "${enforced}" == *"True"* || "${enforced}" == *"true"* ]]; then
        write_log "WARNING: the org policy '${constraint}' appears to be enforced on this project. Service account key creation will fail until it is disabled for this project." true
    fi
}

# ----------------------------------------------------------------------------
# Project
# ----------------------------------------------------------------------------

project_exists() {
    gcloud projects describe "${PROJECT_ID}" --format='value(projectId)' >/dev/null 2>&1
}

configure_project() {
    write_log "Configuring Project: '${PROJECT_ID}'"

    if project_exists; then
        write_log "Project: '${PROJECT_ID}' already exists"

        local current_project
        current_project="$(gcloud config get-value project 2>/dev/null || true)"

        if [[ "${current_project}" != "${PROJECT_ID}" ]]; then
            write_log "Switching to Project: '${PROJECT_ID}'"
            run_gcloud config set project "${PROJECT_ID}" --no-user-output-enabled ||
                fail "Failed to switch to Project: '${PROJECT_ID}'"
            write_log "Switched to Project: '${PROJECT_ID}'"
        fi
    else
        write_log "Creating Project: '${PROJECT_ID}', this may take a few minutes"

        if ! run_gcloud projects create "${PROJECT_ID}" --set-as-default --no-user-output-enabled; then
            fail "Failed to create Project: '${PROJECT_ID}'. The project id may already be in use by another organisation, or your account may not have the resourcemanager.projects.create permission on the target organisation or folder."
        fi

        wait_for_project
        write_log "Created Project: '${PROJECT_ID}'"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        PROJECT_NUMBER="000000000000"
    else
        PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
    fi

    if [[ -z "${PROJECT_NUMBER}" ]]; then
        fail "Failed to configure Project: '${PROJECT_ID}'"
    fi

    write_log "Configured Project: '${PROJECT_ID}' (number ${PROJECT_NUMBER})"
}

# A new project is not immediately readable, so poll until describe succeeds
# rather than waiting a fixed interval and hoping it was long enough.
wait_for_project() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    local waited=0

    until project_exists; do
        if [[ ${waited} -ge ${POLL_TIMEOUT_SECONDS} ]]; then
            fail "Project '${PROJECT_ID}' was not readable after ${POLL_TIMEOUT_SECONDS} seconds"
        fi
        sleep "${POLL_INTERVAL_SECONDS}"
        waited=$((waited + POLL_INTERVAL_SECONDS))
    done
}

# ----------------------------------------------------------------------------
# Service account
# ----------------------------------------------------------------------------

get_service_account_email() {
    printf '%s@%s.iam.gserviceaccount.com' "${SERVICE_ACCOUNT_ID}" "${PROJECT_ID}"
}

service_account_exists() {
    gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" \
        --project="${PROJECT_ID}" --format='value(email)' >/dev/null 2>&1
}

wait_for_service_account() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    local waited=0

    until service_account_exists; do
        if [[ ${waited} -ge ${POLL_TIMEOUT_SECONDS} ]]; then
            fail "Service account '${SERVICE_ACCOUNT_ID}' was not readable after ${POLL_TIMEOUT_SECONDS} seconds"
        fi
        sleep "${POLL_INTERVAL_SECONDS}"
        waited=$((waited + POLL_INTERVAL_SECONDS))
    done
}

# Grants owner, retrying while IAM catches up.
#
# A newly created service account becomes readable through the IAM API before
# the project IAM policy will accept it as a member, so this call can fail with
# "does not exist" seconds after 'describe' has already succeeded. Waiting longer
# before the first attempt only makes that less likely, never impossible, so the
# binding itself is retried instead.
#
# Only the propagation error is retried. Anything else, a missing permission for
# example, fails immediately rather than burning the whole timeout.
add_owner_binding() {
    write_log "Adding Role: '${OWNER_ROLE}' to Service Account: '${SERVICE_ACCOUNT_ID}'"

    # Adding a binding that already exists is a no-op, so this is safe to repeat.
    if [[ "${DRY_RUN}" == "true" ]]; then
        run_gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
            --role="${OWNER_ROLE}" \
            --no-user-output-enabled
        write_log "Added Role: '${OWNER_ROLE}' to Service Account: '${SERVICE_ACCOUNT_ID}'"
        return 0
    fi

    local output waited=0

    while true; do
        if output="$(gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
            --role="${OWNER_ROLE}" \
            --no-user-output-enabled </dev/null 2>&1)"; then
            break
        fi

        if [[ "${output}" != *"does not exist"* ]]; then
            fail "Failed to add Role: '${OWNER_ROLE}' to Service Account: '${SERVICE_ACCOUNT_ID}'. ${output}"
        fi

        if [[ ${waited} -ge ${POLL_TIMEOUT_SECONDS} ]]; then
            fail "Service Account '${SERVICE_ACCOUNT_ID}' was created but the project IAM policy still would not accept it as a member after ${POLL_TIMEOUT_SECONDS} seconds. Re-running the script will reuse the existing account and retry the binding."
        fi

        write_log "IAM has not caught up with the new service account yet, retrying in ${POLL_INTERVAL_SECONDS}s"
        sleep "${POLL_INTERVAL_SECONDS}"
        waited=$((waited + POLL_INTERVAL_SECONDS))
    done

    write_log "Added Role: '${OWNER_ROLE}' to Service Account: '${SERVICE_ACCOUNT_ID}'"
}

configure_service_account() {
    SERVICE_ACCOUNT_EMAIL="$(get_service_account_email)"

    # Reuse an existing account rather than failing. The tutorial hands everyone
    # the same default account name, so a second run has to be safe, and re-running
    # to issue a replacement key is a legitimate thing to want.
    if [[ "${DRY_RUN}" != "true" ]] && service_account_exists; then
        write_log "Service Account: '${SERVICE_ACCOUNT_ID}' already exists, reusing it and issuing a new key"
    else
        write_log "Creating Service Account: '${SERVICE_ACCOUNT_ID}', this may take a few minutes"

        run_gcloud iam service-accounts create "${SERVICE_ACCOUNT_ID}" \
            --display-name="${SERVICE_ACCOUNT_ID}" \
            --project="${PROJECT_ID}" \
            --no-user-output-enabled ||
            fail "Failed to create Service Account: '${SERVICE_ACCOUNT_ID}'"

        wait_for_service_account

        write_log "Created Service Account: '${SERVICE_ACCOUNT_ID}'"
    fi

    add_owner_binding

    if [[ "${DRY_RUN}" == "true" ]]; then
        SERVICE_ACCOUNT_CLIENT_ID="000000000000000000000"
    else
        SERVICE_ACCOUNT_CLIENT_ID="$(gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" \
            --project="${PROJECT_ID}" --format='value(oauth2ClientId)' 2>/dev/null || true)"
    fi

    if [[ -z "${SERVICE_ACCOUNT_CLIENT_ID}" ]]; then
        fail "Failed to retrieve Service Account: '${SERVICE_ACCOUNT_ID}'"
    fi
}

configure_service_account_key() {
    SERVICE_ACCOUNT_KEY_PATH="${OUTPUT_PATH}/${SERVICE_ACCOUNT_ID}_key.json"

    write_log "Creating JSON Service Account Key for: '${SERVICE_ACCOUNT_ID}'"

    warn_on_key_creation_policy

    if ! run_gcloud iam service-accounts keys create "${SERVICE_ACCOUNT_KEY_PATH}" \
        --iam-account="${SERVICE_ACCOUNT_EMAIL}" \
        --key-file-type=json \
        --project="${PROJECT_ID}" \
        --no-user-output-enabled; then
        fail "Failed to create Service Account Key for '${SERVICE_ACCOUNT_ID}'. If your organisation enforces constraints/iam.disableServiceAccountKeyCreation you will need it disabled for this project before a key can be created."
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        chmod 600 "${SERVICE_ACCOUNT_KEY_PATH}"
    fi

    write_log "Created JSON Service Account Key for: '${SERVICE_ACCOUNT_ID}'"
}

# ----------------------------------------------------------------------------
# APIs
# ----------------------------------------------------------------------------

configure_apis() {
    build_api_list

    local enabled_raw enabled_list=()

    # Read even under --dry-run. The call is read-only and it makes the dry run
    # an accurate preview of which APIs would actually be enabled.
    enabled_raw="$(gcloud services list --enabled --project="${PROJECT_ID}" \
        --format='value(name)' 2>/dev/null || true)"

    # gcloud has returned both the bare service name and the fully qualified
    # projects/NUMBER/services/NAME form. Strip any prefix so either works.
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        enabled_list+=("${line##*/}")
    done <<<"${enabled_raw}"

    local api existing to_enable=()

    for api in "${APIS_TO_ENABLE[@]}"; do
        local is_enabled=false

        for existing in "${enabled_list[@]+"${enabled_list[@]}"}"; do
            if [[ "${existing}" == "${api}" ]]; then
                is_enabled=true
                break
            fi
        done

        if [[ "${is_enabled}" == "true" ]]; then
            write_log "Api: '${api}' already Enabled"
        else
            to_enable+=("${api}")
        fi
    done

    if [[ ${#to_enable[@]} -eq 0 ]]; then
        write_log "All required APIs are already enabled"
        return 0
    fi

    # Enabling in one call is a single long running operation rather than one
    # per API, which is noticeably faster.
    write_log "Enabling Apis: ${to_enable[*]}"

    run_gcloud services enable "${to_enable[@]}" \
        --project="${PROJECT_ID}" \
        --no-user-output-enabled ||
        fail "Failed to enable APIs: ${to_enable[*]}. Check that the project has a billing account linked if any of these APIs require one."

    write_log "Enabled Apis: ${to_enable[*]}"
}

# ----------------------------------------------------------------------------
# Output the manual steps
# ----------------------------------------------------------------------------

write_next_steps() {
    build_scopes_list

    local concatenated_scopes
    concatenated_scopes="$(
        IFS=,
        printf '%s' "${SCOPES_TO_USE[*]}"
    )"

    local scopes_file="${OUTPUT_PATH}/scopes.txt"
    printf '%s\n' "${concatenated_scopes}" >"${scopes_file}"

    blank_line
    blank_line
    write_log "Project, APIs and Service Account configured. Please use the following steps to complete the Domain Wide Delegation configuration" true
    blank_line

    # No OAuth consent screen step. A service account using domain-wide
    # delegation authenticates with a signed JWT and never goes through the
    # consent flow, so the consent screen has no bearing on whether it works.
    write_log "Step 1. Configure Google Workspace Domain Wide Delegation" true
    blank_line

    # Prefill deep link. The parameter names are the ones Google itself uses in
    # google/drive-file-search-fix against the current /ac/owl/ page. Scope
    # values are passed unencoded, matching Google's own published example.
    local delegation_url="https://admin.google.com/ac/owl/domainwidedelegation"
    local prefill_url="${delegation_url}?clientIdToAdd=${SERVICE_ACCOUNT_CLIENT_ID}&clientScopeToAdd=${concatenated_scopes}&overwriteClientId=true"

    printf '%s\n' "${prefill_url}" >"${OUTPUT_PATH}/delegation_url.txt"

    write_log "Control-click or command-click the link below. It opens the delegation form with your client id and scopes already filled in. Check the scopes field is not empty, then click Authorise."
    blank_line
    write_hyperlink "${prefill_url}" ">>> Grant domain wide delegation <<<"
    blank_line
    write_log "If the link is not clickable, or the page ignores it, enter the values by hand as below."
    blank_line

    write_log "Manual fallback. Go to ${delegation_url} , click Add new, and enter:"
    blank_line
    write_log "ClientId: ${SERVICE_ACCOUNT_CLIENT_ID}"
    write_log "Scopes: ${concatenated_scopes}"
    blank_line
    write_log "Both values have also been saved to:"
    write_log "  ${scopes_file}"
    write_log "  ${OUTPUT_PATH}/delegation_url.txt"
    blank_line

    write_log "Step 2. Service Account details for use in CloudM Migrate:" true
    blank_line
    write_log "Email: ${SERVICE_ACCOUNT_EMAIL}"
    write_log "JSON Key: ${SERVICE_ACCOUNT_KEY_PATH}"
    write_log "Set the Google authentication method on the connection to JSON, not P12."
    blank_line
}

# Chat app configuration cannot be scripted. There is no public API for the app
# manifest, and several values are things the script cannot know: the HTTP
# endpoint url comes from the CloudM project setup, the visibility group is a
# Google Group the customer has to create, and the avatar has to be a publicly
# reachable image. The Workspace add-on checkbox is also a one-way door, so
# getting it wrong in an automated run would cost the customer the whole project.
# Printing the steps is the safe option.
write_chat_app_steps() {
    if [[ "${INCLUDE_CHAT}" != "true" ]]; then
        return 0
    fi

    write_log "Google Chat: the Chat app still needs configuring" true
    blank_line
    write_log "The Chat API is enabled and the Chat scopes are in the delegation link above. The Chat app itself has to be set up by hand in the console, using these two values:"
    blank_line
    write_log "Configuration page: https://console.cloud.google.com/apis/api/chat.googleapis.com?project=${PROJECT_ID}"
    write_log "Authentication Audience, use the project number: ${PROJECT_NUMBER}"
    blank_line
    write_log "Leave 'Build this Chat app as a Workspace add-on' UNTICKED. That cannot be undone once saved, and saving it means starting again with a new GCP project." true
    blank_line
    write_log "Follow the Chat app step in the tutorial, or https://support.cloudm.io/hc/en-us/articles/16098094416796"
    blank_line
}

# The key is created on the Cloud Shell VM, not on the machine running Migrate,
# so it has to be downloaded to the browser and then removed.
write_key_retrieval_steps() {
    write_log "Step 3. Retrieve the key file" true
    blank_line

    if [[ "${CLOUD_SHELL:-}" == "true" ]]; then
        write_log "Downloading the key to your browser..."

        if [[ "${DRY_RUN}" == "true" ]]; then
            printf '  [dry-run] cloudshell download %s\n' "${SERVICE_ACCOUNT_KEY_PATH}"
        elif command -v cloudshell >/dev/null 2>&1; then
            cloudshell download "${SERVICE_ACCOUNT_KEY_PATH}" || true
        fi

        write_log "If the download did not start, use the Cloud Shell three dot menu and choose Download, then enter this path:"
        write_log "  ${SERVICE_ACCOUNT_KEY_PATH}"
        blank_line
        write_log "Once the key is safely stored, delete it from Cloud Shell. Your home directory is persistent, so the private key will otherwise remain here:" true
        write_log "  shred -u '${SERVICE_ACCOUNT_KEY_PATH}'"
    else
        write_log "Copy the key file to the machine running CloudM Migrate, then delete this copy:"
        write_log "  ${SERVICE_ACCOUNT_KEY_PATH}"
    fi

    blank_line
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_args
    create_output_path

    blank_line
    write_log "Configuring GCP for CloudM Migrate" true

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_log "DRY RUN: no changes will be made" true
    fi

    blank_line

    check_prerequisites
    resolve_project
    validate_project_id
    configure_project
    configure_service_account
    configure_service_account_key
    configure_apis
    write_next_steps
    write_chat_app_steps
    write_key_retrieval_steps

    write_log "Configured GCP for CloudM Migrate" true
    write_log "Log written to: ${LOG_PATH}"
}

main "$@"
