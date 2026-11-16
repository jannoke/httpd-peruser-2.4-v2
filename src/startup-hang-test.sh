#!/bin/bash
# Reproduction test for the dataserver hang of 2026-11-16 (05:53-07:11 EET, .6.peruser.dc):
# every new httpd child blocked in child_init -> ap_proxy_initialize_worker ->
# apr_global_mutex_lock(proxy_mutex), and the owner recorded in the mutex (a
# PI/robust pthread mutex, so a dead owner would have released it) was a child
# that stayed alive and never let go.
#
# The theory under test:
#   1. something sends SIGTERM to a child that is still in child_init;
#   2. its handler, just_die(), runs clean_child_exit(): apr_pool_destroy() and
#      exit() from inside the signal handler. Neither is async-signal-safe. The
#      child has mod_watchdog's thread by then, so malloc takes real locks, and
#      a signal that lands while the main code is in malloc (or holds any lock)
#      deadlocks the child. If that happens inside mod_proxy's locked section,
#      proxy_mutex is never released and every later child waits for it.
#   3. peruser itself sends that SIGTERM: determine_child_fate()'s ExpireTimeout
#      rules don't look at the scoreboard status, and a child's last_used isn't
#      set while it's SERVER_STARTING, so a child started in a slot that has
#      been unused for more than ExpireTimeout is stopped on the parent's next
#      pass, before it is ready.
#
# Two modes, each in a throwaway Rocky container with live's modules (the RPM's
# conf.modules.d), live's peruser.conf values, php-fpm behind SetHandler
# "proxy:unix:...|fcgi://<pool>" like DataPanel's vhosts, and many tenants:
#   --mode kill    (1, 2) an LD_PRELOAD fork() wrapper (startup-hang-forkterm.c)
#                  arms a SIGTERM in a share of the new children, 0-KILL_MAX_US
#                  after the fork, while a load loop keeps peruser starting
#                  new ones. Does a SIGTERM during startup ever leave a lock held?
#   --mode expire  (3) no outside killer. ExpireTimeout is lowered (5 s) so slots
#                  go stale quickly, tenants are hit in bursts with gaps longer
#                  than that, and strace on the parent logs every kill(); each is
#                  matched against the child's age and whether it had reached
#                  its main loop. Does peruser stop children that are starting?
#                  A hang in this mode is the incident itself.
# Both run a hang detector: a PI futex (lock) with waiters whose owner hasn't
# changed for HANG_SECS and isn't idling in poll/select is a hang; the accept
# mutex (owner idle in poll, waiters are multiplexers) is the normal case. On a
# hang the owner and a waiter are backtraced with gdb and the test fails.
#
# Usage (from repo root or src/):
#   EL_VERSION=10 ./src/startup-hang-test.sh --rpms DIR [--mode kill|expire]
#       [--duration S] [--tenants N] [--kill-ratio R] [--kill-max-us US]
# --rpms: one build's RPMs, debuginfo included if available (the .6 that's on
# dcw-ds-1: src/output/el10.6-backup-20261116).
#
# Exit codes: 0 no hang, 1 hang reproduced (or, in expire mode, starting children
# were killed: reported, see the summary), 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EL_VERSION="${EL_VERSION:-10}"
case "$EL_VERSION" in
  9)  IMAGE_NAME="rockylinux:9" ;;
  10) IMAGE_NAME="rockylinux/rockylinux:10.1" ;;
  *)  echo "ERROR: unsupported EL_VERSION '${EL_VERSION}' (expected 9 or 10)"; exit 2 ;;
esac

