"""Regression checks for build selection and native cache boundaries."""

import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "native_cache_key", ROOT / "scripts/native-cache-key.py"
)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for path in (
            "core/go.mod",
            "core/go.sum",
            "core/engine/engine.go",
            "core/compat/embedded/geo.json",
            "core/tools/prepare-mobile/main.go",
            "scripts/native-cache-key.py",
            "scripts/build-libbox.sh",
            "scripts/build-core.sh",
            "scripts/go-build-settings.sh",
        ):
            self.write(path, path)

    def write(self, name, value="changed"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def test_mobile_ignores_tests_docs_cli_and_generated_output(self):
        before = cache.source_hash(self.root, "mobile")
        for path in (
            "core/engine/engine_test.go",
            "core/tools/prepare-mobile/main_test.go",
            "core/README.md",
            "core/.gitignore",
            "core/docs/design.md",
            "core/cmd/melsi-core/run.go",
            "core/dist/mobile-source-123/core/engine/engine.go",
            "app/lib/main.dart",
            "scripts/tests/test_build_workflow.py",
        ):
            with self.subTest(path=path):
                self.write(path)
                self.assertEqual(before, cache.source_hash(self.root, "mobile"))

    def test_mobile_tracks_production_assets_platform_files_and_tools(self):
        for path in (
            "core/engine/engine.go",
            "core/new_package/dialer_windows.go",
            "core/compat/embedded/geo.json",
            "core/compat/embedded/.hidden-asset",
            "core/compat/embedded/readme.md",
            "core/compat/testdata/embedded.bin",
            "core/compat/bridge_arm64.s",
            "core/tools/prepare-mobile/main.go",
            "core/go.mod",
            "core/go.sum",
            "scripts/build-libbox.sh",
            "scripts/native-cache-key.py",
        ):
            with self.subTest(path=path):
                before = cache.source_hash(self.root, "mobile")
                self.write(path)
                self.assertNotEqual(before, cache.source_hash(self.root, "mobile"))

    def test_go_cache_tracks_tests_and_desktop_build_settings(self):
        for path in (
            "core/engine/engine_test.go",
            "core/cmd/melsi-core/run.go",
            "scripts/build-core.sh",
            "scripts/go-build-settings.sh",
        ):
            with self.subTest(path=path):
                before = cache.source_hash(self.root, "go")
                self.write(path)
                self.assertNotEqual(before, cache.source_hash(self.root, "go"))

    def test_key_is_checkout_location_independent_and_tracks_renames(self):
        import shutil

        with tempfile.TemporaryDirectory() as other:
            shutil.copytree(self.root, Path(other) / "copy")
            self.assertEqual(
                cache.source_hash(self.root, "mobile"),
                cache.source_hash(Path(other) / "copy", "mobile"),
            )
        before = cache.source_hash(self.root, "mobile")
        source = self.root / "core/engine/engine.go"
        source.rename(source.with_name("engine_ios.go"))
        self.assertNotEqual(before, cache.source_hash(self.root, "mobile"))


class WorkflowSelectionTests(unittest.TestCase):
    platforms = ("android", "ios", "macos", "windows", "linux")

    @classmethod
    def setUpClass(cls):
        text = (ROOT / ".github/workflows/build.yml").read_text().split("\njobs:\n")[1]
        starts = list(re.finditer(r"^  ([a-z-]+):$", text, re.MULTILINE))
        cls.jobs = {
            match[1]: text[match.end(): starts[index + 1].start() if index + 1 < len(starts) else len(text)]
            for index, match in enumerate(starts)
        }

    def selected(self, event="workflow_dispatch", platform="all", tag="", ref="refs/heads/main"):
        selected = set()
        for name in self.platforms:
            condition = re.search(r"^    if: (.+)$", self.jobs[name], re.MULTILINE)[1]
            condition = condition.replace("||", "or").replace("&&", "and")
            if eval(condition, {"__builtins__": {}}, {
                "github": SimpleNamespace(event_name=event, ref=ref),
                "inputs": SimpleNamespace(platform=platform, release_tag=tag),
                "startsWith": str.startswith,
            }):
                selected.add(name)
        return selected

    def test_manual_build_selects_exactly_one_platform(self):
        for platform in self.platforms:
            with self.subTest(platform=platform):
                self.assertEqual({platform}, self.selected(platform=platform))
        self.assertEqual(set(self.platforms), self.selected())

    def test_release_and_automatic_builds_always_include_all_platforms(self):
        for platform in self.platforms:
            with self.subTest(platform=platform):
                self.assertEqual(set(self.platforms), self.selected(platform=platform, tag="v1.2.3"))
                self.assertEqual(set(self.platforms), self.selected(platform=platform, ref="refs/tags/v1.2.3"))
        for event in ("push", "pull_request"):
            self.assertEqual(set(self.platforms), self.selected(event=event, platform=""))

    def test_shared_tests_are_required_for_release(self):
        self.assertNotRegex(self.jobs["core-test"], r"(?m)^    if:")
        self.assertIn("needs: [core-test, android, ios, macos, windows, linux]", self.jobs["release"])

    def test_windows_keeps_pub_cache_without_sdk_cache(self):
        flutter = self.jobs["windows"].split("uses: subosito/flutter-action@v2\n")[1].split("\n      - ")[0]
        self.assertIn("cache: false", flutter)
        self.assertIn("pub-cache: true", flutter)

    def test_gradle_cache_writes_on_internal_builds_but_not_fork_prs(self):
        gradle = self.jobs["android"].split("uses: gradle/actions/setup-gradle@v4\n")[1].split("\n      - ")[0]
        condition = re.search(r"cache-read-only: \$\{\{ (.+) \}\}", gradle)[1]
        condition = condition.replace("||", "or").replace("&&", "and")
        for event, source_repo, read_only in (
            ("pull_request", "owner/Melsi", False),
            ("pull_request", "contributor/Melsi", True),
            ("pull_request", "", True),
            ("push", None, False),
            ("workflow_dispatch", None, False),
        ):
            with self.subTest(event=event, source_repo=source_repo):
                github = SimpleNamespace(event_name=event, repository="owner/Melsi")
                # Pushes and manual builds have no pull_request payload.
                if source_repo is not None:
                    github.event = SimpleNamespace(pull_request=SimpleNamespace(
                        head=SimpleNamespace(repo=SimpleNamespace(full_name=source_repo)),
                    ))
                self.assertEqual(read_only, eval(condition, {"__builtins__": {}}, {
                    "github": github,
                }))


class DesktopBuildSettingsTests(unittest.TestCase):
    def test_optional_naive_tags_are_windows_only(self):
        script = 'source scripts/go-build-settings.sh; melsi_desktop_go_tags "$1"'
        import os

        for platform, naive in (("windows", True), ("linux", False), ("darwin", False)):
            tags = subprocess.check_output(
                ["bash", "-c", script, "test", platform], cwd=ROOT,
                env={**os.environ, "MELSI_NAIVE": "1"}, text=True,
            ).strip().split(",")
            self.assertEqual(naive, "with_naive_outbound" in tags)
            self.assertEqual(naive, "with_purego" in tags)
            self.assertIn("with_utls", tags)
            self.assertIn("badlinkname", tags)


if __name__ == "__main__":
    unittest.main()
