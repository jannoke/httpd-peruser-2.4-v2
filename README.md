# httpd peruser MPM — RPM Build for Rocky Linux 9 / 10

This repository builds a patched Apache HTTP Server (`httpd`) RPM for
**Rocky Linux 9 and Rocky Linux 10** (EL9/EL10) that includes the **peruser
MPM** (Multi-Processing Module). The peruser MPM allows Apache to run each
virtual host under a separate system user, improving isolation and security
in shared-hosting scenarios.

All build/test scripts take an `EL_VERSION` environment variable (`9` or
`10`, default `9`) to select the target. el10 uses a differently-namespaced
base image than el9/el8 (`rockylinux/rockylinux:10` instead of
`rockylinux:10`), which the scripts already account for — you only need to
set `EL_VERSION`.

## Repository layout

```
.
├── .devcontainer/devcontainer.json   # GitHub Codespaces configuration
├── .github/workflows/build-rpm.yml   # Full CI/CD pipeline (GitHub Actions)
├── AGENT_INSTRUCTIONS.md             # Instructions for the coding agent
├── src/                              # All source files, patches, and build scripts
│   ├── httpd.spec                    # RPM spec file
│   ├── peruser-2.4-httpd24-fix.patch # Main peruser MPM patch
│   ├── httpd-2.4.62.tar.bz2         # Apache source tarball
│   ├── Dockerfile.rpmbuild           # Production Docker build image (el9/el10 via BASE_IMAGE)
│   ├── build-rpm.sh                  # One-shot Docker build script
│   ├── Dockerfile.devbuild           # Development build image (el9/el10 via BASE_IMAGE)
│   ├── build-rpm-dev.sh              # In-container build script (dev loop)
│   ├── dev-build-loop.sh             # Interactive dev build loop (see below)
│   ├── agent-build-loop.sh           # Non-interactive build script (agent use)
│   ├── local-smoke-test.sh           # Install the RPMs, start/request/stop cycles
│   ├── spare-kill-test.sh            # Regression: MaxSpareProcessors never stops a busy copy (.6)
│   ├── pass-timeout-test.sh          # Regression: a processor that takes nothing can't stop the server (.7)
│   ├── startup-hang-test.sh          # Regression: a SIGTERM during a child's startup can't stop the server (.8)
│   └── review-hardening-test.sh      # Regression: the review fixes, nine cases (.9); uses review-hardening-probe.py
└── README.md                         # This file
```

## Review hardening (`.9.peruser.dc`)

Fixes from the security and stability review of 2026-11-16 (two reviews of the MPM, checked against
the source and merged). `review-hardening-test.sh` has a case for each group. On `.8` eight of its
nine cases fail; `extstatus` passes there because `.8` already fixed the behaviour.

**The hand-off between multiplexer and worker**

- **Body read from outside the buffer.** The message carries the request head and what was already
  read of the body. Only the head's length was limited (20000 bytes), and the worker rebuilt the
  body from a 20000-byte buffer. A POST with a head over ~18 KB got part of its body from the
  worker's stack instead, with a 200. Now both sides check the same bound
  (`PERUSER_MAX_PASS_DATA`, 30000 bytes for head and body together, checked at compile time against
  one socket buffer). The multiplexer answers 413 to a head over it, and the worker drops a message
  that doesn't add up and closes the connection (case `handoff`).
- **Request pool freed before the 503.** `pass_request()` destroyed the request's pool on a failed
  send and returned an error, and httpd then wrote the 503 from that freed request, in a
  multiplexer that every site shares. `.7`'s ProcessorPassTimeout made that path common. It no
  longer destroys the pool.
- **Smaller ones:** `pass_socket()` checks its sends, the pipe-of-death read is checked, and the
  address in the message is validated.

**One tenant can't stop the server**

A child that exits with `APEXIT_CHILDFATAL` (setuid, setgid, chroot or cgroup failed) made the
parent return at once: every site down, the children left behind. Now it depends on whose it was:

- **A tenant's processor or worker:** an error line names the processor, no replacement is forked,
  and its requests get a 503 for 10 s (`PERUSER_START_BLOCK_SECS`). Then the next request tries
  again. Connections already queued for it are closed by the parent when no child is left to read
  them. httpd's own `AH00050 ... Apache is exiting!` line still appears just before ours, and it's
  wrong in this case (case `tenant`).
