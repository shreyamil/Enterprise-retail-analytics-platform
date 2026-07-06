-- ============================================================================
-- Enterprise Retail Analytics Platform
-- analysis_queries.sql — 60+ Advanced SQL Analysis Queries
-- ============================================================================
-- Every query includes a short BUSINESS PURPOSE comment explaining why a
-- stakeholder (CFO, Category Manager, Regional Head, Supply Chain Lead, CMO)
-- would ask for it and how they'd use the result.
--
-- Organized into sections:
--   1.  Revenue & Profitability KPIs
--   2.  Growth Analysis (MoM / QoQ / YoY)
--   3.  Window Functions: Ranking, Running Totals, Moving Averages, LAG/LEAD
--   4.  Customer Analytics: RFM, LTV, Segmentation, Cohorts, Churn
--   5.  Product Analysis: ABC/Pareto, Category Contribution, Top/Worst
--   6.  Inventory Analysis: Turnover, Reorder, Stockout, Dead Stock
--   7.  Returns Analysis
--   8.  Regional / Store / Channel Analysis
--   9.  Advanced SQL Mechanics: Recursive CTE, Subqueries, CASE/COALESCE
-- ============================================================================


-- ============================================================================
-- SECTION 1: REVENUE & PROFITABILITY KPIs
-- ============================================================================

-- Q1. Total Revenue, Profit, and Gross Margin %
-- BUSINESS PURPOSE: The single most-asked number in any exec meeting — top-line
-- revenue, bottom-line profit, and the margin % that shows how efficiently
-- revenue converts to profit.
SELECT
    ROUND(SUM(sales_amount), 2) AS total_revenue,
    ROUND(SUM(profit), 2) AS total_profit,
    ROUND(100.0 * SUM(profit) / SUM(sales_amount), 2) AS gross_margin_pct
FROM fact_sales;

-- Q2. Net Margin after Returns (Refunds eat into profit)
-- BUSINESS PURPOSE: Gross margin overstates true profitability if returns are
-- high. Finance needs the post-refund "net" picture to set realistic targets.
SELECT
    ROUND(SUM(s.profit), 2) AS gross_profit,
    ROUND(COALESCE(SUM(r.refund_amount), 0), 2) AS total_refunds,
    ROUND(SUM(s.profit) - COALESCE(SUM(r.refund_amount), 0), 2) AS net_profit,
    ROUND(100.0 * (SUM(s.profit) - COALESCE(SUM(r.refund_amount), 0)) / SUM(s.sales_amount), 2) AS net_margin_pct
FROM fact_sales s
LEFT JOIN fact_returns r ON s.order_id = r.order_id AND r.return_status IN ('Approved','Refunded');

-- Q3. Average Order Value (AOV) overall and by channel
-- BUSINESS PURPOSE: AOV is a core lever — marketing uses it to judge whether
-- promos/bundling are lifting basket size.
SELECT
    sales_channel,
    COUNT(*) AS orders,
    ROUND(AVG(sales_amount), 2) AS avg_order_value
FROM fact_sales
GROUP BY sales_channel
ORDER BY avg_order_value DESC;

-- Q4. Average Discount Given vs Average Margin Retained, by Category
-- BUSINESS PURPOSE: Shows where discounting is eroding margin the most —
-- guides which categories need tighter promo governance.
SELECT
    p.category,
    ROUND(AVG(s.discount) * 100, 2) AS avg_discount_pct,
    ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s
JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.category
ORDER BY avg_discount_pct DESC;

-- Q5. Basket Size (avg units per order) and Revenue per Unit
-- BUSINESS PURPOSE: Distinguishes "people buy more items" growth from "items
-- got more expensive" growth — different levers for merchandising vs pricing.
SELECT
    ROUND(AVG(quantity), 2) AS avg_basket_size,
    ROUND(SUM(sales_amount) / SUM(quantity), 2) AS revenue_per_unit
FROM fact_sales;

-- Q6. Revenue, Profit & Margin by Payment Method
-- BUSINESS PURPOSE: Finance/Ops use this to negotiate processor fees and to
-- understand if certain payment methods (e.g. COD) correlate with lower margin.
SELECT
    payment_method,
    COUNT(*) AS orders,
    ROUND(SUM(sales_amount), 2) AS revenue,
    ROUND(100.0 * SUM(profit) / SUM(sales_amount), 2) AS margin_pct
FROM fact_sales
GROUP BY payment_method
ORDER BY revenue DESC;

-- Q7. Monthly Revenue & Profit Trend
-- BUSINESS PURPOSE: The base time series every other trend/forecast query
-- builds on. Used directly in the Executive Dashboard's main trend chart.
SELECT
    DATE_TRUNC('month', order_date)::date AS month,
    ROUND(SUM(sales_amount), 2) AS revenue,
    ROUND(SUM(profit), 2) AS profit
FROM fact_sales
GROUP BY 1
ORDER BY 1;

-- Q8. Revenue Concentration: % of Revenue from Top 10% of Customers
-- BUSINESS PURPOSE: Tests revenue concentration risk — if too much revenue
-- depends on a thin slice of customers, retention strategy becomes critical.
WITH customer_revenue AS (
    SELECT customer_id, SUM(sales_amount) AS rev
    FROM fact_sales
    GROUP BY customer_id
),
ranked AS (
    SELECT *, PERCENT_RANK() OVER (ORDER BY rev DESC) AS pctile
    FROM customer_revenue
)
SELECT
    ROUND(100.0 * SUM(rev) FILTER (WHERE pctile <= 0.10) / SUM(rev), 2) AS pct_revenue_from_top_10pct_customers
FROM ranked;

