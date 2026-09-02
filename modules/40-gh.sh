#!/usr/bin/env bash
# module-description: GitHub CLI (gh) from the official apt repository
#
# gh is not in the Ubuntu archive, so it comes from GitHub's own repository,
# following the upstream Debian instructions:
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian-ubuntu-linux-raspberry-pi-os-apt
#
# Separate from 10-core because the mechanism is different: core is plain
# packages from the distro, this adds a third-party repository and a signing
# key. Grouping by install mechanism is what keeps the modules honest about
# what they actually do.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

os::require_family debian

# Already installed? Then there is no reason to touch apt sources at all.
if pkg::is_installed gh; then
    log::skip "gh (already installed: $(util::first_line gh --version))"
    log::success "GitHub CLI ready"
    exit 0
fi

# Mirrors the upstream one-liner, with each step going through the library so
# it is logged and honors --dry-run.
#
# One deviation: upstream names the keyring githubcli-archive-keyring.gpg
# while pkg::add_apt_repo derives github-cli-archive-keyring.gpg from the
# repository name. Harmless — the signed-by field points at whatever path we
# wrote, so the two stay consistent.
pkg::add_apt_repo "github-cli" \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "https://cli.github.com/packages" \
    "stable" \
    "main"

pkg::install gh

if util::have gh; then
    log::info "Installed: $(util::first_line gh --version)"
    log::info "Run 'gh auth login' to authenticate — setup.sh does not do it for you."
fi

log::success "GitHub CLI ready"
