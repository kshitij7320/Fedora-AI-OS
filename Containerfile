# ==============================================================================
# Fedora AI OS: Multi-Stage Bootable Container Image
# Base: quay.io/fedora/fedora-bootc:latest
# Target 1: base-os      (Hardware accelerated, pruned kernel/OS foundation)
# Target 2: ai-headless  (Default appliance: decoupled models, ramalama, llama-server, MCP)
# Target 3: ai-gui       (Optional minimal graphical kiosk: labwc, foot, audio filter-chain)
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Base Operating System Foundation
# ------------------------------------------------------------------------------
FROM quay.io/fedora/fedora-bootc:latest AS base-os

LABEL org.opencontainers.image.title="Fedora AI OS (Base)" \
      org.opencontainers.image.description="Minimal Fedora Bootc Base with NPU/GPU Hardware Acceleration" \
      maintainer="AI Distribution Engineering"

# 1. Apply DNF strict minimization drop-ins (disable weak dependencies & documentation)
COPY dnf/99-minimal.conf /etc/dnf/conf.d/99-minimal.conf

# 2. Apply DMA memory lock ceilings and kernel tuning
COPY limits.d/99-ai-memlock.conf /etc/security/limits.d/99-ai-memlock.conf
COPY sysctl.d/99-ai-tuning.conf /etc/sysctl.d/99-ai-tuning.conf

# 3. Strip legacy daemons, desktop bloat, printing, scanning, and unnecessary background services
RUN set -eux; \
    echo "Pruning legacy desktop, printing, and scanning packages..."; \
    dnf remove -y \
        cups \
        cups-libs \
        sane-backends \
        sane-backends-drivers-cameras \
        bluez \
        bluez-libs \
        ModemManager \
        geoclue2 \
        avahi \
        avahi-libs \
        tracker3 \
        evolution-data-server || true; \
    # Explicitly mask pruned system services
    systemctl mask \
        cups.service \
        cups.socket \
        cups.path \
        ModemManager.service \
        avahi-daemon.service \
        avahi-daemon.socket; \
    # Install upstream hardware compute & acceleration packages
    # Keeps amdxdna (Ryzen AI) and ivpu (Intel Core Ultra) kernel modules active
    dnf install -y \
        mesa-vulkan-drivers \
        mesa-va-drivers \
        vulkan-loader \
        vulkan-tools \
        clinfo \
        libdrm \
        kmod \
        podman \
        crun \
        python3 \
        procps-ng \
        pciutils \
        iproute \
        util-linux; \
    # Purge dnf caches to maximize rootfs layer compression
    dnf clean all; \
    rm -rf /var/cache/dnf/* /var/lib/dnf/history* /var/log/dnf*

# ------------------------------------------------------------------------------
# Stage 2: Headless Local-AI Appliance (Default Target)
# ------------------------------------------------------------------------------
FROM base-os AS ai-headless

LABEL org.opencontainers.image.title="Fedora AI OS (Headless Appliance)" \
      org.opencontainers.image.description="Ultra-lightweight local-AI appliance with RamaLama and sandboxed llama-server"

# 1. Install RamaLama and inference toolchains
RUN set -eux; \
    dnf install -y ramalama || true; \
    dnf clean all; \
    rm -rf /var/cache/dnf/*

# 2. Provision unprivileged service accounts with render/video acceleration permissions
RUN set -eux; \
    # llama-server service account
    useradd -r -s /sbin/nologin -d /var/lib/models -M -G render,video llamasrv; \
    # linux-mcp-server telemetry service account
    useradd -r -s /sbin/nologin -d /run/mcp -M -G systemd-journal mcpsrv; \
    # Prepare persistent state directories (preserved across bootc image updates)
    mkdir -p /var/lib/models /var/lib/ramalama /etc/llama-server /usr/libexec/linux-mcp-server /run/mcp; \
    chown -R llamasrv:llamasrv /var/lib/models; \
    chmod 0775 /var/lib/models; \
    chown -R mcpsrv:mcpsrv /run/mcp

# 3. Install Diagnostic Linux MCP Server
COPY mcp/linux_mcp_server.py /usr/libexec/linux-mcp-server/linux_mcp_server.py
RUN chmod 0755 /usr/libexec/linux-mcp-server/linux_mcp_server.py

# 4. Install sandboxed systemd service and socket units
COPY systemd/linux-mcp-server.service /usr/lib/systemd/system/linux-mcp-server.service
COPY systemd/linux-mcp-server.socket /usr/lib/systemd/system/linux-mcp-server.socket
COPY systemd/llama-server.service /usr/lib/systemd/system/llama-server.service
COPY systemd/llama-server.env /etc/llama-server/llama-server.env

# 5. Enable system services
RUN set -eux; \
    systemctl enable linux-mcp-server.socket; \
    systemctl enable llama-server.service

# ------------------------------------------------------------------------------
# Stage 3: Lightweight Wayland GUI Profile (Optional Target)
# ------------------------------------------------------------------------------
FROM ai-headless AS ai-gui

LABEL org.opencontainers.image.title="Fedora AI OS (Wayland Kiosk)" \
      org.opencontainers.image.description="Lightweight Wayland kiosk appliance with labwc and PipeWire audio filter-chain"

# 1. Install labwc, foot terminal, and PipeWire audio filter-chain packages
RUN set -eux; \
    dnf install -y \
        labwc \
        foot \
        seatd \
        pipewire \
        wireplumber \
        pipewire-plugin-filter-chain || true; \
    dnf clean all; \
    rm -rf /var/cache/dnf/*

# 2. Configure PipeWire DeepFilter offline noise suppression
COPY audio/99-deepfilter-pipewire.conf /etc/pipewire/pipewire.conf.d/99-deepfilter-pipewire.conf

# 3. Configure labwc autostart
COPY wayland/labwc-autostart /etc/xdg/labwc/autostart
RUN chmod 0755 /etc/xdg/labwc/autostart
