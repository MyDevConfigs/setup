#!/usr/bin/env bash
# module-description: Global git identity, default branch and pull strategy
#
# Configuration, not installation, which is why it runs last: prompts land
# after the long package output rather than interleaved with it.
#
# Nothing here is ever overwritten. A setting that is already in the global
# config is reported and left alone — this module only fills in blanks, so it
# is safe to re-run on a machine you have tuned by hand.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

util::have git || util::die "git is not installed — run ./setup.sh --only core first"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# gitcfg::get <key> — print a global setting, or nothing if unset.
#
# `git config --get` exits 1 for a missing key, which is not an error here.
gitcfg::get() {
    git config --global --get "$1" 2>/dev/null || true
}

# gitcfg::set <key> <value> — write a global setting.
gitcfg::set() {
    util::run git config --global "$1" "$2"
}

# gitcfg::ensure <key> <label> <question> [default]
#
# Report the existing value, or ask for one and store it. With an empty
# default and no answer, nothing is written — that is the identity case,
# where a wrong guess is worse than leaving it unset.
gitcfg::ensure() {
    local key="$1" label="$2" question="$3" default="${4:-}"

    local current
    current="$(gitcfg::get "$key")"

    if [[ -n "$current" ]]; then
        log::skip "$label: $current"
        return 0
    fi

    local answer
    answer="$(util::prompt "$question" "$default")"

    if [[ -z "$answer" ]]; then
        log::warn "$label is not set. Set it later with:"
        log::warn "    git config --global $key \"<value>\""
        return 0
    fi

    gitcfg::set "$key" "$answer"
    log::success "$label: $answer"
}

# ---------------------------------------------------------------------------
# Identity
#
# No default is offered. Guessing a name or email address and silently
# stamping it onto every future commit is worse than leaving it unset, and
# git itself will prompt on the first commit anyway.
# ---------------------------------------------------------------------------

log::info "Git identity"
gitcfg::ensure user.name  "user.name"  "Your full name for git commits"
gitcfg::ensure user.email "user.email" "Your email address for git commits"

# ---------------------------------------------------------------------------
# Default branch
#
# Unset means git prints a hint on every `git init`. main is the default
# offered because it is what GitHub, GitLab and git's own docs now use.
# ---------------------------------------------------------------------------

log::info "Default branch for new repositories"
gitcfg::ensure init.defaultBranch "init.defaultBranch" \
    "Default branch name for new repositories" "main"

# ---------------------------------------------------------------------------
# Pull strategy
#
# Since git 2.27 a plain `git pull` with diverged branches and no
# pull.rebase / pull.ff configured prints a warning and refuses, because
# there is no safe assumption to make. This picks one deliberately.
# ---------------------------------------------------------------------------

log::info "Pull strategy for diverged branches"

gitconfig::current_strategy() {
    local rebase ff
    rebase="$(gitcfg::get pull.rebase)"
    ff="$(gitcfg::get pull.ff)"

    if [[ "$ff" == "only" ]]; then
        printf 'fast-forward only (pull.ff=only)'
    elif [[ "$rebase" == "true" ]]; then
        printf 'rebase (pull.rebase=true)'
    elif [[ "$rebase" == "false" ]]; then
        printf 'merge (pull.rebase=false)'
    fi
}

strategy="$(gitconfig::current_strategy)"

if [[ -n "$strategy" ]]; then
    log::skip "pull strategy: $strategy"
else
    printf '\n  When your branch and the remote have both moved on, git pull can:\n\n' >&2
    printf '    %smerge%s   Make a merge commit joining the two histories.\n' "$C_CYAN" "$C_RESET" >&2
    printf '            Git'"'"'s traditional behaviour. Never rewrites your commits,\n' >&2
    printf '            so nothing you have already made can be lost, at the cost\n' >&2
    printf '            of merge commits cluttering the log.\n\n' >&2
    printf '    %srebase%s  Replay your local commits on top of the remote ones.\n' "$C_CYAN" "$C_RESET" >&2
    printf '            Gives a clean, linear history. Rewrites your local commit\n' >&2
    printf '            hashes, which is a problem only if you have already pushed\n' >&2
    printf '            them somewhere others pulled from.\n\n' >&2
    printf '    %sff-only%s Refuse to pull and stop, leaving you to decide.\n' "$C_CYAN" "$C_RESET" >&2
    printf '            The most explicit and the safest, at the cost of pull\n' >&2
    printf '            failing more often and needing a follow-up command.\n\n' >&2

    # merge is the default offered: it is what git did for its first fifteen
    # years, it is what most tutorials assume, and it is the only one of the
    # three that cannot rewrite or reject work you already have.
    choice="$(util::prompt "Pull strategy [merge/rebase/ff-only]" "merge")"

    case "$choice" in
        merge)
            gitcfg::set pull.rebase false
            log::success "pull strategy: merge (pull.rebase=false)"
            ;;
        rebase)
            gitcfg::set pull.rebase true
            log::success "pull strategy: rebase (pull.rebase=true)"
            ;;
        ff-only | ff | fast-forward)
            # Both are set: pull.rebase=true would otherwise win over
            # pull.ff=only and quietly rebase instead of refusing.
            gitcfg::set pull.ff only
            gitcfg::set pull.rebase false
            log::success "pull strategy: fast-forward only (pull.ff=only)"
            ;;
        *)
            log::warn "Unrecognised answer '$choice' — leaving pull strategy unset."
            log::warn "    git config --global pull.rebase false   # merge"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log::info "Global git config now:"
for key in user.name user.email init.defaultBranch pull.rebase pull.ff; do
    value="$(gitcfg::get "$key")"
    if [[ -n "$value" ]]; then
        log::info "    $key = $value"
    fi
done

log::success "Git configuration ready"
