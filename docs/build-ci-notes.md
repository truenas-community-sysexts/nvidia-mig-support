# Build / CI notes

Reasoning behind non-obvious CI decisions that aren't self-evident from the workflow YAML. Living document; update when a decision changes.

## What CI builds

Only `nvidia-mig.raw` — a tiny, driver- and kernel-agnostic sysext (`ID=_any`) containing the MIG setup script, the `nvidia-mig-setup.service` unit, `configure-mig`, and `uninstall-nvidia-mig`. No kernel module, no NVIDIA userspace. [`scripts/build-mig-sysext.sh`](../scripts/build-mig-sysext.sh) stages those files and runs `mksquashfs` — under a second. A smoke test then unpacks the result and asserts the expected paths are present.

The NVIDIA **driver** is not built here. It's a separate project: [nvidia-driver-support](https://github.com/truenas-community-sysexts/nvidia-driver-support). This repo used to build/swap the driver (the old `--with-driver` path), which is why earlier history mentions on-host `ubuntu:24.04` builds, runner-GLIBC pinning, `.update`/`.run` caching, and a daily upstream-version poller. All of that moved to nvidia-driver-support.

## Release tagging scheme

[`build-sysext.yml`](../.github/workflows/build-sysext.yml) is **manual dispatch only** (`workflow_dispatch`). Cut a release when the MIG tooling changes — there's nothing upstream to track, since the artifact doesn't depend on the driver or TrueNAS version.

- **Tag: `v<run_number>`** — `github.run_number`, an auto-incrementing counter. Mirrors nvidia-driver-support. Monotonic and unique across retries, so `softprops/action-gh-release` always creates a fresh release cleanly. This matters because the repo enforces **immutable releases** (a tag/assets can't be modified once created) — a rolling tag would fail with `Cannot delete asset from an immutable release`.
- **Per-train approval**: every release is published as a **pre-release**, and one hardware-test issue is opened per TrueNAS train listed in `.github/tracked-versions.json` (`trains`): label `hardware-test` for a stable train (TrueNAS 25.10), `preview-hardware-test` for a preview one (the TrueNAS 26 beta). Each carries `<!-- release-tag -->` and `<!-- train -->` markers, and its title names the train. Closing a train's issue as completed runs [`promote.yml`](../.github/workflows/promote.yml), which appends `<!-- verified-train: KEY -->` to the release notes; on the first approval the same update flips the release out of pre-release and appends the changelog. GitHub's "Latest" follows the newest release approved for a stable train, but nothing selects by it. An issue with no train marker (from before per-train issues) keeps the old behavior: full release, Latest, no marker.
- **No publish-straight-to-Latest option.** A full release without markers counts as approved for every train, so it would reach every box untested. Every release starts as a pre-release and becomes a full release only through a train's sign-off, which writes the marker in the same update.

The assets are `nvidia-mig.raw`, its `.sha256`, and `install-mig-sysext.sh` / `uninstall-mig-sysext.sh` (the scripts `get.sh` runs). The build smoke-tests the artifact before publishing; a failing smoke test, or a missing asset, blocks the release.

## Which release a box installs

The one-liner is [`get.sh`](../get.sh) on `main`. It reads the TrueNAS version (`midclt call system.info`), derives the **train** (the major version from 26 on, so every 26.x release including betas is train `26`; major.minor before that, e.g. `25.10`), lists the releases through the GitHub API, and picks the newest one **approved** for that train:

- its notes carry `<!-- verified-train: <train> -->`, or
- it is a full (non-pre-release) release with no `verified-train` marker at all. Every release published before per-train approval is one of these, so they stay approved for every train.

A marker for another train only does not count, and nothing unapproved is installed on stable or beta boxes: with no approved release for the train it stops and links the open hardware-test issues. It then runs **that** release's `install-mig-sysext.sh` (or, with `--uninstall`, its `uninstall-mig-sysext.sh`) with the user's arguments plus `--release=<tag>`. Releases published before `get.sh` carry only the raw and its checksum; for those the script comes from the release's tag (`raw.githubusercontent.com/<repo>/<tag>/scripts/...`), the source that release was built from. `--release=TAG` skips the selection.

`install-mig-sysext.sh`:
- No `--release` (run on its own, e.g. a raw download from `main`) → it resolves the release by the same rule: the selection code is one block copied verbatim into both scripts, and `tests/test_release_selection.py` fails CI if the copies differ. The same functions are in nvidia-driver-support's `get.sh`; keep them byte-identical. With no approved release it stops rather than install anything.
- `--release=TAG` → `releases/download/<tag>/nvidia-mig.raw`.
- Either way the download is verified against the release's `nvidia-mig.raw.sha256` sidecar (a hard failure if it is missing or mismatched, so the sidecar asset is load-bearing), and the on-pool PREINIT script is staged from inside the verified raw (bundled at `usr/share/nvidia-mig/`; releases that predate the bundling fall back to a fetch pinned to the same tag, never to `main`).

Because the sysext is driver/kernel-agnostic, there's no per-kernel build: one release serves every train, and each train approves it separately.

## Lint

[`lint.yml`](../.github/workflows/lint.yml) runs `shellcheck --severity=warning` over `get.sh`, the scripts and `.github/scripts/`, `actionlint` over the workflows, `validate-tracked-versions.sh` over `.github/tracked-versions.json`, and the unit tests in `tests/` (`python3 -m unittest discover -s tests`): the release selection, `get.sh` and the installer's resolution with stub `midclt`/`curl`, and `build-sysext.yml`'s and `promote.yml`'s github-script under node with stub clients.
