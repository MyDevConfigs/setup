#!/usr/bin/env bash
# module-description: Desktop applications
#
# End-user applications rather than developer tooling. Kept separate so a
# headless machine can skip the lot:
#
#     ./setup.sh --skip apps

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

declare -ra PACKAGES=(
    timeshift  # filesystem snapshots / restore points
)

pkg::install "${PACKAGES[@]}"

# Timeshift installs happily but does nothing until it is told where to put
# snapshots and how often. That is a one-time interactive decision involving
# a target disk, so this module does not attempt it — it just says so once,
# and only when the configuration is genuinely absent.
if [[ ! -f /etc/timeshift/timeshift.json && ! -f /etc/timeshift.json ]]; then
    log::warn "Timeshift is installed but not configured."
    log::warn "Run 'sudo timeshift-gtk' to choose a snapshot location and schedule."
fi

log::success "Applications ready"
