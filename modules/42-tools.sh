#!/usr/bin/env bash
# module-description: lazygit, starship and Task, from upstream releases
#
# Three tools whose archive versions lag far enough behind to be worth
# fetching from upstream. Everything here lands in /usr/local/bin — never
# ~/.local/bin, which is reserved for the user's own scripts.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly BIN_DIR="/usr/local/bin"
readonly STARSHIP_INSTALLER="https://starship.rs/install.sh"
readonly TASK_INSTALLER="https://taskfile.dev/install.sh"

# ---------------------------------------------------------------------------
# Step isolation
#
# The three tools here are unrelated, so one failing must not stop the
# others. Without this, a starship failure aborted the module under errexit
# and Task — which comes after it — was never even attempted.
#
# Each step runs in a subshell that re-enables errexit explicitly: bash
# disables it inside a command used as an `if` condition, so `( set -e; ... )`
# is what keeps a failure *within* a step from carrying on regardless.
# ---------------------------------------------------------------------------

declare -a FAILED_STEPS=()

tools::step() {
    local label="$1"
    shift

    if ( set -e; "$@" ); then
        return 0
    fi

    log::error "$label failed — continuing with the remaining tools"
    FAILED_STEPS+=("$label")
    return 0
}

# ---------------------------------------------------------------------------
# lazygit
#
# The archive is several releases behind; lazygit ships often and its keymap
# and config schema move with it.
# ---------------------------------------------------------------------------

tools::install_lazygit() {
    local tag version url
    tag="$(util::gh_latest_tag jesseduffield/lazygit)" || {
        log::warn "Could not reach the GitHub API — skipping lazygit"
        return 0
    }
    version="${tag#v}"

    # Release assets use uname's naming, not Debian's: x86_64, not amd64.
    url="https://github.com/jesseduffield/lazygit/releases/download/${tag}/lazygit_${version}_Linux_${OS_ARCH_RAW}.tar.gz"

    log::info "Installing lazygit $tag"
    util::install_tarball_binary "$url" lazygit "$BIN_DIR"
}

if util::have lazygit; then
    log::skip "lazygit (already installed: $(util::first_line lazygit --version))"
else
    tools::step "lazygit" tools::install_lazygit
fi

# ---------------------------------------------------------------------------
# starship
#
# The installer writes to /usr/local/bin, which needs root, so it is staged
# into a writable directory first and installed with sudo — the same pattern
# uv uses in 33-python.sh.
# ---------------------------------------------------------------------------

tools::install_starship() {
    local staging
    staging="$(util::tmpdir)/starship-bin"
    util::ensure_dir "$staging"

    # --interpreter sh is required, not stylistic: the installer checks
    # BASH_VERSION and exits 1 under bash, telling you to use sh.
    # -y skips the confirmation prompt, -b chooses the directory.
    util::install_script --interpreter sh "$STARSHIP_INSTALLER" -y -b "$staging"
    util::sudo install -m 0755 "$staging/starship" "$BIN_DIR/starship"
}

if util::have starship; then
    log::skip "starship (already installed: $(util::first_line starship --version))"
elif util::is_dry; then
    log::dry "install starship into $BIN_DIR"
else
    tools::step "starship" tools::install_starship
fi

# starship's prompt has to be initialised after any framework has loaded,
# which it is: this line is appended to the end of the rc file, so starship
# replaces whatever prompt oh-my-zsh's theme had set up. That is why
# ZSH_THEME does not need changing — a theme is still loaded, its prompt is
# just superseded.
if util::have starship || util::is_dry; then
    shell::add_line "eval \"\$(starship init ${SETUP_SHELL})\"" "starship init"
fi

# ---------------------------------------------------------------------------
# starship theme
#
# The portable path: write the preset only when nothing is there. If a config
# already exists it is left alone, whatever it is — a file the user wrote, a
# symlink from a dotfiles repo, or one of the rice's presets.
#
# Never write through a symlink. `starship preset -o` follows one, so running
# this against a symlinked config would silently overwrite its target — which
# on a machine with the KoolDots prompt switcher means corrupting one of its
# preset files while the menu still shows the old name.
# ---------------------------------------------------------------------------

readonly STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
readonly STARSHIP_PRESET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/starship"
readonly PRESET="gruvbox-rainbow"

tools::apply_starship_preset() {
    if [[ -L "$STARSHIP_CONFIG" ]]; then
        log::skip "starship config (symlink to $(readlink "$STARSHIP_CONFIG")) — not overwriting"
        return 0
    fi

    if [[ -e "$STARSHIP_CONFIG" ]]; then
        log::skip "starship config (${STARSHIP_CONFIG/#$HOME/\~} already exists)"
        return 0
    fi

    log::info "Writing the $PRESET preset to ${STARSHIP_CONFIG/#$HOME/\~}"
    util::run starship preset "$PRESET" -o "$STARSHIP_CONFIG"
}

# Optional extra, only where it applies. A preset library at
# ~/.config/starship/ means the KoolDots prompt switcher is installed, and
# dropping a copy in there adds it to that rofi menu by name. Harmless
# anywhere else, which is why it is guarded on the directory rather than on
# the desktop environment.
tools::add_starship_preset_to_library() {
    [[ -d "$STARSHIP_PRESET_DIR" ]] || return 0

    local target="$STARSHIP_PRESET_DIR/${PRESET}.toml"
    if [[ -e "$target" ]]; then
        log::skip "$PRESET in the preset library"
        return 0
    fi

    log::info "Adding $PRESET to the prompt-switcher library"
    util::run starship preset "$PRESET" -o "$target"
}

if util::have starship || util::is_dry; then
    if util::is_dry; then
        log::dry "starship preset $PRESET -o ${STARSHIP_CONFIG/#$HOME/\~}  (only if absent)"
    else
        tools::apply_starship_preset
        tools::add_starship_preset_to_library
    fi
fi

# ---------------------------------------------------------------------------
# Task
#
# Not in the archive under any name — the `task` package elsewhere is
# unrelated. The upstream installer takes a target directory.
# ---------------------------------------------------------------------------

tools::install_task() {
    local staging
    staging="$(util::tmpdir)/task-bin"
    util::ensure_dir "$staging"

    util::install_script "$TASK_INSTALLER" -d -b "$staging"
    util::sudo install -m 0755 "$staging/task" "$BIN_DIR/task"
}

if util::have task; then
    log::skip "task (already installed: $(util::first_line task --version))"
elif util::is_dry; then
    log::dry "install task into $BIN_DIR"
else
    tools::step "task" tools::install_task
fi

if ((${#FAILED_STEPS[@]} > 0)); then
    log::error "Not installed: ${FAILED_STEPS[*]}"
    exit 1
fi

log::success "Developer tools ready"
