import contextlib
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_release_assets import validate_storekit_release_gate

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/testflight.yml"


class StoreKitReleaseGateTests(unittest.TestCase):
    def test_current_workflow_requires_both_test_environments(self):
        validate_storekit_release_gate(WORKFLOW.read_text())

    def test_payment_gate_cannot_be_removed_skipped_or_allowed_to_fail(self):
        source = WORKFLOW.read_text()
        mutations = [
            source.replace("needs: [preflight, storekit-test]", "needs: preflight"),
            source.replace("name: StoreKit purchase integration", "continue-on-error: true\n    name: StoreKit purchase integration"),
            source.replace("- name: Run required StoreKit purchase and finish test", "- name: Run required StoreKit purchase and finish test\n        continue-on-error: true"),
            source.replace("-only-testing:MoneyUpTests/DeveloperSupportTests/testStoreKitConsumableSupportCanBeRepeatedAndFinished", "-only-testing:MoneyUpTests/DeveloperSupportTests/testConcurrentTapsStartOnlyOnePurchase"),
            source.replace("com.apple.CoreSimulator.SimRuntime.iOS-18-5", "com.apple.CoreSimulator.SimRuntime.iOS-26-5"),
        ]
        for mutated in mutations:
            with self.subTest(mutation=mutations.index(mutated)), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    validate_storekit_release_gate(mutated)

    def test_release_runtime_cannot_drop_other_native_tests(self):
        source = WORKFLOW.read_text()
        relocated = "-skip-testing:MoneyUpTests/DeveloperSupportTests/testStoreKitConsumableSupportCanBeRepeatedAndFinished"
        mutated = source.replace(relocated, relocated + " -skip-testing:MoneyUpTests/ImportDocumentTests")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            validate_storekit_release_gate(mutated)


if __name__ == "__main__":
    unittest.main()
