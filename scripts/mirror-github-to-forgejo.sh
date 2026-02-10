#!/usr/bin/env bash
# mirror-github-to-forgejo.sh
#
# Mirror your GitHub repositories into a self-hosted Forgejo instance
# using Forgejo's migration API.
# Mirrors are pull-mirrors — Forgejo re-syncs from GitHub automatically.
#
# Requirements: bash ≥ 4, curl, jq
#
# Configuration: set env vars directly, or place them in a .env file next to
# this script (or provide ENV_FILE=/path/to/.env).

set -euo pipefail


if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: mirror-github-to-forgejo.sh [--help]

Mirror your GitHub repositories into a Forgejo instance.

Configuration (via environment variables or .env file):

  Required:
    GITHUB_TOKEN    GitHub Personal Access Token (repo + read:org scopes)
    FORGEJO_TOKEN   Forgejo API token

  Optional:
    FORGEJO_URL     Forgejo base URL              (default: http://localhost:7830)
    FORGEJO_OWNER   Forgejo user to own repos     (default: auto-detected GitHub username)
    GITHUB_USER     GitHub username                (default: auto-detected from token)
    MIRROR_FORKS    Include forked repos           (default: true)
    MIRROR_PRIVATE  Include private repos          (default: true)
    DRY_RUN         Log without making changes     (default: false)
    ENV_FILE        Path to .env file              (default: .env next to script)

EOF
    exit 0
fi


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No colour

log()     { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
log_ok()  { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
log_skip(){ printf "${YELLOW}[SKIP]${NC}  %s\n" "$*"; }
log_warn(){ printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
log_err() { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
log_dry() { printf "${BOLD}[DRY]${NC}   %s\n" "$*"; }


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
    log "Loading config from ${ENV_FILE}"
    # Source .env but don't override variables already set in the environment
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi


GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required (GitHub PAT with repo + read:org scopes)}"
FORGEJO_TOKEN="${FORGEJO_TOKEN:?FORGEJO_TOKEN is required (Forgejo API token)}"
FORGEJO_URL="${FORGEJO_URL:-http://localhost:7830}"

MIRROR_FORKS="${MIRROR_FORKS:-true}"
MIRROR_PRIVATE="${MIRROR_PRIVATE:-true}"
DRY_RUN="${DRY_RUN:-false}"

# Strip trailing slash from URL
FORGEJO_URL="${FORGEJO_URL%/}"


for cmd in curl jq; do
    if ! command -v "${cmd}" &>/dev/null; then
        log_err "Required command '${cmd}' not found. Please install it."
        exit 1
    fi
done


gh_api() {
    local endpoint="$1"
    shift
    curl -fsSL \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com${endpoint}" "$@"
}

# Paginate a GitHub API endpoint, collecting all JSON array results.
gh_paginate() {
    local endpoint="$1"
    local sep="?"
    if [[ "${endpoint}" == *"?"* ]]; then
        sep="&"
    fi

    local page=1
    local results="[]"

    while true; do
        local response
        response="$(gh_api "${endpoint}${sep}per_page=100&page=${page}")"

        local count
        count="$(jq 'length' <<< "${response}")"

        if (( count == 0 )); then
            break
        fi

        results="$(jq -s '.[0] + .[1]' <<< "${results}
${response}")"
        page=$((page + 1))
    done

    echo "${results}"
}


fj_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    curl -sS \
        -X "${method}" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -w "\n%{http_code}" \
        "${FORGEJO_URL}/api/v1${endpoint}" "$@"
}

# Sets globals: FJ_HTTP_CODE (status code) and FJ_BODY (response body)
fj_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local raw
    raw="$(fj_api "${method}" "${endpoint}" "$@")"

    FJ_HTTP_CODE="$(tail -n1 <<< "${raw}")"
    FJ_BODY="$(head -n -1 <<< "${raw}")"
}


log "Detecting GitHub user…"
GH_USER_JSON="$(gh_api "/user")"
GITHUB_USER="${GITHUB_USER:-$(jq -r '.login' <<< "${GH_USER_JSON}")}"
FORGEJO_OWNER="${FORGEJO_OWNER:-${GITHUB_USER}}"

log "GitHub user:   ${GITHUB_USER}"
log "Forgejo owner: ${FORGEJO_OWNER}"
log "Forgejo URL:   ${FORGEJO_URL}"
log "Mirror forks:  ${MIRROR_FORKS}"
log "Mirror private: ${MIRROR_PRIVATE}"
log "Dry run:       ${DRY_RUN}"
echo


log "Fetching all accessible GitHub repos (this may take a moment)…"
ALL_REPOS="$(gh_paginate "/user/repos?affiliation=owner,collaborator,organization_member")"

TOTAL="$(jq 'length' <<< "${ALL_REPOS}")"
log "Found ${TOTAL} total repos"


FILTERED="$(jq \
    --argjson forks  "$([ "${MIRROR_FORKS}" = "true" ] && echo true || echo false)" \
    --argjson private "$([ "${MIRROR_PRIVATE}" = "true" ] && echo true || echo false)" \
    '[.[] | select(
        ($forks   or (.fork | not)) and
        ($private or (.private | not))
    )]' <<< "${ALL_REPOS}"
)"

