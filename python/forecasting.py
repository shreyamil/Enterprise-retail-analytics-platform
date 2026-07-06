"""
forecasting.py
===============
Enterprise Retail Analytics Platform — Sales Forecasting Module

Builds and compares 5 forecasting approaches on monthly revenue:
    1. Simple Moving Average (naive baseline)
    2. Exponential Smoothing (Holt-Winters, additive trend + seasonality)
    3. ARIMA
    4. SARIMA (seasonal ARIMA)
    5. Prophet (Facebook/Meta's additive model, handles holidays/seasonality well)

Evaluation:
    - Time-based train/test split (last 12 months held out — never shuffle
      time series data, that would leak future information into training)
    - RMSE, MAE, MAPE computed per model on the held-out test set
    - Best model selected by lowest MAPE (most interpretable for stakeholders:
      "average forecast error of X%")
    - Best model is then refit on ALL available data and used to forecast the
      next 12 months forward, with confidence intervals where the model
      supports them.

Run:
    python forecasting.py
"""

import os
import warnings
import numpy as np
import pandas as pd
from statsmodels.tsa.holtwinters import ExponentialSmoothing
from statsmodels.tsa.arima.model import ARIMA
from statsmodels.tsa.statespace.sarimax import SARIMAX
from prophet import Prophet

warnings.filterwarnings("ignore")

DATASET_DIR = os.path.join(os.path.dirname(__file__), "..", "datasets")
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "docs")
os.makedirs(OUTPUT_DIR, exist_ok=True)

TEST_MONTHS = 12  # hold out the last 12 months for evaluation


def load_monthly_revenue():
    sales = pd.read_csv(os.path.join(DATASET_DIR, "sales.csv"), parse_dates=["OrderDate"])
    monthly = sales.set_index("OrderDate").resample("MS")["SalesAmount"].sum()
    return monthly


def rmse(y_true, y_pred):
    return float(np.sqrt(np.mean((np.array(y_true) - np.array(y_pred)) ** 2)))


def mae(y_true, y_pred):
    return float(np.mean(np.abs(np.array(y_true) - np.array(y_pred))))


def mape(y_true, y_pred):
    y_true, y_pred = np.array(y_true), np.array(y_pred)
    return float(np.mean(np.abs((y_true - y_pred) / y_true)) * 100)


# ----------------------------------------------------------------------------
# Model 1: Simple Moving Average (naive baseline — every other model must beat this)
# ----------------------------------------------------------------------------
def forecast_moving_average(train, horizon, window=3):
    history = list(train.values)
    preds = []
    for _ in range(horizon):
        next_val = np.mean(history[-window:])
        preds.append(next_val)
        history.append(next_val)
    return np.array(preds)


# ----------------------------------------------------------------------------
# Model 2: Exponential Smoothing (Holt-Winters)
# ----------------------------------------------------------------------------
def forecast_exp_smoothing(train, horizon):
    model = ExponentialSmoothing(
        train, trend="add", seasonal="add", seasonal_periods=12, initialization_method="estimated"
    ).fit()
    return model.forecast(horizon), model


# ----------------------------------------------------------------------------
# Model 3: ARIMA
# ----------------------------------------------------------------------------
def forecast_arima(train, horizon, order=(2, 1, 2)):
    model = ARIMA(train, order=order).fit()
    forecast_result = model.get_forecast(horizon)
    return forecast_result.predicted_mean, forecast_result.conf_int(alpha=0.05), model


# ----------------------------------------------------------------------------
# Model 4: SARIMA (seasonal ARIMA)
# ----------------------------------------------------------------------------
def forecast_sarima(train, horizon, order=(1, 1, 1), seasonal_order=(1, 1, 1, 12)):
    model = SARIMAX(train, order=order, seasonal_order=seasonal_order,
                     enforce_stationarity=False, enforce_invertibility=False).fit(disp=False)
    forecast_result = model.get_forecast(horizon)
    return forecast_result.predicted_mean, forecast_result.conf_int(alpha=0.05), model


# ----------------------------------------------------------------------------
# Model 5: Prophet
# ----------------------------------------------------------------------------
def forecast_prophet(train, horizon):
    df = pd.DataFrame({"ds": train.index, "y": train.values})
    model = Prophet(yearly_seasonality=True, seasonality_mode="multiplicative")
    model.fit(df)
    future = model.make_future_dataframe(periods=horizon, freq="MS")
    forecast = model.predict(future)
    tail = forecast.tail(horizon)
    return tail["yhat"].values, tail[["yhat_lower", "yhat_upper"]].values, model


