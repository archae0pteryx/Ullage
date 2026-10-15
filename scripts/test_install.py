"""Exercise the real install/dev scripts using disposable apps and mocked OS commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        for script in ("dev.sh", "install-app.sh", "bundle-app.sh"):
            shutil.copy2(ROOT / "scripts" / script, self.repo / "scripts" / script)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.binary = self.root / "bin"
        self.binary.mkdir()
        self.executable(self.binary / "UllageApp", '''
printf 'launch:%s\n' "${ULLAGE_DB:-default}" >> "$DEV_TEST_TRACE"
''')
        self.executable(self.commands / "swift", '''
printf 'swift:%s\n' "$*" >> "$DEV_TEST_TRACE"
if [[ "${DEV_TEST_FAIL_BUILD:-0}" == 1 ]]; then exit 23; fi
if [[ " $* " == *' --show-bin-path '* ]]; then printf '%s\n' "$DEV_TEST_BIN"; fi
''')
        self.executable(self.commands / "codesign", 'exit 0\n')
        self.executable(self.commands / "osascript", '''
echo quit >> "$DEV_TEST_TRACE"
touch "$DEV_TEST_QUIT"
''')
        self.executable(self.commands / "pgrep", '''
if [[ "$DEV_TEST_RUNNING" == idle ]]; then exit 1; fi
if [[ "$DEV_TEST_RUNNING" != stuck && -f "$DEV_TEST_QUIT" ]]; then exit 1; fi
exit 0
''')
        self.executable(self.commands / "sleep", 'exit 0\n')
        self.destination = self.root / "Apps with spaces"
        self.app = self.destination / "Ullage.app"
        self.app.mkdir(parents=True)
        (self.app / "previous").write_text("previous app")
        self.database = self.root / "telemetry.db"
        self.database.write_text("existing history")
        self.trace = self.root / "trace"
        self.env = dict(os.environ, PATH=f"{self.commands}:{os.environ['PATH']}",
                        DEV_TEST_TRACE=str(self.trace), DEV_TEST_BIN=str(self.binary),
                        DEV_TEST_QUIT=str(self.root / "quit"), DEV_TEST_RUNNING="running",
                        ULLAGE_VERSION="0.0.0", ULLAGE_DB=str(self.database), CODE_SIGN_IDENTITY="-")
        self.env.pop("ULLAGE_BUILD_CONFIGURATION", None)
        self.env.pop("SWIFT_BUILD_FLAGS", None)

    @staticmethod
    def executable(path, body):
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def run_script(self, script="dev.sh"):
        return subprocess.run([str(self.repo / "scripts" / script), str(self.destination)],
                              env=self.env, capture_output=True, text=True, timeout=60)

    def test_dev_replaces_shortcut_not_homebrew_and_launches_debug_with_database_override(self):
        cellar = self.root / "Cellar" / "Ullage.app"
        cellar.parent.mkdir()
        self.app.rename(cellar)
        self.app.symlink_to(cellar, target_is_directory=True)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.is_symlink())
        self.assertTrue((cellar / "previous").exists())
        self.assertFalse((self.app / "previous").exists())
        self.assertTrue((self.app / "Contents/MacOS/UllageApp").is_file())
        trace = self.trace.read_text().splitlines()
        self.assertIn("swift:build -c debug --product UllageApp", trace)
        self.assertIn("swift:build -c debug --show-bin-path", trace)
        self.assertLess(trace.index("swift:build -c debug --show-bin-path"), trace.index("quit"))
        self.assertEqual(trace[-1], f"launch:{self.database}")
        self.assertEqual(self.database.read_text(), "existing history")

    def test_build_failure_keeps_running_app_and_previous_install(self):
        self.env["DEV_TEST_FAIL_BUILD"] = "1"
        result = self.run_script()
        self.assertEqual(result.returncode, 23)
        self.assertTrue((self.app / "previous").exists())
        self.assertNotIn("quit", self.trace.read_text())
        self.assertNotIn("launch:", self.trace.read_text())

    def test_unfinished_shutdown_aborts_before_replacing_app(self):
        self.env["DEV_TEST_RUNNING"] = "stuck"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still running", result.stderr)
        self.assertTrue((self.app / "previous").exists())
        self.assertNotIn("launch:", self.trace.read_text())

    def test_regular_install_still_builds_release_and_does_not_launch(self):
        self.env["DEV_TEST_RUNNING"] = "idle"
        result = self.run_script("install-app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text()
        self.assertIn("swift:build -c release --product UllageApp", trace)
        self.assertNotIn("quit", trace)
        self.assertNotIn("launch:", trace)


if __name__ == "__main__":
    unittest.main()
