#!/bin/bash
# Non-interactive build script designed for use by the Copilot coding agent.
#
# Usage (run from the repository root or from src/):
#   ./src/agent-build-loop.sh
#
# Exit codes:
#   0  - Build succeeded
#   1  - Build failed (see output for details)
#
# Output markers the agent should look for:
#   === BUILD SUCCEEDED ===   Build completed without errors
#   === BUILD FAILED ===      Build failed; error details follow
#   === PATCH ERROR ===       The patch failed to apply
#   === COMPILE ERROR ===     The code compiled but with errors
#
# The agent workflow:
#   1. Run this script
#   2. If exit code != 0, read the output to find errors
#   3. Fix src/peruser-2.4-httpd24-fix.patch
#   4. Run this script again
#   5. Repeat until exit code is 0

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the src/ directory regardless of where the script is called from
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="httpd-peruser-devbuild"
CONTAINER_NAME="httpd-peruser-agent-build"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo "=== AGENT BUILD LOOP START ==="
echo "Source directory : ${SCRIPT_DIR}"
echo "Patch file       : ${SCRIPT_DIR}/peruser-2.4-httpd24-fix.patch"
echo ""

# ---------------------------------------------------------------------------
# Prerequisite: Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo "=== BUILD FAILED ==="
    echo "ERROR: Docker is not installed or not in PATH."
    echo "Install Docker and try again."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the development container image (uses cache if unchanged)
# ---------------------------------------------------------------------------
echo "--- Building container image (${IMAGE_NAME}) ---"
if ! docker build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile.devbuild" "${SCRIPT_DIR}" 2>&1; then
    echo ""
    echo "=== BUILD FAILED ==="
    echo "ERROR: Failed to build Docker image. Check Dockerfile.devbuild for errors."
    exit 1
fi
echo "--- Container image ready ---"
echo ""

# ---------------------------------------------------------------------------
# Remove any leftover container from a previous agent run
# ---------------------------------------------------------------------------
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Cleanup on exit (success or failure)
# ---------------------------------------------------------------------------
cleanup() {
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Start the container with src/ mounted read-only at /src
# ---------------------------------------------------------------------------
echo "--- Starting build container ---"
docker run -d \
    --name "${CONTAINER_NAME}" \
    -v "${SCRIPT_DIR}:/src:ro" \
    "${IMAGE_NAME}" > /dev/null
echo "--- Container '${CONTAINER_NAME}' started ---"
echo ""

# ---------------------------------------------------------------------------
# Run the build (non-interactive, single attempt)
# ---------------------------------------------------------------------------
echo "--- Running RPM build ---"
echo ""

# Verify the in-container build script is present in src/ before running
if [ ! -f "${SCRIPT_DIR}/build-rpm-dev.sh" ]; then
    echo "=== BUILD FAILED ==="
    echo "ERROR: src/build-rpm-dev.sh not found at ${SCRIPT_DIR}/build-rpm-dev.sh"
    exit 1
fi

# Capture build output and stream it live at the same time
BUILD_LOG=$(mktemp /tmp/agent-build-XXXXXX.log)
trap 'rm -f "${BUILD_LOG}"; docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true' EXIT

if docker exec "${CONTAINER_NAME}" bash /src/build-rpm-dev.sh 2>&1 | tee "${BUILD_LOG}"; then
    BUILD_EXIT=0
else
    BUILD_EXIT=1
fi

echo ""

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
if [ "${BUILD_EXIT}" -eq 0 ]; then
    # Copy build artifacts
    mkdir -p "${OUTPUT_DIR}/RPMS" "${OUTPUT_DIR}/SRPMS"
    docker cp "${CONTAINER_NAME}:/root/rpmbuild/RPMS/."  "${OUTPUT_DIR}/RPMS/"  2>/dev/null || true
    docker cp "${CONTAINER_NAME}:/root/rpmbuild/SRPMS/." "${OUTPUT_DIR}/SRPMS/" 2>/dev/null || true

    echo "=== BUILD SUCCEEDED ==="
    echo "Build artifacts saved to: ${OUTPUT_DIR}"
    echo ""
    find "${OUTPUT_DIR}" -name "*.rpm" | sort | while read -r f; do
        echo "  RPM: ${f}"
    done
    exit 0
else
    echo "=== BUILD FAILED ==="
    echo ""
    # Pattern that matches patch application failures
    PATCH_PATTERN="patch: \*\*\*\|Hunk #\|FAILED -- saving\|can't find file\|patching file"
    # Highlight patch errors specifically
    if grep -q "${PATCH_PATTERN}" "${BUILD_LOG}" 2>/dev/null; then
        echo "=== PATCH ERROR ==="
        echo "The patch failed to apply. Relevant lines:"
        grep -n "${PATCH_PATTERN}\|offset\|fuzz" "${BUILD_LOG}" 2>/dev/null || true
        echo ""
        echo "HOW TO FIX:"
        echo "  1. Look at which hunk(s) failed above."
        echo "  2. Edit src/peruser-2.4-httpd24-fix.patch to correct the context lines."
        echo "  3. Run this script again."
    fi
    # Highlight compiler errors
    if grep -qE "error:|warning:|undefined reference|implicit declaration" "${BUILD_LOG}" 2>/dev/null; then
        echo "=== COMPILE ERROR ==="
        echo "Compilation errors found. Relevant lines:"
        grep -nE "error:|warning: implicit|undefined reference" "${BUILD_LOG}" 2>/dev/null | head -50 || true
        echo ""
        echo "HOW TO FIX:"
        echo "  1. Look at the error lines above."
        echo "  2. Edit src/peruser-2.4-httpd24-fix.patch to fix the C code."
        echo "  3. Run this script again."
    fi
    echo ""
    echo "Full build log is above. Fix src/peruser-2.4-httpd24-fix.patch and re-run this script."
    exit 1
fi
