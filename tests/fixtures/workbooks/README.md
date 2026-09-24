# Workbook fixtures

Workbooks written by real spreadsheet software, so `tests/node/workbook.test.mjs` proves the
reader against files this project did not write itself. `config/ICFWalk_Instrument_Configuration_Aligned.xlsx`
is the third such file.

| File | How it was made |
| --- | --- |
| `libreoffice-resaved.xlsx` | The workbook `writeWorkbook` produces for `config/instrument-config.json`, opened in LibreOffice Calc 24.2.7.2 and saved as "Calc Office Open XML" with no change (`soffice --headless --convert-to xlsx:"Calc Office Open XML"`). |
| `libreoffice-edited.xlsx` | The same workbook opened in LibreOffice Calc 24.2.7.2 and edited through its own API by `libreoffice-edit.py`, then saved as .xlsx. |

The edits in `libreoffice-edited.xlsx`, which the test asserts one by one:

- `item_definition`, item `prek_k_q1`: prompt set to "Students can describe today's learning goal." and review_status to "Reviewed" (a placeholder resolved);
- item `prek_k_q2`: display_order typed as `15`;
- item `prek_k_q3`: required typed as `TRUE`;
- `dimension_value`, `abbott_middle_school`: label entered as the number 2024 in a text column;
- `response_option`: a new row, `opt_yes_no_maybe` / "Maybe", added below the others.

Both files were produced from the current `config/instrument-config.json`. If that document ever
changes, regenerate them: write the workbook with `writeWorkbook` (exportedFrom versionId "V",
versionLabel "L", status "PUBLISHED", checksum "c", instrumentCode "ICFWALK", exportedAt
"2026-09-24T00:00:00Z"), then re-save and re-edit it with LibreOffice as above
(`python3 libreoffice-edit.py <in.xlsx> <out.xlsx>` needs LibreOffice Calc and its Python bridge).
