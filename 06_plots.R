library(dplyr)
library(ggplot2)
library(lubridate)

cat("Loading XGBoost results...\n")
results <- readRDS("~/nordera/xgboost_results.rds")

wealth     <- results$wealth
importance <- results$importance

# -------------------------------------------------------
# 1. CUMULATIVE WEALTH CHART
# -------------------------------------------------------
cat("Building wealth chart...\n")

# Convert to long format for ggplot
wealth_long <- wealth %>%
  select(yearmon, wealth_reg, wealth_xgb, wealth_xgb20) %>%
  tidyr::pivot_longer(
    cols      = c(wealth_reg, wealth_xgb, wealth_xgb20),
    names_to  = "strategy",
    values_to = "wealth"
  ) %>%
  mutate(
    strategy = case_when(
      strategy == "wealth_reg"   ~ "Regression L/S",
      strategy == "wealth_xgb"   ~ "XGBoost Decile 10-1",
      strategy == "wealth_xgb20" ~ "XGBoost Top/Bot 20%"
    ),
    date = as.Date(paste0(yearmon, "-01"))
  )

# Colors and line types
colors    <- c("Regression L/S"      = "#888780",
               "XGBoost Top/Bot 20%" = "#1D9E75",
               "XGBoost Decile 10-1" = "#534AB7")
linetypes <- c("Regression L/S"      = "dashed",
               "XGBoost Top/Bot 20%" = "longdash",
               "XGBoost Decile 10-1" = "solid")
sizes     <- c("Regression L/S"      = 0.7,
               "XGBoost Top/Bot 20%" = 0.9,
               "XGBoost Decile 10-1" = 1.1)

p_wealth <- ggplot(wealth_long, aes(x = date, y = wealth,
                                     color = strategy,
                                     linetype = strategy,
                                     linewidth = strategy)) +
  geom_line() +
  geom_hline(yintercept = 1, linetype = "dotted",
             color = "gray60", linewidth = 0.4) +
  scale_color_manual(values = colors) +
  scale_linetype_manual(values = linetypes) +
  scale_linewidth_manual(values = sizes) +
  scale_y_continuous(
    labels = scales::dollar_format(prefix = "$"),
    breaks = c(0.5, 1, 2, 4, 6, 8, 10, 12)
  ) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  labs(
    title    = "Cumulative Wealth: Long-Short Portfolio Strategies (2015-2024)",
    subtitle = "$1 invested in January 2015, monthly rebalancing, equal-weighted within decile",
    x        = NULL,
    y        = "Cumulative wealth ($)",
    color    = NULL,
    linetype = NULL,
    linewidth = NULL,
    caption  = paste0(
      "Regression L/S: signal_opportunistic ∈ {-1,+1}. ",
      "XGBoost: expanding window, 19 features, binary:logistic objective.\n",
      "Final values — Regression: $0.89 | XGBoost 20%: $6.48 | XGBoost Decile: $11.60"
    )
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title       = element_text(size = 12, face = "bold", margin = margin(b = 4)),
    plot.subtitle    = element_text(size = 9,  color = "gray40", margin = margin(b = 12)),
    plot.caption     = element_text(size = 8,  color = "gray50", hjust = 0),
    legend.position  = "bottom",
    legend.key.width = unit(2, "cm"),
    panel.grid.minor = element_blank(),
    panel.grid.major = element_line(color = "gray90", linewidth = 0.3),
    axis.text.x      = element_text(angle = 45, hjust = 1)
  )

# Save wealth chart
ggsave("~/nordera/fig_wealth.pdf", p_wealth,
       width = 8, height = 5, device = "pdf")
ggsave("~/nordera/fig_wealth.png", p_wealth,
       width = 8, height = 5, dpi = 300)
cat("Saved fig_wealth.pdf and fig_wealth.png\n")

# -------------------------------------------------------
# 2. FEATURE IMPORTANCE CHART
# -------------------------------------------------------
cat("Building feature importance chart...\n")

