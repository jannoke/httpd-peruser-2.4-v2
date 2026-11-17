#!/bin/bash
# Regression tests for the review fixes of .9.peruser.dc (README, "Review
# hardening"). One throwaway Rocky container, one httpd start per case:
#
#   handoff     a POST with a large request head comes back unchanged
#               (mod_reflector); a head over the hand-off's bound gets a 413
#   stop        SIGWINCH (apachectl graceful-stop, systemd's KillSignal) stops
#               the server; a requested stop exits 0; no process is left
#   limit       ServerLimit 10 without MaxClients: reload and stop don't crash
#   configtest  ServerLimit 406 and 918, MaxSpareProcessors in a vhost before
#               ServerEnvironment: "httpd -t" doesn't crash
#   reload      6 graceful restarts: the parent's shared mappings don't grow,
#               no "long lost child", a changed ServerLimit is refused with a
#               warning, the sites answer
#   extstatus   ExtendedStatus Off: idle workers stay (IdleTimeout 900)
#   tenant      a processor whose child can't be set up gets 503s; the
#               server and the other processor go on
#   maxreq      MaxRequestsPerChild counts connections, not wake-ups
#   daemon      started without -DFOREGROUND, httpd detaches
#
# Usage (from repo root or src/):
#   EL_VERSION=10 ./src/review-hardening-test.sh [--rpms DIR] [--only CASE]
# Exit codes: 0 all passed, 1 a case failed, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EL_VERSION="${EL_VERSION:-9}"
case "$EL_VERSION" in
  9)  IMAGE_NAME="rockylinux:9" ;;
  10) IMAGE_NAME="rockylinux/rockylinux:10" ;;
  *)  echo "ERROR: unsupported EL_VERSION '${EL_VERSION}' (expected 9 or 10)"; exit 2 ;;
esac
CONTAINER_NAME="httpd-peruser-review-hardening-test-el${EL_VERSION}"

