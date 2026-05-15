# Architecture: dual-sysext model

This repo produces **two** systemd-sysext extensions for TrueNAS SCALE on an NVIDIA Blackwell host, plus a small set of management scripts. Users pick one of two install paths depending on whether they trust the driver TrueNAS ships or need a specific version.

Replaces the previous scale-build-based pipeline. See `refactor-mig-only-sysext.md` for history.

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

```
                ┌─────────────────────────────────────────────────────────┐
                │                  TrueNAS host                            │
                │                                                          │
  ┌────────┐    │   /usr/share/truenas/sysext-extensions/                  │
  │  GPU   │    │     ├─ nvidia.raw      (stock OR custom, see below)     │
  │ (B6000)│◄───┤     ├─ hailo.raw       (untouched by us)                │
  └────────┘    │     └─ nvidia-mig.raw  (only on lightweight path)       │
                │                                                          │
                │   /etc/extensions/                                       │
                │     ├─ nvidia.raw      → symlink to above                │
                │     └─ nvidia-mig.raw  → symlink                         │
                │                                                          │
                │   /mnt/<pool>/.config/nvidia-gpu/                        │
                │     ├─ nvidia-original.raw  (stock backup, always kept) │
                │     ├─ nvidia.raw           (custom, full-driver path)  │
                │     ├─ nvidia-mig.raw       (lightweight path)          │
                │     ├─ mig.conf             (MIG_PROFILES=...)          │
                │     └─ nvidia-preinit-full.sh (full-driver path only)   │
                └─────────────────────────────────────────────────────────┘
```

The GPU sees one merged userspace via `systemd-sysext`. Multiple `.raw` extensions overlay onto `/usr` together — no file conflicts because each owns disjoint paths.

## The two install paths

### Lightweight path (`nvidia-mig.raw`)

Adds MIG tooling on top of TrueNAS's stock NVIDIA driver. The stock `nvidia.raw` is untouched.

```
       nvidia.raw (stock, 570.172.08 on 25.10.x)
            +
       hailo.raw (untouched)
            +
       nvidia-mig.raw (this repo, ~8 KB)
              │
              ├─ /usr/bin/nvidia-mig-setup          (boot-time creator)
              ├─ /usr/bin/configure-mig             (interactive setup)
              ├─ /usr/lib/systemd/system/nvidia-mig-setup.service
              └─ /usr/lib/extension-release.d/extension-release.nvidia-mig  (ID=_any)
```

Built locally in <1 s via `mksquashfs`. Auto-published to the `dev-mig-sysext` rolling prerelease on every push.

### Full-driver path (`nvidia.raw`)

Replaces the stock `nvidia.raw` with one containing a different driver version (e.g. 580.126.18 or 590.44.01), plus bundled MIG tooling so the sysext is self-sufficient.

```
       nvidia.raw (custom, ~470 MB)
            │
            ├─ NVIDIA driver (libs, .ko modules, nvidia-smi, …)
            ├─ nvidia-container-toolkit
            ├─ /usr/bin/nvidia-mig-setup           (boot-time creator)
            ├─ /usr/bin/configure-mig              (interactive setup)
            └─ /usr/lib/systemd/system/nvidia-mig-setup.service
```

Built on an `ubuntu-24.04` GitHub Actions runner (no Docker) in ~8 min. Ports biohazardious/truenas-nvidia-driver-updater's `entrypoint.sh`:

1. Download the official TrueNAS `.update` archive
2. Peel the outer squashfs → `rootfs.squashfs` → extract `usr/src` + `usr/lib/modules`
3. Detect the production kernel + matching headers (production over debug)
4. Install `nvidia-container-toolkit` from NVIDIA's apt repo into the runner's `/usr`
5. Cross-compile the chosen NVIDIA driver against the extracted headers (`--no-drm`, gcc-14)
6. Snapshot diff of `/usr`+`/etc` before/after to find every installer-added file
7. Stage all new files into a clean tree, remap `/etc/OpenCL`, `/etc/vulkan`, `/etc/nvidia-container-*` → `/usr/share/...`
8. Generate a combined `modules.dep` covering both system and nvidia `.ko` files
9. Bundle our MIG script + service
10. `mksquashfs -comp gzip` + `extension-release.nvidia` with `ID=_any`

Workflow dispatch input controls `nvidia_version`, `truenas_version`, `kernel_module_type` (open/proprietary), and whether to bundle MIG.

## Boot-time activation: TrueNAS PREINIT

