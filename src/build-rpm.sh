#!/bin/bash
# Script to build the httpd peruser RPM using Docker
# Run this from the src/ directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="httpd-peruser-rpmbuild"
CONTAINER_NAME="httpd-peruser-build"

echo "=== Building httpd peruser RPM ==="
echo "Build context: $SCRIPT_DIR"

# Build the Docker image
echo "Building Docker image..."
docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.rpmbuild" "$SCRIPT_DIR"

# Run the build
echo "Running RPM build..."
docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$SCRIPT_DIR/output:/root/rpmbuild/RPMS" \
    "$IMAGE_NAME"

echo "=== Build complete ==="
echo "RPMs are in: $SCRIPT_DIR/output/"
ls -la "$SCRIPT_DIR/output/" 2>/dev/null || echo "Note: mount output directory to collect RPMs"
