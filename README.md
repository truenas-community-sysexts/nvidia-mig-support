# TrueNAS Scale NVIDIA MIG for Blackwell

NVIDIA MIG (Multi-Instance GPU) tooling for TrueNAS SCALE hosts running an **RTX PRO 6000 Blackwell**. One sysext for the MIG glue, one optional sysext that swaps the NVIDIA driver, and a single install script that handles both.

If you don't know what Nvidia MIG is you then you don't need this sysext (MIGs allow partitionin he GPU into multiple instances.  It is not vGPU it can only be used with containers. This release only supports TrueNas apps (docker) service.

## Getting Started 

Default behaviour is to add mig suport to the existing shipped driver on TrueNas 25.10 or later.

You also need to switch you card into compute mode (this will disable video output if you are using the DP ports)

Please see the instructions [here](docs/architecture.md#workstation-edition-one-time-setup)

```bash
# On TrueNAS, as root:
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
sudo configure-mig
```

If you need to replace the nvidia stock driver with the newest one from the latest release of this sysext, add `--with-driver`:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash -s -- --with-driver
```

See [Install — with custom driver](#install--with-custom-driver) below.

## Why this exists

TrueNAS SCALE bundles an NVIDIA driver, but doesn't ship the MIG setup glue: nothing creates instances at boot, nothing remaps app GPU UUIDs when MIG instances are recreated, and nothing makes that survive a TrueNAS update. This repo fills those gaps.

Every release carries one asset and pins one driver/TrueNAS combination via its tag:

| Where | What | Touches `/usr`? | Reboot? | Used when |
| --- | --- | --- | --- | --- |
| **`nvidia-mig.raw`** (release asset) | MIG setup binary, `configure-mig`, `nvidia-mig-setup.service` (~8 KB, MIT) | No — symlink in `/etc/extensions/` only | No | Always |
| **`nvidia.raw`** (built on your TrueNAS host with `--with-driver`) | NVIDIA kernel module + userspace libs (~420 MB) | Yes — swaps `/usr/share/truenas/sysext-extensions/nvidia.raw` (zfs r/w toggle) | Yes (kernel module reload) | Only with `--with-driver` |

`nvidia.raw` is **not** a release asset — NVIDIA's EULA prohibits us from redistributing the proprietary userspace it contains. With `--with-driver` the install script builds it on your TrueNAS host inside a transient `ubuntu:24.04` docker container; you accept NVIDIA's EULA when the `.run` installer runs. Build is ≈ 8 min first run, cached for subsequent installs.

The release tag encodes the recommended driver + TrueNAS combo (e.g. `v25.10.3.1-nvidia595.58.03-r18` → driver 595.58.03 on TrueNAS 25.10.3.1). The install script parses both out of the tag and feeds them to the on-host build. There is no "driver without MIG" mode — this repo exists to give you MIG.

**Recommended starting point: default install.** TrueNAS 25.10.x's stock 570.172.08 driver supports MIG on the RTX PRO 6000 Blackwell (hardware-confirmed). Only pass `--with-driver` if you've verified you actually need a different driver version.

## Prerequisites

- TrueNAS SCALE 25.10 or later (older versions ship pre-570.x drivers, which we don't validate)
- An NVIDIA GPU that supports MIG (RTX PRO 6000 Blackwell confirmed)
- Workstation Edition cards: a one-time `displaymodeselector` switch into compute mode (see [docs/architecture.md](docs/architecture.md#workstation-edition-one-time-setup))
- `--with-driver` only: a working Docker daemon on the host (the driver is built inside a transient `ubuntu:24.04` container). TrueNAS Apps users already have it; on a headless box with Apps disabled the install script starts Docker for the build and restores its prior state on exit.

## Install — default (MIG on stock driver)

On TrueNAS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash
```

Auto-detects your TrueNAS version, picks the matching `v<version>-nvidia<driver>-r<run>` release, downloads `nvidia-mig.raw`, copies it to your persistent pool, symlinks it into `/etc/extensions/`, merges the sysext, and registers a TrueNAS PREINIT entry so MIG instances are recreated on every boot. **No reboot required** — the stock driver keeps running.

Multi-pool host? The script auto-picks the right pool when there's an existing config dir or only one data pool; otherwise it prompts. To skip detection and pin the pool explicitly:

```bash
curl -fsSL .../scripts/install-mig-sysext.sh | sudo bash -s -- --pool=fast
# or pass --persist-path=/mnt/fast/.config/nvidia-gpu for full control
```

Then `sudo configure-mig` to set up your MIG layout — see [Configure MIG](#configure-mig) below.

## Install — with custom driver

Use `--with-driver` when TrueNAS's stock NVIDIA driver isn't recent enough for your hardware. The script downloads `nvidia-mig.raw` from the release, **builds `nvidia.raw` on your TrueNAS host** inside a transient `ubuntu:24.04` docker container, swaps the stock driver, and installs the MIG sysext alongside.

Today's tracked driver is **NVIDIA 595.58.03** on TrueNAS 25.10.3.1, open kernel modules — bumped automatically by the daily `check-releases.yml` workflow when either upstream moves. To pin to a specific driver/TrueNAS combo, pass `--release=v25.10.3.1-nvidia580.126.18-r10` (driver version is parsed from the tag and fed to the build).

On TrueNAS, as root:

```bash
# First time only: ensure a stock-driver backup exists in /mnt/<pool>/.config/nvidia-gpu/
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/recover-stock-nvidia.sh | sudo bash

# Install (builds driver on-host + installs MIG)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash -s -- --with-driver

sudo reboot
```

**First run takes ≈ 8 min** — the install script pulls `ubuntu:24.04`, downloads the matching TrueNAS `.update` (~1.5 GB, cached at `/mnt/<pool>/.config/nvidia-gpu/cache/`) and NVIDIA `.run` (~400 MB, cached), cross-compiles `nvidia.ko` against the running kernel, snapshots the userspace, and squashfs's the result into `nvidia.raw`. Subsequent installs reuse the cached `nvidia.raw` when it matches the running kernel + target driver — ~10 s — unless you pass `--rebuild`.

After reboot, run `sudo configure-mig`.

**The reboot is mandatory** — the previous driver's kernel modules are still loaded until then. `nvidia-smi` will report `Driver/library version mismatch` if you skip it.

### `--with-driver` extra flags

- `--rebuild` — ignore the cached `nvidia.raw`, force a fresh build
- `--custom-run=PATH` — build using a `.run` you already downloaded (e.g. a version not in our tracked releases). Filename must be the canonical `NVIDIA-Linux-x86_64-X.Y.Z-no-compat32.run`
- `--driver-sysext=PATH` — install a pre-built `nvidia.raw` you produced elsewhere; skips the on-host build entirely
- `--kmod=open|proprietary` — kernel-module flavor (default `open`; the proprietary build is necessary for Maxwell/Pascal/Volta cards, but this isn't a primary target for this repo)

### Boot-time activation

`--with-driver` registers two TrueNAS PREINIT entries:

1. `nvidia-preinit-driver.sh` — restores the built `nvidia.raw` from `/mnt/<pool>/.config/nvidia-gpu/` after a TrueNAS update wipes `/usr`, and flags kernel-version mismatch with a pointer at the rebuild command if TrueNAS bumped the kernel.
2. `systemctl start nvidia-mig-setup.service` — recreates MIG instances each boot.

The two entries are intentionally independent. The MIG service has a built-in wait for the NVIDIA driver to become responsive (`nvidia-smi -L` succeeds), so the PREINITs can fire in either order without coordination.

### Ad-hoc rebuilds (after a TrueNAS kernel bump)

The build helpers are staged to `/mnt/<pool>/.config/nvidia-gpu/scripts/` on first install. You can invoke the build directly without re-running the curl-bash one-liner:

```bash
sudo /mnt/<pool>/.config/nvidia-gpu/scripts/build-on-host.sh --help
```

Or just re-run the install one-liner with `--rebuild` — it'll pick up the new kernel and rebuild.

Need a different driver version, or proprietary kernel modules? See [docs/architecture.md#building-a-custom-nvidiaraw](docs/architecture.md#building-a-custom-nvidiaraw).

## Configure MIG

`configure-mig` is bundled into `nvidia-mig.raw` at `/usr/bin/configure-mig`. Either install path makes it available in `PATH` after merge (default: immediately; `--with-driver`: after reboot).

```bash
sudo configure-mig                          # interactive prompt with profile cheat-sheet
sudo configure-mig --mig=14,14,14,14        # non-interactive: 4× 1g.24gb
sudo configure-mig --mig=14,14,14,14 --skip-app-mapping
```

It validates your profile list (slice budget, instance caps, `+me.all` / OFA conflicts), writes `mig.conf` to persistent storage, restarts the MIG service to create the instances, then walks you through assigning each MIG device to a TrueNAS app. See [docs/mig-profiles.md](docs/mig-profiles.md) for the full profile reference.

## Verify or preview an install

`install-mig-sysext.sh` accepts three flags useful before, during, and after an actual install:

- **`--check`** — read-only probe of an existing install. Auto-detects which variant was used (default vs `--with-driver`) and reports a pass/warn/fail summary on sysext merge state, kernel-module loading, driver-version match (sysext blob vs `nvidia-smi` runtime), persist dir, stock backup, PREINIT entries (one for default; two for `--with-driver`), and `configure-mig` availability.
- **`--dry-run`** — walks through what install would do, downloads + validates the sysext(s), but skips every mutation. Each skipped step prints `[dry-run] would: …`. Useful before installing on a production box, or to check whether a specific tag is reachable + sane.
- **`--release=TAG`** — pin to a specific release (override the latest-tag auto-resolution). Combines with the others: `--check --release=v25.10.3.1-nvidia580.126.18-r10` probes against that tag's expected state.

```bash
# Probe current install state (no mutation)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --check

# Walk through what install would do (no mutation)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --dry-run

# Same, but for the --with-driver variant
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --dry-run --with-driver

# Pin to a specific release tag
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --release=v25.10.3.1-nvidia580.126.18-r10
```

`--check` and `--dry-run` are mutually exclusive. Run `… | sudo bash -s -- --help` for the full flag list including `--pool`, `--persist-path`, `--force`, and `--skip-backup-check`.

Boot-time diagnostic for the `--with-driver` path: the driver-side PREINIT logs to syslog with a dedicated tag.

```bash
sudo journalctl -b -t nvidia-preinit-driver
```

Look for `Kernel-module path matches running kernel <kver>` (good) or `ERROR: kernel-version mismatch` (TrueNAS bumped the kernel and the bundled `nvidia.ko` no longer matches — re-run the install one-liner to pick up the newer release).

## Uninstall

A single command auto-detects what's installed and undoes it. Bundled into `nvidia-mig.raw` at install time, so no curl one-liner needed once the sysext is merged:

```bash
sudo uninstall-nvidia-mig
```

- **If only the MIG layer is installed** (default `install-mig-sysext.sh`): removes the symlink, re-merges sysext, deregisters the MIG PREINIT. Driver untouched. **No reboot needed.**
- **If MIG + custom driver is installed** (`--with-driver` path): also stops app services, drains the GPU, restores stock `nvidia.raw` from `nvidia-original.raw`, deregisters the driver PREINIT. By default it also removes the build-on-host artifacts (`build/`, `scripts/`, and the ~2 GB `cache/`), keeping only `nvidia-original.raw` for recovery. **Reboot required** afterwards (and the same 5–10 min Apps-toggle wait — see the post-uninstall banner the script prints).
- **If neither is installed**: prints "nothing to uninstall" and exits cleanly.

Flags:

- `--keep-cache` — preserve the `cache/` dir (~2 GB of TrueNAS `.update` + NVIDIA `.run` downloads) for a faster reinstall, but still clean `nvidia.raw`, the staged build helpers, and the PREINIT entry
- `--keep-persist` — don't wipe `/mnt/<pool>/.config/nvidia-gpu/` contents at all
- `--skip-backup-check` — allow the driver revert without an `nvidia-original.raw` backup (at your own risk — you won't be able to recover stock later)

**Fallback** — if the sysext isn't currently merged (e.g. corrupted, or you're recovering a host that lost its `/etc/extensions/` symlink), curl-bash still works:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/uninstall-mig-sysext.sh | sudo bash
```

## Scripts reference

All scripts support `--help` for the full flag list. The install script bundles `configure-mig` and the matching `uninstall-*` command into your `PATH` so routine reconfig and teardown don't need network access.

| Script | Run when | What it does |
| --- | --- | --- |
| `install-mig-sysext.sh` | Setting up MIG on a host | Default: downloads `nvidia-mig.raw`, deploys it next to the stock sysext, registers a PREINIT entry. No reboot. `--with-driver`: builds `nvidia.raw` on this host in a transient `ubuntu:24.04` docker container (≈ 8 min first run, cached after), swaps the stock driver, registers a second PREINIT entry. **Reboot required.** |
| `build-on-host.sh` (staged at `/mnt/<pool>/.config/nvidia-gpu/scripts/` after first `--with-driver` install) | Ad-hoc driver rebuilds (e.g. after a TrueNAS kernel bump) | Wraps `build-nvidia-sysext.sh` in `docker run --rm ubuntu:24.04`. Caches the TrueNAS `.update` and NVIDIA `.run` between rebuilds. |
| `configure-mig` installed with solution| After install, and any time you want to change the MIG layout | Validates your MIG profile string, writes `mig.conf`, restarts the MIG service, then walks you through assigning each MIG device to a TrueNAS app. |
| `uninstall-nvidia-mig` installed with solution | Removing anything this repo installed | Auto-detects state. MIG-only → removes the symlink, re-merges sysext, deregisters MIG PREINIT, no reboot. MIG + custom driver → also restores stock `nvidia.raw`, deregisters the driver PREINIT, **reboot required**. |
| `recover-stock-nvidia.sh` | Before `install-mig-sysext.sh --with-driver` if you don't already have a stock backup | Pulls the stock `nvidia.raw` out of the official TrueNAS `.update` archive and stores it as `nvidia-original.raw` for later restore. |



## License

This repo is MIT-licensed (see [LICENSE](LICENSE)). It does **not** redistribute any NVIDIA-proprietary code:

- Release assets only contain `nvidia-mig.raw` (~8 KB of original MIT-licensed tooling).
- `--with-driver` mode assembles `nvidia.raw` on **your** machine — the install script invokes the official NVIDIA `.run` installer inside a transient docker container with `--accept-license --silent`, snapshots the resulting userspace, and packages it into a sysext that lives only on your host. By running `--with-driver` you accept the [NVIDIA Linux Driver License](https://www.nvidia.com/en-us/drivers/nvidia-license/) on your own behalf.

## More

- [docs/architecture.md](docs/architecture.md) — what's inside each sysext, the PREINIT activation flow, build pipeline, `displaymodeselector` one-time setup
- [docs/mig-persistence.md](docs/mig-persistence.md) — how MIG state survives reboots and TrueNAS updates
- [docs/mig-profiles.md](docs/mig-profiles.md) — full NVIDIA profile reference for RTX PRO 6000 Blackwell with engine counts
- [docs/troubleshooting.md](docs/troubleshooting.md) — common failure modes and what to do about them
- [docs/build-ci-notes.md](docs/build-ci-notes.md) — release tagging, auto-cadence, runner pinning rationale
- [docs/refactor-history.md](docs/refactor-history.md) — design history of this refactor

## Credits
- [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) - for the initial solution and inspiration this could be done
- [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater) — the snapshot-diff / two-level squashfs extraction approach that the driver build is ported from
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — profile and capability reference
