/*
    03_mart_facts.sql
    Star schema facts. Run after 02_mart_dimensions.sql (which drops existing facts).
    Large facts use a clustered columnstore index with a nonclustered primary key on the business key.
    Facts store additive quantities, amounts, and per-row flags - never ratios (those are DAX measures).
*/

/* ---------------------------------------------------------------------------------------------
   FactSalesOrderLine - one row per sales order line (sales_orders + demand_transactions)
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactSalesOrderLine (
    sales_order_id              VARCHAR(12)    NOT NULL,
    so_line                     SMALLINT       NOT NULL,
    order_date_key              INT            NOT NULL CONSTRAINT FK_FSOL_OrderDate REFERENCES mart.DimDate (date_key),
    requested_date_key          INT            NOT NULL CONSTRAINT FK_FSOL_RequestedDate REFERENCES mart.DimDate (date_key),
    invoice_date_key            INT            NOT NULL CONSTRAINT FK_FSOL_InvoiceDate REFERENCES mart.DimDate (date_key),
    backorder_fill_date_key     INT            NOT NULL CONSTRAINT FK_FSOL_BOFillDate REFERENCES mart.DimDate (date_key),
    branch_key                  INT            NOT NULL CONSTRAINT FK_FSOL_Branch REFERENCES mart.DimBranch (branch_key),
    customer_key                INT            NOT NULL CONSTRAINT FK_FSOL_Customer REFERENCES mart.DimCustomer (customer_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FSOL_Part REFERENCES mart.DimPart (part_key),
    equipment_key               INT            NOT NULL CONSTRAINT FK_FSOL_Equipment REFERENCES mart.DimEquipment (equipment_key),
    demand_id                   VARCHAR(12)    NULL,
    order_channel               VARCHAR(30)    NOT NULL,
    line_status                 VARCHAR(40)    NOT NULL,
    fill_status                 VARCHAR(30)    NOT NULL,
    order_timestamp             DATETIME2(0)   NOT NULL,
    qty_ordered                 INT            NOT NULL,
    qty_filled_from_stock       INT            NOT NULL,
    qty_backordered             INT            NOT NULL,
    qty_backorder_filled        INT            NOT NULL,
    qty_lost_sale               INT            NOT NULL,
    qty_shipped                 INT            NOT NULL,
    unit_price_usd              DECIMAL(12, 2) NOT NULL,
    unit_cost_usd               DECIMAL(12, 2) NULL,
    extended_price_usd          DECIMAL(14, 2) NOT NULL,   -- ordered value
    shipped_value_usd           DECIMAL(14, 2) NOT NULL,   -- FIN-01
    cost_value_usd              DECIMAL(14, 2) NULL,       -- FIN-02 (shipped qty x cost)
    lost_sale_value_usd         DECIMAL(14, 2) NOT NULL,   -- SVC-04
    backorder_days              SMALLINT       NULL,       -- SVC-05
    is_filled_from_stock        BIT            NOT NULL,   -- SVC-01
    dw_loaded_at                DATETIME2(0)   NOT NULL CONSTRAINT DF_FSOL_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactSalesOrderLine PRIMARY KEY NONCLUSTERED (sales_order_id, so_line)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSalesOrderLine ON mart.FactSalesOrderLine;

/* ---------------------------------------------------------------------------------------------
   FactPurchaseOrderLine - accumulating snapshot, one row per PO line
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactPurchaseOrderLine (
    po_number                   VARCHAR(12)    NOT NULL,
    po_line                     SMALLINT       NOT NULL,
    po_date_key                 INT            NOT NULL CONSTRAINT FK_FPOL_PODate REFERENCES mart.DimDate (date_key),
    promised_date_key           INT            NOT NULL CONSTRAINT FK_FPOL_PromisedDate REFERENCES mart.DimDate (date_key),
    last_receipt_date_key       INT            NOT NULL CONSTRAINT FK_FPOL_ReceiptDate REFERENCES mart.DimDate (date_key),
    branch_key                  INT            NOT NULL CONSTRAINT FK_FPOL_Branch REFERENCES mart.DimBranch (branch_key),
    supplier_key                INT            NOT NULL CONSTRAINT FK_FPOL_Supplier REFERENCES mart.DimSupplier (supplier_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FPOL_Part REFERENCES mart.DimPart (part_key),
    order_type                  VARCHAR(20)    NOT NULL,   -- Stock / Emergency (SUP-06)
    line_status                 VARCHAR(20)    NOT NULL,   -- Open / Partially Received / Closed
    qty_ordered                 INT            NOT NULL,
    qty_received                INT            NOT NULL,
    qty_open                    INT            NOT NULL,
    unit_cost_usd               DECIMAL(12, 2) NOT NULL,
    line_value_usd              DECIMAL(14, 2) NOT NULL,
    planned_lead_time_days      SMALLINT       NULL,       -- supplier master lead time valid on PO date
    actual_lead_time_days       SMALLINT       NULL,       -- SUP-02 / SUP-03 (closed lines)
    days_late                   SMALLINT       NULL,       -- receipt - promised (negative = early)
    is_on_time                  BIT            NULL,       -- SUP-01; NULL while open
    dw_loaded_at                DATETIME2(0)   NOT NULL CONSTRAINT DF_FPOL_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactPurchaseOrderLine PRIMARY KEY NONCLUSTERED (po_number, po_line)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactPurchaseOrderLine ON mart.FactPurchaseOrderLine;

/* ---------------------------------------------------------------------------------------------
   FactGoodsReceiptLine - one row per goods receipt line
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactGoodsReceiptLine (
    gr_number                   VARCHAR(12)    NOT NULL,
    gr_line                     SMALLINT       NOT NULL,
    receipt_date_key            INT            NOT NULL CONSTRAINT FK_FGRL_ReceiptDate REFERENCES mart.DimDate (date_key),
    branch_key                  INT            NOT NULL CONSTRAINT FK_FGRL_Branch REFERENCES mart.DimBranch (branch_key),
    supplier_key                INT            NOT NULL CONSTRAINT FK_FGRL_Supplier REFERENCES mart.DimSupplier (supplier_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FGRL_Part REFERENCES mart.DimPart (part_key),
    po_number                   VARCHAR(12)    NOT NULL,
    po_line                     SMALLINT       NOT NULL,
    qty_received                INT            NOT NULL,
    qty_accepted                INT            NOT NULL,
    qty_rejected                INT            NOT NULL,   -- SUP-04
    unit_cost_usd               DECIMAL(12, 2) NOT NULL,
    received_value_usd          DECIMAL(14, 2) NOT NULL,
    rejection_reason            NVARCHAR(100)  NULL,
    dw_loaded_at                DATETIME2(0)   NOT NULL CONSTRAINT DF_FGRL_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactGoodsReceiptLine PRIMARY KEY NONCLUSTERED (gr_number, gr_line)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactGoodsReceiptLine ON mart.FactGoodsReceiptLine;

/* ---------------------------------------------------------------------------------------------
   FactInventoryTransaction - one row per stock movement
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactInventoryTransaction (
    txn_id                      VARCHAR(12)    NOT NULL,
    txn_date_key                INT            NOT NULL CONSTRAINT FK_FIT_Date REFERENCES mart.DimDate (date_key),
    txn_timestamp               DATETIME2(0)   NOT NULL,
    branch_key                  INT            NOT NULL CONSTRAINT FK_FIT_Branch REFERENCES mart.DimBranch (branch_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FIT_Part REFERENCES mart.DimPart (part_key),
    txn_type_key                INT            NOT NULL CONSTRAINT FK_FIT_Type REFERENCES mart.DimTransactionType (txn_type_key),
    qty                         INT            NOT NULL,   -- signed: + into stock, - out of stock
    unit_cost_usd               DECIMAL(12, 2) NOT NULL,
    value_usd                   DECIMAL(14, 2) NOT NULL,   -- signed qty x cost
    cogs_value_usd              DECIMAL(14, 2) NOT NULL,   -- INV-02: issues positive, returns negative, else 0
    reference_type              VARCHAR(20)    NULL,
    reference_id                VARCHAR(30)    NULL,
    balance_after               INT            NOT NULL,
    dw_loaded_at                DATETIME2(0)   NOT NULL CONSTRAINT DF_FIT_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactInventoryTransaction PRIMARY KEY NONCLUSTERED (txn_id)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactInventoryTransaction ON mart.FactInventoryTransaction;

/* ---------------------------------------------------------------------------------------------
   FactInventorySnapshotDaily - periodic snapshot, one row per branch x part x day (built in SQL)
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactInventorySnapshotDaily (
    snapshot_date_key           INT            NOT NULL CONSTRAINT FK_FISD_Date REFERENCES mart.DimDate (date_key),
    branch_key                  INT            NOT NULL CONSTRAINT FK_FISD_Branch REFERENCES mart.DimBranch (branch_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FISD_Part REFERENCES mart.DimPart (part_key),
    on_hand_qty                 INT            NOT NULL,
    on_order_qty                INT            NOT NULL,   -- open PO quantity
    in_transit_qty              INT            NOT NULL,   -- inbound transfers
    backorder_qty               INT            NOT NULL,   -- open customer backorders
    inventory_position_qty      INT            NOT NULL,   -- on hand + on order + in transit - backorders
    unit_cost_usd               DECIMAL(12, 2) NOT NULL,
    on_hand_value_usd           DECIMAL(14, 2) NOT NULL,   -- INV-01
    demand_qty                  INT            NOT NULL,   -- customer demand on this day
    avg_daily_demand_90d        DECIMAL(10, 3) NOT NULL,
    days_of_supply              DECIMAL(10, 1) NULL,       -- INV-03; NULL when no recent demand
    safety_stock_qty            INT            NULL,
    reorder_point_qty           INT            NULL,
    max_qty                     INT            NULL,
    excess_qty                  INT            NOT NULL,
    excess_value_usd            DECIMAL(14, 2) NOT NULL,   -- INV-04
    is_stockout                 BIT            NOT NULL,   -- SVC-06
    is_below_reorder_point      BIT            NOT NULL,
    is_excess                   BIT            NOT NULL,
    is_non_moving_12m           BIT            NOT NULL,   -- INV-05
    dw_loaded_at                DATETIME2(0)   NOT NULL CONSTRAINT DF_FISD_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactInventorySnapshotDaily PRIMARY KEY NONCLUSTERED (snapshot_date_key, branch_key, part_key)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactInventorySnapshotDaily ON mart.FactInventorySnapshotDaily;

/* ---------------------------------------------------------------------------------------------
   Supporting facts
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.FactEconomicIndicator (
    indicator_key       INT            NOT NULL CONSTRAINT FK_FEI_Indicator REFERENCES mart.DimIndicator (indicator_key),
    date_key            INT            NOT NULL CONSTRAINT FK_FEI_Date REFERENCES mart.DimDate (date_key),
    [value]             DECIMAL(18, 4) NOT NULL,
    retrieved_at        DATETIME2(0)   NOT NULL,
    dw_loaded_at        DATETIME2(0)   NOT NULL CONSTRAINT DF_FEI_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactEconomicIndicator PRIMARY KEY (indicator_key, date_key)
);

CREATE TABLE mart.FactWeatherEvent (
    event_id            BIGINT         NOT NULL CONSTRAINT PK_FactWeatherEvent PRIMARY KEY,
    episode_id          BIGINT         NULL,
    begin_date_key      INT            NOT NULL CONSTRAINT FK_FWE_BeginDate REFERENCES mart.DimDate (date_key),
    end_date_key        INT            NOT NULL CONSTRAINT FK_FWE_EndDate REFERENCES mart.DimDate (date_key),
    state_code          CHAR(2)        NOT NULL,
    county_or_zone      NVARCHAR(80)   NULL,
    zone_type           VARCHAR(20)    NULL,
    event_type          VARCHAR(40)    NOT NULL,
    begin_datetime      DATETIME2(0)   NULL,
    end_datetime        DATETIME2(0)   NULL,
    injuries            INT            NOT NULL,
    deaths              INT            NOT NULL,
    property_damage_usd DECIMAL(16, 2) NULL,
    crop_damage_usd     DECIMAL(16, 2) NULL,
    magnitude           DECIMAL(10, 2) NULL,
    magnitude_type      VARCHAR(5)     NULL,
    begin_lat           DECIMAL(9, 4)  NULL,
    begin_lon           DECIMAL(9, 4)  NULL,
    dw_loaded_at        DATETIME2(0)   NOT NULL CONSTRAINT DF_FWE_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE mart.FactSupplierException (
    exception_id                    VARCHAR(10)   NOT NULL CONSTRAINT PK_FactSupplierException PRIMARY KEY,
    supplier_key                    INT           NOT NULL CONSTRAINT FK_FSE_Supplier REFERENCES mart.DimSupplier (supplier_key),
    start_date_key                  INT           NOT NULL CONSTRAINT FK_FSE_StartDate REFERENCES mart.DimDate (date_key),
    expected_resolution_date_key    INT           NOT NULL CONSTRAINT FK_FSE_ResolutionDate REFERENCES mart.DimDate (date_key),
    issue                           NVARCHAR(300) NOT NULL,
    impacted_category               NVARCHAR(40)  NULL,
    impact                          VARCHAR(10)   NOT NULL,
    status                          VARCHAR(10)   NOT NULL,
    owner                           NVARCHAR(60)  NULL,
    dw_loaded_at                    DATETIME2(0)  NOT NULL CONSTRAINT DF_FSE_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE mart.FactForecastOverride (
    override_id             INT            NOT NULL CONSTRAINT PK_FactForecastOverride PRIMARY KEY,
    branch_key              INT            NOT NULL CONSTRAINT FK_FFO_Branch REFERENCES mart.DimBranch (branch_key),
    forecast_month_key      INT            NOT NULL CONSTRAINT FK_FFO_Month REFERENCES mart.DimDate (date_key),
    submitted_date_key      INT            NOT NULL CONSTRAINT FK_FFO_Submitted REFERENCES mart.DimDate (date_key),
    scope_level             VARCHAR(30)    NOT NULL,   -- Product Family / Product Category / Part Category
    scope_value             NVARCHAR(60)   NOT NULL,
    adjustment_pct          DECIMAL(6, 2)  NOT NULL,   -- +40 = +40%
    approval_status         VARCHAR(10)    NOT NULL,
    reason                  NVARCHAR(200)  NULL,
    submitted_by            NVARCHAR(60)   NULL,
    approved_by             NVARCHAR(60)   NULL,
    dw_loaded_at            DATETIME2(0)   NOT NULL CONSTRAINT DF_FFO_loaded DEFAULT SYSUTCDATETIME()
);

-- Populated by the forecasting engine in Phase 4
CREATE TABLE mart.FactForecast (
    forecast_month_key          INT            NOT NULL CONSTRAINT FK_FF_Month REFERENCES mart.DimDate (date_key),
    branch_key                  INT            NOT NULL CONSTRAINT FK_FF_Branch REFERENCES mart.DimBranch (branch_key),
    part_key                    INT            NOT NULL CONSTRAINT FK_FF_Part REFERENCES mart.DimPart (part_key),
    forecast_version            VARCHAR(20)    NOT NULL,   -- e.g. 2026-10 (month the forecast was made)
    statistical_forecast_qty    DECIMAL(12, 3) NOT NULL,
    override_pct                DECIMAL(6, 2)  NULL,
    final_forecast_qty          DECIMAL(12, 3) NOT NULL,
    model_name                  VARCHAR(40)    NULL,
    created_at                  DATETIME2(0)   NOT NULL CONSTRAINT DF_FF_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactForecast PRIMARY KEY (forecast_version, forecast_month_key, branch_key, part_key)
);

-- Populated by data quality runs in Phase 3
CREATE TABLE mart.FactDataQualityResult (
    run_id              VARCHAR(30)    NOT NULL,
    rule_key            INT            NOT NULL CONSTRAINT FK_FDQR_Rule REFERENCES mart.DimDQRule (rule_key),
    run_date_key        INT            NOT NULL CONSTRAINT FK_FDQR_Date REFERENCES mart.DimDate (date_key),
    run_timestamp       DATETIME2(0)   NOT NULL,
    records_evaluated   INT            NOT NULL,
    records_failed      INT            NOT NULL,
    CONSTRAINT PK_FactDataQualityResult PRIMARY KEY (run_id, rule_key)
);

CREATE TABLE mart.FactDataLoad (
    load_id             VARCHAR(40)    NOT NULL CONSTRAINT PK_FactDataLoad PRIMARY KEY,
    load_date_key       INT            NOT NULL CONSTRAINT FK_FDL_Date REFERENCES mart.DimDate (date_key),
    source_system       VARCHAR(30)    NOT NULL,   -- ERP / Master Data / Business Files / FRED / NOAA ...
    dataset             VARCHAR(60)    NOT NULL,
    loaded_at           DATETIME2(0)   NOT NULL,
    rows_loaded         INT            NOT NULL,
    status              VARCHAR(10)    NOT NULL,   -- ok / failed / skipped
    note                NVARCHAR(400)  NULL
);
GO
