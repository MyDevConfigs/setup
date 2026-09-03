#!/usr/bin/env bash
# module-description: Rust tools installed with cargo
#
# Crates that are not packaged anywhere useful and are best taken straight
# from crates.io. Each is compiled locally, so this module is slow on a
# first run — minutes, not seconds.
#
# cargo installs into ~/.cargo/bin, which is cargo's own home and already on
# PATH from rustup's env. That is a destination this repo is allowed to use,
# unlike ~/.local/bin, which belongs to the user — see AGENTS.md.
#
# Ordered after 30-langs.sh because it needs the toolchain that module
# installs.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"

# Crates to install, as "crate name:binary name". The two differ often
# enough to be worth stating: grip-grab's Cargo.toml declares
# [[bin]] name = "gg", so checking for a binary called "grip-grab" would
# reinstall it on every run.
declare -ra CRATES=(
    "grip-grab:gg"                    # a faster, lighter ripgrep alternative
    "tree-sitter-cli:tree-sitter"     # parser generator; nvim-treesitter uses it
)

# ---------------------------------------------------------------------------
# cargo
#
# rustup may have been installed by 30-langs.sh earlier in this same run, in
# which case it is not on this process's PATH yet — modules run as separate
# processes and none of them re-reads the rc file.
# ---------------------------------------------------------------------------

if [[ -d "$CARGO_BIN" ]]; then
    PATH="$CARGO_BIN:$PATH"
fi

if ! util::have cargo; then
    if util::is_dry; then
        log::dry "cargo install --locked <crates>   (cargo not present yet)"
        log::success "Cargo tools ready"
        exit 0
    fi
    util::die "cargo is not installed. Run ./setup.sh --only langs first."
fi

log::info "Using $(util::first_line cargo --version)"

# ---------------------------------------------------------------------------
# Install
#
# Checking for the binary first rather than relying on cargo's own "already
# installed" behaviour: that still resolves the crate over the network on
# every run, and this keeps a no-op run genuinely offline.
#
# --locked builds against the Cargo.lock the crate was published with,
# instead of resolving fresh dependency versions that upstream never tested.
# ---------------------------------------------------------------------------

cargo::install_crate() {
    local crate="$1" binary="$2"

    if [[ -x "$CARGO_BIN/$binary" ]]; then
        log::skip "$crate ($binary already at ${CARGO_BIN/#$HOME/\~}/$binary)"
        return 0
    fi

    log::info "Compiling $crate — this can take a few minutes"
    util::run cargo install --locked "$crate"
}

for entry in "${CRATES[@]}"; do
    cargo::install_crate "${entry%%:*}" "${entry##*:}"
done

# ---------------------------------------------------------------------------
# gg vs. oh-my-zsh
#
# grip-grab's binary is `gg`, and oh-my-zsh's git plugin defines
# `alias gg='git gui citool'` (git.plugin.zsh:231). An alias wins over a
# binary on PATH, so without this the tool installs successfully and then
# cannot be run under its own name — which is exactly the failure grip-grab's
# own README warns about.
#
# The line has to come after oh-my-zsh has loaded, which it does: everything
# this repo writes is appended to the end of the rc file. The redirect and
# `|| true` matter because zsh treats unaliasing something that is not an
# alias as an error, and this must not break shell startup for anyone who is
# not running the git plugin.
# ---------------------------------------------------------------------------

if [[ -x "$CARGO_BIN/gg" ]] || util::is_dry; then
    if [[ "${SETUP_SHELL:-}" == "zsh" ]]; then
        shell::add_line 'unalias gg 2>/dev/null || true' "unalias gg (frees the name for grip-grab)"
    fi
fi

log::success "Cargo tools ready"
