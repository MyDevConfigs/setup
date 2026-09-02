#!/usr/bin/env bash
#
# setup.sh — provision a development machine.
#
# Discovers the executable modules in modules/, filters them against --only
# and --skip, and runs each one in its own process. Every module is
# idempotent, so running this on an already-configured machine is a safe
# no-op that reports what it skipped.
#
#   ./setup.sh                    run everything
#   ./setup.sh --list             show available modules, run nothing
#   ./setup.sh --dry-run          print every command, change nothing
#   ./setup.sh --only cli,langs   run just those modules
#   ./setup.sh --skip containers  run everything except that one
#
# Repository: https://github.com/<user>/setup

set -o errexit   # abort on any unhandled non-zero status
set -o nounset   # abort on expansion of an unset variable
set -o pipefail  # a pipeline fails if any stage fails
set -o errtrace  # let the ERR trap fire inside functions too

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_ROOT
export SETUP_ROOT

readonly MODULES_DIR="$SETUP_ROOT/modules"

# shellcheck source=lib/bootstrap.sh
source "$SETUP_ROOT/lib/bootstrap.sh"

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

main::on_error() {
    local status="$1" line="$2" command="$3"
    log::error "Failed at line ${line}: ${command}"
    log::error "Exit status ${status}"
    exit "$status"
}
trap 'main::on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

main::usage() {
    cat <<'EOF'
setup.sh — provision a development machine

USAGE
    ./setup.sh [OPTIONS]

OPTIONS
    -l, --list             List available modules and exit
    -o, --only  <a,b,c>    Run only these modules
    -s, --skip  <a,b,c>    Run everything except these modules
    -n, --dry-run          Print commands without executing them
    -y, --yes              Answer yes to every prompt (unattended runs)
    -v, --verbose          Show debug output, including each command
    -q, --quiet            Warnings and errors only
    -h, --help             Show this help and exit

ENVIRONMENT
    GITHUB_TOKEN           Raises the GitHub API rate limit used when
                           resolving the latest release of a tool
    NO_COLOR               Disable colored output

EXAMPLES
    ./setup.sh --list
    ./setup.sh --dry-run
    ./setup.sh --only core,cli
    ./setup.sh --skip containers --yes
EOF
}

# ---------------------------------------------------------------------------
# Module discovery
#
# A module is an executable file at modules/NN-<name>.sh. The numeric prefix
# orders execution; <name> is what --only and --skip match against.
# ---------------------------------------------------------------------------

# main::module_name <path> — modules/10-cli.sh -> cli
main::module_name() {
    local base
    base="$(basename -- "$1" .sh)"
    printf '%s' "${base#*-}"
}

# main::module_description <path> — read the "# module-description:" header.
main::module_description() {
    local line
    line="$(grep -m1 '^# module-description:' -- "$1" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
        printf '%s' "${line#\# module-description: }"
    else
        printf '(no description)'
    fi
}

# main::discover — print every module path, in execution order.
main::discover() {
    [[ -d "$MODULES_DIR" ]] || return 0
    # A glob that matches nothing expands to itself, so check existence.
    local path
    for path in "$MODULES_DIR"/[0-9][0-9]-*.sh; do
        [[ -f "$path" ]] && printf '%s\n' "$path"
    done
}

