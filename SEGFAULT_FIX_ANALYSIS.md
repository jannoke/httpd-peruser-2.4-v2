# Segmentation Fault Analysis and Fix

## Problem Statement
Apache HTTP Server with peruser MPM module was experiencing segmentation faults when making requests. Workflow run #32 produced debug artifacts including a core dump and backtrace showing repeated child process crashes.

## Root Cause Analysis

### Crash Details from Debug Artifacts

**Backtrace Information:**
```
Program terminated with signal SIGSEGV, Segmentation fault.
#0  0x0000000000000000 in ?? ()
#1  0x00005582102b5fbd in ap_reclaim_child_processes ()
#2  0x00007febe9a8378b in peruser_run () from /etc/httpd/modules/mod_mpm_peruser.so
#3  0x00005582102aea08 in ap_run_mpm ()
#4  0x000055821029c6cb in main ()
```

**Error Log Evidence:**
```
[Mon Mar 09 09:33:41.657477 2026] [core:notice] [pid 465:tid 465] AH00052: child pid 474 exit signal Segmentation fault (11)
[Mon Mar 09 09:33:43.664392 2026] [core:notice] [pid 465:tid 465] AH00052: child pid 476 exit signal Segmentation fault (11)
... (multiple similar entries)
[Mon Mar 09 09:34:33.775089 2026] [:notice] [pid 465:tid 465] seg fault or similar nasty error detected in the parent process
```

### Technical Root Cause

The crash occurs at memory address `0x0000000000000000` (NULL pointer), which indicates an attempt to execute code through a NULL function pointer.

**Apache API Change:**
- **Apache 2.4.0 - 2.4.30**: `ap_reclaim_child_processes(int terminate)`
- **Apache 2.4.43+**: `ap_reclaim_child_processes(int terminate, ap_mpm_run_maint_fn maint_fn)`

The old peruser patch (`peruser-040-rc3-full-v16-69-kafix.patch`) was calling this function with only one parameter:
```c
ap_reclaim_child_processes(1); /* Start with SIGTERM */
ap_reclaim_child_processes(0); /* Not when just starting up */
```

When compiled with Apache 2.4.62, the second parameter (a function pointer for maintenance callback) was left uninitialized, containing garbage or NULL. When Apache tried to call this function pointer, it crashed.

## The Fix

The corrected patch (`peruser-2.4-httpd24-fix.patch`) properly provides both parameters:

```c
ap_reclaim_child_processes(1, NULL); /* Start with SIGTERM */
ap_reclaim_child_processes(0, NULL); /* Not when just starting up */
```

**Why NULL is safe:**
The peruser MPM module handles all child process maintenance internally through its own `perform_idle_server_maintenance()` function. It doesn't need an external maintenance callback, so passing `NULL` is the correct approach.

### Additional API Updates in Fixed Patch

The fixed patch also includes other necessary API updates:
- `unixd_killpg()` → `ap_unixd_killpg()` (Apache 2.4 API namespace change)
- Addition of `AP_STATUS_PERUSER_STATS` for extended status reporting
- Improved pod (pipe-of-death) initialization

## Files Involved

### Patch Files
1. **peruser-040-rc3-full-v16-69-kafix.patch** (OLD - CAUSES CRASH)
   - Line 3714: `ap_reclaim_child_processes(1);` ❌
   - Line 3806: `ap_reclaim_child_processes(0);` ❌

2. **peruser-2.4-httpd24-fix.patch** (NEW - CORRECT)
   - Line 3588: `ap_reclaim_child_processes(1, NULL);` ✅
   - Line 3680: `ap_reclaim_child_processes(0, NULL);` ✅

### Configuration
- **src/httpd.spec** (Line 111): Correctly references `Patch300: peruser-2.4-httpd24-fix.patch`
- **src/httpd.spec** (Line 273): Applies patch with `%patch300 -p1 -b .peruser`

## Signal Handling Context

The crashes occur during signal handling in `peruser_run()`:

1. **SIGTERM handling** (shutdown):
   - Sends SIGTERM to all child processes
   - Calls `ap_reclaim_child_processes(1, NULL)` to wait for children to exit
   
2. **SIGHUP handling** (graceful restart):
   - Sends SIGHUP to all child processes  
   - Calls `ap_reclaim_child_processes(0, NULL)` for graceful restart

## Verification

The current codebase already uses the correct patch. The httpd.spec file at line 111 references:
```spec
Patch300: peruser-2.4-httpd24-fix.patch
```

This patch is properly applied during the build process, ensuring compatibility with Apache 2.4.62 and preventing the segmentation fault.

## References

- Debug artifacts from workflow run #32
- Core dump analysis: `core.httpd.465`
- Backtrace: `backtrace.txt`
- Error logs: `error_log`
- Configuration: `peruser.conf`, `00-mpm.conf`
