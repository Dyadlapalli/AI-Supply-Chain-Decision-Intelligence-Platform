/*
    04_Database/mart/02_load_facts.sql
    mart.usp_load_facts: clean -> mart facts (full reload). Run after mart.usp_load_dimensions.

    Facts hold additive quantities, amounts, and per-row flags. Ratios (fill rate, on-time %) are left to DAX.
    A missing date or an unmatched reference points at the Unknown member (-1) rather than dropping the row.
*/
-- Date -> DimDate key (YYYYMMDD); NULL -> -1 (Unknown). Simple enough for SQL Server to inline.
CREATE OR ALTER FUNCTION mart.fn_date_key (@d DATE)
RETURNS INT
AS
BEGIN
    RETURN ISNULL(YEAR(@d) * 10000 + MONTH(@d) * 100 + DAY(@d), -1);
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_facts
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM mart.FactSalesOrderLine;        DELETE FROM mart.FactPurchaseOrderLine;
    DELETE FROM mart.FactGoodsReceiptLine;      DELETE FROM mart.FactInventoryTransaction;
    DELETE FROM mart.FactEconomicIndicator;     DELETE FROM mart.FactWeatherEvent;
    DELETE FROM mart.FactSupplierException;     DELETE FROM mart.FactForecastOverride;
    DELETE FROM mart.FactDataQualityResult;     DELETE FROM mart.FactDataLoad;

    /* =========================================================================================
       FactSalesOrderLine = sales order line + its demand transaction (same grain)
    ========================================================================================= */
    -- historical cost of each sale: the cost on the goods issue it posted
    DROP TABLE IF EXISTS #issue_cost;
    SELECT reference_id, MAX(unit_cost_usd) AS unit_cost_usd
    INTO #issue_cost
    FROM clean.inventory_transaction
    WHERE reference_type = 'SO' AND txn_type IN ('Goods Issue', 'Goods Issue - Backorder')
    GROUP BY reference_id;

    INSERT INTO mart.FactSalesOrderLine WITH (TABLOCK) (
        sales_order_id, so_line, order_date_key, requested_date_key, invoice_date_key, backorder_fill_date_key,
        branch_key, customer_key, part_key, equipment_key, demand_id, order_channel, line_status, fill_status,
        order_timestamp, qty_ordered, qty_filled_from_stock, qty_backordered, qty_backorder_filled, qty_lost_sale,
        qty_shipped, unit_price_usd, unit_cost_usd, extended_price_usd, shipped_value_usd, cost_value_usd,
        lost_sale_value_usd, backorder_days, is_filled_from_stock)
    SELECT s.sales_order_id, s.so_line,
           mart.fn_date_key(CAST(s.order_timestamp AS DATE)), mart.fn_date_key(s.requested_date),
           mart.fn_date_key(s.invoice_date), mart.fn_date_key(d.last_fill_date),
           COALESCE(b.branch_key, -1), COALESCE(c.customer_key, -1), COALESCE(p.part_key, -1), COALESCE(e.equipment_key, -1),
           d.demand_id, COALESCE(s.order_channel, 'Unknown'), COALESCE(s.line_status, 'Unknown'), COALESCE(d.fill_status, 'Unknown'),
           s.order_timestamp,
           s.qty_ordered,
           COALESCE(d.qty_filled_from_stock, 0), COALESCE(d.qty_backordered, 0), COALESCE(d.qty_backorder_filled, 0),
           COALESCE(d.qty_lost_sale, 0), COALESCE(s.qty_shipped, 0),
           COALESCE(s.unit_price_usd, 0), uc.unit_cost_usd,
           COALESCE(s.extended_price_usd, 0),
           COALESCE(s.qty_shipped, 0) * COALESCE(s.unit_price_usd, 0),
           COALESCE(s.qty_shipped, 0) * uc.unit_cost_usd,
           COALESCE(d.qty_lost_sale, 0) * COALESCE(s.unit_price_usd, 0),
           IIF(d.qty_backordered > 0 AND d.last_fill_date IS NOT NULL, DATEDIFF(DAY, d.demand_date, d.last_fill_date), NULL),
           IIF(d.qty_filled_from_stock = s.qty_ordered, 1, 0)
    FROM clean.sales_order_line AS s
    LEFT JOIN clean.demand_line AS d ON d.sales_order_id = s.sales_order_id AND d.so_line = s.so_line
    LEFT JOIN mart.DimBranch AS b ON b.branch_id = s.branch_id
    LEFT JOIN mart.DimCustomer AS c ON c.customer_id = s.customer_id
    LEFT JOIN mart.DimPart AS p ON p.part_id = s.part_id
    LEFT JOIN (SELECT serial_number, MIN(equipment_key) AS equipment_key FROM mart.DimEquipment GROUP BY serial_number) AS e
           ON e.serial_number = s.equipment_serial   -- one key per serial, so a shared serial cannot duplicate a sale
    LEFT JOIN #issue_cost AS ic ON ic.reference_id = s.sales_order_id + '-' + CAST(s.so_line AS VARCHAR(5))
    CROSS APPLY (SELECT COALESCE(ic.unit_cost_usd, p.unit_cost_usd) AS unit_cost_usd) AS uc;

    /* =========================================================================================
       FactPurchaseOrderLine (accumulating snapshot) - supplier version valid on the PO date (SCD 2)
    ========================================================================================= */
    INSERT INTO mart.FactPurchaseOrderLine WITH (TABLOCK) (
        po_number, po_line, po_date_key, promised_date_key, last_receipt_date_key, branch_key, supplier_key, part_key,
        order_type, line_status, qty_ordered, qty_received, qty_open, unit_cost_usd, line_value_usd,
        planned_lead_time_days, actual_lead_time_days, days_late, is_on_time)
    SELECT o.po_number, o.po_line, mart.fn_date_key(o.po_date), mart.fn_date_key(o.promised_date),
           mart.fn_date_key(o.last_receipt_date),
           COALESCE(b.branch_key, -1), COALESCE(sv.supplier_key, -1), COALESCE(p.part_key, -1),
           COALESCE(o.order_type, 'Unknown'), o.line_status, COALESCE(o.qty_ordered, 0), o.qty_received,
           IIF(o.qty_ordered > o.qty_received, o.qty_ordered - o.qty_received, 0),
           COALESCE(o.unit_cost_usd, 0), COALESCE(o.line_value_usd, 0),
           sv.lead_time_days,                                                     -- master lead time valid on the PO date
           IIF(o.line_status = 'Closed', DATEDIFF(DAY, o.po_date, o.last_receipt_date), NULL),
           IIF(o.line_status = 'Closed', DATEDIFF(DAY, o.promised_date, o.last_receipt_date), NULL),
           CASE WHEN o.line_status <> 'Closed' OR o.promised_date IS NULL THEN NULL
                WHEN o.last_receipt_date <= o.promised_date THEN 1 ELSE 0 END
    FROM clean.purchase_order_line AS o
    LEFT JOIN mart.DimBranch AS b ON b.branch_id = o.branch_id
    LEFT JOIN mart.DimPart AS p ON p.part_id = o.part_id
    LEFT JOIN mart.DimSupplier AS sv ON sv.supplier_id = o.supplier_id AND o.po_date BETWEEN sv.valid_from AND sv.valid_to;

    /* =========================================================================================
       FactGoodsReceiptLine
    ========================================================================================= */
    INSERT INTO mart.FactGoodsReceiptLine WITH (TABLOCK) (
        gr_number, gr_line, receipt_date_key, branch_key, supplier_key, part_key, po_number, po_line,
        qty_received, qty_accepted, qty_rejected, unit_cost_usd, received_value_usd, rejection_reason)
    SELECT g.gr_number, g.gr_line, mart.fn_date_key(g.receipt_date),
           COALESCE(b.branch_key, -1), COALESCE(sv.supplier_key, -1), COALESCE(p.part_key, -1),
           g.po_number, COALESCE(g.po_line, 0), COALESCE(g.qty_received, 0), COALESCE(g.qty_accepted, 0),
           COALESCE(g.qty_rejected, 0), COALESCE(g.unit_cost_usd, 0),
           COALESCE(g.qty_received, 0) * COALESCE(g.unit_cost_usd, 0), g.rejection_reason
    FROM clean.goods_receipt_line AS g
    LEFT JOIN mart.DimBranch AS b ON b.branch_id = g.branch_id
    LEFT JOIN mart.DimPart AS p ON p.part_id = g.part_id
    LEFT JOIN mart.DimSupplier AS sv ON sv.supplier_id = g.supplier_id AND g.receipt_date BETWEEN sv.valid_from AND sv.valid_to;

    /* =========================================================================================
       FactInventoryTransaction - signed quantity, value, and cost of goods
    ========================================================================================= */
    INSERT INTO mart.FactInventoryTransaction WITH (TABLOCK) (
        txn_id, txn_date_key, txn_timestamp, branch_key, part_key, txn_type_key, qty, unit_cost_usd, value_usd,
        cogs_value_usd, reference_type, reference_id, balance_after)
    SELECT t.txn_id, mart.fn_date_key(CAST(t.txn_timestamp AS DATE)), t.txn_timestamp,
           COALESCE(b.branch_key, -1), COALESCE(p.part_key, -1), COALESCE(tt.txn_type_key, -1),
           t.qty, COALESCE(t.unit_cost_usd, 0), t.qty * COALESCE(t.unit_cost_usd, 0),
           IIF(tt.is_cogs = 1, -t.qty * COALESCE(t.unit_cost_usd, 0), 0),   -- issues (negative qty) add to COGS, returns reduce it
           t.reference_type, t.reference_id, t.balance_after
    FROM clean.inventory_transaction AS t
    LEFT JOIN mart.DimBranch AS b ON b.branch_id = t.branch_id
    LEFT JOIN mart.DimPart AS p ON p.part_id = t.part_id
    LEFT JOIN mart.DimTransactionType AS tt ON tt.txn_type = t.txn_type;

    /* =========================================================================================
       Supporting facts
    ========================================================================================= */
    INSERT INTO mart.FactEconomicIndicator (indicator_key, date_key, [value], retrieved_at)
    SELECT i.indicator_key, mart.fn_date_key(e.observation_date), e.[value], COALESCE(e.retrieved_at, SYSUTCDATETIME())
    FROM clean.economic_indicator AS e
    JOIN mart.DimIndicator AS i ON i.series_id = e.series_id
    WHERE e.observation_date BETWEEN '2018-01-01' AND '2027-12-31';

    INSERT INTO mart.FactEconomicIndicator (indicator_key, date_key, [value], retrieved_at)
    SELECT i.indicator_key, mart.fn_date_key(f.week_of), f.price_usd_per_gal, SYSUTCDATETIME()
    FROM clean.fuel_price AS f
    JOIN mart.DimIndicator AS i ON i.series_id = 'DIESEL_' + UPPER(REPLACE(LEFT(f.region, CHARINDEX(' (', f.region + ' (') - 1), ' ', '_'))
    WHERE f.week_of BETWEEN '2018-01-01' AND '2027-12-31';

    INSERT INTO mart.FactWeatherEvent (event_id, episode_id, begin_date_key, end_date_key, state_code, county_or_zone,
        zone_type, event_type, begin_datetime, end_datetime, injuries, deaths, property_damage_usd, crop_damage_usd,
        magnitude, magnitude_type, begin_lat, begin_lon)
    SELECT event_id, episode_id, mart.fn_date_key(CAST(begin_datetime AS DATE)), mart.fn_date_key(CAST(end_datetime AS DATE)),
           state_code, county_or_zone, zone_type, event_type, begin_datetime, end_datetime, injuries, deaths,
           property_damage_usd, crop_damage_usd, magnitude, magnitude_type, begin_lat, begin_lon
    FROM clean.storm_event
    WHERE CAST(begin_datetime AS DATE) BETWEEN '2018-01-01' AND '2027-12-31';

    INSERT INTO mart.FactSupplierException (exception_id, supplier_key, start_date_key, expected_resolution_date_key,
        issue, impacted_category, impact, status, owner)
    SELECT x.exception_id, COALESCE(s.supplier_key, -1), mart.fn_date_key(x.start_date),
           mart.fn_date_key(IIF(x.expected_resolution > '2027-12-31', NULL, x.expected_resolution)),
           x.issue, x.impacted_category, COALESCE(x.impact, 'Unknown'), COALESCE(x.status, 'Unknown'), x.owner
    FROM clean.supplier_exception AS x
    LEFT JOIN mart.DimSupplier AS s ON s.supplier_id = x.supplier_id AND s.is_current = 1;

    INSERT INTO mart.FactForecastOverride (override_id, branch_key, forecast_month_key, submitted_date_key, scope_level,
        scope_value, adjustment_pct, approval_status, reason, submitted_by, approved_by)
    SELECT f.override_id, COALESCE(b.branch_key, -1), mart.fn_date_key(f.forecast_month), mart.fn_date_key(f.submitted_date),
           f.scope_level, f.scope_value, f.adjustment_pct, COALESCE(f.approval_status, 'Unknown'), f.reason,
           f.submitted_by, f.approved_by
    FROM clean.forecast_override AS f
    LEFT JOIN mart.DimBranch AS b ON b.branch_id = f.branch_id;

    INSERT INTO mart.FactDataQualityResult (run_id, rule_key, run_date_key, run_timestamp, records_evaluated, records_failed)
    SELECT CAST(rr.run_id AS VARCHAR(30)), r.rule_key, mart.fn_date_key(CAST(run.started_at AS DATE)), run.started_at,
           COALESCE(rr.records_evaluated, 0), COALESCE(rr.records_failed, 0)
    FROM dq.rule_result AS rr
    JOIN dq.run AS run ON run.run_id = rr.run_id
    JOIN mart.DimDQRule AS r ON r.rule_id = rr.rule_id
    WHERE rr.status = 'ok';

    INSERT INTO mart.FactDataLoad (load_id, load_date_key, source_system, dataset, loaded_at, rows_loaded, status, note)
    SELECT load_id, mart.fn_date_key(CAST(started_at AS DATE)), source_system, dataset, COALESCE(finished_at, started_at),
           COALESCE(rows_loaded, 0), status, note
    FROM audit.load_log;
END
GO
