"""
Generate business-managed planning files (Excel / SharePoint) for the Caterpillar-dealer platform.

These are the spreadsheets planners own outside the ERP. Their content is derived from the
master and ERP data so it is consistent (safety stocks from real demand history, supplier
exceptions from actual late deliveries), but the raw files are laid out the way people really
keep them: title blocks, merged cells, subtotal formulas, meaning encoded in cell colour,
free-text supplier names, several versions of the same file.

Requires: generate_master_data.py and generate_erp_data.py to have been run first.

Outputs (under 03_Source_Data/business_files/):
    raw/excel/       Safety_Stock_Targets_FY2026_FINAL.xlsx (+ an older v2 still in circulation)
                     Inventory_Policy_Matrix.xlsx
                     Supplier_Exception_List.xlsx
                     Critical_Parts_List.xlsx
    raw/sharepoint/  Forecast_Overrides_export.xlsx   (SharePoint list export)
    golden/          the same content as clean, tidy CSVs
    dq_issue_log.csv answer key of every defect in raw/ (file, sheet, cell)

Usage:
    python generate_business_files.py [--seed 42]
"""

import argparse
import math
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

HERE = Path(__file__).parent
MASTER = HERE / "master_data" / "golden"
ERP = HERE / "erp_data" / "golden"
OUT = HERE / "business_files"

PLANNERS = ["J. Thompson", "M. Patel", "R. Alvarez", "K. Nguyen", "S. Brooks", "D. Carter-Lee"]
EMAIL_DOMAIN = "dealer.example.com"
SERVICE_LEVEL = {"High": 0.97, "Medium": 0.93, "Low": 0.88}
Z = {0.97: 1.88, 0.95: 1.65, 0.93: 1.48, 0.90: 1.28, 0.88: 1.17, 0.85: 1.04}

TITLE = Font(bold=True, size=14)
BOLD = Font(bold=True)
HEADER_FILL = PatternFill("solid", fgColor="FFD966")   # yellow - typical hand-made header
RED = PatternFill("solid", fgColor="FF9999")
AMBER = PatternFill("solid", fgColor="FFE699")
GREEN = PatternFill("solid", fgColor="C6EFCE")
GREY = PatternFill("solid", fgColor="D9D9D9")


class Log:
    def __init__(self):
        self.rows = []

    def add(self, file, sheet, location, column, issue, dim, sev, golden=None, raw=None):
        self.rows.append({"file": file, "sheet": sheet, "location": location, "column": column,
                          "issue_type": issue, "dq_dimension": dim, "severity": sev,
                          "golden_value": golden, "raw_value": raw})


def part_variant(pn, rng):
    return [pn.replace("-", ""), pn.lower(), pn.replace("-", " "), f"{pn} "][int(rng.integers(4))]


def autosize(ws, min_w=8, max_w=45):
    for col in ws.columns:
        letter = get_column_letter(col[0].column)
        width = max((len(str(c.value)) for c in col if c.value is not None), default=0)
        ws.column_dimensions[letter].width = min(max(width + 2, min_w), max_w)


# ---------------------------------------------------------------------------
# Inventory policy matrix
# ---------------------------------------------------------------------------

POLICY_CATEGORIES = ["Filters", "Fluids", "Hardware", "Ground Engaging Tools", "Undercarriage", "Hydraulics",
                     "Engine", "Electrical", "Cooling", "Power Train", "Cab", "Tires"]


def policy_golden():
    rows = []
    for cat in POLICY_CATEGORIES:
        fast = cat in ("Filters", "Fluids", "Hardware", "Ground Engaging Tools")
        big = cat in ("Power Train", "Tires", "Undercarriage")
        for crit, base_sl in SERVICE_LEVEL.items():
            sl = round(min(0.97, base_sl + (0.02 if fast else 0) - (0.03 if big else 0)), 2)
            rows.append({"part_category": cat, "criticality": crit, "service_level_target": sl,
                         "review_cycle_days": 7 if fast else (14 if not big else 30),
                         "min_days_of_supply": 10 if fast else 5 if not big else 0,
                         "max_days_of_supply": 45 if fast else 60 if not big else 90})
    return pd.DataFrame(rows)


