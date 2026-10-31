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
│   └── agent-build-loop.sh           # Non-interactive build script (agent use)
└── README.md                         # This file
```

---

## Quick start — Production build

Run a single end-to-end RPM build using Docker:

```bash
cd src/
./build-rpm.sh                # el9 (default)
EL_VERSION=10 ./build-rpm.sh  # el10
```

RPMs are written to `src/output/el9/` or `src/output/el10/` (matching
`EL_VERSION`) when the build succeeds.

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
