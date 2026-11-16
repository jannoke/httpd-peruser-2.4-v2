# Development environment for building httpd + peruser straight from a
# patched source tree (no rpmbuild). Same base images and build
# dependencies as src/Dockerfile.devbuild, plus the tools the devenv needs
# (git for the patch series, rsync for the build tree, gdb for debugging).
#
# Built automatically by devenv/devenv.sh; el10 passes
#   --build-arg BASE_IMAGE=rockylinux/rockylinux:10
ARG BASE_IMAGE=rockylinux:9
FROM ${BASE_IMAGE}

RUN dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled crb

RUN dnf install -y \
        rpm-build \
        gcc \
        autoconf \
        libtool \
        pkgconfig \
        findutils \
        make \
        patch \
        perl-interpreter \
        systemd-devel \
        zlib-devel \
        libselinux-devel \
        lua-devel \
        brotli-devel \
        apr-devel \
        apr-util-devel \
        pcre2-devel \
        openssl-devel \
        libxml2-devel \
        git \
        rsync \
        gdb \
        procps-ng \
        which \
        bzip2 \
        tar \
    && dnf clean all

# devenv.sh checks for this file to know it is already inside the container.
RUN touch /.httpd-devenv