if [ "${1:-}" = "--in-container" ]; then
  ONLY="${ONLY:-}"
  LOG=/var/log/httpd/error_log
  FAILED=""
  PASSED=""

  dnf install -y --setopt=install_weak_deps=False --allowerasing \
    curl procps-ng findutils python3 >/dev/null || { echo "ERROR: dnf install failed"; exit 2; }
  RPMS=$(find /rpms -name "*.rpm" | grep -vE 'debuginfo|debugsource|\.src\.rpm|devel' | sort)
  [ -n "$RPMS" ] || { echo "ERROR: no RPMs in the --rpms directory"; exit 2; }
  dnf install -y --allowerasing --setopt=install_weak_deps=False $RPMS >/dev/null \
    || { echo "ERROR: RPM install failed"; exit 2; }
  rpm -q httpd

  for u in usera userb userc; do
    useradd -r -m -d /home/$u -s /sbin/nologin $u
    mkdir -p /var/www/$u
    echo "OK_$u" > /var/www/$u/index.html
    chown -R $u:$u /var/www/$u
  done
  rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.modules.d/*ssl*.conf
  echo "LoadModule mpm_peruser_module modules/mod_mpm_peruser.so" > /etc/httpd/conf.modules.d/00-mpm.conf
  [ -f /usr/lib64/httpd/modules/mod_reflector.so ] \
    && echo "LoadModule reflector_module modules/mod_reflector.so" > /etc/httpd/conf.modules.d/99-reflector.conf
  mkdir -p /run/httpd
  ulimit -c 0

  # write_conf "<lines for the mpm block>" "<lines after it>" "<lines in a.test's vhost before ServerEnvironment>" "<lines in usera's Processor>"
  write_conf() {
    cat > /etc/httpd/conf.d/peruser.conf << CONF
ServerName localhost
LogLevel info
<IfModule mpm_peruser_module>
$1
</IfModule>
${2:-}
Processor usera usera
<Processor usera>
    User usera
    Group usera
${4:-}
</Processor>
Processor userb userb
<Processor userb>
    User userb
    Group userb
</Processor>
Listen 8080
LimitRequestFieldSize 8190
LimitRequestFields 100
<VirtualHost *:8080>
    ServerName a.test
    DocumentRoot /var/www/usera
    <Directory /var/www/usera>
        Require all granted
    </Directory>
${3:-}
    ServerEnvironment usera
    <IfModule reflector_module>
        <Location /echo>
            SetHandler reflector
        </Location>
    </IfModule>
</VirtualHost>
<VirtualHost *:8080>
    ServerName b.test
    DocumentRoot /var/www/userb
    <Directory /var/www/userb>
        Require all granted
    </Directory>
    ServerEnvironment userb
</VirtualHost>
CONF
  }
  MPM_DEFAULT="    ServerLimit 40
    MaxClients 40
    MinMultiplexers 2
    MaxMultiplexers 4
    MinSpareProcessors 1
    MaxSpareProcessors 5
    MinProcessors 1
    MaxProcessors 6
    ExpireTimeout 7200
    IdleTimeout 600
    ProcessorWaitTimeout 5"

  code() { curl -s -m "${2:-5}" -o /dev/null -w "%{http_code}" -H "Host: $1" http://127.0.0.1:8080/; }
  PARENT=""; PARENT_RC_FILE=/tmp/httpd.rc
  start_httpd() { # foreground parent in a subshell that records its exit status
    : > "$LOG"; rm -f "$PARENT_RC_FILE" /run/httpd/httpd.pid
    ( trap '' TERM HUP; httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1; echo $? > "$PARENT_RC_FILE" ) &
    for i in $(seq 1 20); do
      [ "$(code a.test 3)" = 200 ] && [ "$(code b.test 3)" = 200 ] && break; sleep 1
    done
    PARENT=$(cat /run/httpd/httpd.pid 2>/dev/null)
    [ -n "$PARENT" ] && [ "$(code a.test 3)" = 200 ]
  }
  wait_gone() { # all httpd processes gone within $1 s
    for i in $(seq 1 "$1"); do pgrep -x httpd >/dev/null || return 0; sleep 1; done; return 1
  }
  stop_httpd() { pkill -TERM -x httpd 2>/dev/null; wait_gone 15 || { pkill -KILL -x httpd; sleep 1; }; }
  crashed() { grep -qE "exit signal|Segmentation|core dumped" "$LOG" /tmp/httpd-start.log 2>/dev/null; }
  result() { # name ok(0/1) detail
    if [ "$2" = 0 ]; then echo "=== PASS: $1 ($3)"; PASSED="$PASSED $1"
    else echo "=== FAIL: $1 ($3)"; FAILED="$FAILED $1"; echo "--- error_log ---"; tail -25 "$LOG"; cat /tmp/httpd-start.log 2>/dev/null | tail -5; fi
    stop_httpd
  }
  want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

  if want handoff; then
    echo; echo "--- handoff ---"
    write_conf "$MPM_DEFAULT"
    if [ ! -f /etc/httpd/conf.modules.d/99-reflector.conf ]; then
      echo "=== SKIP: handoff (no mod_reflector in this build)"
    elif start_httpd; then
      python3 /src/review-hardening-probe.py; rc=$?
      crashed && rc=1
      [ "$(code b.test)" = 200 ] || rc=1
      result handoff $rc "bodies echoed unchanged, 413 over the bound"
    else result handoff 1 "httpd did not come up"; fi
  fi

  if want stop; then
    echo; echo "--- stop ---"
    write_conf "$MPM_DEFAULT"
    rc=0; detail=""
    for sig in WINCH TERM; do
      start_httpd || { rc=1; detail="$detail no start;"; break; }
      kill -$sig "$PARENT"
      wait_gone 20 || { rc=1; detail="$detail SIG$sig: processes left;"; }
      sleep 1
      st=$(cat "$PARENT_RC_FILE" 2>/dev/null)
      [ "$st" = 0 ] || { rc=1; detail="$detail SIG$sig: exit status ${st:-none};"; }
      grep -q "caught SIG$sig, shutting down" "$LOG" || { rc=1; detail="$detail SIG$sig: no log line;"; }
      grep -q "AH02818" "$LOG" /tmp/httpd-start.log && { rc=1; detail="$detail SIG$sig: AH02818;"; }
      echo "SIG$sig: exit status ${st:-none}; $(grep -c 'shutting down' "$LOG") shutdown line(s)"
      stop_httpd
    done
    result stop $rc "${detail:-SIGWINCH and SIGTERM stop the server, exit 0}"
  fi

  if want limit; then
    echo; echo "--- limit ---"
    write_conf "    ServerLimit 10
    MinMultiplexers 2
    MaxMultiplexers 3
    MinProcessors 1
    MaxProcessors 3"
    rc=0; detail=""
    if start_httpd; then
      kill -USR1 "$PARENT"; sleep 4
      kill -0 "$PARENT" 2>/dev/null || { rc=1; detail="$detail parent gone after SIGUSR1;"; }
      [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer after reload;"; }
      kill -TERM "$PARENT"; wait_gone 20 || { rc=1; detail="$detail processes left;"; }
      sleep 1; st=$(cat "$PARENT_RC_FILE" 2>/dev/null)
      [ "$st" = 0 ] || { rc=1; detail="$detail exit status ${st:-none};"; }
      crashed && { rc=1; detail="$detail crash in the log;"; }
    else rc=1; detail="httpd did not come up"; fi
    result limit $rc "${detail:-ServerLimit 10 without MaxClients: reload and stop clean}"
  fi

  if want configtest; then
    echo; echo "--- configtest ---"
    rc=0; detail=""
    for n in 406 918; do
      write_conf "    ServerLimit $n"
      httpd -t > /tmp/t.out 2>&1; st=$?
      echo "ServerLimit $n: httpd -t exit $st ($(tail -1 /tmp/t.out))"
      [ "$st" = 0 ] || { rc=1; detail="$detail ServerLimit $n: exit $st;"; }
    done
    write_conf "$MPM_DEFAULT" "" "    MaxSpareProcessors 4"
    httpd -t > /tmp/t.out 2>&1; st=$?
    echo "MaxSpareProcessors before ServerEnvironment: httpd -t exit $st ($(tail -1 /tmp/t.out))"
    [ "$st" -lt 126 ] || { rc=1; detail="$detail vhost MaxSpareProcessors: exit $st;"; }
    # more processors than ServerLimit: a config error, not a crash
    write_conf "    ServerLimit 1"
    httpd -t > /tmp/t.out 2>&1; st=$?
    echo "ServerLimit 1 with 2 processors: httpd -t exit $st ($(grep -m1 -i 'ServerLimit' /tmp/t.out | tr -s ' ' | cut -c1-110))"
    [ "$st" = 1 ] || { rc=1; detail="$detail ServerLimit 1: exit $st, expected 1;"; }
    : > "$LOG"
    result configtest $rc "${detail:-no crash in httpd -t}"
  fi

  if want reload; then
    echo; echo "--- reload ---"
    write_conf "$MPM_DEFAULT"
    rc=0; detail=""
    shmaps() { grep -cE 'SYSV|/dev/zero|/dev/shm|\(deleted\)' /proc/"$PARENT"/maps; }
    if start_httpd; then
      kill -USR1 "$PARENT"; sleep 3; [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer after reload 1;"; }
      M1=$(shmaps); V1=$(awk '/VmSize/{print $2}' /proc/"$PARENT"/status)
      for i in 2 3 4 5 6; do kill -USR1 "$PARENT"; sleep 3; code a.test >/dev/null; done
      M6=$(shmaps); V6=$(awk '/VmSize/{print $2}' /proc/"$PARENT"/status)
      echo "parent's shared mappings: $M1 after reload 1, $M6 after reload 6; VmSize $V1 -> $V6 kB"
      [ "$M6" -le "$M1" ] || { rc=1; detail="$detail shared mappings grew $M1 -> $M6;"; }
      [ "$(code a.test)" = 200 ] && [ "$(code b.test)" = 200 ] || { rc=1; detail="$detail no answer after reload 6;"; }
      grep -q "long lost child" "$LOG" && { rc=1; detail="$detail 'long lost child' in the log;"; }
      grep -q "AH00546" "$LOG" && { rc=1; detail="$detail AH00546 in the log;"; }
      # a changed ServerLimit: refused with a warning, twice, no crash
      sed -i 's/ServerLimit 40/ServerLimit 300/' /etc/httpd/conf.d/peruser.conf
      kill -USR1 "$PARENT"; sleep 3; kill -USR1 "$PARENT"; sleep 3
      kill -0 "$PARENT" 2>/dev/null || { rc=1; detail="$detail parent gone after the ServerLimit change;"; }
      [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer after the ServerLimit change;"; }
      W=$(grep -c "changing ServerLimit to 300 from original value of 40" "$LOG")
      echo "ServerLimit 40 -> 300 on reload: $W warning(s)"
      [ "$W" -ge 1 ] || { rc=1; detail="$detail no ServerLimit warning;"; }
      crashed && { rc=1; detail="$detail crash in the log;"; }
      # SIGHUP too
      kill -HUP "$PARENT"; sleep 4
      [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer after SIGHUP;"; }
      # nothing of an old generation left behind after the stop
      kill -TERM "$PARENT"; wait_gone 20 || { rc=1; detail="$detail processes left after stop;"; }
    else rc=1; detail="httpd did not come up"; fi
    result reload $rc "${detail:-6 reloads, no growth, ServerLimit change refused}"
  fi

  if want extstatus; then
    echo; echo "--- extstatus ---"
    write_conf "    ServerLimit 40
    MaxClients 40
    MinMultiplexers 2
    MaxMultiplexers 4
    MinSpareProcessors 0
    MaxSpareProcessors 0
    MinProcessors 0
    MaxProcessors 6
    ExpireTimeout 7200
    IdleTimeout 900" "ExtendedStatus Off"
    rc=0; detail=""
    if start_httpd; then
      for i in 1 2 3; do code a.test >/dev/null; done
      N0=$(pgrep -u usera -x httpd | wc -l); sleep 10; N1=$(pgrep -u usera -x httpd | wc -l)
      echo "usera processes: $N0 after the requests, $N1 ten seconds later"
      [ "$N0" -ge 1 ] && [ "$N1" -ge 1 ] || { rc=1; detail="idle workers gone ($N0 -> $N1)"; }
      grep -q "ExtendedStatus Off is not supported" "$LOG" /tmp/httpd-start.log || { rc=1; detail="$detail no warning;"; }
    else rc=1; detail="httpd did not come up"; fi
    result extstatus $rc "${detail:-idle workers stay with ExtendedStatus Off}"
  fi

  if want tenant; then
    echo; echo "--- tenant ---"
    mkdir -p /var/chroot-usera
    write_conf "    ServerLimit 40
    MaxClients 40
    MinMultiplexers 2
    MaxMultiplexers 4
    MinSpareProcessors 0
    MaxSpareProcessors 3
    MinProcessors 0
    MaxProcessors 6
    ExpireTimeout 7200
    IdleTimeout 600
    ProcessorWaitTimeout 3" "" "" "    Chroot /var/chroot-usera"
    rc=0; detail=""
    : > "$LOG"; rm -f "$PARENT_RC_FILE" /run/httpd/httpd.pid
    ( trap '' TERM HUP; httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1; echo $? > "$PARENT_RC_FILE" ) &
    for i in $(seq 1 20); do [ "$(code b.test 3)" = 200 ] && break; sleep 1; done
    PARENT=$(cat /run/httpd/httpd.pid 2>/dev/null)
    if [ -n "$PARENT" ] && [ "$(code b.test)" = 200 ]; then
      # usera's children can't be set up from now on (as a removed account
      # or a broken cgroup would do)
      pkill -KILL -u usera -x httpd; rmdir /var/chroot-usera; sleep 1
      # 000 = the connection was closed without an answer: the request that
      # was already handed to the child that then failed. Fine when quick.
      A=""; B_OK=0; HUNG=0
      for i in $(seq 1 12); do
        t0=$(date +%s); A="$A $(code a.test 10)"; [ $(( $(date +%s) - t0 )) -ge 9 ] && HUNG=1
        [ "$(code b.test 5)" = 200 ] && B_OK=$((B_OK + 1)); sleep 1
      done
      echo "a.test:$A"; echo "b.test: $B_OK of 12 answered"
      kill -0 "$PARENT" 2>/dev/null || { rc=1; detail="$detail the server stopped;"; }
      [ "$B_OK" = 12 ] || { rc=1; detail="$detail b.test lost requests;"; }
      echo "$A" | grep -q 503 || { rc=1; detail="$detail a.test got no 503;"; }
      [ "$HUNG" = 0 ] || { rc=1; detail="$detail an a.test request hung;"; }
      F=$(grep -c "could not start" "$LOG"); echo "'could not start' lines: $F"
      [ "$F" -ge 1 ] || { rc=1; detail="$detail no log line;"; }
      [ "$F" -le 4 ] || { rc=1; detail="$detail $F start attempts in ~25 s (fork loop);"; }
      # the account is back: the processor recovers by itself
      mkdir -p /var/chroot-usera/var/www; cp -a /var/www/usera /var/chroot-usera/var/www/
      BACK=""
      for i in $(seq 1 25); do [ "$(code a.test 5)" = 200 ] && { BACK=$i; break; }; sleep 1; done
      echo "a.test after the repair: ${BACK:+answers after $BACK s}"
      [ -n "$BACK" ] || { rc=1; detail="$detail a.test did not recover;"; }
    else rc=1; detail="httpd did not come up"; fi
    result tenant $rc "${detail:-one processor failing leaves the server and b.test up}"
  fi

  if want maxreq; then
    echo; echo "--- maxreq ---"
    write_conf "    ServerLimit 40
    MaxClients 40
    MinMultiplexers 2
    MaxMultiplexers 4
    StartProcessors 4
    MinSpareProcessors 4
    MaxSpareProcessors 8
    MinProcessors 4
    MaxProcessors 8
    MaxRequestsPerChild 40
    ExpireTimeout 7200
    IdleTimeout 600"
    rc=0; detail=""
    if start_httpd; then
      for i in $(seq 1 6); do code a.test >/dev/null; done; sleep 3
      P0=$(pgrep -u usera -x httpd | sort | tr '\n' ' ')
      for i in $(seq 1 150); do code a.test >/dev/null; done
      sleep 2
      P1=$(pgrep -u usera -x httpd | sort | tr '\n' ' ')
      KEPT=0; for p in $P0; do echo " $P1" | grep -q " $p " && KEPT=$((KEPT + 1)); done
      echo "usera workers before: $P0"; echo "after 150 requests:   $P1"; echo "kept: $KEPT"
      [ "$(echo $P0 | wc -w)" -ge 4 ] || { rc=2; detail="fewer than 4 workers to start with"; }
      # 156 connections over 6 workers (240 allowed): by connections not all can have
      # reached 40; by wake-ups every one had
      [ "$KEPT" -ge 3 ] || { rc=1; detail="only $KEPT of the workers kept"; }
    else rc=1; detail="httpd did not come up"; fi
    result maxreq $rc "${detail:-workers not all recycled after 156 requests at limit 40}"
  fi

  if want daemon; then
    echo; echo "--- daemon ---"
    write_conf "$MPM_DEFAULT"
    rc=0; detail=""
    : > "$LOG"; rm -f /run/httpd/httpd.pid
    timeout 20 httpd > /tmp/httpd-start.log 2>&1; st=$?
    echo "httpd (no -DFOREGROUND) returned $st"
    [ "$st" = 0 ] || { rc=1; detail="$detail returned $st (124 = did not detach);"; }
    for i in $(seq 1 15); do [ "$(code a.test 3)" = 200 ] && break; sleep 1; done
    [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer;"; }
    PARENT=$(cat /run/httpd/httpd.pid 2>/dev/null)
    if [ -n "$PARENT" ]; then
      echo "parent $PARENT: ppid $(ps -o ppid= -p "$PARENT" | tr -d ' '), session $(ps -o sid= -p "$PARENT" | tr -d ' ')"
      [ "$(ps -o sid= -p "$PARENT" | tr -d ' ')" = "$PARENT" ] || { rc=1; detail="$detail not a session leader;"; }
      httpd -k graceful; sleep 3
      [ "$(code a.test)" = 200 ] || { rc=1; detail="$detail no answer after -k graceful;"; }
      httpd -k stop; wait_gone 20 || { rc=1; detail="$detail processes left after -k stop;"; }
    else rc=1; detail="$detail no pid file;"; fi
    result daemon $rc "${detail:-detaches, reloads and stops}"
  fi

  echo
  echo "passed:${PASSED:- none}"
  if [ -n "$FAILED" ]; then echo "=== FAILED:$FAILED ==="; exit 1; fi
  echo "=== ALL PASSED ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Host side: run the block above in a throwaway Rocky container
# ---------------------------------------------------------------------------
RPMS_DIR="${SCRIPT_DIR}/output/el${EL_VERSION}/RPMS"
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rpms) RPMS_DIR="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
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
  -e "ONLY=${ONLY}" \
  "${IMAGE_NAME}" \
  bash /src/review-hardening-test.sh --in-container
