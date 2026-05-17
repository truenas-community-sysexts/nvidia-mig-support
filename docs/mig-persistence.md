# MIG Persistence: surviving reboots and TrueNAS updates

MIG instances on Blackwell don't survive reboots, and TrueNAS updates rewrite `/usr` from scratch. This doc explains how the two-sysext model handles both, and what to expect under each install variant of `install-mig-sysext.sh` (default vs `--with-driver`).

## What persists where

| Location | Survives reboot | Survives TrueNAS update |
| --- | --- | --- |
| `/usr/` (merged sysext content, systemd units) | Yes | **No** (recreated from stock rootfs) |
| `/etc/` (writable, includes `/etc/extensions/` symlinks and `/etc/systemd/system/.wants/`) | Yes | Mostly — `/etc/extensions/nvidia.raw` symlink may be rewritten by middleware |
| `/mnt/<pool>/` (ZFS data pool) | Yes | Yes |
| TrueNAS middleware DB (PREINIT entries, app GPU assignments) | Yes | Yes |
| GPU firmware (MIG mode, compute-mode selection) | Yes | Yes |
| MIG instances themselves | **No** | **No** |

## What runs on every boot

Both install paths register a TrueNAS PREINIT entry via `midclt initshutdownscript.create`. PREINIT runs early in boot, before `docker.service`, after `systemd-sysext` has merged `/usr`. PREINIT entries live in TrueNAS's middleware DB, so they survive updates.

### Default path: one PREINIT

A single command:

```sh
/usr/bin/systemctl start nvidia-mig-setup.service
```

That's it. The service is shipped inside `nvidia-mig.raw`. Once started, it reads `mig.conf` from persistent storage and creates the MIG instances. The stock `nvidia.raw` is untouched, so there's nothing to restore after a TrueNAS update — the sysext symlink in `/etc/extensions/nvidia-mig.raw` points at the persistent copy on `/mnt/<pool>/`, which survives.

### --with-driver path: two PREINITs

`install-mig-sysext.sh --with-driver` registers a **second** PREINIT alongside the MIG one. The driver PREINIT runs `/mnt/<pool>/.config/nvidia-gpu/nvidia-preinit-driver.sh`, which:

1. Compares SHA256 of the live `/usr/share/truenas/sysext-extensions/nvidia.raw` against the persistent custom `/mnt/<pool>/.config/nvidia-gpu/nvidia.raw`.
2. If they match → normal boot. Nothing to do here.
3. If they differ → TrueNAS update happened, `/usr` was wiped, stock driver is back. Re-apply the custom: `systemd-sysext unmerge` → `zfs set readonly=off /usr` → `cp` custom over live → `zfs set readonly=on` → ensure `/etc/extensions/nvidia.raw` symlink → `systemd-sysext merge` → `systemctl daemon-reload`.
4. Logs kernel-version mismatch if `nvidia.ko`'s `vermagic` doesn't match the running kernel.

The driver PREINIT does **not** start the MIG service — that's the MIG PREINIT's job. Splitting the two means the driver script is concerned only with driver state, and the MIG-side wait for the driver to become responsive (see below) lets the two PREINITs fire in any order without coordination.

The script is installed once during `install-mig-sysext.sh --with-driver` and re-registered after every update because the PREINIT DB entry persists.

## What `nvidia-mig-setup.service` actually does

The unit is `Type=oneshot RemainAfterExit=yes`. `ExecStart=/usr/bin/nvidia-mig-setup`, which is a bash script that:

1. Polls up to 60 s for the NVIDIA driver to become responsive (`nvidia-smi -L` succeeds — not just for the binary to exist). Subsumes three races: stock sysext still merging, sibling driver PREINIT still restoring a custom `nvidia.raw`, and udev/modprobe still loading the kernel module.
2. Reads `MIG_PROFILES` from `/mnt/<pool>/.config/nvidia-gpu/mig.conf` (glob — any pool name works).
3. Enables MIG mode if not enabled (`nvidia-smi -mig 1`).
4. Destroys any existing MIG instances, then creates new ones from the profile list.
5. Enumerates the new MIG UUIDs via `nvidia-smi -L`.
6. Polls up to 25 s for TrueNAS middleware to be ready (`midclt call system.ready`).
7. Looks up the NVIDIA GPU's PCI slot via `midclt call app.gpu_choices`.
8. Walks `midclt call app.query`, finds apps with stale MIG UUID assignments (UUIDs that no longer exist), and remaps them to the first available MIG UUID.
9. Always exits 0 — never blocks boot.

