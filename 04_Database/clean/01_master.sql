/*
    04_Database/clean/01_master.sql
    clean.usp_build_master: builds the clean master data and the crosswalks (source ID -> golden ID).

    Principles:
      - Duplicates are not deleted, they are MAPPED: every source ID resolves to one surviving ID through a
        crosswalk (clean.*_xref), so transactions that reference a duplicate still count toward the right record.
      - Survivorship: the original (lowest) ID survives; a missing attribute is filled from its duplicates.
      - A value that cannot be repaired becomes NULL and stays flagged in dq - it is never guessed.
      - Records that cannot be trusted at all go to clean.quarantine with the reason.
*/
CREATE OR ALTER PROCEDURE clean.usp_build_master
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM clean.quarantine WHERE source_table LIKE 'raw.master[_]%';

    /* =========================================================================================
       BRANCH
    ========================================================================================= */
    DROP TABLE IF EXISTS #br;
    SELECT b.branch_id,
           COALESCE(d.related_key, b.branch_id) AS survivor,
           ROW_NUMBER() OVER (PARTITION BY COALESCE(d.related_key, b.branch_id)
                              ORDER BY IIF(d.related_key IS NULL, 0, 1), b.branch_id) AS rk,
           -- '  RICHMOND' / 'Richmond Branch' / 'Richmond Store' -> 'Richmond'
           clean.fn_proper(REPLACE(REPLACE(N' ' + LTRIM(RTRIM(b.branch_name)) + N' ', N' Branch ', N' '), N' Store ', N' ')) AS branch_name,
           CASE WHEN b.region IN (N'East', N'North', N'Central', N'Southwest') THEN b.region
                WHEN b.region LIKE N'East%' THEN N'East' END AS region,     -- 'Eastern' -> 'East'
           COALESCE(IIF(LEN(LTRIM(RTRIM(b.state))) = 2, UPPER(LTRIM(RTRIM(b.state))), NULL), st.state_code) AS state_code,
           b.branch_type, clean.fn_to_date(b.open_date) AS open_date, IIF(b.is_active = N'Y', 1, 0) AS is_active
    INTO #br
    FROM raw.master_branch_master AS b
    LEFT JOIN dq.chk_M_BR_05 AS d ON d.record_key = b.branch_id
    LEFT JOIN clean.ref_state AS st ON st.state_name = LTRIM(RTRIM(b.state));

    DROP TABLE IF EXISTS clean.branch_xref;
    SELECT CAST(branch_id AS NVARCHAR(100)) AS source_value, CAST(survivor AS VARCHAR(10)) AS branch_id
    INTO clean.branch_xref FROM #br
    UNION   -- operational systems sometimes carry the branch NAME instead of the ID ('Richmond')
    SELECT branch_name, survivor FROM #br WHERE rk = 1;

    DROP TABLE IF EXISTS clean.branch;
    SELECT ISNULL(CAST(s.survivor AS VARCHAR(10)), '') AS branch_id,   -- ISNULL: NOT NULL column for the primary key
           CAST(s.branch_name AS NVARCHAR(60)) AS branch_name,
           CAST(COALESCE(s.region,
                         (SELECT TOP (1) x.region FROM #br x WHERE x.survivor = s.survivor AND x.region IS NOT NULL ORDER BY x.rk),
                         (SELECT MIN(x.region) FROM #br x WHERE x.state_code = s.state_code AND x.rk = 1 AND x.region IS NOT NULL
                          HAVING COUNT(DISTINCT x.region) = 1)) AS VARCHAR(20)) AS region,   -- e.g. every WV branch is Southwest
           CAST(COALESCE(s.state_code, (SELECT TOP (1) x.state_code FROM #br x WHERE x.survivor = s.survivor AND x.state_code IS NOT NULL ORDER BY x.rk)) AS CHAR(2)) AS state_code,
           CAST(s.branch_type AS VARCHAR(30)) AS branch_type,
           s.open_date, CAST(s.is_active AS BIT) AS is_active
    INTO clean.branch
    FROM #br AS s WHERE s.rk = 1;
    EXEC (N'ALTER TABLE clean.branch ADD CONSTRAINT PK_clean_branch PRIMARY KEY (branch_id)');  -- dynamic: compiled after SELECT INTO creates the table

    /* =========================================================================================
       PRODUCT FAMILY - mapped onto the Data Steward's approved list (clean.ref_product_family)
    ========================================================================================= */
    DROP TABLE IF EXISTS #pf;
    SELECT f.product_family_id, f.planning_owner, f.is_active, r.product_family_name AS approved_name
    INTO #pf
    FROM raw.master_product_family_master AS f
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'family' AND syn.source_value = LTRIM(RTRIM(f.product_family_name))
    LEFT JOIN clean.ref_product_family AS r
           ON REPLACE(dq.fn_norm_name(r.product_family_name), N' ', N'') =
              REPLACE(dq.fn_norm_name(COALESCE(syn.approved_value, f.product_family_name)), N' ', N'')
    WHERE f.product_family_id IS NOT NULL;

    DROP TABLE IF EXISTS clean.product_family_xref;
    SELECT CAST(product_family_id AS VARCHAR(10)) AS source_family_id,
           CAST(MIN(product_family_id) OVER (PARTITION BY approved_name) AS VARCHAR(10)) AS product_family_id
    INTO clean.product_family_xref
    FROM #pf WHERE approved_name IS NOT NULL;

    DROP TABLE IF EXISTS clean.product_family;
    SELECT ISNULL(CAST(x.product_family_id AS VARCHAR(10)), '') AS product_family_id,
           CAST(r.product_family_name AS NVARCHAR(60)) AS product_family_name,
           CAST(r.product_family_code AS VARCHAR(5)) AS product_family_code,
           CAST(r.business_segment AS NVARCHAR(40)) AS business_segment,
           CAST(MAX(p.planning_owner) AS NVARCHAR(60)) AS planning_owner,
           CAST(MAX(IIF(p.is_active IN (N'Y', N'Yes'), 1, 0)) AS BIT) AS is_active
    INTO clean.product_family
    FROM #pf AS p
    JOIN clean.product_family_xref AS x ON x.source_family_id = p.product_family_id
    JOIN clean.ref_product_family AS r ON r.product_family_name = p.approved_name
    GROUP BY x.product_family_id, r.product_family_name, r.product_family_code, r.business_segment;
    EXEC (N'ALTER TABLE clean.product_family ADD CONSTRAINT PK_clean_product_family PRIMARY KEY (product_family_id)');  -- dynamic: compiled after SELECT INTO creates the table

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.master_product_family_master', COALESCE(f.product_family_id, N'(missing)'),
           IIF(f.product_family_id IS NULL, 'M-PF-02', 'CLEAN-01'),
           IIF(f.product_family_id IS NULL, N'Family has no ID', N'Not on the approved product family list: ' + f.product_family_name)
    FROM raw.master_product_family_master AS f
    WHERE f.product_family_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM clean.product_family_xref x WHERE x.source_family_id = f.product_family_id);

    /* =========================================================================================
       PRODUCT CATEGORY - name standardized; family taken from the products in the category
       (the category's own family link is the field that was found wrong, duplicated, or missing)
    ========================================================================================= */
    DROP TABLE IF EXISTS #pc;
    SELECT c.product_category_id, c.product_family_id AS raw_family_id,
           COALESCE(syn.approved_value, LTRIM(RTRIM(c.product_category_name))) AS category_name
    INTO #pc
    FROM raw.master_product_category_master AS c
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'category' AND syn.source_value = LTRIM(RTRIM(c.product_category_name));

    DROP TABLE IF EXISTS clean.product_category_xref;
    SELECT CAST(product_category_id AS VARCHAR(10)) AS source_category_id,
           CAST(MIN(product_category_id) OVER (PARTITION BY category_name) AS VARCHAR(10)) AS product_category_id
    INTO clean.product_category_xref FROM #pc;

    DROP TABLE IF EXISTS #cat_family;   -- most common (crosswalked) family among each category's products
    SELECT category_id, family_id
    INTO #cat_family
    FROM (
        SELECT cx.product_category_id AS category_id, fx.product_family_id AS family_id,
               ROW_NUMBER() OVER (PARTITION BY cx.product_category_id ORDER BY COUNT(*) DESC, fx.product_family_id) AS rk
        FROM raw.master_product_master AS p
        JOIN clean.product_category_xref AS cx ON cx.source_category_id = p.product_category_id
        JOIN clean.product_family_xref AS fx ON fx.source_family_id = p.product_family_id
        GROUP BY cx.product_category_id, fx.product_family_id
    ) AS t WHERE rk = 1;

    DROP TABLE IF EXISTS clean.product_category;
    SELECT ISNULL(CAST(c.product_category_id AS VARCHAR(10)), '') AS product_category_id,
           CAST(c.category_name AS NVARCHAR(60)) AS product_category_name,
           CAST(COALESCE(cf.family_id, fx.product_family_id) AS VARCHAR(10)) AS product_family_id
    INTO clean.product_category
    FROM #pc AS c
    JOIN clean.product_category_xref AS x ON x.source_category_id = c.product_category_id
                                           AND x.product_category_id = c.product_category_id   -- survivors only
    LEFT JOIN #cat_family AS cf ON cf.category_id = c.product_category_id
    LEFT JOIN clean.product_family_xref AS fx ON fx.source_family_id = c.raw_family_id;
    EXEC (N'ALTER TABLE clean.product_category ADD CONSTRAINT PK_clean_product_category PRIMARY KEY (product_category_id)');  -- dynamic: compiled after SELECT INTO creates the table

    /* =========================================================================================
       PRODUCT (equipment model)
    ========================================================================================= */
    DROP TABLE IF EXISTS #pr;
    SELECT p.product_id, COALESCE(d.related_key, p.product_id) AS survivor,
           -- 'Cat320' / '320' / 'Caterpillar 320' / 'CAT 320  ' -> 'CAT 320'
           N'CAT ' + LTRIM(RTRIM(
               CASE WHEN LTRIM(p.product_name) LIKE N'Caterpillar %' THEN SUBSTRING(LTRIM(p.product_name), 13, 100)
                    WHEN LTRIM(p.product_name) LIKE N'Cat%' THEN SUBSTRING(LTRIM(p.product_name), 4, 100)
                    ELSE p.product_name END)) AS product_name,
           p.product_category_id, COALESCE(syn.approved_value, p.criticality) AS criticality, p.lifecycle_status
    INTO #pr
    FROM raw.master_product_master AS p
    LEFT JOIN dq.chk_M_PR_05 AS d ON d.record_key = p.product_id
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'criticality' AND syn.source_value COLLATE Latin1_General_BIN2 = p.criticality COLLATE Latin1_General_BIN2;

    DROP TABLE IF EXISTS clean.product_xref;
    SELECT CAST(product_id AS VARCHAR(10)) AS source_product_id, CAST(survivor AS VARCHAR(10)) AS product_id
    INTO clean.product_xref FROM #pr;

    DROP TABLE IF EXISTS #pr_cat;   -- category: product's own if valid, else from its equipment units
    SELECT p.product_id,
           COALESCE(cx.product_category_id,
                    (SELECT TOP (1) ex.product_category_id FROM raw.master_equipment_master e
                     JOIN clean.product_category_xref ex ON ex.source_category_id = e.product_category_id
                     WHERE e.product_id = p.product_id
                     GROUP BY ex.product_category_id ORDER BY COUNT(*) DESC)) AS category_id
    INTO #pr_cat
    FROM #pr AS p
    LEFT JOIN clean.product_category_xref AS cx ON cx.source_category_id = p.product_category_id;

    DROP TABLE IF EXISTS clean.product;
    SELECT ISNULL(CAST(p.product_id AS VARCHAR(10)), '') AS product_id,
           CAST(p.product_name AS NVARCHAR(60)) AS product_name,
           CAST(pc.category_id AS VARCHAR(10)) AS product_category_id,
           CAST(c.product_family_id AS VARCHAR(10)) AS product_family_id,
           CAST(COALESCE(IIF(rp.criticality COLLATE Latin1_General_BIN2 IN (N'High', N'Medium', N'Low'), rp.criticality, NULL),
                         (SELECT TOP (1) o.criticality FROM #pr o JOIN #pr_cat oc ON oc.product_id = o.product_id
                          JOIN raw.master_product_master ro ON ro.product_id = o.product_id
                          WHERE oc.category_id = pc.category_id AND ro.criticality COLLATE Latin1_General_BIN2 IN (N'High', N'Medium', N'Low')
                          GROUP BY o.criticality ORDER BY COUNT(*) DESC),
                         p.criticality) AS VARCHAR(10)) AS criticality,   -- non-standard value -> category's criticality
           CAST(p.lifecycle_status AS VARCHAR(20)) AS lifecycle_status
    INTO clean.product
    FROM #pr AS p
    JOIN raw.master_product_master AS rp ON rp.product_id = p.product_id
    JOIN #pr_cat AS pc ON pc.product_id = p.product_id
    LEFT JOIN clean.product_category AS c ON c.product_category_id = pc.category_id
    WHERE p.product_id = p.survivor;
    EXEC (N'ALTER TABLE clean.product ADD CONSTRAINT PK_clean_product PRIMARY KEY (product_id)');  -- dynamic: compiled after SELECT INTO creates the table

    /* =========================================================================================
       SUPPLIER - the duplicate supplier case study
    ========================================================================================= */
    DROP TABLE IF EXISTS #su;
    SELECT s.supplier_id, COALESCE(d.related_key, s.supplier_id) AS survivor,
           ROW_NUMBER() OVER (PARTITION BY COALESCE(d.related_key, s.supplier_id)
                              ORDER BY IIF(d.related_key IS NULL, 0, 1), s.supplier_id) AS rk,
           LTRIM(RTRIM(s.supplier_name)) AS supplier_name,
           COALESCE(syn.approved_value, IIF(s.supplier_tier IN (N'Tier 1', N'Tier 2', N'Tier 3'), s.supplier_tier, NULL)) AS supplier_tier,
           s.supplier_type, s.city,
           COALESCE(IIF(LEN(LTRIM(RTRIM(s.state))) = 2, UPPER(LTRIM(RTRIM(s.state))), NULL), st.state_code) AS state_code,
           IIF(clean.fn_to_int(s.lead_time_days) > 0, clean.fn_to_int(s.lead_time_days), NULL) AS lead_time_days,
           IIF(TRY_CAST(s.on_time_delivery_pct AS DECIMAL(9, 2)) BETWEEN 0 AND 100, TRY_CAST(s.on_time_delivery_pct AS DECIMAL(5, 1)), NULL) AS otd,
           s.payment_terms, IIF(s.is_active = N'Y', 1, 0) AS is_active
    INTO #su
    FROM raw.master_supplier_master AS s
    LEFT JOIN dq.chk_M_SU_01 AS d ON d.record_key = s.supplier_id
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'tier' AND syn.source_value COLLATE Latin1_General_BIN2 = s.supplier_tier COLLATE Latin1_General_BIN2
    LEFT JOIN clean.ref_state AS st ON st.state_name = LTRIM(RTRIM(s.state));

    DROP TABLE IF EXISTS clean.supplier_xref;
    SELECT CAST(supplier_id AS VARCHAR(10)) AS source_supplier_id, CAST(survivor AS VARCHAR(10)) AS supplier_id,
           CAST(supplier_name AS NVARCHAR(100)) AS source_supplier_name
    INTO clean.supplier_xref FROM #su;

    -- Purchase orders parsed once; used below to repair master values from what was actually ordered
    DROP TABLE IF EXISTS #po;
    SELECT o.part_id AS source_part_id, x.supplier_id, o.order_type,
           clean.fn_to_date(o.po_date) AS po_date, clean.fn_to_date(o.promised_date) AS promised_date,
           clean.fn_to_money(o.unit_cost_usd) AS unit_cost_usd
    INTO #po
    FROM raw.erp_purchase_orders AS o
    LEFT JOIN clean.supplier_xref AS x ON x.source_supplier_id = o.supplier_id;

    DROP TABLE IF EXISTS #po_lead;   -- planned lead time seen on stock POs: most common (promised - PO date)
    SELECT supplier_id, lead_days
    INTO #po_lead
    FROM (
        SELECT supplier_id, DATEDIFF(DAY, po_date, promised_date) AS lead_days,
               ROW_NUMBER() OVER (PARTITION BY supplier_id ORDER BY COUNT(*) DESC) AS rk
        FROM #po
        WHERE order_type = N'Stock' AND supplier_id IS NOT NULL AND promised_date >= po_date
        GROUP BY supplier_id, DATEDIFF(DAY, po_date, promised_date)
    ) AS t WHERE rk = 1;

    DROP TABLE IF EXISTS clean.supplier;
    SELECT ISNULL(CAST(o.survivor AS VARCHAR(10)), '') AS supplier_id,
           CAST(o.supplier_name AS NVARCHAR(100)) AS supplier_name,
           CAST(COALESCE((SELECT TOP (1) r.supplier_tier FROM #su x JOIN raw.master_supplier_master r ON r.supplier_id = x.supplier_id
                          WHERE x.survivor = o.survivor AND r.supplier_tier COLLATE Latin1_General_BIN2 IN (N'Tier 1', N'Tier 2', N'Tier 3')
                          ORDER BY x.rk),
                         o.supplier_tier) AS VARCHAR(10)) AS supplier_tier,
           CAST(o.supplier_type AS VARCHAR(40)) AS supplier_type,
           CAST(o.city AS NVARCHAR(60)) AS city,
           CAST(COALESCE(o.state_code, (SELECT TOP (1) x.state_code FROM #su x WHERE x.survivor = o.survivor AND x.state_code IS NOT NULL ORDER BY x.rk)) AS VARCHAR(3)) AS state_code,
           CAST(COALESCE(o.lead_time_days,
                         (SELECT TOP (1) x.lead_time_days FROM #su x WHERE x.survivor = o.survivor AND x.lead_time_days IS NOT NULL ORDER BY x.rk),
                         (SELECT pl.lead_days FROM #po_lead pl WHERE pl.supplier_id = o.survivor)) AS SMALLINT) AS lead_time_days,
           COALESCE(o.otd, (SELECT TOP (1) x.otd FROM #su x WHERE x.survivor = o.survivor AND x.otd IS NOT NULL ORDER BY x.rk)) AS on_time_delivery_pct,
           CAST(o.payment_terms AS VARCHAR(10)) AS payment_terms,
           CAST(o.is_active AS BIT) AS is_active,
           CAST((SELECT STRING_AGG(x.supplier_id, ', ') WITHIN GROUP (ORDER BY x.supplier_id) FROM #su x WHERE x.survivor = o.survivor) AS VARCHAR(100)) AS source_supplier_ids
    INTO clean.supplier
    FROM #su AS o WHERE o.rk = 1;
    EXEC (N'ALTER TABLE clean.supplier ADD CONSTRAINT PK_clean_supplier PRIMARY KEY (supplier_id)');  -- dynamic: compiled after SELECT INTO creates the table

    /* =========================================================================================
       PART
    ========================================================================================= */
    DROP TABLE IF EXISTS #pt;
    SELECT p.part_id,
           COALESCE(dup.related_key, p.part_id) AS survivor,
           IIF(p.part_description LIKE N'%SUPERSEDED%', 1, 0) AS is_superseded,
           COALESCE(clean.fn_canon_part(p.part_number), UPPER(LTRIM(RTRIM(p.part_number)))) AS part_number,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(p.part_description, N'  ', N' '), N'  ', N' '),
                 N'FLTR', N'FILTER'), N'ASSY', N'ASSEMBLY'), N' (SUPERSEDED)', N'')))) AS part_description,
           COALESCE(syn_c.approved_value, p.part_category) AS part_category,
           p.criticality,
           ABS(NULLIF(clean.fn_to_money(p.unit_cost_usd), 0)) AS unit_cost_usd,   -- sign error -> ABS; zero -> unknown
           COALESCE(syn_u.approved_value, p.unit_of_measure) AS unit_of_measure,
           sx.supplier_id AS primary_supplier_id,
           px.product_id AS primary_product_id,
           IIF(p.reman_available = N'Y', 1, 0) AS reman_available,
           clean.fn_to_date(p.created_date) AS created_date,
           IIF(p.is_active = N'Y', 1, 0) AS is_active
    INTO #pt
    FROM raw.master_part_master AS p
    LEFT JOIN dq.chk_M_PT_10 AS dup ON dup.record_key = p.part_id
    LEFT JOIN clean.ref_synonym AS syn_c ON syn_c.domain = 'part_category' AND syn_c.source_value = p.part_category
    LEFT JOIN clean.ref_synonym AS syn_u ON syn_u.domain = 'uom' AND syn_u.source_value COLLATE Latin1_General_BIN2 = p.unit_of_measure COLLATE Latin1_General_BIN2
    LEFT JOIN clean.supplier_xref AS sx ON sx.source_supplier_id = p.primary_supplier_id
    LEFT JOIN clean.product_xref AS px ON px.source_product_id = p.primary_product_id;

    -- Superseded part numbers resolve to the part that replaced them (same part without the suffix)
    UPDATE s SET survivor = r.part_id
    FROM #pt AS s
    CROSS APPLY (SELECT TOP (1) r.part_id FROM #pt r
                 WHERE r.is_superseded = 0 AND r.part_description = s.part_description
                   AND LEFT(r.part_number, LEN(r.part_number) - 1) = LEFT(s.part_number, LEN(s.part_number) - 1)
                 ORDER BY r.part_id) AS r
    WHERE s.is_superseded = 1;

    DROP TABLE IF EXISTS clean.part_xref;
    SELECT CAST(part_id AS VARCHAR(10)) AS source_part_id, CAST(survivor AS VARCHAR(10)) AS part_id
    INTO clean.part_xref FROM #pt;

    DROP TABLE IF EXISTS #desc_profile;   -- category and criticality are consistent for a given part description
    SELECT part_description,
           (SELECT TOP (1) part_category FROM #pt x WHERE x.part_description = d.part_description AND x.part_category IS NOT NULL
            GROUP BY part_category ORDER BY COUNT(*) DESC) AS part_category,
           (SELECT TOP (1) criticality FROM #pt x WHERE x.part_description = d.part_description AND x.criticality IS NOT NULL
            GROUP BY criticality ORDER BY COUNT(*) DESC) AS criticality
    INTO #desc_profile
    FROM (SELECT DISTINCT part_description FROM #pt) AS d;

    DROP TABLE IF EXISTS #po_part;   -- per part: latest current-year PO cost, and the supplier most POs went to
    WITH po AS (
        SELECT x.part_id, p.supplier_id, p.po_date, p.unit_cost_usd
        FROM #po AS p JOIN clean.part_xref AS x ON x.source_part_id = p.source_part_id
    ), cost AS (
        SELECT part_id, unit_cost_usd,
               ROW_NUMBER() OVER (PARTITION BY part_id ORDER BY po_date DESC) AS rk
        FROM po WHERE YEAR(po_date) = YEAR(SYSUTCDATETIME()) AND unit_cost_usd > 0
    ), sup AS (
        SELECT part_id, supplier_id,
               ROW_NUMBER() OVER (PARTITION BY part_id ORDER BY COUNT(*) DESC, supplier_id) AS rk
        FROM po WHERE supplier_id IS NOT NULL GROUP BY part_id, supplier_id
    )
    SELECT x.part_id, c.unit_cost_usd AS current_po_cost, s.supplier_id AS usual_supplier
    INTO #po_part
    FROM (SELECT DISTINCT part_id FROM clean.part_xref) AS x
    LEFT JOIN cost AS c ON c.part_id = x.part_id AND c.rk = 1
    LEFT JOIN sup AS s ON s.part_id = x.part_id AND s.rk = 1;

    DROP TABLE IF EXISTS clean.part;
    SELECT ISNULL(CAST(p.part_id AS VARCHAR(10)), '') AS part_id,
           CAST(p.part_number AS VARCHAR(20)) AS part_number,
           CAST(p.part_description AS NVARCHAR(100)) AS part_description,
           CAST(COALESCE(p.part_category, dp.part_category) AS NVARCHAR(40)) AS part_category,
           CAST(COALESCE(p.criticality, dp.criticality) AS VARCHAR(10)) AS criticality,
           CAST(COALESCE(p.unit_cost_usd, pp.current_po_cost) AS DECIMAL(12, 2)) AS unit_cost_usd,
           CAST(p.unit_of_measure AS VARCHAR(5)) AS unit_of_measure,
           CAST(COALESCE(p.primary_supplier_id, pp.usual_supplier) AS VARCHAR(10)) AS primary_supplier_id,
           CAST(p.primary_product_id AS VARCHAR(10)) AS primary_product_id,
           CAST(p.reman_available AS BIT) AS reman_available,
           p.created_date, CAST(p.is_active AS BIT) AS is_active
    INTO clean.part
    FROM #pt AS p
    LEFT JOIN #desc_profile AS dp ON dp.part_description = p.part_description
    LEFT JOIN #po_part AS pp ON pp.part_id = p.part_id
    WHERE p.part_id = p.survivor;
    EXEC (N'ALTER TABLE clean.part ADD CONSTRAINT PK_clean_part PRIMARY KEY (part_id)');  -- dynamic: compiled after SELECT INTO creates the table

    /* =========================================================================================
       EQUIPMENT
    ========================================================================================= */
    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.master_equipment_master', d.record_key, 'M-EQ-07', N'Same serial number as ' + d.related_key
    FROM dq.chk_M_EQ_07 AS d;

    DROP TABLE IF EXISTS clean.equipment;
    SELECT ISNULL(CAST(e.equipment_id AS VARCHAR(10)), '') AS equipment_id,
           CAST(UPPER(LTRIM(RTRIM(e.serial_number))) AS VARCHAR(20)) AS serial_number,
           CAST(p.product_id AS VARCHAR(10)) AS product_id,
           CAST(p.product_name AS NVARCHAR(60)) AS equipment_model,
           CAST(p.product_category_id AS VARCHAR(10)) AS product_category_id,
           CAST(IIF(clean.fn_to_int(e.model_year) BETWEEN 1990 AND YEAR(SYSUTCDATETIME()) + 1, clean.fn_to_int(e.model_year), NULL) AS SMALLINT) AS model_year,
           IIF(clean.fn_to_int(e.service_meter_hours) >= 0, clean.fn_to_int(e.service_meter_hours), NULL) AS service_meter_hours,
           CAST(bx.branch_id AS VARCHAR(10)) AS home_branch_id,
           CAST(e.ownership AS VARCHAR(20)) AS ownership
    INTO clean.equipment
    FROM raw.master_equipment_master AS e
    JOIN clean.product_xref AS px ON px.source_product_id = e.product_id
    JOIN clean.product AS p ON p.product_id = px.product_id
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = e.home_branch_id
    WHERE NOT EXISTS (SELECT 1 FROM clean.quarantine q
                      WHERE q.source_table = 'raw.master_equipment_master' AND q.record_key = e.equipment_id);
    EXEC (N'ALTER TABLE clean.equipment ADD CONSTRAINT PK_clean_equipment PRIMARY KEY (equipment_id)');  -- dynamic: compiled after SELECT INTO creates the table
END
GO
