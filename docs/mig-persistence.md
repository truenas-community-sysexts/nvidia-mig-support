# MIG Persistence: surviving reboots and TrueNAS updates

MIG instances on Blackwell don't survive reboots, and TrueNAS updates rewrite `/usr` from scratch. This doc explains how `nvidia-mig.raw` keeps MIG working across both.

The NVIDIA driver's own persistence across updates is handled by [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support) when a custom driver is installed; the stock driver needs none. This doc covers only the MIG layer.

## What persists where

| Location | Survives reboot | Survives TrueNAS update |
| --- | --- | --- |
| `/usr/` (merged sysext content, systemd units) | Yes | **No** (recreated from stock rootfs) |
| `/etc/` (writable, includes `/etc/extensions/` symlinks) | Yes | Mostly |
| `/mnt/<pool>/` (ZFS data pool) | Yes | Yes |
| TrueNAS middleware DB (PREINIT entries, app GPU assignments) | Yes | Yes |
| GPU firmware (MIG mode, compute-mode selection) | Yes | Yes |
| MIG instances themselves | **No** | **No** |

## What runs on every boot

The install registers a TrueNAS PREINIT entry via `midclt initshutdownscript.create`. PREINIT runs early in boot, before `docker.service`, after `systemd-sysext` has merged `/usr`. PREINIT entries live in TrueNAS's middleware DB, so they survive updates.

A single command:

```sh
/usr/bin/systemctl start nvidia-mig-setup.service
```

The service is shipped inside `nvidia-mig.raw`. Once started, it reads `mig.conf` from persistent storage and creates the MIG instances. The driver `nvidia.raw` is untouched by this repo, so there's nothing of ours to restore after a TrueNAS update — the symlink in `/etc/extensions/nvidia-mig.raw` points at the persistent copy on `/mnt/<pool>/`, which survives.

## What `nvidia-mig-setup.service` actually does

The unit is `Type=oneshot RemainAfterExit=yes`. `ExecStart=/usr/bin/nvidia-mig-setup`, a bash script that:

1. Polls up to 60 s for the NVIDIA driver to become responsive (`nvidia-smi -L` succeeds — not just for the binary to exist). Subsumes the races where the sysext is still merging or udev/modprobe is still loading the kernel module.
2. Reads `MIG_PROFILES` from `/mnt/<pool>/.config/nvidia-gpu/mig.conf` (glob — any pool name works).
3. Enables MIG mode if not enabled (`nvidia-smi -mig 1`).
4. Destroys any existing MIG instances, then creates new ones from the profile list.
5. Enumerates the new MIG UUIDs via `nvidia-smi -L`.
6. Polls up to 25 s for TrueNAS middleware to be ready (`midclt call system.ready`).
7. Looks up the NVIDIA GPU's PCI slot via `midclt call app.gpu_choices`.
8. Walks `midclt call app.query`, finds apps with stale MIG UUID assignments (UUIDs that no longer exist), and remaps them to the first available MIG UUID.
9. Always exits 0 — never blocks boot.

MIG UUIDs are **deterministic** on Blackwell — same GPU + same profile config in same order produces bit-identical UUIDs across reboots, driver swaps, and host power cycles. So in normal operation step 8 is a no-op; only when the MIG layout itself changes do apps actually need remapping.

## Persistent storage layout

```text
/mnt/<pool>/.config/nvidia-gpu/
  nvidia-mig.raw               # MIG sysext (this repo)
  mig.conf                     # MIG_PROFILES=14,14,14,14
```

(nvidia-driver-support uses the same directory for its own driver files; those are left alone by the MIG scripts.)

Pool auto-detected as the first non-`boot-pool` from `zpool list`. Override with `--pool=NAME` or `--persist-path=PATH` on any install/uninstall script.

## Boot timing

