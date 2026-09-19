# Build / CI notes

Reasoning behind non-obvious CI decisions that aren't self-evident from the workflow YAML. Living document; update when a decision changes.

## What CI builds

Only `nvidia-mig.raw` — a tiny, driver- and kernel-agnostic sysext (`ID=_any`) containing the MIG setup script, the `nvidia-mig-setup.service` unit, `configure-mig`, and `uninstall-nvidia-mig`. No kernel module, no NVIDIA userspace. [`scripts/build-mig-sysext.sh`](../scripts/build-mig-sysext.sh) stages those files and runs `mksquashfs` — under a second. A smoke test then unpacks the result and asserts the expected paths are present.

The NVIDIA **driver** is not built here. It's a separate project: [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support). This repo used to build/swap the driver (the old `--with-driver` path), which is why earlier history mentions on-host `ubuntu:24.04` builds, runner-GLIBC pinning, `.update`/`.run` caching, and a daily upstream-version poller. All of that moved to nvidia-driver-support.

## Release tagging scheme

[`build-sysext.yml`](../.github/workflows/build-sysext.yml) is **manual dispatch only** (`workflow_dispatch`). Cut a release when the MIG tooling changes — there's nothing upstream to track, since the artifact doesn't depend on the driver or TrueNAS version.

- **Tag: `v<run_number>`** — `github.run_number`, an auto-incrementing counter. Mirrors nvidia-driver-support. Monotonic and unique across retries, so `softprops/action-gh-release` always creates a fresh release cleanly. This matters because the repo enforces **immutable releases** (a tag/assets can't be modified once created) — a rolling tag would fail with `Cannot delete asset from an immutable release`.
- **Latest promotion**: the default dispatch (`mark_latest=false`) publishes a prerelease gated behind a hardware-test issue; promote.yml flips it to "Latest" when the issue closes (`mark_latest=true` publishes straight to Latest). The install script's no-tag path resolves "Latest" to its tag and downloads from it, so users get the newest promoted build.

The single asset is `nvidia-mig.raw` (plus its `.sha256`). The build smoke-tests the artifact before publishing; a failing smoke test blocks the release.

## How `install-mig-sysext.sh` finds the release

- No `--release` → the script resolves the tag behind `https://github.com/<repo>/releases/latest` (one redirect probe, no API call, no TrueNAS-version matching), then downloads `releases/download/<tag>/nvidia-mig.raw`.
- `--release=TAG` → `releases/download/<tag>/nvidia-mig.raw`.
- Either way the download is verified against the release's `nvidia-mig.raw.sha256` sidecar (a hard failure if it is missing or mismatched, so the sidecar asset is load-bearing), and the on-pool PREINIT script is staged from inside the verified raw (bundled at `usr/share/nvidia-mig/`; releases that predate the bundling fall back to a fetch pinned to the same tag).

Because the sysext is driver/kernel-agnostic, there's no per-TrueNAS-version release matching to do — one latest release serves every host.

## Lint

[`lint.yml`](../.github/workflows/lint.yml) runs `shellcheck --severity=warning` over the four scripts (`build-mig-sysext.sh`, `install-mig-sysext.sh`, `uninstall-mig-sysext.sh`, `configure-mig.sh`) and `actionlint` over the workflows.
