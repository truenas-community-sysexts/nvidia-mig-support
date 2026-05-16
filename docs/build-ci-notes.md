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

## Release tagging scheme

**Every release is immutable.** No rolling tags. This is forced by the repo-level "Immutable releases" setting — once a release is created, its tag and assets cannot be modified or deleted. A rolling `dev-*` tag pattern was tried in Phase 3 and immediately failed (`Cannot delete asset from an immutable release`); the design now mirrors hailo8-support's, which solved this same problem first.

Tag formats:

- **`v<truenas>-nvidia<driver>-r<run>`** — produced by `build-nvidia-sysext.yml`
- **`v<truenas>-mig-r<run>`** — produced by `build-mig-sysext.yml`

The `-r<run>` suffix is `github.run_number` — monotonic per workflow, unique across retries on the same commit. So every workflow invocation gets a fresh, never-before-used tag, and `softprops/action-gh-release` can create the release cleanly without ever needing to delete or update an existing one.

The `make_latest` GitHub flag is what users pin to, not a tag name. Two sources can produce releases:

- **Manual `workflow_dispatch`** — defaults `mark_latest=true`. Promotes the new release to GitHub "Latest" immediately. The intent is: a human ran this, it's intentional, surface it as the new default.
- **Phase 4 `workflow_call` from `check-releases.yml`** (not yet built) — will pass `mark_latest=false`. Auto-builds get a release but don't displace the existing Latest until a hardware-test issue is resolved.

How the install scripts find the right release: detect local TrueNAS version via `midclt call system.info`, query `/repos/.../releases`, filter by `v<version>-nvidia` (or `-mig-`) prefix, pick the most-recently-published. See `resolve_release_tag()` in [`scripts/install-nvidia-sysext.sh`](../scripts/install-nvidia-sysext.sh).

Tag schema choices worth noting:

- **MIG tag includes TrueNAS version** even though `nvidia-mig.raw` content is TrueNAS-version-independent. The version is consumer context — it tells the user which TrueNAS release this MIG build pairs with, and it's also what the install script's prefix-match needs.
- **No commit SHA in the tag.** Tags would get ugly (`v25.10.3.1-mig-abc1234-r12345`) and run_number already provides uniqueness. The commit SHA is recorded in the release notes.
- **No `push: main` trigger on the build workflows.** Push-triggered builds are what produced the `dev-*` tag-burn failure. Builds now only happen on intentional triggers (manual dispatch, future check-releases auto-bumps) — same model as hailo.

## Why a separate `resolve` job

The build workflow is split into `resolve` (`ubuntu-latest`, lightweight) and `build` (`ubuntu-24.04`, expensive). Three reasons:

1. **Single source of truth for defaults.** `resolve` reads `.github/tracked-versions.json` and applies user inputs on top. The `build` job and any downstream consumer get one consistent view.
2. **Cheap visibility.** When `resolve` fails (e.g., malformed tracked-versions, missing input), CI fails in ~30 seconds without spinning up a build runner.
3. **Cron-friendly.** The check-releases workflow uses `createWorkflowDispatch` to fire the build with explicit version inputs; `resolve` then computes the final tag and notes from those inputs without re-fetching anything.

## Auto-cadence: `check-releases.yml`

Daily cron at 06:00 UTC polls upstream version pointers and fires a build when anything changes. The flow:

