library(dplyr)
library(lubridate)
library(sandwich)
library(lmtest)

cat("=================================================\n")
cat("  Fama-French 5-Factor Alpha Decomposition\n")
cat("=================================================\n")

# -------------------------------------------------------
# 1. READ FF5 FACTORS
# Download first with:
# curl -L "https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/ftp/F-F_Research_Data_5_Factors_2x3_CSV.zip" -o /tmp/ff5.zip
# unzip -o /tmp/ff5.zip -d /tmp/
# -------------------------------------------------------
csv_path  <- "/tmp/F-F_Research_Data_5_Factors_2x3.csv"
raw_lines <- readLines(csv_path)
header_line <- grep("Mkt-RF", raw_lines)[1]

ff5_raw <- read.csv(csv_path, skip = header_line - 1,
                    header = TRUE, stringsAsFactors = FALSE)
ff5_raw <- ff5_raw[nchar(trimws(as.character(ff5_raw[, 1]))) == 6, ]
names(ff5_raw)[1] <- "yyyymm"

ff5 <- ff5_raw %>%
  mutate(
    yyyymm  = as.integer(trimws(yyyymm)),
    yearmon = format(as.Date(paste0(substr(yyyymm, 1, 4), "-",
                                    substr(yyyymm, 5, 6), "-01")), "%Y-%m"),
    mkt_rf  = as.numeric(Mkt.RF) / 100,
    smb     = as.numeric(SMB)    / 100,
    hml     = as.numeric(HML)    / 100,
    rmw     = as.numeric(RMW)    / 100,
    cma     = as.numeric(CMA)    / 100,
    rf      = as.numeric(RF)     / 100
  ) %>%
  filter(yearmon >= "2015-01" & yearmon <= "2024-11") %>%
  select(yearmon, mkt_rf, smb, hml, rmw, cma, rf)

cat("FF5 months:", nrow(ff5), "| Period:", min(ff5$yearmon),
    "to", max(ff5$yearmon), "\n")

# -------------------------------------------------------
# 2. LOAD PORTFOLIO RETURNS
# -------------------------------------------------------
results    <- readRDS("~/nordera/xgboost_results.rds")
port_reg   <- results$port_reg
port_xgb   <- results$port_xgb
port_xgb20 <- results$port_xgb20

# -------------------------------------------------------
# 3. MERGE WITH FF5
# -------------------------------------------------------
merge_ff5 <- function(port_df, ret_col) {
  port_df %>%
    select(yearmon, ret = all_of(ret_col)) %>%
    left_join(ff5, by = "yearmon") %>%
    filter(!is.na(mkt_rf), !is.na(ret))
}

data_reg   <- merge_ff5(port_reg,   "ret_ls_reg")
data_xgb   <- merge_ff5(port_xgb,   "ret_ls_xgb")
data_xgb20 <- merge_ff5(port_xgb20, "ret_ls_xgb20")

# -------------------------------------------------------
# 4. FF5 REGRESSIONS WITH NEWEY-WEST SE (lag=6)
# -------------------------------------------------------
run_ff5 <- function(data, name) {
  cat("\n---", name, "---\n")
  ols    <- lm(ret ~ mkt_rf + smb + hml + rmw + cma, data = data)
  nw_vcv <- NeweyWest(ols, lag = 6, prewhite = FALSE)
  result <- coeftest(ols, vcov = nw_vcv)

  alpha     <- result["(Intercept)", "Estimate"]
  alpha_t   <- result["(Intercept)", "t value"]
  alpha_p   <- result["(Intercept)", "Pr(>|t|)"]
  alpha_ann <- alpha * 12
  r2        <- summary(ols)$r.squared

  stars <- ifelse(alpha_p < 0.001, "***",
           ifelse(alpha_p < 0.01,  "**",
           ifelse(alpha_p < 0.05,  "*",
           ifelse(alpha_p < 0.10,  ".", ""))))

  cat(sprintf("  Monthly alpha:    %+.4f%s\n", alpha, stars))
  cat(sprintf("  Annualized alpha: %+.2f%%\n", alpha_ann * 100))
  cat(sprintf("  t-statistic:      %.2f\n",    alpha_t))
  cat(sprintf("  p-value:          %.4f\n",    alpha_p))
  cat(sprintf("  R-squared:        %.4f\n",    r2))
  cat(sprintf("  Betas MKT/SMB/HML/RMW/CMA: %.3f / %.3f / %.3f / %.3f / %.3f\n",
    result["mkt_rf", "Estimate"], result["smb", "Estimate"],
    result["hml",    "Estimate"], result["rmw", "Estimate"],
    result["cma",    "Estimate"]))

  list(name = name, alpha_m = alpha, alpha_ann = alpha_ann,
       alpha_t = alpha_t, alpha_p = alpha_p, stars = stars,
       r2 = r2, n_obs = nrow(data),
       beta_mkt = result["mkt_rf", "Estimate"],
       beta_smb = result["smb",    "Estimate"],
       beta_hml = result["hml",    "Estimate"],
       beta_rmw = result["rmw",    "Estimate"],
       beta_cma = result["cma",    "Estimate"])
}

res_reg   <- run_ff5(data_reg,   "Regression L/S")
res_xgb20 <- run_ff5(data_xgb20, "XGBoost Top/Bot 20%")
res_xgb   <- run_ff5(data_xgb,   "XGBoost Decile 10-1")

# -------------------------------------------------------
# 5. SUMMARY TABLES
# -------------------------------------------------------
cat("\n\n=== FF5 ALPHA SUMMARY ===\n")
cat(rep("=", 70), "\n", sep = "")
cat(sprintf("%-25s %12s %12s %8s %6s\n",
            "Strategy", "Alpha/month", "Alpha/year", "t-stat", "N"))
cat(rep("-", 70), "\n", sep = "")
for (res in list(res_reg, res_xgb20, res_xgb)) {
  cat(sprintf("%-25s %+10.4f%s  %+10.2f%%  %7.2f  %5d\n",
    res$name, res$alpha_m, res$stars,
    res$alpha_ann * 100, res$alpha_t, res$n_obs))
}
cat(rep("=", 70), "\n", sep = "")
cat("Newey-West SE lag=6. *** p<0.001 ** p<0.01 * p<0.05 . p<0.10\n")

cat("\n=== FACTOR LOADINGS ===\n")
cat(sprintf("%-25s %7s %7s %7s %7s %7s\n",
            "Strategy", "MKT", "SMB", "HML", "RMW", "CMA"))
cat(rep("-", 60), "\n", sep = "")
for (res in list(res_reg, res_xgb20, res_xgb)) {
  cat(sprintf("%-25s %+6.3f %+6.3f %+6.3f %+6.3f %+6.3f\n",
    res$name, res$beta_mkt, res$beta_smb,
    res$beta_hml, res$beta_rmw, res$beta_cma))
}

# -------------------------------------------------------
# 6. SAVE
# -------------------------------------------------------
saveRDS(list(res_reg = res_reg, res_xgb = res_xgb, res_xgb20 = res_xgb20,
             ff5 = ff5, data_reg = data_reg,
             data_xgb = data_xgb, data_xgb20 = data_xgb20),
        "~/nordera/ff5_results.rds")
cat("\nSaved ff5_results.rds\n")
cat("=== DONE ===\n")
