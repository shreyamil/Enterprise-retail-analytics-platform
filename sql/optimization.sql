-- ============================================================================
-- Enterprise Retail Analytics Platform
-- optimization.sql — Views, Stored Procedures, Triggers, Performance Tuning
-- ============================================================================

-- ============================================================================
-- PART 1: VIEWS
-- ============================================================================
-- BUSINESS PURPOSE: Views encapsulate the most frequently-rerun analytical
-- logic (monthly KPIs, RFM, ABC class) so BI tools (Power BI) and analysts
-- query a stable, pre-defined interface instead of re-writing the same CTEs.

DROP VIEW IF EXISTS vw_monthly_kpis CASCADE;
CREATE VIEW vw_monthly_kpis AS
SELECT
    DATE_TRUNC('month', order_date)::date AS month,
    COUNT(*) AS orders,
    COUNT(DISTINCT customer_id) AS active_customers,
    ROUND(SUM(sales_amount), 2) AS revenue,
    ROUND(SUM(profit), 2) AS profit,
    ROUND(100.0 * SUM(profit) / SUM(sales_amount), 2) AS margin_pct,
    ROUND(AVG(sales_amount), 2) AS avg_order_value
FROM fact_sales
GROUP BY 1;

COMMENT ON VIEW vw_monthly_kpis IS 'Pre-aggregated monthly KPI feed for the Executive Dashboard. Power BI connects directly to this view rather than fact_sales to keep refresh times low.';

DROP VIEW IF EXISTS vw_customer_rfm CASCADE;
CREATE VIEW vw_customer_rfm AS
WITH rfm_base AS (
    SELECT
        customer_id,
        (CURRENT_DATE - MAX(order_date)) AS recency_days,
        COUNT(*) AS frequency,
        SUM(sales_amount) AS monetary
    FROM fact_sales
    GROUP BY customer_id
)
SELECT
    customer_id, recency_days, frequency, monetary,
    NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
    NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
    NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
FROM rfm_base;

COMMENT ON VIEW vw_customer_rfm IS 'Live RFM scoring view feeding the Customer Dashboard RFM page and marketing segment exports.';

DROP VIEW IF EXISTS vw_product_abc CASCADE;
CREATE VIEW vw_product_abc AS
WITH prod_rev AS (
    SELECT product_id, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY product_id
),
cum AS (
    SELECT *,
           SUM(revenue) OVER (ORDER BY revenue DESC) AS running_revenue,
           SUM(revenue) OVER () AS total_revenue
    FROM prod_rev
)
SELECT
    product_id, revenue,
    ROUND(100.0 * running_revenue / total_revenue, 2) AS cumulative_pct,
    CASE
        WHEN running_revenue / total_revenue <= 0.80 THEN 'A'
        WHEN running_revenue / total_revenue <= 0.95 THEN 'B'
        ELSE 'C'
    END AS abc_class
FROM cum;

COMMENT ON VIEW vw_product_abc IS 'ABC classification view used by the Inventory Dashboard to color-code SKUs by revenue priority.';

DROP VIEW IF EXISTS vw_inventory_health CASCADE;
CREATE VIEW vw_inventory_health AS
WITH metrics AS (
    SELECT
        product_id,
        SUM(sold_stock) AS total_sold,
        AVG((opening_stock + closing_stock) / 2.0) AS avg_stock,
        SUM(damaged_stock)::numeric / NULLIF(SUM(received_stock), 0) AS damage_rate,
        COUNT(*) FILTER (WHERE closing_stock = 0)::numeric / COUNT(*) AS stockout_rate
    FROM fact_inventory
    GROUP BY product_id
)
SELECT
    product_id,
    ROUND(total_sold / NULLIF(avg_stock, 0), 2) AS turnover_ratio,
    ROUND(damage_rate * 100, 2) AS damage_rate_pct,
    ROUND(stockout_rate * 100, 2) AS stockout_rate_pct,
    ROUND(GREATEST(0, 100 - (stockout_rate * 50) - (damage_rate * 30)
        - (CASE WHEN total_sold / NULLIF(avg_stock, 0) < 0.5 THEN 20 ELSE 0 END)), 1) AS inventory_health_score
