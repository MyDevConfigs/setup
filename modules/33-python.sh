#!/usr/bin/env bash
# module-description: pyenv, the latest CPython, and uv
#
# This is the slowest module in the repository. pyenv builds CPython from
# source, which takes several minutes on a first run.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly PYENV_ROOT="$HOME/.pyenv"
readonly PYENV_INSTALLER="https://pyenv.run"
readonly UV_INSTALLER="https://astral.sh/uv/install.sh"

# ---------------------------------------------------------------------------
# 1. Build dependencies
#
# These are not optional and not cosmetic. CPython's configure script probes
# for each library and, when one is missing, **builds successfully without
# the corresponding module** and only prints a warning that scrolls past.
#
# The result is a Python that works until the day it does not: no `ssl` means
# pip cannot reach PyPI, no `sqlite3` breaks anything using a local database,
# no `readline` gives you a REPL with no history or arrow keys. Diagnosing it
# weeks later is miserable, so install the lot up front.
#
# From the pyenv wiki's suggested build environment for Debian/Ubuntu.
# ---------------------------------------------------------------------------

os::require_family debian

declare -ra BUILD_DEPS=(
    build-essential
    libssl-dev          # ssl      — pip, requests, anything over https
    zlib1g-dev          # zlib     — compression, wheel installation
    libbz2-dev          # bz2
    libreadline-dev     # readline — REPL history and line editing
    libsqlite3-dev      # sqlite3
    libncursesw5-dev    # curses
    xz-utils            # lzma
    liblzma-dev         # lzma
    tk-dev              # tkinter
    libxml2-dev         # lxml and friends
    libxmlsec1-dev
    libffi-dev          # ctypes   — required by a great deal of the ecosystem
    curl
    git
)

pkg::install "${BUILD_DEPS[@]}"

# ---------------------------------------------------------------------------
# 2. pyenv
#
# From the upstream installer rather than the distro package, even though
# Ubuntu ships one. pyenv carries python-build, the set of recipes describing
# how to fetch and compile each CPython release — a packaged pyenv freezes
# that list at package build time, so "install the latest Python" silently
# means "the latest Python that existed when the package was built".
# `pyenv update` keeps the installer-based one current.
# ---------------------------------------------------------------------------

python::install_pyenv() {
    util::install_script "$PYENV_INSTALLER"
}

if [[ -d "$PYENV_ROOT" ]]; then
    log::skip "pyenv (already at ${PYENV_ROOT/#$HOME/\~})"
else
    python::install_pyenv
fi

# shellcheck disable=SC2016  # the rc file needs these unexpanded
shell::add_block "pyenv" 'export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - )"
eval "$(pyenv virtualenv-init -)"'

# ---------------------------------------------------------------------------
# 3. The latest CPython
# ---------------------------------------------------------------------------

if util::is_dry; then
    log::dry "pyenv install \$(pyenv latest -k 3)   # compiles from source, several minutes"
    log::dry "pyenv global <that version>"
else
    export PYENV_ROOT
    export PATH="$PYENV_ROOT/bin:$PATH"

    if ! util::have pyenv; then
        util::die "pyenv is not on PATH after installation"
    fi

    # `pyenv latest -k 3` resolves the newest 3.x that python-build knows how
    # to build — the newest *stable* release, not a pre-release, because the
    # recipe list names alphas and betas differently (3.15.0a1, not 3.15.0).
    latest_python="$(pyenv latest -k 3 2>/dev/null || true)"

    if [[ -z "$latest_python" ]]; then
        log::warn "Could not determine the latest CPython — skipping the build."
        log::warn "Run 'pyenv update' then 'pyenv install \$(pyenv latest -k 3)'."
    elif pyenv versions --bare 2>/dev/null | grep -qxF "$latest_python"; then
        log::skip "CPython $latest_python (already built)"
        util::run pyenv global "$latest_python"
    else
        log::info "Building CPython $latest_python from source — this takes several minutes"
        util::run pyenv install --skip-existing "$latest_python"
        util::run pyenv global "$latest_python"
        log::success "CPython $latest_python installed and set as global"
    fi
fi

# ---------------------------------------------------------------------------
# 4. uv
#
# Handles virtual environments, dependency resolution, locking and tool
# installation, and is fast enough to change how the work feels. It replaces
# the pip + virtualenv + pipx stack rather than sitting alongside it.
#
# Its installer defaults to ~/.local/bin, which belongs to the user, so
# UV_INSTALL_DIR redirects it to the system location instead.
# ---------------------------------------------------------------------------

if util::have uv; then
    log::skip "uv (already installed: $(util::first_line uv --version))"
elif util::is_dry; then
    log::dry "install uv into /usr/local/bin"
else
    # The installer writes to /usr/local/bin, which needs root. Run the
    # download as the user and the install step with sudo by pointing the
    # installer at a writable staging directory first.
    staging="$(util::tmpdir)/uv-bin"
    util::ensure_dir "$staging"
    UV_INSTALL_DIR="$staging" UV_NO_MODIFY_PATH=1 util::install_script "$UV_INSTALLER"

    for binary in uv uvx; do
        if [[ -x "$staging/$binary" ]]; then
            util::sudo install -m 0755 "$staging/$binary" "/usr/local/bin/$binary"
        fi
    done
    log::success "uv: $(util::first_line uv --version)"
fi

log::success "Python toolchain ready"
