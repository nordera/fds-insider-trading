# Decoding Insider Trading Signals

**Routine vs. Opportunistic Trades, Machine Learning, and Return Predictability**

MIT Sloan School of Management — 15.458 Financial Data Science and Computing, May 2026

---

## Overview

This repository contains the full research pipeline for a study of insider trading signal predictability using panel regressions, gradient boosting (XGBoost), Fama-French alpha decomposition, and reinforcement learning (PPO).

**Main results:**
- Opportunistic insider buying predicts next-month returns of **+0.43%** (p < 0.001), concentrated in high-volatility environments
- XGBoost long-short portfolio: **+34.24% annualized**, Sharpe 1.58, FF5 alpha +32.61%/year (t=3.89)
- PPO reinforcement learning portfolio: **+58.75% annualized** (2020-2024), Sharpe 0.78

---

## Repository Structure

| File | Description |
|------|-------------|
| `data_pipeline.R` | Extract insider trades, CRSP returns, Compustat fundamentals from WRDS |
| `data_collection.py` | Python data collection utilities |
| `fundamentals_pipeline.py` | Compustat fundamentals pipeline |
| `01_classification.R` | Routine vs. opportunistic classification (Cohen et al. 2012) |
| `02_merge_panel.R` | Build firm-month panel |
| `03b_regressions_scaled.R` | Panel regressions with fixest |
| `04_diagnostics.R` | Ljung-Box residual diagnostics |
| `05_xgboost_portfolio.R` | XGBoost expanding window + portfolio construction |
| `06_plots.R` | Generate publication-quality figures |
| `07_ff_alpha.R` | Fama-French 5-factor alpha decomposition |
| `08a_export_predictions.R` | Export XGBoost predictions for RL |
| `08_rl_portfolio.py` | PPO reinforcement learning portfolio |
| `submit_regressions.sh` | SLURM job script for XGBoost |
| `submit_rl.sh` | SLURM job script for RL |
| `FDS_Final_Project.tex` | Paper (LaTeX) |

---

## Data Sources

All data accessed via **WRDS (Wharton Research Data Services)**:
- SEC Form 4 insider transactions (`wrdssec_insiders.nonderivatives`)
- CRSP monthly stock returns (`crsp.msf`)
- Compustat quarterly fundamentals (`comp.fundq`)

Raw data files are not included due to WRDS licensing restrictions.

---

## How to Run

Scripts assume a working directory at `~/nordera/`. Replace with your own path before running.

**Execution order:**
```bash
Rscript data_pipeline.R
Rscript 01_classification.R
Rscript 02_merge_panel.R
Rscript 03b_regressions_scaled.R
Rscript 04_diagnostics.R
sbatch submit_regressions.sh   # XGBoost (SLURM)
Rscript 06_plots.R
Rscript 07_ff_alpha.R
sbatch submit_rl.sh            # RL (SLURM)
```

**R packages:** `dplyr`, `lubridate`, `fixest`, `xgboost`, `ggplot2`, `sandwich`, `lmtest`

**Python packages:** `stable-baselines3`, `gymnasium`, `pandas`, `numpy`

---

## Key Results

| Strategy | Ann. Return | Sharpe | FF5 Alpha |
|----------|------------|--------|-----------|
| Regression L/S | -1.16% | -0.18 | n.s. |
| XGBoost Top/Bot 20% | +25.18% | +1.38 | +24.33%*** |
| XGBoost Decile 10-1 | +34.24% | +1.58 | +32.61%*** |
| RL PPO (2020-2024) | +58.75% | +0.78 | — |

---

## References

- Cohen, Malloy & Pomorski (2012). Decoding inside information. *Journal of Finance*
- Gu, Kelly & Xiu (2020). Empirical asset pricing via machine learning. *Review of Financial Studies*
- Schulman et al. (2017). Proximal policy optimization algorithms. *arXiv:1707.06347*
