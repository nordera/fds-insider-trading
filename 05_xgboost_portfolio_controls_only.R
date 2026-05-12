library(dplyr)
library(xgboost)
library(lubridate)

cat("=================================================\n")
cat("  XGBoost Controls-Only — Expanding Window\n")
cat("=================================================\n")

# -------------------------------------------------------
# 1. LOAD AND PREPARE DATA
# -------------------------------------------------------
cat("\n[1] Loading panel...\n")
panel <- readRDS("~/nordera/panel_classified.rds")
cat("Raw rows:", nrow(panel), "\n")

winsorize <- function(x, p = 0.01) {
  q <- quantile(x, c(p, 1 - p), na.rm = TRUE)
  x[x < q[1]] <- q[1]
  x[x > q[2]] <- q[2]
  x
}

panel <- panel %>%
  arrange(permno, yearmon) %>%
  group_by(permno) %>%
  mutate(ret_lead = lead(ret, 1)) %>%
  ungroup() %>%
  filter(!is.na(ret_lead)) %>%
  mutate(
    net_opportunistic    = winsorize(net_opportunistic),
    net_routine          = winsorize(net_routine),
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
    target  = as.integer(ret_lead > 0),
    date_ym = as.Date(paste0(yearmon, "-01"))
  )

cat("Rows after lead filter:", nrow(panel), "\n")

# -------------------------------------------------------
# 2. FEATURES — CONTROLS ONLY / NO INSIDER INFO
# -------------------------------------------------------
# This ablation keeps the same target, expanding-window setup, and portfolio
# construction as the full XGBoost model, but removes all insider-trading
# variables from the model inputs.
features <- c(
  "momentum", "volatility",
  "booktomarket", "grossprofit", "accruals", "xfin",
  "prc", "shrout"
)

cat("\nFeatures:", length(features), "\n")
cat("Controls-only XGBoost: no insider variables included in model training.\n")
cat("Regression L/S benchmark below still uses signal_opportunistic for comparison.\n")

# -------------------------------------------------------
# 3. EXPANDING WINDOW
# -------------------------------------------------------
all_years  <- sort(unique(year(panel$date_ym)))
first_test <- min(all_years) + 5
test_years <- all_years[all_years >= first_test & all_years <= 2024]

cat("\n[2] Expanding window:\n")
cat("First test year:", first_test, "\n")
cat("Test years:", paste(test_years, collapse = ", "), "\n")

all_preds  <- list()
last_model <- NULL

for (test_yr in test_years) {

  cat("\n--- Test year:", test_yr,
      "| Train: 2010 -", test_yr - 1, "---\n")

  train_data <- panel %>% filter(year(date_ym) <  test_yr)
  test_data  <- panel %>% filter(year(date_ym) == test_yr)

  cat("  Train:", nrow(train_data), "| Test:", nrow(test_data), "\n")

  X_train <- as.matrix(train_data[, features])
  y_train <- train_data$target
  X_test  <- as.matrix(test_data[, features])

  valid_train <- !is.na(y_train)
  X_train <- X_train[valid_train, ]
  y_train <- y_train[valid_train]

  # 10% validation split for early stopping
  n_train <- nrow(X_train)
  set.seed(42)
  val_idx <- sample(n_train, floor(n_train * 0.1))

  dtrain <- xgb.DMatrix(X_train[-val_idx, ],
                        label = y_train[-val_idx], missing = NA)
  dval   <- xgb.DMatrix(X_train[val_idx, ],
                        label = y_train[val_idx],  missing = NA)
  dtest  <- xgb.DMatrix(X_test, missing = NA)

  params <- list(
    objective        = "binary:logistic",
    eval_metric      = "auc",
    eta              = 0.05,
    max_depth        = 5,
    subsample        = 0.8,
    colsample_bytree = 0.8,
    min_child_weight = 50,
    nthread = 16,
    seed             = 42
  )

  model <- xgb.train(
    params                = params,
    data                  = dtrain,
    nrounds               = 500,
    watchlist             = list(val = dval),
    early_stopping_rounds = 30,
    verbose               = 0
  )

  cat("  Best iteration:", model$best_iteration, "\n")
  last_model <- model

  pred_prob <- predict(model, dtest)

  all_preds[[as.character(test_yr)]] <- test_data %>%
    select(permno, yearmon, date_ym, ret_lead, target,
           signal_opportunistic, signal_routine) %>%
    mutate(xgb_prob = pred_prob)
}

predictions <- bind_rows(all_preds)
cat("\n[3] Total predictions:", nrow(predictions), "\n")
cat("Period:", min(predictions$yearmon), "to", max(predictions$yearmon), "\n")

# -------------------------------------------------------
# 4. FEATURE IMPORTANCE
# -------------------------------------------------------
cat("\n[4] Feature importance (last model):\n")
importance <- xgb.importance(feature_names = features, model = last_model)
print(importance[1:10, ])

