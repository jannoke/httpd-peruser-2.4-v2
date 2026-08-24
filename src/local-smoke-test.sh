#!/bin/bash
# Local smoke-test harness for the peruser MPM RPM build.
#
# Mirrors .github/workflows/build-rpm.yml's `test-rpm` job (install RPM,
# load only mpm_peruser_module, start httpd -DFOREGROUND, curl + error_log
# checks, gdb backtrace on failure) so iteration doesn't require pushing to
# GitHub Actions each time. Adds two things CI doesn't do:
#   - repeats the whole start/request/stop cycle N times with a *fresh*
#     httpd start each time (the diagnosed bug is about ap_listeners state
#     at fork time, so a single pass under-tests it)
#   - an strace -f fallback (in addition to gdb) when a cycle fails, to see
#     the exact syscalls (fork/setuid/socket/accept) leading up to a fault
#
# Usage (run from repo root or from src/):
#   ./src/local-smoke-test.sh [--cycles N] [--multi-tenant]
#
# Requires: src/output/RPMS/**/*.rpm already built (run agent-build-loop.sh first)
#
# Exit codes:
#   0 - all cycles passed
#   1 - a cycle failed (see output for gdb/strace diagnostics)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="rockylinux:9"
CONTAINER_NAME="httpd-peruser-smoke-test"

if [ "${1:-}" = "--in-container" ]; then
  # ---------------------------------------------------------------------
  # Runs inside the Rocky Linux 9 container. Everything below this line
  # is the actual test; the host-side dispatch is at the bottom of the file.
  # ---------------------------------------------------------------------
  set -o pipefail
  CYCLES="${CYCLES:-5}"
  MULTI_TENANT="${MULTI_TENANT:-0}"
  SEGFAULT_PATTERN="exit signal.*fault\|exit signal.*abort"

  echo "=== Local peruser MPM smoke test: ${CYCLES} cycle(s), multi-tenant=${MULTI_TENANT} ==="

  echo "--- Installing test dependencies ---"
  dnf install -y --setopt=install_weak_deps=False --allowerasing \
    curl gdb strace procps-ng which >/dev/null
  dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
  dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
  dnf clean all >/dev/null

  echo "--- Installing built peruser httpd RPMs ---"
  RPMS=$(find /src/output/RPMS -name "httpd-*.rpm" | grep -vE 'debuginfo|debugsource|\.src\.rpm' | sort)
  if [ -z "$RPMS" ]; then
    echo "ERROR: no built RPMs found under /src/output/RPMS — run agent-build-loop.sh first."
    exit 1
  fi
  printf 'Installing:\n%s\n' "$RPMS"
  dnf install -y --allowerasing --setopt=install_weak_deps=False $RPMS
  DEBUGINFO_RPMS=$(find /src/output/RPMS -name "httpd-debuginfo-*.rpm" 2>/dev/null | sort)
  if [ -n "$DEBUGINFO_RPMS" ]; then
    dnf install -y --allowerasing $DEBUGINFO_RPMS || echo "Warning: debuginfo installation failed"
  fi
  dnf clean all >/dev/null

  echo "--- Enabling core dumps ---"
  ulimit -c unlimited
  mkdir -p /tmp/coredumps
  chmod 1777 /tmp/coredumps
  echo "/tmp/coredumps/core.%e.%p" > /proc/sys/kernel/core_pattern 2>/dev/null || true
  # Peruser children setuid(); the kernel clears the dumpable bit on setuid,
  # so without this no core is written regardless of ulimit -c.
  echo 1 > /proc/sys/fs/suid_dumpable 2>/dev/null || true
  echo "core_pattern: $(cat /proc/sys/kernel/core_pattern)"
  echo "suid_dumpable: $(cat /proc/sys/fs/suid_dumpable 2>/dev/null || echo unknown)"

  echo "--- Creating test user(s) and web root ---"
  useradd -r -m -d /home/testuser -s /sbin/nologin testuser
  mkdir -p /var/www/html
  cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><body><p>Test ID: PERUSER_TEST_12345</p></body></html>
HTMLEOF
  chown testuser:testuser /var/www/html/index.html
  chmod 644 /var/www/html/index.html

  if [ "$MULTI_TENANT" = "1" ]; then
    useradd -r -m -d /home/testuser2 -s /sbin/nologin testuser2
    mkdir -p /var/www/html2
    cat > /var/www/html2/index.html << 'HTMLEOF'
