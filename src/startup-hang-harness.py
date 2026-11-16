#!/usr/bin/env python3
"""The moving parts of startup-hang-test.sh, run inside its container.

  startup-hang-harness.py                 load + observer (+ killer) + hang detector,
                                          settings from the environment (see the .sh)
  startup-hang-harness.py --kills LOG JSON  match strace's kill() log against the
                                          children's first-seen / ready times

The observer scans /proc every few ms for the httpd parent's children: when
each appeared, and when its main thread first sat in poll/accept/recvmsg (its
main loop, so past child_init). In kill mode it also sends SIGTERM to a share
of new children, KILL_MAX_MS or less after they appeared, the way peruser does
(kill(-pid), the child's own process group).

The detector looks once a second at every httpd thread waiting in
FUTEX_LOCK_PI (a pthread PI mutex: proxy_mutex, the accept mutex, ...). The
futex word holds the owner's thread id. A lock whose owner stays the same for
HANG_SECS while others wait, and whose owner isn't idling in its main loop, is
the hang: it's backtraced and the run stops.
"""
import collections, glob, json, os, random, re, signal, socket, struct, subprocess
import sys, threading, time

IDLE_SYSCALLS = {7, 23, 232, 270, 281, 288}   # poll, select, epoll_wait, pselect6, epoll_pwait, accept4
MAIN_LOOP_SYSCALLS = {7, 47, 288}             # poll, recvmsg, accept4: past child_init
FUTEX = 202
FUTEX_LOCK_PI = 6


def read(path, default=''):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def syscall_of(task):
    f = read(task + '/syscall').split()
    if not f or not f[0].isdigit():
        return None, []
    return int(f[0]), f[1:]


