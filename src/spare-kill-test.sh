#!/bin/bash
# Regression test: MaxSpareProcessors must never stop a busy worker.
#
# Up to .5.peruser.dc the "too many spare workers" rule in
# determine_child_fate() stopped any worker copy of a Processor once the
# Processor had MaxSpareProcessors idle copies, busy or not, and since only an
# idle copy is taken off the idle count, one pass stopped every busy copy. The
# client got a 502 or a cut response, and a copy holding a mod_proxy
# connection aborted in its exit cleanup (a core dump each). That's what hit a
# tenant on a live dataserver on 2026-11-06, with php-fpm behind mod_proxy_fcgi.
#
# The test, in a throwaway Rocky container like local-smoke-test.sh:
#   - one Processor with MinSpareProcessors 2 / MaxSpareProcessors 2, so its
#     clones trip the rule as soon as requests come in;
#   - a backend on 127.0.0.1:9000 (python) that answers after SLOW_SECONDS,
#     reached through mod_proxy_http, so each request keeps a copy busy with
#     a proxy connection open, like a PHP request does;
#   - CONCURRENT such requests at once, plus a few quick ones meanwhile.
# Pass: every slow request gets its 200 and full body, no copy exits on a
# signal and there are no cores. Fail (the bug): slow requests cut with no
# response (HTTP 000), since their copies were stopped mid-request. On .5 that
# was 5 of 6 (2026-11-06). On live, a copy stopped while holding a php-fpm
# connection also aborted with a core; a copy behind mod_proxy_http here exits
# without one, so the cut requests are what shows the bug.
#
# Usage (from repo root or src/):
#   EL_VERSION=10 ./src/spare-kill-test.sh [--rpms DIR] [--concurrent N] [--slow S]
# --rpms defaults to src/output/el${EL_VERSION}/RPMS; any directory with one
# build's RPMs works (e.g. an older release's, to see the bug).
#
# Exit codes: 0 pass, 1 fail, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EL_VERSION="${EL_VERSION:-9}"
case "$EL_VERSION" in
  9)  IMAGE_NAME="rockylinux:9" ;;
  10) IMAGE_NAME="rockylinux/rockylinux:10" ;;
  *)  echo "ERROR: unsupported EL_VERSION '${EL_VERSION}' (expected 9 or 10)"; exit 2 ;;
esac
CONTAINER_NAME="httpd-peruser-spare-kill-test-el${EL_VERSION}"

if [ "${1:-}" = "--in-container" ]; then
  CONCURRENT="${CONCURRENT:-6}"
  SLOW_SECONDS="${SLOW_SECONDS:-20}"
  SIGNAL_PATTERN="exit signal"

  echo "=== spare-kill test: ${CONCURRENT} concurrent requests of ${SLOW_SECONDS}s ==="

  echo "--- Installing test dependencies ---"
  dnf install -y --setopt=install_weak_deps=False --allowerasing \
    curl gdb procps-ng python3 >/dev/null || { echo "ERROR: dnf install failed"; exit 2; }

  echo "--- Installing the httpd RPMs ---"
  RPMS=$(find /rpms -name "*.rpm" | grep -vE 'debuginfo|debugsource|\.src\.rpm|devel' | sort)
  [ -n "$RPMS" ] || { echo "ERROR: no RPMs in the --rpms directory"; exit 2; }
  printf '%s\n' $RPMS
  dnf install -y --allowerasing --setopt=install_weak_deps=False $RPMS >/dev/null \
    || { echo "ERROR: RPM install failed"; exit 2; }
  DEBUGINFO=$(find /rpms -name "httpd-*debuginfo-*.rpm" | sort)
  [ -n "$DEBUGINFO" ] && { dnf install -y $DEBUGINFO >/dev/null 2>&1 || echo "Warning: debuginfo install failed"; }
  rpm -q httpd

  echo "--- Core dumps ---"
  ulimit -c unlimited
  mkdir -p /tmp/coredumps && chmod 1777 /tmp/coredumps
  echo "/tmp/coredumps/core.%e.%p" > /proc/sys/kernel/core_pattern 2>/dev/null || true
  echo 1 > /proc/sys/fs/suid_dumpable 2>/dev/null || true

  echo "--- Backend and test user ---"
  useradd -r -m -d /home/testuser -s /sbin/nologin testuser
  mkdir -p /var/www/html
  echo "PERUSER_QUICK_OK" > /var/www/html/index.html
  chown -R testuser:testuser /var/www/html
  cat > /tmp/backend.py << 'PYEOF'
import http.server, socketserver, sys, time
SLOW = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(SLOW)
        body = b"SLOW_OK " + self.path.encode() + b"\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
