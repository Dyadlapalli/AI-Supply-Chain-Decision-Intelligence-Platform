/*
    04_Database/mart/01_load_dimensions.sql
    mart.usp_load_dimensions: clean -> mart dimensions.

    Dimensions are UPSERTED (MERGE), never truncated, so surrogate keys stay stable from load to load.
    DimSupplier is SCD Type 2: when a tracked attribute changes, the current version is closed (valid_to)
    and a new version is opened, so purchase orders keep pointing at the supplier as it was when ordered.
*/
CREATE OR ALTER PROCEDURE mart.usp_load_dimensions
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    /* --- DimBranch (SCD 1) --------------------------------------------------------------------- */
    MERGE mart.DimBranch AS t
    USING clean.branch AS s ON t.branch_id = s.branch_id
    WHEN MATCHED THEN UPDATE SET branch_name = s.branch_name, region = COALESCE(s.region, 'Unknown'),
        state_code = COALESCE(s.state_code, '--'), branch_type = s.branch_type, open_date = s.open_date,
        is_active = s.is_active, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (branch_id, branch_name, region, state_code, branch_type, open_date, is_active)
        VALUES (s.branch_id, s.branch_name, COALESCE(s.region, 'Unknown'), COALESCE(s.state_code, '--'), s.branch_type, s.open_date, s.is_active);

    /* --- DimProduct (SCD 1): category, family, and segment flattened in ------------------------ */
    MERGE mart.DimProduct AS t
    USING (
        SELECT p.product_id, p.product_name, p.product_category_id, c.product_category_name,
               f.product_family_id, f.product_family_name, f.business_segment,
               COALESCE(p.criticality, 'Unknown') AS criticality, p.lifecycle_status
        FROM clean.product AS p
        JOIN clean.product_category AS c ON c.product_category_id = p.product_category_id
        JOIN clean.product_family AS f ON f.product_family_id = c.product_family_id
    ) AS s ON t.product_id = s.product_id
    WHEN MATCHED THEN UPDATE SET product_name = s.product_name, product_category_id = s.product_category_id,
        product_category_name = s.product_category_name, product_family_id = s.product_family_id,
        product_family_name = s.product_family_name, business_segment = s.business_segment,
        criticality = s.criticality, lifecycle_status = s.lifecycle_status, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (product_id, product_name, product_category_id, product_category_name,
        product_family_id, product_family_name, business_segment, criticality, lifecycle_status)
        VALUES (s.product_id, s.product_name, s.product_category_id, s.product_category_name, s.product_family_id,
                s.product_family_name, s.business_segment, s.criticality, s.lifecycle_status);

    /* --- DimInventoryPolicy (SCD 1) ------------------------------------------------------------ */
    MERGE mart.DimInventoryPolicy AS t
    USING clean.inventory_policy AS s ON t.part_category = s.part_category AND t.criticality = s.criticality
    WHEN MATCHED THEN UPDATE SET service_level_target = s.service_level_target, review_cycle_days = s.review_cycle_days,
        min_days_of_supply = s.min_days_of_supply, max_days_of_supply = s.max_days_of_supply, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (part_category, criticality, service_level_target, review_cycle_days,
        min_days_of_supply, max_days_of_supply)
        VALUES (s.part_category, s.criticality, s.service_level_target, s.review_cycle_days, s.min_days_of_supply, s.max_days_of_supply);

    /* --- DimSupplier (SCD 2) ------------------------------------------------------------------- */
    -- 1. Close the current version of any supplier whose tracked attributes changed
    UPDATE d SET valid_to = DATEADD(DAY, -1, @today), is_current = 0
    FROM mart.DimSupplier AS d
    JOIN clean.supplier AS s ON s.supplier_id = d.supplier_id
    WHERE d.is_current = 1 AND d.supplier_key > 0
      AND EXISTS (SELECT d.supplier_name, d.supplier_tier, d.supplier_type, d.lead_time_days, d.on_time_delivery_pct_master,
                         d.payment_terms, d.is_active
                  EXCEPT
                  SELECT s.supplier_name, COALESCE(s.supplier_tier, 'Unknown'), s.supplier_type, s.lead_time_days,
                         s.on_time_delivery_pct, s.payment_terms, s.is_active);   -- EXCEPT compares NULLs as equal
    -- 2. Open a version for new suppliers (valid since the beginning) and changed ones (valid from today)
    INSERT INTO mart.DimSupplier (supplier_id, supplier_name, supplier_tier, supplier_type, city, state_code, lead_time_days,
                                  on_time_delivery_pct_master, payment_terms, is_active, valid_from)
    SELECT s.supplier_id, s.supplier_name, COALESCE(s.supplier_tier, 'Unknown'), s.supplier_type, s.city, s.state_code,
           s.lead_time_days, s.on_time_delivery_pct, s.payment_terms, s.is_active,
           IIF(EXISTS (SELECT 1 FROM mart.DimSupplier o WHERE o.supplier_id = s.supplier_id), @today, '1900-01-01')
    FROM clean.supplier AS s
    WHERE NOT EXISTS (SELECT 1 FROM mart.DimSupplier d WHERE d.supplier_id = s.supplier_id AND d.is_current = 1);

    /* --- DimPart (SCD 1): product hierarchy, policy, and critical-part flags flattened in -------- */
    MERGE mart.DimPart AS t
    USING (
        SELECT p.part_id, p.part_number, p.part_description, COALESCE(p.part_category, N'Unknown') AS part_category,
               COALESCE(p.criticality, 'Unknown') AS criticality, p.unit_cost_usd, COALESCE(p.unit_of_measure, '--') AS unit_of_measure,
               p.reman_available, p.primary_supplier_id, p.primary_product_id, dp.product_name AS primary_model_name,
               dp.product_category_name, dp.product_family_name, dp.business_segment, ip.service_level_target,
               IIF(cp.part_id IS NULL, 0, 1) AS is_critical_part, cp.priority AS critical_priority, cp.scope AS critical_scope,
               p.created_date, p.is_active
        FROM clean.part AS p
        LEFT JOIN mart.DimProduct AS dp ON dp.product_id = p.primary_product_id
        LEFT JOIN clean.inventory_policy AS ip ON ip.part_category = p.part_category AND ip.criticality = p.criticality
        LEFT JOIN clean.critical_part AS cp ON cp.part_id = p.part_id
    ) AS s ON t.part_id = s.part_id
    WHEN MATCHED THEN UPDATE SET part_number = s.part_number, part_description = s.part_description, part_category = s.part_category,
        criticality = s.criticality, unit_cost_usd = s.unit_cost_usd, unit_of_measure = s.unit_of_measure,
        reman_available = s.reman_available, primary_supplier_id = s.primary_supplier_id, primary_product_id = s.primary_product_id,
        primary_model_name = s.primary_model_name, product_category_name = s.product_category_name,
        product_family_name = s.product_family_name, business_segment = s.business_segment,
        service_level_target = s.service_level_target, is_critical_part = s.is_critical_part,
        critical_priority = s.critical_priority, critical_scope = s.critical_scope, created_date = s.created_date,
        is_active = s.is_active, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (part_id, part_number, part_description, part_category, criticality, unit_cost_usd,
        unit_of_measure, reman_available, primary_supplier_id, primary_product_id, primary_model_name, product_category_name,
        product_family_name, business_segment, service_level_target, is_critical_part, critical_priority, critical_scope,
        created_date, is_active)
        VALUES (s.part_id, s.part_number, s.part_description, s.part_category, s.criticality, s.unit_cost_usd, s.unit_of_measure,
                s.reman_available, s.primary_supplier_id, s.primary_product_id, s.primary_model_name, s.product_category_name,
                s.product_family_name, s.business_segment, s.service_level_target, s.is_critical_part, s.critical_priority,
                s.critical_scope, s.created_date, s.is_active);

    /* --- DimCustomer (SCD 1) ------------------------------------------------------------------- */
    MERGE mart.DimCustomer AS t
    USING (SELECT customer_id, MAX(customer_name) AS customer_name FROM clean.sales_order_line
           WHERE customer_id IS NOT NULL GROUP BY customer_id) AS s ON t.customer_id = s.customer_id
    WHEN MATCHED THEN UPDATE SET customer_name = s.customer_name, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (customer_id, customer_name) VALUES (s.customer_id, s.customer_name);

    /* --- DimEquipment (SCD 1) ------------------------------------------------------------------ */
    MERGE mart.DimEquipment AS t
    USING (
        SELECT e.equipment_id, COALESCE(e.serial_number, 'UNKNOWN-' + e.equipment_id) AS serial_number,
               COALESCE(dp.product_key, -1) AS product_key, e.equipment_model, e.model_year, e.service_meter_hours,
               e.home_branch_id, e.ownership
        FROM clean.equipment AS e LEFT JOIN mart.DimProduct AS dp ON dp.product_id = e.product_id
    ) AS s ON t.equipment_id = s.equipment_id
    WHEN MATCHED THEN UPDATE SET serial_number = s.serial_number, product_key = s.product_key, equipment_model = s.equipment_model,
        model_year = s.model_year, service_meter_hours = s.service_meter_hours, home_branch_id = s.home_branch_id,
        ownership = s.ownership, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (equipment_id, serial_number, product_key, equipment_model, model_year,
        service_meter_hours, home_branch_id, ownership)
        VALUES (s.equipment_id, s.serial_number, s.product_key, s.equipment_model, s.model_year, s.service_meter_hours,
                s.home_branch_id, s.ownership);

    /* --- DimIndicator: economic series + weekly diesel price by region -------------------------- */
    MERGE mart.DimIndicator AS t
    USING (
        SELECT DISTINCT series_id, series_name, category, geography, frequency, units, source FROM clean.economic_indicator
        UNION
        SELECT DISTINCT 'DIESEL_' + UPPER(REPLACE(LEFT(region, CHARINDEX(' (', region + ' (') - 1), ' ', '_')),
               N'Retail Diesel Price', 'Energy', region, 'Weekly', N'USD per gallon', source
        FROM clean.fuel_price
    ) AS s ON t.series_id = s.series_id
    WHEN MATCHED THEN UPDATE SET series_name = s.series_name, category = s.category, geography = s.geography,
        frequency = s.frequency, units = s.units, source = s.source, dw_loaded_at = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (series_id, series_name, category, geography, frequency, units, source)
        VALUES (s.series_id, s.series_name, s.category, s.geography, s.frequency, s.units, s.source);

    /* --- DimDQRule ----------------------------------------------------------------------------- */
    MERGE mart.DimDQRule AS t
    USING dq.rule_catalog AS s ON t.rule_id = s.rule_id
    WHEN MATCHED THEN UPDATE SET rule_name = s.rule_name, dq_dimension = s.dq_dimension, severity = s.severity,
        source_system = s.source_system, source_table = s.source_table, column_name = s.column_name,
        rule_description = s.description, is_active = s.is_active
    WHEN NOT MATCHED BY TARGET THEN INSERT (rule_id, rule_name, dq_dimension, severity, source_system, source_table,
        column_name, rule_description, is_active)
        VALUES (s.rule_id, s.rule_name, s.dq_dimension, s.severity, s.source_system, s.source_table, s.column_name,
                s.description, s.is_active);
END
GO
