#!/bin/bash
# httpd peruser development environment — build Apache from a patched source
# tree without going through rpmbuild.
#
#   devenv/devenv.sh prep            unpack the tarball, apply every patch in
#                                    the order src/httpd.spec %prep applies them
#                                    (one git commit per patch)
#   devenv/devenv.sh build           configure (when needed) + make
#   devenv/devenv.sh install         build + make install into work/elN/install
#   devenv/devenv.sh run             start the installed httpd (peruser) on host
#                                    port 18080 (DEVENV_PORT overrides)
#   devenv/devenv.sh save <patch>    fold your source edits back into <patch>
#                                    and rewrite src/<patch>
#   devenv/devenv.sh export <patch>  rewrite src/<patch> from its commit
#   devenv/devenv.sh series          list the patch series (patch -> commit)
#   devenv/devenv.sh shell [--root]  shell inside the build container
#   devenv/devenv.sh clean           remove the build + install trees
#   devenv/devenv.sh reset --force   remove the whole work/elN tree (incl. edits)
#
# EL_VERSION=9 (default) or 10 selects the Rocky Linux container; each EL
# version gets its own tree under devenv/work/elN/:
#   source/   git tree you edit (upstream + patches, one commit each)
#   build/    rsync'd copy where autoconf/configure/make run (never edit)
#   install/  `make install` prefix
#
# Commands re-exec themselves inside the container automatically. Set
# DEVENV_NATIVE=1 to run on the host instead (needs the build deps + rpmspec).
# DEVENV_CFLAGS=debug (default: -O0 -g3) or rpm (the distro %optflags).

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${YELLOW}==> $*${NC}" >&2; }
ok()   { echo "${GREEN}==> $*${NC}" >&2; }
die()  { echo "${RED}ERROR: $*${NC}" >&2; exit 1; }

DEVENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$DEVENV_DIR")"
SRC_DIR="$REPO_DIR/src"
SPEC="$SRC_DIR/httpd.spec"

EL_VERSION="${EL_VERSION:-9}"
case "$EL_VERSION" in
    9)  BASE_IMAGE="rockylinux:9" ;;
    10) BASE_IMAGE="rockylinux/rockylinux:10" ;;
    *)  die "unsupported EL_VERSION '$EL_VERSION' (expected 9 or 10)" ;;
esac
IMAGE="httpd-peruser-devenv-el${EL_VERSION}"

WORK="$DEVENV_DIR/work/el${EL_VERSION}"
TREE="$WORK/source"
BUILD="$WORK/build"
PREFIX="$WORK/install"
CFLAGS_MODE="${DEVENV_CFLAGS:-debug}"
HOST_PORT="${DEVENV_PORT:-18080}"   # host port published for `run` / `shell --root`

HTTPD_VERSION="$(awk '/^Version:/ {print $2; exit}' "$SPEC")"
TARBALL="$SRC_DIR/httpd-${HTTPD_VERSION}.tar.bz2"

# ---------------------------------------------------------------------------
# Container dispatch
# ---------------------------------------------------------------------------
in_container() { [[ -f /.httpd-devenv ]]; }

ensure_image() {
    command -v docker >/dev/null || die "docker not found (or set DEVENV_NATIVE=1)"
    local want have
    want="$(sha256sum "$DEVENV_DIR/Dockerfile" | cut -c1-16)-${BASE_IMAGE}"
    have="$(docker image inspect -f '{{index .Config.Labels "devenv.sha"}}' "$IMAGE" 2>/dev/null || true)"
    if [[ "$want" != "$have" ]]; then
        info "Building container image $IMAGE (first run takes a few minutes)"
        docker build --build-arg BASE_IMAGE="$BASE_IMAGE" --label "devenv.sha=$want" \
            -t "$IMAGE" -f "$DEVENV_DIR/Dockerfile" "$DEVENV_DIR" >&2
    fi
}

