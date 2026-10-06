"""
Build the clean layer and measure how accurate it is.

Steps:
  1. Deploy the procedures in 04_Database/clean (in file order)
  2. Run them: raw -> clean (typed, standardized, de-duplicated, crosswalked), unrepairable records -> clean.quarantine
  3. Score: compare every cell of the clean tables with the golden files the generators wrote, and do the
     same for the raw tables - the before/after accuracy shows what cleaning achieved. The golden files are
     a test fixture; the pipeline never reads them.

Usage:
    python 04_Database/run_clean.py
"""

import re
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from load_raw import SRC, connect  # noqa: E402

CLEAN_DIR = Path(__file__).parent / "clean"
PROCEDURES = ["clean.usp_build_master", "clean.usp_build_erp", "clean.usp_build_business", "clean.usp_build_external"]
GOLDEN = {"master": "master_data", "erp": "erp_data", "business": "business_files"}

# golden file -> (key column(s), clean table, raw table, {golden column: clean column})
SCORED = {
    "branch_master": ("branch_id", "clean.branch", "raw.master_branch_master",
                      {"branch_name": "branch_name", "region": "region", "state": "state_code",
                       "branch_type": "branch_type", "open_date": "open_date", "is_active": "is_active"}),
    "product_family_master": ("product_family_id", "clean.product_family", "raw.master_product_family_master",
                              {"product_family_name": "product_family_name", "product_family_code": "product_family_code",
                               "business_segment": "business_segment", "planning_owner": "planning_owner",
                               "is_active": "is_active"}),
    "product_category_master": ("product_category_id", "clean.product_category", "raw.master_product_category_master",
                                {"product_category_name": "product_category_name", "product_family_id": "product_family_id"}),
    "product_master": ("product_id", "clean.product", "raw.master_product_master",
                       {"product_name": "product_name", "product_category_id": "product_category_id",
                        "product_family_id": "product_family_id", "criticality": "criticality",
                        "lifecycle_status": "lifecycle_status"}),
    "supplier_master": ("supplier_id", "clean.supplier", "raw.master_supplier_master",
                        {"supplier_name": "supplier_name", "supplier_tier": "supplier_tier", "supplier_type": "supplier_type",
                         "city": "city", "state": "state_code", "lead_time_days": "lead_time_days",
                         "on_time_delivery_pct": "on_time_delivery_pct", "payment_terms": "payment_terms",
                         "is_active": "is_active"}),
    "part_master": ("part_id", "clean.part", "raw.master_part_master",
                    {"part_number": "part_number", "part_description": "part_description", "part_category": "part_category",
                     "criticality": "criticality", "unit_cost_usd": "unit_cost_usd", "unit_of_measure": "unit_of_measure",
                     "primary_supplier_id": "primary_supplier_id", "primary_product_id": "primary_product_id",
                     "reman_available": "reman_available", "created_date": "created_date", "is_active": "is_active"}),
    "equipment_master": ("equipment_id", "clean.equipment", "raw.master_equipment_master",
                         {"serial_number": "serial_number", "product_id": "product_id", "equipment_model": "equipment_model",
                          "product_category_id": "product_category_id", "model_year": "model_year",
                          "service_meter_hours": "service_meter_hours", "home_branch_id": "home_branch_id",
                          "ownership": "ownership"}),
    "erp/sales_orders": (["sales_order_id", "so_line"], "clean.sales_order_line", "raw.erp_sales_orders",
                         {c: c for c in ["order_timestamp", "branch_id", "customer_id", "customer_name", "order_channel",
                                         "equipment_serial", "part_id", "part_number", "part_description", "qty_ordered",
                                         "unit_price_usd", "extended_price_usd", "requested_date", "qty_shipped",
                                         "line_status", "invoice_date"]}),
    "erp/demand_transactions": ("demand_id", "clean.demand_line", "raw.erp_demand_transactions",
                                {c: c for c in ["sales_order_id", "so_line", "branch_id", "part_id", "demand_date",
                                                "demand_source", "qty_demanded", "qty_filled_from_stock", "qty_backordered",
                                                "qty_backorder_filled", "last_fill_date", "qty_lost_sale", "fill_status"]}),
    "erp/purchase_orders": (["po_number", "po_line"], "clean.purchase_order_line", "raw.erp_purchase_orders",
                            {c: c for c in ["po_date", "branch_id", "supplier_id", "part_id", "part_number", "qty_ordered",
                                            "unit_of_measure", "unit_cost_usd", "line_value_usd", "order_type",
                                            "promised_date", "qty_received", "last_receipt_date", "line_status"]}),
    "erp/goods_receipts": (["gr_number", "gr_line"], "clean.goods_receipt_line", "raw.erp_goods_receipts",
                           {c: c for c in ["receipt_date", "po_number", "po_line", "branch_id", "supplier_id", "part_id",
                                           "part_number", "qty_received", "qty_accepted", "qty_rejected", "unit_cost_usd",
                                           "rejection_reason"]}),
    "erp/inventory_transactions": ("txn_id", "clean.inventory_transaction", "raw.erp_inventory_transactions",
                                   {c: c for c in ["txn_timestamp", "branch_id", "part_id", "part_number", "txn_type", "qty",
                                                   "unit_of_measure", "reference_type", "reference_id", "balance_after",
                                                   "unit_cost_usd"]}),
    # Business files: the raw tables are spreadsheet grids, so there is no raw accuracy to compare (None)
    "business/inventory_policy": (["part_category", "criticality"], "clean.inventory_policy", None,
                                  {c: c for c in ["service_level_target", "review_cycle_days", "min_days_of_supply",
                                                  "max_days_of_supply"]}),
    "business/safety_stock_targets": (["branch_id", "part_id"], "clean.safety_stock_target", None,
                                      {c: c for c in ["part_number", "safety_stock_qty", "reorder_point_qty", "max_qty",
                                                      "service_level_target", "effective_date", "approved_by"]}),
    "business/supplier_exceptions": ("exception_id", "clean.supplier_exception", None,
                                     {c: c for c in ["supplier_id", "supplier_name", "issue", "impacted_category",
                                                     "start_date", "expected_resolution", "impact", "status", "owner"]}),
    "business/critical_parts": ("part_id", "clean.critical_part", None,
                                {c: c for c in ["part_number", "part_description", "equipment_model", "scope", "priority",
                                                "reason", "added_by", "added_date"]}),
    "business/forecast_overrides": ("override_id", "clean.forecast_override", None,
                                    {c: c for c in ["branch_id", "scope_level", "scope_value", "forecast_month",
                                                    "adjustment_pct", "reason", "submitted_by", "submitted_date",
                                                    "approval_status", "approved_by"]}),
}