FILTERED_COUNT="$(jq 'length' <<< "${FILTERED}")"
log "After filtering: ${FILTERED_COUNT} repos to mirror"
echo


declare -A ENSURED_ORGS=()

ensure_forgejo_org() {
    local org_name="$1"

    # Already ensured this run
    if [[ -n "${ENSURED_ORGS[${org_name}]+x}" ]]; then
        return 0
    fi

    # Check if org exists
    fj_call GET "/orgs/${org_name}"

    if [[ "${FJ_HTTP_CODE}" == "200" ]]; then
        ENSURED_ORGS["${org_name}"]=1
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would create Forgejo org: ${org_name}"
        ENSURED_ORGS["${org_name}"]=1
        return 0
    fi

    log "Creating Forgejo org: ${org_name}"
    local body
    body="$(jq -n --arg name "${org_name}" '{
        username: $name,
        visibility: "private"
    }')"

    fj_call POST "/orgs" -d "${body}"

    if [[ "${FJ_HTTP_CODE}" == "201" || "${FJ_HTTP_CODE}" == "422" ]]; then
        ENSURED_ORGS["${org_name}"]=1
        log_ok "Created org: ${org_name}"
    else
        log_err "Failed to create org ${org_name} (HTTP ${FJ_HTTP_CODE}): ${FJ_BODY}"
        return 1
    fi
}


mirror_repo() {
    local clone_url="$1"
    local repo_name="$2"
    local forgejo_owner="$3"
    local is_private="$4"
    local description="$5"
    local full_name="$6"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "Would mirror: ${full_name} → ${forgejo_owner}/${repo_name}"
        return 0
    fi

    local body
    body="$(jq -n \
        --arg clone_addr  "${clone_url}" \
        --arg auth_token  "${GITHUB_TOKEN}" \
        --arg repo_name   "${repo_name}" \
        --arg repo_owner  "${forgejo_owner}" \
        --arg description "${description}" \
        --argjson private "${is_private}" \
        '{
            clone_addr: $clone_addr,
            auth_token: $auth_token,
            repo_name: $repo_name,
            repo_owner: $repo_owner,
            description: $description,
            mirror: true,
            private: $private,
            service: "github",
            wiki: true,
            issues: true,
            labels: true,
            milestones: true,
            pull_requests: true,
            releases: true
        }'
    )"

    fj_call POST "/repos/migrate" -d "${body}"

    case "${FJ_HTTP_CODE}" in
        201)
            log_ok "Mirrored: ${full_name} → ${forgejo_owner}/${repo_name}"
            ;;
        409)
            log_skip "Already exists: ${forgejo_owner}/${repo_name} — triggering sync"
            # Trigger a mirror sync for existing repos
            fj_call POST "/repos/${forgejo_owner}/${repo_name}/mirror-sync"
            if [[ "${FJ_HTTP_CODE}" == "200" ]]; then
                log_ok "Sync triggered: ${forgejo_owner}/${repo_name}"
            else
                log_warn "Sync trigger returned HTTP ${FJ_HTTP_CODE} for ${forgejo_owner}/${repo_name}"
            fi
            ;;
        *)
            log_err "Failed (HTTP ${FJ_HTTP_CODE}): ${full_name}"
            log_err "Response: ${FJ_BODY}"
            ;;
    esac
}


jq -c '.[]' <<< "${FILTERED}" | while IFS= read -r repo; do
    repo_name="$(jq -r '.name'        <<< "${repo}")"
    full_name="$(jq -r '.full_name'   <<< "${repo}")"
    clone_url="$(jq -r '.clone_url'   <<< "${repo}")"
    is_fork="$(jq   -r '.fork'        <<< "${repo}")"
    is_private="$(jq -r '.private'    <<< "${repo}")"
    description="$(jq -r '.description // ""' <<< "${repo}")"
    owner_login="$(jq -r '.owner.login' <<< "${repo}")"
    owner_type="$(jq -r '.owner.type'   <<< "${repo}")"

    # Determine Forgejo destination owner
    if [[ "${owner_type}" == "Organization" ]]; then
        forgejo_dest="${owner_login}"
        ensure_forgejo_org "${owner_login}" || {
            log_err "Skipping ${full_name} — could not ensure org ${owner_login}"
            continue
        }
    else
        forgejo_dest="${FORGEJO_OWNER}"
    fi

    label=""
    if [[ "${is_fork}" == "true" ]]; then
        label=" (fork)"
    fi
    if [[ "${owner_login}" != "${GITHUB_USER}" && "${owner_type}" != "Organization" ]]; then
        label="${label} (via: ${owner_login})"
    fi

    log "Processing: ${full_name}${label}"
    mirror_repo "${clone_url}" "${repo_name}" "${forgejo_dest}" "${is_private}" "${description}" "${full_name}"
done

echo
printf '%b\n' "${GREEN}${BOLD}Done!${NC}"
