# shellcheck shell=bash
#
# os.sh — host detection.
#
# Sets a handful of OS_* globals once, at bootstrap, so modules never have to
# parse /etc/os-release or second-guess `uname` themselves.
#
#   OS_ID        distro id, verbatim        ubuntu
#   OS_ID_LIKE   space-separated parents    debian
#   OS_VERSION   version id                 26.04
#   OS_NAME      human-readable name        Ubuntu 26.04 LTS
#   OS_FAMILY    normalized family          debian | fedora | arch | macos
#   OS_ARCH      release-asset arch         amd64 | arm64 | arm
#   OS_ARCH_RAW  uname -m, verbatim         x86_64
#   OS_KERNEL    uname -s, lowercased       linux | darwin
#
# OS_FAMILY is the important one: it is what pkg.sh dispatches on, so a
# derivative like Pop!_OS or Linux Mint resolves to `debian` and needs no
# special-casing anywhere else.

# os::detect — populate the OS_* globals. Idempotent.
os::detect() {
    [[ -n "${OS_FAMILY:-}" ]] && return 0

    OS_KERNEL="$(uname -s | tr '[:upper:]' '[:lower:]')"
    OS_ARCH_RAW="$(uname -m)"
    OS_ARCH="$(os::_normalize_arch "$OS_ARCH_RAW")"

    if [[ -r /etc/os-release ]]; then
        # Read in a subshell so the file's many variables do not leak into
        # ours; only the four we want are copied back out.
        #
        # The trailing newline in the printf is load-bearing: `read` returns
        # non-zero when it hits EOF without seeing its delimiter, and under
        # `set -e` that would abort the script even though the variables were
        # assigned correctly.
        local id id_like version name
        # shellcheck disable=SC1091
        IFS='|' read -r id id_like version name < <(
            . /etc/os-release
            printf '%s|%s|%s|%s\n' \
                "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"
        )
        OS_ID="$id"
        OS_ID_LIKE="$id_like"
        OS_VERSION="$version"
        OS_NAME="$name"
    elif [[ "$OS_KERNEL" == "darwin" ]]; then
        OS_ID="macos"
        OS_ID_LIKE=""
        OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
        OS_NAME="macOS $OS_VERSION"
    else
        OS_ID="unknown"
        OS_ID_LIKE=""
        OS_VERSION="unknown"
        OS_NAME="unknown"
    fi

    OS_FAMILY="$(os::_family_of "$OS_ID" "$OS_ID_LIKE")"

    export OS_ID OS_ID_LIKE OS_VERSION OS_NAME OS_FAMILY \
           OS_ARCH OS_ARCH_RAW OS_KERNEL
}

# os::_normalize_arch <uname-m> — map to the naming GitHub releases use.
os::_normalize_arch() {
    case "$1" in
        x86_64 | amd64)   printf 'amd64' ;;
        aarch64 | arm64)  printf 'arm64' ;;
        armv7l | armhf)   printf 'arm' ;;
        i386 | i686)      printf '386' ;;
        *)                printf '%s' "$1" ;;
    esac
}

# os::_family_of <id> <id_like> — collapse a distro to its packaging family.
#
# Checks ID first, then falls back to ID_LIKE, which is how derivatives
# declare their lineage (Mint sets ID_LIKE="ubuntu debian").
os::_family_of() {
    local id="$1" id_like="$2" token

    for token in "$id" $id_like; do
        case "$token" in
            debian | ubuntu)
                printf 'debian'; return 0 ;;
            fedora | rhel | centos)
                printf 'fedora'; return 0 ;;
            arch | archlinux)
                printf 'arch'; return 0 ;;
            opensuse* | suse)
                printf 'suse'; return 0 ;;
            macos | darwin)
                printf 'macos'; return 0 ;;
        esac
    done

    printf 'unknown'
}

# os::summary — one line describing the host, for the startup banner.
os::summary() {
    printf '%s (family: %s, arch: %s)' "$OS_NAME" "$OS_FAMILY" "$OS_ARCH"
}

# os::require_family <family...> — abort unless the host is one of these.
#
# For a module that genuinely cannot work elsewhere. Prefer branching inside
# the module where a cross-platform path exists.
os::require_family() {
    local family
    for family in "$@"; do
        [[ "$OS_FAMILY" == "$family" ]] && return 0
    done
    util::die "This step requires one of: $* (detected: $OS_FAMILY)"
}