1. **Read** `.github/tracked-versions.json` for the currently-tracked TrueNAS + NVIDIA values.
2. **Check TrueNAS:** highest stable tag in `truenas/scale-build`, gated on (a) the train being discoverable in the `download.truenas.com/` listing for that version, and (b) the matching `.update` file actually being downloadable. Tags can land hours before the `.update` is mirrored — the gate avoids bumping into a half-published state.
3. **Check NVIDIA:** `https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt` advertises a single `<version> <run-file-path>` line. We accept whatever it says (no branch cap, no Frigate-style pin) — we follow NVIDIA's "latest" verbatim, currently whichever branch their CDN promotes. If that turns out to be too aggressive, the cap belongs here, not in the build.
4. **Commit + push** the in-place update to `tracked-versions.json` (default `GITHUB_TOKEN` is sufficient because main is unprotected on this repo; if a ruleset is added later, swap to a PAT — see the comment at the top of `check-releases.yml`).
5. **Dispatch builds** via `actions/github-script` + `createWorkflowDispatch`:
   - `build-nvidia-sysext.yml` whenever **either** TrueNAS or NVIDIA changed (full driver is parameterized by both).
   - `build-mig-sysext.yml` only on TrueNAS bumps (MIG content doesn't depend on NVIDIA driver version).
   Both are dispatched with `mark_latest='false'`.

## Hardware-test issue auto-creation

When a build runs with `mark_latest=false` (the auto-cadence case), the build workflow creates a GitHub issue labeled `hardware-test`. The issue links to the new release and carries a per-build checklist (install, verify driver/MIG works, reboot test, then "Set as latest" + close).

`mark_latest=false` is the gate. A human verifies on real hardware, clicks **Set as latest** on the release page, then closes the issue. The default for manual `workflow_dispatch` is `mark_latest=true` — intentional human builds are promoted immediately, no issue is created.

Label / issue creation is idempotent: existing labels return 422 (handled), and if an open `hardware-test` issue already mentions the release tag in its title, the step skips the duplicate creation. So manually re-triggering an auto-build won't spam the tracker.

Promotion to "Latest" can't be done automatically — it requires human acknowledgement that hardware verification passed. The flag and the issue together encode that pre-merge / post-merge gate.

## MIG packaging: bundled vs standalone

NVIDIA's MIG tooling (`configure-mig`, `nvidia-mig-setup.service`, the MIG setup binary) can ship two ways:

| Path | Sysext | When |
| --- | --- | --- |
| **Bundled** (default) | Inside `nvidia.raw` (full-driver build with `BUNDLE_MIG=true`) | You're replacing TrueNAS's stock NVIDIA driver with a custom build (typical for users on Blackwell GPUs needing a newer driver than stock ships). |
| **Standalone** | Inside `nvidia-mig.raw` (the lightweight sysext) | You're keeping TrueNAS's stock driver and just adding MIG capability on top. |

Both paths produce a working MIG install. They differ only in which sysext owns the MIG bits:

- **Bundled** is what `workflow_dispatch` on `build-nvidia-sysext.yml` does by default (`bundle_mig` input defaults to `true`). The full-driver sysext gets `configure-mig` plus the service, no separate sysext needed. If you've installed via `install-nvidia-sysext.sh`, you're on this path. Running `install-mig-sysext.sh --check` against this state reports `MIG tooling provided by bundled full-driver sysext (nvidia.raw built with BUNDLE_MIG=true) — separate MIG sysext not needed`.
- **Standalone** is the right call when stock TrueNAS already ships a driver new enough for your hardware and you just want MIG support on top of it. Build via `build-mig-sysext.yml` (always produces `nvidia-mig.raw`, no `BUNDLE_MIG` knob). Install via `install-mig-sysext.sh`, which refuses to run if stock driver < `MIN_DRIVER_MAJOR` (570 today).

What this means for the release line:

- Every `build-nvidia-sysext.yml` dispatch produces *one* `v<truenas>-nvidia<driver>-r<run>` release. The release notes say `MIG bundled: true|false` — by default `true`. If you want a non-bundled full-driver release for some reason, dispatch with `bundle_mig=false`.
- Every `build-mig-sysext.yml` dispatch produces *one* `v<truenas>-mig-r<run>` release. There's no bundled-vs-standalone variant on this one — it's always the standalone path.

What this does *not* mean: you do not need to install both. Pick one path. Running both leads to two sysexts trying to provide MIG tooling — the merge order is undefined and the install scripts intentionally don't try to detect this misconfiguration (it would require teaching each script about the other's persistent state).

`bundle_mig` is **kept** in the workflow input list rather than removed because there are legitimate cases for the unbundled full-driver release: someone wants the stock TrueNAS MIG flow but a newer NVIDIA driver, or someone is debugging a MIG-tooling issue and wants the install scripts to refuse to layer the standalone sysext on top. Flag stays; default stays `true`.