# run_in_container <root|user> [docker args...] -- <command...>
run_in_container() {
    local as="$1"; shift
    local -a dargs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do dargs+=("$1"); shift; done
    shift
    ensure_image
    local wd="$REPO_DIR"
    [[ "$PWD" == "$REPO_DIR"* ]] && wd="$PWD"
    local -a tty=()
    [[ -t 0 && -t 1 ]] && tty=(-it)
    local -a user=()
    # Build as the invoking user so everything under work/ stays yours.
    [[ "$as" == user ]] && user=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
    # The repo is mounted at the same absolute path, so paths printed inside
    # the container (compiler errors, gdb) are valid on the host as well.
    exec docker run --rm "${tty[@]}" "${user[@]}" \
        -v "$REPO_DIR:$REPO_DIR:z" -w "$wd" \
        -e EL_VERSION="$EL_VERSION" -e DEVENV_CFLAGS="$CFLAGS_MODE" \
        "${dargs[@]}" "$IMAGE" "$@"
}

# ---------------------------------------------------------------------------
# Spec parsing
# ---------------------------------------------------------------------------

# Emit "num<TAB>strip<TAB>file" for every %patchN line in %prep, in order.
patch_series() {
    awk '
        /^Patch[0-9]+:/ { n = $1; sub(/^Patch/, "", n); sub(/:$/, "", n); file[n] = $2; next }
        /^%prep/        { inprep = 1; next }
        inprep && /^%build/ { exit }
        inprep && /^%(if|autopatch|autosetup|patch -P|patch [0-9])/ {
            print "UNSUPPORTED\t" $0; next
        }
        inprep && /^%patch[0-9]+/ {
            n = $1; sub(/^%patch/, "", n); p = "0"
            for (i = 2; i <= NF; i++) if ($i ~ /^-p[0-9]+$/) p = substr($i, 3)
            if (!(n in file)) { print "UNSUPPORTED\tno Patch" n ": tag"; next }
            print n "\t" p "\t" file[n]
        }
    ' "$SPEC"
}

