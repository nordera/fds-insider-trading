library(dplyr)
library(fixest)

cat("Loading panel...\n")
panel <- readRDS("~/nordera/panel_classified.rds")
cat("Rows loaded:", nrow(panel), "\n")

# --- Sanity check: yearmon must sort correctly as a string ---
# If "2010-1" exists instead of "2010-01", lead() will be computed on wrong order
sample_ym <- head(sort(unique(panel$yearmon)), 5)
cat("First 5 yearmon values:", paste(sample_ym, collapse=", "), "\n")
stopifnot(all(grepl("^\\d{4}-\\d{2}$", panel$yearmon)))

# --- Winsorize helper ---
winsorize <- function(x, p = 0.01) {
  q <- quantile(x, c(p, 1 - p), na.rm = TRUE)
  x[x < q[1]] <- q[1]
  x[x > q[2]] <- q[2]
  x
}

# Winsorize net signals to reduce influence of extreme block trades
panel$net_opportunistic <- winsorize(panel$net_opportunistic)
panel$net_routine       <- winsorize(panel$net_routine)

# --- Construct lead return (dependent variable) ---
# Sort by permno then yearmon (string sort is correct for YYYY-MM format)
panel <- panel %>%
  arrange(permno, yearmon) %>%
  group_by(permno) %>%
  mutate(ret_lead = lead(ret, 1)) %>%
  ungroup() %>%
  filter(!is.na(ret_lead))

cat("Rows after lead filter:", nrow(panel), "\n")

# --- Directional signals: +1 net buy, -1 net sell, 0 no trading ---
panel <- panel %>%
  mutate(
    signal_opportunistic = case_when(
      net_opportunistic > 0  ~  1L,
      net_opportunistic < 0  ~ -1L,
      TRUE                   ~  0L
    ),
    signal_routine = case_when(
      net_routine > 0  ~  1L,
      net_routine < 0  ~ -1L,
      TRUE             ~  0L
    ),
    any_opportunistic = as.integer(n_opportunistic > 0)
  )

cat("% months with opportunistic signal:",
    round(mean(panel$signal_opportunistic != 0) * 100, 1), "%\n")
cat("Signal distribution:\n")
print(table(panel$signal_opportunistic))

# --- Model 1: Baseline decomposition ---
cat("\nRunning Model 1 (baseline)...\n")
m1 <- feols(
  ret_lead ~ signal_opportunistic + signal_routine +
    momentum + volatility + booktomarket + grossprofit |
    permno + yearmon,
  cluster = ~permno,
  data    = panel
)

# --- Model 2: Binary opportunistic dummy ---
cat("Running Model 2 (binary dummy)...\n")
m2 <- feols(
  ret_lead ~ any_opportunistic +
    momentum + volatility + booktomarket + grossprofit |
    permno + yearmon,
  cluster = ~permno,
  data    = panel
)

# --- Model 3: Interaction with volatility ---
cat("Running Model 3 (interaction with volatility)...\n")
m3 <- feols(
  ret_lead ~ signal_opportunistic + signal_routine +
    signal_opportunistic:volatility +
    momentum + volatility + booktomarket + grossprofit |
    permno + yearmon,
  cluster = ~permno,
  data    = panel
)

# --- Results ---
cat("\n=== REGRESSION RESULTS ===\n")
etable(m1, m2, m3, digits = 4)

saveRDS(list(m1 = m1, m2 = m2, m3 = m3), "~/nordera/regression_results_scaled.rds")
cat("Saved regression_results_scaled.rds\n")
