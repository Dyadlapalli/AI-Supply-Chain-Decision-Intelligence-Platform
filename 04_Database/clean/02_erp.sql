/*
    04_Database/clean/02_erp.sql
    clean.usp_build_erp: builds clean ERP transactions. Run after clean.usp_build_master (uses its crosswalks).

    Cross-source reconciliation: ERP documents describe the same events from several angles, so a damaged
    value is recovered from a related document before anything is discarded:
        sales line      <-> demand transaction (same order line)
        PO line         <-> its goods receipts
        goods receipt   <-> the inventory transaction it posted
        inventory       <-> its own running balance
    A record is quarantined only when no related document can repair it.
*/
CREATE OR ALTER PROCEDURE clean.usp_build_erp
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM clean.quarantine WHERE source_table LIKE 'raw.erp[_]%';
    DECLARE @now DATETIME2(0) = SYSUTCDATETIME();

    /* =========================================================================================
       Parse once. ISO values (the large majority) skip the general-purpose parsers.
    ========================================================================================= */
    -- Canonical part numbers are computed once per row and stored: joining ON a function call would make
    -- SQL Server evaluate it for every pair of rows (hundreds of millions of calls)
    DROP TABLE IF EXISTS #so_src;
    SELECT *, clean.fn_canon_part(part_number) AS part_canon INTO #so_src FROM raw.erp_sales_orders;

    DROP TABLE IF EXISTS #so;
    SELECT s.sales_order_id, TRY_CAST(s.so_line AS SMALLINT) AS so_line,
           ROW_NUMBER() OVER (PARTITION BY s.sales_order_id, s.so_line ORDER BY s._row_number) AS copy_no,
           CASE WHEN s.order_timestamp LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:%'
                THEN TRY_CONVERT(DATETIME2(0), s.order_timestamp, 120) ELSE clean.fn_to_datetime(s.order_timestamp) END AS order_ts,
           bx.branch_id, s.customer_id, LTRIM(RTRIM(s.customer_name)) AS customer_name, s.order_channel,
           UPPER(LTRIM(RTRIM(s.equipment_serial))) AS equipment_serial,
           px.part_id AS part_id_by_id, pn.part_id AS part_id_by_number,
           TRY_CAST(s.qty_ordered AS INT) AS qty_ordered, clean.fn_to_money(s.unit_price_usd) AS unit_price,
           TRY_CONVERT(DATE, s.requested_date, 23) AS requested_date, TRY_CAST(s.qty_shipped AS INT) AS qty_shipped,
           s.line_status, TRY_CONVERT(DATE, s.invoice_date, 23) AS invoice_date, s._loaded_at
    INTO #so
    FROM #so_src AS s
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = s.branch_id
    LEFT JOIN clean.part_xref AS px ON px.source_part_id = s.part_id
    LEFT JOIN clean.part AS pn ON pn.part_number = s.part_canon;

    DROP TABLE IF EXISTS #dm;
    SELECT d.demand_id, d.sales_order_id, TRY_CAST(d.so_line AS SMALLINT) AS so_line,
           ROW_NUMBER() OVER (PARTITION BY d.sales_order_id, d.so_line ORDER BY d.demand_id) AS copy_no,
           bx.branch_id, px.part_id,
           IIF(d.demand_date LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]' AND d.demand_date >= N'2000', TRY_CONVERT(DATE, d.demand_date, 23), NULL) AS demand_date,
           d.demand_source, TRY_CAST(d.qty_demanded AS INT) AS qty_demanded,
           TRY_CAST(d.qty_filled_from_stock AS INT) AS qty_filled, TRY_CAST(d.qty_backordered AS INT) AS qty_backordered,
           TRY_CAST(d.qty_backorder_filled AS INT) AS qty_backorder_filled, TRY_CONVERT(DATE, d.last_fill_date, 23) AS last_fill_date,
           TRY_CAST(d.qty_lost_sale AS INT) AS qty_lost, d.fill_status
    INTO #dm
    FROM raw.erp_demand_transactions AS d
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = d.branch_id COLLATE Latin1_General_CS_AS   -- 'b001' is not a valid ID...
    LEFT JOIN clean.part_xref AS px ON px.source_part_id = d.part_id;
    -- ...but it plainly means B001: fall back to a case-insensitive match
    UPDATE d SET branch_id = bx.branch_id
    FROM #dm AS d
    JOIN raw.erp_demand_transactions AS r ON r.demand_id = d.demand_id
    JOIN clean.branch_xref AS bx ON bx.source_value = r.branch_id
    WHERE d.branch_id IS NULL;

    /* =========================================================================================
       SALES ORDER LINES - repaired from the demand transaction for the same line
    ========================================================================================= */
    DROP TABLE IF EXISTS clean.sales_order_line;
    WITH names AS (   -- one spelling per customer: the most common one
        SELECT customer_id, customer_name,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY COUNT(*) DESC, customer_name) AS rk
        FROM #so GROUP BY customer_id, customer_name
    ), order_branch AS (   -- a sales order belongs to one branch
        SELECT sales_order_id, MIN(branch_id) AS branch_id FROM #so WHERE branch_id IS NOT NULL GROUP BY sales_order_id
    ), price AS (          -- a part's price in a given year, from its other lines
        SELECT COALESCE(part_id_by_id, part_id_by_number) AS part_id, YEAR(order_ts) AS yr, MAX(unit_price) AS unit_price
        FROM #so WHERE unit_price > 0 GROUP BY COALESCE(part_id_by_id, part_id_by_number), YEAR(order_ts)
    ), fixed AS (
        SELECT s.sales_order_id, s.so_line,
               CASE WHEN s.order_ts IS NULL OR s.order_ts > s._loaded_at
                    THEN CAST(d.demand_date AS DATETIME2(0)) ELSE s.order_ts END AS order_ts,
               COALESCE(s.branch_id, ob.branch_id, d.branch_id) AS branch_id,
               s.customer_id, n.customer_name, s.order_channel, NULLIF(s.equipment_serial, N'') AS equipment_serial,
               COALESCE(s.part_id_by_id, s.part_id_by_number, d.part_id) AS part_id,
               COALESCE(IIF(s.qty_ordered > 0, s.qty_ordered, NULL), d.qty_demanded, ABS(NULLIF(s.qty_ordered, 0))) AS qty_ordered,
               s.unit_price, s.requested_date, s.qty_shipped, s.line_status, s.invoice_date
        FROM #so AS s
        LEFT JOIN #dm AS d ON d.sales_order_id = s.sales_order_id AND d.so_line = s.so_line AND d.copy_no = 1
        LEFT JOIN order_branch AS ob ON ob.sales_order_id = s.sales_order_id
        LEFT JOIN names AS n ON n.customer_id = s.customer_id AND n.rk = 1
        WHERE s.copy_no = 1   -- the same line sent twice by the interface (E-SO-01)
    )
    SELECT ISNULL(CAST(f.sales_order_id AS VARCHAR(12)), '') AS sales_order_id, ISNULL(f.so_line, 0) AS so_line,
           f.order_ts AS order_timestamp, CAST(f.branch_id AS VARCHAR(10)) AS branch_id,
           CAST(f.customer_id AS VARCHAR(10)) AS customer_id, CAST(f.customer_name AS NVARCHAR(100)) AS customer_name,
           CAST(f.order_channel AS VARCHAR(30)) AS order_channel, CAST(f.equipment_serial AS VARCHAR(20)) AS equipment_serial,
           CAST(f.part_id AS VARCHAR(10)) AS part_id, p.part_number, p.part_description,
           f.qty_ordered,
           CAST(COALESCE(NULLIF(f.unit_price, 0), pr.unit_price) AS DECIMAL(12, 2)) AS unit_price_usd,
           CAST(f.qty_ordered * COALESCE(NULLIF(f.unit_price, 0), pr.unit_price) AS DECIMAL(14, 2)) AS extended_price_usd,  -- recomputed (E-SO-10)
           f.requested_date, f.qty_shipped, CAST(f.line_status AS VARCHAR(40)) AS line_status, f.invoice_date
    INTO clean.sales_order_line
    FROM fixed AS f
    LEFT JOIN clean.part AS p ON p.part_id = f.part_id
    LEFT JOIN price AS pr ON pr.part_id = f.part_id AND pr.yr = YEAR(f.order_ts)
    WHERE f.branch_id IS NOT NULL AND f.part_id IS NOT NULL AND f.qty_ordered IS NOT NULL AND f.order_ts IS NOT NULL;
    EXEC (N'ALTER TABLE clean.sales_order_line ADD CONSTRAINT PK_clean_sales_order_line PRIMARY KEY (sales_order_id, so_line)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT DISTINCT 'raw.erp_sales_orders', s.sales_order_id + N'-' + CAST(s.so_line AS NVARCHAR(5)), 'CLEAN-02',
           N'Sales line could not be repaired from its demand transaction (branch, part, quantity, or date missing)'
    FROM #so AS s
    WHERE s.copy_no = 1
      AND NOT EXISTS (SELECT 1 FROM clean.sales_order_line c WHERE c.sales_order_id = s.sales_order_id AND c.so_line = s.so_line);

    /* =========================================================================================
       DEMAND - repaired from the sales line; quantities reconciled with
                demanded = filled from stock + backordered + lost
    ========================================================================================= */
    DROP TABLE IF EXISTS clean.demand_line;
    SELECT ISNULL(CAST(d.demand_id AS VARCHAR(12)), '') AS demand_id,
           CAST(d.sales_order_id AS VARCHAR(12)) AS sales_order_id, d.so_line,
           CAST(COALESCE(d.branch_id, s.branch_id) AS VARCHAR(10)) AS branch_id,
           CAST(COALESCE(d.part_id, s.part_id) AS VARCHAR(10)) AS part_id,
           COALESCE(d.demand_date, CAST(s.order_timestamp AS DATE)) AS demand_date,
           CAST(d.demand_source AS VARCHAR(30)) AS demand_source,
           q.qty_demanded,
           IIF(d.qty_filled > q.qty_demanded, q.qty_demanded - d.qty_backordered - d.qty_lost, d.qty_filled) AS qty_filled_from_stock,
           d.qty_backordered, d.qty_backorder_filled, d.last_fill_date, d.qty_lost AS qty_lost_sale,
           CAST(d.fill_status AS VARCHAR(30)) AS fill_status
    INTO clean.demand_line
    FROM #dm AS d
    LEFT JOIN clean.sales_order_line AS s ON s.sales_order_id = d.sales_order_id AND s.so_line = d.so_line
    CROSS APPLY (SELECT COALESCE(d.qty_demanded, s.qty_ordered, d.qty_filled + d.qty_backordered + d.qty_lost) AS qty_demanded) AS q
    WHERE d.copy_no = 1;   -- duplicates of the same order line (E-DM-01)
    EXEC (N'ALTER TABLE clean.demand_line ADD CONSTRAINT PK_clean_demand_line PRIMARY KEY (demand_id)');

    DELETE FROM clean.demand_line
    OUTPUT 'raw.erp_demand_transactions', deleted.demand_id, 'CLEAN-03',
           N'Demand could not be repaired from its sales line (branch, part, date, or quantity missing)'
    INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    WHERE branch_id IS NULL OR part_id IS NULL OR demand_date IS NULL OR qty_demanded IS NULL;

    /* =========================================================================================
       GOODS RECEIPTS - date from the inventory posting; quantity from accepted + rejected
    ========================================================================================= */
    DROP TABLE IF EXISTS #gr_post;   -- the inventory transaction each goods receipt posted
    SELECT reference_id AS gr_number, MIN(CASE WHEN txn_timestamp LIKE N'[12][0-9][0-9][0-9]-%' THEN TRY_CONVERT(DATE, LEFT(txn_timestamp, 10), 23)
                                               ELSE clean.fn_to_date(txn_timestamp) END) AS posted_date
    INTO #gr_post
    FROM raw.erp_inventory_transactions WHERE reference_type = N'GR'
    GROUP BY reference_id;

    DROP TABLE IF EXISTS #po_dates;
    SELECT po_number, po_line, MIN(clean.fn_to_date(po_date)) AS po_date
    INTO #po_dates FROM raw.erp_purchase_orders GROUP BY po_number, po_line;

    -- Which PO line each receipt belongs to. A receipt whose PO number does not exist (E-GR-04) is matched
    -- back to its PO line when exactly one line fits: same branch and part, last received on that date,
    -- and received at least this quantity (the classic orphan-receipt match).
    DROP TABLE IF EXISTS #gr_po;
    SELECT g.gr_number, g.gr_line, g.po_number, g.po_line, CAST(0 AS BIT) AS matched
    INTO #gr_po
    FROM raw.erp_goods_receipts AS g
    WHERE EXISTS (SELECT 1 FROM #po_dates pd WHERE pd.po_number = g.po_number AND pd.po_line = g.po_line);

    INSERT INTO #gr_po
    SELECT g.gr_number, g.gr_line, m.po_number, m.po_line, 1
    FROM raw.erp_goods_receipts AS g
    LEFT JOIN #gr_post AS gp ON gp.gr_number = g.gr_number
    CROSS APPLY (
        SELECT MIN(o.po_number) AS po_number, MIN(o.po_line) AS po_line
        FROM raw.erp_purchase_orders AS o
        WHERE o.branch_id = g.branch_id AND o.part_id = g.part_id
          AND clean.fn_to_date(o.last_receipt_date) = COALESCE(TRY_CONVERT(DATE, g.receipt_date, 23), gp.posted_date)
          AND TRY_CAST(o.qty_received AS INT) >= TRY_CAST(g.qty_accepted AS INT) + TRY_CAST(g.qty_rejected AS INT)
        HAVING COUNT(DISTINCT o.po_number + N'-' + o.po_line) = 1
    ) AS m
    WHERE NOT EXISTS (SELECT 1 FROM #po_dates pd WHERE pd.po_number = g.po_number AND pd.po_line = g.po_line);

    DROP TABLE IF EXISTS clean.goods_receipt_line;
    SELECT ISNULL(CAST(g.gr_number AS VARCHAR(12)), '') AS gr_number, ISNULL(TRY_CAST(g.gr_line AS SMALLINT), 0) AS gr_line,
           CASE WHEN TRY_CONVERT(DATE, g.receipt_date, 23) >= pd.po_date THEN TRY_CONVERT(DATE, g.receipt_date, 23)
                ELSE gp.posted_date END AS receipt_date,   -- missing or before its PO (E-GR-02/03) -> inventory posting date
           CAST(gx.po_number AS VARCHAR(12)) AS po_number, TRY_CAST(gx.po_line AS SMALLINT) AS po_line,
           CAST(bx.branch_id AS VARCHAR(10)) AS branch_id, CAST(sx.supplier_id AS VARCHAR(10)) AS supplier_id,
           CAST(px.part_id AS VARCHAR(10)) AS part_id, p.part_number,
           TRY_CAST(g.qty_accepted AS INT) + TRY_CAST(g.qty_rejected AS INT) AS qty_received,   -- over-receipt (E-GR-05)
           TRY_CAST(g.qty_accepted AS INT) AS qty_accepted, TRY_CAST(g.qty_rejected AS INT) AS qty_rejected,
           clean.fn_to_money(g.unit_cost_usd) AS unit_cost_usd, NULLIF(g.rejection_reason, N'') AS rejection_reason
    INTO clean.goods_receipt_line
    FROM raw.erp_goods_receipts AS g
    JOIN #gr_po AS gx ON gx.gr_number = g.gr_number AND gx.gr_line = g.gr_line              -- unmatched unknown PO -> not loaded
    JOIN #po_dates AS pd ON pd.po_number = gx.po_number AND pd.po_line = gx.po_line
    LEFT JOIN #gr_post AS gp ON gp.gr_number = g.gr_number
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = g.branch_id
    LEFT JOIN clean.supplier_xref AS sx ON sx.source_supplier_id = g.supplier_id
    LEFT JOIN clean.part_xref AS px ON px.source_part_id = g.part_id
    LEFT JOIN clean.part AS p ON p.part_id = px.part_id
    WHERE NOT EXISTS (SELECT 1 FROM dq.chk_E_GR_01 x WHERE x.record_key = g.gr_number + N'-' + g.gr_line);   -- posted twice
    EXEC (N'ALTER TABLE clean.goods_receipt_line ADD CONSTRAINT PK_clean_goods_receipt_line PRIMARY KEY (gr_number, gr_line)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.erp_goods_receipts', g.gr_number + N'-' + g.gr_line,
           IIF(EXISTS (SELECT 1 FROM dq.chk_E_GR_01 x WHERE x.record_key = g.gr_number + N'-' + g.gr_line), 'E-GR-01', 'E-GR-04'),
           IIF(EXISTS (SELECT 1 FROM dq.chk_E_GR_01 x WHERE x.record_key = g.gr_number + N'-' + g.gr_line),
               N'Receipt posted twice', N'Receipt against a PO that does not exist')
    FROM raw.erp_goods_receipts AS g
    WHERE NOT EXISTS (SELECT 1 FROM clean.goods_receipt_line c WHERE c.gr_number = g.gr_number AND c.gr_line = TRY_CAST(g.gr_line AS SMALLINT));

    DELETE FROM clean.goods_receipt_line
    OUTPUT 'raw.erp_goods_receipts', deleted.gr_number + N'-' + CAST(deleted.gr_line AS NVARCHAR(5)), 'CLEAN-04',
           N'Receipt date missing and no inventory posting to recover it from'
    INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    WHERE receipt_date IS NULL;

    /* =========================================================================================
       PURCHASE ORDER LINES - quantity from value / cost; status and receipt date from receipts
    ========================================================================================= */
    DROP TABLE IF EXISTS #po;
    SELECT o.po_number, TRY_CAST(o.po_line AS SMALLINT) AS po_line,
           ROW_NUMBER() OVER (PARTITION BY o.po_number, o.po_line ORDER BY o._row_number) AS copy_no,
           clean.fn_to_date(o.po_date) AS po_date, bx.branch_id, sx.supplier_id, px.part_id,
           TRY_CAST(o.qty_ordered AS INT) AS qty_ordered, o.unit_of_measure,
           clean.fn_to_money(o.unit_cost_usd) AS unit_cost, clean.fn_to_money(o.line_value_usd) AS line_value,
           o.order_type, clean.fn_to_date(o.promised_date) AS promised_date
    INTO #po
    FROM raw.erp_purchase_orders AS o
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = o.branch_id
    LEFT JOIN clean.supplier_xref AS sx ON sx.source_supplier_id = o.supplier_id   -- duplicate supplier -> real supplier
    LEFT JOIN clean.part_xref AS px ON px.source_part_id = o.part_id;

    DROP TABLE IF EXISTS clean.purchase_order_line;
    WITH rcv AS (
        SELECT po_number, po_line, SUM(qty_received) AS qty_received, MAX(receipt_date) AS last_receipt_date
        FROM clean.goods_receipt_line GROUP BY po_number, po_line
    ), q AS (
        SELECT o.*,
               COALESCE(IIF(o.qty_ordered > 0, o.qty_ordered, NULL),
                        CAST(ROUND(o.line_value / NULLIF(o.unit_cost, 0), 0) AS INT)) AS qty   -- zero / negative (E-PO-06)
        FROM #po AS o WHERE o.copy_no = 1   -- PO line loaded twice (E-PO-01)
    )
    SELECT ISNULL(CAST(q.po_number AS VARCHAR(12)), '') AS po_number, ISNULL(q.po_line, 0) AS po_line,
           q.po_date, CAST(q.branch_id AS VARCHAR(10)) AS branch_id,
           CAST(COALESCE(q.supplier_id, p.primary_supplier_id) AS VARCHAR(10)) AS supplier_id,   -- unknown supplier -> part's primary
           CAST(q.part_id AS VARCHAR(10)) AS part_id, p.part_number,
           q.qty AS qty_ordered, CAST(q.unit_of_measure AS VARCHAR(5)) AS unit_of_measure,
           CAST(q.unit_cost AS DECIMAL(12, 2)) AS unit_cost_usd, CAST(q.qty * q.unit_cost AS DECIMAL(14, 2)) AS line_value_usd,
           CAST(q.order_type AS VARCHAR(20)) AS order_type,
           CASE WHEN q.promised_date >= q.po_date THEN q.promised_date
                ELSE DATEADD(DAY, IIF(q.order_type = N'Emergency' AND s.supplier_type LIKE N'OEM%', 1, s.lead_time_days), q.po_date)
           END AS promised_date,                                   -- missing or before the PO date (E-PO-04/05)
           COALESCE(r.qty_received, 0) AS qty_received, r.last_receipt_date,
           CAST(CASE WHEN COALESCE(r.qty_received, 0) >= q.qty THEN 'Closed'
                     WHEN r.qty_received > 0 THEN 'Partially Received' ELSE 'Open' END AS VARCHAR(20)) AS line_status   -- recomputed (E-PO-08)
    INTO clean.purchase_order_line
    FROM q
    LEFT JOIN clean.part AS p ON p.part_id = q.part_id
    LEFT JOIN clean.supplier AS s ON s.supplier_id = COALESCE(q.supplier_id, p.primary_supplier_id)
    LEFT JOIN rcv AS r ON r.po_number = q.po_number AND r.po_line = q.po_line;
    EXEC (N'ALTER TABLE clean.purchase_order_line ADD CONSTRAINT PK_clean_purchase_order_line PRIMARY KEY (po_number, po_line)');

    /* =========================================================================================
       INVENTORY TRANSACTIONS - balance recomputed from the transactions themselves
    ========================================================================================= */
    DROP TABLE IF EXISTS #it_src;
    SELECT *, clean.fn_canon_part(part_number) AS part_canon INTO #it_src FROM raw.erp_inventory_transactions;

    DROP TABLE IF EXISTS #it;
    SELECT t.txn_id,
           ROW_NUMBER() OVER (PARTITION BY t.txn_id ORDER BY t._row_number) AS copy_no,
           CASE WHEN t.txn_timestamp LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:%'
                THEN TRY_CONVERT(DATETIME2(0), t.txn_timestamp, 120) ELSE clean.fn_to_datetime(t.txn_timestamp) END AS txn_ts,
           bx.branch_id, COALESCE(px.part_id, pn.part_id) AS part_id,
           COALESCE(syn.approved_value, tt.txn_type) AS txn_type,
           TRY_CAST(t.qty AS INT) AS qty, t.unit_of_measure, t.reference_type, t.reference_id,
           clean.fn_to_money(t.unit_cost_usd) AS unit_cost
    INTO #it
    FROM #it_src AS t
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = t.branch_id
    LEFT JOIN clean.part_xref AS px ON px.source_part_id = t.part_id
    LEFT JOIN clean.part AS pn ON pn.part_number = t.part_canon                                 -- missing part (E-IT-06)
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'txn_type' AND syn.source_value COLLATE Latin1_General_BIN2 = t.txn_type COLLATE Latin1_General_BIN2
    LEFT JOIN (VALUES (N'Opening Balance'), (N'Goods Issue'), (N'Goods Issue - Backorder'), (N'Goods Receipt'),
                      (N'Transfer In'), (N'Transfer Out'), (N'Cycle Count Adjustment'), (N'Customer Return')) AS tt (txn_type)
           ON tt.txn_type = t.txn_type;   -- case-insensitive: 'GOODS ISSUE' -> 'Goods Issue'

    -- Missing branch (E-IT-03): the document the transaction posted tells us where it happened
    UPDATE i SET branch_id = COALESCE(s.branch_id, g.branch_id,
                                      (SELECT TOP (1) o.branch_id FROM #it o WHERE o.part_id = i.part_id AND o.branch_id IS NOT NULL
                                         AND o.reference_id = i.reference_id AND o.txn_id <> i.txn_id))
    FROM #it AS i
    LEFT JOIN clean.sales_order_line AS s ON i.reference_type = N'SO' AND s.sales_order_id + N'-' + CAST(s.so_line AS NVARCHAR(5)) = i.reference_id
    LEFT JOIN clean.goods_receipt_line AS g ON i.reference_type = N'GR' AND g.gr_number = i.reference_id
    WHERE i.branch_id IS NULL;

    DROP TABLE IF EXISTS clean.inventory_transaction;
    SELECT ISNULL(CAST(i.txn_id AS VARCHAR(12)), '') AS txn_id, i.txn_ts AS txn_timestamp,
           CAST(i.branch_id AS VARCHAR(10)) AS branch_id, CAST(i.part_id AS VARCHAR(10)) AS part_id, p.part_number,
           CAST(i.txn_type AS VARCHAR(40)) AS txn_type, i.qty, CAST(i.unit_of_measure AS VARCHAR(5)) AS unit_of_measure,
           CAST(i.reference_type AS VARCHAR(20)) AS reference_type, CAST(i.reference_id AS VARCHAR(30)) AS reference_id,
           -- running balance in posting order (txn_id is sequential); fixes negative balances (E-IT-02)
           SUM(i.qty) OVER (PARTITION BY i.branch_id, i.part_id ORDER BY i.txn_id ROWS UNBOUNDED PRECEDING) AS balance_after,
           CAST(i.unit_cost AS DECIMAL(12, 2)) AS unit_cost_usd
    INTO clean.inventory_transaction
    FROM #it AS i
    LEFT JOIN clean.part AS p ON p.part_id = i.part_id
    WHERE i.copy_no = 1 AND i.branch_id IS NOT NULL AND i.part_id IS NOT NULL AND i.qty IS NOT NULL;   -- posted twice (E-IT-01)
    EXEC (N'ALTER TABLE clean.inventory_transaction ADD CONSTRAINT PK_clean_inventory_transaction PRIMARY KEY (txn_id)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT DISTINCT 'raw.erp_inventory_transactions', i.txn_id, 'CLEAN-05', N'Branch or part missing and not recoverable from the posted document'
    FROM #it AS i
    WHERE i.copy_no = 1 AND (i.branch_id IS NULL OR i.part_id IS NULL OR i.qty IS NULL);
END
GO
