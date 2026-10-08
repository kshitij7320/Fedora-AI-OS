# Fedora-Based AI Operating System

An ultra-lightweight, transactional, local-AI-integrated operating system based on **Fedora Linux**, built using modern bootable container technology (**Fedora bootc** and **bootc-image-builder**).

---

## Architecture Overview

Traditional Linux installations for AI workloads often suffer from filesystem drift, bloated desktop environments, unnecessary hardware daemons, and non-reproducible software dependencies. This OS solves these challenges by treating the operating system as an **immutable, bootable OCI container image** (`quay.io/fedora/fedora-bootc:latest`).

```
+-------------------------------------------------------------------------+
|                  Bootable Container Layer (bootc rootfs)                |
|  - Immutable /usr base with ostree transactional deployment             |
|  - Strictly pruned: No cups, sane, bluez, ModemManager, avahi, geoclue  |
|  - Kernel drivers: amdxdna (AMD Ryzen AI NPU), ivpu (Intel Core Ultra)  |
|  - Compute runtimes: mesa-vulkan-drivers, vulkan-loader, OpenCL         |
|  - Telemetry: linux-mcp-server (UNIX socket, JSON-RPC, read-only)       |
+-------------------------------------------------------------------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v                                           v
+-----------------------------+             +-----------------------------+
|    ai-headless (Default)    |             |       ai-gui (Optional)     |
| - Idle RAM: ~380-450 MB     |             | - Idle RAM: < 580 MB        |
| - Pure CLI / socket daemon  |             | - labwc Wayland compositor  |
| - ramalama + llama-server   |             | - foot terminal kiosk       |
| - Direct server appliance   |             | - PipeWire DeepFilter DSP   |
+-----------------------------+             +-----------------------------+
                                     |
                                     v
+-------------------------------------------------------------------------+
|              Decoupled Persistent Model Storage (/var mount)            |
|  - /var/lib/models      -> GGUF / llama-server storage (persistent)     |
|  - /var/lib/ramalama    -> OCI rootless models (podman/crun container)  |
|  * Survives transactional OS updates (bootc upgrade) without data loss  |
+-------------------------------------------------------------------------+
```

---

## Core Design Principles

1. **Root Filesystem Purity & Transactional Upgrades:** Built from `quay.io/fedora/fedora-bootc`. Updates are atomic, staged in the background, and easily rolled back using standard `bootc upgrade` and `bootc rollback` commands.
2. **No Baked Model Weights:** The root filesystem layers (`/usr`) contain zero static model weights. Weights are stored strictly on persistent volumes (`/var/lib/models` and `/var/lib/ramalama`).
3. **Hardware Acceleration:** Native inclusion of modern upstream Linux kernel acceleration drivers for NPUs:
   - **AMD XDNA** (`amdxdna` driver module for AMD Ryzen AI series)
   - **Intel VPU** (`intel_vpu`/`ivpu` driver module for Core Ultra / Meteor Lake / Lunar Lake)
   - **Mesa Vulkan & Compute** (`mesa-vulkan-drivers`, `vulkan-loader`, `clinfo`)
4. **DMA & Resource Optimization:** Eliminates unified physical DMA buffer mapping crashes by setting unlimited memory lock limits in `/etc/security/limits.d/99-ai-memlock.conf` and expanding kernel virtual memory maps in `/etc/sysctl.d/99-ai-tuning.conf` (`vm.max_map_count = 1048576`).
5. **Deterministic Sandboxing & SELinux:** SELinux runs in targeted enforcing mode. All inference and telemetry services run unprivileged with `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and restricted device access.

---

## Package Omission & Pruning Checklist

To guarantee a sub-600 MB RAM idle footprint, the following services and packages are purged and masked:

* **Desktop Environments:** GNOME Shell, KDE Plasma, GDM, SDDM, Tracker 3, Evolution Data Server, Polkit GNOME agents are omitted completely.
* **Printing & Scanning:** `cups`, `cups-libs`, `sane-backends`, `sane-backends-drivers-cameras` are removed and masked.
* **Legacy Daemons & Telemetry:** `bluez`, `ModemManager`, `geoclue2`, `avahi`, and cloud-telemetry daemons are removed and masked.
* **Package Management:** `install_weak_deps=False` and `nodocs=True` are enforced across all DNF operations in `/etc/dnf/conf.d/99-minimal.conf`.

---

## Project Workspace Structure

```text
.
├── Containerfile                  # Multi-stage bootable container definition (base-os, ai-headless, ai-gui)
├── config.toml                    # bootc-image-builder appliance blueprint
├── build.sh                       # Automation script for container build and image synthesis
├── dnf/
│   └── 99-minimal.conf            # DNF drop-in disabling weak dependencies & docs
├── limits.d/
│   └── 99-ai-memlock.conf         # Unlimited memlock for unified DMA buffer allocation
├── sysctl.d/
│   └── 99-ai-tuning.conf          # Kernel virtual memory overcommit & map limits
├── systemd/
│   ├── llama-server.service       # Sandboxed llama.cpp server service
│   ├── llama-server.env           # Configuration defaults for llama-server
│   ├── linux-mcp-server.service   # Hardened systemd service for telemetry
│   └── linux-mcp-server.socket    # Systemd socket activation unit for MCP
├── mcp/
│   └── linux_mcp_server.py        # Native Python stdlib read-only MCP daemon
├── audio/
│   └── 99-deepfilter-pipewire.conf# PipeWire filter-chain configuration for offline DSP
├── wayland/
│   └── labwc-autostart            # Autostart configuration for labwc + foot
├── tests/                         # Full automated test suite
└── README.md                      # Architecture guide and benchmark test plan
```

---

## Build & Deployment Guide

### Prerequisites
* A Linux host with **Podman** installed.
* Hardware virtualization enabled (`/dev/kvm`).

### Building Bootable Images

The `build.sh` script automates the multi-stage build and calls `bootc-image-builder`:

```bash
# 1. Build default Headless AI appliance in QCOW2 format (for QEMU / KVM)
./build.sh --target headless --format qcow2