```text
1. Kernel boots, modules load (driver from nvidia.raw — stock or custom)
2. systemd-sysext merges nvidia.raw + nvidia-mig.raw + hailo.raw
3. systemctl daemon-reload picks up nvidia-mig-setup.service
   (which declares Before=docker.service)
4. TrueNAS middleware starts
5. PREINIT entry runs: systemctl start nvidia-mig-setup.service
6. nvidia-mig-setup polls until `nvidia-smi -L` succeeds, reads mig.conf
7. MIG mode enable + instance creation + app remap (if needed)
8. docker.service starts (ordered after nvidia-mig-setup.service) →
   instances exist, so containers claim MIG UUIDs cleanly
```

Total nvidia-mig-setup runtime: typically ~45 s (most of it the middleware-ready poll).

### Why docker.service is ordered after MIG setup

Step 8 is **not** incidental ordering — it's enforced by `Before=docker.service` in `nvidia-mig-setup.service` (the same convention the sibling `hailo-load.service` / `coral-load.service` use). MIG instances don't survive a reboot (table above), and TrueNAS apps default to `restart=unless-stopped`, so dockerd would otherwise restart GPU/MIG containers in parallel with — and typically *before* — instance creation at step 7. A container that restarts before its MIG device exists crashes at task creation (`failed to get device handle from UUID: Not Found`). The ordering makes dockerd wait, so the `unless-stopped` restart lands on devices that already exist.

**Tradeoff:** because docker now waits for the whole `nvidia-mig-setup.service` to exit — including its bounded (≤25 s) middleware-ready poll — *all* app startup (GPU or not) is delayed until MIG setup finishes, typically adding tens of seconds to boot. A future optimization is to split instance creation (no middleware dependency) from app remap and gate docker on only the former; for now correctness is preferred over boot speed.

**Deadlock-safe:** instance creation (step 7's first half) happens *before* the middleware poll, and the poll times out and proceeds rather than blocking. So even if middleware readiness transitively depended on docker, `nvidia-mig-setup` still exits and releases docker.

**Why the sysext-delivered ordering is loaded before docker (not too late):** `systemd-sysext.service` is guaranteed to finish before `basic.target` (per `systemd-sysext(8)`), so the merged `nvidia-mig-setup.service` is present before any regular service initializes. `EXTENSION_RELOAD_MANAGER=1` (set in the sysext's `extension-release`) reloads PID 1 after the merge, so the `Before=docker.service` edge is registered. `docker.service` is a regular, `DefaultDependencies=yes` service ordered after `basic.target`, so it starts only once both have happened — the ordering is in effect every boot, with no `/etc` copy required. (This is proven in production by the sibling `hailo-load.service` / `coral-load.service`, which appear in `docker.service`'s resolved `After=` via the identical mechanism.)

## Uninstall

`uninstall-mig-sysext.sh` (bundled as `/usr/bin/uninstall-nvidia-mig`) removes the `/etc/extensions/nvidia-mig.raw` symlink, re-merges the sysext, and deregisters the MIG PREINIT — the driver is untouched, no reboot. When MIG mode is currently Enabled on the GPU it also tears down the runtime side: apps with `MIG-*` UUIDs in `nvidia_gpu_selection` are reassigned to the full-GPU UUID on the same PCI slot, MIG instances destroyed, MIG mode disabled, and `mig.conf` cleaned from the persist dir. Without this teardown, apps would fail to start post-reboot with a stale-UUID error.

## Why this design

The previous approach used a sysext-shipped systemd unit with `[Install] WantedBy=multi-user.target` and tried to make it auto-start at boot. That doesn't work on TrueNAS — the unit ended up `enabled` but `inactive (dead)` with zero journal entries, across reboots, with `systemctl enable`, `After=systemd-sysext.service`, and other approaches. The root cause is TrueNAS's middleware-driven boot model: standard systemd `WantedBy` for sysext-shipped units isn't reliably honored.

TrueNAS's PREINIT mechanism, on the other hand, is the canonical way the platform handles "run this before services start," so the design uses PREINIT to start the MIG service each boot.
