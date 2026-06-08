# Troubleshooting

Common failure modes and what to do about them. For background on how each piece is supposed to work, see [architecture.md](architecture.md) and [mig-persistence.md](mig-persistence.md).

This repo handles only the MIG layer. Driver problems (building, swapping, surviving updates) belong to [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support).

## `Failed to initialize NVML: Driver/library version mismatch`

```text
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 570.172
```

**Cause:** A driver was just swapped (e.g. you installed one via nvidia-driver-support). The new userspace libraries are live (sysext merged), but the previous driver's kernel modules are still loaded in kernel memory. This is not a MIG problem.

**Fix:** Reboot. On next boot, kernel modules load fresh at the matching version and the mismatch is gone.

```bash
sudo reboot
```

## MIG service is `enabled` but `inactive (dead)` after reboot, with no journal entries

```text
$ systemctl status nvidia-mig-setup.service
○ nvidia-mig-setup.service - NVIDIA MIG Instance Setup
     Loaded: loaded (...; enabled; preset: disabled)
     Active: inactive (dead)
$ journalctl -u nvidia-mig-setup.service -b 0
-- No entries --
```

**Cause:** Sysext-shipped systemd units don't activate reliably via `WantedBy=multi-user.target` on TrueNAS. The unit needs to be triggered by a TrueNAS PREINIT entry instead. The install script registers this for you; if it's missing, you'll see the symptom above.

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
    if 'nvidia-mig-setup' in cmd:
        print(s)
"
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

## Install refuses with `driver X.Y.Z is below the MIG-supported minimum 570.x`

**Cause:** Your host's NVIDIA driver is older than 570.x. MIG support on Blackwell starts at 570.x (the driver shipped in the latest TrueNAS 25). The install script refuses by default to avoid a silent failure later.

**Fix:** Install a newer driver first with [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support), then re-run the MIG install on top of it. Recent TrueNAS 25.10.x patches already ship 570.172.08, so an older detected version usually means an out-of-date TrueNAS — upgrading TrueNAS is the simplest fix.

If you genuinely want to try MIG on an older driver, bypass the gate:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-mig-support/main/scripts/install-mig-sysext.sh | sudo bash -s -- --force
```
