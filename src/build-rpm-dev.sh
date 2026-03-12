#!/bin/bash
# Script that runs INSIDE the development container to build the RPM.
# Called by dev-build-loop.sh via: bash /src/build-rpm-dev.sh
#
# Expects:
#   /src  - mounted src/ directory from the host (read-only)
#   /root/rpmbuild - standard rpmbuild tree (set up by Dockerfile.devbuild)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RPMBUILD_DIR="/root/rpmbuild"
SRC_DIR="/src"

# Safety guard: verify RPMBUILD_DIR is the expected path before any deletion
if [ "${RPMBUILD_DIR}" != "/root/rpmbuild" ]; then
    echo -e "${RED}ERROR: unexpected RPMBUILD_DIR '${RPMBUILD_DIR}' — aborting to prevent accidental deletion${NC}"
    exit 1
fi

echo -e "${YELLOW}--- Preparing build environment ---${NC}"

# Clear previous build state so a fresh copy of the edited files is used
rm -rf "${RPMBUILD_DIR}/SOURCES/"* "${RPMBUILD_DIR}/SPECS/"*

# Copy all source files from the mounted src/ directory
echo "Copying source files from ${SRC_DIR} ..."
cp -r "${SRC_DIR}/." "${RPMBUILD_DIR}/SOURCES/"

# Move the spec file into the SPECS directory as expected by rpmbuild
if [ ! -f "${RPMBUILD_DIR}/SOURCES/httpd.spec" ]; then
    echo -e "${RED}ERROR: httpd.spec not found in ${SRC_DIR}${NC}"
    exit 1
fi
mv "${RPMBUILD_DIR}/SOURCES/httpd.spec" "${RPMBUILD_DIR}/SPECS/httpd.spec"

# Import GPG keys for source tarball verification (failure is non-fatal)
gpg --import "${RPMBUILD_DIR}/SOURCES/KEYS" 2>/dev/null || true

echo -e "${YELLOW}--- Running rpmbuild -ba ---${NC}"
echo ""

# Run the full RPM build; output streams directly to the terminal so errors
# are immediately visible to the developer
rpmbuild -ba "${RPMBUILD_DIR}/SPECS/httpd.spec"

echo ""
echo -e "${GREEN}--- rpmbuild finished successfully ---${NC}"