-- Q9. Profit Contribution by Brand (Top 15)
-- BUSINESS PURPOSE: Category managers use this in supplier negotiations and
-- assortment planning — which brands are actually worth the shelf space.
SELECT
    p.brand,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(SUM(s.profit), 2) AS profit,
    ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s
JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.brand
ORDER BY profit DESC
LIMIT 15;

-- Q10. Orders, Revenue and AOV by Customer Segment
-- BUSINESS PURPOSE: Confirms (or challenges) the assumption that "Premium"
-- customers actually drive premium revenue — sometimes "Regular" volume wins.
SELECT
    c.segment,
    COUNT(*) AS orders,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(AVG(s.sales_amount), 2) AS aov
FROM fact_sales s
JOIN dim_customers c ON s.customer_id = c.customer_id
GROUP BY c.segment
ORDER BY revenue DESC;


-- ============================================================================
-- SECTION 2: GROWTH ANALYSIS (MoM / QoQ / YoY)
-- ============================================================================

-- Q11. Month-over-Month Revenue Growth %
-- BUSINESS PURPOSE: The most frequently tracked growth metric in retail ops
-- reviews — flags momentum shifts fast enough to act on.
WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1
)
SELECT
    month,
    revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month)) / LAG(revenue) OVER (ORDER BY month), 2) AS mom_growth_pct
FROM monthly
ORDER BY month;

-- Q12. Quarter-over-Quarter Revenue Growth %
-- BUSINESS PURPOSE: Smooths month-level noise; this is the cadence board
-- decks typically report at.
WITH quarterly AS (
    SELECT DATE_TRUNC('quarter', order_date)::date AS quarter, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1
)
SELECT
    quarter,
    revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY quarter)) / LAG(revenue) OVER (ORDER BY quarter), 2) AS qoq_growth_pct
FROM quarterly
ORDER BY quarter;

-- Q13. Year-over-Year Revenue Growth % by Month (seasonally fair comparison)
-- BUSINESS PURPOSE: Compares each month to the *same* month last year, which
-- is the only fair way to judge growth in a seasonal retail business.
WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1
)
SELECT
    month,
    revenue,
    LAG(revenue, 12) OVER (ORDER BY month) AS revenue_same_month_last_year,
    ROUND(100.0 * (revenue - LAG(revenue, 12) OVER (ORDER BY month)) / LAG(revenue, 12) OVER (ORDER BY month), 2) AS yoy_growth_pct
FROM monthly
ORDER BY month;

-- Q14. Category-level YoY growth (which categories are accelerating/declining)
-- BUSINESS PURPOSE: Directs merchandising investment toward categories
-- gaining momentum and away from structurally declining ones.
WITH cat_year AS (
    SELECT p.category, EXTRACT(YEAR FROM s.order_date)::int AS yr, SUM(s.sales_amount) AS revenue
    FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY 1, 2
)
SELECT
    category, yr, revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (PARTITION BY category ORDER BY yr))
          / LAG(revenue) OVER (PARTITION BY category ORDER BY yr), 2) AS yoy_growth_pct
FROM cat_year
ORDER BY category, yr;

-- Q15. Region with Declining Revenue (flag regions where latest YoY < 0)
-- BUSINESS PURPOSE: Direct answer to "which region has declining revenue" —
-- triggers a regional deep-dive review.
WITH region_year AS (
    SELECT st.region, EXTRACT(YEAR FROM s.order_date)::int AS yr, SUM(s.sales_amount) AS revenue
    FROM fact_sales s JOIN dim_stores st ON s.store_id = st.store_id
    GROUP BY 1, 2
),
yoy AS (
    SELECT region, yr, revenue,
           revenue - LAG(revenue) OVER (PARTITION BY region ORDER BY yr) AS delta
    FROM region_year
)
SELECT region, yr, revenue, delta
FROM yoy
WHERE delta < 0
ORDER BY delta ASC;


-- ============================================================================
-- SECTION 3: WINDOW FUNCTIONS — Ranking, Running Totals, Moving Averages, LAG/LEAD
-- ============================================================================

-- Q16. Running Total of Daily Revenue (cumulative revenue YTD-style)
-- BUSINESS PURPOSE: Powers the "cumulative revenue vs target" line on the
-- executive dashboard.
SELECT
    order_date,
    SUM(sales_amount) AS daily_revenue,
    SUM(SUM(sales_amount)) OVER (ORDER BY order_date) AS running_total_revenue
FROM fact_sales
GROUP BY order_date
ORDER BY order_date;

