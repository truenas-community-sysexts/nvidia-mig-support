"""End-to-end runs of get.sh, and of the installer's release resolution,
against stub `midclt` and `curl` commands on PATH.

The curl stub serves canned GitHub API pages and, for a release asset or a
file at a tag, writes a fake script that prints which file and release it is
and the arguments it got, so the tests see exactly what get.sh would run."""
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from urllib.parse import urlparse

from release_fixtures import release

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install-mig-sysext.sh"
REPO = "truenas-community-sysexts/nvidia-mig-support"

# A raw.githubusercontent.com URL in a script, capturing what follows the
# host so the tag guard below can check that tail instead of testing a line
# for a bare hostname substring.
RAW_URL = re.compile(r"raw\.githubusercontent\.com/(\S*)")


def logged_host(line):
    """Hostname of the URL in a stub-log line ("curl <url>"), or "" for other lines."""
    parts = line.split()
    if len(parts) > 1 and parts[0] == "curl":
        return urlparse(parts[1]).hostname or ""
    return ""


def logged_path(line):
    """Path of the URL in a stub-log line ("curl <url>"), or "" for other lines."""
    parts = line.split()
    if len(parts) > 1 and parts[0] == "curl":
        return urlparse(parts[1]).path
    return ""


# STUB_NO_ASSETS: tags whose release has no script assets (published before
# get.sh). STUB_NO_TREE: tags whose source has no such file either.
CURL_STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, re, sys
    from urllib.parse import urlparse
    args = sys.argv[1:]
    url = args[-1]
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write("curl " + url + "\\n")
    parsed = urlparse(url)
    host, path = parsed.hostname, parsed.path
    def tags(name):
        return [t for t in os.environ.get(name, "").split(",") if t]
    def fake(name, ref):
        with open(args[args.index("-o") + 1], "w") as f:
            f.write('#!/usr/bin/env bash\\n'
                    'echo "dir $(ls -A "$(dirname "$0")" | tr "\\\\n" " ")" >> "$STUB_LOG"\\n'
                    f'echo "RAN {name} from {ref} with: $*"\\n')
    if host == "api.github.com":
        page = int(re.search(r"(?:^|&)page=(\\d+)", parsed.query).group(1))
        pages = json.load(open(os.environ["STUB_PAGES"]))
        print(json.dumps(pages[page - 1] if page <= len(pages) else []))
    elif host == "github.com" and "/releases/download/" in path:
        tag, asset = path.split("/releases/download/")[1].split("/")
        if tag in tags("STUB_NO_ASSETS"):
            sys.exit(22)
        fake(asset, tag)
    elif host == "raw.githubusercontent.com":
        parts = path.lstrip("/").split("/")
        ref, name = parts[2], parts[-1]
        if ref in tags("STUB_NO_TREE"):
            sys.exit(22)
        fake(name, ref)
    else:
        sys.exit(22)
    """)

MIDCLT_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "midclt $*" >> "$STUB_LOG"
    [ -n "$STUB_VERSION" ] || exit 1
    echo "{\\"version\\": \\"$STUB_VERSION\\"}"
    """)

RELEASES = [release("v81", prerelease=True), release("v80", trains=["26"]),
            release("v79"), release("v78")]


class Stubbed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        for name, text in (("curl", CURL_STUB), ("midclt", MIDCLT_STUB)):
            path = self.dir / name
            path.write_text(text)
            path.chmod(0o755)
        self.log = self.dir / "log"
        self.log.write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def run_bash(self, args, version, releases=RELEASES, no_assets=(), no_tree=()):
        pages = self.dir / "pages.json"
        pages.write_text(json.dumps([releases]))
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}",
                   STUB_LOG=str(self.log), STUB_PAGES=str(pages),
                   STUB_VERSION=version, TMPDIR=str(self.dir),
                   STUB_NO_ASSETS=",".join(no_assets),
                   STUB_NO_TREE=",".join(no_tree))
        return subprocess.run(["bash", *args], capture_output=True, text=True,
                              env=env)

    def calls(self):
        return self.log.read_text().splitlines()


