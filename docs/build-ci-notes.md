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

Tag format:

- **`v<truenas>-nvidia<driver>-r<run>`** — produced by `build-sysext.yml`. Carries **both** `nvidia.raw` (driver-only) and `nvidia-mig.raw` (MIG tooling) as assets attached to a single release.

The `-r<run>` suffix is `github.run_number` — monotonic per workflow, unique across retries on the same commit. So every workflow invocation gets a fresh, never-before-used tag, and `softprops/action-gh-release` can create the release cleanly without ever needing to delete or update an existing one.

The `make_latest` GitHub flag is what users pin to, not a tag name. Two sources can produce releases:

- **Manual `workflow_dispatch`** — defaults `mark_latest=true`. Promotes the new release to GitHub "Latest" immediately. The intent is: a human ran this, it's intentional, surface it as the new default.
- **`workflow_call` from `check-releases.yml`** — passes `mark_latest=false`. Auto-builds get a release but don't displace the existing Latest until a hardware-test issue is resolved.

How `install-mig-sysext.sh` finds the right release: detect local TrueNAS version via `midclt call system.info`, query `/repos/.../releases`, filter by `v<version>-nvidia` prefix, pick the most-recently-published. The release exposes both assets; the install script picks which one(s) to download based on whether `--with-driver` is passed. See `resolve_release_tag()` in [`scripts/install-mig-sysext.sh`](../scripts/install-mig-sysext.sh).

Tag schema choices worth noting:

- **One tag, two assets.** Earlier iterations of this repo produced separate `v<truenas>-mig-r<run>` releases for the lightweight path; the model changed when we collapsed onto a single install script (`install-mig-sysext.sh`) with a `--with-driver` flag. One release carrying both assets lines up with one install operation per host.
- **NVIDIA-only bumps still rebuild `nvidia-mig.raw`.** The MIG asset is TrueNAS-version-parameterized for tag/context only — its content doesn't depend on the NVIDIA driver version. On NVIDIA-only `check-releases` bumps we still rebuild it and attach it to the new tag; content is byte-equivalent to the previous build at this TrueNAS version. We accept that small inefficiency to keep the release model simple (no conditional asset attachment).
- **No commit SHA in the tag.** Tags would get ugly (`v25.10.3.1-nvidia595.58.03-abc1234-r12345`) and run_number already provides uniqueness. The commit SHA is recorded in the release notes.
- **No `push: main` trigger on the build workflow.** Push-triggered builds are what produced the `dev-*` tag-burn failure on earlier iterations. Builds now only happen on intentional triggers (manual dispatch, check-releases auto-bumps) — same model as hailo.

## Why a separate `resolve` job

The build workflow is split into `resolve` (`ubuntu-latest`, lightweight), two parallel build jobs `build-nvidia` and `build-mig` (`ubuntu-24.04`, the expensive ones — `build-nvidia` is ~8 min, `build-mig` is ~30 s), and a `publish` job. Three reasons for the split:

1. **Single source of truth for defaults.** `resolve` reads `.github/tracked-versions.json` and applies user inputs on top. Both build jobs and the publish job consume the same outputs — no risk of divergence.
2. **Cheap visibility.** When `resolve` fails (e.g., malformed tracked-versions, missing input), CI fails in ~30 seconds without spinning up a build runner.
3. **Cron-friendly.** The check-releases workflow uses `createWorkflowDispatch` to fire the build with explicit version inputs; `resolve` then computes the final tag and notes from those inputs without re-fetching anything.

The two build jobs run in parallel because they share no inputs beyond the resolved parameters. If `build-nvidia` fails, `build-mig` still produces its artifact (and vice versa) — but the `publish` job depends on both, so a partial failure means no release is published. That's the right tradeoff: we never want a release that's missing one of the two assets that `install-mig-sysext.sh` expects.

## Auto-cadence: `check-releases.yml`

Daily cron at 06:00 UTC polls upstream version pointers and fires a build when anything changes. The flow:

1. **Read** `.github/tracked-versions.json` for the currently-tracked TrueNAS + NVIDIA values.
2. **Check TrueNAS:** highest stable tag in `truenas/scale-build`, gated on (a) the train being discoverable in the `download.truenas.com/` listing for that version, and (b) the matching `.update` file actually being downloadable. Tags can land hours before the `.update` is mirrored — the gate avoids bumping into a half-published state.
3. **Check NVIDIA:** `https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt` advertises a single `<version> <run-file-path>` line. We accept whatever it says (no branch cap, no Frigate-style pin) — we follow NVIDIA's "latest" verbatim, currently whichever branch their CDN promotes. If that turns out to be too aggressive, the cap belongs here, not in the build.
4. **Commit + push** the in-place update to `tracked-versions.json` (default `GITHUB_TOKEN` is sufficient because main is unprotected on this repo; if a ruleset is added later, swap to a PAT — see the comment at the top of `check-releases.yml`).
5. **Dispatch the build** via `actions/github-script` + `createWorkflowDispatch`: a single call to `build-sysext.yml` whenever **either** TrueNAS or NVIDIA changed, with `mark_latest='false'`. The unified workflow produces both assets under one tag. NVIDIA-only bumps re-attach a content-equivalent `nvidia-mig.raw` (see the "Tag schema choices" notes above).

