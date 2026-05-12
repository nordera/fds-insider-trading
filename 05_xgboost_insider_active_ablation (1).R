library(dplyr)
library(xgboost)
library(lubridate)
library(readr)

cat("=================================================\n")
cat("  XGBoost Insider-Active Subsample Ablation\n")
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

safe_zero <- function(x) ifelse(is.na(x), 0, x)

panel <- panel %>%
  arrange(permno, yearmon) %>%
  group_by(permno) %>%
  mutate(ret_lead = lead(ret, 1)) %>%
  ungroup() %>%
  filter(!is.na(ret_lead)) %>%
  mutate(
    # Replace missing insider aggregates with zero before signal construction.
    across(c(n_opportunistic, n_routine, vol_opportunistic, vol_routine,
             net_opportunistic, net_routine, n_purchases, n_sales, net_shares),
           ~ safe_zero(.x)),
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
    # Insider-active universe: firm-months with any classified insider activity.
    # If classified counts are missing/zero, raw purchase/sale counts provide a fallback.
    insider_active = (n_opportunistic + n_routine > 0) | (n_purchases + n_sales > 0),
    target  = as.integer(ret_lead > 0),
    date_ym = as.Date(paste0(yearmon, "-01"))
  ) %>%
  filter(insider_active)

cat("Rows after lead filter and insider-active filter:", nrow(panel), "\n")
cat("Unique firm-month years:", paste(sort(unique(year(panel$date_ym))), collapse = ", "), "\n")

# -------------------------------------------------------
# 2. FEATURE SETS
# -------------------------------------------------------
features_full <- c(
  "signal_opportunistic", "signal_routine",
  "n_opportunistic", "n_routine",
  "vol_opportunistic", "vol_routine",
  "net_opportunistic", "net_routine",
  "n_purchases", "n_sales", "net_shares",
  "momentum", "volatility",
  "booktomarket", "grossprofit", "accruals", "xfin",
  "prc", "shrout"
)

features_controls <- c(
  "momentum", "volatility",
  "booktomarket", "grossprofit", "accruals", "xfin",
  "prc", "shrout"
)

cat("\nFull features:", length(features_full), "\n")
cat("Controls-only features:", length(features_controls), "\n")

# -------------------------------------------------------
# 3. MODEL RUNNER
# -------------------------------------------------------
run_xgb_strategy <- function(panel, features, model_label, nthread = 4) {
  cat("\n=================================================\n")
  cat("Running model:", model_label, "\n")
  cat("=================================================\n")

  all_years  <- sort(unique(year(panel$date_ym)))
  first_test <- min(all_years) + 5
  test_years <- all_years[all_years >= first_test & all_years <= 2024]

  cat("First test year:", first_test, "\n")
  cat("Test years:", paste(test_years, collapse = ", "), "\n")

  all_preds  <- list()
  last_model <- NULL

  for (test_yr in test_years) {
    cat("\n--- Test year:", test_yr, "| Train:", min(all_years), "-", test_yr - 1, "---\n")

    train_data <- panel %>% filter(year(date_ym) <  test_yr)
    test_data  <- panel %>% filter(year(date_ym) == test_yr)

    cat("  Train:", nrow(train_data), "| Test:", nrow(test_data), "\n")

    if (nrow(train_data) < 1000 || nrow(test_data) < 100) {
      cat("  Skipping — insufficient train/test rows.\n")
      next
    }

    X_train <- as.matrix(train_data[, features])
    y_train <- train_data$target
    X_test  <- as.matrix(test_data[, features])

    valid_train <- !is.na(y_train)
    X_train <- X_train[valid_train, , drop = FALSE]
    y_train <- y_train[valid_train]

    n_train <- nrow(X_train)
    set.seed(42)
    val_idx <- sample(n_train, floor(n_train * 0.1))

    dtrain <- xgb.DMatrix(X_train[-val_idx, , drop = FALSE],
                          label = y_train[-val_idx], missing = NA)
    dval   <- xgb.DMatrix(X_train[val_idx, , drop = FALSE],
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
      nthread          = nthread,
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
             signal_opportunistic, signal_routine,
             n_opportunistic, n_routine, n_purchases, n_sales) %>%
      mutate(xgb_prob = pred_prob,
             model = model_label)
  }

  predictions <- bind_rows(all_preds)
  cat("\nTotal predictions:", nrow(predictions), "\n")
  if (nrow(predictions) > 0) {
    cat("Period:", min(predictions$yearmon), "to", max(predictions$yearmon), "\n")
  }

  importance <- xgb.importance(feature_names = features, model = last_model)
  cat("\nFeature importance (last model):\n")
  print(head(importance, 10))

  # Decile long-short portfolio within insider-active universe.
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
    mutate(ret_ls_xgb = ret_long - ret_short,
           model = model_label)

  # Top/bottom 20% portfolio within insider-active universe.
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
    mutate(ret_ls_xgb20 = ret_long - ret_short,
           model = model_label)

  summarise_port <- function(ret_vec, name) {
    ret_vec <- ret_vec[!is.na(ret_vec)]
    ann_ret <- mean(ret_vec) * 12
    ann_vol <- sd(ret_vec)   * sqrt(12)
    sharpe  <- ann_ret / ann_vol
    hit     <- mean(ret_vec > 0) * 100
    wealth  <- prod(1 + ret_vec)
    cat(sprintf("  %-35s | Ret: %+.2f%% | Vol: %.2f%% | Sharpe: %+.2f | Hit: %.1f%% | $1 -> $%.2f\n",
                name, ann_ret * 100, ann_vol * 100, sharpe, hit, wealth))
    data.frame(strategy = name, ann_return = ann_ret, ann_vol = ann_vol,
               sharpe = sharpe, hit_rate = hit, final_wealth = wealth)
  }

  cat("\nPerformance summary:\n")
  perf <- bind_rows(
    summarise_port(port_xgb$ret_ls_xgb,     paste(model_label, "Decile 10-1")),
    summarise_port(port_xgb20$ret_ls_xgb20, paste(model_label, "Top/Bot 20%"))
  )

  list(
    predictions = predictions,
    port_xgb    = port_xgb,
    port_xgb20  = port_xgb20,
    importance  = importance,
    perf        = perf,
    features    = features,
    model_label = model_label
  )
}