def write_policy(gold, path, log, rng):
    f, sh = path.name, "Policy Matrix"
    wb = Workbook()
    ws = wb.active
    ws.title = sh
    ws["A1"] = "Parts Inventory Policy - Service Level & Stocking Rules"
    ws["A1"].font = TITLE
    ws["A2"] = "Owner: Inventory Planning | Rev. 2026-01 | DO NOT CHANGE WITHOUT APPROVAL"
    crits = list(SERVICE_LEVEL)
    metrics = ["Service Level", "Review (days)", "Min DOS", "Max DOS"]
    ws.cell(4, 1, "Part Category").font = BOLD
    for gi, crit in enumerate(crits):
        c0 = 2 + gi * 4
        ws.cell(4, c0, f"{crit} Criticality").font = BOLD
        ws.merge_cells(start_row=4, start_column=c0, end_row=4, end_column=c0 + 3)
        for mi, mname in enumerate(metrics):
            ws.cell(5, c0 + mi, mname).font = BOLD
            ws.cell(5, c0 + mi).fill = HEADER_FILL
    notes_col = 2 + len(crits) * 4
    ws.cell(4, notes_col, "Notes").font = BOLD
    ws.merge_cells(start_row=4, start_column=1, end_row=5, end_column=1)
    log.add(f, sh, "A4:N5", "*", "Pivoted layout with two-row merged header (not tabular)", "Validity", "Medium")

    typos = {"Ground Engaging Tools": "GET", "Undercarriage": "Undercarrage"}
    r = 6
    for cat in POLICY_CATEGORIES:
        label = typos.get(cat, cat)
        ws.cell(r, 1, label)
        if label != cat:
            log.add(f, sh, f"A{r}", "part_category", "Category name not matching master", "Consistency",
                    "Medium", cat, label)
        for gi, crit in enumerate(crits):
            g = gold[(gold.part_category == cat) & (gold.criticality == crit)].iloc[0]
            vals = [g.service_level_target, g.review_cycle_days, g.min_days_of_supply, g.max_days_of_supply]
            for mi, v in enumerate(vals):
                cell = ws.cell(r, 2 + gi * 4 + mi, v)
                if mi == 0:
                    cell.number_format = "0%"
        r += 1

    def mess(row_cat, crit, metric_i, value, issue, dim, sev):
        rr = 6 + POLICY_CATEGORIES.index(row_cat)
        cc = 2 + crits.index(crit) * 4 + metric_i
        cell = ws.cell(rr, cc)
        old = cell.value
        cell.value = value
        log.add(f, sh, cell.coordinate, metrics[metric_i], issue, dim, sev, old, value)

    mess("Hydraulics", "High", 0, "95%", "Percentage stored as text", "Validity", "Medium")
    mess("Cooling", "Medium", 0, 93, "Service level entered as 93 instead of 0.93", "Validity", "High")
    mess("Tires", "Low", 0, "TBD", "Placeholder instead of value", "Completeness", "High")
    mess("Cab", "Medium", 1, "2 wks", "Review cycle as free text", "Validity", "Medium")
    mess("Electrical", "Low", 3, None, "Missing max days of supply", "Completeness", "Medium")
    mess("Engine", "High", 2, 60, "Min DOS greater than Max DOS", "Validity", "High")
    ws.cell(6 + POLICY_CATEGORIES.index("Tires"), notes_col, "Allocation from Bridgestone - see Mike before changing")
    ws.cell(6 + POLICY_CATEGORIES.index("Fluids"), notes_col, "Drums (55 gal) only at Full Service branches")
    r += 1
    ws.cell(r, 1, "* Mining categories follow High criticality regardless of part category (per VP Parts, 2025)")
    log.add(f, sh, f"A{r}", "*", "Business rule held only as a footnote", "Completeness", "Medium")
    autosize(ws)
    wb.save(path)


# ---------------------------------------------------------------------------
# Safety stock targets
# ---------------------------------------------------------------------------

def safety_stock_golden(master, policy, rng):
    dm = pd.read_csv(ERP / "demand_transactions.csv", parse_dates=["demand_date"])
    parts = master["part"].set_index("part_id")
    sup = master["supplier"].set_index("supplier_id")
    hist = dm[dm.demand_date >= "2025-10-01"]
    weekly = (hist.groupby(["branch_id", "part_id", pd.Grouper(key="demand_date", freq="W")])
              .qty_demanded.sum())
    weeks = hist.demand_date.dt.to_period("W").nunique()
    stats = weekly.groupby(["branch_id", "part_id"]).agg(["sum", "count"]).rename(
        columns={"sum": "total", "count": "active_weeks"})
    sq = (weekly ** 2).groupby(["branch_id", "part_id"]).sum()
    stats["mean_w"] = stats.total / weeks
    stats["sd_w"] = np.sqrt(np.maximum(sq / weeks - stats.mean_w ** 2, 0))
    stats = stats.reset_index().join(parts[["part_number", "part_category", "criticality", "unit_cost_usd",
                                            "primary_supplier_id"]], on="part_id")
    stats["annual_value"] = stats.total * stats.unit_cost_usd
    stats = stats[stats.active_weeks >= 3].nlargest(1500, "annual_value")

    pol = policy.set_index(["part_category", "criticality"])
    out = []
    for s in stats.itertuples():
        p = pol.loc[(s.part_category, s.criticality)]
        z = Z.get(p.service_level_target, 1.5)
        lt_w = max(sup.at[s.primary_supplier_id, "lead_time_days"], 1) / 7
        review_w = p.review_cycle_days / 7
        ss = max(1, math.ceil(z * s.sd_w * math.sqrt(lt_w + review_w)))
        rop = math.ceil(s.mean_w * lt_w + ss)
        mx = max(rop + 1, math.ceil(rop + s.mean_w * review_w * 2))
        out.append({"branch_id": s.branch_id, "part_id": s.part_id, "part_number": s.part_number,
                    "safety_stock_qty": ss, "reorder_point_qty": rop, "max_qty": mx,
                    "service_level_target": p.service_level_target, "effective_date": "2026-01-01",
                    "approved_by": PLANNERS[int(rng.integers(len(PLANNERS)))]})
    return pd.DataFrame(out).sort_values(["branch_id", "part_number"]).reset_index(drop=True)