MIG UUIDs are **deterministic** on Blackwell — same GPU + same profile config in same order produces bit-identical UUIDs across reboots, driver swaps, and Proxmox host power cycles. So in normal operation step 8 is a no-op; only when the MIG layout itself changes do apps actually need remapping.

## Persistent storage layout

```text
/mnt/<pool>/.config/nvidia-gpu/
  nvidia-original.raw          # stock backup (kept across uninstalls)
  nvidia.raw                   # custom driver (--with-driver path only)
  nvidia-mig.raw               # MIG sysext (always)
  mig.conf                     # MIG_PROFILES=14,14,14,14
  nvidia-preinit-driver.sh     # driver PREINIT (--with-driver path only)
```

Pool auto-detected as the first non-`boot-pool` from `zpool list`. Override with `--pool=NAME` or `--persist-path=PATH` on any install/uninstall script.

## Boot timing per path

### Default path

```text
1. Kernel boots, modules load (stock 570.x driver from stock nvidia.raw)
2. systemd-sysext merges nvidia.raw + nvidia-mig.raw + hailo.raw
3. systemctl daemon-reload picks up nvidia-mig-setup.service unit
4. TrueNAS middleware starts
5. PREINIT entry runs: systemctl start nvidia-mig-setup.service
6. nvidia-mig-setup polls until `nvidia-smi -L` succeeds, reads mig.conf
7. MIG mode enable + instance creation + app remap (if needed)
8. docker.service starts → containers can claim MIG UUIDs
```

Total nvidia-mig-setup runtime: typically ~45 s (most of it the middleware-ready poll).

### --with-driver path

```text
1. Kernel boots, modules load from /usr/lib/modules/<kernel>/video/ (custom driver)
2. systemd-sysext merges nvidia.raw (custom) + nvidia-mig.raw + hailo.raw
3. systemctl daemon-reload picks up nvidia-mig-setup.service unit
4. TrueNAS middleware starts
5. Two PREINIT entries run (order doesn't matter):
   a. nvidia-preinit-driver.sh
        - compares SHA(live) vs SHA(persistent custom)
        - if same: skip restore (normal boot)
        - if different: full restore dance (TrueNAS update happened)
        - logs any kernel-version mismatch
   b. systemctl start nvidia-mig-setup.service
        - polls until `nvidia-smi -L` succeeds (handles any in-flight
          restore from (a) above OR udev module-load latency)
        - MIG enable + create + remap
6. docker.service starts
```

After a TrueNAS update the first boot is longer (the restore dance adds 5–10 s). Subsequent boots are the same as the default path.

## Uninstall / restore

| Script | What it undoes |
| --- | --- |
| `uninstall-mig-sysext.sh` *(bundled as `/usr/bin/uninstall-nvidia-mig`)* | Auto-detects state. **MIG-only**: removes `/etc/extensions/nvidia-mig.raw` symlink, re-merges sysext, deregisters MIG PREINIT — stock driver untouched, no reboot. **MIG + custom driver**: also stops apps, drains GPU, restores stock `nvidia.raw` from `nvidia-original.raw`, deregisters the driver PREINIT — **reboot required** to load matching kernel modules. The stock backup is preserved across uninstalls. **Plus** (when MIG mode is currently Enabled on the GPU, either path): tears down the runtime side of MIG — apps with `MIG-*` UUIDs in `nvidia_gpu_selection` get reassigned to the full-GPU UUID on the same PCI slot, MIG instances destroyed, MIG mode disabled, `mig.conf` cleaned from the persist dir. Without this teardown, apps would fail to start post-reboot with a stale-UUID error. |
| `recover-stock-nvidia.sh` | Extracts a fresh stock `nvidia.raw` from the official TrueNAS `.update` archive (two-level squashfs peel). Use when no `nvidia-original.raw` backup exists. |

## Why this design

The previous approach used a sysext-shipped systemd unit with `[Install] WantedBy=multi-user.target` and tried to make it auto-start at boot. That doesn't work on TrueNAS — the unit ended up `enabled` but `inactive (dead)` with zero journal entries, across reboots, with `systemctl enable`, `After=systemd-sysext.service`, and various other approaches. The root cause is TrueNAS's middleware-driven boot model: standard systemd `WantedBy` for sysext-shipped units isn't reliably honored.

TrueNAS's PREINIT mechanism, on the other hand, is the canonical way the platform handles "run this before services start" — it's how the project's previous full-driver install handled re-applying `nvidia.raw` after updates. The new design uses PREINIT for both responsibilities (re-apply after update, start MIG service) with the same mechanism.