def norm(v) -> str:
    """Comparable form of a value from either side: Y/N vs bit, '3' vs 3.0, date vs '2026-03-14'."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return ""
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (datetime, date)):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, (int, float, Decimal)):
        return f"{float(v):.2f}"
    s = str(v)
    if re.match(r"^\d{4}-\d\d-\d\d[ T]\d\d:\d\d", s):
        return s[:10]   # timestamps compared at date level: some sources only carry the date
    if s in ("Y", "N"):
        return "1" if s == "Y" else "0"
    try:
        return f"{float(s):.2f}"
    except ValueError:
        return s


def table(conn, name, cols) -> pd.DataFrame:
    cur = conn.execute(f"SELECT {', '.join(cols)} FROM {name}")
    return pd.DataFrame.from_records(cur.fetchall(), columns=[d[0] for d in cur.description])


def score(conn, golden_name, spec) -> dict:
    keys, clean_tbl, raw_tbl, cols = spec
    keys = [keys] if isinstance(keys, str) else keys
    folder, name = golden_name.split("/") if "/" in golden_name else ("master", golden_name)
    golden = pd.read_csv(SRC / GOLDEN[folder] / "golden" / f"{name}.csv", dtype=str, keep_default_na=False)
    key_cols = [k for k in keys if k not in cols]
    clean = table(conn, clean_tbl, key_cols + list(cols.values()))
    raw = table(conn, raw_tbl, key_cols + list(cols)).drop_duplicates(subset=keys) if raw_tbl else None
    for df in (clean, raw) if raw is not None else (clean,):
        for k in keys:
            df[k] = df[k].astype(str)

    def accuracy(df, mapping):
        merged = golden.merge(df, on=keys, how="left", suffixes=("", "__x"), indicator=True)
        cells = correct = 0
        for g_col, o_col in mapping.items():
            if g_col in keys:
                continue
            o_col = o_col if o_col != g_col else g_col + "__x"
            if o_col not in merged:
                continue
            for gv, ov, present in zip(merged[g_col], merged[o_col], merged["_merge"]):
                cells += 1
                correct += present == "both" and norm(gv) == norm(ov)
        return correct / cells if cells else 0.0

    return {
        "table": clean_tbl, "golden_rows": len(golden),
        "raw_rows": conn.execute(f"SELECT COUNT(*) FROM {raw_tbl}").fetchval() if raw_tbl else None,
        "clean_rows": len(clean),
        "missing": len(set(map(tuple, golden[keys].values)) - set(map(tuple, clean[keys].values))),
        "extra": len(set(map(tuple, clean[keys].values)) - set(map(tuple, golden[keys].values))),
        "raw_accuracy": accuracy(raw, {c: c for c in cols}) if raw is not None else None,
        "clean_accuracy": accuracy(clean, cols),
    }


def main():
    conn = connect(autocommit=True)
    for f in sorted(CLEAN_DIR.glob("*.sql")):
        for batch in (b for b in re.split(r"(?im)^\s*GO\s*$", f.read_text(encoding="utf-8")) if b.strip()):
            conn.execute(batch)
    print(f"Deployed {len(list(CLEAN_DIR.glob('*.sql')))} clean script(s)")

    for proc in PROCEDURES:
        t0 = datetime.now()
        conn.execute(f"EXEC {proc}")
        print(f"  {proc}: {(datetime.now() - t0).total_seconds():.1f}s")

    print(f"\n{'clean table':<30}{'golden':>9}{'raw':>9}{'clean':>9}{'missing':>9}{'extra':>7}"
          f"{'raw acc':>10}{'clean acc':>11}")
    for name, spec in SCORED.items():
        r = score(conn, name, spec)
        raw_rows = f"{r['raw_rows']:,}" if r["raw_rows"] is not None else "grid"
        raw_acc = f"{r['raw_accuracy']:.1%}" if r["raw_accuracy"] is not None else "-"
        print(f"{r['table']:<30}{r['golden_rows']:>9,}{raw_rows:>9}{r['clean_rows']:>9,}{r['missing']:>9}"
              f"{r['extra']:>7}{raw_acc:>10}{r['clean_accuracy']:>11.1%}")

    print("\nQuarantined:")
    for row in conn.execute("SELECT source_table, reason_rule_id, COUNT(*) FROM clean.quarantine "
                            "GROUP BY source_table, reason_rule_id ORDER BY source_table"):
        print(f"  {row[0]:<40}{row[1]:<10}{row[2]:>6,}")


if __name__ == "__main__":
    main()
