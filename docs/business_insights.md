# Enterprise Retail Analytics Platform — Business Insights

*Auto-generated from the live dataset by python/insights.py. Every number below is computed directly from the data, not templated.*

### Why did sales rise most recently?

Revenue rose 1.9% from November 2024 (1,130,354) to December 2024 (1,152,290). The largest negative contributor was **Furniture** (-19,525 change), while **Home & Kitchen** contributed the most positive movement (32,477 change). This is consistent with the seasonality detected in statistics.py — month-to-month swings in this business are driven primarily by the holiday calendar, not a structural shift in demand.

### Which customer segment is most profitable?

By **total profit**, the **Regular** segment leads with 1,450,923 in profit across 4,394 customers. By **profit per customer** — arguably the more useful number for targeting — the **Premium** segment leads at 561.73 per customer. These differ — total profit favors volume, profit-per-customer favors efficiency; loyalty investment should weight toward the latter for ROI.

### Which region has declining revenue?

**Central** declined -190,561 (-8.1%) year-over-year in 2024, the steepest drop of any region. This should trigger a regional review covering store-level performance, local competitive activity, and whether inventory availability (see warehouse replenishment below) is a contributing factor.

### Which products should be discontinued?

10 products generate **net-negative profit** despite having at least 5 orders (i.e. consistent demand isn't the issue — pricing/cost structure is):

- **NimbusTech Cameras 371** (Electronics): 594 orders, -52,748.78 cumulative loss
- **Aurawave Laptops 441** (Electronics): 1077 orders, -30,256.18 cumulative loss
- **Sonex Laptops 357** (Electronics): 4027 orders, -18,568.94 cumulative loss
- **Aurawave Laptops 934** (Electronics): 91 orders, -14,065.51 cumulative loss
- **NimbusTech Laptops 416** (Electronics): 182 orders, -13,869.48 cumulative loss
- **NimbusTech Cameras 397** (Electronics): 119 orders, -7,748.73 cumulative loss
- **Sonex Cameras 233** (Electronics): 94 orders, -7,327.73 cumulative loss
- **Sonex Laptops 538** (Electronics): 55 orders, -7,073.27 cumulative loss
- **NimbusTech Accessories 444** (Electronics): 132 orders, -6,941.27 cumulative loss
- **Pulseon Cameras 591** (Electronics): 97 orders, -6,404.73 cumulative loss

These should be repriced, re-sourced from a lower-cost supplier, or discontinued.

### Which warehouses require replenishment?

4 product-warehouse combinations are currently at or below reorder level out of 19,989 total (0.02%). The warehouses with the most replenishment-needed SKUs are:

- **WH_04**: 1 SKUs below reorder level
- **WH_05**: 1 SKUs below reorder level
- **WH_09**: 1 SKUs below reorder level
- **WH_11**: 1 SKUs below reorder level

These warehouses should be prioritized in the next purchase-order cycle to avoid stockouts on fast-moving SKUs.

### Where are discounts hurting profits the most?

At the 26%+ discount band, the categories with the worst resulting margin are:

- **Electronics**: margin falls to -23.4% at this discount depth
- **Grocery**: margin falls to -17.9% at this discount depth
- **Furniture**: margin falls to -8.2% at this discount depth

This matches the regression finding in statistics.py — discount depth is the single largest negative driver of order profit. Promotional depth in these categories should be capped or paired with cost reductions rather than run as broad blanket discounts.

### Which customers are likely to churn?

**2,138** customers (21.4% of those with any purchase history) have not ordered in 180+ days as of the end of the dataset, and are at high churn risk. These should be the immediate target list for a win-back campaign — typically a personalized discount or 'we miss you' offer for the highest-LTV names in this list, rather than a blanket campaign to all of them (which is what `fact_returns`/RFM Section 4 of analysis_queries.sql already segments by value).

### Inventory optimization recommendations

1. **5 products** hold stock with zero recorded sales across all warehouses — candidates for clearance markdown or return-to-supplier.
2. Network-wide damaged-stock rate is **0.26%** of received stock — worth a root-cause review with the highest-damage-rate suppliers (see Q52 in analysis_queries.sql).
3. Reorder levels should be tiered by region lead time (see Q53) rather than set uniformly — regions with longer average lead times need higher safety stock to hit the same service level.

### Marketing recommendations

1. Online channel share is **57.0%** of revenue and rising year over year — digital acquisition budget should grow proportionally rather than stay fixed to last year's split.
2. Repeat purchase rate is **98.9%** — a retention-focused campaign (the churn-risk list above) likely has better ROI than further top-of-funnel acquisition spend at the margin.
3. Target the win-back list (churn-risk customers) with offers sized to their historical LTV tier rather than a flat discount — Platinum/Gold churn-risk customers justify a deeper, more personalized offer than Bronze.

### Executive recommendations

- Overall net margin is **9.0%** — healthy but discount-sensitive; the regression analysis shows discount depth is the single strongest lever management has over profit per order.
- Return rate of **20.0%** is a material cost center (see Q54 in analysis_queries.sql for the exact refund cost); the Returns Dashboard's reason/category breakdown should drive a cross-functional fix (QA + sizing content + delivery SLAs) rather than a single owner.
- Revenue is structurally seasonal (holiday-quarter dependent) rather than steadily trending — working-capital and staffing plans should be built around that seasonal calendar, not a flat monthly run-rate assumption.
- The 12-month forecast (see forecast_model_scorecard.csv) gives finance a statistically validated basis for next year's revenue planning, rather than a straight-line extrapolation.
