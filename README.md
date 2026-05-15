# TrueNAS NVIDIA MIG for Blackwell

NVIDIA MIG (Multi-Instance GPU) tooling for TrueNAS SCALE hosts running an **RTX PRO 6000 Blackwell**. Two sysext flavors plus a small set of scripts.

## Why this exists

TrueNAS SCALE bundles an NVIDIA driver, but doesn't ship the MIG setup glue: nothing creates instances at boot, nothing remaps app GPU UUIDs when MIG instances are recreated, and nothing makes that survive a TrueNAS update. This repo fills those gaps.

It comes in two shapes because two different problems need solving:

| | **Lightweight** (`nvidia-mig.raw`) | **Full driver** (`nvidia.raw`) |
| --- | --- | --- |
| What it ships | MIG scripts + service unit only (~8 KB) | A complete NVIDIA driver of your choice + the MIG scripts (~470 MB) |
| Touches TrueNAS's stock `nvidia.raw`? | **No** — runs alongside it | **Yes** — replaces it |
| Driver version | Whatever TrueNAS ships (570.172.08 on 25.10.x) | You pick (570.x / 580.x / 590.x) |
| Reboot required? | No | Yes (kernel module reload) |
| Use when | TrueNAS's stock driver works on your GPU | You need a different driver version than TrueNAS ships |

**Recommended starting point: lightweight.** TrueNAS 25.10.x's stock 570.172.08 driver supports MIG on the RTX PRO 6000 Blackwell (hardware-confirmed). Only reach for the full driver if you've verified you actually need a different version.

## Prerequisites

- TrueNAS SCALE 25.10 or later
- An NVIDIA GPU that supports MIG (RTX PRO 6000 Blackwell confirmed)
- Workstation Edition cards: a one-time `displaymodeselector` switch into compute mode (see [docs/architecture.md](docs/architecture.md#workstation-edition-one-time-setup))

## Install — lightweight (recommended)

On TrueNAS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/main/scripts/install-mig-sysext.sh \
  | sudo bash
```

Downloads `nvidia-mig.raw` from the rolling `dev-mig-sysext` prerelease, copies it to your persistent pool, symlinks it into `/etc/extensions/`, merges the sysext, and registers a TrueNAS PREINIT entry so MIG instances are recreated on every boot. **No reboot required** — the stock driver keeps running.

Run `sudo configure-mig` next (see [Configure MIG](#configure-mig) below).

## Install — full driver

When you need a specific driver version (e.g. you're on a TrueNAS release that ships an older driver and you want 580.x or 590.x).

1. Trigger a build for the version you want — on your workstation:

   ```bash
   gh workflow run build-nvidia-sysext.yml \
     -f nvidia_version=580.126.18 \
     -f truenas_version=25.10.3.1 \
     -f kernel_module_type=open \
     -f bundle_mig=true \
     -f release_tag=dev-nvidia-sysext
   ```

   (~8 min on a GitHub Actions runner. The `dev-nvidia-sysext` tag also auto-refreshes on every push to `main` with the defaults above.)

2. On TrueNAS as root:

   ```bash
   # First time only: make sure a stock-driver backup exists
   curl -fsSL https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/main/scripts/recover-stock-nvidia.sh | sudo bash

   # Install the custom driver
   curl -fsSL https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/main/scripts/install-nvidia-sysext.sh | sudo bash

   sudo reboot
   ```

   **The reboot is mandatory** — the old driver's kernel modules are still loaded until then. `nvidia-smi` will report `Driver/library version mismatch` if you skip it.

3. After reboot, run `sudo configure-mig`.

## Configure MIG

`configure-mig` is bundled into both sysexts at `/usr/bin/configure-mig`. Either install path makes it available in `PATH` after merge (lightweight: immediately; full driver: after reboot).

```bash
sudo configure-mig                          # interactive prompt with profile cheat-sheet
sudo configure-mig --mig=14,14,14,14        # non-interactive: 4× 1g.24gb
sudo configure-mig --mig=14,14,14,14 --skip-app-mapping
```

It validates your profile list (slice budget, instance caps, `+me.all` / OFA conflicts), writes `mig.conf` to persistent storage, restarts the MIG service to create the instances, then walks you through assigning each MIG device to a TrueNAS app. See [docs/mig-profiles.md](docs/mig-profiles.md) for the full profile reference.

## Uninstall

Lightweight:

```bash
curl -fsSL https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/main/scripts/uninstall-mig-sysext.sh | sudo bash
```

Removes the symlink, re-merges sysext, deregisters the PREINIT entry. The stock NVIDIA driver was never touched, so nothing else needs to change.

Full driver:

```bash
curl -fsSL https://raw.githubusercontent.com/scyto/truenas-nvidia-rtx6000-pro-mig/main/scripts/uninstall-nvidia-sysext.sh | sudo bash
sudo reboot
```

Restores stock `nvidia.raw` from `nvidia-original.raw`, deregisters PREINIT, wipes the persistent custom (but keeps the stock backup). The reboot is required for the kernel modules to reload at the stock driver's version.

## More

- [docs/architecture.md](docs/architecture.md) — what's inside each sysext, the PREINIT activation flow, build pipeline, `displaymodeselector` one-time setup
- [docs/mig-persistence.md](docs/mig-persistence.md) — how MIG state survives reboots and TrueNAS updates
- [docs/mig-profiles.md](docs/mig-profiles.md) — full NVIDIA profile reference for RTX PRO 6000 Blackwell with engine counts
- [docs/refactor-mig-only-sysext.md](docs/refactor-mig-only-sysext.md) — design history of this refactor

## Credits

- [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater) — the snapshot-diff / two-level squashfs extraction approach that the full-driver build is ported from
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — profile and capability reference