-- Q17. 7-Day Moving Average of Revenue (smooths daily noise)
-- BUSINESS PURPOSE: Daily revenue is noisy (weekday/weekend swings); a 7-day
-- moving average is what ops actually watches for trend direction.
WITH daily AS (
    SELECT order_date, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY order_date
)
SELECT
    order_date,
    revenue,
    ROUND(AVG(revenue) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS moving_avg_7d
FROM daily
ORDER BY order_date;

-- Q18. Rank Products by Revenue within each Category (DENSE_RANK)
-- BUSINESS PURPOSE: Category managers need a "best seller in my category"
-- view, not a global one — this is the standard category review query.
SELECT category, product_id, product_name, revenue, rnk
FROM (
    SELECT p.category, p.product_id, p.product_name,
           SUM(s.sales_amount) AS revenue,
           DENSE_RANK() OVER (PARTITION BY p.category ORDER BY SUM(s.sales_amount) DESC) AS rnk
    FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY p.category, p.product_id, p.product_name
) ranked
WHERE rnk <= 3
ORDER BY category, rnk;

-- Q19. Month-over-month change per customer using LAG/LEAD (spend trajectory)
-- BUSINESS PURPOSE: Feeds churn-risk modeling — a customer whose LEAD spend
-- drops to zero relative to LAG is a churn candidate (see Q33).
WITH cust_month AS (
    SELECT customer_id, DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1, 2
)
SELECT
    customer_id, month, revenue,
    LAG(revenue) OVER (PARTITION BY customer_id ORDER BY month) AS prev_month_revenue,
    LEAD(revenue) OVER (PARTITION BY customer_id ORDER BY month) AS next_month_revenue
FROM cust_month
ORDER BY customer_id, month
LIMIT 200;

-- Q20. NTILE(4) Revenue Quartiles of Products (which quartile drives the business)
-- BUSINESS PURPOSE: Quick way to show leadership "our top quartile of SKUs
-- generates X% of revenue" without a full Pareto build-out.
WITH prod_rev AS (
    SELECT product_id, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY product_id
),
quartiled AS (
    SELECT *, NTILE(4) OVER (ORDER BY revenue DESC) AS quartile
    FROM prod_rev
)
SELECT quartile, COUNT(*) AS num_products, ROUND(SUM(revenue), 2) AS total_revenue
FROM quartiled
GROUP BY quartile
ORDER BY quartile;

-- Q21. First and Last Purchase Date per Customer (FIRST_VALUE / LAST_VALUE)
-- BUSINESS PURPOSE: Core input to tenure and recency calculations used across
-- the Customer Dashboard.
SELECT DISTINCT
    customer_id,
    FIRST_VALUE(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS first_purchase,
    LAST_VALUE(order_date) OVER (PARTITION BY customer_id ORDER BY order_date
        RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_purchase
FROM fact_sales
LIMIT 200;

-- Q22. Row Number to De-duplicate / Find Each Customer's Largest Order
-- BUSINESS PURPOSE: "What was each customer's single biggest purchase" is a
-- common VIP-identification ad hoc request from marketing.
SELECT customer_id, order_id, order_date, sales_amount
FROM (
    SELECT customer_id, order_id, order_date, sales_amount,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sales_amount DESC) AS rn
    FROM fact_sales
) t
WHERE rn = 1
ORDER BY sales_amount DESC
LIMIT 50;

-- Q23. Cumulative % of Revenue by Product (for Pareto chart, see also Q40)
-- BUSINESS PURPOSE: Direct feed for the 80/20 Pareto chart on the Inventory/
-- Product dashboard.
WITH prod_rev AS (
    SELECT product_id, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY product_id
)
SELECT
    product_id, revenue,
    ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER (), 2) AS cumulative_pct
FROM prod_rev
ORDER BY revenue DESC;


-- ============================================================================
-- SECTION 4: CUSTOMER ANALYTICS — RFM, LTV, Segmentation, Cohorts, Churn
-- ============================================================================

-- Q24. RFM Scoring (Recency, Frequency, Monetary) — quintile-based
-- BUSINESS PURPOSE: The backbone of the Customer Dashboard's RFM page; used
-- by marketing to target campaigns (e.g. "high R, low F" = win-back candidates).
WITH rfm_base AS (
    SELECT
        customer_id,
        (DATE '2024-12-31' - MAX(order_date)) AS recency_days,
        COUNT(*) AS frequency,
        SUM(sales_amount) AS monetary
    FROM fact_sales
    GROUP BY customer_id
),
rfm_scores AS (
    SELECT
        customer_id, recency_days, frequency, monetary,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- lower recency_days = better = higher score
        NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
    FROM rfm_base
)
SELECT
    customer_id, recency_days, frequency, monetary,
    r_score, f_score, m_score,
    (r_score + f_score + m_score) AS rfm_total,
    CASE
        WHEN (r_score + f_score + m_score) >= 13 THEN 'Champion'
        WHEN (r_score + f_score + m_score) >= 10 THEN 'Loyal'
        WHEN (r_score + f_score + m_score) >= 7  THEN 'At Risk'
        ELSE 'Lost'
    END AS rfm_segment
FROM rfm_scores
ORDER BY rfm_total DESC
LIMIT 200;

-- Q25. Customer Lifetime Value Distribution by Loyalty Tier
-- BUSINESS PURPOSE: Validates that the loyalty tiering actually separates
-- spend levels meaningfully (sanity check + dashboard KPI card).
SELECT
    loyalty_tier,
    COUNT(*) AS customers,
    ROUND(AVG(lifetime_value), 2) AS avg_ltv,
    ROUND(MIN(lifetime_value), 2) AS min_ltv,
    ROUND(MAX(lifetime_value), 2) AS max_ltv
FROM dim_customers
GROUP BY loyalty_tier
ORDER BY avg_ltv DESC;

-- Q26. Repeat Purchase Rate (% of customers with more than one order)
-- BUSINESS PURPOSE: A core retention health metric — low repeat rate signals
-- an acquisition-dependent (expensive) growth model.
SELECT
    ROUND(100.0 * COUNT(*) FILTER (WHERE order_count > 1) / COUNT(*), 2) AS repeat_purchase_rate_pct
FROM (
    SELECT customer_id, COUNT(*) AS order_count
    FROM fact_sales GROUP BY customer_id
) t;

-- Q27. Customer Acquisition by Month (new customers, based on signup_date)
-- BUSINESS PURPOSE: Marketing tracks this against CAC spend to judge
-- acquisition-channel efficiency over time.
SELECT
    DATE_TRUNC('month', signup_date)::date AS signup_month,
    COUNT(*) AS new_customers
FROM dim_customers
GROUP BY 1
ORDER BY 1;

-- Q28. Cohort Retention Analysis (% of each signup-month cohort still buying N months later)
-- BUSINESS PURPOSE: THE standard SaaS/retail retention curve — shows whether
-- newer cohorts retain better than older ones (product/CX improving or not).
WITH cohort AS (
    SELECT customer_id, DATE_TRUNC('month', signup_date)::date AS cohort_month
    FROM dim_customers
),
activity AS (
    SELECT s.customer_id, DATE_TRUNC('month', s.order_date)::date AS activity_month
    FROM fact_sales s
),
cohort_activity AS (
    SELECT
        c.cohort_month,
        a.activity_month,
        (DATE_PART('year', a.activity_month) - DATE_PART('year', c.cohort_month)) * 12 +
        (DATE_PART('month', a.activity_month) - DATE_PART('month', c.cohort_month)) AS month_number,
        c.customer_id
    FROM cohort c
    JOIN activity a ON c.customer_id = a.customer_id
    WHERE a.activity_month >= c.cohort_month
),
cohort_size AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_customers
    FROM cohort GROUP BY cohort_month
)
SELECT
    ca.cohort_month,
    ca.month_number,
    COUNT(DISTINCT ca.customer_id) AS active_customers,
    cs.cohort_customers,
    ROUND(100.0 * COUNT(DISTINCT ca.customer_id) / cs.cohort_customers, 2) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON ca.cohort_month = cs.cohort_month
