# Troubleshooting

Common failure modes and what to do about them. For background on how each piece is supposed to work, see [architecture.md](architecture.md) and [mig-persistence.md](mig-persistence.md).

## `Failed to initialize NVML: Driver/library version mismatch`

```text
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 570.172
```

**Cause:** You just ran `install-mig-sysext.sh --with-driver` or `recover-stock-nvidia.sh --install`. The new userspace libraries are live (sysext is merged), but the previous driver's kernel modules are still loaded in kernel memory.

**Fix:** Reboot. On next boot, kernel modules load fresh at the matching version, sysext re-merges, mismatch is gone.

```bash
sudo reboot
```

Hot-unload (no reboot) is technically possible — `rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia` after stopping Docker — but the reboot path is more reliable. `install-mig-sysext.sh --with-driver` prints an explicit reboot-required warning for this reason.

## MIG service is `enabled` but `inactive (dead)` after reboot, with no journal entries

```text
$ systemctl status nvidia-mig-setup.service
○ nvidia-mig-setup.service - NVIDIA MIG Instance Setup
     Loaded: loaded (...; enabled; preset: disabled)
     Active: inactive (dead)
$ journalctl -u nvidia-mig-setup.service -b 0
-- No entries --
```

**Cause:** Sysext-shipped systemd units don't activate reliably via `WantedBy=multi-user.target` on TrueNAS. The unit needs to be triggered by a TrueNAS PREINIT entry instead. The install scripts register this for you; if it's missing, you'll see the symptom above.

**Fix:** Re-run the install — it will (re-)create the PREINIT entry:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash
```

Verify the PREINIT registration directly:

```bash
sudo midclt call initshutdownscript.query | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    cmd = (s.get('command') or '') + ' ' + (s.get('script') or '')
    if 'nvidia-mig-setup' in cmd or 'nvidia-preinit-driver' in cmd:
        print(s)
"
```

## `recover-stock-nvidia.sh` says `nvidia-original.raw not found` / no backup available

**Cause:** You never had a stock-driver backup, or an earlier install/restore cycle wiped it. The default install doesn't need one (it never touches stock `nvidia.raw`), but `install-mig-sysext.sh --with-driver` and `uninstall-mig-sysext.sh` (when reverting from `--with-driver`) both depend on having one.

**Fix:** Use `recover-stock-nvidia.sh` (with no flags first to download + extract, then with `--install` if you also want to live-swap back to stock):

```bash
# Extract stock nvidia.raw from the official .update archive (~1.8 GB download).
# Stages it as /mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw.
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/recover-stock-nvidia.sh | sudo bash

