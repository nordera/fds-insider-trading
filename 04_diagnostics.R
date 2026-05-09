library(dplyr)
library(fixest)

cat("Loading panel...\n")
panel <- readRDS("~/nordera/panel_classified.rds")

winsorize <- function(x, p = 0.01) {
  q <- quantile(x, c(p, 1 - p), na.rm = TRUE)
  x[x < q[1]] <- q[1]
  x[x > q[2]] <- q[2]
  x
}

panel$net_opportunistic <- winsorize(panel$net_opportunistic)
panel$net_routine       <- winsorize(panel$net_routine)

panel <- panel %>%
  arrange(permno, yearmon) %>%
  group_by(permno) %>%
  mutate(ret_lead = lead(ret, 1)) %>%
  ungroup() %>%
  filter(!is.na(ret_lead)) %>%
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
    )
  )

vars_needed <- c("ret_lead", "signal_opportunistic", "signal_routine",
                 "momentum", "volatility", "booktomarket", "grossprofit")
panel_est <- panel %>%
  filter(complete.cases(across(all_of(vars_needed))))

cat("Estimation sample rows:", nrow(panel_est), "\n")

cat("Refitting Model 1...\n")
m1 <- feols(
  ret_lead ~ signal_opportunistic + signal_routine +
             momentum + volatility + booktomarket + grossprofit |
             permno + yearmon,
  cluster = ~permno,
  data    = panel_est
)

resid_vec <- residuals(m1)
cat("Residuals length:", length(resid_vec), "\n")

# feols removes singletons silently — find which rows survived
# by adding a unique row index and checking which ones have fitted values
panel_est$row_id <- seq_len(nrow(panel_est))
fitted_vec <- fitted(m1)
cat("Fitted values length:", length(fitted_vec), "\n")

# The surviving rows are identified by matching fitted values back
# Use the fact that feols preserves order — just take first N rows minus removed
# Simplest robust solution: refit with keep_singletons and drop manually
m1b <- feols(
  ret_lead ~ signal_opportunistic + signal_routine +
             momentum + volatility + booktomarket + grossprofit |
             permno + yearmon,
  cluster = ~permno,
  data    = panel_est,
  notes   = FALSE
)

# Get the sample used — fixest stores it in $obs_selection in newer versions
# Fallback: use predict() which returns NA for dropped obs
panel_est$fitted_m1  <- predict(m1b, newdata = panel_est)
panel_est$resid_m1   <- panel_est$ret_lead - panel_est$fitted_m1

# Drop rows where we couldn't compute residuals
panel_est <- panel_est %>% filter(!is.na(resid_m1))
cat("Rows with valid residuals:", nrow(panel_est), "\n")

cat("Running Ljung-Box tests...\n")
lb_results <- panel_est %>%
  group_by(permno) %>%
  filter(n() >= 15) %>%
  summarise(
    n_obs   = n(),
    lb_pval = tryCatch(
      Box.test(resid_m1, lag = 12, type = "Ljung-Box")$p.value,
      error = function(e) NA_real_
    ),
    .groups = "drop"
  )

cat("\n=== LJUNG-BOX TEST RESULTS (lag=12) ===\n")
cat("Firms tested:                  ", nrow(lb_results), "\n")
cat("Firms rejecting H0 at 5%:      ",
    sum(lb_results$lb_pval < 0.05, na.rm = TRUE), "\n")
cat("% rejecting (autocorrelation): ",
    round(mean(lb_results$lb_pval < 0.05, na.rm = TRUE) * 100, 1), "%\n")
cat("% rejecting at 1%:             ",
    round(mean(lb_results$lb_pval < 0.01, na.rm = TRUE) * 100, 1), "%\n")

cat("\nDistribution of p-values:\n")
print(quantile(lb_results$lb_pval, c(0.1, 0.25, 0.5, 0.75, 0.9), na.rm = TRUE))

pct_reject <- mean(lb_results$lb_pval < 0.05, na.rm = TRUE) * 100
cat("\n=== INTERPRETATION ===\n")
if (pct_reject < 10) {
  cat("GOOD: Less than 10% of firms show serial correlation.\n")
  cat("Clustered SE are sufficient.\n")
} else if (pct_reject < 25) {
  cat("MODERATE: Some autocorrelation present.\n")
  cat("Consider Newey-West SE as robustness check.\n")
} else {
  cat("WARNING: Strong autocorrelation in residuals.\n")
  cat("Recommend Newey-West SE.\n")
}

saveRDS(lb_results, "~/nordera/diagnostics_lb.rds")
cat("\nSaved diagnostics_lb.rds\n")