WHERE ca.month_number BETWEEN 0 AND 12
GROUP BY ca.cohort_month, ca.month_number, cs.cohort_customers
ORDER BY ca.cohort_month, ca.month_number;

-- Q29. Churn Rate: customers with no purchase in the trailing 6 months (of data)
-- BUSINESS PURPOSE: Direct answer to "which customers are likely to churn" —
-- feeds retention-campaign target lists.
WITH last_purchase AS (
    SELECT customer_id, MAX(order_date) AS last_order
    FROM fact_sales GROUP BY customer_id
)
SELECT
    COUNT(*) FILTER (WHERE last_order < DATE '2024-12-31' - INTERVAL '180 days') AS churned_customers,
    COUNT(*) AS total_customers_with_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE last_order < DATE '2024-12-31' - INTERVAL '180 days') / COUNT(*), 2) AS churn_rate_pct
FROM last_purchase;

-- Q30. Most Profitable Customer Segment (direct business question)
-- BUSINESS PURPOSE: Directly answers "which customer segment is most
-- profitable" — guides where loyalty investment should concentrate.
SELECT
    c.segment,
    ROUND(SUM(s.profit), 2) AS total_profit,
    ROUND(SUM(s.profit) / COUNT(DISTINCT c.customer_id), 2) AS profit_per_customer
FROM fact_sales s
JOIN dim_customers c ON s.customer_id = c.customer_id
GROUP BY c.segment
ORDER BY total_profit DESC;

-- Q31. Customer Segmentation by Spend Tier using CASE (simple, dashboard-ready)
-- BUSINESS PURPOSE: A lightweight, business-readable alternative to RFM for
-- quick stakeholder consumption (no statistics background needed to read it).
SELECT
    CASE
        WHEN lifetime_value >= 10000 THEN 'High Value'
        WHEN lifetime_value >= 3000  THEN 'Mid Value'
        WHEN lifetime_value > 0      THEN 'Low Value'
        ELSE 'No Purchases'
    END AS spend_tier,
    COUNT(*) AS customers,
    ROUND(AVG(lifetime_value), 2) AS avg_ltv
FROM dim_customers
GROUP BY 1
ORDER BY avg_ltv DESC;

-- Q32. Average Days Between Purchases per Customer (purchase cadence)
-- BUSINESS PURPOSE: Used to time win-back email triggers — if a customer's
-- typical gap is 30 days and it's been 60, that's the trigger point.
WITH ordered AS (
    SELECT customer_id, order_date,
           LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS prev_date
    FROM fact_sales
)
SELECT
    customer_id,
    ROUND(AVG(order_date - prev_date), 1) AS avg_days_between_purchases
FROM ordered
WHERE prev_date IS NOT NULL
GROUP BY customer_id
HAVING COUNT(*) >= 3
ORDER BY avg_days_between_purchases ASC
LIMIT 50;

