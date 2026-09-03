#!/usr/bin/env bash
# module-description: zsh autosuggestions and syntax highlighting
#
# The two plugins nearly every zsh user ends up adding. Both are in the
# distro archive, so there is no need to clone them into ZSH_CUSTOM the way
# most guides describe.
#
# They are sourced directly from the rc file rather than added to oh-my-zsh's
# plugins=() array. That array is an existing line that would have to be
# edited in place, and this repository only ever appends — an append is
# idempotent and cannot corrupt a file it did not write. Sourcing is also the
# documented manual installation method, and works with bare zsh too.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

if [[ "${SETUP_SHELL:-}" != "zsh" ]]; then
    log::skip "shell is '${SETUP_SHELL:-unset}', not zsh — nothing to do"
    exit 0
fi

os::require_family debian

pkg::install zsh-autosuggestions zsh-syntax-highlighting

readonly AUTOSUGGESTIONS="/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
readonly HIGHLIGHTING="/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# Order matters, and this is the one place in the repo where it does.
# zsh-syntax-highlighting wraps the line editor and must be sourced last, or
# it does not see the widgets other plugins install. Appends land in call
# order, so highlighting goes second.
zshplugins::add() {
    local path="$1" label="$2"

    if [[ ! -f "$path" ]] && ! util::is_dry; then
        log::warn "$label not found at $path — skipping"
        return 0
    fi

    shell::source_file "$path" "$label"
}

zshplugins::add "$AUTOSUGGESTIONS" "zsh-autosuggestions"
zshplugins::add "$HIGHLIGHTING" "zsh-syntax-highlighting"

log::success "zsh plugins ready"
