#!/usr/bin/env bash
# module-description: tmux, compiled from the latest upstream release
#
# tmux ships source only — the release page carries a tarball and nothing
# else, no binary and no AppImage — so tracking the newest version means
# compiling it. This is the one module in the repository that builds
# software rather than moving bytes into place.
#
# Steps are the ones from https://github.com/tmux/tmux/wiki/Installing:
#
#     ./configure && make && sudo make install
#
# The release tarball ships a pre-generated configure, so autoconf and
# automake are not needed; those are only required when building from git.
#
# /usr/local is the prefix the wiki documents, and also where this repo puts
# single upstream binaries — never ~/.local/bin, which is the user's.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

os::require_family debian

readonly PREFIX="/usr/local"
readonly TMUX_BIN="$PREFIX/bin/tmux"

# ---------------------------------------------------------------------------
# 1. Build dependencies
#
# The wiki's list for Debian. All but libevent-dev are usually already
# present on a machine that has built anything before.
# ---------------------------------------------------------------------------

pkg::install build-essential libevent-dev libncurses-dev bison pkg-config

# ---------------------------------------------------------------------------
# 2. What is installed, and what is current
#
# The version comes from the binary rather than from dpkg, because they can
# disagree: Ubuntu's tmux 3.6a package produces a binary whose `tmux -V`
# reports 3.6. Reading the binary is the safe direction — it can only cause
# one unnecessary rebuild, never a missed one — and the discrepancy vanishes
# after the first source build, since upstream's configure.ac carries the
# full version including the point letter.
# ---------------------------------------------------------------------------

tmux::installed_version() {
    util::have tmux || return 1
    local line
    line="$(util::first_line tmux -V)" || return 1   # "tmux 3.6"
    printf '%s' "${line##* }"
}

current="$(tmux::installed_version || true)"
latest="$(util::gh_latest_tag tmux/tmux 2>/dev/null || true)"

if [[ -n "$current" ]]; then
    log::info "tmux $current is installed ($(command -v tmux))"
else
    log::info "tmux is not installed"
fi

if [[ -z "$latest" ]]; then
    if [[ -n "$current" ]]; then
        log::warn "Could not reach the GitHub API — keeping tmux $current"
        log::success "tmux ready"
        exit 0
    fi
    util::die "Could not reach the GitHub API to find the latest tmux release"
fi

if [[ -n "$current" ]] && util::version_gte "$current" "$latest"; then
    log::skip "tmux $current (already at or ahead of $latest)"
    log::success "tmux ready"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Build and install
# ---------------------------------------------------------------------------

readonly TARBALL_URL="https://github.com/tmux/tmux/releases/download/${latest}/tmux-${latest}.tar.gz"

tmux::build_and_install() {
    local work src
    work="$(util::tmpdir)"
    src="$work/tmux-${latest}"

    util::download "$TARBALL_URL" "$work/tmux.tar.gz"
    util::run tar -xzf "$work/tmux.tar.gz" -C "$work"

    [[ -d "$src" ]] || util::die "Expected $src inside the tarball"

    log::info "Compiling tmux $latest (this takes under a minute)"
    # configure has to run with the source directory as the working
    # directory, so it goes in a subshell rather than through util::run.
    ( cd "$src" && ./configure --prefix="$PREFIX" >/dev/null )
    util::run make -C "$src" -j"$(nproc)" -s

    util::sudo make -C "$src" install
}

if util::is_dry; then
    log::dry "download $TARBALL_URL"
    log::dry "./configure --prefix=$PREFIX && make && sudo make install"
    if [[ -n "$current" ]] && pkg::is_installed tmux; then
        log::dry "apt-get remove -y tmux   # after the build is verified"
    fi
    log::success "tmux ready"
    exit 0
fi

if [[ -n "$current" ]]; then
    log::info "Updating tmux $current -> $latest"
else
    log::info "Installing tmux $latest"
fi

tmux::build_and_install

# ---------------------------------------------------------------------------
# 4. Verify before removing anything
#
# The old tmux is only removed once the new one is on disk and runs. Doing it
# the other way round would leave the machine with no tmux at all if the
# build failed — and a build is the one step here that can fail for reasons
# outside this script, such as a new release needing a newer libevent.
# ---------------------------------------------------------------------------

[[ -x "$TMUX_BIN" ]] || util::die "$TMUX_BIN was not created by make install"

built_version="$(util::first_line "$TMUX_BIN" -V)" || util::die "$TMUX_BIN does not run"
built_version="${built_version##* }"

if [[ "$built_version" != "$latest" ]]; then
    log::warn "Built tmux reports '$built_version' but $latest was expected"
fi

log::success "tmux $built_version installed to $TMUX_BIN"

# ---------------------------------------------------------------------------
# 5. Remove the packaged tmux
#
# Only the distro package needs removing. A previous source build does not:
# `make install` overwrites $TMUX_BIN in place, and the tmux wiki documents
# no uninstall step precisely because there is nothing to track.
#
# Not behind a confirmation, unlike the Node packages in 32-node.sh: there
# the removal happens *before* the replacement exists, so declining is a
# meaningful choice. Here the replacement is already installed and verified,
# so the packaged copy is redundant by the time this runs.
# ---------------------------------------------------------------------------

if pkg::is_installed tmux; then
    log::info "Removing the distro tmux package, now superseded by $TMUX_BIN"
    util::sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y tmux
else
    log::skip "no distro tmux package to remove"
fi

# ---------------------------------------------------------------------------
# 6. Confirm the right one wins
#
# /usr/local/bin normally precedes /usr/bin, but a snap, a Homebrew prefix or
# a hand-rolled PATH can shadow it. Better to say so now than to have the
# user wonder why `tmux -V` disagrees with what this module just printed.
# ---------------------------------------------------------------------------

hash -r 2>/dev/null || true
resolved="$(command -v tmux || true)"

if [[ -z "$resolved" ]]; then
    log::warn "tmux is not on PATH — $PREFIX/bin may be missing from it"
elif [[ "$resolved" != "$TMUX_BIN" ]]; then
    log::warn "PATH resolves tmux to $resolved, not $TMUX_BIN"
    log::warn "Something ahead of $PREFIX/bin is shadowing it."
else
    log::info "tmux resolves to $resolved"
fi

log::success "tmux ready"