- **A multiplexer, or a process the parent has no record of:** the server still stops, but the
  normal way (children signalled and reaped, pid file removed), with an alert line and a failing
  exit status.

**Stop and restart**

- **SIGWINCH stops the server.** It was ignored, so `apachectl graceful-stop` and the unit's
  `KillSignal=SIGWINCH` did nothing until systemd's timeout. It's a plain stop, not a graceful one:
  requests in progress are cut, as with SIGTERM.
- **A requested stop exits 0.** It returned an error, so every stop logged `AH02818: MPM run
  failed` and exited 1 (case `stop`).
- **State survives the module's reload.** httpd unloads and reloads the MPM between its two config
  passes and on every restart, which reset all of peruser's statics. They're kept with
  `ap_retained_data` now:
  - the generation number is carried on, so children of the old generation are recognised;
  - the two tables' shared memory is released at each load, where two segments leaked per restart;
  - httpd detaches when started without `-DFOREGROUND` (it never did; case `daemon`);
  - ServerLimit is fixed at the first start. A reload with another value warns and keeps the old
    one, where raising it crashed the parent two reloads later. **Changing ServerLimit needs a full
    restart.**
- **Old children are tracked.** At a graceful restart the children still finishing a request go on
  the core's extra-process list. Their exit is no longer "long lost child came home", and a stop
  ends them, where they were left running. Child start and exit are reported to the core
  (`mpm_child_status`), and `AP_MPMQ_GENERATION` is answered (case `reload`).
- **The parent's own socket pairs** are closed from its own list, not through the shared table
  that children can write.

**Configuration**

- **ServerLimit and the scoreboard.** The scoreboard was sized by MaxClients' default (256) and the
  tables by ServerLimit, so a ServerLimit of 10 without MaxClients crashed the parent on stop and
  reload. Both use ServerLimit now, MaxClients defaults to it, and a MaxClients above it is cut
  with a warning (case `limit`).
- **Table sizes.** The tables' control structs were allocated by the size of a pointer;
  ServerLimit 406 and 918 crashed `httpd -t`.
- **A ServerLimit below what's configured** is a config error with a message that says to put it
  before the Processor directives, not an overrun.
- **`MaxSpareProcessors` in a vhost before `ServerEnvironment`** crashed `httpd -t` (case
  `configtest`).
- **ExtendedStatus Off** is overridden with a warning: IdleTimeout and ExpireTimeout read the
  scoreboard's `last_used` (case `extstatus`).
- **Warnings** when MaxSpareProcessors is closer than 3 to MinSpareProcessors (the workers are
  started and stopped in turns), and when ProcessorWaitTimeout's steps are over 100 (cut to 100: the
  step size was 0 and the wait never ended).
- **Processors with different Chroot settings** are no longer merged (and comparing a set one with
  an unset one no longer crashes), and a failed `socketpair()` at config time is an error.

**Smaller**

- **MaxRequestsPerChild counts connections.** It counted wake-ups, and every passed connection
  wakes all of a processor's idle workers, so they were all recycled together after N requests to
  the processor (case `maxreq`).
- A request to start a child that arrives while the parent is starting others isn't lost until the
  next maintenance pass.
- `qsort()`'s compare function returns a real three-way result; four unused functions are gone (two
  of them called `free()` on pool memory).

**Not changed, on purpose**

- **The shared tables stay writable by every child** (child table, environment table, scoreboard).
  A worker whose memory is taken over can still mislead the parent. That needs a redesign: the
  parent's own copy of what it acts on.
- **A graceful restart still isn't graceful for requests being passed:** the tables are new for
  each generation, and for a moment requests are refused. Old children also share scoreboard slots
  with new ones.
- **Keep-alive across vhosts,** ExpireTimeout's meaning, the lock-free counters, and the 1 s sleep
  in a multiplexer after it asks for a new worker.
- **MaxClients** is still not a real cap on processes; ServerLimit is.

## Signals in a starting child (`.8.peruser.dc`)

