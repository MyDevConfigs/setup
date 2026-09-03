#!/usr/bin/env bash
# module-description: .NET 10 SDK and the global tools directory
#
# From Ubuntu's own archive rather than Microsoft's apt feed. Both exist, and
# historically having both configured has been a reliable way to end up with
# an SDK that cannot resolve its own runtime, because the two feeds ship
# packages with the same names built against different dependencies.
# Ubuntu 26.04 carries dotnet-sdk-10.0 directly, so there is no reason to add
# a third-party repository here.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

os::require_family debian

readonly DOTNET_TOOLS="$HOME/.dotnet/tools"

# Version-pinned by design. Unlike Node or Java, where a version manager
# switches between releases, .NET majors are separate packages that install
# side by side — so this names the one wanted rather than tracking whatever
# is newest.
pkg::install dotnet-sdk-10.0

# ---------------------------------------------------------------------------
# Global tools
#
# `dotnet tool install --global` puts executables in ~/.dotnet/tools, which
# nothing adds to PATH. Without this, installing a global tool appears to
# succeed and then the command is not found.
#
# The directory is created up front because it does not exist until the first
# global tool is installed, and Ubuntu's stock profile only adds directories
# that already exist.
# ---------------------------------------------------------------------------

util::ensure_dir "$DOTNET_TOOLS"
shell::add_path "$DOTNET_TOOLS" ".NET global tools"

# Opt out of the first-run telemetry banner and the CLI's startup probe.
# This is a plain environment variable, not a config file, so it belongs
# with the rest of the shell environment rather than in a dotfile.
shell::set_env DOTNET_CLI_TELEMETRY_OPTOUT 1

if util::have dotnet; then
    log::info ".NET SDK: $(util::first_line dotnet --version)"
fi

log::success ".NET toolchain ready"
