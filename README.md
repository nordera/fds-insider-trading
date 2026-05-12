# Decoding Insider Trading Signals

**Routine vs. Opportunistic Trades, Machine Learning, and Return Predictability**

MIT Sloan School of Management — 15.458 Financial Data Science and Computing, May 2026

---

## Overview

This repository contains the full research pipeline for a study of insider trading signal predictability. We classify 1,716,763 SEC Form 4 transactions as routine or opportunistic, aggregate signals using **SEC filing dates** (not transaction dates) to ensure strict informational correctness, and evaluate predictability using panel regressions, gradient boosting (XGBoost), Fama-French five-factor alpha decomposition, and reinforcement learning (PPO).

**Main results:**
- Opportunistic insider buying predicts next-month returns of **+0.35%** (p < 0.001), concentrated entirely in high-volatility environments
- XGBoost long-short portfolio: **+34.99% annualized**, Sharpe 1.60, $1 → $12.86 (2015–2024)
- Fama-French 5-factor alpha: **+33.32% per year** (t = 3.91, p < 0.001)
- PPO reinforcement learning portfolio: **+74.18% annualized**, Sharpe 0.91, $1 → $4.65 (2020–2024)
- Feature importance: market variables (price 33%, volatility 25%) dominate; insider signals contribute <2%

---

## Repository Structure

| File | Description |
|------|-------------|
| `data_pipeline.R` | Extract insider trades, CRSP returns, Compustat fundamentals from WRDS |
| `data_collection.py` | Python data collection utilities |
| `fundamentals_pipeline.py` | Compustat fundamentals pipeline |
| `01_classification.R` | Routine vs. opportunistic classification (Cohen et al. 2012), year-by-year |
| `02_merge_panel.R` | Build firm-month panel — aggregates by **SEC filing date** |
| `03b_regressions_scaled.R` | Panel regressions with fixest (firm + time FE, clustered SE) |
| `04_diagnostics.R` | Ljung-Box white noise test on regression residuals |
| `05_xgboost_portfolio.R` | XGBoost expanding window + long-short portfolio construction |
| `06_plots.R` | Publication-quality figures (wealth index, feature importance) |
| `07_ff_alpha.R` | Fama-French 5-factor alpha decomposition (Newey-West SE, lag=6) |
| `08a_export_predictions.R` | Export XGBoost predictions to CSV for RL agent |
| `08_rl_portfolio.py` | PPO reinforcement learning portfolio (continuous actions, 10 deciles) |
| `submit_regressions.sh` | SLURM job script for XGBoost (MIT Engaging cluster) |
| `submit_rl.sh` | SLURM job script for RL (MIT Engaging cluster) |
| `FDS_Final_Project.tex` | Full paper (LaTeX) |

---

## Data Sources

All data accessed via **WRDS (Wharton Research Data Services)**:

| Source | Table | Content |
|--------|-------|---------|
| SEC Insiders | `wrdssec_insiders.nonderivatives` | Form 4 insider transactions |
| CRSP | `crsp.msf` | Monthly stock returns and prices |
| Compustat | `comp.fundq` | Quarterly accounting fundamentals |
| Compustat | `comp.company` | CIK → GVKEY mapping |
| CCM | `crsp.ccmxpf_linktable` | GVKEY → PERMNO mapping |

**Sample period:** January 2010 – December 2025

Raw data files are not included due to WRDS licensing restrictions.

---

## How to Run

Scripts assume a working directory at `~/project/`. Replace with your own path before running.

**R packages:** `dplyr`, `lubridate`, `fixest`, `xgboost`, `ggplot2`, `sandwich`, `lmtest`

**Python packages:** `stable-baselines3`, `gymnasium`, `pandas`, `numpy`

