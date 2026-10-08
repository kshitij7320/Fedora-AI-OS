# Fedora-Based AI OS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete, reproducible bootable container and image-builder workspace for an ultra-lightweight, local-AI-integrated operating system based on Fedora Linux bootc.

**Architecture:** A multi-stage bootable container (`base-os` → `ai-headless` → `ai-gui`) built upon `quay.io/fedora/fedora-bootc:latest`. Features purged legacy daemons, NPU/GPU hardware acceleration, kernel DMA memlock tuning, decoupled non-baked model storage, sandboxed local inference (`ramalama` and `llama-server`), and a zero-cloud read-only telemetry daemon (`linux-mcp-server`) exposed via UNIX domain socket.

**Tech Stack:** Fedora bootc, bootc-image-builder, Podman, systemd sandboxing, Python 3 (stdlib JSON-RPC MCP), llama.cpp / RamaLama, Vulkan / ROCm / AMD XDNA / Intel VPU, labwc, PipeWire.

**Spec:** `docs/superpowers/specs/2026-10-08-fedora-ai-os-design.md`

## Global Constraints
- Base image: `quay.io/fedora/fedora-bootc:latest`
- Weak dependencies: `install_weak_deps=False` and `nodocs=True` enforced across all DNF operations
- Omissions: No cups, sane, bluez, ModemManager, avahi, geoclue2, cloud telemetry, or heavy desktop environments (GNOME/KDE/GDM/SDDM)
- No baked model weights: Root filesystem (`/usr`) contains zero static weights; model persistence lives strictly under `/var/lib/models` and `/var/lib/ramalama`
- Security: Enforce SELinux targeted mode, `ProtectSystem=strict`, `PrivateTmp=yes`, and drop Linux capabilities on diagnostic daemons
- RAM Target: Idle memory footprint < 450 MB (headless) and < 600 MB (GUI)

---

### Task 1: System Optimization & Kernel DMA Configuration

**Files:**
- Create: `dnf/99-minimal.conf`
- Create: `limits.d/99-ai-memlock.conf`
- Create: `sysctl.d/99-ai-tuning.conf`
- Create: `tests/test_sysconfig.py`

**Interfaces:**
- Consumes: None (Root configuration drop-ins)
- Produces: System drop-in configurations for DNF package management, PAM/systemd memlock ceilings, and kernel virtual memory overcommit / map limits.

- [ ] **Step 1: Write the test verifying drop-in configurations**

```python
# tests/test_sysconfig.py
import configparser
import os
import re

def test_dnf_minimal_conf():
    path = "dnf/99-minimal.conf"
    assert os.path.isfile(path), f"Missing {path}"
    parser = configparser.ConfigParser()
    parser.read(path)
    assert "main" in parser.sections()
    assert parser.get("main", "install_weak_deps").lower() == "false"
    assert parser.get("main", "nodocs").lower() == "true"
    assert parser.get("main", "keepcache").lower() == "false"

def test_limits_memlock_conf():
    path = "limits.d/99-ai-memlock.conf"
    assert os.path.isfile(path), f"Missing {path}"
    with open(path, "r") as f:
        content = f.read()
    assert re.search(r"\*\s+soft\s+memlock\s+unlimited", content)
    assert re.search(r"\*\s+hard\s+memlock\s+unlimited", content)
    assert re.search(r"root\s+soft\s+memlock\s+unlimited", content)
    assert re.search(r"root\s+hard\s+memlock\s+unlimited", content)

def test_sysctl_ai_tuning():
    path = "sysctl.d/99-ai-tuning.conf"
    assert os.path.isfile(path), f"Missing {path}"
    with open(path, "r") as f:
        content = f.read()
    assert re.search(r"vm\.max_map_count\s*=\s*1048576", content)
    assert re.search(r"vm\.overcommit_memory\s*=\s*1", content)
    assert re.search(r"fs\.file-max\s*=\s*2097152", content)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_sysconfig.py`
