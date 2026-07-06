"""
data_generation.py
===================
Enterprise Retail Analytics Platform — Synthetic Data Generator

Generates a realistic, internally-consistent relational dataset simulating
a multinational retail operation (Walmart / Amazon / Target / Reliance Retail /
Tesco / Costco style footprint).

Design principles applied (so downstream SQL/BI/forecasting work is meaningful,
not just random noise):
    - Customers have real demographic skew (income ~ lognormal, age ~ normal,
      tier driven by computed LTV rather than randomly assigned).
    - Products have category-appropriate price bands and margins (Electronics
      low-margin/high-price, Apparel high-margin/low-price, etc.).
    - Sales have seasonality (Nov-Dec retail spike, mid-year dip), weekday
      effects, channel mix shifting toward Online over time, and a long-tail
      product popularity distribution (a small set of products drive most
      volume — needed for ABC/Pareto analysis to be meaningful).
    - Discounts correlate with sales events (Nov/Dec, end-of-quarter).
    - Returns are correlated with category return-propensity, discount depth,
      and are time-lagged realistically after the order date.
    - Inventory stock levels are internally consistent with sales velocity
      (fast sellers draw down stock faster -> realistic reorder/stockout signal).

Run:
    python data_generation.py

Output (./datasets/):
    customers.csv   (10,000 rows)
    products.csv    (5,000 rows)
    sales.csv       (~100,000 rows)
    inventory.csv   (~20,000 rows, product x warehouse snapshot)
    returns.csv     (20,000 rows)
"""

import numpy as np
import pandas as pd
from datetime import datetime, timedelta
import os

# ----------------------------------------------------------------------------
# Reproducibility
# ----------------------------------------------------------------------------
SEED = 42
rng = np.random.default_rng(SEED)

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "datasets")
os.makedirs(OUTPUT_DIR, exist_ok=True)

N_CUSTOMERS = 10_000
N_PRODUCTS = 5_000
N_SALES = 100_000
N_WAREHOUSES = 20
N_RETURNS = 20_000

SALES_START = datetime(2022, 1, 1)
SALES_END = datetime(2024, 12, 31)
TOTAL_DAYS = (SALES_END - SALES_START).days


# ----------------------------------------------------------------------------
# Reference data
# ----------------------------------------------------------------------------
COUNTRIES = {
    "USA": (["New York", "Los Angeles", "Chicago", "Houston", "Phoenix", "Dallas", "Seattle"],
            ["NY", "CA", "IL", "TX", "AZ", "TX", "WA"]),
    "UK": (["London", "Manchester", "Birmingham", "Leeds", "Glasgow"],
           ["England", "England", "England", "England", "Scotland"]),
    "India": (["Mumbai", "Delhi", "Bengaluru", "Pune", "Hyderabad", "Chennai"],
              ["Maharashtra", "Delhi", "Karnataka", "Maharashtra", "Telangana", "Tamil Nadu"]),
    "Canada": (["Toronto", "Vancouver", "Montreal"], ["Ontario", "British Columbia", "Quebec"]),
}
COUNTRY_WEIGHTS = [0.45, 0.20, 0.25, 0.10]  # market footprint weighting

SEGMENTS = ["Premium", "Regular", "Budget", "New"]
SEGMENT_WEIGHTS = [0.15, 0.45, 0.30, 0.10]

CATEGORY_CONFIG = {
    # category: (subcategories, cost_price_range, margin_range, return_rate, weight)
    "Electronics":      (["Mobiles", "Laptops", "Audio", "Cameras", "Accessories"], (50, 1200), (0.08, 0.20), 0.12, 0.16),
    "Grocery":          (["Snacks", "Beverages", "Dairy", "Staples", "Frozen Foods"], (1, 25), (0.10, 0.25), 0.02, 0.20),
    "Apparel":          (["Men", "Women", "Kids", "Footwear", "Winterwear"], (5, 80), (0.35, 0.60), 0.18, 0.16),
    "Home & Kitchen":   (["Cookware", "Furnishing", "Storage", "Decor", "Appliances"], (8, 300), (0.20, 0.40), 0.09, 0.12),
    "Beauty":           (["Skincare", "Haircare", "Makeup", "Fragrance"], (3, 60), (0.30, 0.55), 0.07, 0.10),
    "Sports & Fitness":  (["Equipment", "Apparel", "Footwear", "Nutrition"], (5, 250), (0.25, 0.45), 0.10, 0.08),
    "Toys & Games":      (["Action Figures", "Educational", "Board Games", "Outdoor"], (4, 90), (0.30, 0.50), 0.11, 0.08),
    "Books & Media":     (["Fiction", "Non-Fiction", "Academic", "Children"], (3, 40), (0.20, 0.35), 0.04, 0.05),
    "Automotive":        (["Parts", "Accessories", "Care Products"], (5, 400), (0.15, 0.35), 0.08, 0.03),
    "Furniture":         (["Living Room", "Bedroom", "Office", "Outdoor"], (40, 1500), (0.15, 0.30), 0.13, 0.02),
}
CATEGORIES = list(CATEGORY_CONFIG.keys())
CATEGORY_WEIGHTS = [v[4] for v in CATEGORY_CONFIG.values()]

