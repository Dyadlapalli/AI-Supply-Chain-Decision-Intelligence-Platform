"""
Load the star schema (mart) from the clean layer, then check the KPIs it produces against the KPI Catalog.

Steps:
  1. Deploy the procedures in 04_Database/mart
  2. Load dimensions (upsert; DimSupplier keeps history), facts (full reload), and the daily inventory snapshot
  3. Calculate the KPI Catalog baselines (Oct 2025 - Sep 2026) from the mart and compare them with the catalog.
     The catalog baselines were calculated from the generators' reference data, so agreement shows the whole
     pipeline - raw -> data quality -> clean -> mart - preserves the business numbers.

Usage:
    python 04_Database/run_mart.py
"""

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from load_raw import connect  # noqa: E402

MART_DIR = Path(__file__).parent / "mart"
PROCEDURES = ["mart.usp_load_dimensions", "mart.usp_load_facts", "mart.usp_load_inventory_snapshot"]
START, END = 20251001, 20260930   # KPI Catalog baseline period (trailing 12 months)

W = f"BETWEEN {START} AND {END}"
# KPI id, name, catalog baseline (as published), SQL returning one number, display format
KPIS = [
    ("SVC-01", "Line fill rate", "87.8%",
     f"SELECT AVG(CAST(is_filled_from_stock AS FLOAT)) FROM mart.FactSalesOrderLine WHERE order_date_key {W}", "pct"),
    ("SVC-02", "Order fill rate", "82.5%",
     f"""SELECT AVG(CAST(all_filled AS FLOAT)) FROM (SELECT MIN(CAST(is_filled_from_stock AS INT)) AS all_filled
         FROM mart.FactSalesOrderLine WHERE order_date_key {W} GROUP BY sales_order_id) o""", "pct"),
    ("SVC-03", "Unit fill rate", "92.7%",
     f"SELECT 1.0 * SUM(qty_filled_from_stock) / SUM(qty_ordered) FROM mart.FactSalesOrderLine WHERE order_date_key {W}", "pct"),
    ("SVC-04", "Lost sales value", "$479K",
     f"SELECT SUM(lost_sale_value_usd) FROM mart.FactSalesOrderLine WHERE order_date_key {W}", "usd"),
    ("SVC-05", "Average backorder age (days)", "5.0",
     f"SELECT AVG(CAST(backorder_days AS FLOAT)) FROM mart.FactSalesOrderLine WHERE order_date_key {W} AND qty_backordered > 0", "num"),
    ("SVC-06", "Stockout rate (30 Sep 2026)", "1.3%",
     f"SELECT AVG(CAST(is_stockout AS FLOAT)) FROM mart.FactInventorySnapshotDaily WHERE snapshot_date_key = {END}", "pct"),
    ("INV-01", "Inventory value (30 Sep 2026)", "$17.9M",
     f"SELECT SUM(on_hand_value_usd) FROM mart.FactInventorySnapshotDaily WHERE snapshot_date_key = {END}", "usd"),
    ("INV-02", "Inventory turns (COGS / ending value)", "1.1x",
     f"""SELECT (SELECT SUM(cogs_value_usd) FROM mart.FactInventoryTransaction WHERE txn_date_key {W})
              / (SELECT SUM(on_hand_value_usd) FROM mart.FactInventorySnapshotDaily WHERE snapshot_date_key = {END})""", "x"),
    ("INV-02b", "Inventory turns (COGS / avg month-end value)", "-",
     f"""SELECT (SELECT SUM(cogs_value_usd) FROM mart.FactInventoryTransaction WHERE txn_date_key {W})
              / (SELECT AVG(v) FROM (SELECT SUM(s.on_hand_value_usd) AS v FROM mart.FactInventorySnapshotDaily s
                 JOIN mart.DimDate d ON d.date_key = s.snapshot_date_key
                 WHERE d.is_month_end = 1 AND s.snapshot_date_key {W} GROUP BY s.snapshot_date_key) m)""", "x"),
    ("INV-04", "Excess value vs. targets (30 Sep 2026)", "$216K",
     f"SELECT SUM(excess_value_usd) FROM mart.FactInventorySnapshotDaily WHERE snapshot_date_key = {END} AND max_qty IS NOT NULL", "usd"),
    ("INV-05", "Non-moving share of value (30 Sep 2026)", "39%",
     f"""SELECT SUM(IIF(is_non_moving_12m = 1, on_hand_value_usd, 0)) / SUM(on_hand_value_usd)
         FROM mart.FactInventorySnapshotDaily WHERE snapshot_date_key = {END}""", "pct"),
    ("SUP-01", "Supplier on-time delivery", "85.4%",
     f"SELECT AVG(CAST(is_on_time AS FLOAT)) FROM mart.FactPurchaseOrderLine WHERE po_date_key {W} AND is_on_time IS NOT NULL", "pct"),
    ("SUP-02", "Average actual lead time (days)", "6.2",
     f"SELECT AVG(CAST(actual_lead_time_days AS FLOAT)) FROM mart.FactPurchaseOrderLine WHERE po_date_key {W}", "num"),
    ("SUP-03", "Lead time standard deviation (days)", "6.0",
     f"SELECT STDEV(actual_lead_time_days) FROM mart.FactPurchaseOrderLine WHERE po_date_key {W}", "num"),
    ("SUP-04", "Receipt rejection rate (all time)", "0.14%",
     "SELECT 1.0 * SUM(qty_rejected) / SUM(qty_received) FROM mart.FactGoodsReceiptLine", "pct2"),
    ("SUP-06", "Emergency order rate", "4.7%",
     f"SELECT AVG(IIF(order_type = 'Emergency', 1.0, 0)) FROM mart.FactPurchaseOrderLine WHERE po_date_key {W}", "pct"),
    ("NET-01", "Transfer share of replenishment", "5.6%",
     f"""SELECT 1.0 * t.n / (t.n + p.n) FROM
         (SELECT COUNT(DISTINCT reference_id) AS n FROM mart.FactInventoryTransaction WHERE txn_type_key = 5 AND txn_date_key {W}) t,
         (SELECT COUNT(DISTINCT po_number) AS n FROM mart.FactPurchaseOrderLine WHERE po_date_key {W}) p""", "pct"),
    ("FIN-01", "Parts revenue (ordered value)", "$27.9M",
     f"SELECT SUM(extended_price_usd) FROM mart.FactSalesOrderLine WHERE order_date_key {W}", "usd"),
    ("FIN-02", "Parts gross margin (catalog method)", "25.5%",
     f"""SELECT 1 - SUM(f.qty_ordered * p.unit_cost_usd) / SUM(f.extended_price_usd)
         FROM mart.FactSalesOrderLine f JOIN mart.DimPart p ON p.part_key = f.part_key WHERE f.order_date_key {W}""", "pct"),
]