Expected: FAIL (files do not exist yet)

- [ ] **Step 3: Implement minimal configuration drop-in files**

Write `dnf/99-minimal.conf`:
```ini
[main]
install_weak_deps=False
nodocs=True
keepcache=False
tsflags=nodocs
```

Write `limits.d/99-ai-memlock.conf`:
```ini
# Allow unlimited memory locking for DMA / physical memory mapping (NPU & GPU buffers)
* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
```

Write `sysctl.d/99-ai-tuning.conf`:
```ini
# Memory mapping and overcommit settings for high-throughput tensor buffers
vm.max_map_count = 1048576
vm.overcommit_memory = 1
fs.file-max = 2097152
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_sysconfig.py`
Expected: Ran 3 tests, all PASS

- [ ] **Step 5: Commit**

```bash
git add dnf/ limits.d/ sysctl.d/ tests/test_sysconfig.py
git commit -m "feat(sysconfig): add DNF, memlock limits, and sysctl tuning drop-ins"
```

---

### Task 2: Diagnostic Telemetry Daemon (`linux-mcp-server`) & Systemd Units

**Files:**
- Create: `mcp/linux_mcp_server.py`
- Create: `systemd/linux-mcp-server.service`
- Create: `systemd/linux-mcp-server.socket`
- Create: `tests/test_mcp_server.py`

**Interfaces:**
- Consumes: `/sys` metrics, `/proc` stats, `journalctl`, `rpm -qa`
- Produces: JSON-RPC Model Context Protocol (MCP) server listening on UNIX socket `/run/mcp/linux-mcp.sock` with read-only tools: `get_system_metrics`, `get_npu_gpu_status`, `get_journal_logs`, `get_installed_packages`.

- [ ] **Step 1: Write tests for MCP server protocol handling and systemd sandboxing**

```python
# tests/test_mcp_server.py
import json
import os
import unittest
import sys

sys.path.insert(0, os.path.abspath("mcp"))
import linux_mcp_server

class TestLinuxMCPServer(unittest.TestCase):
    def setUp(self):
        self.server = linux_mcp_server.LinuxMCPServer()

    def test_tools_list(self):
        req = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        resp = self.server.handle_request(req)
        self.assertEqual(resp["id"], 1)
        tools = [t["name"] for t in resp["result"]["tools"]]
        self.assertIn("get_system_metrics", tools)
        self.assertIn("get_npu_gpu_status", tools)
        self.assertIn("get_journal_logs", tools)
        self.assertIn("get_installed_packages", tools)

    def test_call_system_metrics(self):
        req = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "get_system_metrics", "arguments": {}}
        }
        resp = self.server.handle_request(req)
        self.assertEqual(resp["id"], 2)
        content = json.loads(resp["result"]["content"][0]["text"])
        self.assertIn("memory", content)
        self.assertIn("load_avg", content)

    def test_systemd_service_hardening(self):
        svc_path = "systemd/linux-mcp-server.service"
        self.assertTrue(os.path.isfile(svc_path))
        with open(svc_path, "r") as f:
            content = f.read()
        self.assertIn("ProtectSystem=strict", content)
        self.assertIn("NoNewPrivileges=true", content)
        self.assertIn("CapabilityBoundingSet=", content)
        self.assertIn("PrivateTmp=yes", content)

    def test_systemd_socket_unit(self):
        sock_path = "systemd/linux-mcp-server.socket"
        self.assertTrue(os.path.isfile(sock_path))
        with open(sock_path, "r") as f:
            content = f.read()
        self.assertIn("ListenStream=/run/mcp/linux-mcp.sock", content)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_mcp_server.py`
Expected: FAIL (modules and unit files do not exist yet)

- [ ] **Step 3: Implement `mcp/linux_mcp_server.py`, `systemd/linux-mcp-server.service`, and `systemd/linux-mcp-server.socket`**

