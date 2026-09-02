#!/usr/bin/env bash
# module-description: Base CLI tools, compilers and build essentials
#
# The packages assumed by everything else. Nothing here has its own installer
# or needs a version check — it is all plain package-manager work, which is
# why this module is a list and one call.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

# Names here are generic. lib/pkg.sh maps them to whatever this host's
# package manager calls them — `build-tools` becomes build-essential on
# Debian and base-devel on Arch.
declare -ra PACKAGES=(
    # Version control and network fetching
    git
    curl
    wget
    ca-certificates

    # Compilers and build drivers.
    # build-tools -> build-essential, which already provides gcc, g++, make
    # and libc6-dev; they are not listed separately to avoid implying they
    # are installed independently of it.
    build-tools
    clang
    cmake
    pkg-config

    # Scripting and archives, needed by a great many install scripts
    perl
    unzip

    # Shell tooling
    fzf
    stow        # deploys the dotfiles repo
    shellcheck  # lints this repo
)

pkg::install "${PACKAGES[@]}"

log::success "Core packages ready"