# Verify it's the version you expect (should be 570.172.08 on TrueNAS 25.10.x)
sudo unsquashfs -l /mnt/*/.config/nvidia-gpu/nvidia-original.raw \
  | grep -oE '[0-9]{3}\.[0-9]+\.[0-9]+' | sort -u | head -3

# Optional: actually swap it over the current live nvidia.raw
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/recover-stock-nvidia.sh | sudo bash -s -- --install
sudo reboot
```

## `displaymodeselector: Permission denied` (or won't run)

```text
$ sudo ./displaymodeselector --gpumode compute
sudo: ./displaymodeselector: Permission denied
```

**Cause:** TrueNAS mounts `/home`, `/tmp`, and `/data` with `noexec`. Wherever you scp'd the binary, the filesystem is refusing to execute it.

**Fix:** Move the binary to a location that allows execution (e.g. `/root`), then run from there:

```bash
sudo mv /tmp/displaymodeselector /root/
sudo chmod +x /root/displaymodeselector
sudo /root/displaymodeselector --gpumode compute
sudo reboot
```

Alternative if you really need to run it from a `noexec` path: invoke via the dynamic linker, which doesn't trigger the `noexec` check:

```bash
/lib64/ld-linux-x86-64.so.2 /tmp/displaymodeselector --gpumode compute
```

This is a one-time, per-physical-card step. The compute-mode setting is stored in GPU firmware and survives reboots, driver swaps, and OS reinstalls.

## `midclt … Failed connection handshake` during install or reboot

```text
$ sudo midclt call docker.update '{"nvidia": false}'
truenas_api_client.exc.ClientException: Failed connection handshake
```

**Cause:** TrueNAS middleware is transitionally restarting. This happens when `systemd-sysext unmerge`/`merge` flaps the nvidia sysext — the middleware re-evaluates Docker's GPU state asynchronously and briefly disconnects clients. Also common in the first ~30 s after a fresh boot, before middleware has finished starting.

**Fix (usually nothing):** The MIG service has its own retry loop and will recover (you'll see `Waiting for TrueNAS middleware to be ready (system.ready); timeout=25s...` in the journal). For interactive `midclt` calls, wait 30–60 s and retry, or run:

```bash
sudo midclt call system.ready
# should return: true
```

If `system.ready` returns `true` and `midclt` calls still fail, that's a genuine middleware bug — restart it: `sudo systemctl restart middlewared`.

## After a TrueNAS update, `--with-driver` path loses the custom driver

**Cause:** TrueNAS updates rewrite `/usr` from scratch, which wipes the custom `nvidia.raw` you'd installed. The PREINIT script registered by `install-mig-sysext.sh --with-driver` (`nvidia-preinit-driver.sh`) is designed to handle this — on the next boot it compares SHA256 of live `nvidia.raw` vs the persistent custom copy on `/mnt/<pool>/.config/nvidia-gpu/`, detects the wipe, and re-applies the custom driver before Docker starts.

**Fix (usually nothing):** Reboot once after the TrueNAS update completes. The PREINIT script handles the re-application automatically. Verify it ran:

```bash
sudo journalctl -b -t nvidia-preinit-driver
sudo /usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

The driver version should match what you installed, not the version TrueNAS just shipped.

A more structured probe in one shot — `install-mig-sysext.sh --check` reports all of the same state (sysext merged, kernel module loaded, driver-version match between the sysext blob and `nvidia-smi` runtime, PREINIT registration, etc.) in a pass/warn/fail summary, without modifying anything:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash -s -- --check
```

The most actionable failure to look for is a kernel-version mismatch — the PREINIT script writes `ERROR: kernel-version mismatch — running <kver> but sysext bundles modules for <kver>` to the syslog tag above when this happens, and points at the install one-liner to fix. This means the TrueNAS update bumped the kernel, so the cached `nvidia.raw` (compiled against the old kernel) no longer loads. A plain reboot won't fix it — you have to **rebuild** the driver against the new kernel:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash -s -- --with-driver --rebuild
sudo reboot
```

The rebuild is warm (the TrueNAS `.update` + NVIDIA `.run` are still cached), so it's ~3 min rather than the cold ~8 min. If the build helpers were staged on first install, you can also invoke the build directly: `sudo /mnt/<pool>/.config/nvidia-gpu/scripts/build-on-host.sh --help`.

If something went wrong and the PREINIT didn't run (or the persistent `/mnt/<pool>/.config/nvidia-gpu/nvidia.raw` is missing): re-run `install-mig-sysext.sh --with-driver`. Use `--dry-run` first if you want to walk through what it would do before letting it mutate the system.

## `--with-driver` fails because Docker isn't available

```text
ERROR: docker not found / Cannot connect to the Docker daemon
```

**Cause:** `--with-driver` builds `nvidia.raw` inside a transient `ubuntu:24.04` container, so it needs a working Docker daemon. TrueNAS Apps users already have one. On a headless box with Apps disabled the install script starts Docker for the build and restores its prior state on exit — but it can't do that if Docker isn't installed at all.

**Fix:** Confirm the daemon is present and reachable:

```bash
sudo docker info >/dev/null && echo "docker OK"
sudo systemctl status docker
```

- **Apps users:** make sure the Apps service is configured (it provisions Docker). If `docker info` still fails, start it: `sudo systemctl start docker`.
- **No Apps / no Docker at all:** build `nvidia.raw` on another machine and hand it to the install with `--driver-sysext=/path/to/nvidia.raw`, which skips the on-host build entirely.

## `--with-driver` build fails (download / compile / squashfs)

```text
[FATAL] Failed to download .update file
[FATAL] NVIDIA installer failed
[FATAL] No .ko kernel modules found
```

**Cause:** The on-host build downloads the TrueNAS `.update` (~1.5 GB) and NVIDIA `.run` (~400 MB), cross-compiles `nvidia.ko` against the extracted kernel headers, and squashfs's the result. Failures usually mean a network problem, not enough scratch disk (~3 GB needed), or an upstream format change (NVIDIA/TrueNAS altered an installer or layout the build script assumes).

**Fix:**

1. Check free space on the persist pool — the cache + build dirs need ~3 GB:

   ```bash
   df -h /mnt/*/.config/nvidia-gpu/
   ```

2. Check reachability of both upstreams:

   ```bash
   curl -I https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt
   ```

3. Force a clean rebuild (re-downloads everything, discards any half-written cache):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
     | sudo bash -s -- --with-driver --rebuild
   ```

