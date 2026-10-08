#!/usr/bin/env bash
# ==============================================================================
# build.sh - Build and Appliance Synthesis for Fedora AI OS
# Automates Containerfile validation, podman container build, and
# bootc-image-builder generation of bootable raw/qcow2/iso disk media.
# ==============================================================================

set -euo pipefail

TARGET="headless"
FORMAT="qcow2"
TAG=""
OUTPUT_DIR="./output"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --target <headless|gui>     Select OS build profile (default: headless)
  --format <qcow2|raw|iso>    Output disk image format (default: qcow2)
  --tag <imagename>           Container image tag (default: localhost/fedora-ai-os:<target>)
  --output-dir <path>         Directory to store output disk images (default: ./output)
  --dry-run                   Validate configurations and print commands without executing
  -h, --help                  Show this help message and exit

Examples:
  $0 --target headless --format qcow2
  $0 --target gui --format iso --output-dir /var/images
  $0 --dry-run
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            echo "Use '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Validate target
case "${TARGET}" in
    headless)
        CONTAINER_TARGET="ai-headless"
        ;;
    gui)
        CONTAINER_TARGET="ai-gui"
        ;;
    *)
        echo "Error: Invalid target '${TARGET}'. Allowed values: headless, gui" >&2
        exit 1
        ;;
esac

# Validate format
case "${FORMAT}" in
    qcow2|raw|iso|ami)
        ;;
    *)
        echo "Error: Invalid format '${FORMAT}'. Allowed values: qcow2, raw, iso, ami" >&2
        exit 1
        ;;
esac

# Set default tag if not specified
if [[ -z "${TAG}" ]]; then
    TAG="localhost/fedora-ai-os:${TARGET}"
fi

# Configuration and syntax validation
echo "=== Step 1: Validating Workspace Files ==="
for file in Containerfile config.toml dnf/99-minimal.conf limits.d/99-ai-memlock.conf sysctl.d/99-ai-tuning.conf systemd/llama-server.service systemd/linux-mcp-server.service mcp/linux_mcp_server.py; do
    if [[ ! -f "${file}" ]]; then
        echo "Error: Missing required file '${file}'" >&2
        exit 1
    fi
    echo "  [OK] Found ${file}"
done

echo ""
echo "=== Step 2: Build Pipeline Configuration ==="
echo "  Build Target:     ${TARGET} (Container stage: ${CONTAINER_TARGET})"
echo "  Image Format:     ${FORMAT}"
echo "  Container Tag:    ${TAG}"
echo "  Output Directory: ${OUTPUT_DIR}"
echo ""

# Dry-run handling
if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "=== [DRY RUN] Commands to be executed ==="
    echo "1. Container Build Command:"
    echo "   podman build --target ${CONTAINER_TARGET} -t ${TAG} ."
    echo ""
    echo "2. Bootable Appliance Builder Command:"
    echo "   mkdir -p ${OUTPUT_DIR}"
    echo "   podman run --rm --privileged \\"
    echo "     -v /var/lib/containers/storage:/var/lib/containers/storage \\"
    echo "     -v \"\$(pwd)/config.toml\":/config.toml:ro \\"
    echo "     -v \"\$(realpath ${OUTPUT_DIR})\":/output \\"
    echo "     quay.io/centos-bootc/bootc-image-builder:latest \\"
    echo "     --type ${FORMAT} \\"
    echo "     --config /config.toml \\"
    echo "     --rootfs xfs \\"
    echo "     ${TAG}"
    echo ""
    echo "3. Sample QEMU Launch Command:"
    echo "   qemu-system-x86_64 -m 4G -smp 4 \\"
    echo "     -drive file=${OUTPUT_DIR}/${FORMAT}/disk.${FORMAT},format=${FORMAT} \\"
    echo "     -enable-kvm -net nic -net user,hostfwd=tcp::8080-:8080,hostfwd=tcp::2222-:22"
    echo ""
    echo "[DRY RUN] All configuration and syntax checks passed."
    exit 0
fi

# Ensure podman exists
if ! command -v podman >/dev/null 2>&1; then
    echo "Error: 'podman' is required but not installed on this host." >&2
    exit 1
fi

echo "=== Step 3: Building Bootable Container Image ==="
podman build --target "${CONTAINER_TARGET}" -t "${TAG}" .

echo ""
echo "=== Step 4: Synthesizing Bootable Appliance with bootc-image-builder ==="
mkdir -p "${OUTPUT_DIR}"
podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$(pwd)/config.toml":/config.toml:ro \
    -v "$(cd "${OUTPUT_DIR}" && pwd)":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type "${FORMAT}" \
    --config /config.toml \
    --rootfs xfs \
    "${TAG}"

echo ""
echo "=== Appliance Build Complete ==="
echo "Artifact located at: ${OUTPUT_DIR}/${FORMAT}/"
echo ""
echo "To test with QEMU/KVM:"
echo "  qemu-system-x86_64 -m 4G -smp 4 \\"
echo "    -drive file=${OUTPUT_DIR}/${FORMAT}/disk.${FORMAT},format=${FORMAT} \\"
echo "    -enable-kvm -net nic -net user,hostfwd=tcp::8080-:8080,hostfwd=tcp::2222-:22"
