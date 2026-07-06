-- ============================================================================
-- Enterprise Retail Analytics Platform
-- schema.sql — PostgreSQL Database Schema
-- ============================================================================
-- Design notes:
--   - Modeled as a star schema (dimension + fact tables). This is a deliberate
--     upgrade over a flat 5-table layout: Store and Warehouse attributes
--     (Region) are functionally dependent on Store/Warehouse, not on each
--     sale/inventory row, so they're extracted into their own dimensions
--     (3NF). This also mirrors how a real enterprise BI warehouse is built
--     and makes the Power BI model (Phase 4) a clean star schema.
--   - Every fact table FKs into its dimensions with ON DELETE RESTRICT
--     (referential integrity matters more than convenience in a financial
--     reporting system — we never want to silently lose sales history).
--   - Indexes are added on every FK and on columns used heavily in WHERE/
--     GROUP BY/ORDER BY for analytical queries (dates, category, region).
-- ============================================================================

DROP TABLE IF EXISTS fact_returns CASCADE;
DROP TABLE IF EXISTS fact_inventory CASCADE;
DROP TABLE IF EXISTS fact_sales CASCADE;
DROP TABLE IF EXISTS dim_products CASCADE;
DROP TABLE IF EXISTS dim_customers CASCADE;
DROP TABLE IF EXISTS dim_stores CASCADE;
DROP TABLE IF EXISTS dim_warehouses CASCADE;

-- ----------------------------------------------------------------------------
-- DIMENSION: Customers
-- ----------------------------------------------------------------------------
CREATE TABLE dim_customers (
    customer_id       VARCHAR(10)     PRIMARY KEY,
    age                SMALLINT        CHECK (age BETWEEN 0 AND 110),
    gender             VARCHAR(10),
    city               VARCHAR(60),
    state              VARCHAR(60),
    country            VARCHAR(60),
    segment            VARCHAR(20)     CHECK (segment IN ('Premium','Regular','Budget','New')),
    income             NUMERIC(12,2)   CHECK (income >= 0),
    signup_date        DATE            NOT NULL,
    lifetime_value     NUMERIC(14,2)   DEFAULT 0,
    loyalty_tier       VARCHAR(10)     CHECK (loyalty_tier IN ('Bronze','Silver','Gold','Platinum'))
);

COMMENT ON TABLE dim_customers IS 'Customer dimension. lifetime_value and loyalty_tier are derived/refreshed from fact_sales by an ETL step (see python/cleaning.py), not manually entered.';

-- ----------------------------------------------------------------------------
-- DIMENSION: Products
-- ----------------------------------------------------------------------------
CREATE TABLE dim_products (
    product_id         VARCHAR(10)     PRIMARY KEY,
    category           VARCHAR(40)     NOT NULL,
    subcategory        VARCHAR(40),
    brand              VARCHAR(40),
    product_name       VARCHAR(120),
    cost_price         NUMERIC(10,2)   CHECK (cost_price >= 0),
    selling_price      NUMERIC(10,2)   CHECK (selling_price >= 0),
    supplier           VARCHAR(20),
    launch_date        DATE
);

-- ----------------------------------------------------------------------------
-- DIMENSION: Stores  (extracted from sales for 3NF — Region depends on Store)
-- ----------------------------------------------------------------------------
CREATE TABLE dim_stores (
    store_id           VARCHAR(15)     PRIMARY KEY,
    region             VARCHAR(20)     NOT NULL
);

-- ----------------------------------------------------------------------------
-- DIMENSION: Warehouses (extracted from inventory for 3NF)
-- ----------------------------------------------------------------------------
CREATE TABLE dim_warehouses (
    warehouse_id       VARCHAR(10)     PRIMARY KEY,
    region             VARCHAR(20)     NOT NULL
);

