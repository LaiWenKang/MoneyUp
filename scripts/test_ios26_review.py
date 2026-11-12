import os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).with_name('export_ios26_review.sh').resolve()
class ExportTests(unittest.TestCase):
    def run_case(self, complete, fail='', suite='full'):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        for name in complete:
            bundle = root / (name + '.xcresult'); bundle.mkdir(); (bundle / 'Info.plist').write_text('fixture')
        fake = root / 'xcrun'
        fake.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$RUNNER_TEMP/calls"
if [[ "$*" == *"${FAIL_BUNDLE:-NOFAIL}"* ]]; then echo "fixture export failure" >&2; exit 64; fi
if [[ "$*" == *"get test-results summary"* ]]; then printf '{"result":"fixture"}\\n'; fi
'''); fake.chmod(0o755)
        result = subprocess.run(['bash', str(SCRIPT)], env={**os.environ, 'RUNNER_TEMP':str(root),'PATH':str(root)+':'+os.environ['PATH'],'FAIL_BUNDLE':fail or 'NOFAIL', 'REVIEW_SUITE':suite}, capture_output=True,text=True)
        return root, result
    def test_both_complete_success(self):
        root, result = self.run_case(['MoneyUpUI26','MoneyUpColdLaunch'])
        self.assertEqual(result.returncode,0)
        self.assertTrue((root/'ui26-summary.json').exists()); self.assertTrue((root/'ui26-cold-summary.json').exists())
    def test_second_incomplete_preserves_first_and_fails(self):
        root, result = self.run_case(['MoneyUpUI26'])
        self.assertEqual(result.returncode,1); self.assertTrue((root/'ui26-summary.json').exists())
        self.assertIn('MoneyUpColdLaunch', (root/'ui26-export-errors.log').read_text())
        self.assertNotIn('MoneyUpColdLaunch', (root/'calls').read_text())
    def test_first_incomplete_still_exports_second_and_fails(self):
        root, result = self.run_case(['MoneyUpColdLaunch'])
        self.assertEqual(result.returncode,1); self.assertTrue((root/'ui26-cold-summary.json').exists())
    def test_export_error_retains_diagnostic_and_attempts_other_bundle(self):
        root, result = self.run_case(['MoneyUpUI26','MoneyUpColdLaunch'],'MoneyUpUI26')
        self.assertEqual(result.returncode,1); self.assertTrue((root/'ui26-cold-summary.json').exists())
        self.assertFalse((root/'ui26-summary.json').exists())
        self.assertIn('fixture export failure',(root/'ui26-export-errors.log').read_text())
    def test_focused_does_not_require_native_bundle(self):
        root, result = self.run_case(['MoneyUpColdLaunch'],suite='favourite')
        self.assertEqual(result.returncode,0)
        self.assertNotIn('MoneyUpUI26',(root/'calls').read_text())
    def test_unknown_mode_fails_without_parsing(self):
        root, result = self.run_case([],suite='invalid')
        self.assertEqual(result.returncode,2); self.assertFalse((root/'calls').exists())

class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        cls.workflow = yaml.load((SCRIPT.parents[1]/'.github/workflows/ios26-ui.yml').read_text(),Loader=yaml.BaseLoader)
        cls.steps = cls.workflow['jobs']['native-review']['steps']
    def step(self,name): return next(s for s in self.steps if s.get('name')==name)
    def test_full_remains_default_and_diagnostic_is_distinct(self):
        w=self.workflow
        self.assertEqual(w['on']['workflow_dispatch']['inputs']['suite']['default'],'full')
        self.assertIn('Favourite diagnostic (not full review)',w['jobs']['native-review']['name'])
        self.assertIn("inputs.suite || 'full'",w['concurrency']['group'])
    def test_every_shell_fragment_parses(self):
        for step in self.steps:
            if 'run' in step:
                result=subprocess.run(['bash','-n'],input=step['run'],text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
    def execute_ui(self,suite,exitcode=0):
        tmp=tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); root=pathlib.Path(tmp.name)
        fake=root/'xcodebuild'
        fake.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$RUNNER_TEMP/args\"\necho fixture-build-log\nexit "+str(exitcode)+"\n");fake.chmod(0o755)
        run=subprocess.run(['bash','-c',self.step('Run UI journeys')['run']],env={**os.environ,'RUNNER_TEMP':str(root),'SIMULATOR_ID':'fixture','REVIEW_SUITE':suite,'PATH':str(root)+':'+os.environ['PATH']},capture_output=True,text=True)
        return root,run
    def test_native_coverage_matches_prechange_baseline(self):
        import re
        actual = re.findall(r'-only-testing:MoneyUpTests/\w+', self.step("Run native render tests")["run"])
        self.assertEqual(actual, ['-only-testing:MoneyUpTests/AppwideExperienceTests', '-only-testing:MoneyUpTests/OverviewInsightTests', '-only-testing:MoneyUpTests/SmartOverviewRenderTests', '-only-testing:MoneyUpTests/AppwideRenderEvidenceTests', '-only-testing:MoneyUpTests/Feedback1039RegressionTests', '-only-testing:MoneyUpTests/AutomaticUnlockTests', '-only-testing:MoneyUpTests/QuickLogKeyboardJourneyTests', '-only-testing:MoneyUpTests/QuickLogBatchTests', '-only-testing:MoneyUpTests/QuickLogFlowReliabilityTests', '-only-testing:MoneyUpTests/BatchDeviceCoverageTests', '-only-testing:MoneyUpTests/ScreenshotReceiptJourneyTests', '-only-testing:MoneyUpTests/DailyJourneyAcceptanceTests', '-only-testing:MoneyUpTests/TransactionPreparationTests', '-only-testing:MoneyUpTests/JourneyRecalculationTests', '-only-testing:MoneyUpTests/BudgetCheckpointAvailabilityTests', '-only-testing:MoneyUpTests/BudgetResilienceTests', '-only-testing:MoneyUpTests/BudgetPeriodRecoveryTests', '-only-testing:MoneyUpTests/NavigationPresentationTests', '-only-testing:MoneyUpTests/RedesignRenderEvidenceTests', '-only-testing:MoneyUpTests/PlatformQuickLogActionTests'])
    def test_full_ui_has_no_test_filters(self):
        root,r=self.execute_ui('full'); self.assertEqual(r.returncode,0)
        args=(root/'args').read_text();self.assertNotIn('-only-testing',args);self.assertNotIn('-skip-testing',args)
    def test_focused_runs_exact_original_test(self):
        root,r=self.execute_ui('favourite');self.assertEqual(r.returncode,0)
        selectors=[x for x in (root/'args').read_text().splitlines() if x.startswith('-only-testing')]
        self.assertEqual(selectors,['-only-testing:MoneyUpUITests/MoneyUpJourneyTests/testSaveAsFavouriteFromTheSavedBanner'])
    def test_build_failure_not_hidden_by_tee(self):
        root,r=self.execute_ui('favourite',65);self.assertEqual(r.returncode,65)
        self.assertIn('fixture-build-log',(root/'ui26-journeys.log').read_text())
    def test_unknown_ui_mode_cannot_run(self):
        root,r=self.execute_ui('wrong');self.assertEqual(r.returncode,2);self.assertFalse((root/'args').exists())
    def test_exports_and_upload_always_attempted(self):
        self.assertEqual(self.step('Export review evidence')['if'],'${{ always() }}')
        upload=self.steps[-1]; self.assertEqual(upload['if'],'${{ always() }}')
        self.assertIn('ui26-export-errors.log',upload['with']['path'])
        self.assertIn('ui26-journeys.log',upload['with']['path'])
if __name__ == '__main__': unittest.main()

