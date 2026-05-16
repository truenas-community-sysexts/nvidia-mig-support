# Changelog

Notable changes to nvidia-mig-support, organized by area. Starts from the post-dual-sysext refactor baseline; per-release changelog entries land here going forward.

## Install / Uninstall Scripts

- **Bundled uninstall scripts.** Both `nvidia.raw` and `nvidia-mig.raw` ship with their respective uninstaller at `/usr/bin/uninstall-nvidia-driver` and `/usr/bin/uninstall-nvidia-mig`, so users can uninstall without re-downloading from the release.
- **Smart pool / persist-dir resolution.** `install-*-sysext.sh`, `configure-mig.sh`, and `recover-stock-nvidia.sh` all share a `resolve_persist_dir()` that searches `/mnt/*/.config/nvidia-gpu`, prompts on ambiguity, and probe-opens `/dev/tty` to fall back cleanly when no TTY is attached.
- **`--pool` / `--persist-path` flags** documented across all install scripts; `--skip-backup-check` on the full-driver installer for users who manage their own stock backup.
- **Reboot-aware install messaging.** Full-driver install prints an explicit reboot-required notice — live-swap leaves stale kernel modules in RAM, producing NVML driver/library version mismatches.

## MIG Configuration

- **`configure-mig.sh` defensive checks.** Validates profile strings before applying; enforces `profile count == MIG instance count`; validates media-engine constraints on Blackwell; preserves the original GPU state (stopped/running) across reassignment; fails loudly on NVML driver/library mismatch rather than reporting an opaque NVML error.
- **Profile picker UX.** Shows all 11 profile IDs in the interactive prompt with exact engine counts per profile; tightened table layout.

## Sysext Architecture

- **Dual-sysext split.** `nvidia.raw` (full driver, replaces stock, requires reboot) and `nvidia-mig.raw` (config-only, layers on stock ≥570).
- **Bundled-MIG full-driver variant — first-class.** The `nvidia.raw` build defaults to `BUNDLE_MIG=true`, baking `configure-mig` + `nvidia-mig-setup.service` into the full-driver sysext. Users on the full-driver path get MIG without installing the separate `nvidia-mig.raw` — and **shouldn't** install both (undefined sysext-merge ordering). See [docs/build-ci-notes.md](docs/build-ci-notes.md#mig-packaging-bundled-vs-standalone) for the tradeoffs. Release notes call out `MIG bundled: true|false` explicitly; the `bundle_mig` workflow input stays in place for the unbundled variant. `install-mig-sysext.sh --check` detects the bundled state and reports it as a single pass rather than three confusing failures.
- **Scale-build pipeline retired** in favor of a direct sysext build path.

## Repo Hygiene

- **Lint workflow.** `shellcheck --severity=warning` on every shell script under `scripts/`, plus `actionlint` (with embedded shellcheck) on workflow YAML.
- **Dependabot.** Weekly bumps for `github-actions`.
- **CHANGELOG.** This file — seeded from the post-dual-sysext baseline.
