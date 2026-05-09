library(dplyr)

cat("Exporting XGBoost predictions to CSV for Python RL script...\n")

results <- readRDS("~/nordera/xgboost_results.rds")
predictions <- results$predictions

cat("Predictions rows:", nrow(predictions), "\n")
cat("Columns:", paste(names(predictions), collapse=", "), "\n")

# Keep only columns needed for RL
predictions_export <- predictions %>%
  select(permno, yearmon, ret_lead, target,
         signal_opportunistic, signal_routine, xgb_prob) %>%
  arrange(yearmon, permno)

write.csv(predictions_export,
          "~/nordera/predictions.csv",
          row.names = FALSE)

cat("Saved predictions.csv —", nrow(predictions_export), "rows\n")
cat("Period:", min(predictions_export$yearmon),
    "to", max(predictions_export$yearmon), "\n")
cat("Done.\n")
