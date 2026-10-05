/*
    04_Database/dq/rules.sql
    Data quality rules. One view per rule, named dq.chk_<rule_id>, returning the records that FAIL:
        record_key, failed_value, related_key (duplicates: the record this one duplicates)
    Rule metadata (dimension, severity, action) is merged into dq.rule_catalog at the end of this file.

    Actions tell the clean layer (Step 3) what to do with failing records:
        quarantine - record cannot be trusted or repaired; excluded from the clean layer
        fix        - clean layer corrects or standardizes the value; record kept
        flag       - record kept as is; issue reported to the Data Steward

    Notes on SQL Server behaviour these rules account for:
      - The database collation is case-insensitive, so case checks use COLLATE Latin1_General_CS_AS.
      - Letter ranges in LIKE ('[A-Z]') use Latin1_General_BIN2: in a case-sensitive collation the range
        still matches lower case b-z.
      - '=', GROUP BY, and LIKE ignore trailing spaces in every collation, so padding is checked with
        dq.fn_has_padding, and comparisons that must see it append a marker character.

    Deployed and executed by 04_Database/run_dq.py.
*/

/* =============================================================================================
   MASTER DATA - Branch
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_BR_01 AS
SELECT branch_id AS record_key, CAST(N'region is blank' AS NVARCHAR(400)) AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master WHERE region IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_BR_02 AS
SELECT branch_id AS record_key, region AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master
WHERE region IS NOT NULL AND region COLLATE Latin1_General_CS_AS NOT IN (N'East', N'North', N'Central', N'Southwest');
GO
CREATE OR ALTER VIEW dq.chk_M_BR_03 AS
SELECT branch_id AS record_key, state AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master
WHERE NOT (state COLLATE Latin1_General_BIN2 LIKE N'[A-Z][A-Z]' AND dq.fn_has_padding(state) = 0);
GO
CREATE OR ALTER VIEW dq.chk_M_BR_04 AS
SELECT branch_id AS record_key, N'[' + branch_name + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master
WHERE dq.fn_has_padding(branch_name) = 1
   OR (branch_name COLLATE Latin1_General_CS_AS = UPPER(branch_name) AND LEN(branch_name) > 3)
   OR branch_name LIKE N'% Branch';
GO
CREATE OR ALTER VIEW dq.chk_M_BR_05 AS
WITH n AS (
    SELECT branch_id,
           REPLACE(REPLACE(N' ' + dq.fn_norm_name(branch_name) + N' ', N' BRANCH ', N' '), N' STORE ', N' ') AS nm
    FROM raw.master_branch_master
), g AS (
    SELECT branch_id, nm, MIN(branch_id) OVER (PARTITION BY LTRIM(RTRIM(nm))) AS survivor FROM n
)
SELECT branch_id AS record_key, N'same branch as ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE branch_id <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_M_BR_06 AS
SELECT branch_id AS record_key, open_date AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master WHERE open_date IS NOT NULL AND dq.fn_is_iso_date(open_date) = 0;
GO
CREATE OR ALTER VIEW dq.chk_M_BR_07 AS
SELECT branch_id AS record_key, N'is_active = ' + is_active AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_branch_master WHERE is_active = N'N';
GO

/* =============================================================================================
   MASTER DATA - Product family
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_PF_01 AS
WITH n AS (
    SELECT product_family_id, REPLACE(dq.fn_norm_name(product_family_name), N' ', N'') AS nm
    FROM raw.master_product_family_master WHERE product_family_id IS NOT NULL
)
SELECT d.product_family_id AS record_key, N'duplicates ' + s.product_family_id AS failed_value, s.product_family_id AS related_key
FROM n AS d
CROSS APPLY (   -- earliest family whose normalized name equals or starts with this one (e.g. POWERSYS -> POWERSYSTEMS)
    SELECT TOP (1) o.product_family_id FROM n AS o
    WHERE o.product_family_id < d.product_family_id
      AND (o.nm = d.nm OR (LEN(d.nm) >= 5 AND o.nm LIKE d.nm + N'%'))
    ORDER BY o.product_family_id
) AS s;
GO
CREATE OR ALTER VIEW dq.chk_M_PF_02 AS
SELECT product_family_id AS record_key, product_family_name AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master WHERE product_family_id IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PF_03 AS
SELECT product_family_id AS record_key, N'business_segment is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master WHERE business_segment IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PF_04 AS
SELECT product_family_id AS record_key, business_segment AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master
WHERE business_segment IS NOT NULL
  AND business_segment COLLATE Latin1_General_CS_AS NOT IN
      (N'Construction Industries', N'Resource Industries', N'Energy & Transportation');
GO
CREATE OR ALTER VIEW dq.chk_M_PF_05 AS   -- business rule: mining families belong to Resource Industries
SELECT product_family_id AS record_key, product_family_name + N' -> ' + business_segment AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master
WHERE product_family_name LIKE N'%Mining%' AND business_segment <> N'Resource Industries';
GO
CREATE OR ALTER VIEW dq.chk_M_PF_06 AS
SELECT product_family_id AS record_key, is_active AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master
WHERE is_active IS NULL OR is_active COLLATE Latin1_General_CS_AS NOT IN (N'Y', N'N') OR is_active = N'N';
GO
CREATE OR ALTER VIEW dq.chk_M_PF_07 AS
SELECT product_family_id AS record_key, N'planning_owner is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_family_master WHERE planning_owner IS NULL;
GO

/* =============================================================================================
   MASTER DATA - Product category
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_PC_01 AS
SELECT product_category_id AS record_key, N'product_family_id is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_category_master WHERE product_family_id IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PC_02 AS
SELECT c.product_category_id AS record_key, c.product_family_id AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_category_master AS c
WHERE c.product_family_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM raw.master_product_family_master f WHERE f.product_family_id = c.product_family_id);
GO
CREATE OR ALTER VIEW dq.chk_M_PC_03 AS
SELECT c.product_category_id AS record_key, c.product_family_id + N' is a duplicate of ' + d.related_key AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_category_master AS c
JOIN dq.chk_M_PF_01 AS d ON d.record_key = c.product_family_id;
GO
CREATE OR ALTER VIEW dq.chk_M_PC_04 AS   -- business rule: mining categories belong to a mining family
SELECT c.product_category_id AS record_key, c.product_category_name + N' -> ' + f.product_family_name AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_category_master AS c
JOIN raw.master_product_family_master AS f ON f.product_family_id = c.product_family_id
WHERE c.product_category_name LIKE N'%Mining%' AND f.product_family_name NOT LIKE N'%Mining%';
GO
CREATE OR ALTER VIEW dq.chk_M_PC_05 AS
SELECT product_category_id AS record_key, product_category_name AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_category_master
WHERE product_category_name LIKE N'%(%' OR dq.fn_has_padding(product_category_name) = 1
   OR (product_category_name COLLATE Latin1_General_CS_AS = UPPER(product_category_name) AND LEN(product_category_name) <= 4);
GO

/* =============================================================================================
   MASTER DATA - Product (equipment models)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_PR_01 AS
SELECT product_id AS record_key, N'[' + product_name + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_master
WHERE NOT (product_name COLLATE Latin1_General_BIN2 LIKE N'CAT [0-9A-Z]%') OR dq.fn_has_padding(product_name) = 1;
GO
CREATE OR ALTER VIEW dq.chk_M_PR_02 AS
SELECT product_id AS record_key, N'criticality is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_master WHERE criticality IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PR_03 AS
SELECT product_id AS record_key, criticality AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_master
WHERE criticality IS NOT NULL AND criticality COLLATE Latin1_General_CS_AS NOT IN (N'High', N'Medium', N'Low');
GO
CREATE OR ALTER VIEW dq.chk_M_PR_04 AS
SELECT p.product_id AS record_key, p.product_category_id AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_product_master AS p
WHERE NOT EXISTS (SELECT 1 FROM raw.master_product_category_master c WHERE c.product_category_id = p.product_category_id);
GO
CREATE OR ALTER VIEW dq.chk_M_PR_05 AS
WITH n AS (
    SELECT product_id,
           LTRIM(RTRIM(REPLACE(REPLACE(N' ' + dq.fn_norm_name(product_name) + N' ', N' CATERPILLAR ', N' '), N'CATERPILLAR', N''))) AS nm
    FROM raw.master_product_master
), g AS (SELECT product_id, MIN(product_id) OVER (PARTITION BY nm) AS survivor FROM n)
SELECT product_id AS record_key, N'same model as ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE product_id <> survivor;
GO

/* =============================================================================================
   MASTER DATA - Supplier
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_SU_01 AS   -- the duplicate-supplier case study
WITH n AS (
    SELECT supplier_id, supplier_name, dq.fn_norm_name(supplier_name) AS nm, UPPER(LTRIM(RTRIM(city))) AS city
    FROM raw.master_supplier_master
), g AS (SELECT n.*, MIN(supplier_id) OVER (PARTITION BY nm, city) AS survivor FROM n)
SELECT supplier_id AS record_key, N'[' + supplier_name + N'] duplicates ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE supplier_id <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_M_SU_02 AS
SELECT supplier_id AS record_key, N'lead_time_days is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master WHERE lead_time_days IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_SU_03 AS
SELECT supplier_id AS record_key, lead_time_days AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master WHERE lead_time_days IS NOT NULL AND TRY_CAST(lead_time_days AS INT) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_SU_04 AS
SELECT supplier_id AS record_key, lead_time_days AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master WHERE TRY_CAST(lead_time_days AS INT) <= 0;
GO
CREATE OR ALTER VIEW dq.chk_M_SU_05 AS
SELECT supplier_id AS record_key, on_time_delivery_pct AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master
WHERE TRY_CAST(on_time_delivery_pct AS DECIMAL(9, 2)) NOT BETWEEN 0 AND 100
   OR (on_time_delivery_pct IS NOT NULL AND TRY_CAST(on_time_delivery_pct AS DECIMAL(9, 2)) IS NULL);
GO
CREATE OR ALTER VIEW dq.chk_M_SU_06 AS
SELECT supplier_id AS record_key, supplier_tier AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master
WHERE supplier_tier IS NULL OR supplier_tier COLLATE Latin1_General_CS_AS NOT IN (N'Tier 1', N'Tier 2', N'Tier 3');
GO
CREATE OR ALTER VIEW dq.chk_M_SU_07 AS
SELECT supplier_id AS record_key, state AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master
WHERE NOT (state COLLATE Latin1_General_BIN2 LIKE N'[A-Z][A-Z]' AND dq.fn_has_padding(state) = 0);
GO
CREATE OR ALTER VIEW dq.chk_M_SU_08 AS
SELECT s.supplier_id AS record_key, N'inactive but referenced by parts or purchase orders' AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_supplier_master AS s
WHERE s.is_active = N'N'
  AND (EXISTS (SELECT 1 FROM raw.master_part_master p WHERE p.primary_supplier_id = s.supplier_id)
       OR EXISTS (SELECT 1 FROM raw.erp_purchase_orders o WHERE o.supplier_id = s.supplier_id));
GO

/* =============================================================================================
   MASTER DATA - Equipment
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_EQ_01 AS
SELECT e.equipment_id AS record_key, COALESCE(e.home_branch_id, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master AS e
WHERE NOT EXISTS (SELECT 1 FROM raw.master_branch_master b
                  WHERE b.branch_id = e.home_branch_id COLLATE Latin1_General_CS_AS);
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_02 AS
SELECT equipment_id AS record_key, N'serial_number is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master WHERE serial_number IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_03 AS
SELECT equipment_id AS record_key, N'[' + serial_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master
WHERE serial_number COLLATE Latin1_General_CS_AS <> UPPER(serial_number) OR dq.fn_has_padding(serial_number) = 1;
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_04 AS
SELECT equipment_id AS record_key, service_meter_hours AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master WHERE TRY_CAST(service_meter_hours AS INT) < 0;
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_05 AS
SELECT equipment_id AS record_key, model_year AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master
WHERE TRY_CAST(model_year AS INT) IS NULL OR TRY_CAST(model_year AS INT) NOT BETWEEN 1990 AND YEAR(SYSUTCDATETIME()) + 1;
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_06 AS
SELECT equipment_id AS record_key, equipment_model AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_equipment_master
WHERE NOT (equipment_model COLLATE Latin1_General_BIN2 LIKE N'CAT [0-9A-Z]%');
GO
CREATE OR ALTER VIEW dq.chk_M_EQ_07 AS
WITH g AS (
    SELECT equipment_id, MIN(equipment_id) OVER (PARTITION BY UPPER(LTRIM(RTRIM(serial_number)))) AS survivor
    FROM raw.master_equipment_master WHERE serial_number IS NOT NULL
)
SELECT equipment_id AS record_key, N'same serial as ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE equipment_id <> survivor;
GO

/* =============================================================================================
   MASTER DATA - Part
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_M_PT_01 AS
SELECT part_id AS record_key, N'[' + part_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master WHERE dq.fn_is_part_number(part_number) = 0;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_02 AS
SELECT part_id AS record_key, N'[' + part_description + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master
WHERE part_description COLLATE Latin1_General_CS_AS <> UPPER(part_description)
   OR part_description LIKE N'%  %' OR part_description LIKE N'%FLTR%' OR part_description LIKE N'%ASSY%';
GO
CREATE OR ALTER VIEW dq.chk_M_PT_03 AS
SELECT part_id AS record_key, N'part_category is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master WHERE part_category IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_04 AS
SELECT part_id AS record_key, N'criticality is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master WHERE criticality IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_05 AS
SELECT part_id AS record_key, COALESCE(unit_cost_usd, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master
WHERE unit_cost_usd IS NULL OR TRY_CAST(REPLACE(REPLACE(unit_cost_usd, N'$', N''), N',', N'') AS DECIMAL(14, 2)) <= 0;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_06 AS
SELECT part_id AS record_key, unit_cost_usd AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master
WHERE unit_cost_usd IS NOT NULL AND TRY_CAST(unit_cost_usd AS DECIMAL(14, 2)) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_07 AS
SELECT p.part_id AS record_key, COALESCE(p.primary_supplier_id, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master AS p
WHERE NOT EXISTS (SELECT 1 FROM raw.master_supplier_master s WHERE s.supplier_id = p.primary_supplier_id);
GO
CREATE OR ALTER VIEW dq.chk_M_PT_08 AS
SELECT part_id AS record_key, unit_of_measure AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master
WHERE unit_of_measure IS NULL OR unit_of_measure COLLATE Latin1_General_CS_AS NOT IN (N'EA', N'GAL');
GO
CREATE OR ALTER VIEW dq.chk_M_PT_09 AS
SELECT part_id AS record_key, created_date AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master WHERE created_date IS NOT NULL AND dq.fn_is_iso_date(created_date) = 0;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_10 AS
WITH g AS (
    SELECT part_id, part_number, MIN(part_id) OVER (PARTITION BY dq.fn_norm_part(part_number)) AS survivor
    FROM raw.master_part_master
)
SELECT part_id AS record_key, N'[' + part_number + N'] same part as ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE part_id <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_M_PT_11 AS
SELECT part_id AS record_key, part_description AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.master_part_master WHERE part_description LIKE N'%SUPERSEDED%' AND is_active = N'Y';
GO

/* =============================================================================================
   ERP - Sales orders  (record key: sales_order_id-so_line)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_E_SO_01 AS
SELECT sales_order_id + N'-' + so_line AS record_key, CONCAT(COUNT(*), N' copies') AS failed_value,
       sales_order_id + N'-' + so_line AS related_key
FROM raw.erp_sales_orders GROUP BY sales_order_id, so_line HAVING COUNT(*) > 1;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_02 AS
SELECT sales_order_id + N'-' + so_line AS record_key, N'branch_id is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE branch_id IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_03 AS
SELECT s.sales_order_id + N'-' + s.so_line AS record_key, s.part_id AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders AS s
WHERE NOT EXISTS (SELECT 1 FROM raw.master_part_master p WHERE p.part_id = s.part_id);
GO
CREATE OR ALTER VIEW dq.chk_E_SO_04 AS
SELECT sales_order_id + N'-' + so_line AS record_key, N'[' + part_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE dq.fn_is_part_number(part_number) = 0;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_05 AS
SELECT sales_order_id + N'-' + so_line AS record_key, COALESCE(qty_ordered, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE qty_ordered IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_06 AS
SELECT sales_order_id + N'-' + so_line AS record_key, qty_ordered AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE TRY_CAST(qty_ordered AS INT) <= 0;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_07 AS
SELECT sales_order_id + N'-' + so_line AS record_key, order_timestamp AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE dq.fn_is_iso_date(order_timestamp) = 0;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_08 AS
SELECT sales_order_id + N'-' + so_line AS record_key, order_timestamp AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE TRY_CONVERT(DATETIME2, order_timestamp, 120) > _loaded_at;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_09 AS
SELECT sales_order_id + N'-' + so_line AS record_key, unit_price_usd AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders WHERE TRY_CAST(unit_price_usd AS DECIMAL(14, 2)) <= 0 OR unit_price_usd IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_10 AS
SELECT sales_order_id + N'-' + so_line AS record_key,
       CONCAT(qty_ordered, N' x ', unit_price_usd, N' <> ', extended_price_usd) AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders
WHERE ABS(TRY_CAST(extended_price_usd AS DECIMAL(14, 2))
          - TRY_CAST(qty_ordered AS INT) * TRY_CAST(unit_price_usd AS DECIMAL(14, 2))) > 0.01;
GO
CREATE OR ALTER VIEW dq.chk_E_SO_11 AS   -- same customer ID, different spelling of the name
WITH names AS (
    SELECT customer_id, CONCAT(customer_name, N'|') COLLATE Latin1_General_BIN2 AS nm, COUNT(*) AS n
    FROM raw.erp_sales_orders GROUP BY customer_id, CONCAT(customer_name, N'|') COLLATE Latin1_General_BIN2
), main AS (
    SELECT customer_id, nm, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY n DESC) AS rk FROM names
)
SELECT s.sales_order_id + N'-' + s.so_line AS record_key, N'[' + s.customer_name + N'] vs [' + LEFT(m.nm, LEN(m.nm) - 1) + N']' AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_sales_orders AS s
JOIN main AS m ON m.customer_id = s.customer_id AND m.rk = 1
WHERE CONCAT(s.customer_name, N'|') COLLATE Latin1_General_BIN2 <> m.nm;
GO

/* =============================================================================================
   ERP - Demand transactions  (record key: demand_id)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_E_DM_01 AS
WITH g AS (
    SELECT demand_id, MIN(demand_id) OVER (PARTITION BY sales_order_id, so_line) AS survivor
    FROM raw.erp_demand_transactions
)
SELECT demand_id AS record_key, N'duplicate of ' + survivor AS failed_value, survivor AS related_key
FROM g WHERE demand_id <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_E_DM_02 AS
SELECT demand_id AS record_key, N'qty_demanded is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_demand_transactions WHERE qty_demanded IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_DM_03 AS
SELECT d.demand_id AS record_key, COALESCE(d.part_id, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_demand_transactions AS d
WHERE NOT EXISTS (SELECT 1 FROM raw.master_part_master p WHERE p.part_id = d.part_id);
GO
CREATE OR ALTER VIEW dq.chk_E_DM_04 AS
SELECT demand_id AS record_key, COALESCE(demand_date, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_demand_transactions
WHERE dq.fn_is_iso_date(demand_date) = 0 OR TRY_CONVERT(DATE, demand_date, 23) < '2000-01-01';
GO
CREATE OR ALTER VIEW dq.chk_E_DM_05 AS
SELECT demand_id AS record_key, CONCAT(qty_filled_from_stock, N' filled > ', qty_demanded, N' demanded') AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_demand_transactions
WHERE TRY_CAST(qty_filled_from_stock AS INT) > TRY_CAST(qty_demanded AS INT);
GO
CREATE OR ALTER VIEW dq.chk_E_DM_06 AS
SELECT d.demand_id AS record_key, COALESCE(d.branch_id, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_demand_transactions AS d
WHERE NOT EXISTS (SELECT 1 FROM raw.master_branch_master b WHERE b.branch_id = d.branch_id COLLATE Latin1_General_CS_AS);
GO

/* =============================================================================================
   ERP - Purchase orders  (record key: po_number-po_line)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_E_PO_01 AS
SELECT po_number + N'-' + po_line AS record_key, CONCAT(COUNT(*), N' copies') AS failed_value, po_number + N'-' + po_line AS related_key
FROM raw.erp_purchase_orders GROUP BY po_number, po_line HAVING COUNT(*) > 1;
GO
CREATE OR ALTER VIEW dq.chk_E_PO_02 AS
SELECT o.po_number + N'-' + o.po_line AS record_key, COALESCE(o.supplier_id, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders AS o
WHERE NOT EXISTS (SELECT 1 FROM raw.master_supplier_master s WHERE s.supplier_id = o.supplier_id);
GO
CREATE OR ALTER VIEW dq.chk_E_PO_03 AS
SELECT o.po_number + N'-' + o.po_line AS record_key, o.supplier_id + N' is a duplicate of ' + d.related_key AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders AS o
JOIN dq.chk_M_SU_01 AS d ON d.record_key = o.supplier_id;
GO
CREATE OR ALTER VIEW dq.chk_E_PO_04 AS
SELECT po_number + N'-' + po_line AS record_key, N'promised_date is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders WHERE promised_date IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_PO_05 AS
SELECT po_number + N'-' + po_line AS record_key, promised_date + N' < ' + po_date AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders
WHERE TRY_CONVERT(DATE, promised_date, 23) < TRY_CONVERT(DATE, po_date, 23);
GO
CREATE OR ALTER VIEW dq.chk_E_PO_06 AS
SELECT po_number + N'-' + po_line AS record_key, qty_ordered AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders WHERE TRY_CAST(qty_ordered AS INT) <= 0;
GO
CREATE OR ALTER VIEW dq.chk_E_PO_07 AS
SELECT po_number + N'-' + po_line AS record_key, unit_cost_usd AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders WHERE unit_cost_usd IS NOT NULL AND TRY_CAST(unit_cost_usd AS DECIMAL(14, 2)) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_PO_08 AS
SELECT po_number + N'-' + po_line AS record_key, CONCAT(N'Closed with ', qty_received, N' of ', qty_ordered, N' received') AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders
WHERE line_status = N'Closed' AND TRY_CAST(qty_received AS INT) < TRY_CAST(qty_ordered AS INT);
GO
CREATE OR ALTER VIEW dq.chk_E_PO_09 AS
SELECT po_number + N'-' + po_line AS record_key, CONCAT(qty_received, N' received, no receipt date') AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_purchase_orders WHERE TRY_CAST(qty_received AS INT) > 0 AND last_receipt_date IS NULL;
GO

/* =============================================================================================
   ERP - Goods receipts  (record key: gr_number-gr_line)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_E_GR_01 AS
WITH g AS (
    SELECT gr_number, gr_line,
           MIN(gr_number) OVER (PARTITION BY po_number, po_line, part_id, qty_received, qty_accepted, unit_cost_usd,
                                             COALESCE(receipt_date, N'')) AS survivor
    FROM raw.erp_goods_receipts
)
SELECT gr_number + N'-' + gr_line AS record_key, N'duplicate of ' + survivor AS failed_value, survivor + N'-' + gr_line AS related_key
FROM g WHERE gr_number <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_E_GR_02 AS
SELECT gr_number + N'-' + gr_line AS record_key, N'receipt_date is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_goods_receipts WHERE receipt_date IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_GR_03 AS
SELECT g.gr_number + N'-' + g.gr_line AS record_key, g.receipt_date + N' < PO ' + o.po_date AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_goods_receipts AS g
CROSS APPLY (SELECT MIN(po_date) AS po_date FROM raw.erp_purchase_orders p
             WHERE p.po_number = g.po_number AND p.po_line = g.po_line) AS o
WHERE TRY_CONVERT(DATE, g.receipt_date, 23) < TRY_CONVERT(DATE, o.po_date, 23);
GO
CREATE OR ALTER VIEW dq.chk_E_GR_04 AS
SELECT g.gr_number + N'-' + g.gr_line AS record_key, g.po_number AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_goods_receipts AS g
WHERE NOT EXISTS (SELECT 1 FROM raw.erp_purchase_orders p WHERE p.po_number = g.po_number);
GO
CREATE OR ALTER VIEW dq.chk_E_GR_05 AS   -- total received on a PO line exceeds what was ordered
WITH rcv AS (
    SELECT g.*, SUM(TRY_CAST(g.qty_received AS INT)) OVER (PARTITION BY g.po_number, g.po_line) AS total_received
    FROM raw.erp_goods_receipts AS g
    WHERE NOT EXISTS (SELECT 1 FROM dq.chk_E_GR_01 d WHERE d.record_key = g.gr_number + N'-' + g.gr_line)
)
SELECT r.gr_number + N'-' + r.gr_line AS record_key,
       CONCAT(r.qty_received, N' received (', r.total_received, N' total) > ', o.qty_ordered, N' ordered') AS failed_value,
       CAST(NULL AS NVARCHAR(200)) AS related_key
FROM rcv AS r
CROSS APPLY (SELECT MAX(TRY_CAST(qty_ordered AS INT)) AS qty_ordered FROM raw.erp_purchase_orders p
             WHERE p.po_number = r.po_number AND p.po_line = r.po_line) AS o
WHERE o.qty_ordered > 0                       -- an invalid PO quantity is caught by E-PO-06, not here
  AND r.total_received > o.qty_ordered
  AND (TRY_CAST(r.qty_received AS INT) > o.qty_ordered          -- this receipt alone is too much, or
       OR TRY_CAST(r.qty_received AS INT) = (SELECT MAX(TRY_CAST(x.qty_received AS INT)) FROM raw.erp_goods_receipts x
                                             WHERE x.po_number = r.po_number AND x.po_line = r.po_line));  -- the largest one

GO
CREATE OR ALTER VIEW dq.chk_E_GR_06 AS
SELECT gr_number + N'-' + gr_line AS record_key, N'[' + part_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_goods_receipts WHERE dq.fn_is_part_number(part_number) = 0;
GO

/* =============================================================================================
   ERP - Inventory transactions  (record key: txn_id)
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_E_IT_01 AS
SELECT txn_id AS record_key, CONCAT(COUNT(*), N' copies') AS failed_value, txn_id AS related_key
FROM raw.erp_inventory_transactions GROUP BY txn_id HAVING COUNT(*) > 1;
GO
CREATE OR ALTER VIEW dq.chk_E_IT_02 AS
SELECT txn_id AS record_key, balance_after AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_inventory_transactions WHERE TRY_CAST(balance_after AS INT) < 0;
GO
CREATE OR ALTER VIEW dq.chk_E_IT_03 AS
SELECT txn_id AS record_key, N'branch_id is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_inventory_transactions WHERE branch_id IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_E_IT_04 AS
SELECT txn_id AS record_key, txn_type AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_inventory_transactions
WHERE txn_type IS NULL OR txn_type COLLATE Latin1_General_CS_AS NOT IN
      (N'Opening Balance', N'Goods Issue', N'Goods Issue - Backorder', N'Goods Receipt', N'Transfer In',
       N'Transfer Out', N'Cycle Count Adjustment', N'Customer Return');
GO
CREATE OR ALTER VIEW dq.chk_E_IT_05 AS
SELECT txn_id AS record_key, txn_timestamp AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_inventory_transactions WHERE dq.fn_is_iso_date(txn_timestamp) = 0;
GO
CREATE OR ALTER VIEW dq.chk_E_IT_06 AS
SELECT txn_id AS record_key, N'part_id is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.erp_inventory_transactions WHERE part_id IS NULL;
GO

/* =============================================================================================
   BUSINESS FILES - Safety stock targets (Excel grid; record key: sheet!excel_row)
   Layout: row 4 header, then per branch a block of part rows, a 'Total <branch>' row, a blank row.
   Columns: c01 branch (merged - first row only), c02 part #, c03 SS, c04 ROP, c05 max, c06 old SS (hidden),
            c07 approved by, c08 comments
============================================================================================= */
CREATE OR ALTER VIEW dq.v_bf_safety_stock_rows AS
SELECT sheet_name, TRY_CAST(excel_row AS INT) AS excel_row, sheet_name + N'!' + excel_row AS record_key,
       COALESCE(c01, b.branch) AS branch, c02 AS part_number, c03 AS ss, c04 AS rop, c05 AS max_qty, c08 AS comments