Implement `mcp/linux_mcp_server.py` with stdlib JSON-RPC protocol parser and read-only telemetry collectors (`/proc/meminfo`, `/proc/loadavg`, `/sys/class/thermal`, `/sys/class/drm`, `/sys/class/accel`, `journalctl`, `rpm -qa`).

Implement `systemd/linux-mcp-server.service`:
```ini
[Unit]
Description=Linux Model Context Protocol (MCP) Read-Only Diagnostic Daemon
Documentation=man:systemd(1)
Requires=linux-mcp-server.socket
After=network.target linux-mcp-server.socket

[Service]
Type=simple
User=mcpsrv
Group=mcpsrv
SupplementaryGroups=systemd-journal
ExecStart=/usr/bin/python3 /usr/libexec/linux-mcp-server/linux_mcp_server.py --socket /run/mcp/linux-mcp.sock
Restart=on-failure
RestartSec=3s

# Hardened Security & Sandboxing
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
RuntimeDirectory=mcp
RuntimeDirectoryMode=0755
```

Implement `systemd/linux-mcp-server.socket`:
```ini
[Unit]
Description=Linux MCP Diagnostic Server Socket
PartOf=linux-mcp-server.service

[Socket]
ListenStream=/run/mcp/linux-mcp.sock
SocketUser=mcpsrv
SocketGroup=wheel
SocketMode=0660
DirectoryMode=0755

[Install]
WantedBy=sockets.target
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_mcp_server.py`
Expected: Ran 4 tests, all PASS

- [ ] **Step 5: Commit**

```bash
git add mcp/ systemd/linux-mcp-server.* tests/test_mcp_server.py
git commit -m "feat(mcp): add read-only diagnostic MCP server and hardened systemd units"
```

---

### Task 3: Local Inference (`llama-server`) Sandboxing & Profile Units

**Files:**
- Create: `systemd/llama-server.service`
- Create: `systemd/llama-server.env`
- Create: `audio/99-deepfilter-pipewire.conf`
- Create: `wayland/labwc-autostart`
- Create: `tests/test_systemd_and_profiles.py`

**Interfaces:**
- Consumes: `/var/lib/models`, `/dev/dri`, `/dev/accel`
- Produces: Systemd sandboxed service for llama.cpp server, PipeWire filter-chain configuration, and labwc desktop autostart.

- [ ] **Step 1: Write test for inference unit hardening and Wayland/Audio configs**

```python
# tests/test_systemd_and_profiles.py
import os
import unittest

class TestSystemdAndProfiles(unittest.TestCase):
    def test_llama_server_service(self):
        path = "systemd/llama-server.service"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("User=llamasrv", content)
        self.assertIn("SupplementaryGroups=render video", content)
        self.assertIn("ProtectSystem=strict", content)
        self.assertIn("DeviceAllow=/dev/dri", content)
        self.assertIn("DeviceAllow=/dev/accel", content)
        self.assertIn("ReadWritePaths=/var/lib/models", content)
        self.assertIn("MemoryDenyWriteExecute=no", content)

    def test_llama_env(self):
        path = "systemd/llama-server.env"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("LLAMA_HOST=127.0.0.1", content)
        self.assertIn("LLAMA_PORT=8080", content)
        self.assertIn("LLAMA_MODELS_DIR=/var/lib/models", content)

    def test_audio_filter_chain(self):
        path = "audio/99-deepfilter-pipewire.conf"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("pipewire-module-filter-chain", content)
        self.assertIn("deepfilter", content.lower())

    def test_wayland_autostart(self):
        path = "wayland/labwc-autostart"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("foot", content)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_systemd_and_profiles.py`
Expected: FAIL (files do not exist yet)

- [ ] **Step 3: Implement `systemd/llama-server.service`, `systemd/llama-server.env`, audio, and wayland autostart**

