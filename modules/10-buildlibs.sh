#!/usr/bin/env bash
# module-description: Development headers for building GUI/Wayland tools from source
#
# Only needed on a machine that compiles things — waybar, hyprland and the
# rest of a Wayland desktop. On a server or a minimal install, skip it:
#
#     ./setup.sh --skip buildlibs

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# shellcheck source=../lib/bootstrap.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/bootstrap.sh"

# Unlike the other modules, these are Debian package names rather than
# generic ones — -dev packages are named quite differently elsewhere
# (libgtk-3-dev is `gtk3` on Arch, `gtk3-devel` on Fedora). When another
# family is implemented in lib/pkg.sh, these need entries in PKG_ALIASES
# rather than a change here.
os::require_family debian

declare -ra PACKAGES=(
    sassc         # Sass compiler, used to build GTK themes
    libdrm-dev    # Direct Rendering Manager headers
    libgtk-3-dev  # GTK3 headers, needed by waybar and most tray applets
    libgdm-dev    # GNOME Display Manager headers
)

pkg::install "${PACKAGES[@]}"

log::success "Build libraries ready"