Up to `.7`, a child's SIGTERM handler (`just_die`) ran `apr_pool_destroy()` and `exit()` inside the
handler, and peruser's parent sends SIGTERM all the time (IdleTimeout, ExpireTimeout, spare
processors). On 2026-11-16 (dcw-ds-1, 05:53–07:11 EET) one landed in `malloc()` inside mod_proxy's
`child_init`. The child deadlocked on malloc's own lock while holding `proxy_mutex`, so every child
started after it waited for that lock, and no site answered until httpd was restarted. Since `.8`:

- `just_die` only calls `_exit(0)`, which is safe in a signal handler. The kernel closes the
  sockets, and the parent marks the slot dead when it reaps the child.
- SIGTERM, SIGHUP and SIGINT are blocked from before `fork()` until the child is ready
  (`SERVER_READY`). Then the main thread lets them in. Threads that `child_init` started, such as
  mod_watchdog's, keep them blocked.
- `determine_child_fate()` never stops a child that is still starting. Its `last_used` is still the
  slot's previous occupant's, so the ExpireTimeout rules took a child started in a slot unused for
  longer than ExpireTimeout for an expired one. When that rule would have fired, the error log says
  `not stopping child #N (pid P, processor X): it is still starting; up to .7 ExpireTimeout ...
  stopped it here`.
- A ready child sets its own `last_used`. The scoreboard does that only with ExtendedStatus On.

`startup-hang-test.sh --mode kill` reproduces the outage on `.6`. An LD_PRELOAD `fork()` wrapper
(`startup-hang-forkterm.c`) sends a SIGTERM to a share of the new children 0–5 ms after the fork,
and a hang detector backtraces the lock owner. `--mode expire` logs the parent's own kills with
strace and matches them against each child's age.

## Directives added in this fork

- **`ProcessorPassTimeout <seconds>`** (`.7.peruser.dc`, default 5, server config): how long a
  multiplexer waits to hand a request to a processor whose socket is full because no copy of it reads
  (all hung). Then that processor's requests get a 503 at once for as long again, and the next one
  after that tries again. The error log says `Processor X took no request for N s` once per stop and
  `Processor X takes requests again` when it recovers. `0` waits forever, as before `.7`: there, on
  2026-11-16, one hung tenant blocked every multiplexer in `sendmsg()` and no site on the server
  answered. Messages over ~32 KB (very large headers) are still sent blocking, so the stream to the
  processor never holds half a message. `pass-timeout-test.sh` shows the outage on `.6` and the fix.

---

## Quick start — Production build

Run a single end-to-end RPM build using Docker:

```bash
cd src/
./build-rpm.sh                # el9 (default)
EL_VERSION=10 ./build-rpm.sh  # el10
```

RPMs are written to `src/output/el9/RPMS/` or `src/output/el10/RPMS/` (matching
`EL_VERSION`, the source RPM to `SRPMS/` beside it) when the build succeeds.

---

## Development Workflow — iterative patch debugging

When actively modifying the peruser patch
(`src/peruser-2.4-httpd24-fix.patch`), it is much faster to iterate locally
rather than triggering a full GitHub Actions run for every change.

The `dev-build-loop.sh` script provides an interactive compile-test-fix loop:

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- The repository checked out locally

### How it works

1. Builds (or reuses) a **Rocky Linux** container matching `EL_VERSION`
   (`9` by default, `10` if set) that mirrors the corresponding CI matrix
   leg exactly.
2. Mounts the `src/` directory into the container as `/src` so that every
   edit you make on the host is immediately available inside the container.
3. Runs `rpmbuild -ba` in a loop:
   - **On failure** — shows the compiler/patch error and waits for you.
   - **On success** — copies the finished RPMs to `src/output/el${EL_VERSION}/`
     and exits.

### Step-by-step workflow