-- ----------------------------------------------------------------------------
-- FACT: Sales
-- ----------------------------------------------------------------------------
CREATE TABLE fact_sales (
    order_id           VARCHAR(12)     PRIMARY KEY,
    order_date         DATE            NOT NULL,
    customer_id        VARCHAR(10)     NOT NULL REFERENCES dim_customers(customer_id) ON DELETE RESTRICT,
    product_id         VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id) ON DELETE RESTRICT,
    quantity           SMALLINT        NOT NULL CHECK (quantity > 0),
    discount           NUMERIC(5,3)    CHECK (discount BETWEEN 0 AND 1),
    sales_amount       NUMERIC(12,2)   NOT NULL CHECK (sales_amount >= 0),
    profit             NUMERIC(12,2)   NOT NULL,
    store_id           VARCHAR(15)     NOT NULL REFERENCES dim_stores(store_id) ON DELETE RESTRICT,
    payment_method     VARCHAR(20),
    sales_channel      VARCHAR(10)     CHECK (sales_channel IN ('Online','Offline'))
);

-- ----------------------------------------------------------------------------
-- FACT: Inventory (product x warehouse snapshot)
-- ----------------------------------------------------------------------------
CREATE TABLE fact_inventory (
    inventory_id       SERIAL          PRIMARY KEY,
    product_id         VARCHAR(10)     NOT NULL REFERENCES dim_products(product_id) ON DELETE RESTRICT,
    warehouse_id       VARCHAR(10)     NOT NULL REFERENCES dim_warehouses(warehouse_id) ON DELETE RESTRICT,
    opening_stock      INTEGER         CHECK (opening_stock >= 0),
    received_stock     INTEGER         CHECK (received_stock >= 0),
    sold_stock         INTEGER         CHECK (sold_stock >= 0),
    damaged_stock      INTEGER         CHECK (damaged_stock >= 0),
    closing_stock      INTEGER         CHECK (closing_stock >= 0),
    reorder_level      INTEGER         CHECK (reorder_level >= 0),
    lead_time_days     SMALLINT        CHECK (lead_time_days >= 0),
    supplier_rating    NUMERIC(3,1)    CHECK (supplier_rating BETWEEN 0 AND 5),
    UNIQUE (product_id, warehouse_id)
);

-- ----------------------------------------------------------------------------
-- FACT: Returns
-- ----------------------------------------------------------------------------
CREATE TABLE fact_returns (
    return_id          VARCHAR(12)     PRIMARY KEY,
    order_id           VARCHAR(12)     NOT NULL REFERENCES fact_sales(order_id) ON DELETE RESTRICT,
    reason             VARCHAR(60),
    refund_amount      NUMERIC(12,2)   CHECK (refund_amount >= 0),
    return_date        DATE            NOT NULL,
    return_status      VARCHAR(15)     CHECK (return_status IN ('Approved','Rejected','Pending','Refunded')),
    days_after_purchase SMALLINT       CHECK (days_after_purchase >= 0)
);

-- ============================================================================
-- INDEXES
-- ============================================================================
-- Sales: the busiest analytical table — index every common filter/join column
CREATE INDEX idx_sales_order_date   ON fact_sales(order_date);
CREATE INDEX idx_sales_customer     ON fact_sales(customer_id);
CREATE INDEX idx_sales_product      ON fact_sales(product_id);
CREATE INDEX idx_sales_store        ON fact_sales(store_id);
CREATE INDEX idx_sales_channel      ON fact_sales(sales_channel);
-- Composite index supports "revenue by region/month" style rollups without a full scan
CREATE INDEX idx_sales_date_store   ON fact_sales(order_date, store_id);

CREATE INDEX idx_products_category  ON dim_products(category);
CREATE INDEX idx_products_brand     ON dim_products(brand);

CREATE INDEX idx_customers_segment  ON dim_customers(segment);
CREATE INDEX idx_customers_country  ON dim_customers(country);

CREATE INDEX idx_inventory_product  ON fact_inventory(product_id);
CREATE INDEX idx_inventory_warehouse ON fact_inventory(warehouse_id);
CREATE INDEX idx_inventory_reorder  ON fact_inventory(closing_stock, reorder_level);

CREATE INDEX idx_returns_order      ON fact_returns(order_id);
CREATE INDEX idx_returns_date       ON fact_returns(return_date);
CREATE INDEX idx_returns_status     ON fact_returns(return_status);

CREATE INDEX idx_stores_region      ON dim_stores(region);
CREATE INDEX idx_warehouses_region  ON dim_warehouses(region);
