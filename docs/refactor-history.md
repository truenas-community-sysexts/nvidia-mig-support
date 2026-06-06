# Refactor history: from scale-build to dual-sysext

> **Frozen snapshot.** This document captures the state of the project at the *end of the scale-build → dual-sysext refactor* (pre-org-move). Subsequent CI/install changes — immutable `v<truenas>-…-r<run>` release tags, `check-releases.yml` daily auto-cadence, the hardware-test gate, install-script flag set (`--check` / `--dry-run` / `--release=TAG`), preinit hardening, and PR #59's relocation of driver compilation from CI to the user's host (`build-on-host.sh`; `nvidia.raw` no longer a release asset) — are tracked in [CHANGELOG.md](../CHANGELOG.md) and [build-ci-notes.md](build-ci-notes.md). In particular, the "rolling `dev-{nvidia,mig}-sysext` release" mentioned in the table below was retired in favor of immutable per-run tags, and the per-stage scripts named below (`install-nvidia-sysext.sh`, separate build workflows) were later unified — the table reflects the dual-sysext snapshot, not current file names.

This refactor replaced a 5–6 hour [scale-build](https://github.com/truenas/scale-build) pipeline with two thin sysext build flows: a tiny lightweight MIG-only sysext (default) and an optional full-driver sysext (a native GitHub Actions runner port of [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater), no Docker). Validated end-to-end on hardware (TrueNAS 25.10.3.1 + RTX PRO 6000 Blackwell).

For day-to-day reference see [architecture.md](architecture.md) and [mig-persistence.md](mig-persistence.md). This doc is the design history — useful if you want to know *why* things ended up shaped the way they did.

## Final shape (as-built)

| Phase | Status | What it produced |
| --- | --- | --- |
| 1 — Lightweight `nvidia-mig.raw` | done | [scripts/build-mig-sysext.sh](../scripts/build-mig-sysext.sh), [scripts/install-mig-sysext.sh](../scripts/install-mig-sysext.sh), [scripts/uninstall-mig-sysext.sh](../scripts/uninstall-mig-sysext.sh), [.github/workflows/build-mig-sysext.yml](../.github/workflows/build-mig-sysext.yml), rolling `dev-mig-sysext` release |
| 2 — Full-driver `nvidia.raw` | done | [scripts/build-nvidia-sysext.sh](../scripts/build-nvidia-sysext.sh) (native-runner port of biohazardious), [scripts/install-nvidia-sysext.sh](../scripts/install-nvidia-sysext.sh), [scripts/uninstall-nvidia-sysext.sh](../scripts/uninstall-nvidia-sysext.sh), [scripts/nvidia-preinit-full.sh](../scripts/nvidia-preinit-full.sh), [scripts/recover-stock-nvidia.sh](../scripts/recover-stock-nvidia.sh), [.github/workflows/build-nvidia-sysext.yml](../.github/workflows/build-nvidia-sysext.yml), rolling `dev-nvidia-sysext` release |
| 3 — Consolidate post-install UX | done | [scripts/configure-mig.sh](../scripts/configure-mig.sh) bundled into both sysexts at `/usr/bin/configure-mig` |
| 4 — Demolish scale-build | done | `scale-build/` submodule, `build.yml`, `check-nvidia-driver.yml`, `check-truenas-release.yml`, `patch-driver-version.sh`, `strip-debug-packages.sh`, `create-dummy-packages.sh`, `setup-runner-vm.sh`, old `install.sh` / `restore.sh` / `nvidia-preinit.sh` — all deleted |
| 5 — Smart pool/persist-dir selection | done | Shared `resolve_persist_dir` helper duplicated across install/recover/configure scripts (intentional — keeps each script self-contained for `curl \| sudo bash`) |

## Key lessons captured during the refactor

These are also in the project's `agents.md` memory:

- **Sysext-shipped systemd units need PREINIT activation, not `WantedBy`.** A `[Install] WantedBy=multi-user.target` symlink (whether inside the sysext, after `systemctl enable`, or with `After=systemd-sysext.service` ordering) is not reliably honored at boot on TrueNAS. The unit ends up `enabled` but `inactive (dead)` with zero journal entries. The working pattern is a `midclt initshutdownscript` entry of `type=COMMAND`, `when=PREINIT`, running `systemctl start <unit>`.
- **Live driver swaps cause kernel/userspace mismatch.** Replacing `nvidia.raw` at runtime leaves the previous driver's kernel modules in memory. New userspace from the freshly-merged sysext then reports `Failed to initialize NVML: Driver/library version mismatch`. Fix: reboot. The full-driver install script prints an explicit reboot-required warning.
- **MIG UUIDs are deterministic across both reboots AND driver swaps** on Blackwell. Verified bit-identical UUIDs across a Proxmox host power cycle, a TrueNAS-only reboot, and a 570.172.08 → 580.126.18 driver swap. UUIDs are a function of GPU + profile config, not driver version. App GPU assignments don't need to be remapped on reboot in normal operation.
- **TrueNAS 25.10.x ships NVIDIA 570.172.08 on every `release/25.10.*` branch** (verified via the `conf/build.manifest` in each branch). Stock driver supports MIG on Blackwell — full-driver replacement is only needed if you specifically want a different version.

---

## Original pre-implementation plan (historical)

The sections below are the original design doc, written before any code was implemented. The as-built result differs from this plan in three notable ways:

1. **Two sysexts, not one.** The original plan was a single tiny `nvidia-mig.raw` paired with whatever TrueNAS shipped. The full-driver path was added during implementation when it became clear that arbitrary driver overrides (e.g. for users on TrueNAS releases with older drivers, or who need proprietary kernel modules) are a legitimate need.
2. **PREINIT, not WantedBy.** The original plan used `[Install] WantedBy=multi-user.target` for boot-time activation — this turned out not to work reliably on TrueNAS (see lessons above).
3. **`configure-mig` instead of folding everything into `install.sh`.** The original plan had `install.sh` accept `--mig-profiles` and do the interactive app assignment. Splitting that into a separate, repeatable `configure-mig` made re-tuning the MIG layout much easier and let the install scripts focus on sysext mechanics.

### Starting assumptions

1. IX Systems are no longer maintaining the scale-build platform
2. The 570.x drivers already included in TrueNAS support MIG (despite NVIDIA documentation suggesting 575+ is required)
3. TrueNAS 26.04 will include the 590.x series open drivers
4. The 590.x drivers will support MIG
5. `displaymodeselector` is still required for Workstation Edition GPUs to switch to compute mode before enabling MIG
6. The stock `nvidia.raw` sysext provides `nvidia-smi` (with all MIG subcommands); `nvidia-persistenced` is NOT included (we use `nvidia-smi -pm 1` instead)

### Original context

IX Systems is no longer maintaining the scale-build platform. TrueNAS 570.x drivers already support MIG, and 26.04 will ship 590.x open drivers. Since drivers are now included natively, we no longer need the 5–6 hour build pipeline that compiles NVIDIA 580.x drivers into a custom `nvidia.raw`. We only need to provide MIG setup tooling.

**Original goal:** Replace the heavy build-system approach with a tiny sysext (`nvidia-mig.raw`) that contains only the MIG setup script + systemd service. Buildable locally in <1 second with `mksquashfs`.

### Original before/after sketch

```text
BEFORE:
  nvidia.raw (stock) → replaced with custom nvidia.raw (drivers + MIG scripts)
  Built via scale-build on GitHub Actions (5–6 hours)

AFTER (as built):
  nvidia.raw (stock OR custom 580.x / 590.x) → drivers
  nvidia-mig.raw (lightweight path only, ~8 KB) → MIG setup script + service
  Both built on `ubuntu-24.04` GitHub Actions runners (mig: <1 s, nvidia: ~8 min)
```

### Why a separate sysext works

- `systemd-sysext` overlays multiple `.raw` files together — no file conflicts because each owns disjoint paths
- TrueNAS middleware only toggles the `nvidia` symlink in `/etc/extensions/`; a sysext named `nvidia-mig` is unaffected by `docker.update` toggles
- Uses `ID=_any` in extension-release (same pattern as stock TrueNAS sysexts)
- Lightweight sysext file lives on a ZFS pool in `/mnt/<pool>/.config/nvidia-gpu/` and is just symlinked into `/etc/extensions/` — no `/usr` modification needed, no ZFS readonly toggle, persists across TrueNAS updates without an active restore step
