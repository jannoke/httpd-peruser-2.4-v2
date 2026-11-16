#!/bin/bash
# Regression test: one processor that takes no requests must not stop the
# whole server (ProcessorPassTimeout, .7.peruser.dc).
#
# On 2026-11-16 a live dataserver stopped answering for every site. Each new
# child hung in mod_proxy's child_init (proxy_mutex), so one tenant's
# processor read nothing from its socketpair. The multiplexers kept handing
# it requests: once the socket was full, sendmsg() blocked for good, one
# multiplexer after the other, and the multiplexers are shared by all sites.
# Up to .6.peruser.dc that sendmsg() had no timeout.
#
# The test, in a throwaway Rocky container like spare-kill-test.sh:
#   - two Processors, usera (a.test) and userb (b.test), and only 2
#     multiplexers, so they run out fast;
#   - every usera httpd process is stopped with SIGSTOP: it reads nothing,
#     like the hung children, but still counts as idle;
#   - FLOOD requests to a.test (enough to fill its socket), and meanwhile a
#     b.test request every second.
# Pass: b.test keeps answering (at most the first few seconds lost, while the
# multiplexers wait out ProcessorPassTimeout once), a.test's requests get 503
# instead of hanging, the error log has the "took no request" line, and after
# SIGCONT a.test answers again. Fail (the bug): b.test stops answering.
#
# Usage (from repo root or src/):
#   EL_VERSION=10 ./src/pass-timeout-test.sh [--rpms DIR] [--flood N]
# --rpms defaults to src/output/el${EL_VERSION}/RPMS; any directory with one
# build's RPMs works (e.g. .6's, to see the bug).
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
CONTAINER_NAME="httpd-peruser-pass-timeout-test-el${EL_VERSION}"

