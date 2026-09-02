# shellcheck shell=bash
#
# shell.sh — the shell configuration contract.
#
# Modules never name an rc file and never write shell syntax by hand. They
# describe an intent:
#
#     shell::add_path   "$HOME/.local/bin"
#     shell::set_env    EDITOR nvim
#     shell::source_file "$HOME/.cargo/env"
#
# and the backend for the configured shell renders it. This is the same
# shape as lib/pkg.sh: a generic API on top, family dispatch below, real
# implementations for what is supported and honest stubs for what is not.
#
# Intent rather than raw text is what makes fish reachable. fish is not
# POSIX — `export PATH="x:$PATH"` is a syntax error there, and the
# equivalent is `fish_add_path x` — so an API that passed raw lines around
# could never grow a fish backend without rewriting every call site.
#
# Two operations remain POSIX-only, because they take opaque text that this
# layer cannot re-render: shell::add_line and shell::add_block. Both refuse
# to run on a non-POSIX shell rather than writing something broken.
#
# All writes are idempotent and honor --dry-run.

# Shells this repo knows about. zsh and bash are implemented; fish has a
# complete backend but is gated off until it has been tested.
declare -gra SHELL_FAMILIES=(zsh bash fish)

# Used when nothing is persisted, nothing is in the environment, and there
# is no terminal to ask at.
declare -gr SHELL_DEFAULT="zsh"

# Machine-local choices. Deliberately not committed: it records what this
# particular machine answered, so a fresh clone asks again.
: "${SETUP_SHELL_CONFIG:=$SETUP_ROOT/.setup.local}"

# ---------------------------------------------------------------------------
# Choice resolution
#
# Precedence, highest first:
#   1. The environment      SETUP_SHELL=bash ./setup.sh
#   2. .setup.local         written by a previous interactive run
#   3. An interactive prompt
#   4. SHELL_DEFAULT, with a warning
# ---------------------------------------------------------------------------

# shell::load — resolve from environment and the local config file only.
#
# Called during bootstrap, so it must never prompt: `./setup.sh --list` and
# a standalone module run both reach this and neither should block on input.
shell::load() {
    shell::_read_config

    if [[ -n "${SETUP_SHELL:-}" ]]; then
        shell::_apply "$SETUP_SHELL"
    fi
    return 0
}

# shell::choose — resolve interactively if it is still unset.
#
# Called by setup.sh once, before any module runs, so the question is asked
# up front rather than surfacing halfway through an install.
shell::choose() {
    if [[ -n "${SETUP_SHELL:-}" ]]; then
        log::debug "shell already resolved: $SETUP_SHELL"
        return 0
    fi

    if ! util::is_interactive || [[ "${SETUP_ASSUME_YES:-0}" == "1" ]]; then
        log::warn "No shell configured and nothing to ask — using $SHELL_DEFAULT."
        log::warn "Set SETUP_SHELL=<zsh|bash> or run interactively to choose."
        shell::_apply "$SHELL_DEFAULT"
        return 0
    fi

    printf '\n  Which shell should this machine use?\n' >&2
    printf '    %szsh%s   with oh-my-zsh (default)\n' "$C_CYAN" "$C_RESET" >&2
    printf '    %sbash%s  bare, using the existing ~/.bashrc\n\n' "$C_CYAN" "$C_RESET" >&2

    local reply
    while true; do
        read -r -p "  ? shell [zsh/bash] " reply
        reply="${reply:-$SHELL_DEFAULT}"
        case "$reply" in
            zsh | bash)
                shell::_apply "$reply"
                break
                ;;
            fish)
                log::error "fish is not supported yet — see _shell::fish::* in lib/shell.sh"
                ;;
            *)
                log::error "Please answer 'zsh' or 'bash'."
                ;;
        esac
    done

    shell::_persist
}

# shell::_apply <family> — validate the choice and derive everything from it.
shell::_apply() {
    local family="$1" known

    local supported=0
    for known in "${SHELL_FAMILIES[@]}"; do
        [[ "$family" == "$known" ]] && supported=1
    done
    ((supported)) || util::die "Unknown shell: '$family' (expected: ${SHELL_FAMILIES[*]})"

    SETUP_SHELL="$family"
    SETUP_SHELL_RC="$("_shell::${family}::rc_path")"
    : "${SETUP_ZSH_FRAMEWORK:=oh-my-zsh}"

    export SETUP_SHELL SETUP_SHELL_RC SETUP_ZSH_FRAMEWORK
}

