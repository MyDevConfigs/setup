# shellcheck shell=bash
#
# log.sh — leveled, colored logging.
#
# Everything goes to stderr so that stdout stays clean for real output; a
# function can `echo` a value and still log around it without corrupting it.

# ---------------------------------------------------------------------------
# Color
#
# Emit escapes only when stderr is a terminal, and honor the NO_COLOR
# convention (https://no-color.org). Piping the script to a file or a log
# collector then yields plain text with no manual flag.
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_DIM=$'\033[2m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_CYAN=$'\033[36m'
else
    readonly C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GREEN='' \
             C_YELLOW='' C_BLUE='' C_CYAN=''
fi

# Numeric severities, so a single comparison decides whether to print.
declare -rA _LOG_LEVELS=(
    [debug]=0
    [info]=1
    [warn]=2
    [error]=3
    [silent]=4
)

# log::_enabled <level> — is <level> at or above the configured threshold?
log::_enabled() {
    local want="${_LOG_LEVELS[$1]:-1}"
    local threshold="${_LOG_LEVELS[${SETUP_LOG_LEVEL:-info}]:-1}"
    ((want >= threshold))
}

# log::_emit <level> <color> <label> <message...>
log::_emit() {
    local level="$1" color="$2" label="$3"
    shift 3
    log::_enabled "$level" || return 0
    printf '%s%s%s %s\n' "$color" "$label" "$C_RESET" "$*" >&2
}

log::debug()   { log::_emit debug "$C_DIM"    "  ·"  "$*"; }
log::info()    { log::_emit info  "$C_BLUE"   "  ▸"  "$*"; }
log::success() { log::_emit info  "$C_GREEN"  "  ✓"  "$*"; }
log::skip()    { log::_emit info  "$C_DIM"    "  ="  "$*"; }
log::warn()    { log::_emit warn  "$C_YELLOW" "  !"  "$*"; }
log::error()   { log::_emit error "$C_RED"    "  ✗"  "$*"; }

# log::step — a heading for a phase of work, with blank-line separation.
log::step() {
    log::_enabled info || return 0
    printf '\n%s%s==>%s %s%s%s\n' \
        "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2
}

# log::cmd — echo a command as it is about to run.
log::cmd() {
    log::_enabled debug || return 0
    printf '%s    $ %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
}

# log::dry — echo a command that is being suppressed by --dry-run.
log::dry() {
    log::_enabled info || return 0
    printf '%s    [dry-run] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2
}

# log::banner — the title block printed once at startup.
log::banner() {
    log::_enabled info || return 0
    printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2
    printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..60})" "$C_RESET" >&2
}