<!DOCTYPE html><html><body><p>Test ID: PERUSER_TEST_67890</p></body></html>
HTMLEOF
    chown testuser2:testuser2 /var/www/html2/index.html
    chmod 644 /var/www/html2/index.html
  fi

  echo "--- Writing httpd config ---"
  rm -f /etc/httpd/conf.d/ssl.conf
  rm -f /etc/httpd/conf.modules.d/*ssl*.conf

  cat > /etc/httpd/conf.modules.d/00-mpm.conf << 'EOF'
LoadModule mpm_peruser_module modules/mod_mpm_peruser.so
EOF

  {
    cat << 'EOF'
ServerName localhost
CoreDumpDirectory /tmp/coredumps

<IfModule mpm_peruser_module>
    ServerLimit          10
    MinSpareProcessors   1
    MaxSpareProcessors   1
    MaxClients           10
    ExpireTimeout        5
    IdleTimeout          300
</IfModule>

Processor testuser testuser

<Processor testuser>
    User testuser
    Group testuser
</Processor>

Listen 8080

<VirtualHost *:8080>
    ServerName localhost
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Require all granted
    </Directory>

    <IfModule peruser.c>
        ServerEnvironment testuser
    </IfModule>
</VirtualHost>
EOF

    if [ "$MULTI_TENANT" = "1" ]; then
      cat << 'EOF'

Processor testuser2 testuser2

<Processor testuser2>
    User testuser2
    Group testuser2
</Processor>

Listen 8081

<VirtualHost *:8081>
    ServerName localhost2
    DocumentRoot /var/www/html2

    <Directory /var/www/html2>
        Require all granted
    </Directory>

    <IfModule peruser.c>
        ServerEnvironment testuser2
    </IfModule>
</VirtualHost>
EOF
    fi
  } > /etc/httpd/conf.d/peruser.conf

  echo "=== peruser.conf ==="
  cat /etc/httpd/conf.d/peruser.conf

  echo "--- Syntax check ---"
  httpd -t || { echo "ERROR: httpd -t failed"; exit 1; }
  httpd -M

  analyze_failure() {
    local reason="$1"
    echo ""
    echo "############################################################"
    echo "# FAILURE: ${reason}"
    echo "############################################################"
    echo "=== httpd error log ==="
    cat /var/log/httpd/error_log 2>/dev/null || echo "(no error log)"

    HTTPD_BIN=$(which httpd 2>/dev/null || echo /usr/sbin/httpd)
    CORES=$(find /tmp/coredumps /tmp \( -name "core.*" -o -name "core" \) 2>/dev/null | head -n 2)
    if [ -n "$CORES" ]; then
      echo "=== gdb backtrace(s) ==="
      cat > /tmp/gdb-commands.txt << 'GDBEOF'
set pagination off
bt full
info threads
thread apply all bt full
GDBEOF
      while IFS= read -r CORE; do
        echo "--- core: $CORE ---"
        gdb --batch -x /tmp/gdb-commands.txt "$HTTPD_BIN" "$CORE" 2>&1
      done <<< "$CORES"
    else
      echo "No core file found (core_pattern: $(cat /proc/sys/kernel/core_pattern))"
    fi

    if [ -f /tmp/strace-cycle.log ]; then
      echo "=== last 200 lines of strace (fork/setuid/socket/accept trail) ==="
      tail -200 /tmp/strace-cycle.log
    fi
  }

  overall_status=0

  for cycle in $(seq 1 "$CYCLES"); do
    echo ""
    echo "======================== Cycle ${cycle}/${CYCLES} ========================"

    rm -f /run/httpd/httpd.pid /tmp/httpd-foreground.pid /tmp/strace-cycle.log
    mkdir -p /run/httpd
    : > /var/log/httpd/error_log 2>/dev/null || true

    # Every 3rd cycle (and always on a re-run after a prior failure), start
    # under strace -f so a fork/setuid/socket trail is available without
    # having to reproduce the crash a second time.
    if [ $(( cycle % 3 )) -eq 0 ]; then
      strace -f -tt -o /tmp/strace-cycle.log -- httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1 &
    else
      httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1 &
    fi
    HTTPD_LAUNCHER_PID=$!
    echo "$HTTPD_LAUNCHER_PID" > /tmp/httpd-foreground.pid

    STARTED=0
    for i in $(seq 1 10); do
      if pgrep -x httpd > /dev/null; then
        if timeout 5 curl -fsS -I http://127.0.0.1:8080/ > /dev/null 2>&1; then
          STARTED=1
          break
        fi
      fi
      sleep 1
    done

    if [ "$STARTED" -ne 1 ]; then
      analyze_failure "cycle ${cycle}: httpd did not become ready"
      overall_status=1
      break
    fi

    CYCLE_FAILED=0
    for i in 1 2 3; do
      if grep -qi "$SEGFAULT_PATTERN" /var/log/httpd/error_log 2>/dev/null; then
        CYCLE_FAILED=1
        break
      fi
      HTTP_CODE=$(timeout 5 curl -s -o /tmp/response_${cycle}_${i}.html -w "%{http_code}" http://localhost:8080/)
      if [ "$HTTP_CODE" != "200" ] || ! grep -q "PERUSER_TEST_12345" /tmp/response_${cycle}_${i}.html; then
        echo "cycle ${cycle} request ${i}: HTTP ${HTTP_CODE}, body:"
        cat /tmp/response_${cycle}_${i}.html 2>/dev/null
        CYCLE_FAILED=1
        break
      fi
      if [ "$MULTI_TENANT" = "1" ]; then
        HTTP_CODE2=$(timeout 5 curl -s -o /tmp/response2_${cycle}_${i}.html -w "%{http_code}" http://localhost:8081/)
        if [ "$HTTP_CODE2" != "200" ] || ! grep -q "PERUSER_TEST_67890" /tmp/response2_${cycle}_${i}.html; then
          echo "cycle ${cycle} tenant2 request ${i}: HTTP ${HTTP_CODE2}, body:"
          cat /tmp/response2_${cycle}_${i}.html 2>/dev/null
          CYCLE_FAILED=1
          break
        fi
      fi
      sleep 0.5
    done

    if [ "$CYCLE_FAILED" -eq 0 ] && grep -qi "$SEGFAULT_PATTERN" /var/log/httpd/error_log 2>/dev/null; then
      CYCLE_FAILED=1
    fi

    if [ "$CYCLE_FAILED" -eq 0 ]; then
      TESTUSER_PROCS=$(pgrep -u testuser -x httpd 2>/dev/null | wc -l)
      if [ "$TESTUSER_PROCS" -eq 0 ]; then
        echo "cycle ${cycle}: no httpd workers running as testuser — isolation not happening"
        CYCLE_FAILED=1
      fi
      if [ "$MULTI_TENANT" = "1" ]; then
        TESTUSER2_PROCS=$(pgrep -u testuser2 -x httpd 2>/dev/null | wc -l)
        if [ "$TESTUSER2_PROCS" -eq 0 ]; then
          echo "cycle ${cycle}: no httpd workers running as testuser2 — isolation not happening"
          CYCLE_FAILED=1
        fi
      fi
    fi

    if [ "$CYCLE_FAILED" -ne 0 ]; then
      analyze_failure "cycle ${cycle}: request/crash/isolation check failed"
      overall_status=1
    else
      echo "cycle ${cycle}: OK (HTTP 200 x3$( [ "$MULTI_TENANT" = "1" ] && echo ", both tenants" ), correct-uid workers, no crash pattern)"
    fi

    # Fresh stop before the next cycle's fresh start.
    kill "$(cat /tmp/httpd-foreground.pid)" 2>/dev/null || true
    pkill -x httpd 2>/dev/null || true
    sleep 1
    pgrep -x httpd 2>/dev/null && pkill -9 -x httpd 2>/dev/null || true
    sleep 1

    [ "$overall_status" -ne 0 ] && break
  done

  if [ "$overall_status" -eq 0 ]; then
    echo ""
    echo "=== ALL ${CYCLES} CYCLES PASSED ==="
  fi
  exit "$overall_status"
fi

# ---------------------------------------------------------------------------
# Host-side dispatch: run the block above inside a throwaway Rocky 9 container
# ---------------------------------------------------------------------------
CYCLES=5
MULTI_TENANT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cycles) CYCLES="$2"; shift 2 ;;
    --multi-tenant) MULTI_TENANT=1; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is not installed or not in PATH."
  exit 1
fi

if [ ! -d "${SCRIPT_DIR}/output/RPMS" ]; then
  echo "ERROR: ${SCRIPT_DIR}/output/RPMS not found — run agent-build-loop.sh first."
  exit 1
fi

docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

docker run --privileged --rm \
  --name "${CONTAINER_NAME}" \
  -v "${SCRIPT_DIR}:/src:ro" \
  -e "CYCLES=${CYCLES}" \
  -e "MULTI_TENANT=${MULTI_TENANT}" \
  "${IMAGE_NAME}" \
  bash /src/local-smoke-test.sh --in-container