def write_safety_stock(gold, branches, path, log, rng, older=False):
    f = path.name
    wb = Workbook()
    wb.remove(wb.active)
    bname = branches.set_index("branch_id").branch_name
    bregion = branches.set_index("branch_id").region
    g = gold.assign(branch_name=gold.branch_id.map(bname), region=gold.branch_id.map(bregion))
    headers = ["Branch", "Part #", "SS Qty", "ROP", "Max", "Old SS (FY25)", "Approved", "Comments"]

    for region in ["East", "North", "Central", "Southwest"]:
        sh = f"{region} Region"
        ws = wb.create_sheet(sh)
        ws["A1"] = f"Safety Stock Targets FY2026 - {region} Region" + (" (DRAFT v2)" if older else "")
        ws["A1"].font = TITLE
        ws["A2"] = "Last updated 3/14/2026 by Inventory Planning" if not older else "Updated 11/20/2025"
        for ci, h in enumerate(headers, start=1):
            ws.cell(4, ci, h).font = BOLD
            ws.cell(4, ci).fill = HEADER_FILL
        ws.column_dimensions["F"].hidden = True
        r = 5
        for b_id, grp in g[g.region == region].groupby("branch_id", sort=True):
            first = r
            for row in grp.itertuples():
                ss, rop, mx, pn = row.safety_stock_qty, row.reorder_point_qty, row.max_qty, row.part_number
                if older:  # stale draft: values from before the FY26 review
                    ss, rop, mx = (max(1, round(v * rng.uniform(0.7, 1.15))) for v in (ss, rop, mx))
                ws.cell(r, 1, row.branch_name)
                ws.cell(r, 2, pn)
                ws.cell(r, 3, ss)
                ws.cell(r, 4, rop)
                ws.cell(r, 5, mx)
                ws.cell(r, 6, max(1, round(ss * rng.uniform(0.6, 1.3))))
                ws.cell(r, 7, row.approved_by)
                if not older:
                    u = rng.random()
                    loc = lambda col: f"{get_column_letter(col)}{r}"
                    key = f"{row.branch_id}|{row.part_id}"
                    if u < 0.02:
                        v = part_variant(pn, rng)
                        ws.cell(r, 2, v)
                        log.add(f, sh, loc(2), "part_number", "Part number format not standardized", "Validity",
                                "Medium", pn, v)
                    elif u < 0.03:
                        v = ["TBD", "see Jim", "?"][int(rng.integers(3))]
                        ws.cell(r, 3, v)
                        log.add(f, sh, loc(3), "safety_stock_qty", "Text in quantity cell", "Validity", "High", ss, v)
                    elif u < 0.04:
                        ws.cell(r, 3, None)
                        log.add(f, sh, loc(3), "safety_stock_qty", "Missing safety stock", "Completeness", "High", ss)
                    elif u < 0.05:
                        ws.cell(r, 3, rop + 5)
                        log.add(f, sh, loc(3), "safety_stock_qty", "Safety stock greater than reorder point",
                                "Validity", "Medium", ss, rop + 5)
                    elif u < 0.055:
                        ws.cell(r, 5, max(0, rop - 3))
                        log.add(f, sh, loc(5), "max_qty", "Max below reorder point", "Validity", "Medium", mx, rop - 3)
                    elif u < 0.065:
                        ws.cell(r, 8, ["per branch mgr", "customer project - Q2", "keep until mine reopens",
                                       "temp increase"][int(rng.integers(4))])
                        ws.cell(r, 3).fill = AMBER
                        log.add(f, sh, loc(3), "safety_stock_qty", "Manual override flagged only by cell colour",
                                "Consistency", "Low", ss, ss)
                    elif u < 0.075:  # same part entered twice with different numbers
                        r += 1
                        ws.cell(r, 1, row.branch_name)
                        ws.cell(r, 2, pn)
                        ws.cell(r, 3, ss + int(rng.integers(1, 6)))
                        ws.cell(r, 4, rop)
                        ws.cell(r, 5, mx)
                        log.add(f, sh, f"A{r}", "*", "Duplicate part row with conflicting quantity", "Uniqueness",
                                "High", key, ws.cell(r, 3).value)
                r += 1
            # merge branch name vertically (classic hand-built report) + subtotal formula row
            if r - 1 > first:
                ws.merge_cells(start_row=first, start_column=1, end_row=r - 1, end_column=1)
                ws.cell(first, 1).alignment = Alignment(vertical="top")
            ws.cell(r, 1, f"Total {bname[b_id]}").font = BOLD
            ws.cell(r, 3, f"=SUM(C{first}:C{r - 1})").font = BOLD
            for ci in range(1, 9):
                ws.cell(r, ci).fill = GREY
            r += 2  # blank spacer row
        if not older:
            log.add(f, sh, "A:A", "branch", "Branch merged vertically; name only in first row of each group",
                    "Completeness", "Medium")
            log.add(f, sh, "*", "*", "Subtotal formula rows and blank rows mixed into data", "Validity", "Medium")
            log.add(f, sh, "*", "branch", "Branch name used instead of branch ID", "Consistency", "Low")
            # superseded / unknown part numbers someone added by hand
            for _ in range(3):
                pn = f"{int(rng.integers(100, 599))}-{int(rng.integers(0, 9999)):04d}"
                ws.cell(r, 1, "Misc")
                ws.cell(r, 2, pn)
                ws.cell(r, 3, int(rng.integers(1, 10)))
                log.add(f, sh, f"B{r}", "part_number", "Part number not in master", "Integrity", "High", None, pn)
                r += 1
        autosize(ws)
    if older:
        log.add(f, "*", "*", "*", "Outdated version of file still in circulation (conflicts with FINAL)",
                "Consistency", "High")
    wb.save(path)


