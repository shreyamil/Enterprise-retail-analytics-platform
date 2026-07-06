# Data Dictionary — Enterprise Retail Analytics Platform

Auto-stats sourced from the live datasets on generation. All counts verified
against `datasets/*.csv`. Last updated from Phase 1 data generation run.

---

## Table: customers (dim_customers in PostgreSQL)

**Purpose:** One row per registered customer. Dimension table — joins to
`fact_sales` on `CustomerID`. `LifetimeValue` and `LoyaltyTier` are
*derived* fields refreshed by `python/cleaning.py` from actual sales data,
not entered by customers or ops.

**Row count:** 10,000 | **Null fields:** None | **Duplicate PKs:** 0

| Column | PG Type | Unique | Sample | Business Definition | Constraints |
|---|---|---|---|---|---|
| CustomerID | VARCHAR(10) | 10,000 | CUST000001 | Surrogate primary key. Format: CUST + 6-digit zero-padded integer | PK, NOT NULL |
| Age | SMALLINT | 63 | 41 | Customer age in years at time of data snapshot | 0–110 |
| Gender | VARCHAR(10) | 3 | Female | Male / Female / Other | NOT NULL |
| City | VARCHAR(60) | 21 | Houston | City of residence | — |
| State | VARCHAR(60) | 16 | TX | State or province | — |
| Country | VARCHAR(60) | 4 | USA | One of: USA, UK, India, Canada | — |
| Segment | VARCHAR(20) | 4 | Regular | Operational customer tier: Premium / Regular / Budget / New. Based on income & signup recency at registration time | CHECK IN ('Premium','Regular','Budget','New') |
| Income | NUMERIC(12,2) | 1,139 | 20400.00 | Annual household income in USD equivalent. Lognormal distribution, right-skewed (mean ~$40K, long tail to $500K+) | ≥ 0 |
| SignupDate | DATE | 1,821 | 2022-09-15 | Date of account creation. Range: up to 5 years before snapshot date | NOT NULL |
| LifetimeValue | NUMERIC(14,2) | 9,919 | 1184.79 | **Derived.** Sum of all `SalesAmount` in `fact_sales` for this customer. Refreshed by `refresh_customer_ltv()` stored procedure | DEFAULT 0 |
| LoyaltyTier | VARCHAR(10) | 4 | Bronze | **Derived.** Quartile-based tier computed from LifetimeValue: Platinum (≥P90) / Gold (P70–P90) / Silver (P40–P70) / Bronze (<P40) | CHECK IN ('Platinum','Gold','Silver','Bronze') |

---

## Table: products (dim_products in PostgreSQL)

**Purpose:** One row per stock-keeping unit (SKU). Dimension table — joins
to `fact_sales` and `fact_inventory` on `ProductID`.

**Row count:** 5,000 | **Null fields:** None | **Duplicate PKs:** 0

| Column | PG Type | Unique | Sample | Business Definition | Constraints |
|---|---|---|---|---|---|
| ProductID | VARCHAR(10) | 5,000 | PROD000001 | Surrogate PK. Format: PROD + 6-digit zero-padded integer | PK, NOT NULL |
| Category | VARCHAR(40) | 10 | Apparel | Top-level merchandise category. One of: Electronics, Grocery, Apparel, Home & Kitchen, Beauty, Sports & Fitness, Toys & Games, Books & Media, Automotive, Furniture | NOT NULL |
| Subcategory | VARCHAR(40) | 40 | Winterwear | Second-level category within each Category. 4–5 subcategories per category | — |
| Brand | VARCHAR(40) | 47 | WearWell | Brand name. 4–5 brands per category, synthetic names | — |
| ProductName | VARCHAR(120) | 4,941 | WearWell Winterwear 328 | Composite name: Brand + Subcategory + random 3-digit ID | — |
| CostPrice | NUMERIC(10,2) | 4,243 | 79.92 | Unit cost to the retailer (COGS basis). Category-appropriate range: Grocery $1–$25, Electronics $50–$1,200, Furniture $40–$1,500 | ≥ 0 |
| SellingPrice | NUMERIC(10,2) | 4,520 | 134.08 | Retail list price before any order-level discount. Always ≥ CostPrice in clean data | ≥ 0 |
| Supplier | VARCHAR(20) | 60 | Supplier_045 | Supplier code. 60 suppliers across all categories | — |
| LaunchDate | DATE | 1,974 | 2019-04-03 | Date the product was first available for sale. Range: up to 6 years before snapshot | — |

