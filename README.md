# TrueNAS NVIDIA MIG for Blackwell

NVIDIA MIG (Multi-Instance GPU) tooling for TrueNAS hosts running an **RTX PRO 6000 Blackwell**. A single lightweight sysext provides the MIG glue; it layers on top of whatever NVIDIA driver is already on the host.

If you don't know what NVIDIA MIG is then you don't need this sysext. MIG partitions the GPU into multiple isolated instances. It is not vGPU — it can only be used with containers. This release only supports TrueNAS apps (the docker service).

> **The driver is a separate project.** This repo installs *only* the MIG tooling. To run a newer/specific NVIDIA driver than TrueNAS ships, install it first with [**nvidia-driver-support**](https://github.com/truenas-community-sysexts/nvidia-driver-support), then add MIG on top.

## Getting Started

Default behaviour is to add MIG support to the driver already shipped on TrueNAS 25.10 or later.

You also need to switch your card into compute mode (this disables video output if you are using the DP ports). See the [Workstation Edition one-time setup](docs/architecture.md#workstation-edition-one-time-setup).

```bash
# On TrueNAS, as root:
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
sudo configure-mig
```

## Why this exists

TrueNAS bundles an NVIDIA driver, but doesn't ship the MIG setup glue: nothing creates instances at boot, nothing remaps app GPU UUIDs when MIG instances are recreated, and nothing makes that survive a TrueNAS update. This repo fills those gaps.

A release carries one asset, `nvidia-mig.raw`:

| Contents | Touches `/usr`? | Reboot? |
| --- | --- | --- |
| MIG setup binary, `configure-mig`, `uninstall-nvidia-mig`, `nvidia-mig-setup.service` (~8 KB, MIT) | No — symlink in `/etc/extensions/` only | No |

It's `ID=_any` and contains **no kernel module and no driver libraries**, so it's driver- and kernel-agnostic: one release works across TrueNAS versions and driver versions. It merges on top of the NVIDIA driver sysext that's already present.

**MIG needs a driver new enough to expose it.** Anything at or above the driver shipped in the latest TrueNAS 25 (major **≥ 570**) is treated as MIG-capable. TrueNAS 25.10.x's stock 570.172.08 driver supports MIG on the RTX PRO 6000 Blackwell (hardware-confirmed). The install refuses on older drivers unless you pass `--force`.

### Need a newer or different driver?

Install it first with [**nvidia-driver-support**](https://github.com/truenas-community-sysexts/nvidia-driver-support) — it builds the chosen NVIDIA driver on your host and swaps the stock sysext — then run the MIG install here on top of it.

## Prerequisites

- TrueNAS 25.10 or later (older versions ship pre-570.x drivers, on which MIG is unsupported)
- An NVIDIA GPU that supports MIG (RTX PRO 6000 Blackwell confirmed)
- Workstation Edition cards: a one-time `displaymodeselector` switch into compute mode (see [docs/architecture.md](docs/architecture.md#workstation-edition-one-time-setup))

## Install

On TrueNAS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
```

Downloads `nvidia-mig.raw` from the latest release, copies it to your persistent pool, symlinks it into `/etc/extensions/`, merges the sysext, and registers a TrueNAS PREINIT entry so MIG instances are recreated on every boot. **No reboot required** — the driver keeps running.

Multi-pool host? The script auto-picks the right pool when there's an existing config dir or only one data pool; otherwise it prompts. To skip detection and pin the pool explicitly:

```bash
curl -fsSL .../scripts/install-mig-sysext.sh | sudo bash -s -- --pool=fast
# or pass --persist-path=/mnt/fast/.config/nvidia-gpu for full control
```

Then `sudo configure-mig` to set up your MIG layout — see [Configure MIG](#configure-mig) below.

### Boot-time activation

The install registers one TrueNAS PREINIT entry — `systemctl start nvidia-mig-setup.service` — which recreates MIG instances on each boot. The MIG service waits for the NVIDIA driver to become responsive (`nvidia-smi -L` succeeds) before acting, so it's robust to driver/boot ordering.

## Configure MIG

`configure-mig` is bundled into `nvidia-mig.raw` at `/usr/bin/configure-mig` and is on `PATH` once the sysext is merged (immediately after install — no reboot).

```bash
sudo configure-mig                          # interactive prompt with profile cheat-sheet
sudo configure-mig --mig=14,14,14,14        # non-interactive: 4× 1g.24gb
sudo configure-mig --mig=14,14,14,14 --skip-app-mapping
```

It validates your profile list (slice budget, instance caps, `+me.all` / OFA conflicts), writes `mig.conf` to persistent storage, restarts the MIG service to create the instances, then walks you through assigning each MIG device to a TrueNAS app. See [docs/mig-profiles.md](docs/mig-profiles.md) for the full profile reference.

## Verify or preview an install

`install-mig-sysext.sh` accepts a few flags useful before, during, and after an actual install:

- **`--check`** — read-only probe of an existing install. Reports a pass/warn/fail summary on driver-sysext + MIG-sysext merge state, kernel-module loading, driver version vs the MIG minimum, persist dir, PREINIT entry, service state, and `configure-mig` availability.
- **`--dry-run`** — walks through what install would do, downloads + validates the sysext, but skips every mutation. Each skipped step prints `[dry-run] would: …`.
- **`--release=TAG`** — pin to a specific release (override the latest-release auto-resolution).

```bash
# Probe current install state (no mutation)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --check

# Walk through what install would do (no mutation)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --dry-run
```

`--check` and `--dry-run` are mutually exclusive. Run `… | sudo bash -s -- --help` for the full flag list including `--pool`, `--persist-path`, and `--force`.

## Uninstall

A single command removes the MIG layer. Bundled into `nvidia-mig.raw` at install time, so no curl one-liner needed once the sysext is merged:

```bash
sudo uninstall-nvidia-mig
```

Removes the symlink, re-merges the sysext, and deregisters the MIG PREINIT entry. If MIG mode is currently active on the GPU it first tears down the runtime state (destroys MIG instances, disables MIG mode, reassigns affected apps to the full-GPU UUID and restarts the ones that were running). The **NVIDIA driver is never touched** — there's nothing to revert and **no reboot needed**.

Flags:

- `--keep-persist` — don't remove `nvidia-mig.raw` / `mig.conf` from `/mnt/<pool>/.config/nvidia-gpu/`

**Fallback** — if the sysext isn't currently merged (e.g. you lost the `/etc/extensions/` symlink), curl-bash still works:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/uninstall-mig-sysext.sh | sudo bash
```

> Migrating from an older `--with-driver` install? This repo no longer manages the driver. Use [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support) (its `uninstall-nvidia-driver` / stock-recovery tooling) to revert the driver; this uninstall only removes the MIG layer.

## Scripts reference

All scripts support `--help`. The install script bundles `configure-mig` and `uninstall-nvidia-mig` into your `PATH` so routine reconfig and teardown don't need network access.

| Script | Run when | What it does |
| --- | --- | --- |
| `install-mig-sysext.sh` | Setting up MIG on a host | Downloads `nvidia-mig.raw`, deploys it next to the driver sysext, registers the MIG PREINIT entry. No reboot. |
| `configure-mig` (bundled in the sysext) | After install, and any time you want to change the MIG layout | Validates your MIG profile string, writes `mig.conf`, restarts the MIG service, then walks you through assigning each MIG device to a TrueNAS app. |
| `uninstall-nvidia-mig` (bundled in the sysext) | Removing the MIG layer | Tears down MIG runtime state if active, removes the symlink, re-merges the sysext, deregisters the MIG PREINIT. No reboot. Driver untouched. |

## License

This repo is MIT-licensed (see [LICENSE](LICENSE)) and redistributes **no** NVIDIA-proprietary code. Release assets contain only `nvidia-mig.raw` (~8 KB of original MIT-licensed tooling) — no driver, no kernel module, no NVIDIA userspace.

## More

- [docs/architecture.md](docs/architecture.md) — what's inside the sysext, the PREINIT activation flow, `displaymodeselector` one-time setup
- [docs/mig-persistence.md](docs/mig-persistence.md) — how MIG state survives reboots and TrueNAS updates
- [docs/mig-profiles.md](docs/mig-profiles.md) — full NVIDIA profile reference for RTX PRO 6000 Blackwell with engine counts
- [docs/troubleshooting.md](docs/troubleshooting.md) — common failure modes and what to do about them
- [docs/build-ci-notes.md](docs/build-ci-notes.md) — release tagging and build CI
- [docs/refactor-history.md](docs/refactor-history.md) — design history

## Credits

- [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) - for the initial solution and inspiration this could be done
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — profile and capability reference
