#!/usr/bin/env bash
# module-description: pokemon-colorscripts, and a sprite on every new shell
#
# https://gitlab.com/phoneybadger/pokemon-colorscripts
#
# Two independent steps: install the program, and add the line that runs it.
# Either can be already done without the other — this machine had the program
# from a KoolDots install but nothing calling it — so neither check gates the
# other.
#
# Install-once, deliberately. Every other module that tracks upstream can ask
# "is my copy current?" by comparing a version. This project has no releases
# and no tags (its API returns an empty list), and its installer copies files
# rather than leaving a git checkout, so there is nothing to compare and
# nothing to pull. Re-running the installer by hand is the update path.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

readonly REPO_URL="https://gitlab.com/phoneybadger/pokemon-colorscripts.git"
readonly BIN="pokemon-colorscripts"

# The upstream install.sh hardcodes both of these; they are named here only so
# the log can say where things went.
readonly INSTALL_DIR="/usr/local/opt/pokemon-colorscripts"
readonly BIN_PATH="/usr/local/bin/$BIN"

# ---------------------------------------------------------------------------
# 1. The program
#
# It is a Python 3 script rather than a compiled binary, so python3 is a
# runtime dependency, not just a build one. Ubuntu always has it, but naming
# it here means a minimal image fails on the missing package rather than on a
# symlink that points at something it cannot execute.
# ---------------------------------------------------------------------------

pkg::install git python3

pokemon::install() {
    local work src
    work="$(util::tmpdir)"
    src="$work/pokemon-colorscripts"

    # --depth 1: the repository is tens of megabytes of sprite art and none
    # of its history is wanted.
    util::run git clone --depth 1 "$REPO_URL" "$src"

    # install.sh copies `colorscripts`, `pokemon-colorscripts.py` and
    # `pokemon.json` by relative path, so it has to run with the clone as the
    # working directory. It writes to /usr/local, hence sudo.
    ( cd "$src" && util::sudo sh ./install.sh )
}

if util::have "$BIN"; then
    log::skip "$BIN (already installed: $(command -v "$BIN"))"
elif util::is_dry; then
    log::dry "git clone --depth 1 $REPO_URL"
    log::dry "sudo sh ./install.sh   # -> $INSTALL_DIR, symlinked at $BIN_PATH"
else
    log::info "Installing $BIN from GitLab"
    pokemon::install

    util::have "$BIN" || util::die "$BIN is not on PATH after installation"
    log::success "$BIN installed to $BIN_PATH"
fi

# ---------------------------------------------------------------------------
# 2. The greeting
#
# Checked and added independently of the install above: the program being
# present says nothing about whether anything calls it.
#
# The `[ -t 1 ]` guard is not about interactivity — an rc file is only read by
# interactive shells anyway. It is about `zsh -ic 'some command'`, which does
# read the rc, and which any script or editor plugin might use. Without the
# guard those get fifteen lines of ANSI sprite prepended to whatever they were
# trying to capture. In a real terminal stdout is a tty, so it changes nothing
# that anyone sees.
# ---------------------------------------------------------------------------

shell::add_line '[ -t 1 ] && pokemon-colorscripts -r --no-title' "pokemon greeting"

log::success "Pokemon colorscripts ready"