class Run:
    def __init__(self):
        e = os.environ
        self.mode = e.get('MODE', 'kill')
        self.duration = int(e.get('DURATION', '300'))
        self.rest = float(e.get('REST', '0'))
        self.kill_ratio = float(e.get('KILL_RATIO', '0.3'))
        self.kill_max = float(e.get('KILL_MAX_MS', '30')) / 1000.0
        self.hang_secs = int(e.get('HANG_SECS', '20'))
        self.parent = int(e['PARENT'])
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.hang = None
        self.children = {}          # pid -> {'first': t, 'ready': t or None}
        self.kills = collections.Counter()
        self.results = collections.Counter()
        self.latencies = []
        self.window = collections.deque()   # (t, ok) of recent requests
        tenants = collections.defaultdict(list)
        for host in open('/tmp/hosts.txt').read().split():
            tenants[host.split('-')[0]].append(host)
        self.tenants = dict(tenants)
        self.last_burst = {t: 0.0 for t in self.tenants}

    # ---- load -------------------------------------------------------------
    def request(self, host, path):
        t0 = time.time()
        status = 'error'
        try:
            s = socket.create_connection(('127.0.0.1', 80), timeout=30)
            s.sendall(('GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' % (path, host)).encode())
            data = b''
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
            s.close()
            m = re.match(rb'HTTP/1\.\d (\d{3})', data)
            status = m.group(1).decode() if m else 'garbled'
            if status == '200' and b'OK' not in data:
                status = '200-empty'
        except socket.timeout:
            status = 'timeout'
        except OSError:
            status = 'error'
        dt = time.time() - t0
        with self.lock:
            self.results[status] += 1
            self.latencies.append(dt)
            self.window.append((time.time(), status == '200'))

    def load(self):
        while not self.stop.is_set():
            now = time.time()
            with self.lock:
                ready = [t for t, last in self.last_burst.items() if now - last >= self.rest]
                if ready:
                    tenant = random.choice(ready)
                    self.last_burst[tenant] = now + 3600    # taken: no other thread picks it
            if not ready:
                time.sleep(0.2)
                continue
            burst = [threading.Thread(target=self.request, args=(
                        random.choice(self.tenants[tenant]), random.choice(['/', '/i.php'])))
                     for _ in range(random.randint(1, 3))]
            for b in burst:
                b.start()
            for b in burst:
                b.join()
            with self.lock:
                self.last_burst[tenant] = time.time()
            if self.rest == 0:
                time.sleep(random.uniform(0, 0.3))

    # ---- observer and killer ----------------------------------------------
    def child_pids(self):
        pids = []
        for p in os.listdir('/proc'):
            if not p.isdigit():
                continue
            st = read('/proc/%s/stat' % p)
            i = st.rfind(')')
            if i < 0 or st[:i].find('(httpd') < 0:
                continue
            if int(st[i + 2:].split()[1]) == self.parent:
                pids.append(int(p))
        return pids

    def forks(self):
        """The children as the LD_PRELOAD fork() wrapper logs them: the exact
        fork time and the SIGTERM delay it armed (-1: none)."""
        pos = 0
        while not self.stop.is_set():
            try:
                with open('/tmp/forks.log') as f:
                    f.seek(pos)
                    lines = f.readlines()
                    pos = f.tell()
            except OSError:
                lines = []
            for line in lines:
                if not line.endswith('\n'):
                    pos -= len(line)
                    break
                pid, t, delay = line.split()
                with self.lock:
                    self.children[int(pid)] = {'first': int(t) / 1e6, 'ready': None,
                                               'delay': int(delay) / 1e6 if int(delay) > 0 else None}
                    if int(delay) > 0:
                        self.kills['armed'] += 1
            time.sleep(0.0005)

    def observe(self):
        """When each child first sits in its main loop (past child_init)."""
        while not self.stop.is_set():
            now = time.time()
            with self.lock:
                todo = [(pid, c) for pid, c in self.children.items()
                        if c['ready'] is None and now - c['first'] < 120]
            for pid, c in todo:
                nr, _ = syscall_of('/proc/%d' % pid)
                if nr in MAIN_LOOP_SYSCALLS:
                    c['ready'] = time.time()
            time.sleep(0.0005)

    # ---- hang detector ----------------------------------------------------
    def lock_waiters(self):
        waiters = collections.defaultdict(list)
        for pid in [self.parent] + self.child_pids():
            for task in glob.glob('/proc/%d/task/*' % pid):
                nr, args = syscall_of(task)
                if nr == FUTEX and len(args) > 1 and (int(args[1], 16) & 0x7f) == FUTEX_LOCK_PI:
                    waiters[int(args[0], 16)].append((pid, int(os.path.basename(task))))
        return waiters

    def owner_state(self, tid):
        tgid = read('/proc/%d/status' % tid)
        m = re.search(r'^Tgid:\s*(\d+)', tgid, re.M)
        if not m:
            return None, []
        tgid = int(m.group(1))
        return tgid, [(int(os.path.basename(t)), syscall_of(t)[0]) for t in glob.glob('/proc/%d/task/*' % tgid)]

    def detect(self):
        seen = {}   # (addr, owner) -> first time
        while not self.stop.wait(1):
            now = time.time()
            current = set()
            for addr, ws in self.lock_waiters().items():
                try:
                    with open('/proc/%d/mem' % ws[0][0], 'rb') as m:
                        m.seek(addr)
                        word = struct.unpack('I', m.read(4))[0]
                except (OSError, struct.error):
                    continue
                owner = word & 0x3fffffff
                key = (addr, owner)
                current.add(key)
                seen.setdefault(key, now)
                if now - seen[key] < self.hang_secs or not owner:
                    continue
                tgid, threads = self.owner_state(owner)
                idle = threads and all(nr in IDLE_SYSCALLS for _, nr in threads)
                if idle and now - seen[key] < 6 * self.hang_secs:
                    continue    # the accept mutex's owner idling in poll: normal
                self.hang = dict(addr=addr, word=word, owner=owner, tgid=tgid, threads=threads,
                                 waiters=ws, since=now - seen[key], idle=idle)
                self.stop.set()
                return
            for key in list(seen):
                if key not in current:
                    del seen[key]

    # ---- report -----------------------------------------------------------
    def progress(self):
        start = time.time()
        while not self.stop.wait(10):
            with self.lock:
                while self.window and self.window[0][0] < time.time() - 10:
                    self.window.popleft()
                ok = sum(1 for _, good in self.window if good)
                print('  t+%3ds: %d requests in 10s (%d ok), totals %s, %d children seen, kills %s' % (
                    time.time() - start, len(self.window), ok, dict(self.results),
                    len(self.children), dict(self.kills)), flush=True)
            if time.time() - start >= self.duration:
                self.stop.set()

    def dump_hang(self):
        h = self.hang
        print('\n=== HANG: lock 0x%x, word 0x%08x, owner tid %d (process %s), unchanged for %ds,'
              ' %d waiter(s)%s ===' % (h['addr'], h['word'], h['owner'], h['tgid'], h['since'],
                                       len(h['waiters']), ', owner idle in poll?!' if h['idle'] else ''))
        print('owner threads (tid, syscall):', h['threads'])
        for tid, _ in h['threads']:
            print('-- owner thread %d kernel stack:' % tid)
            print(read('/proc/%s/task/%d/stack' % (h['tgid'], tid)).rstrip())
        if h['tgid']:
            print('-- owner: gdb backtrace, all threads')
            print(gdb(h['tgid'], ['thread apply all bt 30']))
        wpid = h['waiters'][0][0]
        print('-- a waiter (pid %d): backtrace and proxy_mutex' % wpid)
        print(gdb(wpid, ['bt 25',
            'p ((pthread_mutex_t*)proxy_mutex->proc_mutex->os.pthread_interproc)->__data.__owner',
            'p/x (long)proxy_mutex->proc_mutex->os.pthread_interproc']))
        print('-- waiters:', h['waiters'][:20])

    def main(self):
        threads = [threading.Thread(target=self.forks, daemon=True),
                   threading.Thread(target=self.observe, daemon=True),
                   threading.Thread(target=self.detect, daemon=True),
                   threading.Thread(target=self.progress, daemon=True)]
        threads += [threading.Thread(target=self.load, daemon=True) for _ in range(24)]
        for t in threads:
            t.start()
        self.stop.wait()
        time.sleep(1)
        with self.lock:
            with open('/tmp/children.json', 'w') as f:
                json.dump(self.children, f)
        starts = sorted(c['ready'] - c['first'] for c in self.children.values()
                        if c['ready'] and not c['delay'])
        if starts:
            print('--- Startup (fork to main loop), unkilled children: median %.1f ms, p90 %.1f ms, max %.1f ms' % (
                starts[len(starts) // 2] * 1000, starts[int(len(starts) * .9)] * 1000, starts[-1] * 1000))
        lat = sorted(self.latencies) or [0]
        print('\n--- Load: %s; latency median %.2fs, p99 %.2fs, max %.2fs' % (
            dict(self.results), lat[len(lat) // 2], lat[int(len(lat) * .99)], lat[-1]))
        started = len(self.children)
        never = sum(1 for c in self.children.values() if c['ready'] is None)
        print('--- Children: %d seen, %d never seen in their main loop (killed, or too short-lived to see)'
              % (started, never))
        if self.mode == 'kill':
            armed = [c for c in self.children.values() if c['delay']]
            early = [c for c in armed if c['ready'] is None or c['ready'] - c['first'] > c['delay']]
            print('--- SIGTERMs armed: %d, of them before the child reached its main loop: %d' % (
                len(armed), len(early)))
        if self.hang:
            self.dump_hang()
            print('=== FAIL: a lock stayed held, the startup hang reproduced ===')
            return 1
        print('=== PASS: no lock stayed held for %ds ===' % self.hang_secs)
        return 0


def gdb(pid, commands):
    cmd = ['timeout', '60', 'gdb', '-q', '-batch', '-p', str(pid), '-ex', 'set pagination off']
    for c in commands:
        cmd += ['-ex', c]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    return '\n'.join(l for l in out.splitlines()
                     if re.match(r'^(#|\$|Thread )', l))[:8000]


def kills_report(log, children_json):
    """strace -tt of the parent: '12:34:56.789012 kill(-1234, SIGTERM) = 0'"""
    children = {int(k): v for k, v in json.load(open(children_json)).items()}
    day = time.strftime('%Y-%m-%d', time.localtime(min((c['first'] for c in children.values()),
                                                       default=time.time())))
    total = starting = unknown = 0
    ages, examples = [], []
    for line in open(log):
        m = re.match(r'(\d\d:\d\d:\d\d\.\d+) kill\((-?\d+), SIGTERM\)', line)
        if not m:
            continue
        t = time.mktime(time.strptime(day + ' ' + m.group(1).split('.')[0], '%Y-%m-%d %H:%M:%S')) \
            + float('0.' + m.group(1).split('.')[1])
        pid = abs(int(m.group(2)))
        total += 1
        c = children.get(pid)
        if c is None:
            unknown += 1
            continue
        if c['ready'] is None or c['ready'] > t:
            starting += 1
            ages.append(t - c['first'])
            if len(examples) < 10:
                examples.append('pid %d killed %.0f ms after it appeared, %s' % (
                    pid, (t - c['first']) * 1000,
                    'never reached its main loop' if c['ready'] is None
                    else 'reached its main loop %.0f ms later' % ((c['ready'] - t) * 1000)))
    print('SIGTERMs from the parent: %d; to children still starting: %d; to children not seen: %d'
          % (total, starting, unknown))
    if ages:
        ages.sort()
        print('their age at the kill: min %.0f ms, median %.0f ms, max %.0f ms' % (
            ages[0] * 1000, ages[len(ages) // 2] * 1000, ages[-1] * 1000))
    for e in examples:
        print('  ' + e)
    return 1 if starting else 0


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--kills':
        sys.exit(kills_report(sys.argv[2], sys.argv[3]))
    sys.exit(Run().main())