Implement `systemd/llama-server.service` with strict device isolation (`/dev/dri`, `/dev/accel`), stateful `/var/lib/models` write allowance, and unprivileged user isolation.

Implement `systemd/llama-server.env` with default runtime arguments (`LLAMA_HOST=127.0.0.1`, `LLAMA_PORT=8080`, `LLAMA_CTX_SIZE=4096`, `LLAMA_N_GPU_LAYERS=99`, `LLAMA_MODELS_DIR=/var/lib/models`).

Implement `audio/99-deepfilter-pipewire.conf` setting up a local offline noise suppression sink and source via PipeWire filter-chain without cloud telemetry.

Implement `wayland/labwc-autostart` script to launch the minimal foot terminal and status monitoring session.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_systemd_and_profiles.py`
Expected: Ran 4 tests, all PASS

- [ ] **Step 5: Commit**

```bash
git add systemd/llama-server.* audio/ wayland/ tests/test_systemd_and_profiles.py
git commit -m "feat(runtime): add sandboxed llama-server service, audio filter-chain, and wayland config"
```

---

### Task 4: Multi-Stage Bootable Containerfile

**Files:**
- Create: `Containerfile`
- Create: `tests/test_containerfile.py`

**Interfaces:**
- Consumes: `quay.io/fedora/fedora-bootc:latest`, `dnf/99-minimal.conf`, `limits.d/`, `sysctl.d/`, `systemd/`, `mcp/`, `audio/`, `wayland/`
- Produces: Bootable container image with targets `base-os`, `ai-headless` (default), and `ai-gui`.

- [ ] **Step 1: Write test verifying Containerfile multi-stage structure and package directives**

```python
# tests/test_containerfile.py
import os
import re
import unittest

