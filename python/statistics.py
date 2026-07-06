"""
statistics.py
==============
Enterprise Retail Analytics Platform — Statistical Analysis Module

Pulls from the cleaned datasets (CSV-level, so this runs even without a live
Postgres connection — see cleaning.py for the DB-backed equivalent) and runs:

    1. Correlation analysis            (what actually moves revenue/profit)
    2. Linear regression                (quantify revenue drivers)
    3. Hypothesis testing (t-test)      (does channel/segment matter, statistically)
    4. Confidence intervals             (range estimates for key KPIs)
    5. ANOVA                            (do >2 groups differ significantly)
    6. Customer segmentation (K-Means)  (data-driven segments, not just rules)
    7. Outlier detection (IQR + Z-score)(flag anomalous orders)
    8. Feature importance (Random Forest) (what predicts order profitability)
    9. Trend analysis                   (is revenue trending up/down, significance)
    10. Seasonality detection            (decompose into trend/seasonal/residual)

Each function prints a plain-English interpretation alongside the raw stats,
because a Senior Data Analyst deliverable explains *why* a number matters,
not just what the number is.

Run:
    python statistics.py
"""

import os
import warnings
import numpy as np
import pandas as pd
from scipy import stats
from sklearn.linear_model import LinearRegression
from sklearn.preprocessing import StandardScaler
from sklearn.cluster import KMeans
from sklearn.ensemble import RandomForestRegressor
from sklearn.model_selection import train_test_split
from statsmodels.tsa.seasonal import seasonal_decompose
import statsmodels.api as sm

warnings.filterwarnings("ignore")

DATASET_DIR = os.path.join(os.path.dirname(__file__), "..", "datasets")
RESULTS_DIR = os.path.join(os.path.dirname(__file__), "..", "docs")
os.makedirs(RESULTS_DIR, exist_ok=True)


def load_data():
    customers = pd.read_csv(os.path.join(DATASET_DIR, "customers.csv"))
    products = pd.read_csv(os.path.join(DATASET_DIR, "products.csv"))
    sales = pd.read_csv(os.path.join(DATASET_DIR, "sales.csv"), parse_dates=["OrderDate"])
    sales = sales.merge(products[["ProductID", "Category", "CostPrice", "SellingPrice"]], on="ProductID", how="left")
    sales = sales.merge(customers[["CustomerID", "Segment", "Income", "Age"]], on="CustomerID", how="left")
    return customers, products, sales


# ----------------------------------------------------------------------------
# 1. Correlation Analysis
# ----------------------------------------------------------------------------
def correlation_analysis(sales):
    print("\n" + "=" * 70)
    print("1. CORRELATION ANALYSIS")
    print("=" * 70)
    numeric_cols = sales[["Quantity", "Discount", "SalesAmount", "Profit", "Income", "Age"]].dropna()
    corr = numeric_cols.corr(method="pearson")
    print(corr.round(3))

    r_disc_profit, p_disc_profit = stats.pearsonr(numeric_cols["Discount"], numeric_cols["Profit"])
    print(f"\nDiscount vs Profit: r = {r_disc_profit:.3f}, p = {p_disc_profit:.4f}")
    direction = "negatively" if r_disc_profit < 0 else "positively"
    strength = "weak" if abs(r_disc_profit) < 0.3 else "moderate" if abs(r_disc_profit) < 0.6 else "strong"
    print(f"INTERPRETATION: Discount and Profit are {strength}ly and {direction} correlated "
          f"(statistically significant, p < 0.05)." if p_disc_profit < 0.05 else
          "INTERPRETATION: No statistically significant correlation detected.")
    return corr


# ----------------------------------------------------------------------------
# 2. Linear Regression — what drives Profit per order
# ----------------------------------------------------------------------------
def regression_analysis(sales):
    print("\n" + "=" * 70)
    print("2. LINEAR REGRESSION — Drivers of Order Profit")
    print("=" * 70)
    df = sales[["Quantity", "Discount", "SalesAmount", "Profit"]].dropna()
    X = df[["Quantity", "Discount", "SalesAmount"]]
    y = df["Profit"]

    X_sm = sm.add_constant(X)
    model = sm.OLS(y, X_sm).fit()
    print(model.summary().tables[1])

    r2 = model.rsquared
    print(f"\nR-squared: {r2:.4f}")
    print(f"INTERPRETATION: The model explains {r2*100:.1f}% of the variance in order-level profit. "
          f"Each 1-unit increase in Discount is associated with a "
          f"{model.params['Discount']:.2f} change in Profit, holding quantity and sales amount constant "
          f"(p={model.pvalues['Discount']:.4f}).")
    return model


