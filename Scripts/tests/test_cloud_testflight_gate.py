"""Run the actual TestFlight audience gate in the shell without dispatching CI."""
import os
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_release_assets import workflow_step


class TestFlightInternalOnlyTests(unittest.TestCase):
    def test_preflight_audience_pin_and_upload_confirmation(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/testflight.yml").read_text()
        step = workflow_step(workflow, "Require main and explicit upload confirmation")
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        head = "a" * 40
        for internal, expected, operation, confirmation, ref, ok in (
            ("false", "", "validate", "", "main", True),
            ("false", "", "upload", "", "main", False),
            ("false", "", "upload", "UPLOAD", "main", True),
            ("true", "", "validate", "", "main", False),
            ("true", "", "upload", "UPLOAD", "main", False),
            ("true", "bad", "upload", "UPLOAD", "main", False),
            ("true", "b" * 40, "upload", "UPLOAD", "main", False),
            ("true", head, "upload", "", "main", False),
            ("true", head, "upload", "UPLOAD", "feature", False),
            ("true", head, "upload", "UPLOAD", "main", True),
            ("true", head, "validate", "", "main", True),
        ):
            with self.subTest(internal=internal, expected=expected, operation=operation,
                              confirmation=confirmation, ref=ref):
                env = os.environ | dict(TESTFLIGHT_INTERNAL_ONLY=internal, EXPECTED_SHA=expected,
                                        GITHUB_SHA=head, GITHUB_REF=f"refs/heads/{ref}", OPERATION=operation,
                                        CONFIRMATION=confirmation, CLOUD_BACKUP_MODE="off")
                run = subprocess.run(["bash", "-c", script], env=env, capture_output=True,
                                     text=True, check=False)
                self.assertEqual(run.returncode == 0, ok, run.stderr + run.stdout)

    def test_export_option_matches_the_requested_audience_in_all_legacy_modes(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/testflight.yml").read_text()
        step = workflow_step(workflow, "Export an App Store Connect IPA")
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        script = script.split("\nxcodebuild", 1)[0]
        # Linux stub for plutil writes the exact types that macOS plutil would
        # place in the plist. The production shell and Python validator run.
        stub = """plutil() {
            python3 - "$@" <<'PY_STUB'
import plistlib, sys
from pathlib import Path
op, *args = sys.argv[1:]
path = Path(args[-1])
if op == "-create":
    value = {}
elif op == "-insert":
    value = plistlib.loads(path.read_bytes())
    key, arg_type, arg, _ = args
    assert key not in value
    value[key] = arg if arg_type == "-string" else arg == "true"
else:
    raise ValueError(op)
path.write_bytes(plistlib.dumps(value))
PY_STUB
}
"""
        configured_cloud = {
            "MoneyUpCloudBackupEnabled": True, "MoneyUpCloudEnvironment": "production",
            "MoneyUpCloudBackupReleaseChannel": "internal-beta",
            "MoneyUpCloudBackupDeviceValidationPending": True,
            "MoneyUpCloudContainer": "iCloud.example.MoneyUp",
            "MoneyUpCloudAPIToken": "synthetic",
            "MoneyUpCloudCallbackURL": "https://backup.example/auth/callback",
        }
        for cloud, internal, expected in (
            ("off", "false", None),
            ("off", "true", True),
            ("internal-beta", "false", True),
            ("internal-beta", "true", True),
        ):
            with self.subTest(cloud=cloud, internal=internal), tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / "archive"
                app = archive / "Products/Applications/MoneyUp.app"
                app.mkdir(parents=True)
                info = configured_cloud if cloud == "internal-beta" else {}
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                options = Path(directory) / "export.plist"
                env = os.environ | dict(TESTFLIGHT_INTERNAL_ONLY=internal, CLOUD_BACKUP_MODE=cloud,
                                        ARCHIVE_PATH=str(archive), EXPORT_OPTIONS_PATH=str(options),
                                        APPLE_TEAM_ID="SYNTHETIC0")
                run = subprocess.run(["bash", "-c", stub + script], env=env, cwd=root,
                                     capture_output=True, text=True, check=False)
                self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
                actual = plistlib.loads(options.read_bytes())
                self.assertIs(actual.get("testFlightInternalTestingOnly"), expected)