BRANDS_BY_CATEGORY = {
    "Electronics": ["Sonex", "Veltrix", "Aurawave", "Pulseon", "NimbusTech"],
    "Grocery": ["FarmFresh", "Nutrivia", "PureHarvest", "DailyBasket", "GreenLeaf"],
    "Apparel": ["UrbanThread", "Stratus", "Clovera", "Denimo", "WearWell"],
    "Home & Kitchen": ["HomeCraft", "KitchPro", "Dweliva", "CasaNova", "Hearthly"],
    "Beauty": ["Glowtra", "Lumeve", "PureSkin", "Velvetta", "Auralis"],
    "Sports & Fitness": ["FitForge", "ProAthlete", "PeakGear", "Enduro", "Striveon"],
    "Toys & Games": ["PlayNest", "Funkido", "Brainary", "Kidzoo", "Wonderplay"],
    "Books & Media": ["InkHouse", "Pagewise", "ChapterOne", "Lorebound"],
    "Automotive": ["GearDrive", "MotoFix", "RoadKing", "AutoEdge"],
    "Furniture": ["WoodCraft", "Furnova", "Comforta", "Loungeify"],
}

SUPPLIERS = [f"Supplier_{i:03d}" for i in range(1, 61)]
PAYMENT_METHODS = ["Credit Card", "Debit Card", "UPI", "Net Banking", "Cash on Delivery", "Wallet", "PayPal"]
PAYMENT_WEIGHTS = [0.28, 0.18, 0.18, 0.10, 0.10, 0.08, 0.08]
CHANNELS = ["Online", "Offline"]
RETURN_REASONS = ["Defective Product", "Wrong Item Delivered", "Size/Fit Issue", "Changed Mind",
                  "Better Price Found Elsewhere", "Late Delivery", "Quality Not as Expected", "Damaged in Transit"]
RETURN_STATUS = ["Approved", "Rejected", "Pending", "Refunded"]
RETURN_STATUS_WEIGHTS = [0.30, 0.08, 0.12, 0.50]

STORES = [f"Store_{i:03d}" for i in range(1, 121)]
REGIONS = ["North", "South", "East", "West", "Central"]
WAREHOUSES = [f"WH_{i:02d}" for i in range(1, N_WAREHOUSES + 1)]
WAREHOUSE_REGION = {wh: REGIONS[i % len(REGIONS)] for i, wh in enumerate(WAREHOUSES)}


def random_dates(start, n_days_range, n, seasonal_weight=True):
    """Generate random dates with retail seasonality (Nov/Dec spike, mid-year dip)."""
    day_offsets = rng.integers(0, n_days_range, size=n)
    dates = [start + timedelta(days=int(d)) for d in day_offsets]
    return pd.to_datetime(dates)


# ----------------------------------------------------------------------------
# 1. CUSTOMERS
# ----------------------------------------------------------------------------
def generate_customers():
    print("Generating customers...")
    customer_ids = [f"CUST{str(i).zfill(6)}" for i in range(1, N_CUSTOMERS + 1)]

    ages = np.clip(rng.normal(38, 13, N_CUSTOMERS), 18, 80).astype(int)
    genders = rng.choice(["Male", "Female", "Other"], size=N_CUSTOMERS, p=[0.48, 0.49, 0.03])

    countries = rng.choice(list(COUNTRIES.keys()), size=N_CUSTOMERS, p=COUNTRY_WEIGHTS)
    cities, states = [], []
    for c in countries:
        city_list, state_list = COUNTRIES[c]
        idx = rng.integers(0, len(city_list))
        cities.append(city_list[idx])
        states.append(state_list[idx])

    segments = rng.choice(SEGMENTS, size=N_CUSTOMERS, p=SEGMENT_WEIGHTS)

    # Income: lognormal for realistic right-skew, scaled per segment
    base_income = rng.lognormal(mean=10.5, sigma=0.45, size=N_CUSTOMERS)
    segment_income_mult = pd.Series(segments).map(
        {"Premium": 1.8, "Regular": 1.0, "Budget": 0.6, "New": 0.9}
    ).values
    income = np.round(base_income * segment_income_mult, -2)

    signup_days_ago = rng.integers(0, 5 * 365, size=N_CUSTOMERS)
    signup_dates = [datetime(2024, 12, 31) - timedelta(days=int(d)) for d in signup_days_ago]

    df = pd.DataFrame({
        "CustomerID": customer_ids,
        "Age": ages,
        "Gender": genders,
        "City": cities,
        "State": states,
        "Country": countries,
        "Segment": segments,
        "Income": income,
        "SignupDate": pd.to_datetime(signup_dates).date,
    })
    # LifetimeValue & LoyaltyTier are computed AFTER sales are generated (see finalize step)
    return df


