# Agent Instructions: Autonomous Patch Fixing

This file provides instructions for the Copilot coding agent to autonomously
fix the peruser MPM patch until the RPM builds successfully.

---

## Your Goal

Fix `src/peruser-2.4-httpd24-fix.patch` so that the RPM build completes
without errors. Iterate until the build succeeds, then commit.

---

## The Build Script

**Script**: `./src/agent-build-loop.sh`

- Runs the full RPM build inside a Docker container (Rocky Linux 9)
- Exits with code **0** on success, **non-zero** on failure
- Outputs clear markers you can parse:
  - `=== BUILD SUCCEEDED ===` — done, commit and push
  - `=== BUILD FAILED ===` — fix the patch and retry
  - `=== PATCH ERROR ===` — the patch did not apply cleanly
  - `=== COMPILE ERROR ===` — patch applied but C code has errors

---

## Your Workflow

```
1. Run: ./src/agent-build-loop.sh
2. Check the exit code and look for the markers above.
3. If BUILD FAILED:
   a. Read the error section carefully (PATCH ERROR or COMPILE ERROR).
   b. Edit src/peruser-2.4-httpd24-fix.patch to fix the problem.
   c. Go back to step 1.
4. If BUILD SUCCEEDED:
   a. Commit the fixed patch.
   b. Push / update the PR.
```

---

## How to Read Build Errors

### Patch errors (`=== PATCH ERROR ===`)

Look for output like:
```
Hunk #3 FAILED at 1234.
1 out of 3 hunks FAILED -- saving rejects to file mod_mpm_peruser.c.rej
```

**What this means**: The context lines in the patch hunk no longer match the
upstream source file. The C source around that area has changed.

**How to fix**:
1. Note which hunk number and which file failed.
2. Look at the `.rej` file path (e.g. `mod_mpm_peruser.c.rej`).
3. Find that hunk in `src/peruser-2.4-httpd24-fix.patch`.
4. Adjust the context lines (`' '`-prefixed lines) to match the actual source.
5. The target file is `httpd-2.4.62/modules/mpm/mod_mpm_peruser.c` (or
   whichever file is listed in the patch `---`/`+++` headers).

### Compiler errors (`=== COMPILE ERROR ===`)

Look for output like:
```
mod_mpm_peruser.c:1234: error: 'ap_mpm_run_maint_fn' undeclared
mod_mpm_peruser.c:567: error: too many arguments to function 'ap_reclaim_child_processes'
```

**What this means**: The C API in the upstream httpd version differs from what
the patch assumes.

**How to fix**:
1. Identify the function/type name that changed.
2. Check the Apache httpd 2.4.62 headers in `include/` or look at the upstream
   worker/prefork MPM for the correct calling convention.
3. Edit the `+`-prefixed lines (added code) in the relevant hunk of
   `src/peruser-2.4-httpd24-fix.patch` to match the correct API.

---

## Common Patch Issues and Fixes

### 1. Hunk offset / fuzz

Symptom: `Hunk #N succeeded at NNNN with fuzz N.`

This is a warning, not an error. The patch applied but at a slightly different
line number. No action required unless the build later fails.

### 2. `ap_reclaim_child_processes` signature change

Apache 2.4.43 changed the signature (current target 2.4.62 uses the new form):
```c
// Old (pre-2.4.43, for reference only — not applicable to 2.4.62):
ap_reclaim_child_processes(int terminate);

// New (2.4.43+, required for httpd 2.4.62):
ap_reclaim_child_processes(int terminate, ap_mpm_run_maint_fn callback);
```

Fix: pass a valid callback (or `NULL` only if the httpd version accepts it).
See `server/mpm/worker/worker.c` in the upstream source for the reference
implementation (`worker_note_child_killed`).

### 3. Missing or renamed struct fields

Symptom: `error: 'struct ap_mpm_t' has no member named 'xxx'`

Fix: Check the struct definition in `include/ap_mpm.h` in the upstream source
and update the `+`-lines in the patch accordingly.

### 4. Implicit function declaration

Symptom: `warning: implicit declaration of function 'foo'`

Fix: Add the appropriate `#include` directive in the `+`-lines of the patch,
or check whether the function has been renamed.

---

## Key Files

| File | Purpose |
|------|---------|
| `src/peruser-2.4-httpd24-fix.patch` | **The patch to fix** — this is what you edit |
| `src/agent-build-loop.sh` | Build script — run this to test your fix |
| `src/httpd.spec` | RPM spec — shows how the patch is applied (`%patch300`) |
| `src/Dockerfile.devbuild` | Rocky Linux 9 build container definition |
| `src/build-rpm-dev.sh` | In-container build script (called by agent-build-loop.sh) |

---

## Important Notes

- **Do NOT edit** `src/httpd.spec`, `src/Dockerfile.devbuild`, or
  `src/build-rpm-dev.sh` unless you have a specific reason to do so.
- **Only edit** `src/peruser-2.4-httpd24-fix.patch` to fix patch/compile errors.
- The patch is applied with `patch -p1`, so paths in the patch headers start
  with the top-level directory (e.g. `httpd-2.4.62/modules/mpm/...`).
- Patch hunks use the unified diff format: `-` lines are removed, `+` lines
  are added, and ` ` (space) lines are context.
- The build runs inside a container, so you cannot interactively inspect files.
  Read the error output carefully — it is your only signal.

---

## Done Criteria

The task is complete when `./src/agent-build-loop.sh` exits with code 0 and
prints `=== BUILD SUCCEEDED ===`. At that point:

1. Commit: `git add src/peruser-2.4-httpd24-fix.patch`
2. Commit message: `fix: patch applies and compiles against httpd 2.4.62`
3. Push to update the PR.
