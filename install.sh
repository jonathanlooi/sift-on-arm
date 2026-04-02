#!/usr/bin/env bash
# SIFT Workstation ARM64 Installer
# Installs SIFT on Ubuntu 22.04 LTS ARM64 (tested on UTM/Apple Silicon)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/sift-on-arm/main/install.sh | sudo bash
#   -- or --
#   sudo bash install.sh

set -euo pipefail

CAST_VERSION="1.0.8"
CAST_DEB="cast-v${CAST_VERSION}-linux-arm64.deb"
CAST_URL="https://github.com/ekristen/cast/releases/download/v${CAST_VERSION}/${CAST_DEB}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Sanity checks ---

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    error "This script is for ARM64 (aarch64) systems. Detected: $ARCH"
fi

. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    error "This script requires Ubuntu. Detected: $ID"
fi
if [[ "$VERSION_ID" != "22.04" ]]; then
    warn "This script was tested on Ubuntu 22.04. You have $VERSION_ID — proceed at your own risk."
    read -r -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

info "Starting SIFT ARM64 installation on Ubuntu $VERSION_ID ($ARCH)"
echo ""

# --- Step 1: Apply ARM64 patches to the SaltStack states ---
# These patches fix issues in the sift-saltstack states that prevent installation on ARM64.
# They will be applied AFTER cast downloads the states but BEFORE salt applies them.
# We accomplish this by downloading the states first, patching, then running salt manually.

# --- Step 2: Install Cast ---

if command -v cast &>/dev/null; then
    INSTALLED_VER=$(cast --version 2>/dev/null | grep -oP 'v\K[0-9.]+' || echo "unknown")
    success "cast already installed (v${INSTALLED_VER})"
else
    info "Downloading Cast v${CAST_VERSION} for ARM64..."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${TMP_DIR}/${CAST_DEB}" "${CAST_URL}"
    elif command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "${TMP_DIR}/${CAST_DEB}" "${CAST_URL}"
    else
        error "Neither wget nor curl is installed. Please install one and retry."
    fi

    info "Installing Cast..."
    dpkg -i "${TMP_DIR}/${CAST_DEB}"
    success "Cast installed: $(cast --version)"
fi

# --- Step 3: Download SIFT SaltStack states (without running) ---

SIFT_CACHE_BASE="/var/cache/cast/teamdfir_sift-saltstack"

if [[ -d "$SIFT_CACHE_BASE" ]]; then
    EXISTING=$(ls -1 "$SIFT_CACHE_BASE" 2>/dev/null | head -1)
    if [[ -n "$EXISTING" ]]; then
        info "SIFT SaltStack states already downloaded: $EXISTING"
        SIFT_SOURCE="${SIFT_CACHE_BASE}/${EXISTING}/source"
    fi
fi

if [[ -z "${SIFT_SOURCE:-}" ]]; then
    info "Downloading SIFT SaltStack states..."
    # cast download fetches the states without applying them
    cast install teamdfir/sift-saltstack --dry-run 2>/dev/null || true

    # If dry-run didn't populate the cache, do a full download via git
    LATEST=$(ls -1t "$SIFT_CACHE_BASE" 2>/dev/null | head -1)
    if [[ -z "$LATEST" ]]; then
        warn "Could not pre-download states. They will be downloaded during install."
    else
        SIFT_SOURCE="${SIFT_CACHE_BASE}/${LATEST}/source"
    fi
fi

# --- Step 4: Apply ARM64 patches ---