-- Q33. Churn-Risk Customers: spend dropped to near-zero vs prior 3-month average
-- BUSINESS PURPOSE: A more actionable churn signal than "no orders at all" —
-- catches customers actively disengaging while they're still reachable.
WITH cust_month AS (
    SELECT customer_id, DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1, 2
),
trend AS (
    SELECT customer_id, month, revenue,
           AVG(revenue) OVER (PARTITION BY customer_id ORDER BY month
               ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS prior_3mo_avg
    FROM cust_month
)
SELECT customer_id, month, revenue, prior_3mo_avg
FROM trend
WHERE prior_3mo_avg IS NOT NULL
  AND revenue < 0.3 * prior_3mo_avg
  AND month = (SELECT MAX(month) FROM cust_month)
ORDER BY prior_3mo_avg DESC
LIMIT 50;

-- Q34. New vs Returning Customer Revenue Split, by Month
-- BUSINESS PURPOSE: Distinguishes growth driven by new acquisition from
-- growth driven by existing-customer reactivation — different budgets fund each.
WITH first_order AS (
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM fact_sales GROUP BY customer_id
)
SELECT
    DATE_TRUNC('month', s.order_date)::date AS month,
    ROUND(SUM(s.sales_amount) FILTER (WHERE s.order_date = f.first_order_date), 2) AS new_customer_revenue,
    ROUND(SUM(s.sales_amount) FILTER (WHERE s.order_date != f.first_order_date), 2) AS returning_customer_revenue
FROM fact_sales s
JOIN first_order f ON s.customer_id = f.customer_id
GROUP BY 1
ORDER BY 1;

-- Q35. Top 20 Customers by Lifetime Value with their Favorite Category
-- BUSINESS PURPOSE: VIP account list for the loyalty/CRM team, with the
-- category context needed to personalize outreach.
WITH cat_rank AS (
    SELECT s.customer_id, p.category,
           SUM(s.sales_amount) AS cat_revenue,
           ROW_NUMBER() OVER (PARTITION BY s.customer_id ORDER BY SUM(s.sales_amount) DESC) AS rn
    FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY s.customer_id, p.category
)
SELECT
    c.customer_id, c.country, c.loyalty_tier, c.lifetime_value,
    cr.category AS favorite_category
FROM dim_customers c
JOIN cat_rank cr ON c.customer_id = cr.customer_id AND cr.rn = 1
ORDER BY c.lifetime_value DESC
LIMIT 20;


-- ============================================================================
-- SECTION 5: PRODUCT ANALYSIS — ABC/Pareto, Category Contribution, Top/Worst
-- ============================================================================

-- Q36. ABC Analysis (A = top 80% revenue, B = next 15%, C = last 5%)
-- BUSINESS PURPOSE: Classic inventory-prioritization framework — "A" items
-- get tight stock control and frequent review; "C" items get loose, low-touch
-- management. Directly informs the Inventory Dashboard.
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
FROM cum
ORDER BY revenue DESC;

-- Q37. ABC Class Summary (how many SKUs and what % of revenue each class holds)
-- BUSINESS PURPOSE: The headline stat from ABC analysis — e.g. "12% of SKUs
-- (Class A) drive 80% of revenue" is the number that goes in the exec deck.
WITH prod_rev AS (
    SELECT product_id, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY product_id
),
cum AS (
    SELECT *, SUM(revenue) OVER (ORDER BY revenue DESC) AS running_revenue, SUM(revenue) OVER () AS total_revenue
    FROM prod_rev
),
classed AS (
    SELECT *,
        CASE WHEN running_revenue / total_revenue <= 0.80 THEN 'A'
             WHEN running_revenue / total_revenue <= 0.95 THEN 'B'
             ELSE 'C' END AS abc_class
    FROM cum
)
SELECT
    abc_class,
    COUNT(*) AS num_skus,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_skus,
    ROUND(SUM(revenue), 2) AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_of_revenue
FROM classed
GROUP BY abc_class
ORDER BY abc_class;

-- Q38. Revenue Contribution by Category (with % of total)
-- BUSINESS PURPOSE: Standard category-mix slide — shows which categories the
-- business actually depends on for revenue.
SELECT
    p.category,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(100.0 * SUM(s.sales_amount) / SUM(SUM(s.sales_amount)) OVER (), 2) AS pct_of_total_revenue
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;

-- Q39. Top 10 Best-Selling Products by Revenue
-- BUSINESS PURPOSE: Most basic but most-requested merchandising report —
-- protect these SKUs from stockouts at all costs.
SELECT p.product_id, p.product_name, p.category,
       ROUND(SUM(s.sales_amount), 2) AS revenue,
       SUM(s.quantity) AS units_sold
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.category
ORDER BY revenue DESC
LIMIT 10;

-- Q40. Worst 10 Performing Products (by revenue, among products with >= 5 orders)
-- BUSINESS PURPOSE: Direct answer to "which products should be discontinued"
-- — filtered to products with enough orders to be a real signal, not noise.
SELECT p.product_id, p.product_name, p.category,
       ROUND(SUM(s.sales_amount), 2) AS revenue,
       COUNT(*) AS orders,
       ROUND(SUM(s.profit), 2) AS profit
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.category
HAVING COUNT(*) >= 5
ORDER BY revenue ASC
LIMIT 10;

-- Q41. Products with Negative or Near-Zero Margin (candidates to discontinue or reprice)
-- BUSINESS PURPOSE: Even high-revenue products can be value-destroying if
-- margin is too thin after discounting — this flags them directly.
SELECT p.product_id, p.product_name, p.category,
       ROUND(SUM(s.sales_amount), 2) AS revenue,
       ROUND(SUM(s.profit), 2) AS profit,
       ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.category
HAVING SUM(s.sales_amount) > 0
ORDER BY margin_pct ASC
LIMIT 15;

-- Q42. Where Discounts Are Hurting Profit Most (category x discount-band profit impact)
-- BUSINESS PURPOSE: Directly answers "where discounts are hurting profits" —
-- shows which categories see margin collapse at high discount bands.
SELECT
    p.category,
    CASE
        WHEN s.discount = 0 THEN '0% (no discount)'
        WHEN s.discount <= 0.10 THEN '1-10%'
        WHEN s.discount <= 0.25 THEN '11-25%'
        ELSE '26%+'
    END AS discount_band,
    COUNT(*) AS orders,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.category, discount_band
ORDER BY p.category, discount_band;

-- Q43. New Product Performance (launched in last 12 months of data vs. older)
-- BUSINESS PURPOSE: Tells merchandising whether recent product launches are
-- earning their shelf space relative to the established catalog.
SELECT
    CASE WHEN p.launch_date >= DATE '2024-01-01' THEN 'Launched 2024' ELSE 'Launched Before 2024' END AS launch_cohort,
    COUNT(DISTINCT p.product_id) AS num_products,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(SUM(s.sales_amount) / COUNT(DISTINCT p.product_id), 2) AS revenue_per_product
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY 1;

-- Q44. Subcategory Profitability Ranking within each Category
-- BUSINESS PURPOSE: One level deeper than category — helps category managers
-- decide which subcategories to expand or shrink assortment in.
SELECT category, subcategory, revenue, margin_pct, rnk
FROM (
    SELECT p.category, p.subcategory,
           ROUND(SUM(s.sales_amount), 2) AS revenue,
           ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct,
           RANK() OVER (PARTITION BY p.category ORDER BY SUM(s.profit) DESC) AS rnk
    FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY p.category, p.subcategory
) t
WHERE rnk = 1
ORDER BY revenue DESC;

-- Q45. Supplier Performance: Revenue & Margin Generated by Each Supplier's Products
-- BUSINESS PURPOSE: Procurement uses this alongside fact_inventory.supplier_rating
-- to decide which suppliers to consolidate volume with.
SELECT
    p.supplier,
    COUNT(DISTINCT p.product_id) AS num_products,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
GROUP BY p.supplier
ORDER BY revenue DESC
LIMIT 15;


-- ============================================================================
-- SECTION 6: INVENTORY ANALYSIS — Turnover, Reorder, Stockout, Dead Stock
-- ============================================================================

-- Q46. Inventory Turnover Ratio by Product (Sold Stock / Avg Stock)
-- BUSINESS PURPOSE: Core supply-chain KPI — low turnover ties up working
-- capital in slow-moving stock; high turnover risks stockouts.
SELECT
    product_id,
    SUM(sold_stock) AS total_sold,
    ROUND(AVG((opening_stock + closing_stock) / 2.0), 1) AS avg_stock,
    ROUND(SUM(sold_stock) / NULLIF(AVG((opening_stock + closing_stock) / 2.0), 0), 2) AS turnover_ratio
FROM fact_inventory
GROUP BY product_id
ORDER BY turnover_ratio DESC
LIMIT 20;

-- Q47. Reorder Alerts: Warehouses Below Reorder Level
-- BUSINESS PURPOSE: Direct answer to "which warehouses require replenishment"
-- — this is the literal trigger list for the procurement team's next PO run.
SELECT
    fi.product_id, p.product_name, fi.warehouse_id, w.region,
    fi.closing_stock, fi.reorder_level, fi.lead_time_days
FROM fact_inventory fi
JOIN dim_products p ON fi.product_id = p.product_id
JOIN dim_warehouses w ON fi.warehouse_id = w.warehouse_id
WHERE fi.closing_stock <= fi.reorder_level
ORDER BY (fi.reorder_level - fi.closing_stock) DESC
LIMIT 30;

-- Q48. Dead Stock: Products with Stock On Hand but Zero/Near-Zero Sales
-- BUSINESS PURPOSE: Direct contributor to "inventory optimization
-- recommendations" — capital sitting in stock that isn't moving should be
-- liquidated or discontinued.
SELECT
    fi.product_id, p.product_name, p.category,
    SUM(fi.closing_stock) AS total_stock_on_hand,
    COALESCE(SUM(s.quantity), 0) AS units_sold_lifetime
FROM fact_inventory fi
JOIN dim_products p ON fi.product_id = p.product_id
LEFT JOIN fact_sales s ON fi.product_id = s.product_id
GROUP BY fi.product_id, p.product_name, p.category
HAVING SUM(fi.closing_stock) > 0
ORDER BY units_sold_lifetime ASC, total_stock_on_hand DESC
LIMIT 20;

-- Q49. Fast-Moving Products (top decile by turnover) — protect from stockout
-- BUSINESS PURPOSE: The flip side of dead stock — these SKUs need priority
-- replenishment slots and shorter safety-stock review cycles.
WITH turnover AS (
    SELECT product_id,
           SUM(sold_stock) AS total_sold,
           AVG((opening_stock + closing_stock) / 2.0) AS avg_stock
    FROM fact_inventory
    GROUP BY product_id
)
SELECT product_id, total_sold,
       ROUND(total_sold / NULLIF(avg_stock, 0), 2) AS turnover_ratio
FROM turnover
WHERE total_sold / NULLIF(avg_stock, 0) >= (
    SELECT PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY total_sold / NULLIF(avg_stock, 0))
    FROM turnover
)
ORDER BY turnover_ratio DESC
LIMIT 20;

