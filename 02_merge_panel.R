library(dplyr)
library(lubridate)

cat("Loading data...\n")
insider <- readRDS("~/nordera/insider_classified.rds")
panel   <- read.csv("~/nordera/panel_full.csv")
cat("Insider rows:", nrow(insider), "\n")
cat("Panel rows:  ", nrow(panel), "\n")

# --- Sanity check: yearmon must be zero-padded "YYYY-MM" for correct string sort ---
if ("yearmon" %in% names(panel)) {
  bad_format <- sum(!grepl("^\\d{4}-\\d{2}$", panel$yearmon), na.rm = TRUE)
  if (bad_format > 0) {
    cat("WARNING:", bad_format, "yearmon values are not in YYYY-MM format — reformatting...\n")
    panel$yearmon <- format(as.Date(paste0(panel$yearmon, "-01")), "%Y-%m")
  } else {
    cat("yearmon format OK\n")
  }
}

# --- Aggregate insider trades to firm-month level ---
cat("Aggregating insider trades to firm-month...\n")

insider_agg <- insider %>%
  mutate(yearmon = format(as.Date(transactiondate), "%Y-%m")) %>%
  group_by(issuercik, yearmon) %>%
  summarise(
    n_routine         = sum(is_routine,      na.rm = TRUE),
    n_opportunistic   = sum(is_opportunistic, na.rm = TRUE),
    # total shares traded (all directions) by type
    vol_routine       = sum(transactionshares[is_routine],       na.rm = TRUE),
    vol_opportunistic = sum(transactionshares[is_opportunistic], na.rm = TRUE),
    # net direction: buys minus sells, by type
    net_opportunistic = sum(transactionshares[is_opportunistic & transactioncode == "P"], na.rm = TRUE) -
      sum(transactionshares[is_opportunistic & transactioncode == "S"], na.rm = TRUE),
    net_routine       = sum(transactionshares[is_routine       & transactioncode == "P"], na.rm = TRUE) -
      sum(transactionshares[is_routine       & transactioncode == "S"], na.rm = TRUE),
    .groups = "drop"
  )

cat("Insider aggregated rows:", nrow(insider_agg), "\n")

# --- Merge insider aggregates into panel ---
cat("Merging with panel...\n")
panel_full <- panel %>%
  left_join(insider_agg, by = c("cik" = "issuercik", "yearmon" = "yearmon"))

# Months with no insider trading -> 0 (not NA)
na_to_zero <- c("n_routine", "n_opportunistic",
                "vol_routine", "vol_opportunistic",
                "net_opportunistic", "net_routine")
for (col in na_to_zero) {
  panel_full[[col]][is.na(panel_full[[col]])] <- 0
}

# --- Check for duplicate permno-yearmon rows (can arise from many-to-many CIK-PERMNO links) ---
dups <- panel_full %>%
  group_by(permno, yearmon) %>%
  filter(n() > 1) %>%
  ungroup()

if (nrow(dups) > 0) {
  cat("WARNING:", nrow(dups), "duplicate permno-yearmon rows detected — keeping first occurrence\n")
  panel_full <- panel_full %>%
    group_by(permno, yearmon) %>%
    slice(1) %>%
    ungroup()
} else {
  cat("No duplicates found — OK\n")
}

# --- Summary ---
cat("=== MERGE RESULTS ===\n")
cat("Final panel rows:               ", nrow(panel_full), "\n")
cat("Columns:                        ", ncol(panel_full), "\n")
cat("Months with opportunistic signal:", sum(panel_full$n_opportunistic > 0), "\n")
cat("Months with routine signal:      ", sum(panel_full$n_routine > 0), "\n")
cat("Columns in panel:\n")
print(names(panel_full))

saveRDS(panel_full, "~/nordera/panel_classified.rds")
cat("Saved panel_classified.rds\n")