class TestContainerfile(unittest.TestCase):
    def setUp(self):
        self.path = "Containerfile"
        self.assertTrue(os.path.isfile(self.path), "Containerfile missing")
        with open(self.path, "r") as f:
            self.content = f.read()

    def test_base_image_and_targets(self):
        self.assertIn("FROM quay.io/fedora/fedora-bootc:latest AS base-os", self.content)
        self.assertIn("FROM base-os AS ai-headless", self.content)
        self.assertIn("FROM ai-headless AS ai-gui", self.content)

    def test_omission_pruning(self):
        # Must remove or exclude cups, sane, bluez, ModemManager, avahi, geoclue2
        omissions = ["cups", "sane", "bluez", "ModemManager", "avahi", "geoclue2"]
        for o in omissions:
            self.assertTrue(
                re.search(rf"\b{o}\b", self.content, re.IGNORECASE),
                f"Missing removal or exclusion of {o}"
            )

    def test_hardware_acceleration(self):
        self.assertIn("mesa-vulkan-drivers", self.content)
        self.assertIn("vulkan-loader", self.content)
        self.assertIn("vulkan-tools", self.content)
        self.assertIn("clinfo", self.content)

    def test_user_creation_and_groups(self):
        self.assertIn("llamasrv", self.content)
        self.assertIn("mcpsrv", self.content)
        self.assertIn("render", self.content)

    def test_stateful_directories(self):
        self.assertIn("/var/lib/models", self.content)
        self.assertIn("/var/lib/ramalama", self.content)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_containerfile.py`
Expected: FAIL (Containerfile missing)

- [ ] **Step 3: Implement multi-stage `Containerfile`**

Write `Containerfile`:
1. `AS base-os`:
   - Copy `dnf/99-minimal.conf` into `/etc/dnf/conf.d/`
   - Copy `limits.d/99-ai-memlock.conf` into `/etc/security/limits.d/`
   - Copy `sysctl.d/99-ai-tuning.conf` into `/etc/sysctl.d/`
   - Run `dnf remove -y cups* sane* bluez* ModemManager geoclue2 avahi*`
   - Mask unneeded services via `systemctl mask`
   - Install hardware acceleration: `mesa-vulkan-drivers`, `mesa-va-drivers`, `vulkan-loader`, `vulkan-tools`, `clinfo`, `libdrm`, `kmod`, `podman`, `crun`
   - Clean all dnf caches (`dnf clean all && rm -rf /var/cache/dnf/*`)
2. `AS ai-headless`:
   - Install `ramalama` and Python stdlib support
   - Create system users `llamasrv` and `mcpsrv` with membership in `render`, `video`, `systemd-journal`
   - Install `mcp/linux_mcp_server.py` to `/usr/libexec/linux-mcp-server/linux_mcp_server.py`
   - Copy systemd units (`llama-server.service`, `llama-server.env`, `linux-mcp-server.service`, `linux-mcp-server.socket`)
   - Enable `linux-mcp-server.socket` and `llama-server.service`
   - Provision stateful directory skeletons: `/var/lib/models`, `/var/lib/ramalama`, `/run/mcp`
3. `AS ai-gui`:
   - Install `labwc`, `foot`, `seatd`, `pipewire`, `wireplumber`, `pipewire-plugin-filter-chain`
   - Copy `audio/99-deepfilter-pipewire.conf` to `/etc/pipewire/pipewire.conf.d/`
   - Copy `wayland/labwc-autostart` to `/etc/xdg/labwc/autostart`

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_containerfile.py`
Expected: Ran 5 tests, all PASS

- [ ] **Step 5: Commit**

```bash
git add Containerfile tests/test_containerfile.py
git commit -m "feat(container): add multi-stage bootable Containerfile with hardware acceleration and pruned daemons"
```

---

### Task 5: Appliance Configuration (`config.toml`) & Build Automation (`build.sh`)

**Files:**
- Create: `config.toml`
- Create: `build.sh`
- Create: `tests/test_build_pipeline.py`

**Interfaces:**
- Consumes: Containerfile, podman, bootc-image-builder
- Produces: Validated `config.toml` image blueprint and `build.sh` script to build bootable media (`qcow2`, `raw`, `iso`).

- [ ] **Step 1: Write test verifying `config.toml` structure and `build.sh` execution interface**

```python
# tests/test_build_pipeline.py
import os
import subprocess
import unittest

class TestBuildPipeline(unittest.TestCase):
    def test_config_toml(self):
        path = "config.toml"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("customizations.user.aioperator", content)
        self.assertIn("wheel", content)
        self.assertIn("render", content)
        self.assertIn("video", content)

    def test_build_sh_help(self):
        path = "build.sh"
        self.assertTrue(os.path.isfile(path))
        self.assertTrue(os.access(path, os.X_OK))
        res = subprocess.run(["./build.sh", "--help"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertIn("--target", res.stdout)
        self.assertIn("--format", res.stdout)
        self.assertIn("--dry-run", res.stdout)

    def test_build_sh_dry_run(self):
        res = subprocess.run(["./build.sh", "--dry-run", "--target", "headless", "--format", "qcow2"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertIn("DRY RUN", res.stdout)
        self.assertIn("ai-headless", res.stdout)
        self.assertIn("bootc-image-builder", res.stdout)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_build_pipeline.py`
Expected: FAIL (files do not exist yet)

- [ ] **Step 3: Implement `config.toml` and `build.sh`**

Implement `config.toml`:
```toml
[customizations.user.aioperator]
groups = ["wheel", "render", "video"]
description = "AI OS Appliance Operator"
home = "/var/home/aioperator"

[customizations.kernel]
arguments = ["quiet", "console=tty0", "console=ttyS0,115200n8", "amdxdna.enable=1"]

[customizations.filesystem]
# Enforce transactional root with persistent /var
root_fs_type = "xfs"
```

Implement `build.sh`:
- Flags: `--target [headless|gui]`, `--format [qcow2|raw|iso|ami]`, `--tag [imagename]`, `--output-dir [dir]`, `--dry-run`, `--help`.
- Validates prerequisites (`podman` command, container storage).
- Performs syntax checks on Containerfile and config.toml.
- Builds bootc container image using `podman build --target ...`.
- Runs `bootc-image-builder` container:
  ```bash
  podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$(pwd)/config.toml":/config.toml:ro \
    -v "${OUTPUT_DIR}":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type "${FORMAT}" \
    --config /config.toml \
    --local \
    "${IMAGE_TAG}"
  ```
- Prints QEMU launch command for immediate virtualization testing.
- Make `build.sh` executable (`chmod +x build.sh`).

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_build_pipeline.py`
Expected: Ran 3 tests, all PASS

- [ ] **Step 5: Commit**

```bash
git add config.toml build.sh tests/test_build_pipeline.py
git commit -m "feat(build): add bootc-image-builder config and automated build script"
```

---

### Task 6: Architectural Guide, Benchmark Test Plan & Model Storage Workflows (`README.md`)

**Files:**
- Create: `README.md`
- Create: `tests/test_docs.py`

**Interfaces:**
- Consumes: All repository artifacts
- Produces: Complete technical documentation, benchmark test plan (idle RAM, boot time), and model pulling workflows.

- [ ] **Step 1: Write test verifying README completeness and required sections**

```python
# tests/test_docs.py
import os
import unittest

class TestDocumentation(unittest.TestCase):
    def test_readme_sections(self):
        path = "README.md"
        self.assertTrue(os.path.isfile(path))
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("Architecture Overview", content)
        self.assertIn("Benchmark & Test Plan", content)
        self.assertIn("RAM Footprint", content)
        self.assertIn("Decoupled Model Storage", content)
        self.assertIn("RamaLama", content)
        self.assertIn("Hardware Acceleration", content)
        self.assertIn("SELinux", content)
        self.assertIn("Model Context Protocol", content)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests/test_docs.py`
Expected: FAIL (`README.md` missing)

- [ ] **Step 3: Implement comprehensive `README.md`**

Write `README.md` covering:
1. Executive Summary & Design Principles (Rootfs purity, <600MB RAM target, decoupled models).
2. Project Directory Structure.
3. Build & Flash Guide (`./build.sh --target headless --format qcow2`).
4. Benchmark Test Plan:
   - Idle RAM verification with `free -m` and `/proc/meminfo`.
   - Boot speed profiling with `systemd-analyze blame` and `systemd-analyze critical-chain`.
   - NPU driver validation (`/dev/accel/*`, `amdxdna`, `ivpu`).
5. Decoupled Model Workflows:
   - Rootless OCI model serving via `ramalama run ollama://tinyllama`.
   - Native service serving via `/var/lib/models` and `llama-server.service`.
6. Telemetry & Observation:
   - Querying `linux-mcp-server` over `/run/mcp/linux-mcp.sock`.
7. SELinux & Sandbox Hardening matrix.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests/test_docs.py`
Expected: Ran 1 test, all PASS

- [ ] **Step 5: Commit**

```bash
git add README.md tests/test_docs.py
git commit -m "docs: add architecture guide, benchmark test plan, and model workflows"
```

---

### Task 7: Full Test Suite Execution & Workspace Verification

**Files:**
- Execute: `python3 -m unittest discover tests`

- [ ] **Step 1: Run comprehensive test discovery**

Run: `python3 -m unittest discover tests -v`
Expected: All tests pass across sysconfig, MCP server, systemd/profiles, containerfile, build pipeline, and docs.

- [ ] **Step 2: Dry-run build script verification**

Run: `./build.sh --dry-run --target headless --format qcow2`
Run: `./build.sh --dry-run --target gui --format iso`
Expected: Clean exit code 0 with correct container targets and image-builder commands.

- [ ] **Step 3: Final commit and cleanliness check**

```bash
git status
```
Expected: Working tree clean.
