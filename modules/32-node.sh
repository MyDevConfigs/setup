#!/usr/bin/env bash
# module-description: nvm, Node LTS, corepack (yarn/pnpm) and bun
#
# Node comes from nvm rather than the distro, so the version is yours to
# choose per project. That means the distro's node has to go first — see
# below; it is the only removal this repository performs.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly NVM_DIR="$HOME/.nvm"
readonly NVM_INSTALLER="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh"
readonly BUN_DIR="$HOME/.bun"
readonly BUN_INSTALLER="https://bun.sh/install"

# ---------------------------------------------------------------------------
# 1. Remove the distro's Node
#
# Leaving it installed puts /usr/bin/node and nvm's shim on PATH at the same
# time, and which one a tool sees depends on PATH order. The failure is
# quiet and confusing: `node -v` in your terminal reports one version while
# an editor's language server, a systemd unit or a cron job — none of which
# load your shell rc — silently get the other.
#
# node-typescript goes too: it is the distro's tsc, and it links against the
# distro's node.
# ---------------------------------------------------------------------------

declare -ra DISTRO_NODE=(nodejs npm node-typescript)

node::remove_distro_node() {
    local -a present=()
    local pkg

    for pkg in "${DISTRO_NODE[@]}"; do
        if pkg::is_installed "$pkg"; then
            present+=("$pkg")
        fi
    done

    if ((${#present[@]} == 0)); then
        log::skip "no distro Node packages installed"
        return 0
    fi

    log::warn "These distro packages conflict with nvm and will be removed:"
    log::warn "    ${present[*]}"

    if ! util::confirm "Remove them?"; then
        log::warn "Keeping them. /usr/bin/node and nvm's node will both be on"
        log::warn "PATH, and which one wins depends on PATH order."
        return 0
    fi

    util::sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${present[@]}"
}

node::remove_distro_node

# ---------------------------------------------------------------------------
# 2. nvm
# ---------------------------------------------------------------------------

node::install_nvm() {
    # PROFILE=/dev/null stops nvm's installer editing rc files itself. It
    # appends unconditionally and picks the file by sniffing, which means a
    # second run duplicates the block and a zsh user can end up with it in
    # ~/.bashrc. The block is added through lib/shell.sh below instead.
    PROFILE=/dev/null util::install_script "$NVM_INSTALLER"
}

# nvm is a shell function, not a binary, so util::ensure_command is no use
# here — `command -v nvm` finds nothing even on a machine that has it.
# The install directory is the reliable signal.
if [[ -d "$NVM_DIR" ]]; then
    log::skip "nvm (already at ${NVM_DIR/#$HOME/\~})"
else
    node::install_nvm
fi

# shellcheck disable=SC2016  # the rc file needs these unexpanded
shell::add_block "nvm" 'export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

# ---------------------------------------------------------------------------
# 3. Node LTS
# ---------------------------------------------------------------------------

if util::is_dry; then
    log::dry "nvm install --lts && nvm alias default 'lts/*'"
    log::dry "corepack enable  (provides yarn and pnpm)"
else
    # nvm.sh is written against an older, laxer shell contract and trips over
    # nounset immediately. errexit has to go too: nvm's functions return
    # non-zero for ordinary conditions such as "version already installed".
    set +u
    set +e
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"

    nvm install --lts
    nvm alias default 'lts/*'
    nvm use default

    set -e
    set -u

    log::success "Node: $(util::first_line node --version) (npm $(util::first_line npm --version))"

    # ---------------------------------------------------------------------
    # 4. yarn and pnpm, through corepack
    #
    # corepack ships with Node and manages yarn and pnpm as shims, resolving
    # the version from a project's "packageManager" field. That is why yarn
    # is not installed globally here: a global yarn is one version for every
    # project, and it fights corepack's shim for the same name on PATH.
    # ---------------------------------------------------------------------
    if util::have corepack; then
        util::run corepack enable
        log::success "corepack enabled — yarn and pnpm available"
    else
        log::warn "corepack is not bundled with this Node; installing it"
        util::run npm install -g corepack
        util::run corepack enable
    fi
fi

# ---------------------------------------------------------------------------
# 5. bun
# ---------------------------------------------------------------------------

node::install_bun() {
    BUN_INSTALL="$BUN_DIR" util::install_script "$BUN_INSTALLER"
}

if [[ -d "$BUN_DIR" ]]; then
    log::skip "bun (already at ${BUN_DIR/#$HOME/\~})"
else
    node::install_bun
fi

# bun's installer has no flag to stop it editing rc files, so it may have
# added its own PATH line in its own format. shell::add_path matches on the
# exact line it would write, so a differently-formatted line from bun means
# both end up present. Harmless — they set the same directory — but it is
# why this is the one entry that can appear twice.
shell::add_path "$BUN_DIR/bin" "bun"

log::success "Node toolchain ready"
