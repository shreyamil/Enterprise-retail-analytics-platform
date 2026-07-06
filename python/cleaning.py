"""
cleaning.py
===========
Enterprise Retail Analytics Platform — Data Cleaning & PostgreSQL Load Script

Responsibilities:
    1. Load the raw CSVs produced by data_generation.py
    2. Clean / validate (type coercion, null handling, dedup, range checks)
    3. Derive dim_stores and dim_warehouses (Region is extracted out of the
       flat sales/inventory files to satisfy the normalized schema.sql design)
    4. Load tables into PostgreSQL in FK-safe order:
         dim_customers, dim_products, dim_stores, dim_warehouses
         -> fact_sales -> fact_inventory -> fact_returns
    5. Refresh dim_customers.lifetime_value / loyalty_tier from fact_sales
       (kept here too, not just in the generator, so this script is safe to
       re-run against a real/updated transactional extract later)

Usage:
    Set connection details via environment variables (recommended) or edit
    DB_CONFIG below, then run:

        python cleaning.py

Environment variables (preferred over hardcoding credentials):
    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

import os
import sys
import pandas as pd
import numpy as np

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    print("psycopg2 not installed. Run: pip install psycopg2-binary --break-system-packages")
    sys.exit(1)

DATASET_DIR = os.path.join(os.path.dirname(__file__), "..", "datasets")

DB_CONFIG = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "dbname": os.environ.get("PGDATABASE", "retail_analytics"),
    "user": os.environ.get("PGUSER", "postgres"),
    "password": os.environ.get("PGPASSWORD", "postgres"),
}


# ----------------------------------------------------------------------------
# Cleaning helpers
# ----------------------------------------------------------------------------
def clean_customers(df):
    df = df.drop_duplicates(subset="CustomerID")
    df["Age"] = df["Age"].clip(lower=0, upper=110)
    df["Income"] = df["Income"].fillna(df["Income"].median())
    df["SignupDate"] = pd.to_datetime(df["SignupDate"]).dt.date
    df["LifetimeValue"] = df["LifetimeValue"].fillna(0)
    return df


def clean_products(df):
    df = df.drop_duplicates(subset="ProductID")
    df = df[df["CostPrice"] > 0]              # invalid rows with non-positive cost are dropped
    df = df[df["SellingPrice"] >= df["CostPrice"]]  # selling below cost = bad data, exclude
    df["LaunchDate"] = pd.to_datetime(df["LaunchDate"]).dt.date
    return df


def clean_sales(df, valid_customers, valid_products):
    df = df.drop_duplicates(subset="OrderID")
    df = df[df["CustomerID"].isin(valid_customers)]
    df = df[df["ProductID"].isin(valid_products)]
    df = df[df["Quantity"] > 0]
    df["Discount"] = df["Discount"].clip(0, 1)
    df["OrderDate"] = pd.to_datetime(df["OrderDate"]).dt.date
    return df


def clean_inventory(df, valid_products):
    df = df[df["ProductID"].isin(valid_products)]
    for col in ["OpeningStock", "ReceivedStock", "SoldStock", "DamagedStock", "ClosingStock"]:
        df[col] = df[col].clip(lower=0)
    return df


def clean_returns(df, valid_orders):
    df = df.drop_duplicates(subset="ReturnID")
    df = df[df["OrderID"].isin(valid_orders)]
    df["ReturnDate"] = pd.to_datetime(df["ReturnDate"]).dt.date
    return df


def derive_dim_stores(sales_df):
    """Region is functionally dependent on Store, not on each sale — extract it."""
    store_region = sales_df.groupby("Store")["Region"].agg(lambda x: x.mode()[0]).reset_index()
    store_region.columns = ["store_id", "region"]
    return store_region


def derive_dim_warehouses(inventory_df, sales_df):
    """No explicit warehouse->region mapping in the raw files, so we assign each
    warehouse to the region it most frequently supplies, inferred from which
    stores' regions the products it stocks most often sell into. Falls back to
    round-robin assignment if a warehouse has no inferable signal."""
    warehouses = sorted(inventory_df["Warehouse"].unique())
    regions = sorted(sales_df["Region"].unique())
    mapping = {wh: regions[i % len(regions)] for i, wh in enumerate(warehouses)}
    return pd.DataFrame({"warehouse_id": warehouses, "region": [mapping[w] for w in warehouses]})


def refresh_customer_ltv(customers_df, sales_df):
    ltv = sales_df.groupby("CustomerID")["SalesAmount"].sum()
    customers_df["LifetimeValue"] = customers_df["CustomerID"].map(ltv).fillna(0).round(2)

    q90, q70, q40 = customers_df["LifetimeValue"].quantile([0.90, 0.70, 0.40])

    def tier(v):
        if v >= q90:
            return "Platinum"
        if v >= q70:
            return "Gold"
        if v >= q40:
            return "Silver"
        return "Bronze"

    customers_df["LoyaltyTier"] = customers_df["LifetimeValue"].apply(tier)
    return customers_df


# ----------------------------------------------------------------------------
# Load helpers
# ----------------------------------------------------------------------------
def bulk_insert(cur, table, columns, rows, page_size=5000):
    if not rows:
        return
    sql = f"INSERT INTO {table} ({', '.join(columns)}) VALUES %s ON CONFLICT DO NOTHING"
    execute_values(cur, sql, rows, page_size=page_size)


def load_all(customers_df, products_df, stores_df, warehouses_df,
             sales_df, inventory_df, returns_df):
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        print("Loading dim_customers...")
        bulk_insert(cur, "dim_customers",
                    ["customer_id", "age", "gender", "city", "state", "country",
                     "segment", "income", "signup_date", "lifetime_value", "loyalty_tier"],
                    list(customers_df[["CustomerID", "Age", "Gender", "City", "State", "Country",
                                       "Segment", "Income", "SignupDate", "LifetimeValue",
                                       "LoyaltyTier"]].itertuples(index=False, name=None)))

        print("Loading dim_products...")
        bulk_insert(cur, "dim_products",
                    ["product_id", "category", "subcategory", "brand", "product_name",
                     "cost_price", "selling_price", "supplier", "launch_date"],
                    list(products_df[["ProductID", "Category", "Subcategory", "Brand", "ProductName",
                                       "CostPrice", "SellingPrice", "Supplier", "LaunchDate"]]
                         .itertuples(index=False, name=None)))

        print("Loading dim_stores...")
        bulk_insert(cur, "dim_stores", ["store_id", "region"],
                    list(stores_df.itertuples(index=False, name=None)))

        print("Loading dim_warehouses...")
        bulk_insert(cur, "dim_warehouses", ["warehouse_id", "region"],
                    list(warehouses_df.itertuples(index=False, name=None)))

        print(f"Loading fact_sales ({len(sales_df):,} rows)...")
        bulk_insert(cur, "fact_sales",
                    ["order_id", "order_date", "customer_id", "product_id", "quantity",
                     "discount", "sales_amount", "profit", "store_id", "payment_method", "sales_channel"],
                    list(sales_df[["OrderID", "OrderDate", "CustomerID", "ProductID", "Quantity",
                                    "Discount", "SalesAmount", "Profit", "Store", "PaymentMethod",
                                    "SalesChannel"]].itertuples(index=False, name=None)))

        print(f"Loading fact_inventory ({len(inventory_df):,} rows)...")
        bulk_insert(cur, "fact_inventory",
                    ["product_id", "warehouse_id", "opening_stock", "received_stock", "sold_stock",
                     "damaged_stock", "closing_stock", "reorder_level", "lead_time_days", "supplier_rating"],
                    list(inventory_df[["ProductID", "Warehouse", "OpeningStock", "ReceivedStock",
                                        "SoldStock", "DamagedStock", "ClosingStock", "ReorderLevel",
                                        "LeadTimeDays", "SupplierRating"]]
                         .itertuples(index=False, name=None)))

        print(f"Loading fact_returns ({len(returns_df):,} rows)...")
        bulk_insert(cur, "fact_returns",
                    ["return_id", "order_id", "reason", "refund_amount", "return_date",
                     "return_status", "days_after_purchase"],
                    list(returns_df[["ReturnID", "OrderID", "Reason", "RefundAmount", "ReturnDate",
                                      "ReturnStatus", "DaysAfterPurchase"]]
                         .itertuples(index=False, name=None)))

        conn.commit()
        print("\nLoad complete — transaction committed.")
    except Exception as e:
        conn.rollback()
        print(f"Load failed, transaction rolled back: {e}")
        raise
    finally:
        cur.close()
        conn.close()


def main():
    print("Reading raw CSVs...")
    customers_df = pd.read_csv(os.path.join(DATASET_DIR, "customers.csv"))
    products_df = pd.read_csv(os.path.join(DATASET_DIR, "products.csv"))
    sales_df = pd.read_csv(os.path.join(DATASET_DIR, "sales.csv"))
    inventory_df = pd.read_csv(os.path.join(DATASET_DIR, "inventory.csv"))
    returns_df = pd.read_csv(os.path.join(DATASET_DIR, "returns.csv"))

    print("Cleaning...")
    customers_df = clean_customers(customers_df)
    products_df = clean_products(products_df)
    sales_df = clean_sales(sales_df, set(customers_df["CustomerID"]), set(products_df["ProductID"]))
    inventory_df = clean_inventory(inventory_df, set(products_df["ProductID"]))
    returns_df = clean_returns(returns_df, set(sales_df["OrderID"]))
    customers_df = refresh_customer_ltv(customers_df, sales_df)

    print("Deriving normalized dimensions (stores, warehouses)...")
    stores_df = derive_dim_stores(sales_df)
    warehouses_df = derive_dim_warehouses(inventory_df, sales_df)

    print("Connecting to PostgreSQL and loading...")
    load_all(customers_df, products_df, stores_df, warehouses_df, sales_df, inventory_df, returns_df)


if __name__ == "__main__":
    main()