# The ./configure options from %build, with the RPM filesystem layout options
# dropped (we install into $PREFIX with the default Apache layout instead).
configure_options() {
    command -v rpmspec >/dev/null || die "rpmspec not found (install rpm-build)"
    # Keyed on the (single) "./configure \" block, not on the %build header:
    # rpm >= 4.19 (EL10) omits section headers from `rpmspec -P` output.
    rpmspec -P "$SPEC" 2>/dev/null | awk '
        /^\.\/configure/ { inconf = 1 }
        inconf {
            line = $0; cont = sub(/\\[[:space:]]*$/, "", line)
            n = split(line, w, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (w[i] ~ /^--/) print w[i]
            if (!cont) exit
        }
    ' | grep -vE '^--(prefix|exec-prefix|bindir|sbindir|mandir|libdir|sysconfdir|includedir|libexecdir|datadir|enable-layout|with-installbuilddir|with-suexec-bin)(=|$)'
}

# Find the commit in the source tree that applied <patch> (file name or a
# unique substring of it). Prints "sha<TAB>strip<TAB>file".
find_patch_commit() {
    local q="$1" matches
    matches="$(git -C "$TREE" log --reverse --format='%H%x09%s' upstream..HEAD |
        awk -F'\t' -v q="$q" '
            $2 ~ /^Patch[0-9]+: / {
                split($2, a, " "); f = a[2]; s = a[3]; sub(/^-p/, "", s)
                if (index(f, q)) print $1 "\t" s "\t" f
            }')"
    [[ -n "$matches" ]] || die "no patch matching '$q' (see: devenv.sh series)"
    [[ "$(wc -l <<<"$matches")" -eq 1 ]] || die "'$q' matches several patches:"$'\n'"$(cut -f3 <<<"$matches")"
    echo "$matches"
}

need_tree() { [[ -d "$TREE/.git" ]] || die "no source tree yet — run: devenv/devenv.sh prep"; }

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_prep() {
    if [[ -e "$TREE" ]]; then
        [[ "${1:-}" == "--force" ]] || die "$TREE already exists (it may hold your edits). Use 'prep --force' to recreate it."
        info "Removing existing $WORK"
        rm -rf "$WORK"
    fi
    [[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"

    local series
    series="$(patch_series)"
    if grep -q '^UNSUPPORTED' <<<"$series"; then
        die "%prep uses constructs this script does not parse:"$'\n'"$(grep '^UNSUPPORTED' <<<"$series" | cut -f2-)"
    fi

    mkdir -p "$WORK"
    info "Unpacking $(basename "$TARBALL")"
    tar -xjf "$TARBALL" -C "$WORK"
    mv "$WORK/httpd-${HTTPD_VERSION}" "$TREE"

    cd "$TREE"
    git init -q -b main
    git config user.name "httpd devenv"
    git config user.email "devenv@localhost"
    git config core.autocrlf false
    git add -A -f
    git commit -q -m "upstream httpd-${HTTPD_VERSION}"
    git tag upstream

    local num strip file out
    while IFS=$'\t' read -r num strip file; do
        printf '  %-8s -p%s  %s\n' "Patch$num" "$strip" "$file" >&2
        # --fuzz=0 matches rpmbuild's %_default_patch_fuzz on EL.
        if ! out="$(patch -p"$strip" --fuzz=0 --no-backup-if-mismatch -i "$SRC_DIR/$file" 2>&1)"; then
            echo "$out" >&2
            die "Patch$num ($file) does not apply. The tree is left at $TREE with the rejects (*.rej) for inspection."
        fi
        git add -A -f
        git commit -q --allow-empty -m "Patch$num: $file -p$strip"
    done <<<"$series"

    # The non-patch source tweaks %prep makes (vendor string, release string,
    # no setcap during install).
    local vstring release
    vstring="$(. /etc/os-release; echo "$NAME")"
    release="$(rpmspec -q --srpm --qf '%{release}' "$SPEC" 2>/dev/null || echo dev)"
    sed -i "/^#define PLATFORM/s/Unix/${vstring}/" os/unix/os.h
    sed -i "s/@RELEASE@/${release}/" server/core.c
    sed -i '/suexec/s,setcap ,echo Skipping setcap for ,' Makefile.in
    git add -A -f
    git commit -q -m "spec %prep tweaks (vendor '${vstring}', release ${release}, no setcap)"
    git tag -f patched >/dev/null

    # Same safety check as the spec: packaged MMN must equal upstream MMN.
    local mmn vmmn
    mmn="$(awk '/^%define mmn / {print $3}' "$SPEC")"
    vmmn="$(echo MODULE_MAGIC_NUMBER_MAJOR | cpp -include include/ap_mmn.h | sed -n '/^2/p')"
    [[ "$vmmn" == "$mmn" ]] || die "upstream MMN is $vmmn, spec mmn macro is $mmn"

    ok "Source tree ready: $TREE"
    echo "   Edit files there, then: devenv/devenv.sh build" >&2
}

# Copy the source tree into the build tree. Files autoconf regenerates are
# excluded so the build tree keeps its generated copies. Prints the list of
# changed paths.
sync_build_tree() {
    mkdir -p "$BUILD"
    rsync -a --out-format='%n' \
        --exclude=/.git --exclude=/configure --exclude=/include/ap_config_auto.h.in \
        "$TREE/" "$BUILD/"
}

cmd_configure() {
    local flags_stamp="$BUILD/.devenv-configure"
    local cflags ldflags
    case "$CFLAGS_MODE" in
        debug) cflags="-O0 -g3 -Wall -fno-omit-frame-pointer"; ldflags="" ;;
        rpm)   cflags="$(rpm --eval '%{optflags}')"; ldflags="-Wl,-z,relro,-z,now" ;;
        *)     die "DEVENV_CFLAGS must be 'debug' or 'rpm'" ;;
    esac

    local -a opts
    mapfile -t opts < <(configure_options)
    [[ ${#opts[@]} -gt 0 ]] || die "could not extract ./configure options from $SPEC"
    opts=(--prefix="$PREFIX" --with-suexec-bin="$PREFIX/bin/suexec" "${opts[@]}")

    cd "$BUILD"
    rm -rf srclib/{apr,apr-util,pcre}
    info "autoheader && autoconf"
    autoheader && autoconf
    info "./configure (CFLAGS mode: $CFLAGS_MODE)"
    printf '    %s\n' "${opts[@]}" >&2
    CFLAGS="$cflags" LDFLAGS="$ldflags" LYNX_PATH=/usr/bin/links ./configure "${opts[@]}" >"$BUILD/configure.out" 2>&1 \
        || { tail -40 "$BUILD/configure.out" >&2; die "configure failed (full log: $BUILD/configure.out)"; }
    printf '%s\n' "$CFLAGS_MODE" "${opts[@]}" >"$flags_stamp"
    ok "configured (log: $BUILD/configure.out)"
}

cmd_build() {
    need_tree
    local changed
    changed="$(sync_build_tree)"

    # Re-run autoconf + configure when the build system changed, when the
    # flags changed, or on the first build.
    local reason=""
    if [[ ! -f "$BUILD/.devenv-configure" || ! -f "$BUILD/config.status" ]]; then
        reason="first build"
    elif [[ "$(head -1 "$BUILD/.devenv-configure")" != "$CFLAGS_MODE" ]]; then
        reason="CFLAGS mode changed"
    elif grep -qE '(\.m4|configure\.in|Makefile\.in|\.mk|config\.layout)$' <<<"$changed"; then
        reason="build system files changed"
    fi
    [[ -n "$reason" ]] && { info "Configuring ($reason)"; cmd_configure; }

    info "make -j$(nproc)"
    if ! make -C "$BUILD" -j"$(nproc)" "$@"; then
        echo "${RED}${BOLD}=== BUILD FAILED ===${NC}" >&2
        exit 1
    fi
    echo "${GREEN}${BOLD}=== BUILD SUCCEEDED ===${NC}" >&2
}

cmd_install() {
    cmd_build
    info "make install -> $PREFIX"
    make -C "$BUILD" install >"$BUILD/install.out" 2>&1 \
        || { tail -40 "$BUILD/install.out" >&2; die "make install failed (log: $BUILD/install.out)"; }
    ok "Installed. Binary: $PREFIX/bin/httpd  modules: $PREFIX/modules"
}

cmd_run() {
    [[ -x "$PREFIX/bin/httpd" ]] || die "nothing installed yet — run: devenv/devenv.sh install"
    [[ "$(id -u)" -eq 0 ]] || die "run needs root (peruser switches users); run it via the container"
    # Processor users for the sample config.
    for u in alpha bravo; do id "$u" >/dev/null 2>&1 || useradd -r -M -s /sbin/nologin "$u"; done
    mkdir -p /tmp/devenv-httpd/logs
    local conf="$DEVENV_DIR/conf/httpd-dev.conf"
    "$PREFIX/bin/httpd" -d "$PREFIX" -f "$conf" -C "Define DEVENV_DIR $DEVENV_DIR" -t
    ok "httpd (peruser) on http://localhost:${HOST_PORT} — try: curl -H 'Host: alpha.test' localhost:${HOST_PORT}"
    echo "   logs: /tmp/devenv-httpd/logs inside the container; Ctrl+C stops it" >&2
    exec "$PREFIX/bin/httpd" -d "$PREFIX" -f "$conf" -C "Define DEVENV_DIR $DEVENV_DIR" -DFOREGROUND "$@"
}

cmd_export() {
    need_tree
    local q="${1:-}" sha strip file
    [[ -n "$q" ]] || die "usage: devenv.sh export <patch-name>"
    IFS=$'\t' read -r sha strip file <<<"$(find_patch_commit "$q")"
    local -a prefix=()
    case "$strip" in
        1) prefix=(--src-prefix=a/ --dst-prefix=b/) ;;
        0) prefix=(--no-prefix) ;;
        *) die "$file is applied with -p$strip; only -p0/-p1 can be exported" ;;
    esac
    git -C "$TREE" diff --no-color --no-ext-diff --no-renames \
        "${prefix[@]}" "$sha^" "$sha" >"$SRC_DIR/$file.devenv-tmp"
    mv "$SRC_DIR/$file.devenv-tmp" "$SRC_DIR/$file"
    ok "Wrote src/$file (from commit ${sha:0:10})"
}

