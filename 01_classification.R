library(dplyr)
library(lubridate)

cat("Loading data...\n")
insider <- read.csv("~/nordera/insider_clean.csv")
cat("Rows:", nrow(insider), "\n")

insider$transactiondate <- as.Date(insider$transactiondate)
insider$month_cal <- month(insider$transactiondate)
insider$year_cal  <- year(insider$transactiondate)

cat("Classifying trades (Cohen, Malloy, Pomorski 2012)...\n")

# Step 1: collapse to unique insider-month-year observations
# (one row per insider x calendar month x year — removes intra-month duplicates)
trades_collapsed <- insider %>%
  group_by(issuercik, directorindirectownership, month_cal, year_cal) %>%
  summarise(traded = 1, .groups = "drop")

# Step 2: for each insider x calendar month, check if they traded in
# that same month for AT LEAST 3 consecutive calendar years
routine_flag <- trades_collapsed %>%
  arrange(issuercik, directorindirectownership, month_cal, year_cal) %>%
  group_by(issuercik, directorindirectownership, month_cal) %>%
  mutate(
    # year gap to previous observation in same month
    year_gap = year_cal - lag(year_cal, default = year_cal[1] - 1),
    # new streak starts when gap != 1
    streak_id = cumsum(year_gap != 1),
    # length of current consecutive streak
    streak_len = ave(year_cal, streak_id, FUN = seq_along)
  ) %>%
  # a year is routine if the streak ending IN THAT year is >= 3
  mutate(is_routine_year = streak_len >= 3) %>%
  ungroup() %>%
  select(issuercik, directorindirectownership, month_cal, year_cal, is_routine_year)

# Step 3: join back to full insider dataset on issuercik + ownership + month + YEAR
# (the year dimension is critical: a trade is routine only in the years
#  where the 3-consecutive-year criterion was met, not all future years)
insider <- insider %>%
  left_join(
    routine_flag,
    by = c("issuercik", "directorindirectownership", "month_cal", "year_cal")
  ) %>%
  rename(is_routine = is_routine_year)

insider$is_routine[is.na(insider$is_routine)] <- FALSE
insider$is_opportunistic <- !insider$is_routine

# Sanity checks
cat("=== CLASSIFICATION RESULTS ===\n")
cat("Routine trades:      ", sum(insider$is_routine), "\n")
cat("Opportunistic trades:", sum(insider$is_opportunistic), "\n")
cat("% Routine:           ", round(mean(insider$is_routine) * 100, 1), "%\n")
cat("% Opportunistic:     ", round(mean(insider$is_opportunistic) * 100, 1), "%\n")

stopifnot(sum(insider$is_routine) + sum(insider$is_opportunistic) == nrow(insider))

saveRDS(insider, "~/nordera/insider_classified.rds")
cat("Saved insider_classified.rds\n")

