/*
    04_Database/mart/03_load_snapshot.sql
    mart.usp_load_inventory_snapshot: builds FactInventorySnapshotDaily - one row per stocked branch x part x day.
    Run after mart.usp_load_facts (it is derived from the transaction facts).

    No source system records daily stock positions, so they are rebuilt from events:
        on hand        running total of inventory transactions
        on order       + PO quantity on the PO date, - quantity received on each receipt date
        in transit     + transfer quantity when shipped, - when it arrives at the receiving branch
        backorders     + quantity backordered on the order date, - quantity issued against backorders
        demand         quantity ordered by customers that day (rolling 90 and 365 days for supply and non-moving)
*/
CREATE OR ALTER PROCEDURE mart.usp_load_inventory_snapshot
AS
BEGIN
    SET NOCOUNT ON;

    /* --- stocked branch x part combinations -------------------------------------------------- */
    DROP TABLE IF EXISTS #combo;
    SELECT DISTINCT t.branch_key, t.part_key, COALESCE(p.unit_cost_usd, 0) AS unit_cost_usd
    INTO #combo
    FROM mart.FactInventoryTransaction AS t
    JOIN mart.DimPart AS p ON p.part_key = t.part_key
    WHERE t.branch_key > 0 AND t.part_key > 0;

    DECLARE @from INT = (SELECT MIN(txn_date_key) FROM mart.FactInventoryTransaction WHERE txn_date_key > 0),
            @to   INT = (SELECT MAX(txn_date_key) FROM mart.FactInventoryTransaction WHERE txn_date_key > 0);

    /* --- daily events --------------------------------------------------------------------------- */
    DROP TABLE IF EXISTS #ev;
    CREATE TABLE #ev (branch_key INT, part_key INT, date_key INT, d_on_hand INT, d_on_order INT, d_transit INT,
                      d_backorder INT, demand INT);

    INSERT INTO #ev SELECT branch_key, part_key, txn_date_key, SUM(qty), 0, 0, 0, 0
    FROM mart.FactInventoryTransaction WHERE txn_date_key > 0 GROUP BY branch_key, part_key, txn_date_key;

    INSERT INTO #ev SELECT branch_key, part_key, po_date_key, 0, SUM(qty_ordered), 0, 0, 0
    FROM mart.FactPurchaseOrderLine WHERE po_date_key > 0 GROUP BY branch_key, part_key, po_date_key;

    INSERT INTO #ev SELECT branch_key, part_key, receipt_date_key, 0, -SUM(qty_received), 0, 0, 0
    FROM mart.FactGoodsReceiptLine WHERE receipt_date_key > 0 GROUP BY branch_key, part_key, receipt_date_key;

    -- transfers: the receiving branch has stock in transit from the day it ships until the day it arrives
    INSERT INTO #ev
    SELECT i.branch_key, i.part_key, o.txn_date_key, 0, 0, i.qty, 0, 0
    FROM mart.FactInventoryTransaction AS o
    JOIN mart.FactInventoryTransaction AS i ON i.reference_id = o.reference_id AND i.part_key = o.part_key
    WHERE o.txn_type_key = 6 AND i.txn_type_key = 5;                 -- Transfer Out -> Transfer In
    INSERT INTO #ev SELECT branch_key, part_key, txn_date_key, 0, 0, -qty, 0, 0
    FROM mart.FactInventoryTransaction WHERE txn_type_key = 5;

    INSERT INTO #ev SELECT branch_key, part_key, order_date_key, 0, 0, 0, SUM(qty_backordered), SUM(qty_ordered)
    FROM mart.FactSalesOrderLine WHERE order_date_key > 0 GROUP BY branch_key, part_key, order_date_key;
    INSERT INTO #ev SELECT branch_key, part_key, txn_date_key, 0, 0, 0, SUM(qty), 0   -- backorder issues are negative quantities
    FROM mart.FactInventoryTransaction WHERE txn_type_key = 3 GROUP BY branch_key, part_key, txn_date_key;

    DROP TABLE IF EXISTS #day;
    SELECT branch_key, part_key, date_key, SUM(d_on_hand) AS d_on_hand, SUM(d_on_order) AS d_on_order,
           SUM(d_transit) AS d_transit, SUM(d_backorder) AS d_backorder, SUM(demand) AS demand
    INTO #day FROM #ev GROUP BY branch_key, part_key, date_key;
    CREATE CLUSTERED INDEX cx ON #day (branch_key, part_key, date_key);

    /* --- safety stock targets apply from their effective date -------------------------------- */
    DROP TABLE IF EXISTS #target;
    SELECT b.branch_key, p.part_key, mart.fn_date_key(t.effective_date) AS from_key,
           t.safety_stock_qty, t.reorder_point_qty, t.max_qty
    INTO #target
    FROM clean.safety_stock_target AS t
    JOIN mart.DimBranch AS b ON b.branch_id = t.branch_id
    JOIN mart.DimPart AS p ON p.part_id = t.part_id;

    /* --- dense grid (every combo, every day), running totals, rolling demand ------------------ */
    TRUNCATE TABLE mart.FactInventorySnapshotDaily;   -- nothing references this fact, so TRUNCATE is allowed

    WITH grid AS (
        SELECT c.branch_key, c.part_key, c.unit_cost_usd, d.date_key
        FROM #combo AS c
        CROSS JOIN (SELECT date_key FROM mart.DimDate WHERE date_key BETWEEN @from AND @to) AS d
    ), running AS (
        SELECT g.branch_key, g.part_key, g.unit_cost_usd, g.date_key,
               ISNULL(y.demand, 0) AS demand,
               SUM(ISNULL(y.d_on_hand, 0))   OVER w AS on_hand,
               SUM(ISNULL(y.d_on_order, 0))  OVER w AS on_order,
               SUM(ISNULL(y.d_transit, 0))   OVER w AS in_transit,
               SUM(ISNULL(y.d_backorder, 0)) OVER w AS backorder,
               SUM(ISNULL(y.demand, 0)) OVER (PARTITION BY g.branch_key, g.part_key ORDER BY g.date_key
                                              ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) AS demand_90d,
               SUM(ISNULL(y.demand, 0)) OVER (PARTITION BY g.branch_key, g.part_key ORDER BY g.date_key
                                              ROWS BETWEEN 364 PRECEDING AND CURRENT ROW) AS demand_365d
        FROM grid AS g
        LEFT JOIN #day AS y ON y.branch_key = g.branch_key AND y.part_key = g.part_key AND y.date_key = g.date_key
        WINDOW w AS (PARTITION BY g.branch_key, g.part_key ORDER BY g.date_key ROWS UNBOUNDED PRECEDING)
    )
    INSERT INTO mart.FactInventorySnapshotDaily WITH (TABLOCK) (
        snapshot_date_key, branch_key, part_key, on_hand_qty, on_order_qty, in_transit_qty, backorder_qty,
        inventory_position_qty, unit_cost_usd, on_hand_value_usd, demand_qty, avg_daily_demand_90d, days_of_supply,
        safety_stock_qty, reorder_point_qty, max_qty, excess_qty, excess_value_usd, is_stockout,
        is_below_reorder_point, is_excess, is_non_moving_12m)
    SELECT r.date_key, r.branch_key, r.part_key,
           r.on_hand, GREATEST(r.on_order, 0), GREATEST(r.in_transit, 0), GREATEST(r.backorder, 0),
           r.on_hand + GREATEST(r.on_order, 0) + GREATEST(r.in_transit, 0) - GREATEST(r.backorder, 0),
           r.unit_cost_usd, r.on_hand * r.unit_cost_usd, r.demand,
           CAST(r.demand_90d / 90.0 AS DECIMAL(10, 3)),
           CAST(r.on_hand / NULLIF(r.demand_90d / 90.0, 0) AS DECIMAL(10, 1)),
           t.safety_stock_qty, t.reorder_point_qty, t.max_qty,
           x.excess_qty, x.excess_qty * r.unit_cost_usd,
           IIF(r.on_hand <= 0, 1, 0),
           IIF(t.reorder_point_qty IS NOT NULL
               AND r.on_hand + GREATEST(r.on_order, 0) + GREATEST(r.in_transit, 0) - GREATEST(r.backorder, 0) <= t.reorder_point_qty, 1, 0),
           IIF(x.excess_qty > 0, 1, 0),
           IIF(r.demand_365d = 0, 1, 0)
    FROM running AS r
    LEFT JOIN #target AS t ON t.branch_key = r.branch_key AND t.part_key = r.part_key AND r.date_key >= t.from_key
    CROSS APPLY (SELECT CAST(CASE
        WHEN t.max_qty IS NOT NULL THEN GREATEST(r.on_hand - t.max_qty, 0)                        -- above the planned maximum
        WHEN r.demand_90d > 0 THEN GREATEST(r.on_hand - CEILING(180 * r.demand_90d / 90.0), 0)    -- above 180 days of supply
        ELSE 0 END AS INT) AS excess_qty) AS x;
END
GO
