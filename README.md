# httpd peruser MPM — RPM Build for Rocky Linux 9

This repository builds a patched Apache HTTP Server (`httpd`) RPM for
**Rocky Linux 9** that includes the **peruser MPM** (Multi-Processing Module).
The peruser MPM allows Apache to run each virtual host under a separate system
user, improving isolation and security in shared-hosting scenarios.

## Repository layout

```
.
├── .github/workflows/build-rpm.yml   # Full CI/CD pipeline (GitHub Actions)
├── src/                              # All source files, patches, and build scripts
│   ├── httpd.spec                    # RPM spec file
│   ├── peruser-2.4-httpd24-fix.patch # Main peruser MPM patch
│   ├── httpd-2.4.62.tar.bz2         # Apache source tarball
│   ├── Dockerfile.rpmbuild           # Production Docker build image
│   ├── build-rpm.sh                  # One-shot Docker build script
│   ├── Dockerfile.devbuild           # Development build image (Rocky Linux 9)
│   ├── build-rpm-dev.sh              # In-container build script (dev loop)
│   └── dev-build-loop.sh             # Interactive dev build loop (see below)
└── README.md                         # This file
```

---

## Quick start — Production build

Run a single end-to-end RPM build using Docker:

```bash
cd src/
./build-rpm.sh
```

RPMs are written to `src/output/` when the build succeeds.

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

1. Builds (or reuses) a **Rocky Linux 9** container that mirrors the CI
   environment exactly.
2. Mounts the `src/` directory into the container as `/src` so that every
   edit you make on the host is immediately available inside the container.
3. Runs `rpmbuild -ba` in a loop:
   - **On failure** — shows the compiler/patch error and waits for you.
   - **On success** — copies the finished RPMs to `src/output/` and exits.

### Step-by-step workflow

```bash
# 1. Start the interactive build loop (run from the repo root or from src/)
./src/dev-build-loop.sh

# The script builds the container image on the first run (takes a few minutes).
# Subsequent runs reuse the cached image and are much faster.

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
- The development container is named `httpd-peruser-dev`. If something goes
  wrong you can inspect it directly:
  ```bash
  docker exec -it httpd-peruser-dev bash
  ```
- Build artifacts (SRPM and RPM) are copied to `src/output/` on success.
  The `src/output/` directory is listed in `.gitignore` and will not be
  committed.

---

## CI / GitHub Actions

The full workflow (`.github/workflows/build-rpm.yml`) runs automatically on
every push to `main`/`master` and on pull requests. It:

1. Installs build dependencies on a Rocky Linux 9 runner.
2. Builds the SRPM (`rpmbuild -bs`).
3. Builds the RPM from the SRPM (`rpmbuild --rebuild`).
4. Uploads SRPM and RPM packages as workflow artifacts.

Use the local dev build loop during patch development, then push once the
build is clean to let the full CI pipeline verify and package the result.
