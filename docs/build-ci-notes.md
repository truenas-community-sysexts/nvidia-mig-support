# Build / CI notes

Reasoning behind non-obvious CI decisions that aren't self-evident from the workflow YAML. Living document; update when a decision changes.

## Runner selection: hardcoded `ubuntu-24.04`, not dynamic

The sister repo [hailo8-support](https://github.com/truenas-community-sysexts/hailo8-support) resolves its runner image dynamically — it fetches TrueNAS's `GITMANIFEST`, looks up the pinned `truenas-build` commit, reads `debian_release` from `conf/build.manifest`, and maps it to an Ubuntu runner via [`.github/scripts/resolve-runner.sh`](https://github.com/truenas-community-sysexts/hailo8-support/blob/main/.github/scripts/resolve-runner.sh).

We considered porting that pattern when scoping Phase 2 of the CI refactor and **chose not to**. The hailo mapping enforces *runner GLIBC ≤ target GLIBC*. That rule exists because hailo compiles `libhailort.so` on the runner and ships it into the target sysext — if the runner's GLIBC is newer than the target's, the resulting binary will fail to load on TrueNAS at install time.

That constraint does not apply here:

- **Kernel modules don't link GLIBC.** `nvidia.ko` is a kernel module; it links against the kernel's internal ABI, not libc.
- **NVIDIA's userspace `.so` files are pre-built by NVIDIA**, extracted from the `.run` blob, and copied into the sysext as-is. They are not re-linked on the runner, so runner GLIBC is irrelevant to what ships.

Mapping `bookworm → ubuntu-22.04` (hailo's answer for TrueNAS 25.x) would therefore solve a problem we don't have. Worse: it would *create* a problem — [`scripts/build-nvidia-sysext.sh`](../scripts/build-nvidia-sysext.sh) requires `gcc-14` (or any gcc supporting `-fmin-function-alignment=16`), which ubuntu-22.04 does not ship in default repos. ubuntu-24.04 does.

The constraint that *does* matter for nvidia is "the runner has a modern enough GCC to build kernel modules for the target kernel." Today that means gcc-13+ (anything supporting `-fmin-function-alignment=16`). Tomorrow it might be gcc-15. Ubuntu-24.04 satisfies today's requirement comfortably and will for a while.

**A nvidia-specific dynamic mapper could be sound** — keyed off "what GCC does the target kernel need" → "what is the oldest Ubuntu image that ships it" — but the answer has been "ubuntu-24.04" for years and will be for years, so building that mapper now is YAGNI.

**When to revisit:** if any of these change, re-evaluate.

1. TrueNAS rebases onto a kernel that needs a build flag ubuntu-24.04's gcc-14 cannot provide.
2. GitHub deprecates ubuntu-24.04 runner images.
3. We start compiling nvidia userspace components from source on the runner (would re-introduce the GLIBC concern).

## Caching: `.update` file only (for now)

[`build-nvidia-sysext.sh`](../scripts/build-nvidia-sysext.sh) downloads three large things:

1. The TrueNAS `.update` file (~1–3 GB) — keyed on `truenas_version`.
2. The NVIDIA `.run` driver blob (~400 MB) — keyed on `nvidia_version`.
3. Kernel headers, extracted from the `.update`'s rootfs squashfs — keyed on `truenas_version`.

Phase 2 caches only the `.update` file because that's the largest download and the build script already supports loading it from a known path via `--update-file=`.

The other two are deferred:

- The **NVIDIA `.run` cache** is held back because the build script `rm -rf`'s its build dir at start (line ~157), so a cache restore would be wiped before the existence check at line ~271 ever runs. Caching this cleanly needs a small script change — a `--nvidia-run-file=` flag mirroring `--update-file=`. Worth it as a follow-up; not in Phase 2's scope.
- The **kernel-headers cache** is held back because the extraction is fast relative to the `.update` download and adds non-trivial step complexity (needs a `.real-kver` marker file to detect layout changes between TrueNAS minor versions).

## Why a separate `resolve` job

The build workflow is split into `resolve` (`ubuntu-latest`, lightweight) and `build` (`ubuntu-24.04`, expensive). Three reasons:

1. **Single source of truth for defaults.** `resolve` reads `.github/tracked-versions.json` and applies user inputs on top. The `build` job and any downstream consumer get one consistent view.
2. **Cheap visibility.** When `resolve` fails (e.g., malformed tracked-versions, missing input), CI fails in ~30 seconds without spinning up a build runner.
3. **Phase 4 prerequisite.** The forthcoming `check-releases.yml` will invoke this workflow via `workflow_call`. The resolve/build split lets that caller pass values directly into `resolve`'s outputs without having to mirror logic.
