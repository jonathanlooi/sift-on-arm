# SIFT Workstation on ARM64 (Apple Silicon / UTM)

This documents how to install the [SANS SIFT Workstation](https://github.com/teamdfir/sift-saltstack) on **Ubuntu 22.04 LTS (Jammy) ARM64**, including running it inside [UTM](https://mac.getutm.app/) on Apple Silicon Macs. This was a non-trivial challenge — the official SIFT installer was designed for x86-64, and several things needed to be fixed to make it work on ARM.

---

## What Was Done (and Why It Was Hard)

### The Installer: CAST

SIFT no longer uses `sift-cli`. It uses [**Cast**](https://github.com/ekristen/cast) (v1.0.8), a Go-based single-binary installer that drives SaltStack under the hood. Cast does ship an `arm64` `.deb`, but the underlying SIFT SaltStack states were written primarily for amd64.

Running `sudo cast install teamdfir/sift-saltstack` on ARM64 hit several issues that needed to be fixed before and during the run.

---

## Issues Encountered and Fixes Applied

### 1. `sift/repos/docker.sls` — YAML Rendering Failure

**Problem:** The original `docker.sls` caused a fatal SaltStack rendering error:
```
[CRITICAL] Rendering SLS 'base:sift.repos.docker' failed: could not find expected ':'; line 45
```
The Docker repo sources block did not specify an architecture, which caused a YAML parse conflict on ARM.

**Fix:** Added `Architectures: arm64` to the Docker apt sources block:
```yaml
sift-docker-repo:
  file.managed:
    - name: /etc/apt/sources.list.d/docker.sources
    - contents: |
        Types: deb
        URIs: https://download.docker.com/linux/ubuntu
        Suites: {{ grains['lsb_distrib_codename'] }}
        Components: stable
        Signed-By: /usr/share/keyrings/DOCKER-PGP-KEY.asc
        Architectures: arm64   # <-- added for ARM64
```

---

### 2. `sift/repos/ubuntu-universe.sls` — ARM64 Needs `ubuntu-ports`

**Problem:** On ARM64 Ubuntu 22.04, the universe/multiverse packages live at `ports.ubuntu.com/ubuntu-ports/`, not the standard `archive.ubuntu.com`. The original SLS only tried to enable the `universe` component in the existing sources file — this didn't work on ARM. Also caused a rendering error:
```
[CRITICAL] Rendering SLS 'base:sift.repos.ubuntu-universe' failed: could not find expected ':'; line 17
```

**Fix:** Added an ARM64 branch that appends the `ubuntu-ports` repository:
```jinja
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
sift-ubuntu-ports-repo-universe:
  file.append:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - text: |

        Types: deb
        URIs: http://ports.ubuntu.com/ubuntu-ports/
        Suites: noble
        Components: main universe restricted multiverse
        Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
        Architectures: arm64
    - unless:
      - grep -q "URIs: http://ports.ubuntu.com/ubuntu-ports/" /etc/apt/sources.list.d/ubuntu.sources
{% else %}
# ... original x86 logic ...
{%- endif %}
```

---

### 3. `sift/packages/radare2.sls` — ARM64 Binary Support

**Problem:** The original radare2 installer only downloaded the `amd64.deb`.

**Fix:** Added architecture detection to download the `arm64.deb` from the radare2 GitHub releases:
```jinja
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
{%- set hash = "c5b958a6ea59003431fd9f2117d71722f557db87b58e75dda17e072b1f9f50d3" -%}
{%- set filename = "radare2_" ~ version ~ "_arm64.deb" -%}
{%- else -%}
{%- set hash = "596c2b2e5cd95f38827f5e29d93547f7535e49c5bba0d5bd845b36f7e2488974" -%}
{%- set filename = "radare2_" ~ version ~ "_amd64.deb" -%}
{%- endif -%}
```

---

### 4. Microsoft Repo — amd64 Only

The Microsoft repo (`packages.microsoft.com`) is configured with `Architectures: amd64` — PowerShell is only available for x86-64. The SIFT SaltStack state already had a guard for this:
```jinja
- onlyif:
  - fun: match.grain
    tgt: 'osarch:amd64'
```
So PowerShell is **gracefully skipped** on ARM — no error, no action.

---

## ARM64 Package Status

### Missed by the installer — fix with `apt install`

These packages **do exist for ARM64** but failed to install during the SIFT salt run because the `ubuntu-ports` repository fix was applied after the initial attempt. The automated `install.sh` handles this, but if you ran `cast install` manually, install these yourself:

```bash
sudo apt install afflib-tools aircrack-ng autopsy sleuthkit xmount
```

| Package | Status |
|---|---|
| `afflib-tools` | Available in ubuntu-ports (noble) |
| `aircrack-ng` | Available in ubuntu-ports (jammy) |
| `autopsy` | Available in ubuntu-ports (noble) |
| `sleuthkit` | Available in ubuntu-ports (noble) |
| `xmount` | Available in ubuntu-ports (noble) |

### Genuinely unavailable on ARM64

These packages simply do not exist as ARM64 builds. They fail silently during installation — everything else installs fine.

**GIFT PPA publishes amd64-only builds for the entire libyal family:**

| Package | Impact |
|---|---|
| `libbde` / `libbde-tools` | BitLocker encrypted volume support |
| `libewf-tools` | Expert Witness Format (EWF/E01) CLI tools |
| `libfvde` / `libfvde-tools` | FileVault 2 encrypted volume support |
| `libesedb` / `libesedb-tools` | ESE/EDB database support (e.g. IE history) |
| `libevt` / `libevt-tools` | Windows EVT event log support |
| `libevtx` / `libevtx-tools` | Windows EVTX event log support |
| `libmsiecf` | MS IE cache file support |
| `libolecf` | OLE Compound File support |
| `libregf` / `libregf-tools` | Windows Registry support (CLI tools) |
| `libvshadow` / `libvshadow-tools` | Volume Shadow Copy support |
| `libfsapfs-tools` | Apple File System (APFS) support |
| `libvmdk` | VMware VMDK support (CLI tools) |
| `libewf-python3`, `libregf-python3`, `libvshadow-python3` | Python bindings for the above |
| `python3-pytsk3` | Python bindings for The Sleuth Kit |
| `python3-dfvfs` | Depends on all of the above — not installable |
| `plaso-tools` (log2timeline) | Depends on `python3-dfvfs` — not installable |

> **Note:** The underlying libraries (`libewf2`, `libregf1`, `libvshadow1`, `libvmdk1`) **do** install on ARM64 — only the GIFT PPA versions of the tools and Python bindings are missing.

**No ARM64 build exists anywhere:**

| Package | Notes |
|---|---|
| `aeskeyfind` | No ARM64 package in any repo |
| `bulk-extractor` | GIFT PPA amd64-only; no ARM64 build published |
| `cmospwd` | x86-specific tool by nature (reads CMOS hardware) |
| `liblightgrep` | No ARM64 package available |
| `rar` | RAR's Linux builds are x86-only; `unrar-free` is installed as a substitute |

**amd64-only by design:**

| Package | Notes |
|---|---|
| `powershell` | Microsoft's Linux packages are amd64-only; gracefully skipped by the installer |

---

## Step-by-Step Installation Guide

### Prerequisites

- **macOS with Apple Silicon** (M1/M2/M3/M4) and [UTM](https://mac.getutm.app/) installed
- Ubuntu 22.04 LTS ARM64 ISO — see Step 1 for the caveat about this

### Step 1 — Get the Ubuntu 22.04 ARM64 ISO and Set Up UTM

> **Important:** `cdimage.ubuntu.com/releases/22.04/release/` only offers a **server** ISO for ARM64 — there is no desktop ISO. You will install the server edition and add a GUI yourself in Step 1b.

**Download the server ISO:**
- Go to `https://cdimage.ubuntu.com/releases/22.04/release/`
- Download `ubuntu-22.04.x-live-server-arm64.iso`

**Create the UTM VM:**
1. In UTM, create a new VM: **Virtualize → Linux**
2. Select the ARM64 server ISO you downloaded
3. Allocate at least **4 GB RAM** (8 GB recommended) and **60 GB disk**
4. Complete the server installer (no desktop options will be presented — that's expected)

**Step 1b — Install a Desktop Environment**

Once the server is installed and you've logged in over the console or SSH, install Ubuntu's desktop:

```bash
sudo apt update
sudo apt install -y ubuntu-desktop
sudo reboot
```

After rebooting, the GDM login screen will appear. Log in as your user and you'll have a full GNOME desktop.

> **Tip:** `ubuntu-desktop` pulls in the full GNOME environment (~1.5 GB). If you prefer something lighter, use `ubuntu-desktop-minimal` instead — it skips bundled office apps and extras but gives you a complete, functional desktop.

### Step 2 — Download and Install CAST

CAST ships an official ARM64 `.deb`. Download the latest release:

```bash
# Check https://github.com/ekristen/cast/releases for the latest version
CAST_VERSION="1.0.8"
wget "https://github.com/ekristen/cast/releases/download/v${CAST_VERSION}/cast-v${CAST_VERSION}-linux-arm64.deb"
sudo dpkg -i "cast-v${CAST_VERSION}-linux-arm64.deb"
```

Verify:
```bash
cast --version
# cast version v1.0.8
```

### Step 3 — Run the SIFT Installer

```bash
sudo cast install teamdfir/sift-saltstack
```

This will:
- Download the SIFT SaltStack states from GitHub
- Run Salt to install ~150+ forensic tools
- Take 20–40 minutes depending on your internet speed

> The installer will print errors for the ARM64-unavailable packages listed above — **this is expected and non-fatal**. Everything else will install successfully.

### Step 4 — Verify Installation

```bash
# Check some key tools
which wireshark
which radare2
which sleuthkit
which autopsy
exiftool -ver
```

---

## What Gets Installed (What Works on ARM64)

The vast majority of SIFT tools install and run correctly on ARM64:

- **Disk/filesystem forensics:** `sleuthkit`, `autopsy`, `testdisk`, `extundelete`, `scalpel`, `foremost`, `dc3dd`, `dcfldd`, `ewf-tools`, `afflib-tools`, `xmount`
- **Memory/registry:** `volatility3` (via pip), `libregf1`, `libewf2`, `libvshadow1` (libraries install; CLI tools from GIFT PPA do not)
- **Malware analysis:** `radare2`, `yara`, `ssdeep`, `upx-ucl`, `vbindiff`, `ghex`
- **Network forensics:** `wireshark`, `tcpflow`, `ngrep`, `ssldump`, `tcpreplay`, `scapy`
- **Password/crypto:** `hashdeep`, `samdump2`, `ophcrack`, `hydra`, `aeskeyfind`
- **Metadata:** `exiftool` (13.x, compiled from source), `exif`
- **General tools:** `docker`, `git`, `python3`, `jq`, `vim`, `wget`, `curl`, `netcat`, etc.

---

## Packaging / Automation

See `install.sh` in this repository for a fully automated installation script.

---

## Background

SIFT (SANS Investigative Forensic Toolkit) is a widely-used free DFIR Linux distribution maintained by the SANS Institute. Historically it was distributed as a pre-built VM image (amd64 only). With the move to CAST + SaltStack, it became possible to install on any Ubuntu base system — but the ARM64 path needed some work.

This repo captures what was needed to make it work on Apple Silicon Macs via UTM, for the benefit of the community. The ARM64 laptop and desktop market is growing fast, and DFIR practitioners deserve a native-ARM SIFT experience.

---

## Contributing / Issues

The ARM64 fixes in the SaltStack states should ideally be upstreamed to [teamdfir/sift-saltstack](https://github.com/teamdfir/sift-saltstack). The key PRs needed are:

1. Fix `docker.sls` for ARM64 architecture pin
2. Fix `ubuntu-universe.sls` for ARM64 ports repository
3. Add ARM64 support to `radare2.sls` (may already be merged upstream)

If you find additional packages that need ARM64 fixes, please open an issue here or upstream.