class GetSh(Stubbed):
    def get(self, *args, version="25.10.7", releases=RELEASES, **kw):
        return self.run_bash([str(GET_SH), *args], version, releases, **kw)

    def test_runs_the_approved_releases_installer_pinned_to_it(self):
        p = self.get()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN install-mig-sysext.sh from v79 with: --release=v79")
        self.assertIn("TrueNAS 25.10.7 (train 25.10): newest approved release is v79",
                      p.stderr)
        self.assertIn(f"curl https://github.com/{REPO}/releases/download/v79/"
                      "install-mig-sysext.sh", self.calls())

    def test_each_train_gets_its_own_approved_release(self):
        p = self.get(version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("from v80 with: --release=v80", p.stdout)

    def test_arguments_pass_through(self):
        p = self.get("--pool=fast", "--dry-run")
        self.assertIn("with: --pool=fast --dry-run --release=v79", p.stdout)

    def test_uninstall_runs_the_approved_releases_uninstaller_without_release(self):
        p = self.get("--uninstall", "--keep-persist")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN uninstall-mig-sysext.sh from v79 with: --keep-persist")

    def test_pinned_release_skips_selection(self):
        p = self.get("--release=v81", "--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN install-mig-sysext.sh from v81 with: --check --release=v81")
        self.assertFalse(any(c.startswith("midclt")
                             or logged_host(c) == "api.github.com"
                             for c in self.calls()), self.calls())

    def test_pinned_uninstall(self):
        p = self.get("--uninstall", "--release=v81")
        self.assertEqual(p.stdout.strip(),
                         "RAN uninstall-mig-sysext.sh from v81 with:")

    def test_release_without_script_assets_runs_the_script_at_its_tag(self):
        # Releases published before get.sh (v33 and older) carry only
        # nvidia-mig.raw and its .sha256: the installer comes from the same
        # release's tag, never from main or another release.
        p = self.get(no_assets=["v79"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN install-mig-sysext.sh from v79 with: --release=v79")
        self.assertIn(f"curl https://raw.githubusercontent.com/{REPO}/v79/scripts/"
                      "install-mig-sysext.sh", self.calls())
        self.assertIn("Release v79 has no install-mig-sysext.sh asset", p.stderr)
        self.assertNotIn("curl: ", p.stderr)

    def test_uninstall_of_a_release_without_script_assets(self):
        p = self.get("--uninstall", no_assets=["v79"])
        self.assertEqual(p.stdout.strip(), "RAN uninstall-mig-sysext.sh from v79 with:")
        self.assertIn(f"curl https://raw.githubusercontent.com/{REPO}/v79/scripts/"
                      "uninstall-mig-sysext.sh", self.calls())

    def test_script_missing_everywhere_is_an_error(self):
        p = self.get(no_assets=["v79"], no_tree=["v79"])
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("could not download install-mig-sysext.sh from release v79", p.stderr)
        self.assertFalse(any("/main/" in c for c in self.calls()), self.calls())

    def test_installer_runs_alone_in_its_directory(self):
        # A sibling nvidia-mig-preinit.sh would win over the copy bundled in
        # the verified raw, so the installer's directory holds nothing else.
        p = self.get()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("dir install-mig-sysext.sh ", self.calls())

    def test_no_approved_release_stops_before_any_download(self):
        p = self.get(version="26.0.0-BETA.3",
                     releases=[release("v81", prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertFalse(any("/releases/download/" in logged_path(c)
                             or logged_host(c) == "raw.githubusercontent.com"
                             for c in self.calls()), self.calls())

    def test_unreadable_truenas_version_is_an_error(self):
        p = self.get(version="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("could not read the TrueNAS version", p.stderr)
        self.assertFalse(any("/releases/download/" in c for c in self.calls()))

    def test_empty_release_flag_is_refused(self):
        p = self.get("--release=")
        self.assertEqual(p.returncode, 2)

    def test_temp_dir_is_removed(self):
        self.get()
        self.assertEqual(list(self.dir.glob("nvidia-mig-get.*")), [])


def function(text, name):
    return re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", text, re.S | re.M).group(0)


class InstallerResolve(Stubbed):
    """install-mig-sysext.sh run on its own (a raw download from main, or a
    copy of the script alone) resolves its release by the same rule."""

    def installer_script(self, setup, commands):
        text = INSTALL_SH.read_text()
        block = text[text.index("# BEGIN approved-release"):
                     text.index("# END approved-release")]
        script = self.dir / "resolve.sh"
        script.write_text(
            f'set -euo pipefail\nREPO="{REPO}"\n{setup}\n{block}\n'
            f'{function(text, "resolve_release_tag")}\n{commands}\n')
        return script

    def resolve(self, version, release_tag="", releases=RELEASES):
        script = self.installer_script(
            f'RELEASE_TAG="{release_tag}"',
            'resolve_release_tag\necho "tag=${RELEASE_TAG}"')
        return self.run_bash([str(script)], version, releases)

    def test_auto_resolve_takes_the_approved_release(self):
        p = self.resolve("26.1.0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Resolved release: v80 (newest approved for this TrueNAS train)",
                      p.stdout)
        self.assertIn("tag=v80", p.stdout)
        self.assertFalse(any("releases/latest" in c for c in self.calls()), self.calls())

    def test_grandfathered_release_on_a_stable_box(self):
        p = self.resolve("25.10.7")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("tag=v79", p.stdout)

    def test_no_approved_release_fails_instead_of_taking_latest(self):
        p = self.resolve("26.1.0", releases=[release("v81", prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("tag=", p.stdout)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)

    def test_explicit_release_is_trusted(self):
        p = self.resolve("", release_tag="v81")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("tag=v81", p.stdout)
        self.assertFalse(any(c.startswith("midclt") for c in self.calls()))

    def preinit(self, version, release_tag="", releases=RELEASES):
        """stage_mig_preinit for a raw with no bundled copy (predates the
        bundling), run from a directory with no sibling copy."""
        text = INSTALL_SH.read_text()
        dest = self.dir / "persist" / "nvidia-mig-preinit.sh"
        dest.parent.mkdir()
        script = self.installer_script(
            f'RELEASE_TAG="{release_tag}"\nDRY_RUN=false\nMIG_LISTING=""\n'
            'MIG_SRC=/nonexistent\n' + function(text, "if_real"),
            function(text, "stage_mig_preinit")
            + f'if stage_mig_preinit "{dest}"; then echo "staged $(cat "{dest}")"; '
              'else echo "not staged"; fi')
        return self.run_bash([str(script)], version, releases)

    def test_preinit_fetch_is_pinned_to_the_approved_release(self):
        p = self.preinit("26.1.0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("staged", p.stdout)
        self.assertIn(f"curl https://raw.githubusercontent.com/{REPO}/v80/scripts/"
                      "nvidia-mig-preinit.sh", self.calls())

    def test_preinit_is_never_fetched_from_main(self):
        # No approved release: nothing is staged, and main is not a fallback.
        p = self.preinit("26.1.0", releases=[release("v81", prerelease=True)])
        self.assertIn("not staged", p.stdout)
        self.assertFalse(any(logged_host(c) == "raw.githubusercontent.com"
                             for c in self.calls()), self.calls())


class NoUnapprovedSources(unittest.TestCase):
    def test_no_latest_redirect_or_main_fetch_in_the_scripts(self):
        # GitHub's Latest is cosmetic now, and main is not what a hardware
        # test approved: neither may be an install source. (Comments may
        # still show the main/get.sh one-liner.)
        for path in (GET_SH, INSTALL_SH, ROOT / "scripts" / "uninstall-mig-sysext.sh",
                     ROOT / "scripts" / "configure-mig.sh"):
            code = [ln for ln in path.read_text().splitlines()
                    if not ln.lstrip().startswith("#")]
            for ln in code:
                self.assertNotIn("releases/latest", ln, path.name)
                self.assertNotIn("/main/", ln, path.name)
                # A file at a git ref is fetched only at the release's tag.
                for tail in RAW_URL.findall(ln):
                    self.assertRegex(
                        tail, r"^\$\{REPO\}/\$\{(tag|RELEASE_TAG)\}/", path.name)


class HelpText(unittest.TestCase):
    def test_help_prints_the_whole_header_and_nothing_else(self):
        p = subprocess.run(["bash", str(INSTALL_SH), "--help"], capture_output=True,
                           text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("Install the nvidia-mig sysext on TrueNAS."))
        self.assertTrue(p.stdout.rstrip().endswith("error (no tty + ambiguous)."), p.stdout)
        self.assertIn("--release=TAG", p.stdout)


if __name__ == "__main__":
    unittest.main()
