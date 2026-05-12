library(dplyr)
library(lubridate)
library(sandwich)
library(lmtest)

csv_path <- "/tmp/F-F_Research_Data_5_Factors_2x3.csv"
raw_lines <- readLines(csv_path)
header_line <- grep("Mkt-RF", raw_lines)[1]
ff5_raw <- read.csv(csv_path, skip = header_line - 1, header = TRUE, stringsAsFactors = FALSE)
ff5_raw <- ff5_raw[nchar(trimws(as.character(ff5_raw[,1]))) == 6, ]
names(ff5_raw)[1] <- "yyyymm"
ff5 <- ff5_raw
ff5$yyyymm  <- as.integer(trimws(ff5_raw[,1]))
ff5$yearmon <- format(as.Date(paste0(substr(ff5$yyyymm,1,4),"-",substr(ff5$yyyymm,5,6),"-01")),"%Y-%m")
ff5$mkt_rf  <- as.numeric(ff5_raw$Mkt.RF)/100
ff5$smb     <- as.numeric(ff5_raw$SMB)/100
ff5$hml     <- as.numeric(ff5_raw$HML)/100
ff5$rmw     <- as.numeric(ff5_raw$RMW)/100
ff5$cma     <- as.numeric(ff5_raw$CMA)/100
ff5$rf      <- as.numeric(ff5_raw$RF)/100
ff5 <- ff5[ff5$yearmon >= "2015-01" & ff5$yearmon <= "2024-11", c("yearmon","mkt_rf","smb","hml","rmw","cma","rf")]
cat("FF5 loaded:", nrow(ff5), "months\n")
results    <- readRDS("~/nordera/xgboost_results.rds")
port_reg   <- results$port_reg
port_xgb   <- results$port_xgb
port_xgb20 <- results$port_xgb20
merge_ff5 <- function(port_df, ret_col) {
  df <- port_df[, c("yearmon", ret_col)]
  names(df)[2] <- "ret"
  df <- merge(df, ff5, by="yearmon")
  df[!is.na(df$mkt_rf) & !is.na(df$ret), ]
}
data_reg   <- merge_ff5(port_reg,   "ret_ls_reg")
data_xgb   <- merge_ff5(port_xgb,   "ret_ls_xgb")
data_xgb20 <- merge_ff5(port_xgb20, "ret_ls_xgb20")
run_ff5 <- function(data, name) {
  cat("\n---", name, "---\n")
  ols    <- lm(ret ~ mkt_rf + smb + hml + rmw + cma, data=data)
  nw_vcv <- NeweyWest(ols, lag=6, prewhite=FALSE)
  result <- coeftest(ols, vcov=nw_vcv)
  alpha   <- result["(Intercept)","Estimate"]
  alpha_t <- result["(Intercept)","t value"]
  alpha_p <- result["(Intercept)","Pr(>|t|)"]
  stars <- ifelse(alpha_p<0.001,"***",ifelse(alpha_p<0.01,"**",ifelse(alpha_p<0.05,"*",ifelse(alpha_p<0.10,".",""))))
  cat(sprintf("  Monthly alpha: %+.4f%s\n", alpha, stars))
  cat(sprintf("  Annualized:    %+.2f%%\n", alpha*12*100))
  cat(sprintf("  t-stat:        %.2f   p: %.4f\n", alpha_t, alpha_p))
  cat(sprintf("  R2: %.4f   N: %d\n", summary(ols)$r.squared, nrow(data)))
}
run_ff5(data_reg,   "Regression L/S")
res_reg   <- run_ff5(data_reg,   "Regression L/S")
res_xgb20 <- run_ff5(data_xgb20, "XGBoost Top/Bot 20%")
res_xgb   <- run_ff5(data_xgb,   "XGBoost Decile 10-1")
saveRDS(list(res_reg=res_reg, res_xgb=res_xgb, res_xgb20=res_xgb20,
             ff5=ff5, data_reg=data_reg, data_xgb=data_xgb, data_xgb20=data_xgb20),
        "~/nordera/ff5_results.rds")
cat("\nSaved ff5_results.rds\n")
cat("=== DONE ===\n")
