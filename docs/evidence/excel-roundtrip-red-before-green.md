# Excel round-trip: red before green

Environment: Lucee 6.2.8.20 (Jetty), SQL Server 2022 Developer in Docker, Node 22.22.2, Playwright
1.56.1 with Chromium, LibreOffice Calc 24.2.7.2 (installed into the build container for
verification only; not a project dependency). Base commit `2b68cc06db98bf335b375529088ca5adef7132fb`.
Microsoft Excel, Adobe ColdFusion 2023 and SQL Server 2016 were not available and were not run.

## 1. Absent capability: every new check fails without the new source

The new source (`src/`, `app/`) was stashed, leaving the new and changed tests, and Lucee was
restarted on the base commit. Then the stash was restored and Lucee restarted again.

| Check | Result without the source | Why |
| --- | --- | --- |
| `InstrumentDocumentExporterTest` | 0 passed, 6 failed | `key [INSTRUMENTDOCUMENTEXPORTER] doesn't exist` |
| `tests/node/workbook.test.mjs` | cannot load | `ERR_MODULE_NOT_FOUND: .../app/assets/js/workbook.js` |
| `tests/node/admin-instrument.test.mjs` | cannot load | the same module is missing |
| `tests/node/browser-admin.test.mjs` | cannot load | the same module is missing |

## 2. What the checks were run against, besides this project's own writer

A reader tested only on files its own writer produced proves little about files people will
actually upload. So the reader was also run, from the start, against:

- `config/ICFWalk_Instrument_Configuration_Aligned.xlsx`, the reviewed workbook written by other
  software (shared strings, `str` and boolean cells, styled empty cells, Excel tables). It reads to
  exactly the supplied instrument: same definitions checksum, same whole-snapshot checksum.
- the workbook this project writes, opened in LibreOffice Calc and saved with its own writer
  (`tests/fixtures/workbooks/libreoffice-resaved.xlsx`): reads back unchanged;
- the same workbook edited inside LibreOffice through its own API and saved
  (`tests/fixtures/workbooks/libreoffice-edited.xlsx`): the five edits come back exactly and nothing
  else moves; imported through the real route, the comparison shows exactly those five edits.

The first LibreOffice attempt failed with "source file could not be loaded" for this project's file
**and** for the control (the aligned workbook). The container's LibreOffice had no Calc component;
installing `libreoffice-calc` fixed it. That was the environment, not the converter.

## 3. Defects found

None in the product. Two test expectations were wrong on their first run and were corrected, not
weakened: one edited the prompts of placeholder questions and then expected the placeholder summary
not to change (it correctly did); one picked as its "newly marked" question the question it had just
resolved. One existing browser assertion was updated for deliberately changed wording ("is neither an
Excel workbook (.xlsx) nor valid JSON, so nothing was sent"); it still checks that nothing was sent.

## Green on the finished tree (development runs)

| Check | Result |
| --- | --- |
| `InstrumentDocumentExporterTest` | 6/6 |
| `tests/node/workbook.test.mjs` | 12/12 |
| `tests/node/admin-instrument.test.mjs` | 13/13 (2 new) |
| `tests/node/browser-admin.test.mjs` | 7/7 (1 new, plus the download panel in the accessibility case) |

The full gate on a freshly created database is recorded in `excel-roundtrip-release-gate.txt`.