S(("127.0.0.1", 9000), H).serve_forever()
PYEOF
  python3 /tmp/backend.py "$SLOW_SECONDS" 2>/tmp/backend.log &

  echo "--- httpd config ---"
  rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.modules.d/*ssl*.conf
  echo "LoadModule mpm_peruser_module modules/mod_mpm_peruser.so" > /etc/httpd/conf.modules.d/00-mpm.conf
  cat > /etc/httpd/conf.d/peruser.conf << EOF
ServerName localhost
CoreDumpDirectory /tmp/coredumps
LogLevel info

<IfModule mpm_peruser_module>
    ServerLimit          40
    MaxClients           40
    MinSpareProcessors   2
    MaxSpareProcessors   2
    MinProcessors        0
    MaxProcessors        30
    ExpireTimeout        7200
    IdleTimeout          60
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
    ProxyPass /slow/ http://127.0.0.1:9000/ timeout=$((SLOW_SECONDS + 30))
    <IfModule peruser.c>
        ServerEnvironment testuser
    </IfModule>
</VirtualHost>
EOF
  httpd -t || { echo "ERROR: httpd -t failed"; exit 2; }

  mkdir -p /run/httpd
  httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1 &
  for i in $(seq 1 15); do
    timeout 5 curl -fsS http://127.0.0.1:8080/ 2>/dev/null | grep -q PERUSER_QUICK_OK && break
    sleep 1
  done
  timeout 5 curl -fsS http://127.0.0.1:8080/ 2>/dev/null | grep -q PERUSER_QUICK_OK \
    || { echo "ERROR: httpd did not come up"; cat /var/log/httpd/error_log; exit 2; }

  echo "--- ${CONCURRENT} slow requests ---"
  SLOW_PIDS=()
  for n in $(seq 1 "$CONCURRENT"); do
    curl -s -m $((SLOW_SECONDS + 40)) -o /tmp/slow_$n.body -w "%{http_code}" \
      "http://127.0.0.1:8080/slow/$n" > /tmp/slow_$n.code 2>/dev/null &
    SLOW_PIDS+=($!)
    sleep 0.3
  done
  # Quick requests while they run, so copies are cloned, used and go idle
  QUICK_FAILED=0
  for i in $(seq 1 $((SLOW_SECONDS - 2))); do
    code=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/)
    [ "$code" = "200" ] || QUICK_FAILED=$((QUICK_FAILED + 1))
    [ $((i % 5)) -eq 0 ] && echo "  t+${i}s: $(pgrep -u testuser -x httpd | wc -l) testuser copies"
    sleep 1
  done
  wait "${SLOW_PIDS[@]}" 2>/dev/null || true
  sleep 1

  echo "--- Results ---"
  FAILED=0
  for n in $(seq 1 "$CONCURRENT"); do
    code=$(cat /tmp/slow_$n.code 2>/dev/null)
    if [ "$code" = "200" ] && grep -q "SLOW_OK /$n" /tmp/slow_$n.body 2>/dev/null; then
      echo "slow request $n: 200, complete"
    else
      echo "slow request $n: HTTP '${code:-none}', body: $(head -c 80 /tmp/slow_$n.body 2>/dev/null | tr '\n' ' ')"
      FAILED=$((FAILED + 1))
    fi
  done
  echo "quick requests that failed: ${QUICK_FAILED}"
  SIGNALS=$(grep -c "$SIGNAL_PATTERN" /var/log/httpd/error_log 2>/dev/null)
  CORES=$(find /tmp/coredumps -name 'core.*' 2>/dev/null | wc -l)
  echo "error_log lines with '${SIGNAL_PATTERN}': ${SIGNALS}"
  grep "$SIGNAL_PATTERN" /var/log/httpd/error_log 2>/dev/null | head -5
  echo "core files: ${CORES}"

  if [ "$CORES" -gt 0 ]; then
    CORE=$(find /tmp/coredumps -name 'core.*' | head -1)
    echo "=== backtrace of ${CORE} ==="
    gdb --batch -ex 'set pagination off' -ex bt /usr/sbin/httpd "$CORE" 2>&1 | grep -E '^#' | head -20
  fi

  if [ "$FAILED" -eq 0 ] && [ "$QUICK_FAILED" -eq 0 ] && [ "$SIGNALS" -eq 0 ] && [ "$CORES" -eq 0 ]; then
    echo "=== PASS: no busy copy was stopped ==="
    exit 0
  fi
  echo "=== FAIL: ${FAILED} slow request(s) cut, ${SIGNALS} copies died on a signal, ${CORES} core(s) ==="
  echo "=== error_log (last 40 lines) ==="
  tail -40 /var/log/httpd/error_log
  exit 1
fi

# ---------------------------------------------------------------------------
# Host side: run the block above in a throwaway Rocky container
# ---------------------------------------------------------------------------
RPMS_DIR="${SCRIPT_DIR}/output/el${EL_VERSION}/RPMS"
CONCURRENT=6
SLOW_SECONDS=20
while [ $# -gt 0 ]; do
  case "$1" in
    --rpms) RPMS_DIR="$2"; shift 2 ;;
    --concurrent) CONCURRENT="$2"; shift 2 ;;
    --slow) SLOW_SECONDS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
[ -d "$RPMS_DIR" ] || { echo "ERROR: $RPMS_DIR not found (build first, or pass --rpms)"; exit 2; }
RPMS_DIR="$(cd "$RPMS_DIR" && pwd)"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run --privileged --rm \
  --name "${CONTAINER_NAME}" \
  -v "${SCRIPT_DIR}:/src:ro" \
  -v "${RPMS_DIR}:/rpms:ro" \
  -e "CONCURRENT=${CONCURRENT}" \
  -e "SLOW_SECONDS=${SLOW_SECONDS}" \
  "${IMAGE_NAME}" \
  bash /src/spare-kill-test.sh --in-container
