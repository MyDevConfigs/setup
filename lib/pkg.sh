# shellcheck shell=bash
#
# pkg.sh — package manager abstraction.
#
# Modules call the generic API and never name a package manager:
#
#     pkg::install ripgrep fd jq
#
# This file resolves that to `apt-get install -y ripgrep fd-find jq` on a
# Debian family host. Adding a distro means filling in the four _pkg::<family>
# functions at the bottom — nothing above them changes, and no module changes.
#
# Only the Debian family is implemented. The others are deliberate stubs that
# fail with a clear message rather than silently doing the wrong thing.

# ---------------------------------------------------------------------------
# Naming differences between distros
#
# Modules use one generic name; these maps translate. Keys are
# "<family>:<generic>" — an entry is needed only where the name differs from
# the generic one, so these tables stay short.
# ---------------------------------------------------------------------------

# Package name, as the package manager knows it.
declare -grA PKG_ALIASES=(
    [debian:fd]="fd-find"
    [debian:delta]="git-delta"
    [debian:python-venv]="python3-venv"
    [debian:python-pip]="python3-pip"
    [debian:go]="golang-go"
    [debian:build-tools]="build-essential"

    [fedora:fd]="fd-find"
    [fedora:delta]="git-delta"
    [fedora:python-venv]="python3-virtualenv"
    [fedora:python-pip]="python3-pip"
    [fedora:go]="golang"
    [fedora:build-tools]="@development-tools"

    [arch:delta]="git-delta"
    [arch:python-pip]="python-pip"
    [arch:build-tools]="base-devel"
)

# Executable name, where the distro ships it under something unexpected.
#
# Debian renames two binaries to avoid clashing with existing packages:
# `fd` belongs to fdclone and `bat` to bacula-console. Modules use
# pkg::binary_for to find the real name, then symlink it onto PATH.
declare -grA PKG_BINARIES=(
    [debian:fd]="fdfind"
    [debian:bat]="batcat"
)

# ---------------------------------------------------------------------------
# Generic API
# ---------------------------------------------------------------------------

# pkg::manager — print the package manager command for this host.
pkg::manager() {
    case "$OS_FAMILY" in
        debian) printf 'apt-get' ;;
        fedora) printf 'dnf' ;;
        arch)   printf 'pacman' ;;
        suse)   printf 'zypper' ;;
        macos)  printf 'brew' ;;
        *)      printf 'unknown' ;;
    esac
}

# pkg::resolve <generic> — print the real package name for this host.
pkg::resolve() {
    printf '%s' "${PKG_ALIASES[${OS_FAMILY}:${1}]:-$1}"
}

# pkg::binary_for <generic> — print the executable name for this host.
pkg::binary_for() {
    printf '%s' "${PKG_BINARIES[${OS_FAMILY}:${1}]:-$1}"
}

# pkg::refresh — update the package index, at most once per setup.sh run.
#
# Modules can call this freely; the stamp file makes every call after the
# first a no-op, including across the separate processes that modules run in.
pkg::refresh() {
    local stamp="${SETUP_STATE_DIR:-}/pkg-refreshed"

    if [[ -n "${SETUP_STATE_DIR:-}" && -f "$stamp" ]]; then
        log::debug "package index already refreshed this run"
        return 0
    fi

    log::info "Refreshing package index ($(pkg::manager))"
    "_pkg::${OS_FAMILY}::refresh"

    [[ -n "${SETUP_STATE_DIR:-}" ]] && touch "$stamp"
    return 0
}

# pkg::is_installed <generic> — is this package already installed?
pkg::is_installed() {
    "_pkg::${OS_FAMILY}::is_installed" "$(pkg::resolve "$1")"
}

# pkg::is_available <generic> — does this host's repos offer the package?
#
# Use before installing something that only exists on newer releases, so the
# module can fall back to a tarball or cargo instead of failing the run.
pkg::is_available() {
    "_pkg::${OS_FAMILY}::is_available" "$(pkg::resolve "$1")"
}