# ----------------------------------------------------------------------------
# 2. PRODUCTS
# ----------------------------------------------------------------------------
def generate_products():
    print("Generating products...")
    product_ids = [f"PROD{str(i).zfill(6)}" for i in range(1, N_PRODUCTS + 1)]
    categories = rng.choice(CATEGORIES, size=N_PRODUCTS, p=CATEGORY_WEIGHTS)

    subcats, brands, cost_prices, selling_prices, suppliers, launch_dates, names = [], [], [], [], [], [], []

    for cat in categories:
        subcat_list, cost_range, margin_range, _, _ = CATEGORY_CONFIG[cat]
        subcat = rng.choice(subcat_list)
        brand = rng.choice(BRANDS_BY_CATEGORY[cat])

        cost = round(rng.uniform(*cost_range), 2)
        margin = rng.uniform(*margin_range)
        sell = round(cost / (1 - margin), 2)

        subcats.append(subcat)
        brands.append(brand)
        cost_prices.append(cost)
        selling_prices.append(sell)
        suppliers.append(rng.choice(SUPPLIERS))
        launch_days_ago = rng.integers(0, 6 * 365)
        launch_dates.append(datetime(2024, 12, 31) - timedelta(days=int(launch_days_ago)))
        names.append(f"{brand} {subcat} {rng.integers(100, 999)}")

    df = pd.DataFrame({
        "ProductID": product_ids,
        "Category": categories,
        "Subcategory": subcats,
        "Brand": brands,
        "ProductName": names,
        "CostPrice": cost_prices,
        "SellingPrice": selling_prices,
        "Supplier": suppliers,
        "LaunchDate": pd.to_datetime(launch_dates).date,
    })
    return df


# ----------------------------------------------------------------------------
# 3. SALES
# ----------------------------------------------------------------------------
def seasonality_multiplier(date):
    """Retail seasonality: Nov/Dec holiday spike, summer dip, weekend lift."""
    month_mult = {1: 0.85, 2: 0.80, 3: 0.90, 4: 0.95, 5: 1.0, 6: 0.90,
                  7: 0.85, 8: 0.90, 9: 1.0, 10: 1.10, 11: 1.45, 12: 1.65}[date.month]
    weekday_mult = 1.15 if date.weekday() >= 5 else 1.0
    return month_mult * weekday_mult


