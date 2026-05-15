#!/usr/bin/env bash
# Validate that .github/tracked-versions.json has the shape the rest of the
# CI machinery (check-releases.yml — Phase 4 — and the build workflows once
# they consume tracked-versions defaults — Phase 2) will assume.
#
# Run locally:
#   .github/scripts/validate-tracked-versions.sh
# Exits non-zero with a `::error::` annotation on any shape violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${REPO_ROOT}/.github/tracked-versions.json"

if [ ! -f "$FILE" ]; then
  echo "::error title=tracked-versions::file not found: ${FILE}" >&2
  exit 1
fi

python3 - "$FILE" <<'PY'
import json
import re
import sys

path = sys.argv[1]

def fail(msg):
    print(f"::error title=tracked-versions::{msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    fail(f"invalid JSON in {path}: {e}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

# Match the shape check-releases.yml's tag parser will accept: 2-or-more
# numeric parts. Today's TrueNAS tags are 3- or 4-part (25.10.3, 25.10.3.1)
# but a future train (e.g. TS-26.0) could legitimately be 2-part. Capping at
# 5 parts so a runaway tag still trips the gate.
truenas_ver_re = re.compile(r"^\d+(\.\d+){1,4}$")
# NVIDIA driver tags are 3-part (e.g. 580.126.18). Strict X.Y.Z.
nvidia_ver_re = re.compile(r"^\d+\.\d+\.\d+$")
# Only two valid kernel-module flavors for the NVIDIA driver.
valid_kmod_types = {"open", "proprietary"}

truenas = data.get("truenas")
if not isinstance(truenas, dict):
    fail("'truenas' key missing or not an object")

tn_version = truenas.get("version")
if not isinstance(tn_version, str) or not truenas_ver_re.match(tn_version):
    fail(f"'truenas.version' missing or malformed (got {tn_version!r}); expected X.Y[.Z[.W[.V]]]")

tn_train = truenas.get("train")
if not isinstance(tn_train, str) or not tn_train.strip():
    fail(f"'truenas.train' missing or empty (got {tn_train!r})")

nvidia = data.get("nvidia")
if not isinstance(nvidia, dict):
    fail("'nvidia' key missing or not an object")

nv_driver = nvidia.get("driver")
if not isinstance(nv_driver, str) or not nvidia_ver_re.match(nv_driver):
    fail(f"'nvidia.driver' missing or malformed (got {nv_driver!r}); expected X.Y.Z")

nv_kmod = nvidia.get("kernel_module_type")
if nv_kmod not in valid_kmod_types:
    fail(f"'nvidia.kernel_module_type' must be one of {sorted(valid_kmod_types)} (got {nv_kmod!r})")

print(f"tracked-versions OK: TrueNAS {tn_version} ({tn_train}), NVIDIA {nv_driver} ({nv_kmod})")
PY
