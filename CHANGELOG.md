# Changelog

Notable changes to nvidia-mig-support, organized by area. Starts from the post-dual-sysext refactor baseline; per-release changelog entries land here going forward.

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
