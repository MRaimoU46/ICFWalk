"""Opens an ICFWalk workbook in LibreOffice Calc, makes the edits an administrator would, saves .xlsx."""
import subprocess, sys, time, uno
from com.sun.star.beans import PropertyValue

src, dst = sys.argv[1], sys.argv[2]
def prop(n, v):
    p = PropertyValue(); p.Name = n; p.Value = v; return p

office = subprocess.Popen(["soffice", "--headless", "--norestore", "--nologo", "--nodefault",
                           "--accept=socket,host=127.0.0.1,port=2002;urp;"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
    ctx = None
    for _ in range(120):
        try:
            ctx = resolver.resolve("uno:socket,host=127.0.0.1,port=2002;urp;StarOffice.ComponentContext"); break
        except Exception:
            time.sleep(0.5)
    desktop = ctx.ServiceManager.createInstanceWithContext("com.sun.star.frame.Desktop", ctx)
    doc = desktop.loadComponentFromURL(uno.systemPathToFileUrl(src), "_blank", 0, (prop("Hidden", True),))
    sheets = doc.Sheets

    def columns(sheet):
        out = {}
        for c in range(0, 40):
            name = sheet.getCellByPosition(c, 2).getString()
            if name: out[name] = c
        return out

    def row_of(sheet, col, value):
        r = 3
        while sheet.getCellByPosition(0, r).getString() != "":
            if sheet.getCellByPosition(col, r).getString() == value: return r
            r += 1
        raise SystemExit(f"no row with {value}")

    def last_row(sheet):
        r = 3
        while sheet.getCellByPosition(0, r).getString() != "": r += 1
        return r  # first empty row

    items = sheets.getByName("item_definition"); ic = columns(items)
    r1 = row_of(items, ic["item_key"], "prek_k_q1")
    items.getCellByPosition(ic["prompt"], r1).setString("Students can describe today's learning goal.")
    items.getCellByPosition(ic["review_status"], r1).setString("Reviewed")
    r2 = row_of(items, ic["item_key"], "prek_k_q2")
    items.getCellByPosition(ic["display_order"], r2).setFormula("15")
    r3 = row_of(items, ic["item_key"], "prek_k_q3")
    items.getCellByPosition(ic["required"], r3).setFormula("TRUE")

    values = sheets.getByName("dimension_value"); vc = columns(values)
    rv = row_of(values, vc["value_code"], "abbott_middle_school")
    values.getCellByPosition(vc["label"], rv).setValue(2024)

    options = sheets.getByName("response_option"); oc = columns(options)
    rn = last_row(options)
    new = {"option_id": "opt_yes_no_maybe", "response_set_id": "rs_yes_no", "option_key": "maybe", "stored_code": "maybe",
           "label": "Maybe", "source_location": "added in LibreOffice", "review_status": "Reviewed"}
    for k, v in new.items(): options.getCellByPosition(oc[k], rn).setString(v)
    options.getCellByPosition(oc["display_order"], rn).setValue(30)
    options.getCellByPosition(oc["is_na"], rn).setFormula("FALSE")
    options.getCellByPosition(oc["active"], rn).setFormula("TRUE")

    doc.storeToURL(uno.systemPathToFileUrl(dst), (prop("FilterName", "Calc Office Open XML"),))
    doc.close(True)
    print("saved", dst)
finally:
    try:
        desktop.terminate()
    except Exception:
        pass
    time.sleep(1)
    office.kill()
