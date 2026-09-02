# shellcheck shell=bash
#
# util.sh — small, dependency-free helpers shared by every module.
#
# Two rules hold everywhere in this file:
#   1. Anything that changes the system goes through util::run or util::sudo,
#      so --dry-run is honored in exactly one place instead of forty.
#   2. Predicates (util::have, util::is_root) return a status and print
#      nothing, so they compose inside `if` without noise.

# ---------------------------------------------------------------------------
# Failure
# ---------------------------------------------------------------------------

# util::die <message...> — log an error and exit non-zero.
util::die() {
    log::error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Predicates
# ---------------------------------------------------------------------------

# util::have <command> — is this command on PATH?
util::have() {
    command -v -- "$1" >/dev/null 2>&1
}

# util::is_root — running as uid 0?
util::is_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# util::is_dry — is this a dry run?
util::is_dry() {
    [[ "${SETUP_DRY_RUN:-0}" == "1" ]]
}

# util::is_interactive — is there a human on the other end of stdin?
util::is_interactive() {
    [[ -t 0 ]]
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

# util::run <command> [args...] — run a state-changing command.
#
# Arguments are passed through as an array, never re-parsed by a shell, so
# paths with spaces are safe. Under --dry-run the command is printed instead.
util::run() {
    if util::is_dry; then
        log::dry "$*"
        return 0
    fi
    log::cmd "$*"
    "$@"
}

# util::sudo <command> [args...] — run a command as root.
#
# A no-op wrapper when already root, so the script works both as a normal
# user with sudo rights and inside a root container.
util::sudo() {
    if util::is_root; then
        util::run "$@"
    else
        util::run sudo "$@"
    fi
}

# util::sudo_init — prompt for the sudo password once, up front.
#
# Without this the password prompt appears at an arbitrary point mid-run,
# often buried under package-manager output.
util::sudo_init() {
    util::is_root && return 0
    util::is_dry && return 0

    util::have sudo || util::die "sudo is required but not installed"

    if ! sudo -n true 2>/dev/null; then
        log::info "Requesting sudo access (needed to install packages)"
        sudo -v || util::die "Could not obtain sudo access"
    fi
}

# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------

# util::confirm <question> — ask a yes/no question; default no.
#
# Returns 0 for yes. Auto-answers yes under --yes, and no when there is no
# terminal, so an unattended run never hangs waiting on stdin.
util::confirm() {
    local question="$1"

    if [[ "${SETUP_ASSUME_YES:-0}" == "1" ]]; then
        log::debug "auto-confirming: $question"
        return 0
    fi

    if ! util::is_interactive; then
        log::warn "Not interactive, assuming no: $question"
        return 1
    fi

    local reply
    read -r -p "  ? $question [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# Filesystem
# ---------------------------------------------------------------------------

# util::ensure_dir <path...> — create directories if missing.
util::ensure_dir() {
    local dir
    for dir in "$@"; do
        [[ -d "$dir" ]] && continue
        util::run mkdir -p -- "$dir"
    done
}

# util::append_once <file> <line> — add a line to a file if not already there.
#
# The idempotency helper for shell rc files: sourcing cargo's env, nvm's
# loader, and so on. Matches the whole line exactly to avoid false positives
# on substrings.
util::append_once() {
    local file="$1" line="$2"

    if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
        log::debug "already present in ${file/#$HOME/\~}: $line"
        return 0
    fi

    if util::is_dry; then
        log::dry "append to ${file/#$HOME/\~}: $line"
        return 0
    fi

    util::ensure_dir "$(dirname -- "$file")"
    printf '%s\n' "$line" >>"$file"
    log::debug "appended to ${file/#$HOME/\~}: $line"
}

# util::tmpdir — print a fresh temp directory, removed when this process exits.
#
# Callers use it as `dir="$(util::tmpdir)"`, which runs the function in a
# command-substitution subshell — so it cannot register the path in a shell
# variable for the cleanup trap to find. Instead every directory is named
# after the shell's PID, which `$$` reports identically inside subshells, and
# cleanup removes them by glob.
util::tmpdir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/setup.$$.XXXXXXXX")" \
        || util::die "Could not create a temporary directory"
    printf '%s' "$dir"
}

util::_cleanup_tmpdirs() {
    local dir
    for dir in "${TMPDIR:-/tmp}/setup.$$."*; do
        [[ -d "$dir" ]] && rm -rf -- "$dir"
    done
    return 0
}
trap util::_cleanup_tmpdirs EXIT

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# util::download <url> <dest> — fetch a URL to a file.
#
#   --fail          treat HTTP 4xx/5xx as an error instead of saving the body
#   --location      follow redirects (GitHub release assets always redirect)
#   --retry 3       survive a flaky connection
util::download() {
    local url="$1" dest="$2"

    log::debug "downloading $url"
    util::run curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 2 --connect-timeout 15 \
        --output "$dest" -- "$url"
}

# util::gh_latest_tag <owner/repo> — print the newest release tag.
#
# The unauthenticated GitHub API allows 60 requests per hour per IP. Export
# GITHUB_TOKEN to raise that if you hit the limit.
util::gh_latest_tag() {
    local repo="$1"
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local -a auth=()

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    # Fetch first, parse second — deliberately not `curl | grep -m1 | cut`.
    # `grep -m1` exits at the first match, curl then takes SIGPIPE, and
    # pipefail reports the whole pipeline as failed. Whether that happens
    # depends on which process finishes first, so the bug is intermittent.
    local json
    json="$(curl --fail --silent --location --connect-timeout 15 \
        "${auth[@]}" "$url")" || return 1

    # grep -o reads its input to EOF, so nothing here can be killed early.
    local -a matches=()
    mapfile -t matches < <(printf '%s' "$json" | grep -o '"tag_name"[^,]*')
    ((${#matches[@]} > 0)) || return 1

    # "tag_name": "v0.64.1"  ->  v0.64.1
    local tag="${matches[0]}"
    tag="${tag#*: \"}"
    tag="${tag%\"*}"

    [[ -n "$tag" ]] || return 1
    printf '%s' "$tag"
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

# util::version_gte <have> <want> — is <have> at least <want>?
#
# Uses sort -V, which understands 1.10 > 1.9. Leading "v" is tolerated.
util::version_gte() {
    local have="${1#v}" want="${2#v}"
    [[ "$have" == "$want" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" == "$want" ]]
}