-- Q50. Stockout Frequency by Warehouse (how often closing stock hits zero)
-- BUSINESS PURPOSE: Warehouse-level service-quality metric — frequent
-- stockouts at a specific warehouse point to a local replenishment process
-- problem, not a product-demand problem.
SELECT
    w.warehouse_id, w.region,
    COUNT(*) FILTER (WHERE fi.closing_stock = 0) AS stockout_events,
    COUNT(*) AS total_product_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fi.closing_stock = 0) / COUNT(*), 2) AS stockout_rate_pct
FROM fact_inventory fi
JOIN dim_warehouses w ON fi.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.region
ORDER BY stockout_rate_pct DESC
LIMIT 20;

-- Q51. Inventory Health Score (composite: turnover, stockout risk, damage rate)
-- BUSINESS PURPOSE: A single 0-100 composite score per product so leadership
-- doesn't need to read five separate metrics to judge inventory health.
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
    ROUND(
        GREATEST(0, 100
            - (stockout_rate * 50)
            - (damage_rate * 30)
            - (CASE WHEN total_sold / NULLIF(avg_stock, 0) < 0.5 THEN 20 ELSE 0 END)
        ), 1
    ) AS inventory_health_score
FROM metrics
ORDER BY inventory_health_score ASC
LIMIT 20;

-- Q52. Supplier Rating vs Damage Rate (does supplier quality predict damaged stock?)
-- BUSINESS PURPOSE: Tests whether the supplier_rating field is actually
-- predictive — informs whether procurement should weight it in sourcing
-- decisions (see also the regression/correlation work in statistics.py).
SELECT
    CASE
        WHEN supplier_rating >= 4.5 THEN '4.5-5.0'
        WHEN supplier_rating >= 4.0 THEN '4.0-4.49'
        WHEN supplier_rating >= 3.5 THEN '3.5-3.99'
        WHEN supplier_rating >= 3.0 THEN '3.0-3.49'
        ELSE 'Below 3.0'
    END AS rating_band,
    COUNT(*) AS records,
    ROUND(AVG(damaged_stock::numeric / NULLIF(received_stock, 0)) * 100, 3) AS avg_damage_rate_pct
