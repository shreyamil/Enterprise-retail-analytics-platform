# Power BI Dashboard Specification — Enterprise Retail Analytics Platform

Six pages, each with its visuals, the fields/measures feeding them, and the
business question it answers. Build order matters: build the Executive page
last, since it borrows visuals/measures already proven out on the other five.

---

## Page 1 — Executive Dashboard

**Audience:** CEO, CFO, VP Retail. **Goal:** answer "how is the business doing"
in under 15 seconds.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| 4 KPI cards (top strip) | `[Total Revenue]`, `[Total Profit]`, `[Gross Margin %]`, `[Average Order Value]`, each with `[MoM Growth %]` as the card's trend indicator | The four numbers leadership asks for first |
| Line chart: Revenue & Profit trend | `dim_date[Date]` (axis), `[Total Revenue]`, `[Total Profit]` (values), `[Revenue YTD]` as a reference line | Is the trend healthy, and is profit keeping pace with revenue |
| Combo chart: Revenue vs Forecast | `dim_date[Date]`, `[Total Revenue]` (columns), `[Forecasted Revenue]` + `[Forecast Lower Bound]`/`[Forecast Upper Bound]` (line + band) | Are we on track vs the statistically modeled forecast (not a guess) |
| Donut: Revenue by Category | `dim_products[Category]`, `[Total Revenue]` | Where the business's revenue actually comes from |
| Card row: Growth strip | `[MoM Growth %]`, `[QoQ Growth %]`, `[YoY Growth %]`, each using `[Growth Trend Icon]` for conditional ▲/▼ | Momentum at three different cadences |
| Slicer | `'KPI Selector'[KPI Name]` driving `[Selected KPI Value]` and `[Dynamic Dashboard Title]` | Lets the exec swap the whole page's focus KPI without rebuilding visuals |

**Page-level filter:** none (this page should always show the full business).

---

## Page 2 — Sales Dashboard

**Audience:** VP Sales, Regional Directors. **Goal:** regional/store/category
performance detail.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| Filled map | `dim_stores[Region]` / `dim_customers[Country]`, `[Total Revenue]` (color saturation) | Where geographically is revenue concentrated |
| Bar chart: Revenue by Region | `dim_stores[Region]`, `[Total Revenue]`, `[Revenue Variance % vs Target]` as a secondary axis | Which regions are over/under-performing |
| Table: Top 10 Stores | `dim_stores[StoreID]`, `[Total Revenue]`, `[Store Revenue Rank]`, `[MoM Growth %]` | Store ops review — best practice sharing candidates |
| Matrix: Category x Month heatmap | `dim_products[Category]` (rows), `dim_date[Month Name]` (columns), `[Total Revenue]` (values, conditional-formatted as heatmap) | Visualizes the seasonality found in `statistics.py`'s decomposition directly |
| Line chart: Monthly trend by Channel | `dim_date[Date]`, `fact_sales[SalesChannel]` (legend), `[Total Revenue]` | Tracks the Online/Offline mix shift over time |
| Card: Average Order Value + sparkline | `[Average Order Value]` | Basket-value health check |

**Page-level slicers:** Region, Category, Sales Channel, Date range.

---

## Page 3 — Customer Dashboard

