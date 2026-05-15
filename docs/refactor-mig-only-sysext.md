# Refactor: Dual-Sysext (No scale-build)

## Status (2026-05-14, Phases 1 + 2 complete on hardware)

Both halves of the dual-sysext refactor are implemented and validated on a TrueNAS 25.10.3.1 box with an RTX PRO 6000 Blackwell.

### Phase 1 — lightweight `nvidia-mig.raw`

- `scripts/build-mig-sysext.sh` builds a 4 KB `nvidia-mig.raw` in <1 s via `mksquashfs`.
- `.github/workflows/build-mig-sysext.yml` rebuilds on every push to `refactor/dual-sysext` and auto-publishes to the rolling prerelease `dev-mig-sysext`.
- `scripts/install-mig-sysext.sh` deploys it. Pre-flight reads the host's stock driver major version from `libnvidia-ml.so.X.Y.Z` filenames inside the stock `nvidia.raw` (no driver load needed) and refuses on major <570 unless `--force`.
- `scripts/uninstall-mig-sysext.sh` reverses the deploy.

### Phase 2 — full-driver `nvidia.raw`

- `scripts/build-nvidia-sysext.sh` ports biohazardious/truenas-nvidia-driver-updater's entrypoint.sh to a native GitHub Actions runner (no Docker). ~8 min on `ubuntu-24.04`. Pulls the official TrueNAS `.update`, peels both squashfs layers to find kernel headers + the system module tree, cross-compiles the chosen NVIDIA driver against those headers, captures all new files via a /usr+/etc snapshot diff, generates a combined `modules.dep`, and packages the lot with `mksquashfs -comp gzip` and an `ID=_any` extension-release. Phase 5b bundles the MIG script + service so the resulting `nvidia.raw` is self-contained.
- `.github/workflows/build-nvidia-sysext.yml` is `workflow_dispatch`-only. Inputs: `nvidia_version`, `truenas_version`, `kernel_module_type`, `bundle_mig`, optional `release_tag`. (GitHub requires `workflow_dispatch` workflows on the default branch, so this YAML is also on `main` — it does nothing without an explicit dispatch.)
- `scripts/install-nvidia-sysext.sh` deploys the full sysext. Refuses to swap unless `nvidia-original.raw` is on hand (run `scripts/recover-stock-nvidia.sh` first if missing — that script extracts stock `nvidia.raw` from the official `.update` archive via the same two-level squashfs peel). Drains GPU, unmerges sysext, ZFS-writable, swaps the raw, restores readonly, re-merges, registers a PREINIT entry, re-enables Docker, prints a reboot-required warning.
- `scripts/nvidia-preinit-full.sh` is shipped to persistent storage and registered as PREINIT. Two responsibilities: (a) compare SHA of live `nvidia.raw` vs persistent custom and restore custom if /usr was wiped by a TrueNAS update; (b) start `nvidia-mig-setup.service` so MIG instances are recreated at boot.
- `scripts/uninstall-nvidia-sysext.sh` restores stock from `nvidia-original.raw`, deregisters PREINIT, clears persistent custom (keeps the stock backup).

### Key lessons captured along the way (see `agents.md` memory)

- **Sysext-shipped systemd units need PREINIT activation, not `WantedBy`.** A `[Install] WantedBy=multi-user.target` symlink (whether inside the sysext, after `systemctl enable`, or with `After=systemd-sysext.service` ordering) is not reliably honored at boot on TrueNAS. The unit ends up `enabled` but `inactive (dead)` with zero journal entries. The working pattern is a `midclt initshutdownscript` entry of `type=COMMAND`, `when=PREINIT`, running `systemctl start <unit>`.
- **Live driver swaps cause kernel/userspace mismatch.** Replacing `nvidia.raw` at runtime leaves the previous driver's kernel modules in memory. New userspace from the freshly-merged sysext then reports `Failed to initialize NVML: Driver/library version mismatch`. Fix: reboot. The full-driver install script prints an explicit reboot-required warning.
- **MIG UUIDs are deterministic across both reboots AND driver swaps** on Blackwell. Verified bit-identical UUIDs across a Proxmox host power cycle, a TrueNAS-only reboot, and a 570.172.08 → 580.126.18 driver swap. UUIDs are a function of GPU + profile config, not driver version.