FROM raw.bf_safety_stock_targets_fy2026_final AS r
OUTER APPLY (   -- branch name is only in the first row of each merged block: carry it down
    SELECT TOP (1) p.c01 AS branch FROM raw.bf_safety_stock_targets_fy2026_final p
    WHERE p.sheet_name = r.sheet_name AND TRY_CAST(p.excel_row AS INT) < TRY_CAST(r.excel_row AS INT)
      AND p.c01 IS NOT NULL
    ORDER BY TRY_CAST(p.excel_row AS INT) DESC
) AS b
WHERE TRY_CAST(excel_row AS INT) > 4 AND c02 IS NOT NULL AND COALESCE(c01, N'') NOT LIKE N'Total %';
GO
CREATE OR ALTER VIEW dq.chk_B_SS_01 AS
SELECT record_key, ss AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE ss IS NOT NULL AND TRY_CAST(ss AS INT) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_B_SS_02 AS
SELECT record_key, N'safety stock is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE ss IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_B_SS_03 AS
SELECT record_key, CONCAT(N'SS ', ss, N' > ROP ', rop) AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE TRY_CAST(ss AS INT) > TRY_CAST(rop AS INT);
GO
CREATE OR ALTER VIEW dq.chk_B_SS_04 AS
SELECT record_key, CONCAT(N'max ', max_qty, N' < ROP ', rop) AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE TRY_CAST(max_qty AS INT) < TRY_CAST(rop AS INT);
GO
CREATE OR ALTER VIEW dq.chk_B_SS_05 AS
SELECT record_key, N'[' + part_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE dq.fn_is_part_number(part_number) = 0;
GO
CREATE OR ALTER VIEW dq.chk_B_SS_06 AS
SELECT r.record_key, r.part_number AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows AS r
WHERE NOT EXISTS (SELECT 1 FROM raw.master_part_master p WHERE dq.fn_norm_part(p.part_number) = dq.fn_norm_part(r.part_number));
GO
CREATE OR ALTER VIEW dq.chk_B_SS_07 AS
WITH g AS (
    SELECT record_key, branch, part_number, excel_row,
           FIRST_VALUE(record_key) OVER (PARTITION BY sheet_name, branch, dq.fn_norm_part(part_number) ORDER BY excel_row) AS survivor
    FROM dq.v_bf_safety_stock_rows
)
SELECT record_key, branch + N' ' + part_number + N' listed twice' AS failed_value, survivor AS related_key
FROM g WHERE record_key <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_B_SS_08 AS
SELECT record_key, comments AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_safety_stock_rows WHERE comments IS NOT NULL;
GO

