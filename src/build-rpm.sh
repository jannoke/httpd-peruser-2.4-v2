#!/bin/bash
# Script to build the httpd peruser RPM using Docker
# Run this from the src/ directory
#
# Usage:
#   ./build-rpm.sh              # el9 (default)
#   EL_VERSION=10 ./build-rpm.sh  # el10

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EL_VERSION="${EL_VERSION:-9}"

case "$EL_VERSION" in
    9)
        BASE_IMAGE="almalinux:9"
        ;;
    10)
        BASE_IMAGE="almalinux:10"
        ;;
    *)
        echo "ERROR: unsupported EL_VERSION '$EL_VERSION' (expected 9 or 10)" >&2
        exit 1
        ;;
esac

IMAGE_NAME="httpd-peruser-rpmbuild-el${EL_VERSION}"
CONTAINER_NAME="httpd-peruser-build-el${EL_VERSION}"
OUTPUT_DIR="$SCRIPT_DIR/output/el${EL_VERSION}"

echo "=== Building httpd peruser RPM (EL${EL_VERSION}, base image: ${BASE_IMAGE}) ==="
echo "Build context: $SCRIPT_DIR"

mkdir -p "$OUTPUT_DIR"

# Build the Docker image
echo "Building Docker image..."
docker build --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.rpmbuild" "$SCRIPT_DIR"

# Run the build
echo "Running RPM build..."
docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$OUTPUT_DIR:/root/rpmbuild/RPMS" \
    "$IMAGE_NAME"

echo "=== Build complete ==="
echo "RPMs are in: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR/" 2>/dev/null || echo "Note: mount output directory to collect RPMs"