def generate_sales(customers_df, products_df):
    print("Generating sales (this is the largest table)...")

    # Long-tail product popularity: a small share of products drive most volume (Zipf-like)
    product_popularity = rng.pareto(a=1.3, size=N_PRODUCTS) + 1
    product_popularity = product_popularity / product_popularity.sum()

    # Customer purchase propensity skewed by segment (Premium/Regular buy more often)
    seg_mult = customers_df["Segment"].map({"Premium": 2.2, "Regular": 1.3, "Budget": 0.8, "New": 0.5}).values
    customer_propensity = seg_mult / seg_mult.sum()

    order_ids = [f"ORD{str(i).zfill(7)}" for i in range(1, N_SALES + 1)]

    # Sample raw dates then reweight via seasonality using rejection-free approach:
    # generate candidate dates uniformly, then accept-weight via seasonality by oversampling.
    candidate_n = int(N_SALES * 1.8)
    cand_offsets = rng.integers(0, TOTAL_DAYS, size=candidate_n)
    cand_dates = [SALES_START + timedelta(days=int(d)) for d in cand_offsets]
    weights = np.array([seasonality_multiplier(d) for d in cand_dates])
    weights = weights / weights.sum()
    chosen_idx = rng.choice(candidate_n, size=N_SALES, replace=False, p=weights)
    order_dates = pd.to_datetime([cand_dates[i] for i in chosen_idx])

    cust_idx = rng.choice(N_CUSTOMERS, size=N_SALES, p=customer_propensity)
    prod_idx = rng.choice(N_PRODUCTS, size=N_SALES, p=product_popularity)

    customer_ids = customers_df["CustomerID"].values[cust_idx]
    product_ids = products_df["ProductID"].values[prod_idx]
    cost_prices = products_df["CostPrice"].values[prod_idx]
    selling_prices = products_df["SellingPrice"].values[prod_idx]
    categories = products_df["Category"].values[prod_idx]

    quantities = rng.choice([1, 2, 3, 4, 5], size=N_SALES, p=[0.55, 0.25, 0.12, 0.05, 0.03])

    # Discounts higher in Nov/Dec and end-of-quarter months
    base_discount = rng.beta(1.5, 6, size=N_SALES) * 0.5  # right-skewed, mostly low discounts
    is_promo_month = pd.Series(order_dates.month).isin([3, 6, 9, 11, 12]).values
    discounts = np.round(np.clip(base_discount + is_promo_month * rng.uniform(0.05, 0.15, N_SALES), 0, 0.7), 3)

    gross_amount = selling_prices * quantities
    sales_amount = np.round(gross_amount * (1 - discounts), 2)
    profit = np.round(sales_amount - (cost_prices * quantities), 2)

    # Channel mix shifts toward Online in later years
    year = pd.Series(order_dates.year)
    online_prob = year.map({2022: 0.45, 2023: 0.58, 2024: 0.68}).values
    channels = np.where(rng.random(N_SALES) < online_prob, "Online", "Offline")

    regions = rng.choice(REGIONS, size=N_SALES)
    stores = rng.choice(STORES, size=N_SALES)
    payment_methods = rng.choice(PAYMENT_METHODS, size=N_SALES, p=PAYMENT_WEIGHTS)

    df = pd.DataFrame({
        "OrderID": order_ids,
        "OrderDate": order_dates.date,
        "CustomerID": customer_ids,
        "ProductID": product_ids,
        "Quantity": quantities,
        "Discount": discounts,
        "SalesAmount": sales_amount,
        "Profit": profit,
        "Store": stores,
        "Region": regions,
        "PaymentMethod": payment_methods,
        "SalesChannel": channels,
    })
    return df


# ----------------------------------------------------------------------------
# 4. INVENTORY (product x warehouse snapshot, consistent with sales velocity)
# ----------------------------------------------------------------------------
def generate_inventory(products_df, sales_df):
    print("Generating inventory...")

    sold_by_product = sales_df.groupby("ProductID")["Quantity"].sum()

    rows = []
    for _, prod in products_df.iterrows():
        n_warehouses_for_product = rng.integers(3, 6)  # each product stocked in 3-5 warehouses
        assigned = rng.choice(WAREHOUSES, size=n_warehouses_for_product, replace=False)
        total_sold = int(sold_by_product.get(prod["ProductID"], 0))
        sold_share = rng.dirichlet(np.ones(n_warehouses_for_product))

        for wh, share in zip(assigned, sold_share):
            sold_here = int(round(total_sold * share))
            opening = int(sold_here * rng.uniform(1.2, 2.0)) + rng.integers(10, 100)
            received = int(sold_here * rng.uniform(0.8, 1.5)) + rng.integers(0, 50)
            damaged = int(rng.binomial(max(sold_here, 1), 0.01))
            closing = max(opening + received - sold_here - damaged, 0)
            reorder_level = int(opening * 0.2) + 10
            lead_time = int(rng.integers(2, 21))
            supplier_rating = round(rng.uniform(2.5, 5.0), 1)

            rows.append({
                "ProductID": prod["ProductID"],
                "Warehouse": wh,
                "OpeningStock": opening,
                "ReceivedStock": received,
                "SoldStock": sold_here,
                "DamagedStock": damaged,
                "ClosingStock": closing,
                "ReorderLevel": reorder_level,
                "LeadTimeDays": lead_time,
                "SupplierRating": supplier_rating,
            })

    df = pd.DataFrame(rows)
    # Trim/pad to land near the ~20,000 row target while keeping realism
    if len(df) > 20_000:
        df = df.sample(n=20_000, random_state=SEED).reset_index(drop=True)
    return df


