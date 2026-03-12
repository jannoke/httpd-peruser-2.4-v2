#!/bin/bash
# Interactive local development build loop for httpd peruser patch debugging.
#
# Usage (run from the repository root or from src/):
#   ./src/dev-build-loop.sh
#
# Workflow:
#   1. Builds (or reuses) a Rocky Linux 9 development container.
#   2. Mounts the src/ directory into the container as /src.
#   3. Runs rpmbuild in a loop.
#      - On failure: shows the error output and waits for you to fix the patch.
#      - On success: copies build artifacts to src/output/ and exits.
#   4. Once it builds cleanly, commit and push to trigger the full CI workflow.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Resolve the src/ directory regardless of where the script is called from
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="httpd-peruser-devbuild"
CONTAINER_NAME="httpd-peruser-dev"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo -e "${BLUE}${BOLD}============================================${NC}"
echo -e "${BLUE}${BOLD}  httpd peruser - Local Dev Build Loop      ${NC}"
echo -e "${BLUE}${BOLD}============================================${NC}"
echo -e "Source directory : ${SCRIPT_DIR}"
echo -e "Patch file       : ${SCRIPT_DIR}/peruser-2.4-httpd24-fix.patch"
echo ""

# ---------------------------------------------------------------------------
# Prerequisite: Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo -e "${RED}ERROR: Docker is not installed or not in PATH.${NC}"
    echo "Please install Docker and try again."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build (or rebuild) the development container image
# ---------------------------------------------------------------------------
echo -e "${YELLOW}Building development container image (${IMAGE_NAME})...${NC}"
docker build -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile.devbuild" "${SCRIPT_DIR}"
echo -e "${GREEN}Container image ready.${NC}"
echo ""

# ---------------------------------------------------------------------------
# Remove any leftover container from a previous run
# ---------------------------------------------------------------------------
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Start the container with src/ mounted read-only at /src
# ---------------------------------------------------------------------------
echo -e "${YELLOW}Starting development container...${NC}"
docker run -d \
    --name "${CONTAINER_NAME}" \
    -v "${SCRIPT_DIR}:/src:ro" \
    "${IMAGE_NAME}" > /dev/null
echo -e "${GREEN}Container '${CONTAINER_NAME}' is running.${NC}"
echo ""

# ---------------------------------------------------------------------------
# Ensure the container is stopped/removed when this script exits
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up container '${CONTAINER_NAME}'...${NC}"
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    echo -e "${GREEN}Done.${NC}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build loop
# ---------------------------------------------------------------------------
attempt=0
while true; do
    attempt=$(( attempt + 1 ))

    echo -e "${BLUE}${BOLD}--------------------------------------------${NC}"
    echo -e "${BLUE}${BOLD}  Build attempt #${attempt}${NC}"
    echo -e "${BLUE}${BOLD}--------------------------------------------${NC}"

    # Run the inner build script; allow failure without exiting this script
    if docker exec "${CONTAINER_NAME}" bash /src/build-rpm-dev.sh; then

        echo ""
        echo -e "${GREEN}${BOLD}============================================${NC}"
        echo -e "${GREEN}${BOLD}  BUILD SUCCEEDED on attempt #${attempt}${NC}"
        echo -e "${GREEN}${BOLD}============================================${NC}"
        echo ""

        # Copy RPM and SRPM artifacts to src/output/
        mkdir -p "${OUTPUT_DIR}/RPMS" "${OUTPUT_DIR}/SRPMS"
        docker cp "${CONTAINER_NAME}:/root/rpmbuild/RPMS/."  "${OUTPUT_DIR}/RPMS/"  2>/dev/null || true
        docker cp "${CONTAINER_NAME}:/root/rpmbuild/SRPMS/." "${OUTPUT_DIR}/SRPMS/" 2>/dev/null || true

        echo -e "Build artifacts saved to: ${OUTPUT_DIR}"
        echo ""
        find "${OUTPUT_DIR}" -name "*.rpm" | sort | while read -r f; do
            echo -e "  ${GREEN}${f}${NC}"
        done
        echo ""
        echo -e "${BOLD}Next step:${NC} commit and push to trigger the full GitHub Actions workflow."
        break

    else
        echo ""
        echo -e "${RED}${BOLD}============================================${NC}"
        echo -e "${RED}${BOLD}  BUILD FAILED (attempt #${attempt})${NC}"
        echo -e "${RED}${BOLD}============================================${NC}"
        echo ""
        echo -e "${YELLOW}Edit the patch file to fix the error, then press Enter to retry.${NC}"
        echo -e "  Patch file: ${BLUE}${SCRIPT_DIR}/peruser-2.4-httpd24-fix.patch${NC}"
        echo ""
        # Wait for the developer to fix the patch
        read -r -p "Press Enter to retry (or Ctrl+C to exit)... "
        echo ""
    fi
done
