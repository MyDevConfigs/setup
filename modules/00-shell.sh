#!/usr/bin/env bash
# module-description: Install the configured shell, set it as login shell, seed PATH
# module-required: true
#
# Runs first, on every invocation, and cannot be skipped.
#
# Required because it establishes the file the rest of the repository writes
# to. Later modules add PATH entries and env loaders through lib/shell.sh,
# which targets whichever rc file the configured shell uses — and this module
# is what guarantees that file exists. Running `./setup.sh --only langs` on a
# fresh machine without it would leave rustup's loader line in a ~/.zshrc that
# oh-my-zsh later backs up and replaces.
#
# Which shell gets installed is a choice, not a constant. setup.sh resolves it
# before any module runs, from the environment, .setup.local, or a prompt.
#
# The login shell change takes effect at the next login, not immediately.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly OMZ_DIR="$HOME/.oh-my-zsh"
readonly OMZ_INSTALLER="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
readonly LOCAL_BIN="$HOME/.local/bin"

# A standalone run of this module never went through shell::choose, so fall
# back to whatever shell::load resolved.
: "${SETUP_SHELL:?No shell configured. Run ./setup.sh, or set SETUP_SHELL=zsh}"

log::info "Configuring shell: $SETUP_SHELL"

# ---------------------------------------------------------------------------
# 1. The shell itself
# ---------------------------------------------------------------------------

case "$SETUP_SHELL" in
    zsh)
        pkg::install zsh
        ;;
    bash)
        # bash is already present on any system running this script, and
        # Ubuntu ships a ~/.bashrc. Nothing to install; just make sure the
        # file exists before anything appends to it.
        if [[ -f "$SETUP_SHELL_RC" ]]; then
            log::skip "${SETUP_SHELL_RC/#$HOME/\~} (already exists)"
        else
            log::info "Creating ${SETUP_SHELL_RC/#$HOME/\~}"
            util::run touch "$SETUP_SHELL_RC"
        fi
        ;;
    *)
        util::die "No installation path for shell '$SETUP_SHELL'"
        ;;
esac

# ---------------------------------------------------------------------------
# 2. Framework
# ---------------------------------------------------------------------------

shell_module::install_zsh_framework() {
    case "${SETUP_ZSH_FRAMEWORK:-oh-my-zsh}" in
        none)
            log::info "No zsh framework requested (SETUP_ZSH_FRAMEWORK=none)"
            # Bare zsh has nothing to create ~/.zshrc, so do it here. Without
            # a file, zsh runs the new-user setup wizard on first login.
            if [[ ! -f "$SETUP_SHELL_RC" ]]; then
                log::info "Creating an empty ${SETUP_SHELL_RC/#$HOME/\~}"
                util::run touch "$SETUP_SHELL_RC"
            fi
            ;;
        oh-my-zsh)
            if [[ -d "$OMZ_DIR" ]]; then
                log::skip "oh-my-zsh (already installed at ${OMZ_DIR/#$HOME/\~})"
                return 0
            fi

            log::info "Installing oh-my-zsh"
            local installer
            installer="$(util::tmpdir)/install-ohmyzsh.sh"
            util::download "$OMZ_INSTALLER" "$installer"

            # --unattended does two things that matter. It stops the
            # installer exec'ing into a new zsh at the end, which would hang
            # setup.sh forever because nothing would ever return. And it
            # stops it calling chsh itself, so the login shell change below
            # goes through util::sudo and is logged like everything else.
            util::run sh "$installer" --unattended
            ;;
        *)
            util::die "Unknown SETUP_ZSH_FRAMEWORK: '${SETUP_ZSH_FRAMEWORK}'
    (expected: oh-my-zsh, none)"
            ;;
    esac
}

if [[ "$SETUP_SHELL" == "zsh" ]]; then
    shell_module::install_zsh_framework
fi

# ---------------------------------------------------------------------------
# 3. ~/.local/bin on PATH
#
# Reserved for the user's own scripts. Nothing this repository installs may
# be placed here — see "Where things get installed" in AGENTS.md. Tools go
# where their own documentation says: their own home (~/.nvm, ~/.pyenv),
# /opt for self-contained upstream trees, or /usr/local/bin for single
# binaries.
#
# The directory is created and put on PATH here rather than in a later
# module because this is the module that owns the rc file, and because the
# entry should exist from the very first run whether or not anything has
# been put in it yet. Ubuntu's stock ~/.profile adds this directory only if
# it already exists at login, and nothing adds it for zsh at all.
# ---------------------------------------------------------------------------

util::ensure_dir "$LOCAL_BIN"
shell::add_path "$LOCAL_BIN"

# ---------------------------------------------------------------------------
# 4. Login shell
# ---------------------------------------------------------------------------

# Under --dry-run the shell was never actually installed, so there is no
# binary to resolve. Report what would happen and stop.
if ! util::have "$SETUP_SHELL"; then
    if util::is_dry; then
        log::dry "chsh -s \$(command -v $SETUP_SHELL) $USER"
        log::success "Shell environment ready"
        exit 0
    fi
    util::die "$SETUP_SHELL is still not on PATH after installing it"
fi

shell_path="$(command -v "$SETUP_SHELL")"
readonly shell_path

current_shell="$(getent passwd "$USER" | cut -d: -f7)"
readonly current_shell

# Compare resolved paths, not strings. On a usrmerge system /bin/bash and
# /usr/bin/bash are the same file, and a string comparison would report a
# change that is not needed and run chsh pointlessly on every invocation.
if [[ "$(readlink -f "$current_shell" 2>/dev/null)" == "$(readlink -f "$shell_path")" ]]; then
    log::skip "login shell (already $current_shell)"
else
    # chsh refuses a shell that is not listed in /etc/shells. Distro packages
    # normally register themselves; this is a fallback for when they have not.
    if ! grep -qxF -- "$shell_path" /etc/shells 2>/dev/null; then
        log::info "Registering $shell_path in /etc/shells"
        util::sudo tee -a /etc/shells >/dev/null <<<"$shell_path"
    fi

    log::info "Setting login shell to $shell_path (was $current_shell)"
    # Through sudo so it reuses the session setup.sh already established;
    # unprivileged chsh would prompt for the password a second time.
    util::sudo chsh -s "$shell_path" "$USER"
    log::warn "Login shell changed — it takes effect at your next login."
fi

log::success "Shell environment ready"
