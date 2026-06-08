# Architecture

This repo produces **one** systemd-sysext extension for TrueNAS SCALE on an NVIDIA Blackwell host — `nvidia-mig.raw`, the MIG tooling — plus a small set of management scripts. It layers on top of whatever NVIDIA driver is already present.

The NVIDIA driver itself is a separate project: [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support). This repo used to build/swap the driver too (the old `--with-driver` path); that has been split out. See [refactor-history.md](refactor-history.md).

## Workstation Edition one-time setup

NVIDIA Workstation Edition cards (RTX PRO 6000 included) ship in **graphics mode** by default. MIG requires **compute mode**. The mode is **stored in GPU firmware** — once switched, it persists across reboots, driver swaps, and OS reinstalls. You only do this once per physical card.

If `nvidia-smi -mig 1` fails on a Workstation Edition card with a permission-style error, you need `displaymodeselector`. NVIDIA distributes it separately from the driver:

1. Download "DisplayModeSelector Tool" from the [NVIDIA developer portal](https://developer.nvidia.com/displaymodeselector) (free account required, approval usually immediate)
2. Extract: `tar xzf DisplayModeSelector-*.tar.gz`
3. SCP the binary to TrueNAS, then:

   ```bash
   chmod +x displaymodeselector
   sudo ./displaymodeselector --gpumode compute
   sudo reboot
   ```

Note: `/home`, `/tmp`, and `/data` on TrueNAS are mounted `noexec`. Run `displaymodeselector` from somewhere it can execute (move it into `/root` or run via the dynamic linker: `/lib64/ld-linux-x86-64.so.2 ./displaymodeselector ...`).

Server Edition cards and previous-gen workstation cards (e.g. RTX A6000) don't need this — they ship in compute mode.

## High-level

```text
                ┌─────────────────────────────────────────────────────────┐
                │                  TrueNAS host                            │
                │                                                          │
  ┌────────┐    │   /usr/share/truenas/sysext-extensions/                  │
  │  GPU   │    │     ├─ nvidia.raw      (the driver — stock, or installed │
  │ (B6000)│◄───┤     │                   via nvidia-driver-support)       │
  └────────┘    │     ├─ hailo.raw       (untouched by us)                │
                │     └─ nvidia-mig.raw  (this repo)                      │
                │                                                          │
                │   /etc/extensions/                                       │
                │     ├─ nvidia.raw      → symlink to the driver           │
                │     └─ nvidia-mig.raw  → symlink to the persistent copy  │
                │                                                          │
                │   /mnt/<pool>/.config/nvidia-gpu/                        │
                │     ├─ nvidia-mig.raw  (this repo's sysext)             │
                │     └─ mig.conf        (MIG_PROFILES=...)               │
                └─────────────────────────────────────────────────────────┘
```

The GPU sees one merged userspace via `systemd-sysext`. Multiple `.raw` extensions overlay onto `/usr` together — no file conflicts because each owns disjoint paths.

## What's in `nvidia-mig.raw`

```text
       nvidia.raw (the driver, ≥ 570 for MIG — not ours)
            +
       hailo.raw (untouched)
            +
       nvidia-mig.raw (this repo, ~8 KB, ID=_any)
              │
              ├─ /usr/bin/nvidia-mig-setup          (boot-time creator)
              ├─ /usr/bin/configure-mig             (interactive setup)
              ├─ /usr/bin/uninstall-nvidia-mig      (teardown)
              ├─ /usr/lib/systemd/system/nvidia-mig-setup.service
              │                                     (Before=docker.service)
              └─ /usr/lib/extension-release.d/extension-release.nvidia-mig  (ID=_any)
```

`ID=_any` and no kernel module: the sysext is driver- and kernel-agnostic, so one release works on any TrueNAS version / driver version that's new enough for MIG. Built locally in <1 s via `mksquashfs` ([scripts/build-mig-sysext.sh](../scripts/build-mig-sysext.sh)). See [build-ci-notes.md](build-ci-notes.md) for the release scheme.

## Boot-time activation: TrueNAS PREINIT

The MIG setup service does NOT use `[Install] WantedBy=multi-user.target`. On TrueNAS, a sysext-shipped WantedBy symlink (or even `systemctl enable` post-merge) is not reliably honored at boot — the unit ends up `enabled` but `inactive (dead)` with zero journal entries. Confirmed across multiple reboots.

The working pattern is TrueNAS's middleware-driven PREINIT mechanism:

```text
                  TrueNAS boot
                       │
                       ▼
              systemd-sysext merges
              nvidia.raw + nvidia-mig.raw
                       │
                       ▼
        midclt-registered PREINIT entry runs
        (when=PREINIT, type=COMMAND, before Docker)
                       │
                       ▼
        "systemctl start nvidia-mig-setup.service"
        (mig-setup polls for the driver to become
         responsive before creating instances)
                       │
                       ▼
              docker.service starts
              (ordered after nvidia-mig-setup.service via
               its Before=docker.service — instances exist,
               so containers claim MIG UUIDs cleanly)
```

`nvidia-mig-setup.service` is `Type=oneshot RemainAfterExit=yes` — once started this boot, `systemctl start` is a no-op. `configure-mig` uses `systemctl restart` when it needs to re-apply a new `mig.conf`.

The PREINIT starts the MIG service early, but the **ordering that actually prevents the boot race** is `Before=docker.service` declared in `nvidia-mig-setup.service` (the same convention the sibling `hailo-load.service` / `coral-load.service` use). Without it, dockerd starts in parallel and its `restart=unless-stopped` policy recreates GPU/MIG containers *before* the instances exist — they crash at task creation with `failed to get device handle from UUID: Not Found`. MIG instances do **not** survive a reboot, so this race is hit on every boot, not just driver swaps. It's deadlock-safe: `nvidia-mig-setup` creates the instances before its bounded (25 s) middleware wait and never blocks boot, so it always exits and releases docker. See [troubleshooting.md](troubleshooting.md) and [mig-persistence.md](mig-persistence.md).

The driver's own persistence (surviving a TrueNAS update that wipes `/usr`) is handled by nvidia-driver-support's PREINIT when a custom driver is installed; the stock driver needs none. Either way it's independent of the MIG PREINIT — `nvidia-mig-setup` waits for the driver to become responsive (`nvidia-smi -L` succeeds), so firing order doesn't matter.

## Persistent storage layout

Everything this repo must survive a TrueNAS update lives under `/mnt/<pool>/.config/nvidia-gpu/`:

| File | Purpose |
| --- | --- |
| `nvidia-mig.raw` | MIG sysext (always). Symlinked from `/etc/extensions/`. |
| `mig.conf` | `MIG_PROFILES=14,14,14,14` style config read by `nvidia-mig-setup`. |

The same directory is also used by nvidia-driver-support for its own files (driver backup, custom `nvidia.raw`, etc.) — those belong to that project and are left alone by the MIG scripts.

## Validated hardware

- **GPU**: NVIDIA RTX PRO 6000 Blackwell Workstation Edition (96 GB)
- **TrueNAS**: SCALE 25.10.3.1 (codename Goldeye)
- **Stock driver**: 570.172.08 (supports MIG on this card — hardware-confirmed)

MIG UUIDs are deterministic — same GPU + same profile config produces bit-identical UUIDs across host power cycles, TrueNAS reboots, and driver swaps.