def fmt(v, kind):
    if v is None:
        return "-"
    v = float(v)
    return {"pct": f"{v:.1%}", "pct2": f"{v:.2%}", "num": f"{v:.1f}", "x": f"{v:.2f}x",
            "usd": f"${v / 1e6:.1f}M" if abs(v) >= 1e6 else f"${v / 1e3:.0f}K"}[kind]


def main():
    conn = connect(autocommit=True)
    files = sorted(MART_DIR.glob("*.sql"))
    for f in files:
        for batch in (b for b in re.split(r"(?im)^\s*GO\s*$", f.read_text(encoding="utf-8")) if b.strip()):
            conn.execute(batch)
    print(f"Deployed {len(files)} mart script(s)")

    for proc in PROCEDURES:
        t0 = time.time()
        conn.execute(f"EXEC {proc}")
        print(f"  {proc}: {time.time() - t0:.1f}s")

    print("\nRows loaded:")
    for (name,) in conn.execute("SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('mart') ORDER BY name").fetchall():
        n = conn.execute(f"SELECT COUNT_BIG(*) FROM mart.{name}").fetchval()
        print(f"  {name:<30}{n:>12,}")

    print(f"\nKPI check, {START}-{END}: star schema vs. KPI Catalog baseline")
    print(f"  {'KPI':<8}{'Name':<46}{'Catalog':>10}{'Mart':>10}")
    for kpi_id, name, baseline, sql, kind in KPIS:
        value = conn.execute(sql).fetchval()
        print(f"  {kpi_id:<8}{name:<46}{baseline:>10}{fmt(value, kind):>10}")


if __name__ == "__main__":
    main()