# -------------------------------------------------------
# 5. PORTFOLIO CONSTRUCTION
# -------------------------------------------------------
cat("\n[5] Building portfolios...\n")

# Portfolio A: Regression signal (binary ±1)
port_reg <- predictions %>%
  filter(signal_opportunistic != 0) %>%
  group_by(yearmon) %>%
  summarise(
    ret_long  = mean(ret_lead[signal_opportunistic ==  1], na.rm = TRUE),
    ret_short = mean(ret_lead[signal_opportunistic == -1], na.rm = TRUE),
    n_long    = sum(signal_opportunistic ==  1),
    n_short   = sum(signal_opportunistic == -1),
    .groups   = "drop"
  ) %>%
  mutate(ret_ls_reg = ret_long - ret_short)

# Portfolio B: XGBoost top vs bottom decile
port_xgb <- predictions %>%
  group_by(yearmon) %>%
  mutate(decile = ntile(xgb_prob, 10)) %>%
  summarise(
    ret_long     = mean(ret_lead[decile == 10], na.rm = TRUE),
    ret_short    = mean(ret_lead[decile ==  1], na.rm = TRUE),
    n_long       = sum(decile == 10),
    n_short      = sum(decile ==  1),
    .groups      = "drop"
  ) %>%
  mutate(ret_ls_xgb = ret_long - ret_short)

# Portfolio C: XGBoost top/bottom 20%
port_xgb20 <- predictions %>%
  group_by(yearmon) %>%
  mutate(pct = percent_rank(xgb_prob)) %>%
  summarise(
    ret_long     = mean(ret_lead[pct >= 0.80], na.rm = TRUE),
    ret_short    = mean(ret_lead[pct <= 0.20], na.rm = TRUE),
    n_long       = sum(pct >= 0.80),
    n_short      = sum(pct <= 0.20),
    .groups      = "drop"
  ) %>%
  mutate(ret_ls_xgb20 = ret_long - ret_short)

# -------------------------------------------------------
# 6. PERFORMANCE SUMMARY
# -------------------------------------------------------
cat("\n[6] Portfolio Performance:\n")
cat(rep("-", 75), "\n", sep = "")

summarise_port <- function(ret_vec, name) {
  ret_vec <- ret_vec[!is.na(ret_vec)]
  ann_ret <- mean(ret_vec) * 12
  ann_vol <- sd(ret_vec)   * sqrt(12)
  sharpe  <- ann_ret / ann_vol
  hit     <- mean(ret_vec > 0) * 100
  cat(sprintf("  %-25s | Ret: %+.2f%% | Vol: %.2f%% | Sharpe: %+.2f | Hit: %.1f%%\n",
              name, ann_ret * 100, ann_vol * 100, sharpe, hit))
}

summarise_port(port_reg$ret_ls_reg,     "Regression L/S")
summarise_port(port_xgb$ret_ls_xgb,     "Controls-Only XGB Decile")
summarise_port(port_xgb20$ret_ls_xgb20, "Controls-Only XGB 20%")
cat(rep("-", 75), "\n", sep = "")

# -------------------------------------------------------
# 7. CUMULATIVE WEALTH INDEX
# -------------------------------------------------------
cat("\n[7] Building cumulative wealth index...\n")

wealth <- port_reg %>%
  select(yearmon, ret_ls_reg) %>%
  left_join(port_xgb   %>% select(yearmon, ret_ls_xgb),   by = "yearmon") %>%
  left_join(port_xgb20 %>% select(yearmon, ret_ls_xgb20), by = "yearmon") %>%
  arrange(yearmon) %>%
  mutate(
    wealth_reg   = cumprod(1 + ifelse(is.na(ret_ls_reg), 0, ret_ls_reg)),
    wealth_xgb   = cumprod(1 + ifelse(is.na(ret_ls_xgb), 0, ret_ls_xgb)),
    wealth_xgb20 = cumprod(1 + ifelse(is.na(ret_ls_xgb20), 0, ret_ls_xgb20))
  )

cat("Final wealth (starting from $1):\n")
cat(sprintf("  Regression L/S:      $%.2f\n", tail(wealth$wealth_reg,   1)))
cat(sprintf("  Controls-Only XGB Decile: $%.2f\n", tail(wealth$wealth_xgb,   1)))
cat(sprintf("  Controls-Only XGB 20%%: $%.2f\n", tail(wealth$wealth_xgb20, 1)))

# -------------------------------------------------------
# 8. SAVE
# -------------------------------------------------------
saveRDS(list(
  predictions = predictions,
  port_reg    = port_reg,
  port_xgb    = port_xgb,
  port_xgb20  = port_xgb20,
  wealth      = wealth,
  importance  = importance,
  features    = features,
  model_type  = "controls_only"
), "~/nordera/xgboost_results_controls_only.rds")

cat("\nSaved ~/nordera/xgboost_results_controls_only.rds\n")
cat("=== DONE ===\n")
