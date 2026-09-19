"""Render the hardware-test issues build-sysext.yml opens and check them.

The github-script body of the issue step is extracted verbatim and run under
node with a stub GitHub client, from the repo root, so it reads the real
tracked-versions.json. The issues are procedures a human follows by hand, so
these checks pin what their commands depend on: the markers promote.yml
parses, flags get.sh and the installer accept, and the per-train duplicate
check."""
import json
import os
import re
import unittest

from workflow_script import OWNER, REPO, ROOT, run_script, step_script

BUILD_YML = ROOT / ".github" / "workflows" / "build-sysext.yml"
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install-mig-sysext.sh"
STEP = "Open hardware-test issues, one per train (prerelease gate)"

HARNESS = """
const state = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = { labels: [], issues: [] };
console.log = (...a) => process.stderr.write(a.join(' ') + '\\n');
const github = { rest: { issues: {
  createLabel: async (args) => { out.labels.push(args);
    if ((state.existingLabels || []).includes(args.name)) {
      throw Object.assign(new Error('exists'), { status: 422 }); } },
  listForRepo: async ({ labels }) => ({ data: (state.open || [])
    .filter((i) => i.labels.includes(labels)) }),
  create: async (args) => { out.issues.push(args); },
} } };
const context = { repo: { owner: 'truenas-community-sysexts', repo: 'nvidia-mig-support' } };
(async () => {
%s
})().then(() => process.stdout.write(JSON.stringify(out)),
          (e) => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""


def min_driver():
    # The same line the workflow's "Read the MIG minimum driver major" step
    # reads with sed.
    return re.search(r"^MIN_DRIVER_MAJOR=(\d+)$", INSTALL_SH.read_text(), re.M).group(1)


def render(run="80", open_issues=(), existing_labels=()):
    env = dict(os.environ, RUN_NUMBER=run, MIG_MIN_DRIVER=min_driver())
    return run_script(HARNESS, step_script("build-sysext.yml", STEP),
                      {"open": list(open_issues),
                       "existingLabels": list(existing_labels)}, env=env)


def open_issue(title, body="", labels=("hardware-test",), number=7):
    return {"number": number, "title": title, "body": body, "labels": list(labels)}


def code_lines(body):
    out, inside = [], False
    for ln in body.splitlines():
        if ln.startswith("```"):
            inside = not inside
            continue
        if inside:
            out.append(ln)
    return out


def accepted_flags():
    flags = set()
    for path in (GET_SH, INSTALL_SH):
        flags |= set(re.findall(r"^\s+(--[a-z-]+=?)\*?\)", path.read_text(), re.M))
        flags |= set(re.findall(r"^\s+-h\|(--[a-z-]+)\)", path.read_text(), re.M))
    return flags


class PerTrain(unittest.TestCase):
    def setUp(self):
        self.out = render()
        self.by_train = {re.search(r"<!-- train: (\S+) -->", i["body"]).group(1): i
                         for i in self.out["issues"]}

    def test_one_issue_per_tracked_train(self):
        tracked = json.loads((ROOT / ".github" / "tracked-versions.json").read_text())
        self.assertEqual(sorted(self.by_train), sorted(t["key"] for t in tracked["trains"]))

    def test_titles_name_the_train(self):
        mn = min_driver()
        self.assertEqual(self.by_train["25.10"]["title"],
                         f"Hardware test: NVIDIA MIG tooling v80 | MIG-capable NVIDIA GPU, "
                         f"driver {mn}+, TrueNAS 25.10 | v80")
        self.assertEqual(self.by_train["26"]["title"],
                         f"Preview hardware test: NVIDIA MIG tooling v80 | MIG-capable NVIDIA GPU, "
                         f"driver {mn}+, TrueNAS 26 beta | v80")

    def test_labels_follow_the_channel(self):
        self.assertEqual(self.by_train["25.10"]["labels"], ["hardware-test"])
        self.assertEqual(self.by_train["26"]["labels"], ["preview-hardware-test"])
        self.assertEqual(sorted(l["name"] for l in self.out["labels"]),
                         ["hardware-test", "preview-hardware-test"])

    def test_existing_labels_are_fine(self):
        out = render(existing_labels=["hardware-test", "preview-hardware-test"])
        self.assertEqual(len(out["issues"]), 2)

    def test_markers_promote_yml_parses(self):
        for key, iss in self.by_train.items():
            body = iss["body"]
            self.assertIn("<!-- release-tag: v80 -->", body.splitlines())
            self.assertIn(f"<!-- train: {key} -->", body.splitlines())
            # promote.yml's regexes, verbatim.
            self.assertEqual(re.search(r"<!--\s*release-tag:\s*(\S+?)\s*-->", body).group(1), "v80")
            self.assertEqual(re.search(r"<!--\s*train:\s*(\S+?)\s*-->", body).group(1), key)

    def test_body_tells_the_tester_which_train(self):
        body = self.by_train["26"]["body"]
        self.assertIn("approves it for **TrueNAS 26 beta** boxes only", body)
        self.assertIn("on a TrueNAS 26 beta box", body)
        self.assertIn("TrueNAS 25.10 has its own issue for this release", body)
        self.assertIn("cat /etc/version                       # starts with 26.", body)
        self.assertIn("`verified-train: 26`", body)

    def test_install_commands_pin_this_release_via_get_sh(self):
        for iss in self.out["issues"]:
            lines = code_lines(iss["body"])
            self.assertIn(f"I=https://raw.githubusercontent.com/{OWNER}/{REPO}/main/get.sh", lines)
            runs = [ln for ln in lines if ln.startswith('curl -fsSL "$I"')]
            self.assertEqual(len(runs), 4)
            for ln in runs:
                self.assertIn("--release=v80", ln)

    def test_every_flag_in_the_procedure_exists(self):
        flags = accepted_flags()
        for iss in self.out["issues"]:
            for ln in code_lines(iss["body"]):
                if 'curl -fsSL "$I"' not in ln:
                    continue
                cmd = ln.split("#")[0].split("bash -s --", 1)[1]
                for f in re.findall(r"(--[a-z-]+=?)", cmd):
                    self.assertIn(f, flags, ln)

    def test_sha256_check_uses_this_releases_sidecar(self):
        for iss in self.out["issues"]:
            self.assertIn(f"curl -fsSL https://github.com/{OWNER}/{REPO}/releases/download/v80/"
                          "nvidia-mig.raw.sha256", "\n".join(code_lines(iss["body"])))

    def test_no_em_dash_or_emoji(self):
        for iss in self.out["issues"]:
            text = iss["title"] + iss["body"]
            self.assertNotIn("\u2014", text)  # em-dash
            self.assertFalse(any(ord(ch) > 0x2600 for ch in text), text)


class DuplicateCheck(unittest.TestCase):
    def trains_created(self, *open_issues):
        out = render(open_issues=open_issues)
        return sorted(re.search(r"<!-- train: (\S+) -->", i["body"]).group(1)
                      for i in out["issues"])

    def test_open_issue_for_tag_and_train_by_markers(self):
        body = "<!-- release-tag: v80 -->\n<!-- train: 25.10 -->\n"
        self.assertEqual(self.trains_created(open_issue("renamed", body)), ["26"])

    def test_open_issue_for_tag_and_train_by_title(self):
        title = ("Preview hardware test: NVIDIA MIG tooling v80 | MIG-capable NVIDIA GPU, "
                 "driver 570+, TrueNAS 26 beta | v80")
        self.assertEqual(self.trains_created(
            open_issue(title, labels=("preview-hardware-test",))), ["25.10"])

    def test_old_single_issue_covers_every_train(self):
        title = ("Hardware test: NVIDIA MIG tooling v80 | MIG-capable NVIDIA GPU, "
                 "driver 570+, TrueNAS 25.10+ or 26 beta | v80")
        self.assertEqual(self.trains_created(
            open_issue(title, "<!-- release-tag: v80 -->\n")), [])
        self.assertEqual(self.trains_created(
            open_issue("Hardware test: nvidia-mig v80")), [])

    def test_other_train_or_tag_does_not_block(self):
        self.assertEqual(self.trains_created(
            open_issue("x", "<!-- release-tag: v80 -->\n<!-- train: 24.04 -->\n"),
            open_issue("Hardware test: nvidia-mig v8", number=8),
            open_issue("y", "<!-- release-tag: v79 -->\n<!-- train: 25.10 -->\n", number=9)),
            ["25.10", "26"])


class PublishGate(unittest.TestCase):
    def test_no_publish_straight_to_latest(self):
        # A full release with no verified-train marker is approved for every
        # train, so nothing may publish one: every release starts as a
        # prerelease, and the workflow takes no mark_latest input.
        text = BUILD_YML.read_text()
        self.assertNotIn("mark_latest", text)
        self.assertNotIn("make_latest", text)
        self.assertIn('-F draft=false -F prerelease=true', text)

    def test_release_carries_the_scripts_get_sh_runs(self):
        text = BUILD_YML.read_text()
        files = text[text.index("          files: |"):text.index("fail_on_unmatched_files")]
        for asset in ("dist/nvidia-mig.raw", "dist/nvidia-mig.raw.sha256",
                      "scripts/install-mig-sysext.sh", "scripts/uninstall-mig-sysext.sh"):
            self.assertIn(f"\n            {asset}\n", files)
        self.assertIn("fail_on_unmatched_files: true", text)

    def test_issue_title_reads_the_installers_driver_floor(self):
        # The workflow's sed must still find MIN_DRIVER_MAJOR in the installer.
        text = BUILD_YML.read_text()
        self.assertIn("sed -n 's/^MIN_DRIVER_MAJOR=\\([0-9][0-9]*\\)$/\\1/p' "
                      "scripts/install-mig-sysext.sh", text)
        self.assertTrue(min_driver().isdigit())


if __name__ == "__main__":
    unittest.main()
