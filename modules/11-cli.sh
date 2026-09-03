#!/usr/bin/env bash
# module-description: Modern CLI tools from the distro archive
#
# Everything here is a plain distro package whose archive version is current
# enough to be worth taking. Tools that ship stale in the archive — lazygit,
# starship, neovim — come from upstream in their own modules instead.
#
# Separate from 10-core because core is the set everything else assumes:
# compilers, git, curl. These are quality-of-life, and a minimal machine can
# skip them without breaking anything downstream.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

declare -ra PACKAGES=(
    # Searching and navigating
    ripgrep     # rg — fast recursive grep
    fd          # fd — friendlier find
    zoxide      # smarter cd, learns your habits
    tree

    # Reading
    bat         # cat with syntax highlighting and paging
    eza         # ls with colours, icons and a --tree mode
    jq          # JSON processor

    # Git
    delta       # syntax-highlighted, word-level git diffs

    # Environment and sessions
    direnv      # per-directory environment, auto-loaded on cd
    tmux        # terminal multiplexer

    # Monitoring
    btop

    # Task running and history
    just        # project-scoped command runner
    atuin       # searchable shell history
)

pkg::install "${PACKAGES[@]}"

# ---------------------------------------------------------------------------
# Canonical binary names
#
# Debian renames two of these to avoid clashing with older packages: `fd`
# belongs to fdclone and `bat` to bacula-console, so the archive ships them
# as `fdfind` and `batcat`. Every tutorial, alias and editor plugin expects
# the upstream names.
#
# The symlinks go in /usr/local/bin, not ~/.local/bin — that directory is
# reserved for the user's own scripts. /usr/local/bin is the FHS location
# for locally-installed binaries and is already ahead of /usr/bin on PATH.
# ---------------------------------------------------------------------------

cli::link_canonical_name() {
    local generic="$1"
    local real target="/usr/local/bin/$1"

    real="$(pkg::binary_for "$generic")"

    # On a distro that does not rename it, there is nothing to do.
    if [[ "$real" == "$generic" ]]; then
        log::debug "$generic is not renamed on $OS_FAMILY"
        return 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        log::skip "$generic -> $real ($target already exists)"
        return 0
    fi

    if ! util::have "$real"; then
        # Reachable under --dry-run, where the package was never installed.
        if util::is_dry; then
            log::dry "ln -s \$(command -v $real) $target"
        else
            log::warn "$real is not on PATH — cannot link $generic"
        fi
        return 0
    fi

    log::info "Linking $generic -> $real in /usr/local/bin"
    util::sudo ln -s "$(command -v "$real")" "$target"
}

cli::link_canonical_name fd
cli::link_canonical_name bat

log::success "CLI tools ready"