**Audience:** CRM/Loyalty team, CMO. **Goal:** who the customers are and how
to retain/grow them.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| Scatter: RFM plot | `vw_customer_rfm.recency_days` (x), `frequency` (y), `monetary` (bubble size), colored by R/F/M-derived segment | Visual RFM segmentation straight from `sql/optimization.sql`'s view |
| Donut: Loyalty Tier mix | `dim_customers[LoyaltyTier]`, `[Distinct Customers]` | Tier distribution at a glance |
| Card: Average LTV, Repeat Purchase Rate, Churn Risk Customers | `[Average Customer Lifetime Value]`, `[Repeat Purchase Rate]`, `[Churn Risk Customers]` | The three numbers retention strategy is built around |
| Line chart: Cohort retention curves | `month_number` (x, from Q28's cohort query), `retention_pct` (y), one line per `cohort_month` | Are newer signup cohorts retaining better than older ones |
| Table: Top 20 by LTV | `dim_customers[CustomerID]`, `LifetimeValue`, `LoyaltyTier`, favorite category (from Q35) | VIP account list for CRM outreach |
| Bar: Revenue by Segment | `dim_customers[Segment]`, `[Total Revenue]`, `[Profit per Customer]` | Validates which segment is genuinely most valuable (see `business_insights.md`) |

**Page-level slicers:** Loyalty Tier, Segment, Country.

---

## Page 4 — Inventory Dashboard

**Audience:** Supply Chain / Ops leadership. **Goal:** stock health and
replenishment priorities.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| Card row | `[Inventory Turnover Ratio]`, `[Stockout Rate %]`, count of Dead Stock SKUs (`[Dead Stock Flag]`) | Top-line inventory health |
| Table: Reorder Alerts | `fact_inventory[ProductID]`, `Warehouse`, `ClosingStock`, `ReorderLevel`, `LeadTimeDays`, conditional-formatted red when `ClosingStock <= ReorderLevel` | Direct procurement action list (mirrors Q47) |
| Bar: Stockout Rate by Warehouse | `dim_warehouses[WarehouseID]`, `[Stockout Rate %]` | Which warehouses have a replenishment-process problem, not just a demand problem |
| Scatter: ABC vs Turnover | `vw_product_abc.abc_class` (color), `cumulative_pct` (x), `[Inventory Turnover Ratio]` (y) | Cross-references revenue priority (ABC) against stock efficiency |
| Table: Dead Stock list | Products where `[Dead Stock Flag] = "Dead Stock"`, sorted by stock value tied up | Clearance/return-to-supplier candidates |
| Gauge: Inventory Health Score | `vw_inventory_health.inventory_health_score` (avg) | Single composite number for the ops weekly review |

**Page-level slicers:** Warehouse, Region, Category.

---

## Page 5 — Returns Dashboard

**Audience:** Customer Experience / QA leadership. **Goal:** why things come
back and what it costs.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| Card row | `[Return Rate %]`, `[Total Refunds]`, `[Refund Cost Ratio]` | Headline cost-of-returns numbers |
| Bar: Refund Cost by Reason | `fact_returns[Reason]`, `[Total Refunds]` | Where to focus the fix (QA vs sizing vs delivery SLAs) |
| Bar: Return Rate by Category | `dim_products[Category]`, `[Return Rate %]` | Problem-category identification (mirrors Q56) |
| Table: Problem Products | `dim_products[ProductID]`, `Supplier`, return rate, order count, filtered to >=10 orders | Supplier escalation list (mirrors Q57) |
| Funnel: Return Status | `fact_returns[ReturnStatus]` (Approved/Rejected/Pending/Refunded) | Spot backlog (high Pending) or high rejection friction |
| Line: Days-to-Return distribution by Reason | `fact_returns[DaysAfterPurchase]` (binned), `Reason` (legend) | Distinguishes fast "changed mind" returns from slow "defective" returns |

**Page-level slicers:** Category, Return Reason, Date range.

---

## Page 6 — Forecast Dashboard

**Audience:** Finance / FP&A. **Goal:** statistically grounded forward view.

| Visual | Fields / Measures | Business Question Answered |
|---|---|---|
| Line + band chart | `Forecast[Month]`, `[Forecasted Revenue]` (line), `[Forecast Lower Bound]`/`[Forecast Upper Bound]` (shaded band), historical `[Total Revenue]` for context | The core "next 12 months" forecast visual |
| Table: Model Scorecard | `forecast_model_scorecard.csv` columns (Model, RMSE, MAE, MAPE) | Transparency on *which* model was used and why (lowest MAPE) — builds stakeholder trust vs a black-box number |
| Card: Selected month forecast + CI | `[Forecasted Revenue]`, `[Forecast Lower Bound]`, `[Forecast Upper Bound]` for a slicer-selected month | Drill into any specific future month |
| Card: `[Is Actuals Within Forecast CI]` | Once new actuals land, flags whether the forecast is tracking | Ongoing forecast-accuracy monitoring, not a one-time exercise |
| Bar: Seasonal Index by Month | Decomposition output from `statistics.py` (`decomposition.seasonal`) loaded as a table | Explains *why* the forecast has the shape it does (Nov/Dec peak) |

**Page-level filter:** none — this page is inherently forward-looking and
shouldn't be sliced by historical dimensions other than the month selector.

---

## Cross-Page Conventions

- **Color**: Revenue = blue, Profit = green, Returns/Refunds = red/orange,
  Forecast = dashed/lighter shade of the Revenue color — consistent across
  all 6 pages so a viewer doesn't have to re-learn the legend per page.
- **Drill-through**: Set up a drill-through page from any Product/Customer/
  Store visual to a detail page filtered to that single entity — avoids
  cluttering the main 6 pages with every possible cut.
- **Tooltips**: Use report-page tooltips on the Executive Dashboard's trend
  line to show the Section-1-style KPI breakdown on hover, rather than
  forcing a click-through.