# ---------------------------------------------------------------------------
# Supplier exceptions
# ---------------------------------------------------------------------------

def supplier_exceptions_golden(master, rng):
    po = pd.read_csv(ERP / "purchase_orders.csv", parse_dates=["po_date", "promised_date", "last_receipt_date"])
    po = po[po.line_status == "Closed"]
    po["on_time"] = po.last_receipt_date <= po.promised_date
    po["quarter"] = po.po_date.dt.to_period("Q")
    q = po.groupby(["supplier_id", "quarter"]).agg(lines=("on_time", "size"), otd=("on_time", "mean")).reset_index()
    q = q[(q.lines >= 20) & (q.otd < 0.75)]
    sup = master["supplier"].set_index("supplier_id")
    parts = master["part"]
    cats = parts.groupby("primary_supplier_id").part_category.agg(lambda s: s.value_counts().index[0])

    rows = []
    for sid, grp in q.groupby("supplier_id"):
        # collapse consecutive bad quarters into one exception
        periods = sorted(grp.quarter)
        start = prev = periods[0]
        spans = []
        for p in periods[1:]:
            if p != prev + 1:
                spans.append((start, prev))
                start = p
            prev = p
        spans.append((start, prev))
        for a, b in spans:
            otd = grp[(grp.quarter >= a) & (grp.quarter <= b)].otd.mean()
            closed = b < pd.Period("2026Q2", "Q")
            rows.append({
                "supplier_id": sid, "supplier_name": sup.at[sid, "supplier_name"],
                "issue": f"On-time delivery {otd:.0%} - late shipments on {cats.get(sid, 'mixed')} parts",
                "impacted_category": cats.get(sid, "Mixed"),
                "start_date": a.start_time.date().isoformat(),
                "expected_resolution": (b.end_time.date() + timedelta(days=1)).isoformat(),
                "impact": "High" if otd < 0.6 else "Medium",
                "status": "Closed" if closed else "Open",
                "owner": PLANNERS[int(rng.integers(len(PLANNERS)))],
            })
    # Known events that do not show up as averages
    def add(sid, issue, cat, start, end, impact, status):
        rows.append({"supplier_id": sid, "supplier_name": sup.at[sid, "supplier_name"], "issue": issue,
                     "impacted_category": cat, "start_date": start, "expected_resolution": end, "impact": impact,
                     "status": status, "owner": PLANNERS[int(rng.integers(len(PLANNERS)))]})
    by_name = {n: i for i, n in sup.supplier_name.items()}
    for name, issue, cat, s, e, imp, st in [
        ("Berco of America", "Undercarriage capacity constraint - allocations on track groups", "Undercarriage",
         "2025-03-01", "2025-09-15", "High", "Closed"),
        ("ITR America", "Undercarriage backlog - substitute for Berco allocation", "Undercarriage",
         "2025-04-01", "2025-09-30", "Medium", "Closed"),
        ("Bridgestone OTR", "Allocation on large OTR tires (29.5R25)", "Tires", "2024-06-01", "2026-12-31",
         "High", "Open"),
        ("Perkins Engines", "Ocean freight delays - UK origin engine components", "Engine", "2026-05-01",
         "2026-11-30", "Medium", "Open"),
        ("Caterpillar Inc. - Parts Distribution Center Atlanta", "Hurricane-season surge on generator parts",
         "Electrical", "2025-08-15", "2025-10-31", "Medium", "Closed"),
    ]:
        if name in by_name:
            add(by_name[name], issue, cat, s, e, imp, st)
    df = pd.DataFrame(rows).sort_values("start_date").reset_index(drop=True)
    df.insert(0, "exception_id", [f"SX{i:04d}" for i in range(1, len(df) + 1)])
    return df


