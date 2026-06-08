# Changelog

Notable changes to nvidia-mig-support, organized by area. Starts from the post-dual-sysext refactor baseline; per-release changelog entries land here going forward.

## MIG-only: the driver path moved to nvidia-driver-support

This repo now does exactly one thing: build and install `nvidia-mig.raw` on top of whatever NVIDIA driver is already present. The entire driver side — the `--with-driver` install mode, the on-host `nvidia.raw` build, stock-driver recovery, the driver PREINIT, and the daily upstream-version poller — has been removed. To run a newer/specific/legacy driver, use the separate [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support) project first, then install MIG on top.

- **`install-mig-sysext.sh` is MIG-only.** Dropped `--with-driver`, `--driver-sysext`, `--custom-run`, `--rebuild`, `--kmod`, and `--skip-backup-check`, plus all the build/cache/stage/driver-swap machinery. It now: pre-flights the running driver, fetches `nvidia-mig.raw`, symlinks + merges it, and registers the MIG PREINIT. No reboot. Release resolution simplified to the repo's latest release (or `--release=TAG`) via the `releases/latest/download` URL — no more TrueNAS-version tag matching.
- **MIG-support gate reframed.** The driver must be major **≥ 570** (the driver shipped in the latest TrueNAS 25). Below that, install refuses unless `--force` — worded as "MIG unsupported; install a newer driver via nvidia-driver-support" rather than the old "use --with-driver".
- **`uninstall-mig-sysext.sh` is MIG-only.** Removed the driver-revert path (stock restore, `/usr` readonly toggle, driver PREINIT deregistration, `--keep-cache`/`--skip-backup-check`). It still tears down MIG runtime state (instances, mode, app reassignment) and removes the MIG sysext + PREINIT. The driver is never touched; no reboot.
- **Deleted** `build-nvidia-sysext.sh`, `build-on-host.sh`, `recover-stock-nvidia.sh`, `nvidia-preinit-driver.sh`.
- **CI: `build-sysext.yml` is MIG-only**, manual-dispatch, tag `v<run_number>`, publishes `nvidia-mig.raw` as the sole asset. Removed the `build-nvidia` job, the `resolve` version-logic job, `workflow_call`, and the hardware-test issue flow. **Deleted** `check-releases.yml`, `.github/tracked-versions.json`, and `validate-tracked-versions.sh`; trimmed `lint.yml` accordingly.
- **Docs** rewritten MIG-only across README and `docs/`, pointing at nvidia-driver-support for the driver.

> Migration: an existing `--with-driver` install isn't auto-reverted by the new uninstall. Use nvidia-driver-support's tooling to manage/revert the driver; this repo's uninstall only removes the MIG layer.

## install: aborted --with-driver now rolls back the GPU release (issue #62)

A `--with-driver` install frees the GPU before swapping the driver: it stops every GPU-bound app with `app.stop` and disables the docker nvidia toggle. On a clean run those are intentionally left that way until the post-reboot `configure-mig` re-enables the toggle and restarts the apps. On an *aborted* run, nothing restored them. install's cleanup trap (`cleanup_tmp`) only put `/usr` readonly back, so an interrupted install left the host with its apps stopped and the toggle off, with no auto-recovery. install was the only one of the four GPU scripts with this gap: `uninstall-mig-sysext.sh` and `recover-stock-nvidia.sh` already restore the toggle in their `restore_state` trap (PR #55), and both uninstall and configure-mig restart the apps they stop. The toggle half was the visible symptom in issue #62; the stopped-apps half is the part that actually takes a user's Frigate/Ollama offline, and it is not self-healing by re-running install (only configure-mig restarts apps).