patch_sift_states() {
    local SIFT_SRC="$1"
    info "Applying ARM64 patches to SaltStack states in: $SIFT_SRC"

    # Patch 1: ubuntu-universe.sls
    # Original file tries to enable 'universe' component via regex replace.
    # On ARM64, the packages live at ports.ubuntu.com/ubuntu-ports/ instead.
    # The original also had a YAML rendering error due to colons in the unless clause.
    UNIVERSE_SLS="${SIFT_SRC}/sift/repos/ubuntu-universe.sls"
    if [[ -f "$UNIVERSE_SLS" ]]; then
        if ! grep -q "ubuntu-ports" "$UNIVERSE_SLS"; then
            info "Patching ubuntu-universe.sls for ARM64 ports repository..."
            cat > "$UNIVERSE_SLS" << 'UNIVERSE_EOF'
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
sift-ubuntu-ports-repo-universe:
  file.append:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - text: |

        Types: deb
        URIs: http://ports.ubuntu.com/ubuntu-ports/
        Suites: jammy jammy-updates jammy-security jammy-backports
        Components: main universe restricted multiverse
        Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
        Architectures: arm64
    - unless: grep -q "ubuntu-ports" /etc/apt/sources.list.d/ubuntu.sources
{% else %}
sift-universe-repo:
  file.replace:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - pattern: '^(Components: )(?!.*\buniverse\b)(.*)$'
    - repl: '\1\2 universe'
    - flags:
        - MULTILINE
{%- endif %}
UNIVERSE_EOF
            success "Patched ubuntu-universe.sls"
        else
            info "ubuntu-universe.sls already patched"
        fi
    else
        warn "ubuntu-universe.sls not found at expected path: $UNIVERSE_SLS"
    fi

    # Patch 2: docker.sls
    # Docker repo sources need explicit architecture for ARM64.
    DOCKER_SLS="${SIFT_SRC}/sift/repos/docker.sls"
    if [[ -f "$DOCKER_SLS" ]]; then
        if ! grep -q "Architectures: arm64" "$DOCKER_SLS"; then
            info "Patching docker.sls for ARM64 architecture..."
            cat > "$DOCKER_SLS" << 'DOCKER_EOF'
include:
  - sift.packages.software-properties-common

sift-docker-key:
  file.managed:
    - name: /usr/share/keyrings/DOCKER-PGP-KEY.asc
    - source: https://download.docker.com/linux/ubuntu/gpg
    - skip_verify: True
    - makedirs: True

sift-remove-docker-ppa:
  pkgrepo.absent:
    - ppa: docker/stable
    - require:
      - sls: sift.packages.software-properties-common

sift-remove-docker-list:
  file.absent:
    - name: /etc/apt/sources.list.d/docker.list
    - require:
      - pkgrepo: sift-remove-docker-ppa

sift-remove-docker-sources:
  file.absent:
    - name: /etc/apt/sources.list.d/docker.sources
    - require:
      - pkgrepo: sift-remove-docker-ppa

sift-docker-repo:
  file.managed:
    - name: /etc/apt/sources.list.d/docker.sources
    - contents: |
        Types: deb
        URIs: https://download.docker.com/linux/ubuntu
        Suites: {{ grains['lsb_distrib_codename'] }}
        Components: stable
        Signed-By: /usr/share/keyrings/DOCKER-PGP-KEY.asc
        Architectures: arm64
    - require:
      - file: sift-docker-key
      - pkgrepo: sift-remove-docker-ppa
      - file: sift-remove-docker-list
      - file: sift-remove-docker-sources
DOCKER_EOF
            success "Patched docker.sls"
        else
            info "docker.sls already patched"
        fi
    else
        warn "docker.sls not found at expected path: $DOCKER_SLS"
    fi

    # Patch 3: radare2.sls
    # radare2 ARM64 binary is available from GitHub releases.
    RADARE2_SLS="${SIFT_SRC}/sift/packages/radare2.sls"
    if [[ -f "$RADARE2_SLS" ]]; then
        if ! grep -q "aarch64" "$RADARE2_SLS"; then
            info "Patching radare2.sls for ARM64 binary..."
            # Get current version from the file
            R2_VERSION=$(grep -oP 'set version = "\K[^"]+' "$RADARE2_SLS" | head -1)
            if [[ -z "$R2_VERSION" ]]; then
                R2_VERSION="5.9.6"
            fi
            cat > "$RADARE2_SLS" << RADARE2_EOF
{# renovate: datasource=github-release-attachments depName=radareorg/radare2 #}
{%- set version = "${R2_VERSION}" -%}
{%- set base_url = "https://github.com/radareorg/radare2/releases/download/" -%}
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
{%- set filename = "radare2_" ~ version ~ "_arm64.deb" -%}
{%- else -%}
{%- set filename = "radare2_" ~ version ~ "_amd64.deb" -%}
{%- endif -%}

sift-package-radare2-download:
  file.managed:
    - name: /var/cache/sift/archives/{{ filename }}
    - source: "{{ base_url }}{{ version }}/{{ filename }}"
    - skip_verify: True
    - makedirs: True

sift-radare2:
  pkg.installed:
    - sources:
      - radare2: /var/cache/sift/archives/{{ filename }}
    - watch:
      - file: sift-package-radare2-download
RADARE2_EOF
            success "Patched radare2.sls"
        else
            info "radare2.sls already has ARM64 support"
        fi
    else
        warn "radare2.sls not found at expected path: $RADARE2_SLS"
    fi
}

if [[ -n "${SIFT_SOURCE:-}" ]] && [[ -d "$SIFT_SOURCE" ]]; then
    patch_sift_states "$SIFT_SOURCE"
else
    warn "SIFT states not yet downloaded — patches will be applied after first download attempt."
    warn "You may need to re-run this script after the first cast run, or patch manually."
fi

# --- Step 5: Run the SIFT installer ---

echo ""
info "Running SIFT installer (this will take 20-40 minutes)..."
echo ""
warn "Expected errors (safe to ignore on ARM64):"
warn "  - libbde, libbde-tools: not in GIFT PPA for ARM64"
warn "  - libewf-tools: not in GIFT PPA for ARM64"
warn "  - libvshadow-tools: not in GIFT PPA for ARM64"
warn "  - python3-pytsk3, python3-dfvfs: not available for ARM64"
warn "  - plaso-tools (log2timeline): depends on python3-dfvfs"
warn "  - rar: not available in Ubuntu ARM64 repos"
warn "  - powershell: amd64-only (gracefully skipped)"
echo ""

cast install teamdfir/sift-saltstack

# --- Step 6: Apply patches if states were just downloaded ---

LATEST=$(ls -1t "$SIFT_CACHE_BASE" 2>/dev/null | head -1)
if [[ -n "$LATEST" ]]; then
    NEW_SIFT_SOURCE="${SIFT_CACHE_BASE}/${LATEST}/source"
    if [[ -d "$NEW_SIFT_SOURCE" ]] && [[ "$NEW_SIFT_SOURCE" != "${SIFT_SOURCE:-}" ]]; then
        patch_sift_states "$NEW_SIFT_SOURCE"
        info "Re-running cast to apply patches..."
        cast install teamdfir/sift-saltstack
    fi
fi

echo ""
success "SIFT installation complete!"
echo ""
info "Verify key tools:"
echo "  which volatility3"
echo "  which bulk_extractor"
echo "  which wireshark"
echo "  which radare2"
echo "  exiftool -ver"
echo ""
warn "Note: plaso (log2timeline) and some libyal tools are NOT available on ARM64."
warn "See README.md for full details."