**Implied gross margin:** `(SellingPrice - CostPrice) / SellingPrice`. Ranges by category:
Electronics 8–20%, Grocery 10–25%, Apparel 35–60%, Furniture 15–30%.

---

## Table: sales (fact_sales in PostgreSQL)

**Purpose:** Primary fact table. One row per order line (each row is one
product within one order — orders with multiple products produce multiple rows
sharing the same `OrderID` prefix, each with a unique `OrderID` in this
synthetic dataset, which simplifies the star schema without materially changing
any analysis).

**Row count:** 100,000 | **Null fields:** None | **Duplicate PKs:** 0

| Column | PG Type | Unique | Sample | Business Definition | Constraints |
|---|---|---|---|---|---|
| OrderID | VARCHAR(12) | 100,000 | ORD0000001 | Surrogate PK. Format: ORD + 7-digit integer | PK, NOT NULL |
| OrderDate | DATE | 1,095 | 2023-01-28 | Date the order was placed. Range: 2022-01-01 to 2024-12-30. Distribution weighted by retail seasonality (Nov/Dec spike, weekend lift) | NOT NULL |
| CustomerID | VARCHAR(10) | 9,977 | CUST000252 | FK to `dim_customers`. 23 customers never made a purchase (new signups at dataset close) | FK, NOT NULL |
| ProductID | VARCHAR(10) | 4,999 | PROD002151 | FK to `dim_products`. One product never sold (dead stock candidate) | FK, NOT NULL |
| Quantity | SMALLINT | 5 | 2 | Units ordered. Distribution: 1 (55%), 2 (25%), 3 (12%), 4 (5%), 5 (3%) | > 0 |
| Discount | NUMERIC(5,3) | 503 | 0.016 | Fractional discount applied (0 = no discount, 0.3 = 30% off). Higher in Nov/Dec/end-of-quarter months | 0–1 |
| SalesAmount | NUMERIC(12,2) | 44,647 | 1313.34 | Net revenue: `SellingPrice × Quantity × (1 − Discount)` | ≥ 0, NOT NULL |
| Profit | NUMERIC(12,2) | 24,847 | 201.76 | `SalesAmount − (CostPrice × Quantity)`. Can be negative for high-discount transactions. Enforced/recomputed by `trg_sales_profit_check` trigger | NOT NULL |
| Store | VARCHAR(15) | 120 | Store_053 | Store identifier. 120 stores, FK to `dim_stores`. Offline-channel sales reference a physical store; Online-channel sales also reference a notional fulfillment store | FK, NOT NULL |
| Region | VARCHAR(20) | 5 | East | One of: North / South / East / West / Central. Denormalized in the CSV layer; extracted to `dim_stores` in the PostgreSQL schema | — |
| PaymentMethod | VARCHAR(20) | 7 | Net Banking | One of: Credit Card, Debit Card, UPI, Net Banking, Cash on Delivery, Wallet, PayPal | — |
| SalesChannel | VARCHAR(10) | 2 | Offline | Online or Offline. Online share increases from 45% (2022) → 68% (2024) | CHECK IN ('Online','Offline') |

---

## Table: inventory (fact_inventory in PostgreSQL)

**Purpose:** Inventory snapshot per product per warehouse. One row per
product–warehouse pair, representing end-of-period stock levels. Stock levels
are internally consistent with `fact_sales` sold quantities (fast-selling
products show lower closing stock, correctly triggering reorder alerts).

**Row count:** 19,989 | **Null fields:** None | **Unique (product, warehouse):** 19,989

| Column | PG Type | Unique | Sample | Business Definition | Constraints |
|---|---|---|---|---|---|
| ProductID | VARCHAR(10) | 5,000 | PROD000001 | FK to `dim_products` | FK, NOT NULL |
| Warehouse | VARCHAR(10) | 20 | WH_08 | Warehouse identifier. 20 warehouses, FK to `dim_warehouses`. Each product stocked in 3–5 warehouses | FK, NOT NULL |
| OpeningStock | INTEGER | 346 | 91 | Units on hand at start of period | ≥ 0 |
| ReceivedStock | INTEGER | 267 | 9 | Units received from supplier during period | ≥ 0 |
| SoldStock | INTEGER | 220 | 1 | Units dispatched to customers during period (consistent with `fact_sales` for this product) | ≥ 0 |
| DamagedStock | INTEGER | 12 | 0 | Units written off as damaged. ~1% of received stock; network average 0.26% | ≥ 0 |
| ClosingStock | INTEGER | 381 | 99 | End-of-period units: `Opening + Received − Sold − Damaged`. A trigger warns on reconciliation mismatches | ≥ 0 |
| ReorderLevel | INTEGER | 129 | 28 | Minimum closing stock below which a replenishment PO should be raised. Set to ≈20% of opening stock + 10 | ≥ 0 |
| LeadTimeDays | SMALLINT | 19 | 18 | Days from PO placement to stock arrival. Used to size safety stock by region (see Q53) | ≥ 0 |
| SupplierRating | NUMERIC(3,1) | 26 | 3.5 | Supplier quality rating (2.5–5.0). Tested for correlation with damage rate in Q52 and `statistics.py` | 0–5 |