cmd_save() {
    need_tree
    local q="${1:-}" sha strip file
    [[ -n "$q" ]] || die "usage: devenv.sh save <patch-name>   (e.g. save peruser)"
    IFS=$'\t' read -r sha strip file <<<"$(find_patch_commit "$q")"
    cd "$TREE"
    git add -A
    if git diff --cached --quiet; then
        info "No uncommitted changes in the source tree; re-exporting only"
    else
        info "Folding your changes into the commit for $file"
        git diff --cached --stat >&2
        git commit -q --fixup="$sha"
        if ! GIT_SEQUENCE_EDITOR=: git rebase -q -i --autosquash upstream; then
            git rebase --abort || true
            git reset -q --soft HEAD~1
            die "your changes conflict with a later patch; they are back as uncommitted changes in $TREE"
        fi
        git tag -f patched >/dev/null
    fi
    cmd_export "$file"
    echo "   Remember to bump Release: in src/httpd.spec before building the RPM." >&2
}

cmd_series() {
    need_tree
    git -C "$TREE" log --reverse --format='%h  %s' upstream..HEAD
    local dirty
    dirty="$(git -C "$TREE" status --porcelain | wc -l)"
    [[ "$dirty" -eq 0 ]] || echo "${YELLOW}($dirty uncommitted change(s) in $TREE)${NC}"
}

