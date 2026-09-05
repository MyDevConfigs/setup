#!/usr/bin/env bash
# module-description: Claude Code and GitHub Copilot CLI
#
# Two AI coding assistants, each from its vendor's own install script.
# Neither is packaged anywhere useful, and neither needs Node: Copilot ships
# a standalone binary and Claude Code's installer fetches one, so this module
# has no ordering dependency on 32-node.sh.
#
# Both update themselves, so this module only ever installs a missing tool —
# the same rule the toolchains follow. And neither does anything until you
# log in, which is an account decision rather than provisioning: the hint is
# printed once, on the run that installs the tool, and never again.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly BIN_DIR="/usr/local/bin"
readonly CLAUDE_INSTALLER="https://claude.ai/install.sh"
readonly COPILOT_INSTALLER="https://gh.io/copilot-install"

# ---------------------------------------------------------------------------
# Step isolation
#
# The same reasoning as 42-tools.sh: the two tools are unrelated, so one
# vendor's installer failing must not stop the other. The subshell re-enables
# errexit explicitly, because bash disables it inside an `if` condition.
#
# Unlike its counterpart in 42-tools.sh this one reports the outcome, since
# the caller needs to know whether the tool was actually installed before
# printing a first-run hint about it. The non-zero return is always consumed
# by an `if`, so it never reaches an ERR trap.
# ---------------------------------------------------------------------------

declare -a FAILED_STEPS=()

ai::step() {
    local label="$1"
    shift

    if ( set -e; "$@" ); then
        return 0
    fi

    log::error "$label failed — continuing with the remaining tools"
    FAILED_STEPS+=("$label")
    return 1
}

CLAUDE_FRESH=0
COPILOT_FRESH=0

# ---------------------------------------------------------------------------
# Claude Code
#
# The single exception to "nothing this repository installs goes in
# ~/.local/bin" — named as such in AGENTS.md, and it stops there.
#
# The installer downloads a binary to ~/.claude/downloads and then runs
# `claude install`, and that second step is what picks the destination. It
# takes no --bin-dir, reads no install-directory variable, and its only
# argument is stable|latest|VERSION. It also writes its own shell
# integration, which is equally not suppressible — the one third-party rc
# edit this repo does not own. Redirecting the first install would not hold
# anyway: Claude Code updates itself into that same directory afterwards.
#
# ~/.local/bin is already on PATH by the time this runs. 00-shell.sh is
# required and puts it there on every invocation.
# ---------------------------------------------------------------------------

ai::install_claude() {
    # `claude install` draws a TUI on its way through. It finishes on its
    # own; there is nothing here that needs to answer it.
    util::install_script "$CLAUDE_INSTALLER"
}

if util::have claude; then
    log::skip "Claude Code (already installed: $(command -v claude))"
elif util::is_dry; then
    log::dry "install Claude Code into ~/.local/bin"
else
    log::info "Installing Claude Code"
    if ai::step "Claude Code" ai::install_claude; then
        CLAUDE_FRESH=1
    fi
fi

# ---------------------------------------------------------------------------
# GitHub Copilot CLI
#
# https://gh.io/copilot-install redirects to github/copilot-cli's install.sh.
# Left to itself it installs into ~/.local/bin, which this repo may not
# touch — but it documents a PREFIX variable, so the tarball is staged into a
# temporary tree and installed to /usr/local/bin with sudo. That is the shape
# 42-tools.sh uses for starship and Task, and it also means a script fetched
# over the network never runs as root.
#
# PATH is extended across the call for one specific reason. After extracting,
# the installer runs `command -v copilot`, and when that fails it *prompts*,
# offering to append `export PATH="<staging>/bin:$PATH"` to ~/.zprofile — a
# temporary path, written to a file this repo does not manage. It reads the
# answer from /dev/tty rather than stdin, so redirecting input does not
# silence it. Letting its own check succeed does.
# ---------------------------------------------------------------------------

ai::install_copilot() {
    local staging
    staging="$(util::tmpdir)/copilot"
    util::ensure_dir "$staging"

    PREFIX="$staging" PATH="$staging/bin:$PATH" \
        util::install_script "$COPILOT_INSTALLER"

    [[ -x "$staging/bin/copilot" ]] \
        || util::die "The Copilot installer left no binary in $staging/bin"

    util::sudo install -m 0755 "$staging/bin/copilot" "$BIN_DIR/copilot"
}

if util::have copilot; then
    log::skip "copilot (already installed: $(command -v copilot))"
elif util::is_dry; then
    log::dry "install the GitHub Copilot CLI into $BIN_DIR"
else
    log::info "Installing the GitHub Copilot CLI"
    if ai::step "GitHub Copilot CLI" ai::install_copilot; then
        COPILOT_FRESH=1
    fi
fi

# ---------------------------------------------------------------------------
# First-run hints
#
# Only for a tool this run actually installed. Repeating them on every
# invocation would be noise on a machine that logged in months ago, and
# there is no artifact on disk that reliably distinguishes "authenticated"
# from "not" for either tool.
# ---------------------------------------------------------------------------

if ((CLAUDE_FRESH)); then
    log::warn "Claude Code needs a one-time login — run 'claude' to authenticate."
    log::warn "It was installed into ~/.local/bin; open a new shell to pick it up."
fi

if ((COPILOT_FRESH)); then
    log::warn "Copilot CLI needs a one-time login — run 'copilot', then /login."
    log::warn "It requires an active GitHub Copilot subscription."
fi

if ((${#FAILED_STEPS[@]} > 0)); then
    log::error "Not installed: ${FAILED_STEPS[*]}"
    exit 1
fi

log::success "AI assistants ready"