FROM metrics;

COMMENT ON VIEW vw_inventory_health IS 'Composite inventory health score per product for the Inventory Dashboard.';


-- ============================================================================
-- PART 2: STORED PROCEDURES / FUNCTIONS
-- ============================================================================

-- BUSINESS PURPOSE: Encapsulates the "refresh customer LTV & loyalty tier"
-- logic as a callable routine so it can be scheduled (e.g. nightly via cron/
-- pg_cron) rather than re-run manually after every data load.
CREATE OR REPLACE PROCEDURE refresh_customer_ltv()
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE dim_customers c
    SET lifetime_value = sub.total_spend
    FROM (
        SELECT customer_id, SUM(sales_amount) AS total_spend
        FROM fact_sales
        GROUP BY customer_id
    ) sub
    WHERE c.customer_id = sub.customer_id;

    WITH quantiles AS (
        SELECT
            percentile_cont(0.90) WITHIN GROUP (ORDER BY lifetime_value) AS q90,
            percentile_cont(0.70) WITHIN GROUP (ORDER BY lifetime_value) AS q70,
            percentile_cont(0.40) WITHIN GROUP (ORDER BY lifetime_value) AS q40
        FROM dim_customers
    )
    UPDATE dim_customers c
    SET loyalty_tier = CASE
        WHEN c.lifetime_value >= q.q90 THEN 'Platinum'
        WHEN c.lifetime_value >= q.q70 THEN 'Gold'
        WHEN c.lifetime_value >= q.q40 THEN 'Silver'
        ELSE 'Bronze'
    END
    FROM quantiles q;

    RAISE NOTICE 'Customer LTV and loyalty tiers refreshed.';
END;
$$;

-- BUSINESS PURPOSE: A parameterized function so analysts/Power BI can pull
-- "top N products by revenue in a given category" without writing raw SQL
-- each time — a reusable building block for ad hoc requests.
CREATE OR REPLACE FUNCTION top_products_by_category(p_category VARCHAR, p_limit INT DEFAULT 10)
RETURNS TABLE (product_id VARCHAR, product_name VARCHAR, revenue NUMERIC)
LANGUAGE sql
AS $$
    SELECT p.product_id, p.product_name, ROUND(SUM(s.sales_amount), 2) AS revenue
    FROM fact_sales s
    JOIN dim_products p ON s.product_id = p.product_id
    WHERE p.category = p_category
    GROUP BY p.product_id, p.product_name
    ORDER BY revenue DESC
    LIMIT p_limit;
$$;

-- BUSINESS PURPOSE: Encapsulates monthly growth % calc as a reusable function
-- so dashboards and ad hoc analysts get a single source of truth for "growth".
CREATE OR REPLACE FUNCTION monthly_growth_pct()
RETURNS TABLE (month DATE, revenue NUMERIC, growth_pct NUMERIC)
LANGUAGE sql
AS $$
    WITH monthly AS (
        SELECT DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
        FROM fact_sales GROUP BY 1
    )
    SELECT month, revenue,
           ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month)) / LAG(revenue) OVER (ORDER BY month), 2)
    FROM monthly
    ORDER BY month;
$$;


-- ============================================================================
-- PART 3: TRIGGERS
-- ============================================================================

-- BUSINESS PURPOSE: Guarantees data integrity at the database level — profit
-- must always equal sales_amount minus cost basis at time of sale. Rather
-- than trust every ETL/app write path to compute it correctly, the database
-- recomputes it on insert/update so the number is never wrong in fact_sales.
CREATE OR REPLACE FUNCTION trg_validate_sales_profit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cost_price NUMERIC;
BEGIN
    SELECT cost_price INTO v_cost_price FROM dim_products WHERE product_id = NEW.product_id;

    IF v_cost_price IS NOT NULL THEN
        NEW.profit := ROUND(NEW.sales_amount - (v_cost_price * NEW.quantity), 2);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_profit_check ON fact_sales;
