#!/usr/bin/env bash
# module-description: SDKMAN with Java LTS, Gradle and Kotlin
#
# SDKMAN manages JVM-ecosystem SDKs the way nvm manages Node: several
# versions side by side, switchable per shell or per project.
#
# Note for the fish backend in lib/shell.sh: SDKMAN has no native fish
# support. Enabling fish will need a shim here (the community uses
# bass or sdkman-for-fish), which is why this module's rc block is added
# through shell::add_block and guarded on a POSIX shell.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly SDKMAN_DIR="$HOME/.sdkman"
readonly SDKMAN_INSTALLER="https://get.sdkman.io"
readonly SDKMAN_INIT="$SDKMAN_DIR/bin/sdkman-init.sh"

if ! shell::is_posix; then
    util::die "SDKMAN has no native ${SETUP_SHELL} support — see the note at the
    top of this module."
fi

# SDKMAN needs unzip and zip to unpack candidates, and curl to fetch them.
pkg::install curl zip unzip

# ---------------------------------------------------------------------------
# 1. SDKMAN
# ---------------------------------------------------------------------------

java::install_sdkman() {
    # The installer edits rc files itself and offers no flag to stop it, so
    # it may add its own copy of the init block. shell::add_block below
    # fences ours with markers and matches on those, so a duplicate from the
    # installer is visible and removable rather than silently interleaved.
    util::install_script "$SDKMAN_INSTALLER"
}

if [[ -d "$SDKMAN_DIR" ]]; then
    log::skip "SDKMAN (already at ${SDKMAN_DIR/#$HOME/\~})"
else
    java::install_sdkman
fi

# shellcheck disable=SC2016  # the rc file needs these unexpanded
shell::add_block "sdkman" 'export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"'

# ---------------------------------------------------------------------------
# 2. Candidates
#
# Installed without a version argument on purpose. SDKMAN maintains a
# "default" for each candidate, and for Java that default is the current LTS
# Temurin build. Pinning a version here would mean editing this file every
# time a new LTS lands, and would silently install something ancient on a
# machine set up years from now.
# ---------------------------------------------------------------------------

declare -ra CANDIDATES=(java gradle kotlin)

if util::is_dry; then
    for candidate in "${CANDIDATES[@]}"; do
        log::dry "sdk install $candidate   # SDKMAN's current default"
    done
else
    # sdkman-init.sh is written against a laxer shell contract: it reads
    # unset variables and its functions return non-zero for ordinary
    # outcomes such as "candidate already installed".
    set +u
    set +e
    # shellcheck source=/dev/null
    source "$SDKMAN_INIT"

    for candidate in "${CANDIDATES[@]}"; do
        if sdk current "$candidate" >/dev/null 2>&1; then
            log::skip "$candidate ($(sdk current "$candidate" 2>/dev/null | tr -d '\n'))"
            continue
        fi
        log::info "Installing $candidate (SDKMAN default)"
        sdk install "$candidate" </dev/null
    done

    set -e
    set -u

    for candidate in "${CANDIDATES[@]}"; do
        version="$(sdk current "$candidate" 2>/dev/null | tr -d '\n' || true)"
        [[ -n "$version" ]] && log::info "    $version"
    done
fi

log::success "JVM toolchain ready"