def write_supplier_exceptions(gold, master, path, log, rng):
    f, sh = path.name, "Exceptions"
    raw_sup = pd.read_csv(HERE / "master_data" / "raw" / "supplier_master.csv")
    aliases = raw_sup.groupby(raw_sup.supplier_id.str[-2:]).supplier_name.apply(list)  # S0xx and S1xx dup share tail
    wb = Workbook()
    ws = wb.active
    ws.title = sh
    ws["A1"] = "SUPPLIER EXCEPTION LIST"
    ws["A1"].font = TITLE
    ws["A2"] = "Red = escalated to VP, Yellow = monitoring, Green = resolved.  Please keep sorted!!"
    log.add(f, sh, "A2", "status", "Status meaning encoded only in fill colour legend", "Consistency", "Medium")
    headers = ["#", "Supplier", "Issue / Description", "Parts Affected", "Started", "Fix ETA", "Impact", "Owner",
               "Status", "Last Update / Notes"]
    for ci, h in enumerate(headers, start=1):
        ws.cell(3, ci, h).font = BOLD
        ws.cell(3, ci).fill = HEADER_FILL
    log.add(f, sh, "A3:J3", "*", "Supplier identified by free-text name, no supplier ID column", "Integrity", "High")

    def fuzzy_date(iso):
        d = date.fromisoformat(iso)
        return [d.strftime("%m/%d/%Y"), f"Q{(d.month - 1) // 3 + 1} {d.year}", d.strftime("%b %Y"),
                d.strftime("%m/%d/%y"), datetime(d.year, d.month, d.day)][int(rng.integers(5))]

    r = 4
    for g in gold.itertuples():
        names = aliases.get(g.supplier_id[-2:], [g.supplier_name])
        name = names[int(rng.integers(len(names)))] if rng.random() < 0.5 else g.supplier_name
        if name != g.supplier_name:
            log.add(f, sh, f"B{r}", "supplier_name", "Supplier name variant", "Consistency", "Medium",
                    g.supplier_name, name)
        started, eta = fuzzy_date(g.start_date), fuzzy_date(g.expected_resolution)
        if g.status == "Open" and rng.random() < 0.4:
            eta = ["TBD", "ASAP", "waiting on supplier", None][int(rng.integers(4))]
            log.add(f, sh, f"F{r}", "expected_resolution", "Non-date resolution ETA", "Validity", "Medium",
                    g.expected_resolution, eta)
        status = {"Closed": ["Closed", "closed", "Resolved", "DONE"], "Open": ["Open", "open", "In progress", "Open?"]}
        st = status[g.status][int(rng.integers(4))]
        if st not in ("Closed", "Open"):
            log.add(f, sh, f"I{r}", "status", "Status value not standardized", "Consistency", "Low", g.status, st)
        vals = [r - 3, name, g.issue, g.impacted_category, started, eta, g.impact, g.owner, st,
                f"{g.owner.split()[-1]}: followed up {fuzzy_date(g.start_date)}\nstill waiting on confirmation"]
        for ci, v in enumerate(vals, start=1):
            ws.cell(r, ci, v)
        ws.cell(r, 10).alignment = Alignment(wrap_text=True)
        fill = GREEN if g.status == "Closed" else (RED if g.impact == "High" else AMBER)
        for ci in range(1, len(headers) + 1):
            ws.cell(r, ci).fill = fill
        if isinstance(started, str) and not started[:2].isdigit():
            log.add(f, sh, f"E{r}", "start_date", "Start date as quarter/month text", "Validity", "Low",
                    g.start_date, started)
        r += 1
    # Row covering two suppliers at once, and a re-entered exception
    ws.cell(r, 1, r - 3)
    ws.cell(r, 2, "Berco / ITR")
    ws.cell(r, 3, "Undercarriage - see rows above, combined for VP review")
    ws.cell(r, 9, "Open")
    log.add(f, sh, f"B{r}", "supplier_name", "Multiple suppliers in one cell", "Validity", "High", None, "Berco / ITR")
    log.add(f, sh, f"I{r}", "status", "Combined row still Open while source rows are Closed", "Consistency",
            "Medium", "Closed", "Open")
    ws.cell(r, 2).comment = Comment("Should we split this? -KN", "K. Nguyen")
    autosize(ws)
    ws.column_dimensions["J"].width = 40
    wb.save(path)


# ---------------------------------------------------------------------------
# Critical parts list
# ---------------------------------------------------------------------------

