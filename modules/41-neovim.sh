#!/usr/bin/env bash
# module-description: Neovim (upstream AppImage) and the default editor
#
# From the upstream AppImage, following https://neovim.io/doc/install/ —
# Ubuntu's archive lags several minor versions behind, and Neovim's plugin
# ecosystem moves fast enough that the gap matters.
#
# The AppImage runs against fuse3 on current systems; the libfuse2 that older
# AppImages required is not needed. If it ever fails to run, the documented
# fallback is `--appimage-extract`.
#
# Installed to /opt/nvim/nvim exactly as the docs describe. Not ~/.local/bin,
# which is reserved for the user's own scripts.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly NVIM_DIR="/opt/nvim"
readonly NVIM_BIN="$NVIM_DIR/nvim"
# The 'latest' path is a permanent redirect to the newest release, so no
# GitHub API call is needed to find it.
readonly NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${OS_ARCH_RAW}.appimage"

# ---------------------------------------------------------------------------
# 1. Install or update
#
# The download is 11 MB, so a version check comes first rather than fetching
# it on every run. util::gh_latest_tag is a single API call; if it fails —
# rate limit, no network — the existing install is kept rather than
# reinstalled blindly.
# ---------------------------------------------------------------------------

neovim::installed_version() {
    [[ -x "$NVIM_BIN" ]] || return 1
    # "NVIM v0.12.5" -> "v0.12.5"
    local line
    line="$(util::first_line "$NVIM_BIN" --version)" || return 1
    printf '%s' "${line##* }"
}

neovim::install() {
    local staged
    staged="$(util::tmpdir)/nvim.appimage"

    util::download "$NVIM_URL" "$staged"
    util::sudo install -d -m 0755 "$NVIM_DIR"
    util::sudo install -m 0755 "$staged" "$NVIM_BIN"
}

current="$(neovim::installed_version || true)"
latest="$(util::gh_latest_tag neovim/neovim 2>/dev/null || true)"

if util::is_dry; then
    log::dry "install $NVIM_URL -> $NVIM_BIN"
elif [[ -n "$current" && -n "$latest" && "$current" == "$latest" ]]; then
    log::skip "neovim $current (already the latest release)"
elif [[ -n "$current" && -z "$latest" ]]; then
    log::warn "Could not reach the GitHub API — keeping neovim $current"
else
    if [[ -n "$current" ]]; then
        log::info "Updating neovim $current -> ${latest:-latest}"
    else
        log::info "Installing neovim ${latest:-latest}"
    fi
    neovim::install
    log::success "neovim $(neovim::installed_version || echo installed)"
fi

# The upstream docs append this directory to PATH; shell::add_path prepends.
# Prepending is deliberate: if the distro's neovim is ever pulled in as a
# dependency, /opt should still win over /usr/bin.
shell::add_path "$NVIM_DIR" "neovim"

# ---------------------------------------------------------------------------
# 2. Default editor
#
# Three separate mechanisms that do not cascade into one another:
#
#   $EDITOR / $VISUAL   what most CLI programs read
#   git config core.editor   git alone; set in 60-gitconfig.sh
#   update-alternatives      Debian's `editor`, used by sudoedit and visudo
#
# All three follow the repository's rule for configuration: fill a blank,
# never overwrite a choice already made.
# ---------------------------------------------------------------------------

if shell::has_env EDITOR nvim; then
    log::skip "EDITOR (already nvim in the rc file)"
elif [[ -n "${EDITOR:-}" && "${EDITOR:-}" != "nvim" ]]; then
    log::skip "EDITOR is already set to '$EDITOR' — leaving it alone"
else
    shell::set_env EDITOR nvim
    shell::set_env VISUAL nvim
fi

# Debian's alternatives system. `editor` is what sudoedit, visudo and
# select-editor consult, and it is entirely separate from $EDITOR — a machine
# can have nvim as $EDITOR and still open nano under `sudoedit`.
neovim::register_alternative() {
    if ! util::have update-alternatives; then
        log::debug "update-alternatives is not present"
        return 0
    fi

    local current_alt
    current_alt="$(readlink -f /etc/alternatives/editor 2>/dev/null || true)"

    if [[ "$current_alt" == "$NVIM_BIN" ]]; then
        log::skip "editor alternative (already neovim)"
        return 0
    fi

    log::info "Registering neovim with update-alternatives (was ${current_alt:-unset})"
    util::sudo update-alternatives --install /usr/bin/editor editor "$NVIM_BIN" 100
    util::sudo update-alternatives --set editor "$NVIM_BIN"
}

if util::is_dry; then
    log::dry "update-alternatives --install /usr/bin/editor editor $NVIM_BIN 100"
else
    neovim::register_alternative
fi

log::success "Neovim ready"
