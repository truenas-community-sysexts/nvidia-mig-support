# TrueNAS NVIDIA MIG for Blackwell

NVIDIA MIG (Multi-Instance GPU) tooling for TrueNAS SCALE hosts running an **RTX PRO 6000 Blackwell**. Two sysext flavors plus a small set of scripts.

## tl;dr

```bash
# On TrueNAS, as root:
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
sudo configure-mig
```

That's the lightweight path — adds MIG tooling alongside TrueNAS's stock NVIDIA driver. No reboot, no driver replacement. Stops working only if TrueNAS's stock driver doesn't support MIG on your GPU (570.x+ on Blackwell does — confirmed on RTX PRO 6000).

If you need a different driver version, see [Install — full driver](#install--full-driver) below.

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

- TrueNAS SCALE 25.10 or later (older versions ship pre-570.x drivers, which we don't validate)
- An NVIDIA GPU that supports MIG (RTX PRO 6000 Blackwell confirmed)
- Workstation Edition cards: a one-time `displaymodeselector` switch into compute mode (see [docs/architecture.md](docs/architecture.md#workstation-edition-one-time-setup))

## Install — lightweight (recommended)

On TrueNAS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
```

Downloads `nvidia-mig.raw` from the rolling `dev-mig-sysext` prerelease, copies it to your persistent pool, symlinks it into `/etc/extensions/`, merges the sysext, and registers a TrueNAS PREINIT entry so MIG instances are recreated on every boot. **No reboot required** — the stock driver keeps running.

Multi-pool host? The script auto-picks the right pool when there's an existing config dir or only one data pool; otherwise it prompts. To skip detection and pin the pool explicitly:

```bash
curl -fsSL .../scripts/install-mig-sysext.sh | sudo bash -s -- --pool=fast
# or pass --persist-path=/mnt/fast/.config/nvidia-gpu for full control
```

Then `sudo configure-mig` to set up your MIG layout — see [Configure MIG](#configure-mig) below.

## Install — full driver

Uses the auto-built `dev-nvidia-sysext` rolling prerelease — currently **NVIDIA 580.126.18 on TrueNAS 25.10.3.1, open kernel modules**. The release is rebuilt on every push to `main`, so it's always current with the source.

On TrueNAS, as root:

```bash
# First time only: ensure a stock-driver backup exists in /mnt/<pool>/.config/nvidia-gpu/
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/recover-stock-nvidia.sh | sudo bash

# Install
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-nvidia-sysext.sh | sudo bash

sudo reboot
```

After reboot, run `sudo configure-mig`.

**The reboot is mandatory** — the previous driver's kernel modules are still loaded until then. `nvidia-smi` will report `Driver/library version mismatch` if you skip it.

Need a different driver version (e.g. you want 590.44.01 for TrueNAS 26.x, or you need proprietary kernel modules instead of open)? See [docs/architecture.md#building-a-custom-nvidiaraw](docs/architecture.md#building-a-custom-nvidiaraw).

## Configure MIG

`configure-mig` is bundled into both sysexts at `/usr/bin/configure-mig`. Either install path makes it available in `PATH` after merge (lightweight: immediately; full driver: after reboot).

```bash
sudo configure-mig                          # interactive prompt with profile cheat-sheet
sudo configure-mig --mig=14,14,14,14        # non-interactive: 4× 1g.24gb
sudo configure-mig --mig=14,14,14,14 --skip-app-mapping
```

It validates your profile list (slice budget, instance caps, `+me.all` / OFA conflicts), writes `mig.conf` to persistent storage, restarts the MIG service to create the instances, then walks you through assigning each MIG device to a TrueNAS app. See [docs/mig-profiles.md](docs/mig-profiles.md) for the full profile reference.

## Uninstall

Both uninstall scripts are bundled into the sysext at install time, so you don't need a curl one-liner — just run them locally once the sysext is merged.

Lightweight:

```bash
sudo uninstall-nvidia-mig
```

Removes the symlink, re-merges sysext, deregisters the PREINIT entry. The stock NVIDIA driver was never touched, so nothing else needs to change.

Full driver:

```bash
sudo uninstall-nvidia-driver
sudo reboot
```

Restores stock `nvidia.raw` from `nvidia-original.raw`, deregisters PREINIT, wipes the persistent custom (but keeps the stock backup). The reboot is required for the kernel modules to reload at the stock driver's version.

**Fallback** — if the sysext somehow isn't merged (e.g. corrupted, or you're recovering a host that lost its `/etc/extensions/` symlink), curl-bash still works:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/uninstall-mig-sysext.sh | sudo bash
# or
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/uninstall-nvidia-sysext.sh | sudo bash
```

## Scripts reference

All scripts support `--help` for the full flag list. The install scripts bundle `configure-mig` and the matching `uninstall-*` command into your `PATH` so routine reconfig and teardown don't need network access.

| Script | Run when | What it does |
| --- | --- | --- |
| [`install-mig-sysext.sh`](scripts/install-mig-sysext.sh) | Adding MIG to a host that keeps TrueNAS's stock driver | Auto-detects local TrueNAS version, picks the matching `v<version>-mig-r<run>` release, downloads `nvidia-mig.raw`, deploys it next to the stock sysext, registers a TrueNAS PREINIT entry. No reboot. |
| [`install-nvidia-sysext.sh`](scripts/install-nvidia-sysext.sh) | Replacing TrueNAS's stock driver with a custom one | Auto-detects local TrueNAS version, picks the matching `v<version>-nvidia<driver>-r<run>` release, downloads `nvidia.raw`, swaps the stock sysext, registers a PREINIT entry that re-applies after TrueNAS updates. **Reboot required.** |
| [`recover-stock-nvidia.sh`](scripts/recover-stock-nvidia.sh) | Before `install-nvidia-sysext.sh` if you don't already have a stock backup | Pulls the stock `nvidia.raw` out of the official TrueNAS `.update` archive and stores it as `nvidia-original.raw` for later restore. |
| `configure-mig` *(bundled in both sysexts at `/usr/bin/configure-mig`)* | After install, and any time you want to change the MIG layout | Validates your MIG profile string, writes `mig.conf`, restarts the MIG service, then walks you through assigning each MIG device to a TrueNAS app. |
| `uninstall-nvidia-mig` *(bundled in the lightweight sysext at `/usr/bin/uninstall-nvidia-mig`; source: [`uninstall-mig-sysext.sh`](scripts/uninstall-mig-sysext.sh))* | Removing the lightweight sysext | Removes the symlink, re-merges sysext, deregisters PREINIT. Stock driver untouched. |
| `uninstall-nvidia-driver` *(bundled in the full-driver sysext at `/usr/bin/uninstall-nvidia-driver`; source: [`uninstall-nvidia-sysext.sh`](scripts/uninstall-nvidia-sysext.sh))* | Restoring stock driver after a full-driver install | Restores stock `nvidia.raw` from the backup, deregisters PREINIT. **Reboot required.** |

## More

- [docs/architecture.md](docs/architecture.md) — what's inside each sysext, the PREINIT activation flow, build pipeline, `displaymodeselector` one-time setup
- [docs/mig-persistence.md](docs/mig-persistence.md) — how MIG state survives reboots and TrueNAS updates
- [docs/mig-profiles.md](docs/mig-profiles.md) — full NVIDIA profile reference for RTX PRO 6000 Blackwell with engine counts
- [docs/troubleshooting.md](docs/troubleshooting.md) — common failure modes and what to do about them
- [docs/refactor-history.md](docs/refactor-history.md) — design history of this refactor

## Credits

- [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater) — the snapshot-diff / two-level squashfs extraction approach that the full-driver build is ported from
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — profile and capability reference