CREATE TRIGGER trg_sales_profit_check
BEFORE INSERT OR UPDATE ON fact_sales
FOR EACH ROW
EXECUTE FUNCTION trg_validate_sales_profit();

-- BUSINESS PURPOSE: Automatically flags impossible inventory states (closing
-- stock that doesn't reconcile with opening + received - sold - damaged) the
-- moment they're written, instead of being discovered weeks later in a report.
CREATE OR REPLACE FUNCTION trg_check_inventory_reconciliation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.closing_stock != (NEW.opening_stock + NEW.received_stock - NEW.sold_stock - NEW.damaged_stock) THEN
        RAISE WARNING 'Inventory reconciliation mismatch for product % in warehouse %: closing_stock does not equal opening+received-sold-damaged',
            NEW.product_id, NEW.warehouse_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_inventory_reconciliation ON fact_inventory;
CREATE TRIGGER trg_inventory_reconciliation
BEFORE INSERT OR UPDATE ON fact_inventory
FOR EACH ROW
EXECUTE FUNCTION trg_check_inventory_reconciliation();


-- ============================================================================
-- PART 4: PERFORMANCE OPTIMIZATION — Execution Plans
-- ============================================================================
-- BUSINESS PURPOSE: Documents *why* the indexes in schema.sql exist, by
-- showing the before/after query plan for the two heaviest analytical query
-- patterns (date-range scans and category joins).

-- Example 1: Date-range filter on fact_sales (100K rows) — relies on idx_sales_order_date
EXPLAIN ANALYZE
SELECT SUM(sales_amount) FROM fact_sales
WHERE order_date BETWEEN '2024-11-01' AND '2024-12-31';
-- Expected plan: Index Scan using idx_sales_order_date (NOT Seq Scan).
-- Without the index, Postgres would do a full 100K-row sequential scan for
-- every monthly/quarterly dashboard refresh — the index turns this into a
-- range lookup that only touches the relevant rows.

-- Example 2: Category-level aggregation join — relies on idx_products_category
EXPLAIN ANALYZE
SELECT p.category, SUM(s.sales_amount)
FROM fact_sales s
JOIN dim_products p ON s.product_id = p.product_id
WHERE p.category = 'Electronics'
GROUP BY p.category;
-- Observed plan (verified against the live 100K-row fact_sales table):
-- idx_products_category is used as a Bitmap Index Scan to cheaply pull the
-- ~770 Electronics products, which are then hashed (Hash Join build side).
-- fact_sales is read with a Seq Scan, not an index probe — and that's the
-- CORRECT choice here: with 100K rows and no filter on fact_sales itself,
-- one sequential pass is cheaper than 100K individual index lookups. The
-- idx_sales_product index earns its keep on *selective* lookups instead
-- (e.g. "all orders for product X", see idx_sales_product usage implied by
-- Q18/Q39-style per-product queries), not on a full-table join like this one.
-- This is a useful real-world lesson for the documentation: more indexes
-- isn't always better — the planner ignores indexes when a scan is cheaper.

-- Example 3: Composite index validation for "revenue by store over a date range"
EXPLAIN ANALYZE
SELECT store_id, SUM(sales_amount)
FROM fact_sales
WHERE order_date >= '2024-01-01'
GROUP BY store_id;
-- Expected plan: Index Scan using idx_sales_date_store satisfies both the
-- WHERE and GROUP BY without a separate sort step, which a single-column
-- index on order_date alone would not achieve as efficiently.

-- ----------------------------------------------------------------------------
-- ANALYZE the tables after bulk load — Postgres's planner relies on table
-- statistics (row counts, value distributions) to choose the right plan.
-- This must be run once after the initial load and periodically thereafter.
-- ----------------------------------------------------------------------------
ANALYZE dim_customers;
ANALYZE dim_products;
ANALYZE dim_stores;
ANALYZE dim_warehouses;
ANALYZE fact_sales;
ANALYZE fact_inventory;
ANALYZE fact_returns;
