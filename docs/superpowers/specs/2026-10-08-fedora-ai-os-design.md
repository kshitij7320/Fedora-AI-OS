# Architecture Specification: Ultra-Lightweight Fedora-Based AI Operating System

## 1. System Overview & Objectives
This specification defines the architecture, file layout, package manifests, and automated build pipeline for a custom, ultra-lightweight, local-AI-integrated operating system based on Fedora Linux. 

The operating system is constructed as a bootable container utilizing **Fedora bootc** (`quay.io/fedora/fedora-bootc:latest`) and synthesized into bare-metal and virtual machine disk appliances using **bootc-image-builder**.

### 1.1 Core Principles
* **Ultra-Minimal Footprint:** Sub-600 MB RAM at idle (targeting ~380–450 MB headless, ~550 MB with Wayland). Legacy services, monolithic desktop environments, printing/scanning daemons, and cloud telemetry are strictly purged.
* **Decoupled AI Architecture:** Root filesystem layers remain pure and immutable (`/usr`). Static weights (GGUF, safetensors) are strictly prohibited from container layers. Weight storage is stateful and isolated in `/var/lib/models` and `/var/lib/ramalama`, surviving OS updates intact.
* **Modern Hardware Acceleration:** Full enablement of modern upstream Linux kernel acceleration interfaces for NPUs (AMD XDNA via `amdxdna`, Intel VPU via `intel_vpu`/`ivpu`) and unified GPU/iGPU compute (Vulkan Loader, Mesa Vulkan drivers, OpenCL runtime).
* **Deterministic Sandboxing:** SELinux targeted enforcing mode enabled by default. Services run as unprivileged dynamic or dedicated users with `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and explicit device filtering.
* **Diagnostic Telemetry without Shell Escapes:** A local `linux-mcp-server` daemon provides Model Context Protocol (MCP) telemetry (journal logs, package states, `/sys` thermals/frequencies) over a UNIX domain socket with zero shell execution capabilities.

---

## 2. Layer Architecture & Build Targets

The container image uses a multi-stage target inheritance structure:

```
+--------------------------------------------------------------+
|               quay.io/fedora/fedora-bootc:latest             |
+--------------------------------------------------------------+
                               |
                               v
+--------------------------------------------------------------+
| Stage 1: base-os                                             |
| - DNF: install_weak_deps=False, nodocs=True                  |
| - Stripped: cups, sane, bluez, ModemManager, avahi, geoclue  |
| - Drivers: amdxdna, ivpu, mesa-vulkan-drivers, clinfo        |
| - System Tuning: memlock unlimited, vm.max_map_count         |
+--------------------------------------------------------------+
                               |
                               v
+--------------------------------------------------------------+
| Stage 2: ai-headless (Default Appliance Target)              |
| - Runtime: ramalama (OCI-based rootless inference)           |
| - Server: sandboxed llama-server.service                     |
| - Diagnostic: linux-mcp-server (UNIX domain socket)          |
| - Storage: /var/lib/models, /var/lib/ramalama                |
| - Footprint: ~380-450 MB Idle RAM                            |
+--------------------------------------------------------------+
                               |
                               v