# shell::_read_config — load .setup.local, without executing it.
#
# Parsed rather than sourced: a config file should not be able to run
# arbitrary code just because it is read. Unknown keys are ignored, and
# values already set in the environment win.
shell::_read_config() {
    local file="$SETUP_SHELL_CONFIG"
    [[ -f "$file" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"

        case "$key" in
            SETUP_SHELL)
                if [[ -z "${SETUP_SHELL:-}" ]]; then SETUP_SHELL="$value"; fi
                ;;
            SETUP_ZSH_FRAMEWORK)
                if [[ -z "${SETUP_ZSH_FRAMEWORK:-}" ]]; then SETUP_ZSH_FRAMEWORK="$value"; fi
                ;;
            *)
                log::debug "ignoring unknown key in ${file##*/}: $key"
                ;;
        esac
    done <"$file"
    return 0
}

# shell::_persist — record the answer so the next run does not ask again.
shell::_persist() {
    local file="$SETUP_SHELL_CONFIG"

    if util::is_dry; then
        log::dry "save SETUP_SHELL=$SETUP_SHELL to ${file##*/}"
        return 0
    fi

    {
        printf '# Written by setup.sh. Machine-local, not committed.\n'
        printf '# Delete this file to be asked again.\n'
        printf 'SETUP_SHELL=%s\n' "$SETUP_SHELL"
        printf 'SETUP_ZSH_FRAMEWORK=%s\n' "${SETUP_ZSH_FRAMEWORK:-oh-my-zsh}"
    } >"$file"

    log::success "Saved to ${file##*/} — delete it to be asked again"
}

# ---------------------------------------------------------------------------
# Generic API
# ---------------------------------------------------------------------------

# shell::rc_path — the rc file modules write to.
shell::rc_path() {
    printf '%s' "${SETUP_SHELL_RC:?shell not resolved; call shell::load first}"
}

# shell::is_posix — does the configured shell speak POSIX syntax?
shell::is_posix() {
    "_shell::${SETUP_SHELL}::is_posix"
}

# shell::assert_supported — abort if the configured shell has no backend.
shell::assert_supported() {
    if ! declare -F "_shell::${SETUP_SHELL}::rc_path" >/dev/null; then
        util::die "No backend for shell: ${SETUP_SHELL}"
    fi
    "_shell::${SETUP_SHELL}::assert_supported"
}

# shell::add_path <dir> [label] — prepend a directory to PATH.
shell::add_path() {
    local dir="$1" label="${2:-PATH += $1}"
    shell::_write "$("_shell::${SETUP_SHELL}::render_path" "$dir")" "$label"
}

# shell::set_env <NAME> <VALUE> [label] — export an environment variable.
shell::set_env() {
    local name="$1" value="$2" label="${3:-$1=$2}"
    shell::_write "$("_shell::${SETUP_SHELL}::render_env" "$name" "$value")" "$label"
}

# shell::source_file <path> [label] — source a file from the rc.
#
# The backend picks the right variant: rustup, nvm and friends ship a
# separate `.fish` script because their POSIX one cannot be parsed by fish.
shell::source_file() {
    local path="$1" label="${2:-source ${1##*/}}"
    shell::_write "$("_shell::${SETUP_SHELL}::render_source" "$path")" "$label"
}

# shell::add_line <raw> [label] — append a literal POSIX line.
#
# Escape hatch for anything the semantic operations above do not cover.
# Refuses to run on a non-POSIX shell, because this layer has no way to
# translate opaque text.
shell::add_line() {
    local line="$1" label="${2:-$1}"

    if ! shell::is_posix; then
        util::die "shell::add_line is POSIX-only and the configured shell is
    '${SETUP_SHELL}'. Use shell::add_path / shell::set_env / shell::source_file,
    which every backend can render."
    fi

    shell::_write "$line" "$label"
}