/* =============================================================================================
   BUSINESS FILES - Inventory policy matrix (record key: sheet!excel_row)
   Rows 6-17: c01 category, then per criticality (High c02-c05, Medium c06-c09, Low c10-c13):
   service level, review days, min DOS, max DOS
============================================================================================= */
CREATE OR ALTER VIEW dq.v_bf_policy_cells AS
SELECT r.sheet_name + N'!' + r.excel_row AS record_key, r.c01 AS category, v.criticality, v.metric, v.val
FROM raw.bf_inventory_policy_matrix AS r
CROSS APPLY (VALUES
    (N'High', N'service_level', r.c02), (N'High', N'review_days', r.c03), (N'High', N'min_dos', r.c04), (N'High', N'max_dos', r.c05),
    (N'Medium', N'service_level', r.c06), (N'Medium', N'review_days', r.c07), (N'Medium', N'min_dos', r.c08), (N'Medium', N'max_dos', r.c09),
    (N'Low', N'service_level', r.c10), (N'Low', N'review_days', r.c11), (N'Low', N'min_dos', r.c12), (N'Low', N'max_dos', r.c13)
) AS v (criticality, metric, val)
WHERE TRY_CAST(r.excel_row AS INT) BETWEEN 6 AND 17;
GO
CREATE OR ALTER VIEW dq.chk_B_IP_01 AS
SELECT DISTINCT r.sheet_name + N'!' + r.excel_row AS record_key, r.c01 AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_inventory_policy_matrix AS r
WHERE TRY_CAST(r.excel_row AS INT) BETWEEN 6 AND 17
  AND NOT EXISTS (SELECT 1 FROM raw.master_part_master p WHERE p.part_category = r.c01);