# 2. Build Minimal Wayland Kiosk appliance in ISO format (for bare-metal installation)
./build.sh --target gui --format iso

# 3. Dry-run validation (checks syntax and prints commands without running container builds)
./build.sh --dry-run
```

Output disk images will be generated into `./output/<format>/disk.<format>`.

### Testing in QEMU / KVM

You can immediately boot the generated QCOW2 image in QEMU:

```bash
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -drive file=output/qcow2/disk.qcow2,format=qcow2 \
    -enable-kvm \
    -net nic -net user,hostfwd=tcp::8080-:8080,hostfwd=tcp::2222-:22
```

Default credentials:
* **User:** `aioperator`
* **Groups:** `wheel`, `render`, `video`

---

## Benchmark & Test Plan

### 1. Idle RAM Footprint Verification

Boot the system without active workloads and execute:

```bash
free -h
```

**Target Benchmarks:**
* **Headless Profile:** Under **450 MB RAM** at idle (typical: ~380–420 MB).
* **Wayland GUI Profile:** Under **600 MB RAM** at idle (typical: ~520–560 MB).

To verify process-level memory consumption:
```bash
ps -eo pid,user,rss,comm --sort -rss | head -n 15
```

### 2. Boot Speed Profiling

Evaluate systemd initialization latency:

```bash
# View overall firmware, loader, kernel, and userspace boot duration
systemd-analyze

# Inspect slowest starting units
systemd-analyze blame

# View the critical startup dependency chain
systemd-analyze critical-chain
```

Target userspace startup duration is under **4 seconds** on modern NVMe hardware.

### 3. Hardware Acceleration & NPU Validation

Verify that unified memory render and NPU accelerator nodes are available:

```bash
# Check DRM render nodes
ls -l /dev/dri/
# Expected: /dev/dri/card0, /dev/dri/renderD128 (owned by group 'render')

# Check NPU compute nodes
ls -l /dev/accel/
# Expected: /dev/accel/accel0 (owned by group 'render')

# Verify Vulkan compute device enumeration
vulkaninfo --summary

# Verify OpenCL compute platforms
clinfo
```

### 4. SELinux & Service Sandboxing Audit

Verify security hardening:

```bash
# Verify SELinux is in enforcing mode
sestatus
# Expected: Current mode: enforcing

# Verify llama-server sandboxing
systemd-analyze security llama-server.service

# Verify linux-mcp-server sandboxing
systemd-analyze security linux-mcp-server.service
```

---

## Decoupled Model Storage & Inference Workflows

Model weights are decoupled from the OS and persist across OS image updates.

### Workflow A: Dynamic Inference via RamaLama (Rootless OCI)

RamaLama allows users to pull and run quantized models without root permissions:

```bash
# Pull and chat with an open model via Ollama registry
ramalama run ollama://tinyllama

# Run with local Vulkan or ROCm runtime acceleration
ramalama run --runtime llama.cpp huggingface://TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF

# Models are saved statefully in /var/lib/ramalama or ~/.local/share/ramalama
```

### Workflow B: Persistent llama-server Service

For persistent HTTP/REST endpoints:

1. Place your GGUF model file into `/var/lib/models/`:
   ```bash
   curl -L -o /var/lib/models/tinyllama-chat.gguf \
     https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf
   ```
2. Adjust `/etc/llama-server/llama-server.env` if necessary:
   ```ini
   LLAMA_HOST=127.0.0.1
   LLAMA_PORT=8080
   LLAMA_MODELS_DIR=/var/lib/models
   LLAMA_CTX_SIZE=4096
   LLAMA_N_GPU_LAYERS=99
   ```
3. Restart the service:
   ```bash
   sudo systemctl restart llama-server.service
   ```
4. Query the OpenAI-compatible completions endpoint:
   ```bash
   curl http://127.0.0.1:8080/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{
       "model": "tinyllama-chat.gguf",
       "messages": [{"role": "user", "content": "Hello!"}]
     }'
   ```

---

## Model Context Protocol (MCP) Diagnostic Interface

The OS includes `linux-mcp-server`, a native read-only JSON-RPC Model Context Protocol daemon listening on `/run/mcp/linux-mcp.sock`.

### Available Tools:
* `get_system_metrics`: Gathers load averages, uptime, thermals, and `/proc/meminfo` metrics.
* `get_npu_gpu_status`: Inspects `/sys/class/drm` and `/sys/class/accel` devices.
* `get_journal_logs`: Fetches recent systemd log entries for specific units.
* `get_installed_packages`: Queries installed RPM packages.

### Connecting to the Socket:

```bash
# Query MCP server over UNIX domain socket using socat
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_system_metrics","arguments":{}}}' | \
  socat - UNIX-CONNECT:/run/mcp/linux-mcp.sock
```

The daemon runs unprivileged as user `mcpsrv` with `ProtectSystem=strict` and all Linux capabilities dropped, ensuring safe observation by AI agents without the risk of host compromise.
