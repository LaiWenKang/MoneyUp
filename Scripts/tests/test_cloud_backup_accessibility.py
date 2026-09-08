import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import validate_accessible_errors as errors


class CloudBackupAccessibilityTests(unittest.TestCase):
    def sources(self):
        root = SCRIPTS.parent / "App/MoneyUp/CloudBackup"
        return {root / name: (root / name).read_text() for name in (
            "CloudBackupController.swift", "CloudBackupView.swift")}

    def test_bound_view_provides_accessible_error_route(self):
        self.assertEqual(errors.validate_documents(self.sources()), [])

    def test_unbound_alert_hidden_details_or_missing_retry_fail_closed(self):
        for before, after in (
            ("$controller.errorMessage", "$unrelated"),
            ("Text(detail)", "Text(unrelated)"),
            ("controller.backUpNow(", "unrelated.backUpNow("),
            ("controller.connectAccount(", "unrelated.connectAccount("),
            ("failureDetail = message", "unrelated = message"),
            ("errorMessage = message", "unrelated = message"),
        ):
            sources = {path: text.replace(before, after) for path, text in self.sources().items()}
            self.assertTrue(errors.validate_documents(sources), before)


if __name__ == "__main__":
    unittest.main()