# shell::add_block <marker> <content> — append a fenced multi-line block once.
shell::add_block() {
    local marker="$1" content="$2"
    local rc="$SETUP_SHELL_RC"
    local pretty="${rc/#$HOME/\~}"
    local begin="# >>> ${marker} >>>"
    local end="# <<< ${marker} <<<"

    if ! shell::is_posix; then
        util::die "shell::add_block is POSIX-only and the configured shell is
    '${SETUP_SHELL}'."
    fi

    if [[ -f "$rc" ]] && grep -qxF -- "$begin" "$rc"; then
        log::skip "$marker block (already in $pretty)"
        return 0
    fi

    if util::is_dry; then
        log::dry "append '$marker' block to $pretty"
        return 0
    fi

    log::info "$pretty += $marker block"
    util::ensure_dir "$(dirname -- "$rc")"
    {
        printf '\n%s\n' "$begin"
        printf '%s\n' "$content"
        printf '%s\n' "$end"
    } >>"$rc"
}

# shell::_write <line> <label> — the single point where the rc file is touched.
shell::_write() {
    local line="$1" label="$2"
    local rc="$SETUP_SHELL_RC"
    local pretty="${rc/#$HOME/\~}"

    if [[ -f "$rc" ]] && grep -qxF -- "$line" "$rc"; then
        log::skip "$label (already in $pretty)"
        return 0
    fi

    log::info "$pretty += $label"
    util::append_once "$rc" "$line"
}

# ---------------------------------------------------------------------------
# zsh — implemented
# ---------------------------------------------------------------------------

_shell::zsh::assert_supported() { return 0; }
_shell::zsh::rc_path()          { printf '%s' "$HOME/.zshrc"; }
_shell::zsh::is_posix()         { return 0; }
_shell::zsh::render_path()      { _shell::posix::render_path "$@"; }
_shell::zsh::render_env()       { _shell::posix::render_env "$@"; }
_shell::zsh::render_source()    { _shell::posix::render_source "$@"; }

# ---------------------------------------------------------------------------
# bash — implemented
# ---------------------------------------------------------------------------

_shell::bash::assert_supported() { return 0; }
_shell::bash::rc_path()          { printf '%s' "$HOME/.bashrc"; }
_shell::bash::is_posix()         { return 0; }
_shell::bash::render_path()      { _shell::posix::render_path "$@"; }
_shell::bash::render_env()       { _shell::posix::render_env "$@"; }
_shell::bash::render_source()    { _shell::posix::render_source "$@"; }

# Shared renderers. bash and zsh differ in plenty of ways, but not in how a
# PATH entry, an export or a source line is written.
#
# $PATH is left unexpanded in the written line so the rc file stays correct
# regardless of what PATH happened to be when setup.sh ran.
_shell::posix::render_path()   { printf 'export PATH="%s:$PATH"' "$1"; }
_shell::posix::render_source() { printf '. "%s"' "$1"; }
_shell::posix::render_env() {
    local value="${2//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf 'export %s="%s"' "$1" "$value"
}

# ---------------------------------------------------------------------------
# fish — written, not yet enabled
#
# The renderers below are believed correct but untested, so
# assert_supported refuses. Removing that refusal (and testing it) is all
# that adding fish support should require — no module changes.
# ---------------------------------------------------------------------------

_shell::fish::assert_supported() {
    util::die "fish support is not enabled yet. The backend exists in
    lib/shell.sh but is untested; remove the guard in
    _shell::fish::assert_supported once you have verified it.
    Note that shell::add_line and shell::add_block cannot work under fish."
}

_shell::fish::rc_path()  { printf '%s' "$HOME/.config/fish/config.fish"; }
_shell::fish::is_posix() { return 1; }

# fish_add_path is idempotent in fish itself and handles ordering properly.
_shell::fish::render_path() { printf 'fish_add_path %s' "$1"; }

_shell::fish::render_env() {
    local value="${2//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf 'set -gx %s "%s"' "$1" "$value"
}

# Tools that ship a POSIX env script almost always ship a .fish sibling,
# because fish cannot parse the original. Prefer it when it exists.
_shell::fish::render_source() {
    local path="$1"
    if [[ -f "${path}.fish" ]]; then
        printf 'source "%s.fish"' "$path"
    else
        printf 'source "%s"' "$path"
    fi
}
