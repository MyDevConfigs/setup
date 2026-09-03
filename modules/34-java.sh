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

# ---------------------------------------------------------------------------
# Additional JDKs
#
# Major versions to install alongside SDKMAN's default. These do not become
# the machine default — the newest LTS keeps that — they are here so a
# project can select one with `sdk use java <version>` or an .sdkmanrc.
#
# Listed by major version rather than a full identifier so this file does not
# need editing every time a patch release lands; the exact build is resolved
# against SDKMAN's own catalogue at run time.
# ---------------------------------------------------------------------------

declare -ra EXTRA_JAVA_MAJORS=(21)

# java::sdkman_platform — the platform string SDKMAN uses in its API paths.
#
# Read from the file SDKMAN wrote at install time rather than derived from
# uname: it is the same value SDKMAN itself queries with, so the two can
# never disagree.
java::sdkman_platform() {
    if [[ -r "$SDKMAN_DIR/var/platform" ]]; then
        cat "$SDKMAN_DIR/var/platform"
    else
        printf 'linuxx64'
    fi
}

# java::latest_temurin <major> — newest Temurin build of that major version.
#
# Fetched then parsed, never piped through an early-exiting command, for the
# reason in AGENTS.md. Temurin to match the vendor SDKMAN's bare `java`
# default already uses, so the installed JDKs come from one place.
java::latest_temurin() {
    local major="$1" platform json
    platform="$(java::sdkman_platform)"

    json="$(curl --fail --silent --location --connect-timeout 15 \
        "https://api.sdkman.io/2/candidates/java/${platform}/versions/list?installed=" \
        2>/dev/null)" || return 1

    local -a versions=()
    mapfile -t versions < <(
        printf '%s' "$json" | grep -oE "\\b${major}\\.[0-9.]+(\\+[0-9.]+)?-tem" | sort -V -u
    )

    ((${#versions[@]} > 0)) || return 1
    printf '%s' "${versions[-1]}"
}

# java::current_default — the version the `current` symlink points at.
#
# More reliable than parsing `sdk current java`, whose wording has changed
# between SDKMAN releases.
java::current_default() {
    local link="$SDKMAN_DIR/candidates/java/current"
    [[ -L "$link" ]] || return 1
    basename "$(readlink -f "$link")"
}

if util::is_dry; then
    for candidate in "${CANDIDATES[@]}"; do
        log::dry "sdk install $candidate   # SDKMAN's current default"
    done
    for major in "${EXTRA_JAVA_MAJORS[@]}"; do
        log::dry "sdk install java \$(latest ${major}.x Temurin)   # not made default"
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

    # -----------------------------------------------------------------------
    # Extra JDKs, without disturbing the default
    #
    # `sdk install java <version>` asks whether the new build should become
    # the default, and with stdin closed it takes the affirmative answer. So
    # rather than trying to suppress the prompt, the default is recorded
    # first and reasserted afterwards — which is correct whatever the prompt
    # decides, and stays correct if SDKMAN changes that behaviour.
    # -----------------------------------------------------------------------

    default_before="$(java::current_default || true)"

    for major in "${EXTRA_JAVA_MAJORS[@]}"; do
        extra_version="$(java::latest_temurin "$major" || true)"

        if [[ -z "$extra_version" ]]; then
            log::warn "Could not resolve a Temurin ${major}.x build — skipping"
            continue
        fi

        if [[ -d "$SDKMAN_DIR/candidates/java/$extra_version" ]]; then
            log::skip "java $extra_version"
            continue
        fi

        log::info "Installing java $extra_version (alongside the default)"
        sdk install java "$extra_version" </dev/null
    done

    if [[ -n "$default_before" ]]; then
        default_now="$(java::current_default || true)"
        if [[ "$default_now" != "$default_before" ]]; then
            log::info "Restoring the default JDK to $default_before"
            sdk default java "$default_before" </dev/null
        fi
    fi

    set -e
    set -u

    for candidate in "${CANDIDATES[@]}"; do
        version="$(sdk current "$candidate" 2>/dev/null | tr -d '\n' || true)"
        [[ -n "$version" ]] && log::info "    $version"
    done

    # Every JDK on the machine, so it is obvious which are available to
    # switch to and which one is actually in force.
    for jdk in "$SDKMAN_DIR"/candidates/java/*/; do
        jdk="$(basename "$jdk")"
        [[ "$jdk" == "current" ]] && continue
        if [[ "$jdk" == "$(java::current_default || true)" ]]; then
            log::info "    java $jdk (default)"
        else
            log::info "    java $jdk"
        fi
    done
fi

log::success "JVM toolchain ready"