cmd_clean() {
    info "Removing $BUILD and $PREFIX (source tree kept)"
    rm -rf "$BUILD" "$PREFIX"
}

cmd_reset() {
    [[ "${1:-}" == "--force" ]] || die "this deletes $WORK including uncommitted edits; pass --force"
    rm -rf "$WORK"
    ok "Removed $WORK"
}

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-help}"; shift || true

    if ! in_container && [[ "${DEVENV_NATIVE:-0}" != 1 ]]; then
        case "$cmd" in
            help|-h|--help) usage; exit 0 ;;
            shell)
                if [[ "${1:-}" == "--root" ]]; then
                    run_in_container root -p "$HOST_PORT:8080" -- bash
                fi
                run_in_container user -- bash ;;
            run)
                run_in_container root -p "$HOST_PORT:8080" -e DEVENV_PORT="$HOST_PORT" -- "$DEVENV_DIR/devenv.sh" run "$@" ;;
            *)
                run_in_container user -- "$DEVENV_DIR/devenv.sh" "$cmd" "$@" ;;
        esac
    fi

    case "$cmd" in
        prep)      cmd_prep "$@" ;;
        configure) need_tree; sync_build_tree >/dev/null; cmd_configure ;;
        build)     cmd_build "$@" ;;
        install)   cmd_install ;;
        run)       cmd_run "$@" ;;
        save)      cmd_save "$@" ;;
        export)    cmd_export "$@" ;;
        series)    cmd_series ;;
        clean)     cmd_clean ;;
        reset)     cmd_reset "$@" ;;
        shell)     exec bash ;;
        help|-h|--help) usage ;;
        *)         usage; die "unknown command '$cmd'" ;;
    esac
}

main "$@"