FROM fact_inventory
GROUP BY 1
ORDER BY 1 DESC;

-- Q53. Average Lead Time by Warehouse Region (supply chain responsiveness)
-- BUSINESS PURPOSE: Regions with longer average lead times need higher
-- safety-stock buffers — directly informs reorder_level policy by region.
SELECT
    w.region,
    ROUND(AVG(fi.lead_time_days), 1) AS avg_lead_time_days,
    COUNT(DISTINCT fi.warehouse_id) AS warehouses
FROM fact_inventory fi
JOIN dim_warehouses w ON fi.warehouse_id = w.warehouse_id
GROUP BY w.region
ORDER BY avg_lead_time_days DESC;


-- ============================================================================
-- SECTION 7: RETURNS ANALYSIS
-- ============================================================================

-- Q54. Overall Return Rate and Refund Cost
-- BUSINESS PURPOSE: Headline number for the Returns Dashboard — what % of
-- orders come back, and what does that cost in refunded revenue.
SELECT
    (SELECT COUNT(*) FROM fact_sales) AS total_orders,
    COUNT(*) AS total_returns,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM fact_sales), 2) AS return_rate_pct,
    ROUND(SUM(refund_amount), 2) AS total_refund_cost
FROM fact_returns;

-- Q55. Return Reasons Breakdown (which reasons drive the most refund cost)
-- BUSINESS PURPOSE: Different reasons need different fixes — "Defective" is
-- a QA problem, "Size/Fit Issue" is a sizing-chart/content problem.
SELECT
    reason,
    COUNT(*) AS return_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_returns,
    ROUND(SUM(refund_amount), 2) AS refund_cost
FROM fact_returns
GROUP BY reason
ORDER BY refund_cost DESC;

-- Q56. Return Rate by Category (problem-category identification)
-- BUSINESS PURPOSE: Direct contributor to "problem products" insight —
-- categories with outsized return rates need QA/sizing/description review.
SELECT
    p.category,
    COUNT(DISTINCT s.order_id) AS orders,
    COUNT(DISTINCT r.return_id) AS returns,
    ROUND(100.0 * COUNT(DISTINCT r.return_id) / COUNT(DISTINCT s.order_id), 2) AS return_rate_pct
FROM fact_sales s
JOIN dim_products p ON s.product_id = p.product_id
LEFT JOIN fact_returns r ON s.order_id = r.order_id
GROUP BY p.category
ORDER BY return_rate_pct DESC;

-- Q57. "Problem Products": highest return rate among products with meaningful volume
-- BUSINESS PURPOSE: Direct answer to "problem products / supplier issues" —
-- cross-references with supplier so procurement can escalate to the vendor.
SELECT
    p.product_id, p.product_name, p.supplier,
    COUNT(DISTINCT s.order_id) AS orders,
    COUNT(DISTINCT r.return_id) AS returns,
    ROUND(100.0 * COUNT(DISTINCT r.return_id) / COUNT(DISTINCT s.order_id), 2) AS return_rate_pct
FROM fact_sales s
JOIN dim_products p ON s.product_id = p.product_id
LEFT JOIN fact_returns r ON s.order_id = r.order_id
GROUP BY p.product_id, p.product_name, p.supplier
HAVING COUNT(DISTINCT s.order_id) >= 10
ORDER BY return_rate_pct DESC
LIMIT 20;

-- Q58. Return Status Funnel (Approved / Rejected / Pending / Refunded)
-- BUSINESS PURPOSE: Ops tracks this funnel to spot backlog (high Pending) or
-- a rejection rate that may be frustrating legitimate customers.
SELECT
    return_status,
    COUNT(*) AS count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM fact_returns
GROUP BY return_status
ORDER BY count DESC;

-- Q59. Average Days-After-Purchase to Return, by Reason
-- BUSINESS PURPOSE: "Changed Mind" returns happening fast vs "Defective"
-- returns happening late tells different stories about the failure point.
SELECT
    reason,
    ROUND(AVG(days_after_purchase), 1) AS avg_days_to_return,
    COUNT(*) AS n
FROM fact_returns
GROUP BY reason
ORDER BY avg_days_to_return;


-- ============================================================================
-- SECTION 8: REGIONAL / STORE / CHANNEL ANALYSIS
-- ============================================================================

-- Q60. Revenue, Profit and Margin by Region
-- BUSINESS PURPOSE: Standard regional-performance scorecard for the
-- Sales Dashboard's regional page.
SELECT
    st.region,
    ROUND(SUM(s.sales_amount), 2) AS revenue,
    ROUND(SUM(s.profit), 2) AS profit,
    ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS margin_pct
FROM fact_sales s JOIN dim_stores st ON s.store_id = st.store_id
GROUP BY st.region
ORDER BY revenue DESC;

-- Q61. Top 10 Stores by Revenue, with Rank
-- BUSINESS PURPOSE: Store ops review — identifies best-performing physical
-- locations for best-practice sharing across the network.
SELECT store_id, revenue, RANK() OVER (ORDER BY revenue DESC) AS store_rank
FROM (
    SELECT store_id, ROUND(SUM(sales_amount), 2) AS revenue
    FROM fact_sales GROUP BY store_id
) t
ORDER BY revenue DESC
LIMIT 10;

-- Q62. Online vs Offline Revenue Trend by Year (channel shift over time)
-- BUSINESS PURPOSE: Tracks the structural shift toward e-commerce — informs
-- capital allocation between physical store investment and digital platform investment.
SELECT
    EXTRACT(YEAR FROM order_date)::int AS yr,
    sales_channel,
    ROUND(SUM(sales_amount), 2) AS revenue
FROM fact_sales
GROUP BY 1, 2
ORDER BY 1, 2;

