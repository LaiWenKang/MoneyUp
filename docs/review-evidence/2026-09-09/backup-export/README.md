# Build 1046.1 encrypted-backup export crash

## Incident and cause

TestFlight report `AI4yvUzAycQIVxsjLnZ01V4` identifies MoneyUp 0.7.1 (1046.1),
iPhone 16 Pro Max, iOS 27.0 beta (24A5430a), at 2026-09-09 00:21:12 +08:00.
The owner reproduced it after generating inventory, entering the backup
password, and creating an encrypted backup. The report was downloaded as
`testflight_feedback.zip`; private tester metadata and the full device report
are not copied into the repository.

The exception is `EXC_CRASH / SIGABRT`. Its last exception stack is:

```text
NSFileWrapper.setPreferredFilename
SwiftUI.AnyTransferable fileWrapper(for:item:)
SwiftUI.AnyTransferable.newFileWrapper(contentType:)
SwiftUI.FileExportOperation.makeFiles
SwiftUI.FileImportExportBridge.presentExportPicker
```

`DataSafetyView` successfully awaits encrypted archive creation before setting
the export item and showing the picker. `MoneyUpArchiveTransfer` supplied a
file representation without a suggested filename. The dialog's
`defaultFilename` did not supply that earlier transfer metadata. A native
regression reproduces the same exception on the unmodified app:

```text
NSInvalidArgumentException:
-[NSFileWrapper setPreferredFilename:] *** preferredFilename cannot be empty.
```

The fix supplies `MoneyUp-Backup.moneyup` using the transfer representation's
`suggestedFileName`, and shares that name with the dialog. The existing
file-backed encrypted archive and cryptographic format are preserved.
See Apple's [transfer filename API](https://developer.apple.com/documentation/coretransferable/transferrepresentation/suggestedfilename(_:)-2yln2).

## iCloud availability

The signed 1046.1 upload came from `4b89508deeb4f50836c8aa0c2b95b8a7977bc1f0`
using the standard `xcodegen generate` path. That spec has no enabled cloud
configuration. `CloudBackupConfiguration.bundled()` returns nil and Data Safety
previously hid the whole entry. Development provisioning and the ignored
`CloudKit/Local.project.yml` were not included in that release.

Data Safety now shows the unavailable status in English and Simplified Chinese.
Where local export is available, it explains that the encrypted file can be
saved to iCloud Drive through Files. This is distinct from the separate-account
CloudKit backup feature. Production schema/configuration and live account,
callback, upload/download/restore acceptance remain open as documented in
[CloudKit setup](../../../../CloudKit/README.md).

## Verification

- Before fix: `BackupExportPresentationTests.testInventoryThenEncryptedBackupPresentsFilesPickerRepeatedly`
  failed with the exact empty-filename exception; result bundle
  `/tmp/moneyup-backup-export-before.xcresult`.
- After fix: **23 focused native tests passed**, zero failures, in
  `/tmp/moneyup-backup-export-verified.xcresult` (iOS 27 simulator, Xcode 27 beta 6).
  The export regression generated inventory, created a real encrypted fixture
  backup, presented and dismissed the live Files picker twice, checked transfer
  filename metadata, and verified byte-identical export. The other tests cover
  pending-capture preservation, reviewed restore, daily logging and restore,
  cloud opt-in/account isolation, and cloud UI rendering using fictional data.
- The initial fixed run used an overly strict assertion that direct transfer
  export must rename the source file. Apple describes this filename as a
  suggestion; receivers can retain the source basename. That assertion was
  corrected to require the archive extension and exact encrypted bytes. Its
  stalled diagnostic collection was stopped. The clean run above is the
  completed passing result, not the interrupted run.
- Release asset, Swift structure, architecture, launch safety, accessible error,
  performance signpost, platform action, and diff-whitespace checks passed.
- Data Safety's unavailable-cloud explanation was inspected in both languages.
  Its fixture render also synchronizes the app-language preference for strings
  resolved outside SwiftUI. The picker screenshot verifies presentation and the
  backup name; its remote folder-provider contents are not captured by the
  in-process renderer. This does not establish a completed user save to iCloud.
  The corrected bilingual render passed separately in
  `/tmp/moneyup-backup-export-localization.xcresult`.
- Physical TestFlight acceptance: pending a new signed build installed over the
  owner's existing app. Do not reset or replace the existing book to test this.

Review artifacts: [Files picker](files-picker.png),
[English availability](cloud-unavailable-en.png),
[Chinese availability](cloud-unavailable-zh-Hans.png), and
[release validation](release-validation.txt).

## Physical acceptance after the next beta upload

1. Update over 1046.1 and confirm the original book and pending entries remain.
2. Generate inventory, enter and confirm a backup password, and create the backup.
3. Confirm Files opens with `MoneyUp-Backup`; cancel, then repeat and save it
   outside MoneyUp. Verify the saved `.moneyup` file exists in the chosen location.
4. Reopen MoneyUp and confirm the book, inventory counts, and pending entries.
5. Test restore with fictional data on a separate disposable installation;
   preserve the owner's live installation throughout.
