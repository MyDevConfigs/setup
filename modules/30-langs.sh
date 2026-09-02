#!/usr/bin/env bash
# module-description: Language toolchains (Go, Rust)
#
# This module installs a toolchain only when it is missing, and never
# upgrades one that is already present. Provisioning and upgrading are
# separate concerns: re-running setup.sh must not move the compiler under a
# project that is mid-build. Upgrades stay explicit:
#
#     rustup update
#     sudo apt upgrade golang-go

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

# ---------------------------------------------------------------------------
# Go — the distro package is fine here
#
# Ubuntu 26.04 ships go1.26, which tracks upstream closely enough that the
# official tarball buys nothing. Reach for that only if you need several Go
# versions side by side, which wants a version manager rather than this.
# ---------------------------------------------------------------------------

pkg::install go

# ---------------------------------------------------------------------------
# Rust — rustup, never the distro package
#
# `apt install cargo` installs a second Rust that dpkg owns, pinned to
# whatever the release froze, unable to `rustup update` or switch toolchains
# per project. On a machine that already has rustup the two would coexist,
# with PATH order silently deciding which compiler a build uses.
#
# So the check here is command-level, not package-level: pkg::is_installed
# would report cargo as missing on exactly the machines that already have it.
# ---------------------------------------------------------------------------

langs::install_rustup() {
    local installer
    installer="$(util::tmpdir)/rustup-init.sh"

    util::download "https://sh.rustup.rs" "$installer"

    # --no-modify-path stops rustup editing the shell rc files itself. Left
    # to its own devices it appends unconditionally, and it targets the rc
    # files of shells it detects rather than the one this repo standardizes
    # on. lib/shell.sh writes the loader to ~/.zshrc, once.
    util::run sh "$installer" -y --no-modify-path --default-toolchain stable

    # Semantic, not a raw line: rustup ships env.fish alongside env because
    # fish cannot parse the POSIX one, and the backend knows to prefer it.
    shell::source_file "$HOME/.cargo/env" "cargo environment"
}

util::ensure_command rustup "Rust toolchain (rustup)" langs::install_rustup

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

# A rustup installed a moment ago is not on this process's PATH yet, so add
# its bin directory before reporting versions.
if [[ -d "$HOME/.cargo/bin" ]]; then
    PATH="$HOME/.cargo/bin:$PATH"
fi

# langs::report_version <label> <command> [args...]
#
# Deliberately avoids `... | head -n1`: under pipefail, head exiting early can
# kill the producer with SIGPIPE and fail the pipeline. Trimming the string
# after capture has no such race.
langs::report_version() {
    local label="$1"
    shift

    if ! util::have "$1"; then
        log::warn "$label: not on PATH"
        return 0
    fi

    local output
    output="$("$@" 2>/dev/null)" || output="(version check failed)"
    log::info "$label: ${output%%$'\n'*}"
}

langs::report_version "Go" go version
langs::report_version "Rust" rustc --version
langs::report_version "Cargo" cargo --version

log::success "Language toolchains ready"