if [ "${1:-}" = "--in-container" ]; then
  FLOOD="${FLOOD:-800}"
  PASS_TIMEOUT=5
  PROBES=30

  echo "=== pass-timeout test: ${FLOOD} requests to a stopped processor ==="

  echo "--- Installing test dependencies ---"
  dnf install -y --setopt=install_weak_deps=False --allowerasing \
    curl procps-ng findutils >/dev/null || { echo "ERROR: dnf install failed"; exit 2; }

  echo "--- Installing the httpd RPMs ---"
  RPMS=$(find /rpms -name "*.rpm" | grep -vE 'debuginfo|debugsource|\.src\.rpm|devel' | sort)
  [ -n "$RPMS" ] || { echo "ERROR: no RPMs in the --rpms directory"; exit 2; }
  dnf install -y --allowerasing --setopt=install_weak_deps=False $RPMS >/dev/null \
    || { echo "ERROR: RPM install failed"; exit 2; }
  rpm -q httpd

  echo "--- Users and sites ---"
  for u in usera userb; do
    useradd -r -m -d /home/$u -s /sbin/nologin $u
    mkdir -p /var/www/$u
    echo "OK_$u" > /var/www/$u/index.html
    chown -R $u:$u /var/www/$u
  done

  # .6 has no ProcessorPassTimeout: set it only where the build knows it
  PASS_LINE=""
  if grep -aq ProcessorPassTimeout /usr/lib64/httpd/modules/mod_mpm_peruser.so; then
    PASS_LINE="    ProcessorPassTimeout ${PASS_TIMEOUT}"
  fi

  echo "--- httpd config ---"
  rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.modules.d/*ssl*.conf
  echo "LoadModule mpm_peruser_module modules/mod_mpm_peruser.so" > /etc/httpd/conf.modules.d/00-mpm.conf
  cat > /etc/httpd/conf.d/peruser.conf << EOF
ServerName localhost
LogLevel info

<IfModule mpm_peruser_module>
    ServerLimit          40
    MaxClients           40
    MinMultiplexers      2
    MaxMultiplexers      2
    MinSpareProcessors   1
    MaxSpareProcessors   2
    MinProcessors        1
    MaxProcessors        2
    ExpireTimeout        7200
    IdleTimeout          600
    ProcessorWaitTimeout 5
${PASS_LINE}
</IfModule>

Processor usera usera
<Processor usera>
    User usera
    Group usera
</Processor>
Processor userb userb
<Processor userb>
    User userb
    Group userb
</Processor>

Listen 8080
ListenBacklog 4096

<VirtualHost *:8080>
    ServerName a.test
    DocumentRoot /var/www/usera
    <Directory /var/www/usera>
        Require all granted
    </Directory>
    <IfModule peruser.c>
        ServerEnvironment usera
    </IfModule>
</VirtualHost>
<VirtualHost *:8080>
    ServerName b.test
    DocumentRoot /var/www/userb
    <Directory /var/www/userb>
        Require all granted
    </Directory>
    <IfModule peruser.c>
        ServerEnvironment userb
    </IfModule>
</VirtualHost>
EOF
  httpd -t || { echo "ERROR: httpd -t failed"; exit 2; }
  echo "ProcessorPassTimeout set: ${PASS_LINE:-no (this build has no such directive)}"

  get() { # host timeout -> "code seconds"
    curl -s -m "$2" -o /tmp/body -w "%{http_code} %{time_total}" -H "Host: $1" http://127.0.0.1:8080/
  }

  mkdir -p /run/httpd
  httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1 &
  for i in $(seq 1 20); do
    [ "$(get a.test 3 | cut -d' ' -f1)" = 200 ] && [ "$(get b.test 3 | cut -d' ' -f1)" = 200 ] && break
    sleep 1
  done
  [ "$(get a.test 3 | cut -d' ' -f1)" = 200 ] && [ "$(get b.test 3 | cut -d' ' -f1)" = 200 ] \
    || { echo "ERROR: httpd did not come up"; tail -30 /var/log/httpd/error_log; exit 2; }
  echo "warm-up: a.test and b.test answer"

  echo "--- Stopping every usera process ---"
  APIDS=$(pgrep -u usera -x httpd | tr '\n' ' ')
  [ -n "$APIDS" ] || { echo "ERROR: no usera httpd process"; exit 2; }
  kill -STOP $APIDS
  echo "stopped: $APIDS"

  echo "--- ${FLOOD} requests to a.test, b.test once a second ---"
  seq 1 "$FLOOD" | xargs -P 100 -I{} \
    curl -s -m 20 -o /dev/null -w "%{http_code}\n" -H "Host: a.test" http://127.0.0.1:8080/ \
    > /tmp/flood.codes 2>/dev/null &
  FLOOD_PID=$!
  sleep 2
  B_OK=0; B_FAIL=0; B_LATE_FAIL=0
  for i in $(seq 1 "$PROBES"); do
    r=$(get b.test 8); code=${r%% *}
    if [ "$code" = 200 ]; then B_OK=$((B_OK + 1)); else
      B_FAIL=$((B_FAIL + 1)); [ "$i" -gt 10 ] && B_LATE_FAIL=$((B_LATE_FAIL + 1)); fi
    [ $((i % 5)) -eq 0 ] && echo "  probe $i: b.test $r"
    sleep 1
  done
  wait "$FLOOD_PID" 2>/dev/null || true

  echo "--- a.test after SIGCONT ---"
  # also any usera copy started meanwhile
  kill -CONT $APIDS $(pgrep -u usera -x httpd) 2>/dev/null
  A_BACK=""
  for i in $(seq 1 30); do
    r=$(get a.test 5); [ "${r%% *}" = 200 ] && { A_BACK="after ${i} tries ($r)"; break; }
    sleep 1
  done

  echo "--- Results ---"
  echo "b.test probes: ${B_OK} answered, ${B_FAIL} failed (${B_LATE_FAIL} after the first 10 s)"
  echo "a.test flood codes:"; sort /tmp/flood.codes | uniq -c
  echo "a.test after SIGCONT: ${A_BACK:-no answer}"
  TRIPPED=$(grep -c "took no request" /var/log/httpd/error_log)
  RECOVERED=$(grep -c "takes requests again" /var/log/httpd/error_log)
  echo "error_log: 'took no request' ${TRIPPED}, 'takes requests again' ${RECOVERED}"
  grep -E "took no request|takes requests again" /var/log/httpd/error_log | head -4

  if [ "$B_LATE_FAIL" -eq 0 ] && [ "$B_OK" -ge $((PROBES - 3)) ] && [ "$TRIPPED" -ge 1 ] \
     && [ -n "$A_BACK" ] && grep -q '^503$' /tmp/flood.codes; then
    echo "=== PASS: b.test kept answering while usera took nothing ==="
    exit 0
  fi
  echo "=== FAIL ==="
  echo "=== error_log (last 30 lines) ==="
  tail -30 /var/log/httpd/error_log
  exit 1
fi

# ---------------------------------------------------------------------------
# Host side: run the block above in a throwaway Rocky container
# ---------------------------------------------------------------------------
RPMS_DIR="${SCRIPT_DIR}/output/el${EL_VERSION}/RPMS"
FLOOD=800
while [ $# -gt 0 ]; do
  case "$1" in
    --rpms) RPMS_DIR="$2"; shift 2 ;;
    --flood) FLOOD="$2"; shift 2 ;;
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
  -e "FLOOD=${FLOOD}" \
  "${IMAGE_NAME}" \
  bash /src/pass-timeout-test.sh --in-container