- **Trap now undoes the GPU release on abnormal exit.** `cleanup_tmp` captures the exit code and, on a non-zero/signalled exit, restarts the apps it stopped and restores the toggle, in addition to the existing `/usr` readonly restore. A clean exit changes nothing (the toggle-off + stopped apps remain intentional, handed off to the post-reboot configure-mig).
- **Phase-gated so it never restarts apps onto a broken driver.** A `SWAP_STARTED` flag is set the moment the driver teardown (sysext unmerge) begins. If the abort happens before that, the stock driver is still intact and the rollback is a full restore. If it happens after, the trap does not restart apps onto a possibly half-swapped driver; it prints a recovery banner pointing at `recover-stock-nvidia.sh` and lists which apps were left stopped.
- **Toggle restored to its captured prior value, not a hardcoded `true`.** install reads `docker.config.nvidia` before disabling it and restores that exact value on abort, so a user who had the toggle off to begin with keeps it off. (uninstall/recover still hardcode `true`; this is the more correct behavior and could be backported.)
- **Success path now names the stopped apps.** On a clean `--with-driver` finish the script lists the apps it stopped and states plainly that configure-mig restarts them after reboot, so the apps being down is not a silent surprise.
- **Rollback restores the toggle before restarting apps.** Follow-up to the above: in the pre-swap rollback the toggle is re-enabled first, then the apps are restarted. With the toggle off, TrueNAS won't start any docker container (GPU or not), so an `app.start` ahead of the toggle restore would no-op.
- **Rollback also restarts an app interrupted mid-stop.** `app.stop -j` is a blocking job; if the abort lands during the call the middleware may still stop the app server-side, but it never reached the success branch that records it. A separate `STOPPING_APP` marker tracks the in-flight app so the rollback restarts it too. A cleanly-failed stop (app still up) is deliberately left out, so no app is needlessly restarted.

## NVIDIA driver built on the host, not redistributed (PR #59)

`nvidia.raw` is no longer published as a release asset. NVIDIA's EULA prohibits us from redistributing the proprietary userspace it bundles, and the org's no-binary-redistribution policy (profile/README.md) says we shouldn't. The previous `--with-driver` flow downloaded a `nvidia.raw` we attached to every release — that violated both. The driver is now **built on the user's TrueNAS host**, where the operator accepts NVIDIA's EULA themselves.