def evaluate_all_models(monthly):
    train, test = monthly.iloc[:-TEST_MONTHS], monthly.iloc[-TEST_MONTHS:]
    horizon = len(test)
    results = {}

    print(f"Train period: {train.index.min().date()} to {train.index.max().date()} ({len(train)} months)")
    print(f"Test period:  {test.index.min().date()} to {test.index.max().date()} ({len(test)} months)\n")

    # 1. Moving Average
    ma_preds = forecast_moving_average(train, horizon)
    results["Moving Average"] = ma_preds

    # 2. Exponential Smoothing
    es_preds, _ = forecast_exp_smoothing(train, horizon)
    results["Exponential Smoothing"] = es_preds.values

    # 3. ARIMA
    arima_preds, _, _ = forecast_arima(train, horizon)
    results["ARIMA"] = arima_preds.values

    # 4. SARIMA
    sarima_preds, _, _ = forecast_sarima(train, horizon)
    results["SARIMA"] = sarima_preds.values

    # 5. Prophet
    prophet_preds, _, _ = forecast_prophet(train, horizon)
    results["Prophet"] = prophet_preds

    print(f"{'Model':<24}{'RMSE':>12}{'MAE':>12}{'MAPE %':>10}")
    print("-" * 58)
    scorecard = []
    for name, preds in results.items():
        r, m, p = rmse(test.values, preds), mae(test.values, preds), mape(test.values, preds)
        scorecard.append((name, r, m, p))
        print(f"{name:<24}{r:>12,.1f}{m:>12,.1f}{p:>9.2f}%")

    scorecard_df = pd.DataFrame(scorecard, columns=["Model", "RMSE", "MAE", "MAPE"])
    best_model_name = scorecard_df.sort_values("MAPE").iloc[0]["Model"]
    print(f"\nBest model (lowest MAPE): {best_model_name}")
    return scorecard_df, best_model_name, test, results


def forecast_future_12_months(monthly, best_model_name):
    print(f"\nRefitting '{best_model_name}' on full history to forecast next 12 months...")
    horizon = 12

    if best_model_name == "Moving Average":
        preds = forecast_moving_average(monthly, horizon)
        lower = upper = preds  # naive baseline has no native CI
    elif best_model_name == "Exponential Smoothing":
        preds, model = forecast_exp_smoothing(monthly, horizon)
        preds = preds.values
        resid_std = np.std(model.resid)
        lower, upper = preds - 1.96 * resid_std, preds + 1.96 * resid_std
    elif best_model_name == "ARIMA":
        preds, ci, _ = forecast_arima(monthly, horizon)
        preds = preds.values
        lower, upper = ci.iloc[:, 0].values, ci.iloc[:, 1].values
    elif best_model_name == "SARIMA":
        preds, ci, _ = forecast_sarima(monthly, horizon)
        preds = preds.values
        lower, upper = ci.iloc[:, 0].values, ci.iloc[:, 1].values
    else:  # Prophet
        preds, ci, _ = forecast_prophet(monthly, horizon)
        lower, upper = ci[:, 0], ci[:, 1]

    future_dates = pd.date_range(monthly.index.max() + pd.DateOffset(months=1), periods=horizon, freq="MS")
    forecast_df = pd.DataFrame({
        "Month": future_dates,
        "Forecasted_Revenue": np.round(preds, 2),
        "Lower_95CI": np.round(lower, 2),
        "Upper_95CI": np.round(upper, 2),
    })
    return forecast_df


def main():
    monthly = load_monthly_revenue()
    print("=" * 70)
    print("FORECAST MODEL COMPARISON (12-month holdout)")
    print("=" * 70)
    scorecard_df, best_model_name, test, results = evaluate_all_models(monthly)

    forecast_df = forecast_future_12_months(monthly, best_model_name)
    print("\n" + "=" * 70)
    print(f"NEXT 12 MONTHS FORECAST (using {best_model_name})")
    print("=" * 70)
    print(forecast_df.to_string(index=False))

    scorecard_path = os.path.join(OUTPUT_DIR, "forecast_model_scorecard.csv")
    forecast_path = os.path.join(OUTPUT_DIR, "revenue_forecast_next_12_months.csv")
    scorecard_df.to_csv(scorecard_path, index=False)
    forecast_df.to_csv(forecast_path, index=False)
    print(f"\nSaved model comparison -> {scorecard_path}")
    print(f"Saved 12-month forecast -> {forecast_path}")


if __name__ == "__main__":
    main()