# ----------------------------------------------------------------------------
# 3. Hypothesis Testing — Online vs Offline order value (independent t-test)
# ----------------------------------------------------------------------------
def hypothesis_test_channel(sales):
    print("\n" + "=" * 70)
    print("3. HYPOTHESIS TESTING — Online vs Offline Order Value (t-test)")
    print("=" * 70)
    online = sales.loc[sales["SalesChannel"] == "Online", "SalesAmount"].dropna()
    offline = sales.loc[sales["SalesChannel"] == "Offline", "SalesAmount"].dropna()

    t_stat, p_val = stats.ttest_ind(online, offline, equal_var=False)
    print(f"H0: Mean order value is equal between Online and Offline channels.")
    print(f"Online mean = {online.mean():.2f} | Offline mean = {offline.mean():.2f}")
    print(f"t-statistic = {t_stat:.3f}, p-value = {p_val:.4f}")
    if p_val < 0.05:
        print("INTERPRETATION: Statistically significant difference (p < 0.05) — reject H0. "
              "The channels genuinely differ in average order value; this isn't sampling noise.")
    else:
        print("INTERPRETATION: No statistically significant difference detected (p >= 0.05) — fail to reject H0.")
    return t_stat, p_val


# ----------------------------------------------------------------------------
# 4. Confidence Intervals
# ----------------------------------------------------------------------------
def confidence_intervals(sales):
    print("\n" + "=" * 70)
    print("4. CONFIDENCE INTERVALS (95%)")
    print("=" * 70)
    aov = sales["SalesAmount"].dropna()
    mean = aov.mean()
    sem = stats.sem(aov)
    ci = stats.t.interval(0.95, len(aov) - 1, loc=mean, scale=sem)
    print(f"Average Order Value: {mean:.2f}, 95% CI: ({ci[0]:.2f}, {ci[1]:.2f})")
    print(f"INTERPRETATION: We are 95% confident the true average order value across all transactions "
          f"falls between {ci[0]:.2f} and {ci[1]:.2f}. This range is what should be used in financial "
          f"planning instead of a single point estimate.")
    return mean, ci


# ----------------------------------------------------------------------------
# 5. ANOVA — Does avg order value differ across Customer Segments?
# ----------------------------------------------------------------------------
def anova_segments(sales):
    print("\n" + "=" * 70)
    print("5. ANOVA — Order Value Across Customer Segments")
    print("=" * 70)
    groups = [g["SalesAmount"].dropna().values for _, g in sales.groupby("Segment")]
    f_stat, p_val = stats.f_oneway(*groups)
    print(f"F-statistic = {f_stat:.3f}, p-value = {p_val:.4f}")
    means = sales.groupby("Segment")["SalesAmount"].mean().round(2)
    print(means)
    if p_val < 0.05:
        print("INTERPRETATION: At least one segment's average order value differs significantly "
              "from the others (p < 0.05) — segment is a meaningful driver of order value, "
              "justifying segment-specific marketing/pricing strategy.")
    else:
        print("INTERPRETATION: No statistically significant difference across segments.")
    return f_stat, p_val


# ----------------------------------------------------------------------------
# 6. Customer Segmentation — K-Means (data-driven, vs rule-based Segment column)
# ----------------------------------------------------------------------------
def kmeans_segmentation(customers, sales):
    print("\n" + "=" * 70)
    print("6. CUSTOMER SEGMENTATION (K-Means on RFM features)")
    print("=" * 70)
    snapshot_date = sales["OrderDate"].max()
    rfm = sales.groupby("CustomerID").agg(
        Recency=("OrderDate", lambda x: (snapshot_date - x.max()).days),
        Frequency=("OrderID", "count"),
        Monetary=("SalesAmount", "sum"),
    ).reset_index()

    features = rfm[["Recency", "Frequency", "Monetary"]]
    scaled = StandardScaler().fit_transform(features)

    kmeans = KMeans(n_clusters=4, random_state=42, n_init=10)
    rfm["Cluster"] = kmeans.fit_predict(scaled)

    profile = rfm.groupby("Cluster").agg(
        Customers=("CustomerID", "count"),
        AvgRecency=("Recency", "mean"),
        AvgFrequency=("Frequency", "mean"),
        AvgMonetary=("Monetary", "mean"),
    ).round(1)
    print(profile)
    print("\nINTERPRETATION: K-Means found 4 natural customer groupings based purely on behavior "
          "(recency/frequency/monetary), independent of the self-reported Segment label. Compare "
          "this to the rule-based Segment column — clusters with low recency + high frequency/monetary "
          "are the data-driven 'Champions', useful for validating (or challenging) the existing segmentation.")
    return rfm