- **`--with-driver` builds `nvidia.raw` on host.** The install script runs `scripts/build-on-host.sh` (a thin wrapper around the unchanged `scripts/build-nvidia-sysext.sh`) inside a transient `ubuntu:24.04` docker container. The NVIDIA `.run` runs with `--accept-license --silent`, so the host operator accepts the [NVIDIA driver EULA](https://www.nvidia.com/en-us/drivers/nvidia-license/) on their own behalf. First build ≈ 8 min; the TrueNAS `.update` (~1.5 GB) and NVIDIA `.run` (~400 MB) are cached at `${PERSIST_DIR}/cache/` so warm rebuilds are ~3 min.
- **Build output is cached and reused.** The built `nvidia.raw` lands at `${PERSIST_DIR}/nvidia.raw` and is reused on re-install when the driver version and running kernel both match (~10 s, no rebuild). `--rebuild` forces a fresh build.
- **Release assets are MIG-only.** Releases now carry just `nvidia-mig.raw` (+ `.sha256`). `build-sysext.yml` still *builds* `nvidia.raw` as a smoke test that gates the release — if the build script breaks against current upstream the release fails, rather than shipping a recipe that would break on every user's host — but the artifact is kept only as a 30-day workflow run artifact, never published. (Supersedes the "single tag carries both assets" / "downloads both assets" wording in the *Unified Sysext Release* entry below.)
- **New `--with-driver` flags.** `--rebuild` (force fresh build), `--custom-run=PATH` (use a local NVIDIA `.run`), `--kmod=open|proprietary` (default open; proprietary path wired in but untested). `--driver-sysext=PATH` is retained as the escape hatch for a sysext built elsewhere.
- **Uninstall cleans build artifacts.** `uninstall-mig-sysext.sh` now removes the `build/`, `scripts/`, and `cache/` persist dirs by default (only `nvidia-original.raw` survives, for recovery). New `--keep-cache` preserves the ~2 GB cache for an imminent reinstall; `--keep-persist` still keeps everything.
- **Install releases the GPU per-app.** The `--with-driver` install now stops each GPU-holding app with `app.stop` before the sysext swap (matching configure-mig/uninstall), instead of the `docker.update '{"nvidia": false}'` toggle that couldn't evict live CUDA/NVENC contexts.

Validated end-to-end on hardware (TrueNAS 25.10.3.1 + RTX PRO 6000 Blackwell).

## nvidia toggle handling: uninstall now restores it, configure-mig waits post-boot

Two related issues with the `docker.config.nvidia` toggle (TrueNAS UI: Apps → Settings → "Use NVIDIA GPU"), both surfaced after hardware testing PR #49.

**Uninstall was leaving the toggle stuck OFF.** The `--with-driver` uninstall path calls `docker.update '{"nvidia": false}'` to evict nvidia-runtime containers before swapping the driver `.raw` out, and never restored it. Earlier comments justified skipping the restore with the claim that "TrueNAS resets the toggle on boot anyway." Hardware testing showed that claim was wrong: the toggle **persists** across reboot. The OFF state our uninstall wrote pre-reboot survived intact, and the user had to flip it back manually in the UI before apps regained GPU access. Fix: after the sysext re-merge in the `HAS_DRIVER` path, set `docker.update '{"nvidia": true}'` and verify the read-back. One-shot is sufficient here — the docker subsystem has been running continuously throughout uninstall, no service-startup race. The post-reboot banner now just suggests an optional verification one-liner.

**configure-mig now waits for the toggle to accept writes before doing anything else.** Separate but related observation: immediately after a fresh boot, `docker.update '{"nvidia": true}'` returns success but the value doesn't actually persist for some time (read-back continues to show `False`). Empirically resolves within ~10 min; we don't know why. Running configure-mig inside that window let its final apps-re-enable silently no-op, leaving the toggle OFF and apps without GPU. Fix: at the start of configure-mig (right after the nvidia-smi preflight, before any state changes), poll `docker.update` → `docker.config` with a visible counter until the write sticks. Up to 10 min, then exit non-zero with a diagnostic and suggested actions. `nvidia=true` is the desired post-configure-mig state anyway, so leaving it set during the precheck is fine.

Install and uninstall banners and surrounding comments rewritten to drop the speculative "TrueNAS resets on boot" framing. The accurate model is: the toggle persists across reboots, but the apps subsystem just doesn't process write requests for a window after a fresh boot.

## configure-mig: ignore stale UUIDs + cache original app state for restart

Two follow-up bugs from the per-app-stop change one entry below, both surfaced on hardware test of release r16:

1. **App that wasn't actually using the GPU got pre-stopped.** A `glances` app showed no NVIDIA assignment in the TrueNAS UI but still appeared in the pre-stop scan and got stopped. The app's persisted `nvidia_gpu_selection.<slot>` entry had `use_gpu: false` together with the current GPU's UUID — TrueNAS persists the slot binding even when the user toggles off "use this GPU" in the UI. The scan filter didn't look at `use_gpu` at all, so any app with a non-empty UUID anywhere in the selection map got flagged as GPU-bound. Fix: tighten the filter to require both (a) `use_gpu == true` for the slot (the app is actively using the GPU, not just carrying a slot entry with the toggle off), and (b) the slot's UUID matches a device that actually exists on the current hardware. The valid set comes from `nvidia-smi -L`: parent GPU plus any existing MIG slices. Matches the UI's "is this binding live?" gating, and is defensive against the GPU-swap case (UUID from a previously-installed card) even if that's not what triggered this particular report.

2. **Apps that were RUNNING ended up STOPPED after configure-mig.** The app-mapping section queries `app.get_instance` *during* its apply loop to record each app's "original state" — but by then the new per-app-stop code has already taken those apps from RUNNING → STOPPED. The loop sees STOPPED, applies the MIG UUID, then says "leaving stopped (was not running originally)". Fix: cache the pre-stop scan's `name|state` in `GPU_APPS_INFO`, and have the app-mapping `orig_state` lookup prefer the cached value when present. Apps newly assigned this run (not in the pre-stop set) still query live as before.

Apps that the user *doesn't* assign to a MIG UUID stay stopped — intentional, since their config still points at the now-non-existent full-GPU UUID and restarting them would just produce a crash loop. The visible-stopped signal is correct.

## configure-mig: explicit `app.stop` before MIG create + diagnostic abort on stuck GPU

Hardware-test finding (issue #47). A first run of `configure-mig` against a host with running GPU apps (Frigate, Ollama, etc.) ended with a misleading `ERROR: 'nvidia-smi mig -lgi' returned no GPU instances. Check journalctl…` after `Waiting for 6 GPU process(es)... 120s/120s`. Journal showed the real cause: `nvidia-smi mig -cgi` failing with `In use by another client` because containers with open CUDA/NVENC contexts kept holding the GPU past the wait window.

Same root cause as the uninstall-script fix one entry below: the global `docker.update '{"nvidia": false}'` toggle doesn't kill running containers — it only reconfigures the docker runtime for future starts. `configure-mig` was relying on this toggle alone where the uninstall path already does the right thing (per-app `app.stop -j` first, toggle as belt-and-suspenders).

Three changes:

1. **Per-app `app.stop -j` before the toggle.** Walk `app.query`, fetch each `app.config`, filter for any with `nvidia_gpu_selection.<slot>.uuid` set (broader than uninstall's MIG-only filter — on first run, apps are bound to the full-GPU UUID, not MIG-* UUIDs). Stop each one in RUNNING state. `-j` blocks on actual container teardown so CUDA/NVENC contexts release.
2. **Abort on stuck GPU instead of falling through.** The 120s drain wait is now 30s (sufficient post-`app.stop`) and on timeout the script dumps the stuck `pid,process_name,used_memory` rows, re-enables the docker toggle so non-GPU apps can come back, and exits non-zero. The previous "give up and try anyway" path always produced a misleading post-check failure.
3. **Surface the real service error inline.** When the `mig -lgi` post-check finds zero instances, tail the last 20 lines of `journalctl -u nvidia-mig-setup` so the actual cause (`In use by another client`, kernel-module issue, etc.) is right there in the error output instead of requiring a separate journalctl invocation.

## configure-mig: race condition in app-picker enumeration

Hardware-test finding: `sudo configure-mig` would intermittently show an empty `--- Apps ---` section in the device-to-app assignment picker even though `App services ready (6 apps)` had just printed seconds earlier. Re-running the script a minute later produced the full list.

Root cause: middleware app state isn't fully consistent immediately after `docker.update '{"nvidia": true}'` returns. The existing wait loop polls `app.query` and exits as soon as it returns `>0` apps — but a follow-up `app.query` a few seconds later can still return empty during the same flap window. The picker's `mapfile -t APP_NAMES` query then sees an empty list, so the display loop has nothing to iterate.

Two-layer fix:

1. **Stabilization wait** after the "ready" detection: once the wait-loop exits, sleep a visible 10s (counter every second) so middleware state settles before the picker queries again. Matches the user's "give it 5–10s after services come back" hypothesis.
2. **Retry on empty** at the actual picker query: `mapfile -t APP_NAMES` is wrapped in a 5×3s poll that re-queries if the first result is empty. Defense in depth — covers any other middleware transient the stabilization wait missed.

The picker also now explicitly lists every app regardless of state (RUNNING/STOPPED/CRASHED/DEPLOYING) — assigning a MIG slice to a stopped app is a valid operation. The previous code already had no state filter, but the comment now makes the intent explicit.

## Uninstall replaces `docker.update` sledgehammer with explicit `app.stop`

Hardware-test follow-up to #42. The previous teardown flow relied on `midclt call -j docker.update '{"nvidia": false}'` to "stop every container using the nvidia runtime", then drained, then destroyed MIG instances. In practice the toggle does NOT stop already-running containers — it only changes the docker runtime config so *future* container starts won't request a GPU. Containers with open CUDA/NVENC/NVDEC contexts keep running, keep holding their MIG slices, and `nvidia-smi mig -dci` fails with `In use by another client`.

The drain check (`nvidia-smi --query-compute-apps=pid`) also missed this — it returns 0 when no **compute** kernels are active, but NVENC/NVDEC clients (frigate's ffmpeg, all transcoding/decode workloads) don't show there. Idle compute is not the same as no clients.

Restructured the teardown into a six-step deterministic flow:

1. **Pre-scan** every app via `app.query` → `app.config <name>`, cache `(name, slot, old MIG-* UUID, state)` for each app whose `nvidia_gpu_selection.<slot>.uuid` starts with `MIG-`.
2. **Stop** each MIG-holding app explicitly with `midclt call -j app.stop <name>`. `-j` blocks on the container actually tearing down, which is the only reliable way to get NVENC/NVDEC clients off the GPU. Apps already non-RUNNING are skipped (no container to stop) but still get reassigned in step 5.
3. **Drain** for up to 15 s on `nvidia-smi --query-compute-apps` — short window since `app.stop -j` already blocked on the heavy lifting.
4. **Destroy + disable with retry** — wrap `mig -dci` / `mig -dgi` / `-mig 0` in a 3×3 s retry loop. Driver sometimes takes a few seconds to release a CUDA client after the container PID is reaped; the retry absorbs this.
5. **Reassign** each cached app to the full-GPU UUID on the same PCI slot. Uses the cached `(slot, old_uuid)` so no second walk through `app.config` is needed.
6. **Restart** any cached app that was RUNNING pre-stop.

The `docker.update` toggle is gone from the MIG-only path. It's preserved (now with `-j`) for the `--with-driver` path, where we genuinely need every nvidia-runtime container down so the kernel module isn't held while the live `.raw` is swapped.

Side-benefits of the new structure: the pre-scan cache means each app is read from middleware once instead of twice (was: once in the reassign loop, once implicitly via the docker toggle); the restart phase no longer disturbs apps that didn't use MIG; the failure message is more accurate ("non-app process must be holding a slice" instead of pointing the user back at app.stop, which the script already did).

## Uninstall reassign-loop hardening (silent abort + state-scope + docker job race)

Hardware-test finding on the previous "rewrite per-app MIG-* UUIDs" change (#41): on a host with apps in mixed states, the script went silent right after `Reassigning apps that still point at MIG-* UUIDs...` and never reached sysext-unmerge, PREINIT-deregister, or persist-cleanup. Diagnostic showed `nvidia-mig.raw` symlink still in `/etc/extensions/`, PREINIT id still registered, `mig.conf` still on disk, and the target app's `nvidia_gpu_selection.<slot>.uuid` still pointing at a stale `MIG-*` value.

Three concurrent bugs:

1. **`set -euo pipefail` + unprotected command substitutions** — `mig_info=$(midclt call app.config "$app" 2>/dev/null | python3 -c "…" 2>/dev/null)` (and the analogous read in the restart loop) ran without `|| true`. When `midclt call app.config <name>` failed for any one app (mid-deploy, crashed, transient middleware error), `pipefail` propagated the non-zero status through the command substitution and `set -e` aborted the whole script silently before any per-app output landed. Hardened with `|| true` on every middleware-result command substitution that feeds a variable; added an inline comment so the hardening doesn't get refactored away.
2. **Reassign scope was too narrow.** The loop iterated `ORIG_RUNNING` (apps that were `state == 'RUNNING'` at snapshot time). Apps in DEPLOYING/STOPPED/CRASHED at snapshot but with `MIG-*` UUIDs persisted in config were skipped entirely — those would fail to start next boot. Loop now iterates `app.query` for all apps and reassigns any with a `MIG-*` UUID in config regardless of state. The restart loop still uses `ORIG_RUNNING` (correct: only restart what was previously running).
3. **`docker.update '{"nvidia": true}'` race with the preceding `false` job.** Fire-and-forget `midclt call docker.update` returned before the docker subsystem had finished applying the `nvidia: false` transition; the immediately-following re-enable was rejected. Switched both `docker.update` calls to `midclt call -j` so they block on the job, and wrapped the re-enable in a 5× retry-with-3s-backoff that re-queries `docker.config.nvidia` after each attempt. Self-heals both the docker-mid-transition reject and the post-boot ~10-min middleware boot-window.

## Uninstall tears down MIG runtime state (instances, mode, app assignments)

Hardware-test finding: the unified `uninstall-nvidia-mig` (released in the prior changelog entry below) removed the **sysext + PREINIT + persist files**, but left:

- MIG mode still Enabled in GPU firmware
- MIG compute + GPU instances still alive
- Each affected app's `nvidia_gpu_selection.<slot>.uuid` still pointing at the now-orphaned `MIG-…` UUID

On next boot (without the now-deregistered PREINIT to recreate MIG instances) the apps would try to claim a stale UUID and fail to start. The intent of "uninstall MIG" is a clean revert; this filled the gap.

Added a teardown phase that runs before sysext unmerge, gated on `nvidia-smi --query-gpu=mig.mode.current` == `Enabled`:

1. Identify apps whose `nvidia_gpu_selection.<slot>.uuid` starts with `MIG-`.
2. Stop those apps (per-app, with the same live-elapsed counter as configure-mig).
3. Wait for the GPU to drain (visible counter).
4. `nvidia-smi mig -dci` + `mig -dgi` to destroy compute and GPU instances.
5. `nvidia-smi -mig 0` to disable MIG mode (firmware state).
6. Read the full-GPU UUID via `nvidia-smi --query-gpu=uuid`.
7. Per affected app: `app.update` with `nvidia_gpu_selection.<slot>.uuid = <full-gpu-uuid>`. Apps that were originally running are restarted with the new config.

`mig.conf` is also removed from the persist dir in the non-`--keep-persist` cleanup pass (previously left behind as cruft).

Final banner shows a "MIG runtime teardown summary" block when the teardown ran, so the user can confirm at a glance what state was cleaned.

## Unified uninstall + script-name fixups

Follow-up to the unified-release refactor below. Same project shape (one release tag, two assets), but the script-side entrypoints get tightened:

- **`scripts/install-sysext.sh` → `scripts/install-mig-sysext.sh`.** Generic `install-sysext.sh` was a bad name across a multi-project sysext family (`nvidia-mig-support`, `hailo8-support`, …); each repo should have a project-named entrypoint. The `install-mig-sysext.sh` name matches the bundled `uninstall-nvidia-mig` convention and the project's MIG-first focus. Users hard-coding the old curl URL must update — old URL 404s.
- **One unified uninstall: `scripts/uninstall-mig-sysext.sh`** (absorbs the deleted `scripts/uninstall-nvidia-sysext.sh`). Auto-detects state via persist-dir contents and `/etc/extensions/` symlinks:
  - **MIG only** → remove the MIG sysext + PREINIT. No driver touched, no reboot.
  - **MIG + custom driver** → stop apps, drain GPU, single unmerge → revert `nvidia.raw` to stock + remove MIG symlink → single re-merge → deregister both PREINITs → cleanup persist files. **Reboot required.**
  - **Neither** → print "nothing to uninstall" and exit cleanly.
- **`nvidia.raw` no longer bundles an uninstaller** (`uninstall-nvidia-driver` is gone). `systemd-sysext` refuses to merge two extensions that share a `/usr/bin/<name>` path; since `nvidia-mig.raw` is always installed alongside `nvidia.raw` in the `--with-driver` path, the single `uninstall-nvidia-mig` binary in `nvidia-mig.raw` is enough. The build smoke-test now actively asserts `uninstall-nvidia-driver` is **absent** from `nvidia.raw` so any regression that re-introduces the path collision fails CI.
- **`uninstall-mig-sysext.sh` drops the `attempt_nvidia_reenable` pre-reboot call.** Same boot-window reasoning as the install-side fix (#37): pre-reboot verification is defeated by TrueNAS resetting `docker.config.nvidia` during boot, and the docker subsystem rejecting re-enable for ~5–10 min after that. The post-reboot banner makes the wait explicit.

## Unified Sysext Release (single tag, single install script)

Breaking refactor that collapses two parallel release lines into one tag, and two install scripts into one with a `--with-driver` flag.

- **Single release tag carries both assets.** Every release is now `v<truenas>-nvidia<driver>-r<run>` with both `nvidia.raw` (driver-only) and `nvidia-mig.raw` (MIG tooling) attached. Old `v<truenas>-mig-r<run>` releases remain valid (immutable) but no new ones will be produced. NVIDIA-only bumps still rebuild `nvidia-mig.raw` at byte-equivalent content — accepted as simpler than conditional asset attachment.
- **`nvidia.raw` is now driver-only.** The `BUNDLE_MIG` knob and `--no-mig-bundle` flag are gone. `nvidia.raw` never contains MIG tooling; that lives exclusively in `nvidia-mig.raw`. Removes the dual-MIG-source collision risk and the bundled-vs-standalone framing that made `--check` reporting confusing.
- **`install-mig-sysext.sh` replaces the two install scripts.** Default = MIG-only on stock driver (no reboot, no `/usr` r/w — same as the old `install-mig-sysext.sh`). `--with-driver` = downloads both assets, swaps the driver (`/usr` r/w via zfs `readonly=off`/`on`, single re-merge cycle covers both sysexts), registers two PREINIT entries, prompts reboot. Old `install-mig-sysext.sh` and `install-nvidia-sysext.sh` are deleted — users who hard-coded those URLs will need to update.
- **Two independent PREINIT entries with no ordering dependency.** `--with-driver` registers `nvidia-preinit-driver.sh` (custom-driver restore + kernel-mismatch detection) AND `systemctl start nvidia-mig-setup.service` (MIG instance creation) as separate `midclt initshutdownscript` rows. The MIG service has a built-in wait for `nvidia-smi -L` to succeed — covers stock-sysext-still-merging, driver-PREINIT-still-restoring, and udev-still-loading-modules in one 60 s poll. PREINITs can fire in any order without coordination.
- **`nvidia-preinit-full.sh` renamed to `nvidia-preinit-driver.sh`** and stripped of its MIG service start (Phase 3). It's now driver-side concerns only. Syslog tag changes from `nvidia-preinit-full` to `nvidia-preinit-driver`. The legacy file is auto-cleaned by `install-mig-sysext.sh --with-driver` and detected as a warning by `--check`.
- **One unified build workflow.** `build-nvidia-sysext.yml` + `build-mig-sysext.yml` collapse to `build-sysext.yml`: one `resolve` job feeding two parallel build jobs (`build-nvidia`, `build-mig`) and a single `publish` job that attaches both assets to one release. Hardware-test issue auto-creation is one issue per release with checklists for both install variants.
- **`check-releases.yml` dispatches the unified workflow** on any TrueNAS-or-NVIDIA bump (was: two separate dispatches with TrueNAS-only gating on the MIG side).
- **Smoke-tests reflect the separation.** `nvidia.raw` smoke-test asserts driver bits are present AND that MIG bits are **absent** (catches future regressions if someone reintroduces bundling). `nvidia-mig.raw` smoke-test stays as before.

## Install / Uninstall Scripts

- **Bundled uninstall scripts.** Both `nvidia.raw` and `nvidia-mig.raw` ship with their respective uninstaller at `/usr/bin/uninstall-nvidia-driver` and `/usr/bin/uninstall-nvidia-mig`, so users can uninstall without re-downloading from the release.
- **Smart pool / persist-dir resolution.** `install-*-sysext.sh`, `configure-mig.sh`, and `recover-stock-nvidia.sh` all share a `resolve_persist_dir()` that searches `/mnt/*/.config/nvidia-gpu`, prompts on ambiguity, and probe-opens `/dev/tty` to fall back cleanly when no TTY is attached.
- **`--pool` / `--persist-path` flags** documented across all install scripts; `--skip-backup-check` on the full-driver installer for users who manage their own stock backup.
- **`--release=TAG` flag.** Pin an install to a specific release instead of the auto-resolved latest matching `v<truenas>-…-r<run>` tag. Useful for reproducing a known-good driver version on a fresh host or pinning to a particular hardware-verified build.
- **`--check` flag.** Read-only diagnostic — `install-{nvidia,mig}-sysext.sh --check` reports pass/warn/fail on sysext merge state, kernel-module loading, driver-version match (sysext blob vs `nvidia-smi` runtime), persist dir, stock backup, PREINIT registration, and (for the MIG script) detection of bundled-MIG-in-full-driver vs standalone MIG. Exits 1 if anything fails — scriptable as a health check.
- **`--dry-run` flag.** Walks through every read + network step (release lookup, sysext download, validation, midclt query) but skips every mutation. Each skipped step is logged as `[dry-run] would: …`. Mutually exclusive with `--check`.
- **Robust root check.** `[ "$(id -u)" -eq 0 ]` swapped to string comparison `[ "$(id -u 2>/dev/null)" = "0" ]` across all install/uninstall/configure scripts. Degrades gracefully on weird invocation patterns (`sudo bash -c "$(curl …)" --`) where `id -u` returns empty — prints the intended "must run as root" message instead of a bash diagnostic.
- **Reboot-aware install messaging.** Full-driver install prints an explicit reboot-required notice — live-swap leaves stale kernel modules in RAM, producing NVML driver/library version mismatches.

## Boot-time PREINIT

- **Syslog tag for diagnostics.** `nvidia-preinit-full.sh` writes to `logger -t nvidia-preinit-full` in addition to stdout, so `journalctl -b -t nvidia-preinit-full` produces a clean boot-scoped diagnostic without trawling the whole journal.
- **Kernel-version mismatch detection.** Catches the failure mode where TrueNAS auto-updates the kernel and the bundled `nvidia.ko` no longer matches — logs an explicit ERROR with running kernel, bundled kernel, and the re-install one-liner. Converts a silent "nvidia-smi couldn't find any device" into a single named, actionable line. Path-tolerant: searches anywhere under `/usr/lib/modules/<kver>/` for `nvidia.ko*`, including compressed variants.
- **SHA256 restore from persistent backup.** On every boot, compares live `nvidia.raw` vs the persistent backup copy. On mismatch (typical after a TrueNAS update wipes `/usr`) or empty SHA (defensive — won't treat two empty strings as a match), restores from backup, re-symlinks, re-merges sysext. Wrapped with `trap restore_usr_readonly` so a SIGTERM mid-restore can't leave `/usr` writable.

## MIG Configuration

- **`configure-mig.sh` defensive checks.** Validates profile strings before applying; enforces `profile count == MIG instance count`; validates media-engine constraints on Blackwell; preserves the original GPU state (stopped/running) across reassignment; fails loudly on NVML driver/library mismatch rather than reporting an opaque NVML error.
- **Profile picker UX.** Shows all 11 profile IDs in the interactive prompt with exact engine counts per profile; tightened table layout.

## Sysext Architecture

- **Dual-sysext split.** `nvidia.raw` (full driver, replaces stock, requires reboot) and `nvidia-mig.raw` (config-only, layers on stock ≥570).
- **Bundled-MIG full-driver variant — first-class.** The `nvidia.raw` build defaults to `BUNDLE_MIG=true`, baking `configure-mig` + `nvidia-mig-setup.service` into the full-driver sysext. Users on the full-driver path get MIG without installing the separate `nvidia-mig.raw` — and **shouldn't** install both (undefined sysext-merge ordering). See [docs/build-ci-notes.md](docs/build-ci-notes.md#mig-packaging-bundled-vs-standalone) for the tradeoffs. Release notes call out `MIG bundled: true|false` explicitly; the `bundle_mig` workflow input stays in place for the unbundled variant. `install-mig-sysext.sh --check` detects the bundled state and reports it as a single pass rather than three confusing failures.
- **Scale-build pipeline retired** in favor of a direct sysext build path.

## Automated Workflows

- **`tracked-versions.json` + validator.** Single CI-state file at `.github/tracked-versions.json` holds the currently-tracked TrueNAS and NVIDIA versions plus `kernel_module_type`. `.github/scripts/validate-tracked-versions.sh` enforces shape (TrueNAS 2–5 numeric parts, NVIDIA `X.Y.Z`, `kernel_module_type` ∈ `{open, proprietary}`) and runs on every PR/push that touches the file. Build workflows consume the file via a dedicated `resolve` job so all inputs are optional and default to tracked values.
- **`.update` file cache.** TrueNAS `.update` is 1–3 GB. Caching it at `/tmp/truenas.update` keyed on `truenas_version` skips the download on hot builds. Build script accepts `--update-file=` to consume a pre-staged copy. Restore lives next to the unmerge step; save lives after the build script downloads, on cache miss only, so failures don't poison the cache.
- **Hardcoded `ubuntu-24.04` runner.** Unlike hailo's dynamic Debian→Ubuntu mapping, we deliberately *don't* port that pattern. nvidia's GLIBC constraint is different (kernel modules don't link GLIBC; nvidia userspace `.so` files ship pre-built from the `.run` blob, not re-linked on the runner), and ubuntu-22.04 doesn't ship `gcc-14` which the build script requires for `-fmin-function-alignment=16`. Documented in [docs/build-ci-notes.md](docs/build-ci-notes.md#runner-selection-hardcoded-ubuntu-2404-not-dynamic).
- **Immutable `-r<run>` release tags.** Every build publishes to `v<truenas>-nvidia<driver>-r<run>` (full driver) or `v<truenas>-mig-r<run>` (MIG). `github.run_number` makes each tag unique even on same-commit re-dispatch, sidestepping GitHub's immutable-release tag-burn behavior. The rolling `dev-nvidia-sysext` / `dev-mig-sysext` pattern that earlier Phase 3 designs used was retired — incompatible with the repo's "Immutable releases" setting (asset deletion forbidden, which `--clobber` requires). Uses `softprops/action-gh-release@v3` with `make_latest` rather than `gh release upload --clobber`. Install scripts resolve "latest matching tag" via the `/releases` API with `published_at` sort.
- **`check-releases.yml` daily auto-cadence.** 06:00 UTC cron polls `truenas/scale-build` tags and `download.nvidia.com/.../latest.txt`. On drift, commits an in-place update to `tracked-versions.json` and dispatches `build-nvidia-sysext.yml` (on either bump) and `build-mig-sysext.yml` (TrueNAS-only) with `mark_latest='false'`. Default `GITHUB_TOKEN` is sufficient on this repo (main unprotected); if a ruleset is later added, swap `token:` to `secrets.CHECK_BUILDS` (one-line change documented in the workflow).
- **Hardware-test gate.** Auto-cadence builds publish as releases but don't promote to GitHub "Latest". The build workflow auto-creates a `hardware-test`-labeled issue with a per-build install/verify checklist; the issue closes by hand after the user runs "Set as latest" on the release page. Idempotent (skips duplicates by tag). Manual `workflow_dispatch` defaults `mark_latest=true` and skips the issue creation — intentional human builds promote immediately.

## Repo Hygiene

- **Lint workflow.** `shellcheck --severity=warning` on every shell script under `scripts/` and `.github/scripts/`, plus `actionlint` (with embedded shellcheck) on workflow YAML, plus the `tracked-versions.json` shape validator.
- **Dependabot.** Weekly bumps for `github-actions`.
- **CHANGELOG.** This file.