### Outstanding work

- Phase 3 (optional): fold `install-mig-sysext.sh` + `install-nvidia-sysext.sh` into a unified `install.sh` with `--replace-driver=<version>` if a single-entry-point UX is desired. The two scripts work fine standalone.
- Phase 4: delete `scale-build/` submodule, `.github/workflows/build.yml`, `.github/workflows/check-nvidia-driver.yml`, `.github/workflows/check-truenas-release.yml`, `scripts/patch-driver-version.sh`, `scripts/strip-debug-packages.sh`, `scripts/create-dummy-packages.sh`, `scripts/setup-runner-vm.sh`, `.nvidia-driver-version`, old `install.sh`, old `restore.sh`, old `nvidia-preinit.sh`.
- README + `docs/architecture.md` rewrite for the dual-sysext model.

The original Phase 1 design from this doc (single-sysext, WantedBy-activated) is preserved below for historical reference; the as-built result differs in the ways noted above.

---

## Starting Assumptions

1. IX Systems are no longer maintaining the scale-build platform
2. The 570.x drivers already included in TrueNAS support MIG (despite NVIDIA documentation suggesting 575+ is required)
3. TrueNAS 26.04 will include the 590.x series open drivers
4. The 590.x drivers will support MIG
5. `displaymodeselector` is still required for Workstation Edition GPUs to switch to compute mode before enabling MIG
6. The stock `nvidia.raw` sysext provides `nvidia-smi` (with all MIG subcommands); `nvidia-persistenced` is NOT included (we use `nvidia-smi -pm 1` instead)

## Context

IX Systems is no longer maintaining the scale-build platform. TrueNAS 570.x drivers already support MIG, and 26.04 will ship 590.x open drivers. Since drivers are now included natively, we no longer need the 5-6 hour build pipeline that compiles NVIDIA 580.x drivers into a custom `nvidia.raw`. We only need to provide MIG setup tooling.

**Goal:** Replace the heavy build-system approach with a tiny sysext (`nvidia-mig.raw`) that contains only the MIG setup script + systemd service. Buildable locally in <1 second with `mksquashfs`.

## Architecture

```text
BEFORE:
  nvidia.raw (stock) → replaced with custom nvidia.raw (drivers + MIG scripts)
  Built via scale-build on GitHub Actions (5-6 hours)

AFTER:
  nvidia.raw (stock, untouched) → drivers provided by TrueNAS
  nvidia-mig.raw (tiny, ~4KB)  → MIG setup script + systemd service only
  Built locally with mksquashfs (<1 second)
```

**Why a separate sysext works:**

- systemd-sysext overlays multiple `.raw` files together — no file conflicts (stock has drivers, ours has MIG scripts)
- TrueNAS middleware only toggles the `nvidia` symlink; a sysext named `nvidia-mig` is unaffected by `docker.update` toggles
- Uses `ID=_any` in extension-release (same pattern as stock sysexts)

**Symlink approach (no /usr modification needed):**

- Store `nvidia-mig.raw` in persistent storage: `/mnt/<pool>/.config/nvidia-gpu/nvidia-mig.raw`
- Symlink from `/etc/extensions/nvidia-mig.raw` → persistent storage path
- `/etc/` is writable, so no ZFS readonly toggle needed
- PREINIT script recreates symlink after TrueNAS updates (which may reset `/etc/extensions/`)

## Implementation Steps

### 1. Create `scripts/build-sysext.sh` (~30 lines, new file)