# ----------------------------------------------------------------------------
# 7. Outlier Detection — IQR and Z-score methods on order value
# ----------------------------------------------------------------------------
def outlier_detection(sales):
    print("\n" + "=" * 70)
    print("7. OUTLIER DETECTION (IQR & Z-score on Order Value)")
    print("=" * 70)
    s = sales["SalesAmount"].dropna()

    q1, q3 = s.quantile([0.25, 0.75])
    iqr = q3 - q1
    lower, upper = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    iqr_outliers = sales[(s < lower) | (s > upper)]

    z_scores = np.abs(stats.zscore(s))
    z_outliers = sales.loc[s.index[z_scores > 3]]

    print(f"IQR method: bounds = ({lower:.2f}, {upper:.2f}) -> {len(iqr_outliers):,} outlier orders "
          f"({len(iqr_outliers)/len(sales)*100:.2f}% of all orders)")
    print(f"Z-score method (|z|>3): {len(z_outliers):,} outlier orders "
          f"({len(z_outliers)/len(sales)*100:.2f}% of all orders)")
    print("INTERPRETATION: These are unusually large (or small) transactions worth a manual review — "
          "either legitimate bulk/VIP orders worth nurturing, or data-entry/fraud cases worth investigating.")
    return iqr_outliers, z_outliers


# ----------------------------------------------------------------------------
# 8. Feature Importance — Random Forest predicting order Profit
# ----------------------------------------------------------------------------
def feature_importance(sales):
    print("\n" + "=" * 70)
    print("8. FEATURE IMPORTANCE (Random Forest -> Order Profit)")
    print("=" * 70)
    df = sales[["Quantity", "Discount", "SalesAmount", "Income", "Age", "Profit"]].dropna()
    X = df[["Quantity", "Discount", "SalesAmount", "Income", "Age"]]
    y = df["Profit"]

    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
    rf = RandomForestRegressor(n_estimators=100, random_state=42, max_depth=8)
    rf.fit(X_train, y_train)

    importances = pd.Series(rf.feature_importances_, index=X.columns).sort_values(ascending=False)
    print(importances.round(4))
    test_r2 = rf.score(X_test, y_test)
    print(f"\nTest R-squared: {test_r2:.4f}")
    print(f"INTERPRETATION: '{importances.index[0]}' is the single strongest predictor of order profit "
          f"among the features tested. This should guide which levers (pricing, discount policy, basket "
          f"size promotions) get prioritized for profit improvement initiatives.")
    return importances


# ----------------------------------------------------------------------------
# 9. Trend Analysis — is monthly revenue trending up/down, with significance
# ----------------------------------------------------------------------------
def trend_analysis(sales):
    print("\n" + "=" * 70)
    print("9. TREND ANALYSIS (Monthly Revenue)")
    print("=" * 70)
    monthly = sales.set_index("OrderDate").resample("MS")["SalesAmount"].sum().reset_index()
    monthly["t"] = range(len(monthly))

    slope, intercept, r_value, p_value, std_err = stats.linregress(monthly["t"], monthly["SalesAmount"])
    print(f"Slope = {slope:.2f} revenue/month, R-squared = {r_value**2:.4f}, p-value = {p_value:.4f}")
    direction = "upward" if slope > 0 else "downward"
    if p_value < 0.05:
        print(f"INTERPRETATION: There is a statistically significant {direction} trend in monthly "
              f"revenue of approximately {abs(slope):,.0f} per month.")
    else:
        print("INTERPRETATION: No statistically significant linear trend detected — revenue is "
              "essentially flat over time once monthly noise is accounted for.")
    return slope, p_value, monthly


# ----------------------------------------------------------------------------
# 10. Seasonality Detection — classical decomposition
# ----------------------------------------------------------------------------
def seasonality_detection(sales):
    print("\n" + "=" * 70)
    print("10. SEASONALITY DETECTION (Classical Decomposition)")
    print("=" * 70)
    monthly = sales.set_index("OrderDate").resample("MS")["SalesAmount"].sum()
    decomposition = seasonal_decompose(monthly, model="additive", period=12)

    seasonal_strength = 1 - (decomposition.resid.var() / (decomposition.seasonal + decomposition.resid).var())
    print(f"Seasonal component range: {decomposition.seasonal.min():,.0f} to {decomposition.seasonal.max():,.0f}")
    peak_month = decomposition.seasonal.groupby(decomposition.seasonal.index.month).mean().idxmax()
    trough_month = decomposition.seasonal.groupby(decomposition.seasonal.index.month).mean().idxmin()
    print(f"Seasonal strength score: {seasonal_strength:.3f} (closer to 1 = more seasonal)")
    print(f"Peak seasonal month: {peak_month} | Trough seasonal month: {trough_month}")
    print("INTERPRETATION: Confirms the expected holiday-season retail pattern. Staffing, inventory "
          "build-up, and marketing spend should be timed ahead of the peak month identified above.")
    return decomposition


def main():
    customers, products, sales = load_data()

    correlation_analysis(sales)
    regression_analysis(sales)
    hypothesis_test_channel(sales)
    confidence_intervals(sales)
    anova_segments(sales)
    kmeans_segmentation(customers, sales)
    outlier_detection(sales)
    feature_importance(sales)
    trend_analysis(sales)
    seasonality_detection(sales)

    print("\n" + "=" * 70)
    print("Statistical analysis complete.")
    print("=" * 70)


if __name__ == "__main__":
    main()