GO
CREATE OR ALTER VIEW dq.chk_B_IP_02 AS
SELECT record_key, criticality + N' ' + metric + N' = ' + COALESCE(val, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_policy_cells
WHERE val IS NULL OR TRY_CAST(val AS DECIMAL(9, 3)) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_B_IP_03 AS
SELECT record_key, criticality + N' service level = ' + val AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_policy_cells
WHERE metric = N'service_level' AND TRY_CAST(val AS DECIMAL(9, 3)) NOT BETWEEN 0.5 AND 1;
GO
CREATE OR ALTER VIEW dq.chk_B_IP_04 AS
SELECT mn.record_key, mn.criticality + N' min ' + mn.val + N' > max ' + mx.val AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_policy_cells AS mn
JOIN dq.v_bf_policy_cells AS mx ON mx.record_key = mn.record_key AND mx.criticality = mn.criticality AND mx.metric = N'max_dos'
WHERE mn.metric = N'min_dos' AND TRY_CAST(mn.val AS DECIMAL(9, 3)) > TRY_CAST(mx.val AS DECIMAL(9, 3));
GO

/* =============================================================================================
   BUSINESS FILES - Supplier exception list (record key: sheet!excel_row; data from row 4)
   c02 supplier, c05 started, c06 fix ETA, c09 status
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_B_SX_01 AS
SELECT r.sheet_name + N'!' + r.excel_row AS record_key, N'[' + r.c02 + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_supplier_exception_list AS r
WHERE TRY_CAST(r.excel_row AS INT) >= 4
  AND NOT EXISTS (SELECT 1 FROM raw.master_supplier_master s
                  WHERE s.supplier_name COLLATE Latin1_General_BIN2 = r.c02 COLLATE Latin1_General_BIN2
                    AND s.supplier_id < N'S100');
GO
CREATE OR ALTER VIEW dq.chk_B_SX_02 AS
SELECT sheet_name + N'!' + excel_row AS record_key, c02 AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_supplier_exception_list
WHERE TRY_CAST(excel_row AS INT) >= 4 AND (c02 LIKE N'%/%' OR c02 LIKE N'% and %');
GO
CREATE OR ALTER VIEW dq.chk_B_SX_03 AS
SELECT sheet_name + N'!' + excel_row AS record_key, COALESCE(c05, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_supplier_exception_list
WHERE TRY_CAST(excel_row AS INT) >= 4 AND dq.fn_is_iso_date(c05) = 0 AND c03 NOT LIKE N'%combined%';
GO
CREATE OR ALTER VIEW dq.chk_B_SX_04 AS
SELECT sheet_name + N'!' + excel_row AS record_key, COALESCE(c06, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_supplier_exception_list
WHERE TRY_CAST(excel_row AS INT) >= 4 AND c03 NOT LIKE N'%combined%'
  AND (c06 IS NULL OR c06 IN (N'TBD', N'ASAP') OR c06 LIKE N'%waiting%');
GO
CREATE OR ALTER VIEW dq.chk_B_SX_05 AS
SELECT sheet_name + N'!' + excel_row AS record_key, c09 AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.bf_supplier_exception_list
WHERE TRY_CAST(excel_row AS INT) >= 4 AND (c09 IS NULL OR c09 COLLATE Latin1_General_CS_AS NOT IN (N'Open', N'Closed'));
GO

/* =============================================================================================
   BUSINESS FILES - Critical parts list (record key: sheet!excel_row; data from row 4 until separator)
   c01 part number(s), c02 description, c03 machines, c04 branches
============================================================================================= */
CREATE OR ALTER VIEW dq.v_bf_critical_rows AS
SELECT r.sheet_name + N'!' + r.excel_row AS record_key, TRY_CAST(r.excel_row AS INT) AS excel_row,
       r.c01 AS part_number, r.c02 AS description, r.c03 AS machines, r.c04 AS scope
FROM raw.bf_critical_parts_list AS r
WHERE TRY_CAST(r.excel_row AS INT) >= 4
  AND TRY_CAST(r.excel_row AS INT) < COALESCE((SELECT MIN(TRY_CAST(excel_row AS INT)) FROM raw.bf_critical_parts_list
                                               WHERE c01 LIKE N'---%'), 100000);
GO
CREATE OR ALTER VIEW dq.chk_B_CP_01 AS
SELECT record_key, part_number AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_critical_rows WHERE part_number LIKE N'%/%' OR part_number LIKE N'%,%';
GO
CREATE OR ALTER VIEW dq.chk_B_CP_02 AS
SELECT record_key, N'[' + part_number + N']' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_critical_rows
WHERE dq.fn_is_part_number(part_number) = 0 AND part_number NOT LIKE N'%/%';
GO
CREATE OR ALTER VIEW dq.chk_B_CP_03 AS
SELECT c.record_key, c.description + N' vs master ' + p.part_description AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_critical_rows AS c
JOIN raw.master_part_master AS p ON dq.fn_norm_part(p.part_number) = dq.fn_norm_part(c.part_number)
WHERE c.description COLLATE Latin1_General_BIN2 <> p.part_description COLLATE Latin1_General_BIN2
  AND p.part_id < N'PT80000';
GO
CREATE OR ALTER VIEW dq.chk_B_CP_04 AS
SELECT record_key, machines AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_critical_rows WHERE machines LIKE N'%,%';
GO
CREATE OR ALTER VIEW dq.chk_B_CP_05 AS
SELECT record_key, COALESCE(scope, N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_bf_critical_rows
WHERE scope IS NULL OR scope COLLATE Latin1_General_CS_AS NOT IN (N'ALL', N'Southwest');
GO
CREATE OR ALTER VIEW dq.chk_B_CP_06 AS
WITH g AS (
    SELECT record_key, part_number,
           FIRST_VALUE(record_key) OVER (PARTITION BY dq.fn_norm_part(part_number) ORDER BY excel_row) AS survivor
    FROM dq.v_bf_critical_rows WHERE part_number NOT LIKE N'%/%'
)
SELECT record_key, part_number + N' listed twice' AS failed_value, survivor AS related_key
FROM g WHERE record_key <> survivor;
GO

/* =============================================================================================
   SHAREPOINT - Forecast overrides (record key: 'Forecast Overrides!' + Excel row)
============================================================================================= */
CREATE OR ALTER VIEW dq.v_sp_overrides AS
SELECT N'Forecast Overrides!' + CAST(_row_number + 1 AS NVARCHAR(10)) AS record_key, *,
       -- adjustment as a percentage: '+40%' -> 40, '0.4' -> 40, '40' -> 40
       CASE WHEN adjustment LIKE N'%[%]' THEN TRY_CAST(REPLACE(REPLACE(adjustment, N'%', N''), N'+', N'') AS DECIMAL(9, 2))
            WHEN ABS(TRY_CAST(adjustment AS DECIMAL(9, 4))) < 1 THEN TRY_CAST(adjustment AS DECIMAL(9, 4)) * 100
            ELSE TRY_CAST(adjustment AS DECIMAL(9, 2)) END AS adjustment_pct
FROM raw.sp_forecast_overrides_export;
GO
CREATE OR ALTER VIEW dq.chk_S_FO_01 AS
SELECT record_key, N'branch is blank' AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_sp_overrides WHERE branch IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_S_FO_02 AS
SELECT record_key, adjustment AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_sp_overrides WHERE ABS(adjustment_pct) > 100 OR adjustment_pct IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_S_FO_03 AS
WITH g AS (
    SELECT record_key, id, branch, scope, forecast_month,
           FIRST_VALUE(record_key) OVER (PARTITION BY branch, scope_type, scope, forecast_month, title
                                         ORDER BY TRY_CAST(id AS INT)) AS survivor
    FROM dq.v_sp_overrides
)
SELECT record_key, branch + N' / ' + scope + N' / ' + forecast_month + N' submitted again' AS failed_value, survivor AS related_key
FROM g WHERE record_key <> survivor;
GO
CREATE OR ALTER VIEW dq.chk_S_FO_04 AS
SELECT record_key, forecast_month AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM dq.v_sp_overrides WHERE forecast_month NOT LIKE N'%[12][0-9][0-9][0-9]%';
GO

/* =============================================================================================
   EXTERNAL DATA
============================================================================================= */
CREATE OR ALTER VIEW dq.chk_X_EI_01 AS
SELECT series_id + N'|' + [date] AS record_key, COALESCE([value], N'(blank)') AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.ext_economic_indicators WHERE TRY_CAST([value] AS DECIMAL(18, 4)) IS NULL;
GO
CREATE OR ALTER VIEW dq.chk_X_EI_02 AS   -- monthly series should not be more than ~2.5 months behind the fetch date
SELECT series_id AS record_key, N'latest observation ' + MAX([date]) AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.ext_economic_indicators
GROUP BY series_id, frequency
HAVING DATEDIFF(DAY, MAX(TRY_CONVERT(DATE, [date], 23)), MAX(TRY_CONVERT(DATE, LEFT(retrieved_at, 10), 23)))
       > CASE WHEN MAX(frequency) = N'Weekly' THEN 21 ELSE 75 END;
GO
CREATE OR ALTER VIEW dq.chk_X_WA_01 AS
SELECT COALESCE(alert_id, N'(blank)') AS record_key, event AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.ext_weather_alerts_active WHERE event LIKE N'%Test%';
GO
CREATE OR ALTER VIEW dq.chk_X_SE_01 AS
SELECT event_id AS record_key, begin_datetime + N' > ' + end_datetime AS failed_value, CAST(NULL AS NVARCHAR(200)) AS related_key
FROM raw.ext_storm_events
WHERE TRY_CONVERT(DATETIME2, begin_datetime) > TRY_CONVERT(DATETIME2, end_datetime);
GO

/* =============================================================================================
   Rule catalogue
============================================================================================= */
MERGE dq.rule_catalog AS t
USING (VALUES
 -- rule_id,   name,                                                            system,          table,                                         column,                 dimension,      severity, action
 ('M-BR-01', N'Branch region is missing',                                      'Master Data', 'raw.master_branch_master',                    'region',               'Completeness', 'High',   'fix'),
 ('M-BR-02', N'Branch region not in allowed list',                             'Master Data', 'raw.master_branch_master',                    'region',               'Validity',     'Medium', 'fix'),
 ('M-BR-03', N'Branch state is not a 2-letter code',                           'Master Data', 'raw.master_branch_master',                    'state',                'Consistency',  'Low',    'fix'),
 ('M-BR-04', N'Branch name formatting (padding, capitals, suffix)',            'Master Data', 'raw.master_branch_master',                    'branch_name',          'Consistency',  'Low',    'fix'),
 ('M-BR-05', N'Duplicate branch under another ID',                             'Master Data', 'raw.master_branch_master',                    'branch_name',          'Uniqueness',   'High',   'fix'),
 ('M-BR-06', N'Branch open date not ISO format',                               'Master Data', 'raw.master_branch_master',                    'open_date',            'Validity',     'Low',    'fix'),
 ('M-BR-07', N'Inactive branch in master',                                     'Master Data', 'raw.master_branch_master',                    'is_active',            'Validity',     'Low',    'flag'),
 ('M-PF-01', N'Duplicate product family under another ID',                     'Master Data', 'raw.master_product_family_master',            'product_family_name',  'Uniqueness',   'High',   'fix'),
 ('M-PF-02', N'Product family ID is missing',                                  'Master Data', 'raw.master_product_family_master',            'product_family_id',    'Completeness', 'High',   'quarantine'),
 ('M-PF-03', N'Business segment is missing',                                   'Master Data', 'raw.master_product_family_master',            'business_segment',     'Completeness', 'Medium', 'fix'),
 ('M-PF-04', N'Business segment not in allowed list',                          'Master Data', 'raw.master_product_family_master',            'business_segment',     'Consistency',  'Low',    'fix'),
 ('M-PF-05', N'Mining family not in Resource Industries segment',              'Master Data', 'raw.master_product_family_master',            'business_segment',     'Validity',     'High',   'fix'),
 ('M-PF-06', N'Active flag invalid or family inactive',                        'Master Data', 'raw.master_product_family_master',            'is_active',            'Validity',     'Low',    'flag'),
 ('M-PF-07', N'Planning owner is missing',                                     'Master Data', 'raw.master_product_family_master',            'planning_owner',       'Completeness', 'Medium', 'flag'),
 ('M-PC-01', N'Category has no product family',                                'Master Data', 'raw.master_product_category_master',          'product_family_id',    'Completeness', 'High',   'fix'),
 ('M-PC-02', N'Category references unknown product family',                    'Master Data', 'raw.master_product_category_master',          'product_family_id',    'Integrity',    'High',   'fix'),
 ('M-PC-03', N'Category references a duplicate product family',                'Master Data', 'raw.master_product_category_master',          'product_family_id',    'Integrity',    'Medium', 'fix'),
 ('M-PC-04', N'Mining category mapped to non-mining family',                   'Master Data', 'raw.master_product_category_master',          'product_family_id',    'Validity',     'High',   'fix'),
 ('M-PC-05', N'Category name not standard',                                    'Master Data', 'raw.master_product_category_master',          'product_category_name','Consistency',  'Low',    'fix'),
 ('M-PR-01', N'Model name not in CAT <model> format',                          'Master Data', 'raw.master_product_master',                   'product_name',         'Consistency',  'Medium', 'fix'),
 ('M-PR-02', N'Product criticality is missing',                                'Master Data', 'raw.master_product_master',                   'criticality',          'Completeness', 'High',   'fix'),
 ('M-PR-03', N'Product criticality not in allowed list',                       'Master Data', 'raw.master_product_master',                   'criticality',          'Validity',     'Medium', 'fix'),
 ('M-PR-04', N'Product references unknown category',                           'Master Data', 'raw.master_product_master',                   'product_category_id',  'Integrity',    'High',   'fix'),
 ('M-PR-05', N'Duplicate product under another ID',                            'Master Data', 'raw.master_product_master',                   'product_name',         'Uniqueness',   'High',   'fix'),
 ('M-SU-01', N'Duplicate supplier under another ID',                           'Master Data', 'raw.master_supplier_master',                  'supplier_name',        'Uniqueness',   'High',   'fix'),
 ('M-SU-02', N'Supplier lead time is missing',                                 'Master Data', 'raw.master_supplier_master',                  'lead_time_days',       'Completeness', 'High',   'fix'),
 ('M-SU-03', N'Supplier lead time is not a number',                            'Master Data', 'raw.master_supplier_master',                  'lead_time_days',       'Validity',     'Medium', 'fix'),
 ('M-SU-04', N'Supplier lead time zero or negative',                           'Master Data', 'raw.master_supplier_master',                  'lead_time_days',       'Validity',     'High',   'fix'),
 ('M-SU-05', N'On-time delivery % outside 0-100',                              'Master Data', 'raw.master_supplier_master',                  'on_time_delivery_pct', 'Validity',     'Medium', 'fix'),
 ('M-SU-06', N'Supplier tier not standard',                                    'Master Data', 'raw.master_supplier_master',                  'supplier_tier',        'Consistency',  'Low',    'fix'),
 ('M-SU-07', N'Supplier state is not a 2-letter code',                         'Master Data', 'raw.master_supplier_master',                  'state',                'Consistency',  'Low',    'fix'),
 ('M-SU-08', N'Inactive supplier still referenced',                            'Master Data', 'raw.master_supplier_master',                  'is_active',            'Integrity',    'High',   'flag'),
 ('M-EQ-01', N'Equipment home branch missing or invalid',                      'Master Data', 'raw.master_equipment_master',                 'home_branch_id',       'Integrity',    'High',   'fix'),
 ('M-EQ-02', N'Equipment serial number is missing',                            'Master Data', 'raw.master_equipment_master',                 'serial_number',        'Completeness', 'High',   'quarantine'),
 ('M-EQ-03', N'Serial number lower case or padded',                            'Master Data', 'raw.master_equipment_master',                 'serial_number',        'Consistency',  'Low',    'fix'),
 ('M-EQ-04', N'Negative service meter hours',                                  'Master Data', 'raw.master_equipment_master',                 'service_meter_hours',  'Validity',     'Medium', 'fix'),
 ('M-EQ-05', N'Impossible model year',                                         'Master Data', 'raw.master_equipment_master',                 'model_year',           'Validity',     'Medium', 'fix'),
 ('M-EQ-06', N'Equipment model not in CAT <model> format',                     'Master Data', 'raw.master_equipment_master',                 'equipment_model',      'Consistency',  'Medium', 'fix'),
 ('M-EQ-07', N'Same serial number loaded twice',                               'Master Data', 'raw.master_equipment_master',                 'serial_number',        'Uniqueness',   'High',   'quarantine'),
 ('M-PT-01', N'Part number not in Caterpillar format',                         'Master Data', 'raw.master_part_master',                      'part_number',          'Validity',     'Medium', 'fix'),
 ('M-PT-02', N'Part description abbreviated or badly formatted',               'Master Data', 'raw.master_part_master',                      'part_description',     'Consistency',  'Low',    'fix'),
 ('M-PT-03', N'Part category is missing',                                      'Master Data', 'raw.master_part_master',                      'part_category',        'Completeness', 'High',   'flag'),
 ('M-PT-04', N'Part criticality is missing',                                   'Master Data', 'raw.master_part_master',                      'criticality',          'Completeness', 'High',   'flag'),
 ('M-PT-05', N'Unit cost missing, zero, or negative',                          'Master Data', 'raw.master_part_master',                      'unit_cost_usd',        'Validity',     'High',   'flag'),
 ('M-PT-06', N'Unit cost stored as text',                                      'Master Data', 'raw.master_part_master',                      'unit_cost_usd',        'Validity',     'Medium', 'fix'),
 ('M-PT-07', N'Primary supplier missing or unknown',                           'Master Data', 'raw.master_part_master',                      'primary_supplier_id',  'Integrity',    'High',   'flag'),
 ('M-PT-08', N'Unit of measure not standard',                                  'Master Data', 'raw.master_part_master',                      'unit_of_measure',      'Consistency',  'Low',    'fix'),
 ('M-PT-09', N'Part created date not ISO format',                              'Master Data', 'raw.master_part_master',                      'created_date',         'Validity',     'Low',    'fix'),
 ('M-PT-10', N'Duplicate part number under another ID',                        'Master Data', 'raw.master_part_master',                      'part_number',          'Uniqueness',   'High',   'fix'),
 ('M-PT-11', N'Superseded part still active',                                  'Master Data', 'raw.master_part_master',                      'is_active',            'Validity',     'Medium', 'flag'),
 ('E-SO-01', N'Sales order line loaded more than once',                        'ERP',         'raw.erp_sales_orders',                        NULL,                   'Uniqueness',   'High',   'fix'),
 ('E-SO-02', N'Sales line has no branch',                                      'ERP',         'raw.erp_sales_orders',                        'branch_id',            'Completeness', 'High',   'quarantine'),
 ('E-SO-03', N'Sales line part not in part master',                            'ERP',         'raw.erp_sales_orders',                        'part_id',              'Integrity',    'High',   'quarantine'),
 ('E-SO-04', N'Sales line part number not standard',                           'ERP',         'raw.erp_sales_orders',                        'part_number',          'Validity',     'Low',    'fix'),
 ('E-SO-05', N'Sales line quantity missing',                                   'ERP',         'raw.erp_sales_orders',                        'qty_ordered',          'Completeness', 'High',   'quarantine'),
 ('E-SO-06', N'Sales line quantity zero or negative',                          'ERP',         'raw.erp_sales_orders',                        'qty_ordered',          'Validity',     'High',   'quarantine'),
 ('E-SO-07', N'Order date not ISO format',                                     'ERP',         'raw.erp_sales_orders',                        'order_timestamp',      'Validity',     'Low',    'fix'),
 ('E-SO-08', N'Order date in the future',                                      'ERP',         'raw.erp_sales_orders',                        'order_timestamp',      'Validity',     'High',   'quarantine'),
 ('E-SO-09', N'Unit price zero or missing',                                    'ERP',         'raw.erp_sales_orders',                        'unit_price_usd',       'Validity',     'Medium', 'flag'),
 ('E-SO-10', N'Extended price differs from qty x price',                       'ERP',         'raw.erp_sales_orders',                        'extended_price_usd',   'Consistency',  'Medium', 'fix'),
 ('E-SO-11', N'Customer name spelled differently for same customer ID',        'ERP',         'raw.erp_sales_orders',                        'customer_name',        'Consistency',  'Low',    'fix'),
 ('E-DM-01', N'Demand transaction duplicated',                                 'ERP',         'raw.erp_demand_transactions',                 NULL,                   'Uniqueness',   'High',   'fix'),
 ('E-DM-02', N'Demand quantity missing',                                       'ERP',         'raw.erp_demand_transactions',                 'qty_demanded',         'Completeness', 'High',   'quarantine'),
 ('E-DM-03', N'Demand part not in part master',                                'ERP',         'raw.erp_demand_transactions',                 'part_id',              'Integrity',    'High',   'quarantine'),
 ('E-DM-04', N'Demand date invalid or missing',                                'ERP',         'raw.erp_demand_transactions',                 'demand_date',          'Validity',     'High',   'quarantine'),
 ('E-DM-05', N'Filled quantity exceeds demanded',                              'ERP',         'raw.erp_demand_transactions',                 'qty_filled_from_stock','Validity',     'Medium', 'fix'),
 ('E-DM-06', N'Demand branch not a valid branch ID',                           'ERP',         'raw.erp_demand_transactions',                 'branch_id',            'Integrity',    'High',   'fix'),
 ('E-PO-01', N'PO line loaded more than once',                                 'ERP',         'raw.erp_purchase_orders',                     NULL,                   'Uniqueness',   'High',   'fix'),
 ('E-PO-02', N'PO supplier not in supplier master',                            'ERP',         'raw.erp_purchase_orders',                     'supplier_id',          'Integrity',    'High',   'flag'),
 ('E-PO-03', N'PO booked to a duplicate supplier record',                      'ERP',         'raw.erp_purchase_orders',                     'supplier_id',          'Integrity',    'Medium', 'fix'),
 ('E-PO-04', N'PO promised date missing',                                      'ERP',         'raw.erp_purchase_orders',                     'promised_date',        'Completeness', 'Medium', 'flag'),
 ('E-PO-05', N'PO promised date before PO date',                               'ERP',         'raw.erp_purchase_orders',                     'promised_date',        'Validity',     'Medium', 'flag'),
 ('E-PO-06', N'PO quantity zero or negative',                                  'ERP',         'raw.erp_purchase_orders',                     'qty_ordered',          'Validity',     'High',   'quarantine'),
 ('E-PO-07', N'PO unit cost stored as text',                                   'ERP',         'raw.erp_purchase_orders',                     'unit_cost_usd',        'Validity',     'Medium', 'fix'),
 ('E-PO-08', N'PO closed but not fully received',                              'ERP',         'raw.erp_purchase_orders',                     'line_status',          'Consistency',  'Medium', 'fix'),
 ('E-PO-09', N'PO received but no receipt date',                               'ERP',         'raw.erp_purchase_orders',                     'last_receipt_date',    'Completeness', 'Medium', 'fix'),
 ('E-GR-01', N'Goods receipt posted twice',                                    'ERP',         'raw.erp_goods_receipts',                      NULL,                   'Uniqueness',   'High',   'quarantine'),
 ('E-GR-02', N'Goods receipt date missing',                                    'ERP',         'raw.erp_goods_receipts',                      'receipt_date',         'Completeness', 'High',   'quarantine'),
 ('E-GR-03', N'Goods receipt dated before its PO',                             'ERP',         'raw.erp_goods_receipts',                      'receipt_date',         'Validity',     'High',   'quarantine'),
 ('E-GR-04', N'Goods receipt against unknown PO',                              'ERP',         'raw.erp_goods_receipts',                      'po_number',            'Integrity',    'High',   'quarantine'),
 ('E-GR-05', N'Received quantity exceeds PO quantity',                         'ERP',         'raw.erp_goods_receipts',                      'qty_received',         'Validity',     'Medium', 'flag'),
 ('E-GR-06', N'Goods receipt part number not standard',                        'ERP',         'raw.erp_goods_receipts',                      'part_number',          'Validity',     'Low',    'fix'),
 ('E-IT-01', N'Inventory transaction posted twice',                            'ERP',         'raw.erp_inventory_transactions',              NULL,                   'Uniqueness',   'High',   'fix'),
 ('E-IT-02', N'Negative on-hand balance',                                      'ERP',         'raw.erp_inventory_transactions',              'balance_after',        'Validity',     'High',   'fix'),
 ('E-IT-03', N'Inventory transaction has no branch',                           'ERP',         'raw.erp_inventory_transactions',              'branch_id',            'Completeness', 'High',   'quarantine'),
 ('E-IT-04', N'Transaction type code not standard',                            'ERP',         'raw.erp_inventory_transactions',              'txn_type',             'Consistency',  'Low',    'fix'),
 ('E-IT-05', N'Transaction date not ISO format',                               'ERP',         'raw.erp_inventory_transactions',              'txn_timestamp',        'Validity',     'Low',    'fix'),
 ('E-IT-06', N'Inventory transaction has no part',                             'ERP',         'raw.erp_inventory_transactions',              'part_id',              'Completeness', 'High',   'quarantine'),
 ('B-SS-01', N'Safety stock is text, not a number',                            'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c03',                  'Validity',     'High',   'flag'),
 ('B-SS-02', N'Safety stock is blank',                                         'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c03',                  'Completeness', 'High',   'flag'),
 ('B-SS-03', N'Safety stock above reorder point',                              'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c03',                  'Validity',     'Medium', 'flag'),
 ('B-SS-04', N'Max below reorder point',                                       'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c05',                  'Validity',     'Medium', 'flag'),
 ('B-SS-05', N'Part number not standard',                                      'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c02',                  'Validity',     'Medium', 'fix'),
 ('B-SS-06', N'Part number not in part master',                                'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c02',                  'Integrity',    'High',   'quarantine'),
 ('B-SS-07', N'Same part listed twice for a branch',                           'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c02',                  'Uniqueness',   'High',   'fix'),
 ('B-SS-08', N'Manual override noted in comments',                             'Business Files','raw.bf_safety_stock_targets_fy2026_final',  'c08',                  'Consistency',  'Low',    'flag'),
 ('B-IP-01', N'Policy category not in part master',                            'Business Files','raw.bf_inventory_policy_matrix',            'c01',                  'Consistency',  'Medium', 'fix'),
 ('B-IP-02', N'Policy value blank or not a number',                            'Business Files','raw.bf_inventory_policy_matrix',            NULL,                   'Validity',     'High',   'fix'),
 ('B-IP-03', N'Service level outside 50-100%',                                 'Business Files','raw.bf_inventory_policy_matrix',            NULL,                   'Validity',     'High',   'fix'),
 ('B-IP-04', N'Minimum days of supply above maximum',                          'Business Files','raw.bf_inventory_policy_matrix',            NULL,                   'Validity',     'High',   'flag'),
 ('B-SX-01', N'Supplier name does not match supplier master',                  'Business Files','raw.bf_supplier_exception_list',            'c02',                  'Integrity',    'Medium', 'fix'),
 ('B-SX-02', N'Several suppliers in one row',                                  'Business Files','raw.bf_supplier_exception_list',            'c02',                  'Validity',     'High',   'quarantine'),
 ('B-SX-03', N'Start date not a date',                                         'Business Files','raw.bf_supplier_exception_list',            'c05',                  'Validity',     'Low',    'fix'),
 ('B-SX-04', N'Resolution ETA not a date',                                     'Business Files','raw.bf_supplier_exception_list',            'c06',                  'Validity',     'Medium', 'flag'),
 ('B-SX-05', N'Status not Open or Closed',                                     'Business Files','raw.bf_supplier_exception_list',            'c09',                  'Consistency',  'Low',    'fix'),
 ('B-CP-01', N'Several part numbers in one cell',                              'Business Files','raw.bf_critical_parts_list',                'c01',                  'Validity',     'High',   'fix'),
 ('B-CP-02', N'Critical part number not standard',                             'Business Files','raw.bf_critical_parts_list',                'c01',                  'Validity',     'Medium', 'fix'),
 ('B-CP-03', N'Critical part description differs from master',                 'Business Files','raw.bf_critical_parts_list',                'c02',                  'Consistency',  'Low',    'fix'),
 ('B-CP-04', N'Machines entered as free-text list',                            'Business Files','raw.bf_critical_parts_list',                'c03',                  'Validity',     'Low',    'flag'),
 ('B-CP-05', N'Branch scope blank or free text',                               'Business Files','raw.bf_critical_parts_list',                'c04',                  'Consistency',  'Medium', 'fix'),
 ('B-CP-06', N'Critical part listed twice',                                    'Business Files','raw.bf_critical_parts_list',                'c01',                  'Uniqueness',   'Medium', 'fix'),
 ('S-FO-01', N'Override has no branch',                                        'SharePoint',  'raw.sp_forecast_overrides_export',            'branch',               'Completeness', 'High',   'quarantine'),
 ('S-FO-02', N'Override adjustment over 100% or unreadable',                   'SharePoint',  'raw.sp_forecast_overrides_export',            'adjustment',           'Validity',     'High',   'quarantine'),
 ('S-FO-03', N'Override submitted more than once',                             'SharePoint',  'raw.sp_forecast_overrides_export',            NULL,                   'Uniqueness',   'High',   'fix'),
 ('S-FO-04', N'Forecast month missing the year',                               'SharePoint',  'raw.sp_forecast_overrides_export',            'forecast_month',       'Validity',     'High',   'fix'),
 ('X-EI-01', N'Economic indicator value not a number',                         'External',    'raw.ext_economic_indicators',                 'value',                'Validity',     'Medium', 'quarantine'),
 ('X-EI-02', N'Economic series is stale',                                      'External',    'raw.ext_economic_indicators',                 'date',                 'Completeness', 'Low',    'flag'),
 ('X-WA-01', N'Weather alert is a test message',                               'External',    'raw.ext_weather_alerts_active',               'event',                'Validity',     'Low',    'quarantine'),
 ('X-SE-01', N'Storm event ends before it begins',                             'External',    'raw.ext_storm_events',                        'end_datetime',         'Validity',     'Low',    'flag')
) AS s (rule_id, rule_name, source_system, source_table, column_name, dq_dimension, severity, action)
ON t.rule_id = s.rule_id
WHEN MATCHED THEN UPDATE SET rule_name = s.rule_name, source_system = s.source_system, source_table = s.source_table,
    column_name = s.column_name, dq_dimension = s.dq_dimension, severity = s.severity, action = s.action
WHEN NOT MATCHED THEN INSERT (rule_id, rule_name, source_system, source_table, column_name, dq_dimension, severity, action)
    VALUES (s.rule_id, s.rule_name, s.source_system, s.source_table, s.column_name, s.dq_dimension, s.severity, s.action);
GO
