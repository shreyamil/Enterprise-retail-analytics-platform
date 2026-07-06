# Power BI Data Model — Enterprise Retail Analytics Platform

> **Note on scope:** Power BI Desktop is a Windows GUI application and cannot run in
> this build environment, so a `.pbix` binary file cannot be generated directly here.
> What follows is the complete, ready-to-use blueprint: the star schema, every Power
> Query load step, the Date dimension DAX, and (in `dax_measures.dax`) 50+ measures.
> Importing the 5 CSVs from `datasets/` (or connecting directly to the PostgreSQL
> tables from `sql/schema.sql`) and pasting these measures in will produce the exact
> model described here in under 15 minutes in Power BI Desktop.

---

## 1. Star Schema

This mirrors `sql/schema.sql` exactly — the dimensional model was designed once, in
SQL, and Power BI just inherits it. That's intentional: a model that's normalized at
the database layer doesn't need to be re-flattened or re-thought for BI.

```
                        ┌──────────────────┐
                        │   dim_customers   │
                        └─────────┬────────┘
                                  │ 1
                                  │
                                  │ *
┌──────────────────┐    ┌────────┴─────────┐    ┌──────────────────┐
│   dim_products    │ *──┤    fact_sales     ├──* │    dim_stores     │
└──────────────────┘    └────────┬─────────┘    └──────────────────┘
         │ 1                      │
         │                        │ 1
         │ *                      │
┌────────┴─────────┐    ┌────────┴─────────┐
│  fact_inventory   │    │   fact_returns    │
└────────┬─────────┘    └──────────────────┘
         │ *
         │
         │ 1
┌────────┴─────────┐
│  dim_warehouses   │
└──────────────────┘

                ┌──────────────────┐
                │     dim_date      │  (built in Power BI, see §3)
                └──────────────────┘
                  connects to OrderDate on fact_sales,
                  ReturnDate on fact_returns (inactive),
                  and snapshot logic on fact_inventory
```

**Relationship cardinality (set these explicitly in Model view — don't rely on
autodetect):**

| From | To | Cardinality | Cross-filter |
|---|---|---|---|
| fact_sales.customer_id | dim_customers.customer_id | Many-to-1 | Single |
| fact_sales.product_id | dim_products.product_id | Many-to-1 | Single |
| fact_sales.store_id | dim_stores.store_id | Many-to-1 | Single |
| fact_inventory.product_id | dim_products.product_id | Many-to-1 | Single |
| fact_inventory.warehouse_id | dim_warehouses.warehouse_id | Many-to-1 | Single |
| fact_returns.order_id | fact_sales.order_id | Many-to-1 | Single |
| dim_date.Date | fact_sales.OrderDate | 1-to-Many | Single (**Active**) |
| dim_date.Date | fact_returns.ReturnDate | 1-to-Many | Single (**Inactive** — see `[Refunds (by Return Date)]` measure using USERELATIONSHIP) |

**Why one fact table (`fact_sales`) is the hub:** Every dashboard page's primary
trend line is sales-driven. Inventory and Returns are satellite facts that join back
through `product_id` / `order_id` respectively — this keeps the model a clean star,
not a snowflake, which matters for DAX performance (avoid many-hop relationship chains).

---

## 2. Power Query (M) Load Steps

If loading from the CSVs directly rather than PostgreSQL:

1. **Get Data → Folder** → point at `datasets/`
2. For each CSV, set explicit column types on load (don't trust auto-detect for
   dates — it will misparse `OrderDate`/`SignupDate`/`LaunchDate`/`ReturnDate` if any
   regional locale settings differ):

```m
// Example: sales.csv load step (apply equivalent pattern to the other 4 files)
let
    Source = Csv.Document(File.Contents("sales.csv"), [Delimiter=",", Columns=12, Encoding=65001, QuoteStyle=QuoteStyle.None]),
    PromotedHeaders = Table.PromoteHeaders(Source, [PromoteAllScalars=true]),
    ChangedType = Table.TransformColumnTypes(PromotedHeaders,{
        {"OrderID", type text}, {"OrderDate", type date}, {"CustomerID", type text},
        {"ProductID", type text}, {"Quantity", Int64.Type}, {"Discount", type number},
        {"SalesAmount", type number}, {"Profit", type number}, {"Store", type text},
        {"Region", type text}, {"PaymentMethod", type text}, {"SalesChannel", type text}
    })
in
    ChangedType
```

3. **Disable Load** on any staging/reference queries you create for the `dim_stores`
   / `dim_warehouses` derivation (mirror the `derive_dim_stores` / `derive_dim_warehouses`
   logic from `python/cleaning.py` in M if loading from flat CSVs instead of Postgres) —
   only load the final shaped tables into the model.
4. **Set Data Categories**: `City` → City, `State` → State/Province, `Country` → Country
   on `dim_customers` (enables the map visuals on the Sales Dashboard region page).

---

## 3. Date Dimension (dim_date)

A real Date table is mandatory for the YTD/MTD/QTD/rolling-12 DAX measures —
auto date/time hierarchies in Power BI **do not** support `DATEADD`/`SAMEPERIODLASTYEAR`
reliably across fiscal logic and will silently break period-over-period measures.

Create via **New Table** (Modeling tab) using `CALENDAR`, not Power Query, so it
recalculates automatically as fact data grows:

```dax
dim_date =
ADDCOLUMNS(
    CALENDAR(DATE(2022,1,1), DATE(2025,12,31)),
    "Year", YEAR([Date]),
    "Month Number", MONTH([Date]),
    "Month Name", FORMAT([Date], "MMMM"),
    "Month Short", FORMAT([Date], "MMM"),
    "Quarter", "Q" & FORMAT([Date], "Q"),
    "Year-Month", FORMAT([Date], "YYYY-MM"),
    "Day of Week", FORMAT([Date], "dddd"),
    "Is Weekend", IF(WEEKDAY([Date], 2) > 5, TRUE, FALSE),
    "Fiscal Year", YEAR([Date])   -- adjust if fiscal year != calendar year
)
```

Then: **Mark as Date Table** (right-click `dim_date` → Mark as date table → column `Date`),
and sort `Month Name` by `Month Number` (Column tool → Sort by Column) so monthly
visuals don't sort alphabetically (April before January).

Relationship: `dim_date[Date]` (1) → `fact_sales[OrderDate]` (Many), active.

---

## 4. Auxiliary Tables Required by dax_measures.dax

Three small tables in `dax_measures.dax` aren't part of the core 5 CSVs — create
them as follows before pasting the measures in:

**`KPI Selector`** (disconnected table, powers the Dynamic KPI measures in
Category 7). Create via **Enter Data**:

| KPI Name |
|---|
| Revenue |
| Profit |
| Orders |
| Margin % |
| AOV |

**`Targets`** (powers Category 9 — Variance Analysis). Either **Enter Data**
manually with your actual monthly revenue targets, or skip this category
entirely if no formal target-setting process exists yet:

| Month | TargetRevenue |
|---|---|
| 2022-01-01 | 900000 |
| ... | ... |

Relate `Targets[Month]` to `dim_date[Date]` (Many-to-1).

**`Forecast`** (powers Category 10). Get Data → CSV → import
`docs/revenue_forecast_next_12_months.csv` directly (generated by
`python/forecasting.py`) — no manual entry needed. No relationship to
`dim_date` is required since it occupies a future date range the historical
date table doesn't cover; the forecast visuals reference `Forecast[Month]`
on their own axis instead.