The MIG setup service does NOT use `[Install] WantedBy=multi-user.target`. On TrueNAS, a sysext-shipped WantedBy symlink (or even `systemctl enable` post-merge) is not reliably honored at boot — the unit ends up `enabled` but `inactive (dead)` with zero journal entries. Confirmed across multiple reboots.

The working pattern is TrueNAS's middleware-driven PREINIT mechanism:

```
                  TrueNAS boot
                       │
                       ▼
              systemd-sysext merges
              nvidia.raw + nvidia-mig.raw
                       │
                       ▼
        midclt-registered PREINIT entries run
        (when=PREINIT, type=COMMAND, before Docker)
                       │
            ┌──────────┴───────────┐
            ▼                      ▼
   lightweight path        full-driver path
            │                      │
   "systemctl start         /mnt/<pool>/.config/nvidia-gpu/
    nvidia-mig-setup.        nvidia-preinit-full.sh
    service"                 │
                             ├─ compare SHA of live nvidia.raw
                             │  vs persistent custom
                             ├─ if differ (e.g. after TrueNAS update):
                             │    unmerge → zfs writable → cp → readonly
                             │    → ensure symlink → merge
                             └─ systemctl start nvidia-mig-setup.service
                       │
                       ▼
              docker.service starts
              (containers can now claim MIG UUIDs)
```

`nvidia-mig-setup.service` is `Type=oneshot RemainAfterExit=yes` — once started this boot, `systemctl start` is a no-op. `configure-mig` uses `systemctl restart` when it needs to re-apply a new `mig.conf`.

## Persistent storage layout

Everything that must survive a TrueNAS update lives under `/mnt/<pool>/.config/nvidia-gpu/`:

| File | Purpose |
| --- | --- |
| `nvidia-original.raw` | Stock TrueNAS `nvidia.raw` backup. Used by `uninstall-nvidia-sysext.sh` and `recover-stock-nvidia.sh`. |
| `nvidia.raw` | Custom driver sysext (full-driver path only). Re-applied by `nvidia-preinit-full.sh` after `/usr` is wiped by a TrueNAS update. |
| `nvidia-mig.raw` | Lightweight sysext (lightweight path only). Symlinked from `/etc/extensions/`. |
| `mig.conf` | `MIG_PROFILES=14,14,14,14` style config read by `nvidia-mig-setup`. |
| `nvidia-preinit-full.sh` | Full-driver PREINIT script. Registered via `midclt` so survives DB updates too. |

## Why ZFS readonly matters

`/usr` on TrueNAS is a ZFS dataset with `readonly=on`. To swap `nvidia.raw` you must:

1. `systemd-sysext unmerge`
2. `zfs set readonly=off <usr-dataset>`
3. `cp` the new file
4. `zfs set readonly=on <usr-dataset>`
5. `ln -sf` into `/etc/extensions/` (no toggle needed — `/etc` is writable)
6. `systemd-sysext merge` + `systemctl daemon-reload`

The lightweight path bypasses this entirely — `nvidia-mig.raw` lives in `/mnt/<pool>/` and is just symlinked into `/etc/extensions/`. Only the full-driver path needs the readonly dance.

## What's NOT in the build

By design, the build does NOT include:

- `nvidia-drm.ko` — the TrueNAS kernel lacks `drm_fbdev_ttm_driver_fbdev_probe`. Loading it causes "Unknown symbol" errors that cascade into Docker failures. DRM/KMS is for graphical display anyway — irrelevant on a headless NAS. We pass `--no-drm` to the NVIDIA installer.
- `nvidia-persistenced.service` — not shipped by NVIDIA's open-modules `.run` installer. We rely on `nvidia-smi -pm 1` if persistence mode is needed.
- DKMS source — `/usr/src/nvidia-*` is skipped during staging to avoid the kernel-headers-on-target rebuild attempts.
- Documentation, man pages, license files (other than the LICENSE in `nvidia.raw`).
- Apt repository configuration for `nvidia-container-toolkit` — only the runtime binaries.

## Validated hardware

- **GPU**: NVIDIA RTX PRO 6000 Blackwell Workstation Edition (96 GB)
- **TrueNAS**: SCALE 25.10.3.1 (codename Goldeye)
- **Stock driver**: 570.172.08 (per `release/25.10.*` manifests in truenas/scale-build)
- **Custom drivers tested**: 580.126.18

Both paths verified end-to-end including reboot survival. MIG UUIDs are deterministic — same GPU + same profile config produces bit-identical UUIDs across Proxmox host power cycles, TrueNAS reboots, and driver swaps.