# Clean feature names for the plot
fi <- importance[1:10, ] %>%
  mutate(
    Feature = case_when(
      Feature == "prc"               ~ "Price (prc)",
      Feature == "volatility"        ~ "Volatility",
      Feature == "grossprofit"       ~ "Gross profitability",
      Feature == "booktomarket"      ~ "Book-to-market",
      Feature == "accruals"          ~ "Accruals",
      Feature == "momentum"          ~ "Momentum",
      Feature == "shrout"            ~ "Shares outstanding",
      Feature == "xfin"              ~ "External financing",
      Feature == "vol_opportunistic" ~ "Vol. opportunistic",
      Feature == "n_purchases"       ~ "N purchases",
      TRUE                           ~ Feature
    ),
    Gain = Gain * 100,
    # Color by type: market vars vs fundamentals vs insider
    Type = case_when(
      Feature %in% c("Price (prc)", "Volatility", "Momentum",
                     "Shares outstanding") ~ "Market",
      Feature %in% c("Gross profitability", "Book-to-market",
                     "Accruals", "External financing") ~ "Fundamental",
      TRUE ~ "Insider signal"
    )
  ) %>%
  arrange(Gain) %>%
  mutate(Feature = factor(Feature, levels = Feature))

type_colors <- c("Market"       = "#534AB7",
                 "Fundamental"  = "#1D9E75",
                 "Insider signal" = "#D85A30")

p_fi <- ggplot(fi, aes(x = Gain, y = Feature, fill = Type)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = paste0(round(Gain, 1), "%")),
            hjust = -0.1, size = 3, color = "gray30") +
  scale_fill_manual(values = type_colors) +
  scale_x_continuous(
    expand = expansion(mult = c(0, 0.15)),
    labels = function(x) paste0(x, "%")
  ) +
  labs(
    title   = "XGBoost Feature Importance (Gain) — Last Model (2024)",
    subtitle = "Gain measures the relative contribution of each feature to model accuracy",
    x       = "Gain (%)",
    y       = NULL,
    fill    = "Variable type"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title      = element_text(size = 12, face = "bold", margin = margin(b = 4)),
    plot.subtitle   = element_text(size = 9, color = "gray40", margin = margin(b = 12)),
    legend.position = "bottom",
    panel.grid.major.y = element_blank(),
    panel.grid.minor   = element_blank(),
    panel.grid.major.x = element_line(color = "gray90", linewidth = 0.3)
  )

ggsave("~/nordera/fig_importance.pdf", p_fi,
       width = 7, height = 5, device = "pdf")
ggsave("~/nordera/fig_importance.png", p_fi,
       width = 7, height = 5, dpi = 300)
cat("Saved fig_importance.pdf and fig_importance.png\n")

# -------------------------------------------------------
# 3. PERFORMANCE SUMMARY TABLE (for LaTeX)
# -------------------------------------------------------
cat("\n=== PERFORMANCE SUMMARY ===\n")
cat(sprintf("%-25s %10s %10s %8s %8s\n",
            "Strategy", "Ann.Ret", "Volatility", "Sharpe", "$1 →"))
cat(rep("-", 65), "\n", sep="")

perf <- list(
  list("Regression L/S",       -0.0116, 0.0659, -0.18, 0.89),
  list("XGBoost Top/Bot 20%",   0.2518, 0.1829,  1.38, 6.48),
  list("XGBoost Decile 10-1",   0.3424, 0.2172,  1.58, 11.60)
)

for (p in perf) {
  cat(sprintf("%-25s %+9.2f%% %9.2f%% %8.2f %7.2f\n",
              p[[1]], p[[2]]*100, p[[3]]*100, p[[4]], p[[5]]))
}

cat("\nDone! Files saved in ~/nordera/\n")
cat("  fig_wealth.pdf\n")
cat("  fig_wealth.png\n")
cat("  fig_importance.pdf\n")
cat("  fig_importance.png\n")