-- Q63. Revenue by Country and Segment (cross-tab via CASE-based pivot)
-- BUSINESS PURPOSE: A pivoted view — common ad hoc request format that's
-- easier for non-technical stakeholders to read than a long thin table.
SELECT
    c.country,
    ROUND(SUM(s.sales_amount) FILTER (WHERE c.segment = 'Premium'), 2) AS premium_revenue,
    ROUND(SUM(s.sales_amount) FILTER (WHERE c.segment = 'Regular'), 2) AS regular_revenue,
    ROUND(SUM(s.sales_amount) FILTER (WHERE c.segment = 'Budget'), 2) AS budget_revenue,
    ROUND(SUM(s.sales_amount) FILTER (WHERE c.segment = 'New'), 2) AS new_revenue
FROM fact_sales s JOIN dim_customers c ON s.customer_id = c.customer_id
GROUP BY c.country
ORDER BY c.country;


-- ============================================================================
-- SECTION 9: ADVANCED SQL MECHANICS — Recursive CTE, Subqueries, CASE/COALESCE
-- ============================================================================

-- Q64. Recursive CTE: Generate a Full Calendar of Months (date spine for reporting)
-- BUSINESS PURPOSE: BI reports need every month to appear even if it had zero
-- sales (so trend charts don't silently skip gaps) — a recursive CTE builds
-- this calendar spine without a physical date dimension table.
WITH RECURSIVE month_spine AS (
    SELECT DATE '2022-01-01' AS month
    UNION ALL
    SELECT (month + INTERVAL '1 month')::date
    FROM month_spine
    WHERE month < DATE '2024-12-01'
)
SELECT
    ms.month,
    COALESCE(SUM(s.sales_amount), 0) AS revenue
FROM month_spine ms
LEFT JOIN fact_sales s ON DATE_TRUNC('month', s.order_date) = ms.month
GROUP BY ms.month
ORDER BY ms.month;

-- Q65. Correlated Subquery: Each Customer's Orders Above Their Own Average
-- BUSINESS PURPOSE: Flags "unusually large" purchases per customer relative
-- to their own typical behavior — useful for fraud review and VIP-moment triggers.
SELECT s1.order_id, s1.customer_id, s1.sales_amount
FROM fact_sales s1
WHERE s1.sales_amount > (
    SELECT AVG(s2.sales_amount)
    FROM fact_sales s2
    WHERE s2.customer_id = s1.customer_id
)
ORDER BY s1.sales_amount DESC
LIMIT 20;

-- Q66. Subquery in FROM: Products Outperforming Their Category Average Margin
-- BUSINESS PURPOSE: Identifies which specific SKUs beat their own category's
-- typical margin — good candidates to push harder in promotions since they're
-- profitable even with markdowns.
SELECT product_id, product_name, category, product_margin_pct, category_avg_margin_pct
FROM (
    SELECT
        p.product_id, p.product_name, p.category,
        ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2) AS product_margin_pct,
        AVG(ROUND(100.0 * SUM(s.profit) / SUM(s.sales_amount), 2)) OVER (PARTITION BY p.category) AS category_avg_margin_pct
    FROM fact_sales s JOIN dim_products p ON s.product_id = p.product_id
    GROUP BY p.product_id, p.product_name, p.category
) t
WHERE product_margin_pct > category_avg_margin_pct
ORDER BY (product_margin_pct - category_avg_margin_pct) DESC
LIMIT 20;

-- Q67. COALESCE-heavy Data Quality Report (surfaces nulls/missing dimension data)
-- BUSINESS PURPOSE: Before trusting any dashboard number, data quality must
-- be checked — this report flags how much of each dimension has gaps.
SELECT
    'dim_customers' AS table_name,
    COUNT(*) AS total_rows,
    COUNT(*) - COUNT(income) AS missing_income,
    COUNT(*) - COUNT(loyalty_tier) AS missing_loyalty_tier
FROM dim_customers
UNION ALL
SELECT
    'dim_products',
    COUNT(*),
    COUNT(*) - COUNT(supplier),
    COUNT(*) - COUNT(launch_date)
FROM dim_products;

-- Q68. EXISTS Subquery: Customers Who Have Never Returned Anything (loyal/low-friction)
-- BUSINESS PURPOSE: A clean "never returned" customer list is useful for
-- testimonial/referral-program targeting — these are low-friction, satisfied buyers.
SELECT c.customer_id, c.country, c.loyalty_tier, c.lifetime_value
FROM dim_customers c
WHERE c.lifetime_value > 0
  AND NOT EXISTS (
      SELECT 1 FROM fact_sales s
      JOIN fact_returns r ON s.order_id = r.order_id
      WHERE s.customer_id = c.customer_id
  )
ORDER BY c.lifetime_value DESC
LIMIT 20;

-- Q69. CASE-based Dynamic KPI Flag: Is each month "Above" or "Below" its trailing 3-month average
-- BUSINESS PURPOSE: Powers a simple traffic-light (red/green) indicator that
-- dashboards use so executives don't have to read raw numbers to spot trouble.
WITH monthly AS (
    SELECT DATE_TRUNC('month', order_date)::date AS month, SUM(sales_amount) AS revenue
    FROM fact_sales GROUP BY 1
),
trended AS (
    SELECT month, revenue,
           AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS trailing_3mo_avg
    FROM monthly
)
SELECT
    month, revenue, ROUND(trailing_3mo_avg, 2) AS trailing_3mo_avg,
    CASE
        WHEN trailing_3mo_avg IS NULL THEN 'Insufficient History'
        WHEN revenue >= trailing_3mo_avg THEN 'Above Trend'
        ELSE 'Below Trend'
    END AS trend_flag
FROM trended
ORDER BY month;