**Execution order:**
```bash
# Step 0: Extract data from WRDS
Rscript data_pipeline.R

# Step 1: Classify trades
Rscript 01_classification.R

# Step 2: Build panel (filing date aggregation)
Rscript 02_merge_panel.R

# Step 3: Panel regressions
Rscript 03b_regressions_scaled.R

# Step 4: Residual diagnostics
Rscript 04_diagnostics.R

# Step 5: XGBoost + portfolio (submit via SLURM for 16-core parallelism)
sbatch submit_regressions.sh

# Step 6: Generate figures
Rscript 06_plots.R

# Step 7: Fama-French alpha
# Download FF5 factors first:
curl -L "https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/ftp/F-F_Research_Data_5_Factors_2x3_CSV.zip" -o /tmp/ff5.zip
unzip -o /tmp/ff5.zip -d /tmp/
Rscript 07_ff_alpha.R

# Step 8: Export predictions and run RL (submit via SLURM)
Rscript 08a_export_predictions.R
sbatch submit_rl.sh
```

---

## Key Results

### Panel Regressions (600,699 firm-month observations, filing-date signals)

| | Model 1 Baseline | Model 2 Dummy | Model 3 Interaction |
|--|--|--|--|
| Signal_Opportunistic | 0.0035*** | — | 0.0009 |
| Signal_Routine | 0.0044*** | — | 0.0043*** |
| Any_Opportunistic | — | -0.0021*** | — |
| SigOpp x Volatility | — | — | 0.0203*** |

All models include firm and time fixed effects, clustered SE by firm.

### Portfolio Performance (filing-date signals)

| Strategy | Period | Ann. Return | Sharpe | $1 → |
|----------|--------|------------|--------|-------|
| Regression L/S | 2015–2024 | -2.55% | -0.38 | $0.78 |
| XGBoost Top/Bot 20% | 2015–2024 | +25.27% | +1.39 | $6.69 |
| XGBoost Decile 10-1 | 2015–2024 | +34.99% | +1.60 | $12.86 |
| RL PPO (continuous) | 2020–2024 | +74.18% | +0.91 | $4.65 |

### Fama-French 5-Factor Alpha

| Strategy | Alpha/year | t-stat | Significant |
|----------|-----------|--------|-------------|
| Regression L/S | -2.77% | -1.50 | No |
| XGBoost Top/Bot 20% | +24.41% | +3.68 | *** |
| XGBoost Decile 10-1 | +33.32% | +3.91 | *** |

Newey-West SE, lag=6. FF5 factors from Kenneth French Data Library.

### XGBoost Feature Importance (Top 5)

| Feature | Gain | Type |
|---------|------|------|
| Price (prc) | 33.1% | Market |
| Volatility | 25.0% | Market |
| Gross profitability | 8.3% | Fundamental |
| Book-to-market | 7.7% | Fundamental |
| Accruals | 7.5% | Fundamental |

Insider features contribute less than 2% of total gain.

---

## Methodological Notes

**Filing date aggregation:** Insider signals are aggregated using the SEC filing date (`fdate`) rather than the transaction date. Form 4 must be filed within 2 business days of the transaction, but the trade becomes public only upon filing. This ensures strict informational correctness with no look-ahead bias.

**Routine classification:** Year-by-year application — a trade in year t is routine only if the insider traded in the same calendar month in each of the two preceding years. Once a streak breaks, the label immediately reverts to opportunistic. This reduces routine share from ~55% (naive permanent implementation) to 27%.

**Lookahead bias prevention:** Both XGBoost and the RL agent use a strict expanding window — trained on 2010 through t-1, predicting year t only.

**Duplicate resolution:** 211,920 duplicate firm-month observations from many-to-many CIK-PERMNO links resolved by keeping the first valid observation per firm-month.

---

## References

- Cohen, L., Malloy, C., & Pomorski, L. (2012). Decoding inside information. *Journal of Finance*, 67(3), 1009–1043.
- Chen, T., & Guestrin, C. (2016). XGBoost: A scalable tree boosting system. *KDD*, 785–794.
- Gu, S., Kelly, B., & Xiu, D. (2020). Empirical asset pricing via machine learning. *Review of Financial Studies*, 33(5), 2223–2273.
- Fama, E. F., & French, K. R. (2015). A five-factor asset pricing model. *Journal of Financial Economics*, 116(1), 1–22.
- Schulman, J., et al. (2017). Proximal policy optimization algorithms. *arXiv:1707.06347*.
- Freyberger, J., Neuhierl, A., & Weber, M. (2020). Dissecting characteristics nonparametrically. *Review of Financial Studies*, 33(5), 2326–2377.