# -------------------------------------------------------
# 4. RUN FULL AND CONTROLS-ONLY MODELS
# -------------------------------------------------------
res_full <- run_xgb_strategy(panel, features_full, "Insider-active full", nthread = 4)
res_ctrl <- run_xgb_strategy(panel, features_controls, "Insider-active controls-only", nthread = 4)

# -------------------------------------------------------
# 5. COMPARISON TABLE
# -------------------------------------------------------
comparison <- bind_rows(res_full$perf, res_ctrl$perf) %>%
  mutate(
    ann_return_pct = 100 * ann_return,
    ann_vol_pct    = 100 * ann_vol
  )

cat("\n=================================================\n")
cat("Final comparison: insider-active subsample\n")
cat("=================================================\n")
print(comparison)

# -------------------------------------------------------
# 6. SAVE RDS AND CSV OUTPUTS
# -------------------------------------------------------
saveRDS(list(
  full       = res_full,
  controls   = res_ctrl,
  comparison = comparison,
  sample     = "insider_active"
), "~/nordera/xgboost_results_insider_active_ablation.rds")

write_csv(comparison, "~/nordera/xgboost_insider_active_comparison.csv")
write_csv(res_full$port_xgb, "~/nordera/results_insider_active_full_decile.csv")
write_csv(res_full$port_xgb20, "~/nordera/results_insider_active_full_20pct.csv")
write_csv(res_ctrl$port_xgb, "~/nordera/results_insider_active_controls_decile.csv")
write_csv(res_ctrl$port_xgb20, "~/nordera/results_insider_active_controls_20pct.csv")
write_csv(res_full$importance, "~/nordera/importance_insider_active_full.csv")
write_csv(res_ctrl$importance, "~/nordera/importance_insider_active_controls.csv")

cat("\nSaved:\n")
cat("  ~/nordera/xgboost_results_insider_active_ablation.rds\n")
cat("  ~/nordera/xgboost_insider_active_comparison.csv\n")
cat("  ~/nordera/results_insider_active_full_decile.csv\n")
cat("  ~/nordera/results_insider_active_full_20pct.csv\n")
cat("  ~/nordera/results_insider_active_controls_decile.csv\n")
cat("  ~/nordera/results_insider_active_controls_20pct.csv\n")
cat("=== DONE ===\n")