if [ "${1:-}" = "--in-container" ]; then
  MODE="${MODE:-kill}"
  DURATION="${DURATION:-300}"
  TENANTS="${TENANTS:-40}"
  VHOSTS="${VHOSTS:-3}"
  KILL_RATIO="${KILL_RATIO:-0.3}"
  KILL_MAX_US="${KILL_MAX_US:-5000}"
  HANG_SECS="${HANG_SECS:-20}"
  if [ "$MODE" = expire ]; then
    EXPIRE_TIMEOUT="${EXPIRE_TIMEOUT:-5}"; IDLE_TIMEOUT="${IDLE_TIMEOUT:-2}"; REST="${REST:-8}"
  else
    # rests longer than IdleTimeout: processors stop and start again all the time
    EXPIRE_TIMEOUT="${EXPIRE_TIMEOUT:-7200}"; IDLE_TIMEOUT="${IDLE_TIMEOUT:-2}"; REST="${REST:-4}"
  fi
  echo "=== startup-hang test, mode ${MODE}: ${DURATION}s, ${TENANTS} tenants x ${VHOSTS} vhosts," \
       "ExpireTimeout ${EXPIRE_TIMEOUT}, IdleTimeout ${IDLE_TIMEOUT} ==="

  echo "--- Installing test dependencies ---"
  dnf install -y --setopt=install_weak_deps=False --allowerasing \
    curl gdb gcc procps-ng python3 strace php-fpm dnf-plugins-core >/dev/null || { echo "ERROR: dnf install failed"; exit 2; }

  echo "--- Installing the httpd RPMs ---"
  RPMS=$(find /rpms -name "*.rpm" | grep -vE 'debuginfo|debugsource|\.src\.rpm|devel|manual' | sort)
  [ -n "$RPMS" ] || { echo "ERROR: no RPMs in the --rpms directory"; exit 2; }
  dnf install -y --allowerasing --setopt=install_weak_deps=False $RPMS >/dev/null \
    || { echo "ERROR: RPM install failed"; exit 2; }
  DEBUGINFO=$(find /rpms -name "httpd-*debug*.rpm" | grep -v tools | sort)
  [ -n "$DEBUGINFO" ] && { rpm -Uvh --nodeps --force $DEBUGINFO >/dev/null 2>&1 || echo "Warning: debuginfo install failed"; }
  dnf -q -y debuginfo-install glibc apr apr-util >/dev/null 2>&1 || echo "(no distro debuginfo: glibc frames without lines)"
  rpm -q httpd-core

  echo "--- Core dumps ---"
  ulimit -c unlimited
  mkdir -p /tmp/coredumps && chmod 1777 /tmp/coredumps
  echo "/tmp/coredumps/core.%e.%p" > /proc/sys/kernel/core_pattern 2>/dev/null || true
  echo 1 > /proc/sys/fs/suid_dumpable 2>/dev/null || true

  echo "--- php-fpm (one pool; each vhost names its own worker, like DataPanel) ---"
  mkdir -p /run/php-fpm
  POOL=/etc/php-fpm.d/www.conf
  sed -i -e 's|^listen.acl_users.*|;&|' -e 's|^;\?listen.mode.*|listen.mode = 0666|' \
         -e 's|^pm.max_children.*|pm.max_children = 40|' "$POOL"
  php-fpm -D || { echo "ERROR: php-fpm failed"; exit 2; }
  SOCK=$(awk -F' *= *' '/^listen *=/{print $2}' "$POOL")

  echo "--- Tenants and vhosts ---"
  rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.modules.d/*ssl*.conf
  echo "LoadModule mpm_peruser_module modules/mod_mpm_peruser.so" > /etc/httpd/conf.modules.d/00-mpm.conf
  : > /etc/httpd/conf.modules.d/01-cgi.conf
  CONF=/etc/httpd/conf.d/zz-startup-hang.conf
  cat > "$CONF" << EOF
ServerName localhost
CoreDumpDirectory /tmp/coredumps
LogLevel info
ExtendedStatus On
ProxyTimeout 600
<IfModule peruser.c>
	ServerLimit 640
	MaxClients 640
	MinSpareProcessors 2
	MaxSpareProcessors 20
	MinProcessors 0
	MaxProcessors 100
	MaxRequestsPerChild 1000
	ExpireTimeout ${EXPIRE_TIMEOUT}
	IdleTimeout ${IDLE_TIMEOUT}
	MinMultiplexers 3
	MaxMultiplexers 20
	MultiplexerIdleTimeout 120
	ProcessorWaitTimeout 5
</IfModule>
<VirtualHost *:80>
	ServerName localhost
	<Location /server-status>
		SetHandler server-status
		Require local
	</Location>
</VirtualHost>
EOF
  : > /tmp/hosts.txt
  for t in $(seq 1 "$TENANTS"); do
    uid=$((7000 + t))
    useradd -u $uid -M -d /home/t$uid -s /sbin/nologin t$uid
    cat >> "$CONF" << EOF
<Processor $uid>
	User #$uid
	Group #$uid
</Processor>
EOF
    for k in $(seq 1 "$VHOSTS"); do
      d=/home/t$uid/www$k; mkdir -p $d
      echo "OK t$uid-$k" > $d/index.html
      echo '<?php usleep(mt_rand(0, 200000)); echo "PHP_OK\n";' > $d/i.php
      cat >> "$CONF" << EOF
<VirtualHost *:80>
	ServerName t$uid-$k.test
	DocumentRoot $d
	<Directory $d>
		Require all granted
	</Directory>
	<FilesMatch "\.php\$">
		SetHandler "proxy:unix:${SOCK}|fcgi://dp-$uid-83"
	</FilesMatch>
	<IfModule peruser.c>
		ServerEnvironment $uid
	</IfModule>
</VirtualHost>
EOF
      echo "t$uid-$k.test" >> /tmp/hosts.txt
    done
    chown -R $uid:$uid /home/t$uid; chmod 755 /home/t$uid
  done
  httpd -t || { echo "ERROR: httpd -t failed"; exit 2; }

  echo "--- The fork() wrapper (LD_PRELOAD) ---"
  gcc -shared -fPIC -O2 -o /tmp/forkterm.so /src/startup-hang-forkterm.c -ldl -lrt \
    || { echo "ERROR: building the fork() wrapper failed"; exit 2; }
  FT_RATIO=0
  [ "$MODE" = kill ] && FT_RATIO=$KILL_RATIO
  echo "SIGTERM to ${FT_RATIO} of new children, 0-${KILL_MAX_US} us after the fork"

  mkdir -p /run/httpd
  LD_PRELOAD=/tmp/forkterm.so FT_RATIO=$FT_RATIO FT_MAX_US=$KILL_MAX_US FT_LOG=/tmp/forks.log \
    httpd -DFOREGROUND > /tmp/httpd-start.log 2>&1 &
  # up to 60 s: in kill mode the first children are killed too, and a busy host is slow
  for i in $(seq 1 60); do
    [ -s /run/httpd/httpd.pid ] && curl -fsS -m 5 -H "Host: t7001-1.test" http://127.0.0.1/ 2>/dev/null | grep -q OK && break
    sleep 1
  done
  curl -fsS -m 5 -H "Host: t7001-1.test" http://127.0.0.1/i.php 2>/dev/null | grep -q PHP_OK \
    || { echo "ERROR: httpd or php-fpm did not come up"; tail -20 /var/log/httpd/error_log; exit 2; }
  PARENT=$(cat /run/httpd/httpd.pid)
  echo "httpd parent $PARENT, $(pgrep -x httpd | wc -l) processes"

  STRACE_PID=
  if [ "$MODE" = expire ]; then
    strace -q -tt -e trace=kill -e signal=none -p "$PARENT" -o /tmp/kills.log &
    STRACE_PID=$!
  fi

  echo "--- Running ---"
  MODE=$MODE DURATION=$DURATION REST=$REST \
    HANG_SECS=$HANG_SECS PARENT=$PARENT python3 -u /src/startup-hang-harness.py
  RESULT=$?
  [ -n "$STRACE_PID" ] && kill "$STRACE_PID" 2>/dev/null
  sleep 1

  echo "--- Children that died on a signal or cored ---"
  echo "error_log lines with 'exit signal': $(grep -c 'exit signal' /var/log/httpd/error_log)"
  grep 'exit signal' /var/log/httpd/error_log | awk '{$1=$2=$3=$4=""; print}' | sort | uniq -c | sort -rn | head -5
  echo "core files: $(find /tmp/coredumps -name 'core.*' | wc -l)"
  echo "error_log 'not stopping child' (.8: a starting child ExpireTimeout would have stopped):" \
       "$(grep -c 'not stopping child' /var/log/httpd/error_log)"
  for core in $(find /tmp/coredumps -name 'core.*' | head -5); do
    echo "-- $core: the thread that crashed"
    gdb -q -batch -ex 'set pagination off' -ex bt /usr/sbin/httpd "$core" 2>&1 | grep -E '^#' | head -16 | cut -c1-160
  done

  if [ "$MODE" = expire ]; then
    echo "--- peruser's kills (strace on the parent) vs the children's age ---"
    python3 /src/startup-hang-harness.py --kills /tmp/kills.log /tmp/children.json
    [ $? -eq 1 ] && [ "$RESULT" -eq 0 ] && RESULT=1
  fi
  exit $RESULT
fi

# ---------------------------------------------------------------------------
# Host side: run the block above in a throwaway Rocky container
# ---------------------------------------------------------------------------
RPMS_DIR=""
MODE=kill; DURATION=300; TENANTS=40; KILL_RATIO=0.3; KILL_MAX_US=5000
while [ $# -gt 0 ]; do
  case "$1" in
    --rpms) RPMS_DIR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --tenants) TENANTS="$2"; shift 2 ;;
    --kill-ratio) KILL_RATIO="$2"; shift 2 ;;
    --kill-max-us) KILL_MAX_US="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
case "$MODE" in kill|expire) ;; *) echo "ERROR: --mode kill or expire"; exit 2 ;; esac
[ -n "$RPMS_DIR" ] && [ -d "$RPMS_DIR" ] || { echo "ERROR: --rpms DIR (one build's RPMs)"; exit 2; }
RPMS_DIR="$(cd "$RPMS_DIR" && pwd)"

CONTAINER_NAME="httpd-peruser-startup-hang-${MODE}-el${EL_VERSION}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run --privileged --rm \
  --name "${CONTAINER_NAME}" \
  -v "${SCRIPT_DIR}:/src:ro" \
  -v "${RPMS_DIR}:/rpms:ro" \
  -e "MODE=${MODE}" -e "DURATION=${DURATION}" -e "TENANTS=${TENANTS}" \
  -e "KILL_RATIO=${KILL_RATIO}" -e "KILL_MAX_US=${KILL_MAX_US}" \
  "${IMAGE_NAME}" \
  bash /src/startup-hang-test.sh --in-container