Builds `nvidia-mig.raw` from the existing `sysext/` directory contents:

- Copies `sysext/usr/bin/nvidia-mig-setup` and `sysext/usr/lib/systemd/system/nvidia-mig-setup.service`
- Creates `usr/lib/extension-release.d/extension-release.nvidia-mig` with `ID=_any`
- Creates WantedBy symlink: `usr/lib/systemd/system/multi-user.target.wants/nvidia-mig-setup.service`
- Accepts optional displaymodeselector path as argument, injects into `usr/bin/` (still required for Workstation Edition GPUs to switch to compute mode before MIG)
- Runs `mksquashfs ... nvidia-mig.raw -noappend -comp zstd`
- Generates `nvidia-mig.raw.sha256`

### 2. Rewrite `scripts/install.sh` (~350 lines, down from 828)

**Remove:**

- GitHub release download logic — sysext built locally or provided as arg
- nvidia.raw replacement dance: unmerge, ZFS writable, backup, copy, ZFS readonly, merge
- nvidia.raw backup to persistent storage
- Original nvidia.raw backup
- All `[diag]` re-merge safety nets for middleware async remount — our sysext isn't affected by `docker.update`
- Docker stop/start just for sysext installation — not needed since we're not replacing the driver sysext

**Keep/adapt:**

- CLI argument parsing (`--mig-profiles`, `--pool`, `--persist-path`) — keep as-is
- Pool auto-detection — keep as-is
- displaymodeselector detection + injection — move to build-sysext.sh call
- MIG mode enable + instance creation — keep as-is
- Interactive MIG-to-app assignment loop — keep as-is
- PREINIT registration via midclt — keep, update script content
- mig.conf writing — keep as-is

**New install flow:**

1. Parse arguments
2. Build `nvidia-mig.raw` (call `build-sysext.sh`, or use `--sysext=path`)
3. Detect/create persistent storage dir
4. Copy `nvidia-mig.raw` to persistent storage
5. Create symlink: `ln -sf $PERSIST_DIR/nvidia-mig.raw /etc/extensions/nvidia-mig.raw`
6. `systemd-sysext merge` + `systemctl daemon-reload`
7. Verify `nvidia-mig-setup` is accessible
8. If `--mig-profiles` given:
   - Disable Docker (need GPU processes stopped for MIG)
   - Enable MIG mode, create instances
   - Write `mig.conf`
   - Re-enable Docker, wait for apps
   - Interactive app assignment
9. Write PREINIT script, register via midclt
10. Summary output

**Key change:** Docker stop/start is only needed for MIG setup (GPU must be free), NOT for sysext installation.

### 3. Rewrite `scripts/nvidia-preinit.sh` (~40 lines, down from 112)

**Remove:**

- SHA256 comparison of nvidia.raw (no longer replacing driver sysext)
- ZFS writable/readonly toggle (no /usr modification)
- nvidia.raw copy logic

**New PREINIT flow:**

1. Find persistent config via glob (`/mnt/*/.config/nvidia-gpu/`)
2. Ensure `/etc/extensions/nvidia-mig.raw` symlink exists → persistent storage
3. If symlink was missing/wrong: `systemd-sysext merge` + `systemctl daemon-reload`
4. Start `nvidia-mig-setup.service` (recreates MIG instances + remaps UUIDs)
5. Re-enable NVIDIA in Docker: `midclt call docker.update '{"nvidia": true}'`

### 4. Simplify `scripts/restore.sh` (~80 lines, down from 179)

**Remove:**

- nvidia.raw swap logic (not replacing driver sysext)
- ZFS writable/readonly toggle

**New restore flow:**

1. Stop Docker
2. Wait for GPU processes to exit
3. Destroy MIG instances, disable MIG mode
4. Remove `/etc/extensions/nvidia-mig.raw` symlink
5. `systemd-sysext merge` (re-merge without our extension)
6. Deregister PREINIT script via midclt
7. Remove persistent config dir
8. Re-enable Docker