```bash
# 1. Start the interactive build loop (run from the repo root or from src/)
./src/dev-build-loop.sh                # el9 (default)
EL_VERSION=10 ./src/dev-build-loop.sh   # el10

# The script builds the container image on the first run (takes a few minutes).
# Subsequent runs reuse the cached image and are much faster. el9 and el10
# use separately-named images/containers, so you can iterate on both without
# them clobbering each other's cache.

# 2. The script runs rpmbuild. If the patch fails to apply or the code does
#    not compile, you will see output like:
#
#   ============================================
#     BUILD FAILED (attempt #1)
#   ============================================
#   Edit the patch file to fix the error, then press Enter to retry.
#     Patch file: /path/to/src/peruser-2.4-httpd24-fix.patch

# 3. Open another terminal (or editor) and fix the patch:
#    - Correct the offending hunk
#    - Adjust context lines if the upstream source has changed
#    - Add or remove lines as needed

# 4. Press Enter in the first terminal to retry. The script copies the
#    freshly edited patch into the container and runs rpmbuild again.

# 5. Repeat steps 3–4 until the build succeeds:
#
#   ============================================
#     BUILD SUCCEEDED on attempt #3
#   ============================================
#   Build artifacts saved to: /path/to/src/output

# 6. Commit your changes and push to GitHub to trigger the full CI workflow.
git add src/peruser-2.4-httpd24-fix.patch
git commit -m "fix: patch applies and compiles against httpd 2.4.62"
git push
```

### Useful tips

- The error output is streamed live — look for lines starting with `error:`
  or `patch: ***` to identify exactly which hunk failed.
- You can leave the loop running across multiple editing sessions; press
  `Ctrl+C` at any time to stop and clean up the container.
- The development container is named `httpd-peruser-dev-el9` (or
  `-el10`). If something goes wrong you can inspect it directly:
  ```bash
  docker exec -it httpd-peruser-dev-el9 bash
  ```
- Build artifacts (SRPM and RPM) are copied to `src/output/el${EL_VERSION}/`
  on success. The `src/output/` directory is listed in `.gitignore` and will
  not be committed.

---

## Agent-Driven Compile Loop (Codespaces)

If you use the **Copilot coding agent** to fix the peruser patch, you can ask
it to iterate autonomously until the build succeeds — no more saying "fix it
again" repeatedly.

### How it works

1. The agent opens the repository in a **GitHub Codespace** (which has Docker
   support via the included `.devcontainer/devcontainer.json`).
2. It runs `./src/agent-build-loop.sh` (optionally `EL_VERSION=10 ./src/agent-build-loop.sh`)
   — a non-interactive build script that:
   - Runs the full RPM build in a Rocky Linux (el9 or el10) Docker container
   - Exits `0` on success, non-zero on failure
   - Outputs clear markers (`=== BUILD SUCCEEDED ===`, `=== BUILD FAILED ===`,
     `=== PATCH ERROR ===`, `=== COMPILE ERROR ===`)
3. If the build fails, the agent reads the error, edits
   `src/peruser-2.4-httpd24-fix.patch`, and runs the script again.
4. Once the build succeeds, the agent commits and updates the PR.

### Prompt to give the agent

> "Fix the peruser-2.4-httpd24-fix.patch until it compiles successfully.
> Follow the instructions in AGENT_INSTRUCTIONS.md.
> Run ./src/agent-build-loop.sh to test each fix.
> Keep iterating until the build succeeds, then commit."

The agent will autonomously loop through fix → build → check → fix until done.

### Prerequisites

- A GitHub Codespace for this repository (Docker-in-Docker is pre-configured)
- Or any machine with Docker installed (the script works the same way)

---

## CI / GitHub Actions

The full workflow (`.github/workflows/build-rpm.yml`) runs automatically on
every push to `main`/`master` and on pull requests. Both `build-rpm` and
`test-rpm` run as a **matrix across el9 and el10** (`rockylinux:9` and
`rockylinux/rockylinux:10` containers respectively — note the el10 image
lives under a different Docker Hub namespace than el8/el9). Each leg:

1. Installs build dependencies on the matrix's Rocky Linux container.
2. Builds the SRPM (`rpmbuild -bs`).
3. Builds the RPM from the SRPM (`rpmbuild --rebuild`).
4. Uploads SRPM and RPM packages as workflow artifacts, suffixed per leg
   (`srpm-el9`/`srpm-el10`, `rpms-el9`/`rpms-el10`, etc.) so the two legs
   don't collide.
5. `test-rpm` installs the matching leg's built RPM and runs the peruser
   MPM functional test (multi-user process check, HTTP smoke test, crash
   detection with gdb).

Use the local dev build loop during patch development (set `EL_VERSION` to
target either release), then push once the build is clean to let the full CI
matrix verify and package the result for both el9 and el10.