main::list_modules() {
    local -a modules
    mapfile -t modules < <(main::discover)

    if ((${#modules[@]} == 0)); then
        log::warn "No modules found in ${MODULES_DIR/#$HOME/\~}"
        return 0
    fi

    printf '\n%sAvailable modules%s\n\n' "$C_BOLD" "$C_RESET"
    local path
    for path in "${modules[@]}"; do
        printf '  %s%-14s%s %s\n' \
            "$C_CYAN" "$(main::module_name "$path")" "$C_RESET" \
            "$(main::module_description "$path")"
    done
    printf '\n'
}

# main::selected <name> — should this module run, given --only and --skip?
main::selected() {
    local name="$1" entry

    if ((${#ONLY[@]} > 0)); then
        for entry in "${ONLY[@]}"; do
            [[ "$entry" == "$name" ]] && return 0
        done
        return 1
    fi

    for entry in "${SKIP[@]:-}"; do
        [[ "$entry" == "$name" ]] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

main::preflight() {
    # Bash 4 gives us associative arrays and mapfile, both used throughout.
    if ((BASH_VERSINFO[0] < 4)); then
        util::die "Bash 4.0 or newer is required (found ${BASH_VERSION})"
    fi

    # Running the whole script as root would leave every file it creates in
    # $HOME owned by root. Individual commands escalate via util::sudo.
    if util::is_root; then
        util::die "Do not run setup.sh as root. Run it as your normal user;
    it will call sudo only where a command actually needs it."
    fi

    pkg::assert_supported

    local -a required=(curl grep sed awk)
    local cmd
    for cmd in "${required[@]}"; do
        util::have "$cmd" || util::die "Required command not found: $cmd"
    done
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

main::run_modules() {
    local -a modules
    mapfile -t modules < <(main::discover)

    if ((${#modules[@]} == 0)); then
        log::warn "No modules found in ${MODULES_DIR/#$HOME/\~} — nothing to do."
        log::info "Add modules as modules/NN-<name>.sh and re-run."
        return 0
    fi

    local -a ran=() failed=() skipped=()
    local path name started elapsed

    for path in "${modules[@]}"; do
        name="$(main::module_name "$path")"

        if ! main::selected "$name"; then
            skipped+=("$name")
            log::debug "skipping module: $name"
            continue
        fi

        log::step "$name — $(main::module_description "$path")"
        started=$SECONDS

        # Modules run in their own process: a failure is contained, and no
        # module can leak variables or function definitions into another.
        # The ERR trap must not fire here, so the status is tested inline.
        if bash "$path"; then
            elapsed=$((SECONDS - started))
            ran+=("$name")
            log::success "$name completed in ${elapsed}s"
        else
            elapsed=$((SECONDS - started))
            failed+=("$name")
            log::error "$name failed after ${elapsed}s"
        fi
    done

    main::summary "${#ran[@]}" "${#failed[@]}" "${#skipped[@]}" "${failed[@]:-}"
}

main::summary() {
    local ok="$1" fail="$2" skip="$3"
    shift 3
    local -a failed=("$@")

    log::banner "Summary"
    printf '  %s%d succeeded%s   %s%d failed%s   %s%d skipped%s   %s%ds total%s\n' \
        "$C_GREEN" "$ok" "$C_RESET" \
        "$( ((fail > 0)) && printf '%s' "$C_RED" || printf '%s' "$C_DIM")" \
        "$fail" "$C_RESET" \
        "$C_DIM" "$skip" "$C_RESET" \
        "$C_DIM" "$SECONDS" "$C_RESET" >&2

    if ((fail > 0)); then
        printf '\n' >&2
        local name
        for name in "${failed[@]}"; do
            [[ -n "$name" ]] && log::error "failed: $name"
        done
        printf '\n' >&2
        log::info "Re-run just the failures with: ./setup.sh --only $(
            IFS=,; printf '%s' "${failed[*]}")"

        # Record the failure for main() to turn into an exit status, rather
        # than returning non-zero from here. With errtrace on, a bare
        # `return 1` fires the ERR trap and prints a spurious "Failed at
        # line N" for what is a deliberate, already-reported outcome.
        FAILED_COUNT=$fail
    fi

    if util::is_dry; then
        printf '\n' >&2
        log::warn "This was a dry run. Nothing was changed."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

declare -a ONLY=()
declare -a SKIP=()
LIST_ONLY=0

# Set by main::summary, turned into the process exit status by main().
declare -i FAILED_COUNT=0

main::parse_args() {
    while (($# > 0)); do
        case "$1" in
            -l | --list)    LIST_ONLY=1 ;;
            -n | --dry-run) SETUP_DRY_RUN=1 ;;
            -y | --yes)     SETUP_ASSUME_YES=1 ;;
            -v | --verbose) SETUP_LOG_LEVEL=debug ;;
            -q | --quiet)   SETUP_LOG_LEVEL=warn ;;
            -h | --help)    main::usage; exit 0 ;;
            -o | --only)
                [[ $# -ge 2 ]] || util::die "--only requires a value"
                IFS=, read -r -a ONLY <<<"$2"
                shift ;;
            -s | --skip)
                [[ $# -ge 2 ]] || util::die "--skip requires a value"
                IFS=, read -r -a SKIP <<<"$2"
                shift ;;
            --) shift; break ;;
            -*) util::die "Unknown option: $1 (try --help)" ;;
            *)  util::die "Unexpected argument: $1 (try --help)" ;;
        esac
        shift
    done

    export SETUP_DRY_RUN SETUP_ASSUME_YES SETUP_LOG_LEVEL
}

main() {
    main::parse_args "$@"

    if ((LIST_ONLY)); then
        main::list_modules
        exit 0
    fi

    log::banner "Machine setup"
    log::info "Host:   $(os::summary)"
    log::info "Loader: $(pkg::manager)"
    util::is_dry && log::warn "Dry run — no changes will be made"

    main::preflight

    # A run-scoped state directory lets modules in separate processes share
    # facts, such as whether the package index has been refreshed yet.
    SETUP_STATE_DIR="$(util::tmpdir)"
    export SETUP_STATE_DIR

    util::is_dry || util::sudo_init

    main::run_modules

    # Exit non-zero if any module failed, so CI and `&&` chains see it.
    ((FAILED_COUNT == 0)) || exit 1
}

main "$@"