def critical_parts_golden(master, rng):
    dm = pd.read_csv(ERP / "demand_transactions.csv")
    parts = master["part"].set_index("part_id")
    fam = master["family"].set_index("product_family_id").product_family_name
    prod = master["product"].set_index("product_id")
    lost = (dm.assign(short=dm.qty_lost_sale + dm.qty_backordered).groupby("part_id")
            .agg(short=("short", "sum"), branches=("branch_id", "nunique")))
    cand = lost.join(parts[["part_number", "part_description", "criticality", "primary_product_id"]])
    cand["family"] = cand.primary_product_id.map(prod.product_family_id).map(fam)
    cand = cand[(cand.criticality == "High") & (cand.short > 0)]
    pick = pd.concat([cand.nlargest(110, "short"),
                      cand[cand.family.isin(["Mining", "Underground Mining"])].nlargest(30, "short")]).drop_duplicates()
    reasons = {"Mining": "Down-machine risk at mine sites - 24hr availability required",
               "Underground Mining": "Down-machine risk at mine sites - 24hr availability required",
               "Power Systems": "Standby power for hospitals / data centers - emergency coverage"}
    rows = []
    for pid, p in pick.iterrows():
        branch_scope = "ALL" if p.branches >= 6 else "Southwest" if p.family in reasons and "Mining" in p.family else "ALL"
        rows.append({"part_id": pid, "part_number": p.part_number, "part_description": p.part_description,
                     "equipment_model": prod.at[p.primary_product_id, "product_name"],
                     "scope": branch_scope,
                     "priority": "P1" if p.short > pick.short.quantile(0.7) or p.family in reasons else "P2",
                     "reason": reasons.get(p.family, f"Repeated stockouts ({int(p.short)} units short since 2023)"),
                     "added_by": PLANNERS[int(rng.integers(len(PLANNERS)))],
                     "added_date": (date(2024, 1, 15) + timedelta(days=int(rng.integers(0, 800)))).isoformat()})
    return pd.DataFrame(rows).sort_values(["priority", "part_number"]).reset_index(drop=True)


def write_critical_parts(gold, path, log, rng):
    f, sh = path.name, "Critical Parts"
    wb = Workbook()
    ws = wb.active
    ws.title = sh
    ws["A1"] = "CRITICAL PARTS - DO NOT LET STOCK OUT"
    ws["A1"].font = TITLE
    ws["A2"] = "Red highlight = P1 (call branch mgr before transfer).  Questions -> Service Ops"
    headers = ["Part Number(s)", "Description", "Machine(s)", "Branches", "Why critical", "Added by", "Date added"]
    for ci, h in enumerate(headers, start=1):
        ws.cell(3, ci, h).font = BOLD
        ws.cell(3, ci).fill = HEADER_FILL
    log.add(f, sh, "*", "priority", "Priority stored only as red cell fill, no priority column", "Completeness", "High")
    r = 4
    for g in gold.itertuples():
        pn, desc, model = g.part_number, g.part_description, g.equipment_model
        u = rng.random()
        if u < 0.06:
            pn = part_variant(pn, rng)
            log.add(f, sh, f"A{r}", "part_number", "Part number format not standardized", "Validity", "Medium",
                    g.part_number, pn)
        elif u < 0.1:
            other = gold.part_number.iat[int(rng.integers(len(gold)))]
            pn = f"{g.part_number} / {other}"
            log.add(f, sh, f"A{r}", "part_number", "Multiple part numbers in one cell", "Validity", "High",
                    g.part_number, pn)
        if rng.random() < 0.15:
            desc = desc.title().replace("Filter", "Fltr").replace("Assembly", "Assy")
            log.add(f, sh, f"B{r}", "part_description", "Description differs from part master", "Consistency",
                    "Low", g.part_description, desc)
        if rng.random() < 0.2:
            model = f"{model}, {model.replace('CAT ', '')}B, others"
            log.add(f, sh, f"C{r}", "equipment_model", "Free-text list of machines", "Validity", "Low",
                    g.equipment_model, model)
        scope = {"ALL": ["ALL", "All", "all branches", ""], "Southwest": ["SW only", "Abingdon/Grundy/Bluefield",
                                                                          "Southwest"]}[g.scope]
        scope = scope[int(rng.integers(len(scope)))]
        if scope not in ("ALL", "Southwest"):
            log.add(f, sh, f"D{r}", "scope", "Branch scope as free text / blank", "Consistency", "Medium",
                    g.scope, scope)
        added = date.fromisoformat(g.added_date)
        added_v = added.strftime(["%m/%d/%Y", "%Y-%m-%d", "%b-%y"][int(rng.integers(3))])
        vals = [pn, desc, model, scope, g.reason, g.added_by, added_v]
        for ci, v in enumerate(vals, start=1):
            ws.cell(r, ci, v)
        if g.priority == "P1":
            for ci in range(1, 8):
                ws.cell(r, ci).fill = RED
        if rng.random() < 0.04:  # same part added again by someone else later
            r += 1
            for ci, v in enumerate([g.part_number, desc, model, "ALL", "per service mgr request",
                                    PLANNERS[int(rng.integers(len(PLANNERS)))], "2026-06-02"], start=1):
                ws.cell(r, ci, v)
            log.add(f, sh, f"A{r}", "*", "Part listed twice", "Uniqueness", "Medium", g.part_number, g.part_number)
        r += 1
    r += 1
    ws.cell(r, 1, "--- parts below removed from program, keep for history ---").font = Font(italic=True)
    log.add(f, sh, f"A{r}", "*", "Retired items kept in same table below a text separator", "Validity", "Medium")
    for _ in range(5):
        r += 1
        ws.cell(r, 1, f"{int(rng.integers(100, 599))}-{int(rng.integers(0, 9999)):04d}")
        ws.cell(r, 2, "SUPERSEDED")
        ws.cell(r, 1).font = Font(strike=True)
    autosize(ws)
    wb.save(path)