4. If it still fails, the build script may have broken against current upstream. The release's CI smoke-test (`build-sysext.yml`'s `build-nvidia` job) builds the same way — a red run there confirms it's upstream, not your host. File an issue with the build log.

If you already have a `.run` downloaded, `--custom-run=/path/to/NVIDIA-Linux-x86_64-<ver>.run` skips the NVIDIA download.

## Large disk usage under `/mnt/<pool>/.config/nvidia-gpu/cache/`

```bash
du -sh /mnt/*/.config/nvidia-gpu/cache/   # ~2 GB
```

**Cause:** This is intentional. `--with-driver` caches the TrueNAS `.update` and NVIDIA `.run` so rebuilds (e.g. after a kernel bump) are ~3 min instead of a cold ~8 min. It survives between builds and is keyed on version.

**Fix (only if space is tight):** it's safe to delete — the next build re-downloads as needed:

```bash
sudo rm -rf /mnt/*/.config/nvidia-gpu/cache/
```

If you're uninstalling but plan to reinstall soon, `uninstall-mig-sysext.sh --keep-cache` keeps this dir while cleaning everything else.

## MIG instances don't come back after reboot

**Cause:** Either (a) the MIG service didn't run at boot (see "MIG service is `enabled` but `inactive (dead)`" above), or (b) `mig.conf` is missing/empty/malformed.

**Fix:** Inspect `mig.conf` first:

```bash
sudo cat /mnt/*/.config/nvidia-gpu/mig.conf
# should contain a single line: MIG_PROFILES="14,14,14,14"  (or your chosen profile string)
```

If missing or wrong, run `configure-mig`:

```bash
sudo configure-mig                          # interactive
sudo configure-mig --mig=14,14,14,14        # non-interactive
```

If `mig.conf` looks fine but the service still didn't run, see the PREINIT troubleshooting section above.

## App lost its MIG UUID assignment

**Symptom:** A TrueNAS app that was previously running on a MIG device now has no GPU assigned, or the assignment shows a UUID that doesn't exist in `nvidia-smi -L`.

**Cause:** You changed the MIG layout (e.g. went from `14,14,14,14` to `47,47,14,14`) and the old MIG UUIDs no longer exist. The MIG service's app-remap step only remaps to the *first* available MIG UUID — apps that need a specific MIG device need to be reassigned manually.

**Fix:** Re-run `configure-mig` (without `--skip-app-mapping`) so it walks through interactive app assignment:

```bash
sudo configure-mig
```

Or via the TrueNAS UI: Apps → app → Edit → Resources → NVIDIA GPU → pick the right MIG UUID.

## Default install fails pre-flight with `stock driver X.Y.Z is below the minimum-validated 570.x`

**Cause:** Your TrueNAS shipped an NVIDIA driver older than 570.x. MIG support on Blackwell was first validated by this project at 570.172.08; older drivers may or may not work. The install script refuses by default to avoid silent failure later.

**Fix:** First, check what your TrueNAS version actually ships — recent 25.10.x patches all pin 570.172.08, so an older detected version suggests a non-standard install. Either upgrade TrueNAS, or install a custom driver alongside MIG:

```bash
# Build a current driver on this host + install MIG tooling on top
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh \
  | sudo bash -s -- --with-driver
```

If you genuinely want to use MIG on a stock-but-old driver, bypass the gate:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --force
```