+--------------------------------------------------------------+
| Stage 3: ai-gui (Optional Graphical Layer)                   |
| - Compositor: labwc (wlroots Wayland compositor)             |
| - Terminal: foot                                             |
| - Audio: PipeWire + filter-chain (DeepFilterNet LV2 noise)   |
| - Footprint: < 580 MB Idle RAM                               |
+--------------------------------------------------------------+
```

---

## 3. Detailed Component Architecture

### 3.1 Base Operating System (`base-os`)
* **Package Manager Configuration (`/etc/dnf/conf.d/99-minimal.conf`):**
  ```ini
  [main]
  install_weak_deps=False
  nodocs=True
  keepcache=False
  tsflags=nodocs
  ```
* **Explicit Package Removal / Exclusion:**
  * Printing/Scanning: `cups`, `cups-libs`, `sane-backends`, `sane-backends-drivers-cameras`
  * Legacy Wireless/Cellular: `bluez`, `bluez-libs`, `ModemManager`, `geoclue2`
  * Service Discovery & Identity: `avahi`, `avahi-libs`, `sssd`
  * Heavy Desktop/Telemetry: GNOME, KDE, GDM, SDDM, `tracker3`, `evolution-data-server`, `polkit-gnome`
* **Acceleration Runtimes:**
  * Packages: `mesa-vulkan-drivers`, `vulkan-loader`, `vulkan-tools`, `clinfo`, `libdrm`, `kmod`
  * Kernel Module Verification: Upstream Linux kernel bundles `amdxdna` (Ryzen AI) and `intel_vpu`/`ivpu` (Core Ultra / Meteor Lake / Lunar Lake) out-of-the-box in Fedora kernels.

### 3.2 Kernel & Direct Memory Access (DMA) Tuning
NPUs and iGPUs map physical unified memory buffers via DMA. Insufficient virtual memory mapping limits or memory lock ceilings trigger fatal segmentation faults or OOM termination.
* **`/etc/security/limits.d/99-ai-memlock.conf`:**
  ```ini
  * soft memlock unlimited
  * hard memlock unlimited
  root soft memlock unlimited
  root hard memlock unlimited
  ```
* **`/etc/sysctl.d/99-ai-tuning.conf`:**
  ```ini
  vm.max_map_count = 1048576
  vm.overcommit_memory = 1
  fs.file-max = 2097152
  ```

### 3.3 Decoupled Local Inference Runtimes
* **Rootless OCI Execution (`ramalama`):**
  * Built using Podman and crun.
  * Dynamically manages model pulls from Ollama, Hugging Face, and OCI registries.
  * Writes to user or system `/var/lib/ramalama`.
* **Native Sandboxed Service (`llama-server.service`):**
  * Binary: `llama-server` (or containerized lightweight C++ build).
  * System User: `llamasrv` (UID/GID dedicated system account).
  * Supplementary Groups: `render`, `video`.
  * Security Sandboxing:
    * `ProtectSystem=strict`
    * `ProtectHome=yes`
    * `PrivateTmp=yes`
    * `ProtectKernelTunables=yes`
    * `ProtectControlGroups=yes`
    * `DevicePolicy=closed`
    * `DeviceAllow=/dev/dri rw`
    * `DeviceAllow=/dev/accel rw`
    * `MemoryDenyWriteExecute=no` (Needed for Vulkan JIT shader compilation)
    * `ReadWritePaths=/var/lib/models /run/llama-server`

### 3.4 Telemetry & Diagnostic Interface (`linux-mcp-server`)
* Lightweight native daemon exposing Model Context Protocol JSON-RPC endpoints:
  * `tools/call: get_system_metrics` (CPU, RAM, swap, thermal zones from `/sys/class/thermal`)
  * `tools/call: get_npu_gpu_status` (DRI render node stats, `/sys/class/accel` metrics)
  * `tools/call: get_journal_logs` (read-only tail of system journal via `journalctl -n <lines>`)
  * `tools/call: get_installed_packages` (query rpm/dnf transaction state)
* Systemd Socket Activation: `/run/mcp/linux-mcp.sock`.
* Service Security:
  * Runs as unprivileged `mcpsrv`.
  * `CapabilityBoundingSet=` (all capabilities dropped).
  * `NoNewPrivileges=true`.
  * `ProtectSystem=strict` with read-only view of `/proc` and `/sys`.

### 3.5 Optional Graphical Target (`ai-gui`) & Audio DSP
* Compositor: `labwc` with `foot` terminal.
* Autostart launches terminal running local AI control center or status monitor.
* Audio: PipeWire with `pipewire-module-filter-chain` configured for local LV2/LADSPA DeepFilterNet noise cancellation, running entirely offline without telemetry.

---

## 4. Appliance Generation Pipeline (`bootc-image-builder`)

### 4.1 Configuration Blueprint (`config.toml`)
```toml
[customizations.user.aioperator]
password = "$6$rounds=4096$salt$placeholder" # Or SSH key authentication
groups = ["wheel", "render", "video"]
description = "AI OS Operator"

[[customizations.user.aioperator.ssh_authorized_keys]]
key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... operator@ai-os"

[customizations.kernel]
arguments = ["quiet", "console=tty0", "console=ttyS0,115200n8"]
```

### 4.2 Build Orchestration (`build.sh`)
* Validates dependencies (`podman`, `selinux` permissions).
* Syntax checks all configuration files and units.
* Executes multi-stage container build:
  ```bash
  podman build --target ${TARGET} -t localhost/fedora-ai-os:${TARGET} .
  ```
* Invokes `quay.io/centos-bootc/bootc-image-builder:latest` with `--type qcow2|raw|iso`.
* Outputs bootable disk image to `./output/`.

---

## 5. Verification & Test Plan

1. **Footprint & Memory Verification:**
   * Boot appliance in QEMU with 2 GB vRAM.
   * Query `free -m` and `systemd-analyze` immediately upon boot.
   * Success criteria: Headless idle RAM < 450 MB; GUI idle RAM < 600 MB.
2. **NPU/GPU Driver Nodes:**
   * Verify `/dev/dri/renderD128` and `/dev/accel/*` permissions and group ownership (`render`).
   * Test Vulkan device enumeration via `vulkaninfo --summary`.
3. **Decoupled Weight Storage:**
   * Download a GGUF model (e.g. `TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf`) into `/var/lib/models`.
   * Trigger simulated bootc upgrade and confirm weights remain intact.
4. **Sandboxing & SELinux:**
   * Run `sestatus` to confirm `SELinux status: enabled` and `Current mode: enforcing`.
   * Confirm `llama-server` and `linux-mcp-server` units enforce systemd sandbox flags.