# ---------------------------------------------------------------------------
# SharePoint forecast overrides
# ---------------------------------------------------------------------------

def overrides_golden(master, rng):
    branches = master["branch"]
    rows = []

    def add(branch, level, value, month, pct, reason, status="Approved"):
        who = PLANNERS[int(rng.integers(len(PLANNERS)))]
        sub = date.fromisoformat(month) - timedelta(days=int(rng.integers(10, 45)))
        rows.append({"branch_id": branch, "scope_level": level, "scope_value": value, "forecast_month": month,
                     "adjustment_pct": pct, "reason": reason, "submitted_by": who,
                     "submitted_date": sub.isoformat(), "approval_status": status,
                     "approved_by": PLANNERS[(PLANNERS.index(who) + 1) % len(PLANNERS)] if status == "Approved" else ""})

    east = branches[branches.region == "East"].branch_id.tolist()
    sw = branches[branches.region == "Southwest"].branch_id.tolist()
    for y in (2024, 2025, 2026):
        for m in (8, 9, 10):
            for b in east:
                add(b, "Product Family", "Power Systems", f"{y}-{m:02d}-01", 40, "Hurricane season - generator demand")
        for m in (4, 5, 6):
            for b in branches.branch_id.sample(8, random_state=int(rng.integers(1e6))):
                add(b, "Product Family", "Earthmoving", f"{y}-{m:02d}-01", 15, "Spring construction ramp")
    for m in range(1, 13):
        for b in sw:
            add(b, "Product Family", "Mining", f"2025-{m:02d}-01", -20, "Met coal slowdown - customer idling")
    for b in branches.branch_id:
        add(b, "Part Category", "Undercarriage", "2025-02-01", 25, "Pre-buy ahead of undercarriage allocation")
    for m in (3, 4, 5, 6, 7, 8):
        add("B004", "Product Category", "Pipelayers", f"2026-{m:02d}-01", 60, "Pipeline project - large customer job")
    for _ in range(25):
        b = branches.branch_id.iat[int(rng.integers(len(branches)))]
        m = int(rng.integers(1, 13))
        add(b, "Part Category", ["Filters", "Hydraulics", "Ground Engaging Tools", "Tires"][int(rng.integers(4))],
            f"2026-{m:02d}-01", int(rng.choice([-15, -10, 10, 20])), "Branch manager input",
            ["Approved", "Rejected", "Pending"][int(rng.integers(3))])
    df = pd.DataFrame(rows).reset_index(drop=True)
    df.insert(0, "override_id", range(1, len(df) + 1))
    return df


