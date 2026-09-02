# shellcheck shell=bash
#
# bootstrap.sh — the single entry point for the library.
#
# Every module sources this one file and gets the whole library. It resolves
# SETUP_ROOT on its own, so a module can be executed directly:
#
#     ./modules/10-cli.sh          # works standalone
#     ./setup.sh --only cli        # works through the runner
#
# Guard against double-sourcing: modules may be sourced more than once in a
# single shell, and re-running the library would clobber readonly variables.
[[ -n "${_SETUP_BOOTSTRAP_LOADED:-}" ]] && return 0
_SETUP_BOOTSTRAP_LOADED=1

# Resolve the repository root from this file's location unless the runner
# already exported it. Symlink-safe: cd resolves the physical path.
if [[ -z "${SETUP_ROOT:-}" ]]; then
    SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export SETUP_ROOT

# ---------------------------------------------------------------------------
# Runtime flags
#
# These are exported by setup.sh so they survive into modules run as separate
# processes. Defaults here mean a standalone module still behaves sanely.
# ---------------------------------------------------------------------------
: "${SETUP_DRY_RUN:=0}"     # 1 = print commands, change nothing
: "${SETUP_ASSUME_YES:=0}"  # 1 = never prompt, answer yes
: "${SETUP_LOG_LEVEL:=info}"  # debug | info | warn | error | silent
export SETUP_DRY_RUN SETUP_ASSUME_YES SETUP_LOG_LEVEL

# Load order matters: log has no dependencies, util needs log,
# os needs log+util, pkg needs all three.
# shellcheck source=lib/log.sh
source "$SETUP_ROOT/lib/log.sh"
# shellcheck source=lib/util.sh
source "$SETUP_ROOT/lib/util.sh"
# shellcheck source=lib/os.sh
source "$SETUP_ROOT/lib/os.sh"
# shellcheck source=lib/pkg.sh
source "$SETUP_ROOT/lib/pkg.sh"

# Detect the host once, here, so every module can rely on OS_* being set.
os::detect