### 5. Remove build system artifacts

**Delete files:**

- `.github/workflows/build.yml` (600-line build pipeline)
- `.github/workflows/check-nvidia-driver.yml` (driver version checker)
- `.github/workflows/check-truenas-release.yml` (release checker — sysext is version-independent)
- `.gitmodules` (scale-build submodule reference)
- `scale-build/` (submodule — `git rm scale-build`)
- `scripts/patch-driver-version.sh`
- `scripts/strip-debug-packages.sh`
- `scripts/create-dummy-packages.sh`
- `scripts/setup-runner-vm.sh`
- `.nvidia-driver-version`

**Keep:**

- `version`, `train` — useful for release context

### 6. Create simple GitHub Actions workflow

Replace the 600-line build.yml with a ~50-line workflow:

- Trigger: manual dispatch or tag push
- Steps: checkout, run `build-sysext.sh`, create GitHub release with `nvidia-mig.raw` + install/restore scripts

### 7. Update documentation

- `README.md` — rewrite for new lightweight approach
- `docs/architecture.md` — document dual-sysext model
- `docs/mig-persistence.md` — document simplified PREINIT flow
- `docs/mig-profiles.md` — keep as-is (still accurate)

### 8. Update `sysext/usr/bin/nvidia-mig-setup` comment

Line 3 says "Baked into nvidia.raw sysext" — update to "Baked into nvidia-mig.raw sysext"

## Files Summary

| File                                                      | Action                          |
| --------------------------------------------------------- | ------------------------------- |
| `scripts/build-sysext.sh`                                 | Create (~30 lines)              |
| `scripts/install.sh`                                      | Rewrite (~350 lines, was 828)   |
| `scripts/nvidia-preinit.sh`                               | Rewrite (~40 lines, was 112)    |
| `scripts/restore.sh`                                      | Simplify (~80 lines, was 179)   |
| `sysext/usr/bin/nvidia-mig-setup`                         | Minor comment update            |
| `sysext/usr/lib/systemd/system/nvidia-mig-setup.service`  | Keep as-is                      |
| `.github/workflows/build.yml`                             | Replace with simple workflow    |
| `.github/workflows/check-nvidia-driver.yml`               | Delete                          |
| `.github/workflows/check-truenas-release.yml`             | Delete                          |
| `scripts/patch-driver-version.sh`                         | Delete                          |
| `scripts/strip-debug-packages.sh`                         | Delete                          |
| `scripts/create-dummy-packages.sh`                        | Delete                          |
| `scripts/setup-runner-vm.sh`                              | Delete                          |
| `.nvidia-driver-version`                                  | Delete                          |
| `.gitmodules`                                             | Delete                          |
| `scale-build/`                                            | Remove submodule                |
| `README.md`                                               | Rewrite                         |
| `docs/architecture.md`                                    | Rewrite                         |
| `docs/mig-persistence.md`                                 | Rewrite                         |

## Verification

1. **Build:** Run `scripts/build-sysext.sh` locally — should produce `nvidia-mig.raw` in <1s
2. **Inspect:** `unsquashfs -l nvidia-mig.raw` — verify it contains only MIG script, service, extension-release, and WantedBy symlink
3. **On TrueNAS 26.04:** Run `install.sh --mig-profiles=14,14,14,14 --pool=<pool>` — verify:
   - `nvidia-mig.raw` symlinked in `/etc/extensions/`
   - `systemd-sysext status` shows both `nvidia` and `nvidia-mig` extensions
   - `nvidia-mig-setup` is executable at `/usr/bin/nvidia-mig-setup`
   - MIG instances created successfully
   - `mig.conf` written to persistent storage
   - PREINIT script registered
4. **Reboot test:** Reboot TrueNAS — verify MIG instances recreated, app UUIDs remapped
5. **Restore test:** Run `restore.sh` — verify clean removal