def write_overrides(gold, branches, path, log, rng):
    f, sh = path.name, "Forecast Overrides"
    bname = branches.set_index("branch_id").branch_name
    bnum = {b: int(b[1:]) for b in branches.branch_id}
    status_code = {"Approved": 0, "Rejected": 1, "Pending": 2}
    rows = []
    for g in gold.itertuples():
        m = date.fromisoformat(g.forecast_month)
        month = [m.strftime("%b %Y"), m.strftime("%Y-%m"), m.strftime("%m/%d/%Y"), m.strftime("%B")][int(rng.integers(4))]
        adj = [f"{g.adjustment_pct:+d}%", g.adjustment_pct, g.adjustment_pct / 100][int(rng.integers(3))]
        created = datetime.combine(date.fromisoformat(g.submitted_date), datetime.min.time()) + \
            timedelta(hours=int(rng.integers(13, 23)), minutes=int(rng.integers(60)))
        user = g.submitted_by.replace(". ", "").replace("-", "").lower()
        rows.append({
            "ID": g.override_id,
            "Title": f"{g.scope_value} {g.adjustment_pct:+d}%",
            "Branch": f"{bname[g.branch_id]};#{bnum[g.branch_id]}",
            "Scope Type": g.scope_level, "Scope": g.scope_value, "Forecast Month": month,
            "Adjustment": adj, "Reason": g.reason,
            "Approval Status": status_code[g.approval_status] if rng.random() < 0.5 else g.approval_status,
            "Approver": g.approved_by,
            "Created": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "Created By": f"i:0#.f|membership|{user}@{EMAIL_DOMAIN}",
            "Modified": (created + timedelta(days=int(rng.integers(0, 5)))).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "Item Type": "Item", "Path": "sites/PartsPlanning/Lists/ForecastOverrides",
        })
    df = pd.DataFrame(rows)
    log.add(f, sh, "C:C", "branch_id", "SharePoint lookup format 'Name;#ID' (ID is list item, not branch ID)",
            "Integrity", "High")
    log.add(f, sh, "F:F", "forecast_month", "Month in mixed formats; some missing the year", "Validity", "High")
    log.add(f, sh, "G:G", "adjustment_pct", "Adjustment mixes '+15%', 15 and 0.15", "Validity", "High")
    log.add(f, sh, "I:I", "approval_status", "Approval status mixes codes (0/1/2) and text", "Consistency", "Medium")
    log.add(f, sh, "L:L", "submitted_by", "User stored as SharePoint claims string", "Consistency", "Low")
    log.add(f, sh, "K:K", "submitted_date", "Created timestamp in UTC, other dates local", "Consistency", "Low")

    def row_ref(i):
        return f"row {i + 2}"

    # Resubmitted duplicates and conflicting overrides for the same scope + month
    dup_idx = rng.choice(len(df), size=12, replace=False)
    dups = df.loc[dup_idx].copy()
    dups["ID"] = range(df.ID.max() + 1, df.ID.max() + 1 + len(dups))
    conflict = dups.index[:5]
    dups.loc[conflict, "Adjustment"] = [f"{int(v):+d}%" for v in rng.choice([-10, 5, 30, 50], size=len(conflict))]
    df = pd.concat([df, dups], ignore_index=True)
    for i, (orig, is_conf) in enumerate(zip(dup_idx, [True] * 5 + [False] * 7)):
        log.add(f, sh, row_ref(len(df) - len(dups) + i), "*",
                "Conflicting override for same branch/scope/month" if is_conf else "Duplicate resubmitted override",
                "Uniqueness", "High", int(gold.override_id.iat[orig]), None)
    # Typos
    for i in rng.choice(len(gold), size=4, replace=False):
        v = gold.adjustment_pct.iat[i] * 10
        df.at[i, "Adjustment"] = v
        log.add(f, sh, row_ref(i), "adjustment_pct", "Adjustment 10x too large (typo)", "Validity", "High",
                int(gold.adjustment_pct.iat[i]), int(v))
    for i in rng.choice(len(gold), size=3, replace=False):
        df.at[i, "Branch"] = None
        log.add(f, sh, row_ref(i), "branch_id", "Missing branch", "Completeness", "High", gold.branch_id.iat[i])

    with pd.ExcelWriter(path, engine="openpyxl") as xw:
        df.to_excel(xw, sheet_name=sh, index=False)
        autosize(xw.sheets[sh])


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)

    if not (ERP / "demand_transactions.csv").exists():
        raise SystemExit("ERP data missing - run generate_master_data.py then generate_erp_data.py first")
    master = {k: pd.read_csv(MASTER / f"{v}.csv") for k, v in
              {"part": "part_master", "supplier": "supplier_master", "branch": "branch_master",
               "product": "product_master", "family": "product_family_master"}.items()}

    for d in ("raw/excel", "raw/sharepoint", "golden"):
        (OUT / d).mkdir(parents=True, exist_ok=True)
    log = Log()

    policy = policy_golden()
    write_policy(policy, OUT / "raw/excel/Inventory_Policy_Matrix.xlsx", log, rng)

    ss = safety_stock_golden(master, policy, rng)
    write_safety_stock(ss, master["branch"], OUT / "raw/excel/Safety_Stock_Targets_FY2026_FINAL.xlsx", log, rng)
    write_safety_stock(ss, master["branch"], OUT / "raw/excel/Safety_Stock_Targets_FY2026_v2.xlsx", log, rng,
                       older=True)

    sx = supplier_exceptions_golden(master, rng)
    write_supplier_exceptions(sx, master, OUT / "raw/excel/Supplier_Exception_List.xlsx", log, rng)

    cp = critical_parts_golden(master, rng)
    write_critical_parts(cp, OUT / "raw/excel/Critical_Parts_List.xlsx", log, rng)

    fo = overrides_golden(master, rng)
    write_overrides(fo, master["branch"], OUT / "raw/sharepoint/Forecast_Overrides_export.xlsx", log, rng)

    golden = {"inventory_policy": policy, "safety_stock_targets": ss, "supplier_exceptions": sx,
              "critical_parts": cp, "forecast_overrides": fo}
    for name, df in golden.items():
        df.to_csv(OUT / "golden" / f"{name}.csv", index=False)
    logdf = pd.DataFrame(log.rows)
    logdf.to_csv(OUT / "dq_issue_log.csv", index=False)

    print(f"{'dataset':<24}{'golden rows':>12}")
    for name, df in golden.items():
        print(f"{name:<24}{len(df):>12,}")
    print(f"\nLogged issues by file:\n{logdf.groupby('file').size().to_string()}")
    print(f"\nTotal: {len(logdf):,}  ->  {OUT}")


if __name__ == "__main__":
    main()