## Hardware-test issue auto-creation

When a build runs with `mark_latest=false` (the auto-cadence case), the build workflow creates a GitHub issue labeled `hardware-test`. The issue links to the new release and carries a per-build checklist (install, verify driver/MIG works, reboot test, then "Set as latest" + close).

`mark_latest=false` is the gate. A human verifies on real hardware, clicks **Set as latest** on the release page, then closes the issue. The default for manual `workflow_dispatch` is `mark_latest=true` — intentional human builds are promoted immediately, no issue is created.

Label / issue creation is idempotent: existing labels return 422 (handled), and if an open `hardware-test` issue already mentions the release tag in its title, the step skips the duplicate creation. So manually re-triggering an auto-build won't spam the tracker.

Promotion to "Latest" can't be done automatically — it requires human acknowledgement that hardware verification passed. The flag and the issue together encode that pre-merge / post-merge gate.

## Driver vs MIG: separation of concerns

The two sysexts the build produces are deliberately scoped to non-overlapping responsibilities:

| Sysext | Contains | Touches `/usr`? | Reboot? |
| --- | --- | --- | --- |
| **`nvidia.raw`** | NVIDIA driver only (kernel module + userspace libs). No `/usr/bin/` helpers — the uninstaller is bundled into `nvidia-mig.raw` (always installed alongside under `--with-driver`) to avoid a sysext-merge path collision. | Yes — swaps the stock sysext via a brief zfs `readonly=off` toggle. | Yes — live-swapping leaves stale modules in RAM, NVML mismatch until reboot. |
| **`nvidia-mig.raw`** | MIG setup binary (`/usr/bin/nvidia-mig-setup`), `nvidia-mig-setup.service` unit, `configure-mig` user-facing helper, **unified** `/usr/bin/uninstall-nvidia-mig` (auto-detects MIG-only vs MIG+driver state). | No — symlinked into `/etc/extensions/`; lives entirely in the persistent ZFS pool. | No. |

`nvidia.raw` is **driver-only by design**. Earlier iterations of this build had a `BUNDLE_MIG` knob that packed the MIG tooling into `nvidia.raw`, but that created two collision modes (both sysexts providing `configure-mig` and the service unit; install scripts needing to detect which one was the source of truth). The unified model is:

- `install-mig-sysext.sh` (default) installs `nvidia-mig.raw` only. Stock driver carries on.
- `install-mig-sysext.sh --with-driver` installs `nvidia.raw` **and** `nvidia-mig.raw`. The driver swap and the MIG install are two separate operations; they share a re-merge cycle but otherwise don't interact.

This means there is never a need to install both `nvidia-mig.raw` and a separately-bundled MIG copy — `nvidia.raw` never contains MIG. The same `nvidia-mig.raw` works on top of either the stock TrueNAS driver or a custom one.

### Two PREINIT entries, no ordering dependency

`--with-driver` registers two `midclt initshutdownscript` PREINIT entries. They have non-overlapping concerns:

1. **`nvidia-preinit-driver.sh`** — restores the custom `nvidia.raw` if TrueNAS updates wiped `/usr`, and logs kernel-version mismatch if TrueNAS bumped the kernel. Lives at `${PERSIST_DIR}/nvidia-preinit-driver.sh`. No MIG concerns at all.
2. **`systemctl start nvidia-mig-setup.service`** — recreates MIG instances on boot. The service runs the bundled `/usr/bin/nvidia-mig-setup` script.

TrueNAS PREINIT entries fire roughly in their middleware-DB-insertion order, but we don't depend on that. `nvidia-mig-setup` (the script, not the PREINIT trigger) has a built-in wait that handles three race conditions in one loop:

1. The stock NVIDIA sysext may still be merging asynchronously after `systemd-sysext.service` has technically completed.
2. Under `--with-driver`, the sibling PREINIT may still be re-applying a custom `nvidia.raw` from persistent storage.
3. The kernel module is loaded asynchronously by udev/modprobe; even when `/usr/bin/nvidia-smi` exists on disk, `nvidia-smi -L` may not yet succeed because NVML can't talk to the module.

The wait polls `nvidia-smi -L` for up to 60s — that's a single conservative check that subsumes all three races, so the PREINITs can run in either order without explicit sequencing.