# ----------------------------------------------------------------------------
# 5. RETURNS (correlated with category return-rate & discount depth)
# ----------------------------------------------------------------------------
def generate_returns(sales_df, products_df):
    print("Generating returns...")

    cat_return_rate = {cat: cfg[3] for cat, cfg in CATEGORY_CONFIG.items()}
    prod_cat_map = products_df.set_index("ProductID")["Category"].to_dict()

    sales_df = sales_df.copy()
    sales_df["Category"] = sales_df["ProductID"].map(prod_cat_map)
    sales_df["ReturnProb"] = sales_df["Category"].map(cat_return_rate) + sales_df["Discount"] * 0.15

    # Sample candidate orders weighted by return probability
    probs = sales_df["ReturnProb"].values
    probs = probs / probs.sum()
    candidate_idx = rng.choice(len(sales_df), size=min(N_RETURNS, len(sales_df)), replace=False, p=probs)
    returned_orders = sales_df.iloc[candidate_idx].reset_index(drop=True)

    return_ids = [f"RET{str(i).zfill(6)}" for i in range(1, len(returned_orders) + 1)]
    days_after = rng.choice(range(1, 31), size=len(returned_orders),
                             p=np.array([1 / (d ** 0.7) for d in range(1, 31)]) /
                               sum(1 / (d ** 0.7) for d in range(1, 31)))

    return_dates = pd.to_datetime(returned_orders["OrderDate"]) + pd.to_timedelta(days_after, unit="D")
    reasons = rng.choice(RETURN_REASONS, size=len(returned_orders))
    statuses = rng.choice(RETURN_STATUS, size=len(returned_orders), p=RETURN_STATUS_WEIGHTS)

    refund_amount = np.where(
        np.isin(statuses, ["Approved", "Refunded"]),
        returned_orders["SalesAmount"].values,
        0.0
    )

    df = pd.DataFrame({
        "ReturnID": return_ids,
        "OrderID": returned_orders["OrderID"].values,
        "Reason": reasons,
        "RefundAmount": np.round(refund_amount, 2),
        "ReturnDate": return_dates.dt.date,
        "ReturnStatus": statuses,
        "DaysAfterPurchase": days_after,
    })
    return df


# ----------------------------------------------------------------------------
# Finalize customers: compute real LifetimeValue & LoyaltyTier from sales
# ----------------------------------------------------------------------------
def finalize_customers(customers_df, sales_df):
    print("Finalizing customer LTV & loyalty tiers from actual sales...")
    ltv = sales_df.groupby("CustomerID")["SalesAmount"].sum()
    customers_df["LifetimeValue"] = customers_df["CustomerID"].map(ltv).fillna(0).round(2)

    def tier(v):
        if v >= customers_df["LifetimeValue"].quantile(0.90):
            return "Platinum"
        elif v >= customers_df["LifetimeValue"].quantile(0.70):
            return "Gold"
        elif v >= customers_df["LifetimeValue"].quantile(0.40):
            return "Silver"
        return "Bronze"

    customers_df["LoyaltyTier"] = customers_df["LifetimeValue"].apply(tier)
    return customers_df


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main():
    customers_df = generate_customers()
    products_df = generate_products()
    sales_df = generate_sales(customers_df, products_df)
    customers_df = finalize_customers(customers_df, sales_df)
    inventory_df = generate_inventory(products_df, sales_df)
    returns_df = generate_returns(sales_df, products_df)

    customers_df.to_csv(os.path.join(OUTPUT_DIR, "customers.csv"), index=False)
    products_df.to_csv(os.path.join(OUTPUT_DIR, "products.csv"), index=False)
    sales_df.to_csv(os.path.join(OUTPUT_DIR, "sales.csv"), index=False)
    inventory_df.to_csv(os.path.join(OUTPUT_DIR, "inventory.csv"), index=False)
    returns_df.to_csv(os.path.join(OUTPUT_DIR, "returns.csv"), index=False)

    print("\n--- Generation complete ---")
    print(f"Customers : {len(customers_df):,} rows -> customers.csv")
    print(f"Products  : {len(products_df):,} rows -> products.csv")
    print(f"Sales     : {len(sales_df):,} rows -> sales.csv")
    print(f"Inventory : {len(inventory_df):,} rows -> inventory.csv")
    print(f"Returns   : {len(returns_df):,} rows -> returns.csv")

    print("\n--- Quick sanity stats ---")
    print(f"Total Revenue      : {sales_df['SalesAmount'].sum():,.2f}")
    print(f"Total Profit       : {sales_df['Profit'].sum():,.2f}")
    print(f"Avg Order Value    : {sales_df['SalesAmount'].mean():,.2f}")
    print(f"Overall Return Rate: {len(returns_df) / len(sales_df):.2%}")
    print(f"Online Share       : {(sales_df['SalesChannel'] == 'Online').mean():.2%}")


if __name__ == "__main__":
    main()