# pkg::install <generic...> — install packages that are not already present.
#
# Filtering first keeps a re-run fast and quiet: with everything present this
# makes no network calls at all, which is what makes setup.sh safe to run
# repeatedly.
pkg::install() {
    (($# > 0)) || return 0

    local generic resolved
    local -a missing=()

    for generic in "$@"; do
        resolved="$(pkg::resolve "$generic")"
        if "_pkg::${OS_FAMILY}::is_installed" "$resolved"; then
            log::skip "$generic (already installed)"
        else
            missing+=("$resolved")
        fi
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    pkg::refresh
    log::info "Installing: ${missing[*]}"
    "_pkg::${OS_FAMILY}::install" "${missing[@]}"
}

# pkg::add_apt_repo <name> <key-url> <repo-url> <suite> <components...>
#
# Register a third-party apt repository with a signed-by keyring, the way
# every upstream now documents it. Idempotent: does nothing when both the
# keyring and the sources file are already in place.
#
#     pkg::add_apt_repo github-cli \
#         https://cli.github.com/packages/githubcli-archive-keyring.gpg \
#         https://cli.github.com/packages stable main
#
# apt-key and a bare `deb` line without signed-by are both deprecated: a key
# added the old way is trusted for *every* repository on the system, so a
# compromised third-party repo could serve a signed replacement for any
# package. signed-by scopes the key to the one repository it belongs to.
pkg::add_apt_repo() {
    os::require_family debian

    local name="$1" key_url="$2" repo_url="$3" suite="$4"
    shift 4
    local components="$*"

    local keyring="/etc/apt/keyrings/${name}-archive-keyring.gpg"
    local list="/etc/apt/sources.list.d/${name}.list"

    if [[ -f "$keyring" && -f "$list" ]]; then
        log::skip "$name apt repository (already configured)"
        return 0
    fi

    log::info "Adding the $name apt repository"

    util::sudo install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d

    # Download as the normal user, then install as root. Piping curl straight
    # into a privileged write would mean a truncated download lands as a
    # valid-looking keyring.
    local tmp
    tmp="$(util::tmpdir)/${name}.gpg"
    util::download "$key_url" "$tmp"
    util::sudo install -m 0644 "$tmp" "$keyring"

    local arch
    arch="$(dpkg --print-architecture)"
    util::sudo tee "$list" >/dev/null <<<"deb [arch=${arch} signed-by=${keyring}] ${repo_url} ${suite} ${components}"

    # A new repository means the cached index is stale, so drop the
    # once-per-run stamp and refresh again.
    if [[ -n "${SETUP_STATE_DIR:-}" ]]; then
        rm -f "$SETUP_STATE_DIR/pkg-refreshed"
    fi
    pkg::refresh
}

# pkg::assert_supported — abort early if this host has no implementation.
#
# Called once by setup.sh so an unsupported distro fails on line one with a
# useful message, rather than halfway through the first module.
pkg::assert_supported() {
    if ! declare -F "_pkg::${OS_FAMILY}::install" >/dev/null; then
        util::die "Unsupported distro family: ${OS_FAMILY} (${OS_NAME})"
    fi
    "_pkg::${OS_FAMILY}::assert_supported"
}

# ---------------------------------------------------------------------------
# Debian / Ubuntu — implemented
# ---------------------------------------------------------------------------

_pkg::debian::assert_supported() { return 0; }

_pkg::debian::refresh() {
    util::sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

_pkg::debian::install() {
    util::sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -q "$@"
}

_pkg::debian::is_installed() {
    # dpkg-query exits non-zero for unknown packages, and prints a status
    # like "deinstall ok config-files" for removed-but-not-purged ones —
    # so match the exact installed state rather than trusting the exit code.
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

_pkg::debian::is_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Fedora / RHEL — stub
# ---------------------------------------------------------------------------

_pkg::fedora::assert_supported() {
    util::die "Fedora support is not implemented yet. See lib/pkg.sh — filling
    in the four _pkg::fedora::* functions below is all that is required."
}

_pkg::fedora::refresh()      { util::sudo dnf makecache; }
_pkg::fedora::install()      { util::sudo dnf install -y "$@"; }
_pkg::fedora::is_installed() { rpm -q "$1" >/dev/null 2>&1; }
_pkg::fedora::is_available() { dnf info "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Arch — stub
# ---------------------------------------------------------------------------

_pkg::arch::assert_supported() {
    util::die "Arch support is not implemented yet. See lib/pkg.sh — filling
    in the four _pkg::arch::* functions below is all that is required.
    Note that AUR packages need a helper (paru/yay) that this layer does not
    model yet."
}

_pkg::arch::refresh()      { util::sudo pacman -Sy --noconfirm; }
_pkg::arch::install()      { util::sudo pacman -S --needed --noconfirm "$@"; }
_pkg::arch::is_installed() { pacman -Qi "$1" >/dev/null 2>&1; }
_pkg::arch::is_available() { pacman -Si "$1" >/dev/null 2>&1; }