---

## Table: returns (fact_returns in PostgreSQL)

**Purpose:** One row per return event. Each return references a specific
`OrderID` from `fact_sales` — the model doesn't allow a return without an
underlying sale (enforced by FK with ON DELETE RESTRICT).

**Row count:** 20,000 | **Null fields:** None | **Duplicate ReturnIDs:** 0

| Column | PG Type | Unique | Sample | Business Definition | Constraints |
|---|---|---|---|---|---|
| ReturnID | VARCHAR(12) | 20,000 | RET000001 | Surrogate PK. Format: RET + 6-digit integer | PK, NOT NULL |
| OrderID | VARCHAR(12) | 20,000 | ORD0087799 | FK to `fact_sales`. Each returned order appears once | FK, NOT NULL |
| Reason | VARCHAR(60) | 8 | Wrong Item Delivered | Return reason chosen by the customer. One of: Defective Product, Wrong Item Delivered, Size/Fit Issue, Changed Mind, Better Price Found Elsewhere, Late Delivery, Quality Not as Expected, Damaged in Transit | — |
| RefundAmount | NUMERIC(12,2) | 13,259 | 0.00 | Amount refunded. Non-zero only for Approved/Refunded status. For Rejected/Pending status = 0 | ≥ 0 |
| ReturnDate | DATE | 1,122 | 2023-11-08 | Date the return was registered. Always ≥ `OrderDate`. Distribution right-skewed (most returns within 7 days) | NOT NULL |
| ReturnStatus | VARCHAR(15) | 4 | Pending | Current status: Approved (30%) / Rejected (8%) / Pending (12%) / Refunded (50%) | CHECK IN ('Approved','Rejected','Pending','Refunded') |
| DaysAfterPurchase | SMALLINT | 30 | 17 | `ReturnDate − OrderDate` in calendar days. Range 1–30. Power-law distribution: most returns happen soon after purchase | ≥ 0 |

---

## Derived Dimension: dim_stores (PostgreSQL only — not a raw CSV)

**Generated by:** `python/cleaning.py` → `derive_dim_stores()` which extracts
the most frequent Region for each Store from `fact_sales` (Region is
functionally dependent on Store, extracted to satisfy 3NF).

| Column | Type | Notes |
|---|---|---|
| store_id | VARCHAR(15) PK | 120 distinct stores |
| region | VARCHAR(20) | One of: North / South / East / West / Central |

---

## Derived Dimension: dim_warehouses (PostgreSQL only — not a raw CSV)

**Generated by:** `python/cleaning.py` → `derive_dim_warehouses()`. Region
assigned to each warehouse by round-robin across the 5 region codes (consistent
with how the generator assigns inventory to warehouses).

| Column | Type | Notes |
|---|---|---|
| warehouse_id | VARCHAR(10) PK | 20 warehouses (WH_01 – WH_20) |
| region | VARCHAR(20) | One of: North / South / East / West / Central |

---

## Relationships Summary

| Relationship | Type | Cardinality |
|---|---|---|
| fact_sales.CustomerID → dim_customers | FK, RESTRICT delete | Many-to-1 |
| fact_sales.ProductID → dim_products | FK, RESTRICT delete | Many-to-1 |
| fact_sales.StoreID → dim_stores | FK, RESTRICT delete | Many-to-1 |
| fact_inventory.ProductID → dim_products | FK, RESTRICT delete | Many-to-1 |
| fact_inventory.WarehouseID → dim_warehouses | FK, RESTRICT delete | Many-to-1 |
| fact_returns.OrderID → fact_sales | FK, RESTRICT delete | Many-to-1 |
