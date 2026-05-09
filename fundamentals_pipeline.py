"""
fundamentals_pipeline.py
========================
Step 2 of the insider trading project.

Takes Brandon's parquet files (firm x month insider signals) and:
  1. Maps CIK -> PERMNO via the CRSP-Compustat linking table
  2. Pulls monthly CRSP firm characteristics (size, BM, returns)
  3. Merges everything into a single panel
  4. Classifies each insider trade as routine vs opportunistic
     using the Cohen, Malloy, Pomorski (2012) algorithm
  5. Exports the final panel ready for regressions

Requirements
------------
  pip install pyodbc pandas numpy glob2

Usage
-----
  python fundamentals_pipeline.py \
      --raw_dir   data/raw \
      --out_path  data/final_panel.parquet \
      --server    hedge.mit.edu \
      --start     2010-01-01 \
      --end       2025-12-31
"""

import argparse
import glob
import os
import warnings
import pyodbc
import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")


# ── 0. CLI ────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--raw_dir",  default="data/raw",
                   help="Folder containing Brandon's parquet files")
    p.add_argument("--out_path", default="data/final_panel.parquet",
                   help="Where to save the final merged panel")
    p.add_argument("--server",   default="hedge.mit.edu",
                   help="SQL server hostname")
    p.add_argument("--start",    default="2010-01-01")
    p.add_argument("--end",      default="2025-12-31")
    return p.parse_args()


# ── 1. DATABASE CONNECTION ────────────────────────────────────────────────────

def get_connection(server: str) -> pyodbc.Connection:
    """
    Trusted (Kerberos) connection — same approach used in Project E.
    Uses Windows Auth on Engaging; no password stored in code.
    """
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={server};"
        f"Trusted_Connection=yes;"
    )
    print(f"Connecting to {server} ...")
    conn = pyodbc.connect(conn_str, timeout=30)
    print("  Connected.")
    return conn


# ── 2. LOAD BRANDON'S DATA ────────────────────────────────────────────────────

def load_insider_panel(raw_dir: str) -> pd.DataFrame:
    """
    Load all parquet files produced by Brandon's collect_quarter_fast()
    and aggregate_to_firm_month(), then stack into one DataFrame.

    Expects files matching: data/raw/insider_YYYY_QN_*.parquet
    If pre-aggregated firm_month CSVs exist, load those instead.
    """
    # Try firm_month CSVs first (Camilo's export)
    csv_files = glob.glob(os.path.join(raw_dir, "*firm_month*.csv"))
    if csv_files:
        print(f"Loading {len(csv_files)} firm_month CSV(s) ...")
        dfs = [pd.read_csv(f) for f in csv_files]
        df = pd.concat(dfs, ignore_index=True)
        print(f"  {len(df):,} firm-month rows loaded.")
        return df

    # Otherwise load raw parquets and aggregate here
    parquet_files = glob.glob(os.path.join(raw_dir, "insider_*.parquet"))
    if not parquet_files:
        raise FileNotFoundError(
            f"No parquet or CSV files found in {raw_dir}. "
            "Run Brandon's collection script first."
        )

    print(f"Loading {len(parquet_files)} raw parquet(s) and aggregating ...")
    raw_dfs = [pd.read_parquet(f) for f in parquet_files]
    raw = pd.concat(raw_dfs, ignore_index=True)
    print(f"  {len(raw):,} raw transactions loaded.")

    # Re-run aggregation (copied logic from Brandon's notebook)
    ps = raw[raw["txn_code"].isin(["P", "S"])].copy()
    ps["date_filed"]   = pd.to_datetime(ps["date_filed"],  errors="coerce")
    ps["txn_date"]     = pd.to_datetime(ps["txn_date"],    errors="coerce")
    ps["filing_month"] = ps["date_filed"].dt.to_period("M").astype(str)

    for col in ["trade_value", "shares"]:
        ps[col] = pd.to_numeric(ps[col], errors="coerce")

    ps["signed_value"] = np.where(ps["txn_code"] == "P",
                                   ps["trade_value"], -ps["trade_value"])
    ps["buy_value"]    = np.where(ps["txn_code"] == "P", ps["trade_value"], 0)
    ps["sell_value"]   = np.where(ps["txn_code"] == "S", ps["trade_value"], 0)
    ps["buy_shares"]   = np.where(ps["txn_code"] == "P", ps["shares"], 0)
    ps["sell_shares"]  = np.where(ps["txn_code"] == "S", ps["shares"], 0)

    firm_month = (
        ps.groupby(["cik", "ticker", "filing_month"])
        .agg(
            n_unique_insiders = ("owner_cik",    "nunique"),
            n_transactions    = ("txn_code",     "count"),
            net_value         = ("signed_value", "sum"),
            gross_buy_value   = ("buy_value",    "sum"),
            gross_sell_value  = ("sell_value",   "sum"),
            gross_buy_shares  = ("buy_shares",   "sum"),
            gross_sell_shares = ("sell_shares",  "sum"),
            any_10b51         = ("is_10b51_doc", "max"),
            n_officer_days    = ("is_officer",   "sum"),
        )
        .reset_index()
    )
    firm_month["trade_direction"]   = np.sign(firm_month["net_value"]).astype(int)
    firm_month["coordination_dummy"]= (firm_month["n_unique_insiders"] >= 2).astype(int)
    print(f"  {len(firm_month):,} firm-month rows after aggregation.")
    return firm_month


# ── 3. CIK → PERMNO MAPPING ──────────────────────────────────────────────────

def get_cik_permno_map(conn: pyodbc.Connection,
                       cik_list: list) -> pd.DataFrame:
    """
    Fetch the CIK -> PERMNO link from the CRSP-Compustat linking table.

    The standard WRDS table is crsp.ccmxpf_linktable.
    On the Mende server the schema prefix may be 'dbo.' — adjust if needed.

    Link types:
      LC = primary link (best), LU = secondary. We keep both and
      deduplicate by preferring LC links and most recent linkdt.

    Returns a DataFrame with columns: cik, permno
    """
    # Format CIK list for SQL IN clause (remove leading zeros)
    cik_ints = list({int(c) for c in cik_list if str(c).isdigit()})
    if not cik_ints:
        raise ValueError("No valid integer CIKs found in insider panel.")

    # SQL Server requires chunking for large IN lists
    chunk_size = 1000
    chunks = [cik_ints[i:i+chunk_size]
              for i in range(0, len(cik_ints), chunk_size)]

    rows = []
    for chunk in chunks:
        placeholders = ",".join("?" * len(chunk))
        sql = f"""
            SELECT
                CAST(gvkey AS VARCHAR) AS gvkey,
                lpermno                AS permno,
                linktype,
                linkdt,
                linkenddt,
                cik
            FROM dbo.ccmxpf_linktable
            WHERE cik IN ({placeholders})
              AND linktype IN ('LC','LU','LS')
              AND (linkenddt IS NULL OR linkenddt >= '2010-01-01')
        """
        cur = conn.cursor()
        cur.execute(sql, chunk)
        cols = [d[0] for d in cur.description]
        rows.extend([dict(zip(cols, row)) for row in cur.fetchall()])

    if not rows:
        raise ValueError(
            "No CIK->PERMNO links found. Check that dbo.ccmxpf_linktable "
            "exists on the server and that the CIK column is populated."
        )

    link = pd.DataFrame(rows)
    link["cik"]      = link["cik"].astype(str).str.zfill(10)
    link["permno"]   = pd.to_numeric(link["permno"], errors="coerce")
    link["linkdt"]   = pd.to_datetime(link["linkdt"],    errors="coerce")
    link["linkenddt"]= pd.to_datetime(link["linkenddt"], errors="coerce")

    # Keep best link per CIK: prefer LC, then most recent
    link["link_rank"] = link["linktype"].map({"LC": 0, "LS": 1, "LU": 2})
    link = (link.sort_values(["cik", "link_rank", "linkdt"],
                              ascending=[True, True, False])
                 .drop_duplicates(subset=["cik"])
                 [["cik", "permno"]])

    print(f"  CIK->PERMNO: {len(link):,} unique links found "
          f"({link['permno'].notna().sum():,} with valid PERMNO).")
    return link


# ── 4. CRSP MONTHLY CHARACTERISTICS ──────────────────────────────────────────

def get_crsp_monthly(conn: pyodbc.Connection,
                     permno_list: list,
                     start: str,
                     end: str) -> pd.DataFrame:
    """
    Pull monthly stock data from CRSP for the given PERMNOs.

    Variables pulled:
      - ret        : monthly return
      - prc        : price (absolute value; CRSP uses negative for bid/ask avg)
      - shrout     : shares outstanding (thousands)
      - me         : market equity = |prc| * shrout  (computed here)
      - bm         : book-to-market (from Compustat annual, lagged 6 months)

    For BM we use the Fama-French convention: book equity from the
    most recent fiscal year ending at least 6 months before the month.

    Returns DataFrame indexed by (permno, yyyymm).
    """
    permno_ints = list({int(p) for p in permno_list
                        if not pd.isna(p)})
    chunk_size  = 500
    chunks = [permno_ints[i:i+chunk_size]
              for i in range(0, len(permno_ints), chunk_size)]

    rows = []
    for chunk in chunks:
        placeholders = ",".join("?" * len(chunk))
        sql = f"""
            SELECT
                m.permno,
                m.date            AS crsp_date,
                m.ret,
                ABS(m.prc)        AS prc,
                m.shrout,
                ABS(m.prc) * m.shrout * 1000.0  AS me
            FROM dbo.crsp_msf AS m          -- monthly stock file
            WHERE m.permno IN ({placeholders})
              AND m.date BETWEEN ? AND ?
              AND m.ret IS NOT NULL
        """
        params = chunk + [start, end]
        cur = conn.cursor()
        cur.execute(sql, params)
        cols = [d[0] for d in cur.description]
        rows.extend([dict(zip(cols, row)) for row in cur.fetchall()])

    if not rows:
        raise ValueError("No CRSP monthly data returned. Check table name "
                         "dbo.crsp_msf and date range.")

    crsp = pd.DataFrame(rows)
    crsp["crsp_date"] = pd.to_datetime(crsp["crsp_date"])
    crsp["yyyymm"]    = crsp["crsp_date"].dt.to_period("M").astype(str)
    crsp["permno"]    = crsp["permno"].astype(int)
    crsp["ret"]       = pd.to_numeric(crsp["ret"], errors="coerce")
    crsp["me"]        = pd.to_numeric(crsp["me"],  errors="coerce")

    # ---- Past returns -------------------------------------------------------
    crsp = crsp.sort_values(["permno", "crsp_date"])

    # Past 1-month return (prior month)
    crsp["ret_1m"] = crsp.groupby("permno")["ret"].shift(1)

    # Past 12-month cumulative return (months t-2 to t-12, skipping t-1)
    # Standard momentum: compounded return over months -12 to -2
    crsp["ret_12m"] = (
        crsp.groupby("permno")["ret"]
        .transform(lambda x: (1 + x.shift(2)).rolling(11).apply(
            lambda r: r.prod() - 1, raw=True))
    )

    # Log size (Fama-French: log of market equity)
    crsp["log_me"] = np.log(crsp["me"].clip(lower=1))

    print(f"  CRSP: {len(crsp):,} monthly observations for "
          f"{crsp['permno'].nunique():,} stocks.")
    return crsp[["permno", "yyyymm", "crsp_date",
                 "ret", "ret_1m", "ret_12m", "me", "log_me"]]


# ── 5. BOOK-TO-MARKET FROM COMPUSTAT ─────────────────────────────────────────

def get_book_to_market(conn: pyodbc.Connection,
                       permno_list: list,
                       start: str,
                       end: str) -> pd.DataFrame:
    """
    Pull annual book equity from Compustat and compute book-to-market.
    Uses the Fama-French timing convention:
      BM for calendar year t uses book equity from fiscal year ending
      in calendar year t-1, applied from July t to June t+1.

    Returns DataFrame with (permno, yyyymm, bm).
    """
    permno_ints = list({int(p) for p in permno_list if not pd.isna(p)})
    chunk_size  = 500
    chunks = [permno_ints[i:i+chunk_size]
              for i in range(0, len(permno_ints), chunk_size)]

    rows = []
    for chunk in chunks:
        placeholders = ",".join("?" * len(chunk))
        # Join Compustat annual (funda) with CRSP link via gvkey
        sql = f"""
            SELECT
                lnk.lpermno    AS permno,
                a.fyear,
                a.datadate,
                a.ceq           AS book_equity,  -- common equity
                a.pstkl         AS pref_stock,   -- preferred stock liquidation
                a.txditc        AS def_tax       -- deferred taxes
            FROM dbo.comp_funda AS a
            JOIN dbo.ccmxpf_linktable AS lnk
              ON a.gvkey = lnk.gvkey
             AND lnk.lpermno IN ({placeholders})
             AND lnk.linktype IN ('LC','LU','LS')
             AND (lnk.linkenddt IS NULL OR lnk.linkenddt >= a.datadate)
             AND lnk.linkdt <= a.datadate
            WHERE a.indfmt  = 'INDL'
              AND a.datafmt = 'STD'
              AND a.popsrc  = 'D'
              AND a.consol  = 'C'
              AND a.datadate BETWEEN ? AND ?
              AND a.ceq IS NOT NULL
        """
        params = chunk + [
            str(int(start[:4]) - 2) + "-01-01",  # go back extra for timing
            end
        ]
        cur = conn.cursor()
        cur.execute(sql, params)
        cols = [d[0] for d in cur.description]
        rows.extend([dict(zip(cols, row)) for row in cur.fetchall()])

    if not rows:
        print("  WARNING: No Compustat data returned. BM will be missing.")
        return pd.DataFrame(columns=["permno", "yyyymm", "bm"])

    comp = pd.DataFrame(rows)
    comp["datadate"]     = pd.to_datetime(comp["datadate"])
    comp["permno"]       = pd.to_numeric(comp["permno"],    errors="coerce")
    comp["book_equity"]  = pd.to_numeric(comp["book_equity"],errors="coerce")
    comp["pref_stock"]   = pd.to_numeric(comp["pref_stock"], errors="coerce").fillna(0)
    comp["def_tax"]      = pd.to_numeric(comp["def_tax"],    errors="coerce").fillna(0)

    # Book equity (Davis, Fama, French 2000 definition)
    comp["be"] = comp["book_equity"] + comp["def_tax"] - comp["pref_stock"]
    comp = comp[comp["be"] > 0].copy()

    # Assign to calendar months using FF timing convention
    # Fiscal year ending in calendar year Y -> applies July Y+1 to June Y+2
    comp["apply_start"] = comp["datadate"].apply(
        lambda d: pd.Period(f"{d.year + 1}-07", freq="M"))
    comp["apply_end"]   = comp["datadate"].apply(
        lambda d: pd.Period(f"{d.year + 2}-06", freq="M"))

    # Expand to monthly rows (we'll merge on yyyymm later)
    monthly_rows = []
    for _, row in comp.iterrows():
        period = row["apply_start"]
        while period <= row["apply_end"]:
            monthly_rows.append({
                "permno":  row["permno"],
                "yyyymm":  str(period),
                "be":      row["be"],
            })
            period += 1

    be_monthly = pd.DataFrame(monthly_rows)
    be_monthly["permno"] = be_monthly["permno"].astype(int)
    print(f"  Compustat BE: {len(comp):,} annual obs -> "
          f"{len(be_monthly):,} monthly rows.")
    return be_monthly  # will merge with crsp me to get bm


# ── 6. ROUTINE VS OPPORTUNISTIC CLASSIFICATION ───────────────────────────────

def classify_routine_opportunistic(raw_trades: pd.DataFrame) -> pd.DataFrame:
    """
    Cohen, Malloy, Pomorski (2012) algorithm.

    A trade is ROUTINE if the same insider traded in the same calendar
    month for at least 3 consecutive years prior to the current trade.
    Everything else is OPPORTUNISTIC.

    Input:  raw transaction-level DataFrame (from Brandon's parquet files)
            Must have columns: owner_cik, cik, txn_date, txn_code

    Output: DataFrame with (owner_cik, cik, filing_month, is_routine)
            aggregated to insider x firm x filing_month level.

    Note: We use FILING month (public info) not transaction date,
          consistent with Camilo's update.
    """
    ps = raw_trades[raw_trades["txn_code"].isin(["P", "S"])].copy()
    ps["txn_date"]     = pd.to_datetime(ps["txn_date"],   errors="coerce")
    ps["date_filed"]   = pd.to_datetime(ps["date_filed"], errors="coerce")
    ps["filing_month"] = ps["date_filed"].dt.to_period("M")
    ps["txn_month"]    = ps["txn_date"].dt.month      # 1-12
    ps["txn_year"]     = ps["txn_date"].dt.year

    # For each insider x firm, get the set of (year, calendar_month) traded
    history = (
        ps.groupby(["owner_cik", "cik", "txn_year", "txn_month"])
        .size()
        .reset_index(name="n")
        [["owner_cik", "cik", "txn_year", "txn_month"]]
        .drop_duplicates()
    )

    def _is_routine(group):
        """
        For each row in this insider-firm group, check if there are
        trades in the same calendar month in each of the 3 prior years.
        """
        results = []
        years_by_month = group.groupby("txn_month")["txn_year"].apply(set).to_dict()

        for _, row in group.iterrows():
            m = row["txn_month"]
            y = row["txn_year"]
            years_traded = years_by_month.get(m, set())
            # Check 3 consecutive prior years all have a trade in month m
            prior_3 = {y - 1, y - 2, y - 3}
            routine  = prior_3.issubset(years_traded)
            results.append({
                "owner_cik":  row["owner_cik"],
                "cik":        row["cik"],
                "txn_year":   y,
                "txn_month":  m,
                "is_routine": int(routine),
            })
        return pd.DataFrame(results)

    print("  Classifying routine vs opportunistic (CMP 2012 algorithm)...")
    classified = (
        history.groupby(["owner_cik", "cik"], group_keys=False)
        .apply(_is_routine)
        .reset_index(drop=True)
    )

    # Merge back to get filing_month
    ps_with_class = ps.merge(
        classified,
        on=["owner_cik", "cik", "txn_year", "txn_month"],
        how="left"
    )
    ps_with_class["is_routine"] = ps_with_class["is_routine"].fillna(0).astype(int)

    # Aggregate to insider x firm x filing_month
    result = (
        ps_with_class.groupby(["owner_cik", "cik", "filing_month"])
        .agg(is_routine=("is_routine", "max"))  # routine if ANY trade is routine
        .reset_index()
    )
    result["filing_month"] = result["filing_month"].astype(str)
    result["is_opportunistic"] = 1 - result["is_routine"]

    print(f"  Classified {len(result):,} insider-firm-month observations.")
    pct_routine = result["is_routine"].mean() * 100
    print(f"  Routine: {pct_routine:.1f}%  |  "
          f"Opportunistic: {100 - pct_routine:.1f}%")
    return result


# ── 7. AGGREGATE ROUTINE FLAG TO FIRM-MONTH ──────────────────────────────────

def aggregate_routine_to_firm_month(routine_df: pd.DataFrame) -> pd.DataFrame:
    """
    Roll up insider-level routine/opportunistic flags to firm x month.

    A firm-month is tagged 'opportunistic' if at least one insider
    traded opportunistically. Separate counts give richer signal.
    """
    agg = (
        routine_df.groupby(["cik", "filing_month"])
        .agg(
            n_routine_insiders      = ("is_routine",      "sum"),
            n_opportunistic_insiders= ("is_opportunistic","sum"),
            n_total_insiders        = ("owner_cik",       "nunique"),
        )
        .reset_index()
    )
    agg["any_opportunistic"] = (agg["n_opportunistic_insiders"] > 0).astype(int)
    agg["any_routine"]       = (agg["n_routine_insiders"]       > 0).astype(int)
    agg["pct_opportunistic"] = (
        agg["n_opportunistic_insiders"] / agg["n_total_insiders"]
    ).fillna(0)
    return agg


# ── 8. MASTER MERGE ──────────────────────────────────────────────────────────

def build_final_panel(firm_month:    pd.DataFrame,
                      cik_permno:    pd.DataFrame,
                      crsp:          pd.DataFrame,
                      be_monthly:    pd.DataFrame,
                      routine_agg:   pd.DataFrame) -> pd.DataFrame:
    """
    Merge everything into the final regression panel.

    Final columns:
      Identifiers : cik, permno, ticker, filing_month
      Insider signals : net_value, gross_buy_value, gross_sell_value,
                        trade_direction, coordination_dummy, any_10b51,
                        n_unique_insiders, n_transactions
      Routine/Opp : any_opportunistic, any_routine, pct_opportunistic,
                    n_routine_insiders, n_opportunistic_insiders
      CRSP controls : ret (forward return), ret_1m, ret_12m, me, log_me, bm
    """
    panel = firm_month.copy()
    panel["cik"] = panel["cik"].astype(str).str.zfill(10)

    # 1. Add PERMNO
    cik_permno["cik"] = cik_permno["cik"].astype(str).str.zfill(10)
    panel = panel.merge(cik_permno, on="cik", how="left")
    n_no_permno = panel["permno"].isna().sum()
    if n_no_permno > 0:
        print(f"  WARNING: {n_no_permno:,} firm-months have no PERMNO match "
              "(will be dropped for return regressions).")

    # 2. Add routine/opportunistic flags
    routine_agg["cik"] = routine_agg["cik"].astype(str).str.zfill(10)
    panel = panel.merge(routine_agg, on=["cik", "filing_month"], how="left")

    # 3. Merge CRSP characteristics on permno x yyyymm
    panel["yyyymm"] = panel["filing_month"]  # both are "YYYY-MM" strings
    crsp["permno"]  = crsp["permno"].astype("Int64")
    panel["permno"] = panel["permno"].astype("Int64")
    panel = panel.merge(
        crsp[["permno", "yyyymm", "ret", "ret_1m", "ret_12m", "me", "log_me"]],
        on=["permno", "yyyymm"], how="left"
    )

    # 4. Merge book equity, then compute BM
    be_monthly["permno"] = be_monthly["permno"].astype("Int64")
    panel = panel.merge(be_monthly, on=["permno", "yyyymm"], how="left")
    panel["bm"] = panel["be"] / panel["me"]
    panel["bm"] = panel["bm"].clip(lower=0, upper=10)  # winsorise extremes

    # 5. Forward return: the dependent variable (next month's return)
    panel = panel.sort_values(["permno", "filing_month"])
    panel["ret_fwd_1m"] = (
        panel.groupby("permno")["ret"].shift(-1)
    )

    # 6. Clean up
    panel = panel.drop(columns=["be", "yyyymm"], errors="ignore")
    panel = panel.sort_values(["cik", "filing_month"]).reset_index(drop=True)

    print(f"\n  Final panel: {len(panel):,} firm-month rows.")
    print(f"  Rows with PERMNO:         {panel['permno'].notna().sum():,}")
    print(f"  Rows with CRSP return:    {panel['ret'].notna().sum():,}")
    print(f"  Rows with BM:             {panel['bm'].notna().sum():,}")
    print(f"  Rows with fwd return:     {panel['ret_fwd_1m'].notna().sum():,}")
    return panel


# ── 9. MAIN ───────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    # ── Load Brandon's output ─────────────────────────────────────────────────
    print("\n[1/6] Loading insider panel ...")
    firm_month = load_insider_panel(args.raw_dir)

    # Also load raw transactions for routine classification
    raw_files = glob.glob(os.path.join(args.raw_dir, "insider_*.parquet"))
    if raw_files:
        print(f"  Loading {len(raw_files)} raw parquet(s) for routine classification ...")
        raw_trades = pd.concat([pd.read_parquet(f) for f in raw_files],
                               ignore_index=True)
    else:
        print("  WARNING: No raw parquets found; skipping routine classification.")
        raw_trades = pd.DataFrame()

    # ── Connect to SQL server ─────────────────────────────────────────────────
    print("\n[2/6] Connecting to SQL server ...")
    conn = get_connection(args.server)

    # ── CIK -> PERMNO ─────────────────────────────────────────────────────────
    print("\n[3/6] Fetching CIK -> PERMNO mapping ...")
    cik_list   = firm_month["cik"].dropna().unique().tolist()
    cik_permno = get_cik_permno_map(conn, cik_list)

    # ── CRSP monthly data ─────────────────────────────────────────────────────
    print("\n[4/6] Pulling CRSP monthly characteristics ...")
    permno_list = cik_permno["permno"].dropna().unique().tolist()
    crsp        = get_crsp_monthly(conn, permno_list, args.start, args.end)

    # Book-to-market from Compustat
    be_monthly  = get_book_to_market(conn, permno_list, args.start, args.end)

    # Merge BE into CRSP to compute BM (needed for build_final_panel)
    crsp = crsp.merge(be_monthly.rename(columns={"be": "_be_tmp"}),
                      on=["permno", "yyyymm"], how="left")

    conn.close()
    print("  SQL connection closed.")

    # ── Routine vs opportunistic ──────────────────────────────────────────────
    print("\n[5/6] Classifying routine vs opportunistic trades ...")
    if not raw_trades.empty:
        routine_insider = classify_routine_opportunistic(raw_trades)
        routine_agg     = aggregate_routine_to_firm_month(routine_insider)
    else:
        routine_agg = pd.DataFrame(
            columns=["cik", "filing_month", "any_opportunistic",
                     "any_routine", "pct_opportunistic",
                     "n_routine_insiders", "n_opportunistic_insiders",
                     "n_total_insiders"])

    # ── Build final panel ─────────────────────────────────────────────────────
    print("\n[6/6] Building final merged panel ...")
    # Re-create be_monthly without the crsp merge column
    be_monthly2 = get_book_to_market.__wrapped__ if hasattr(
        get_book_to_market, "__wrapped__") else be_monthly

    final_panel = build_final_panel(
        firm_month  = firm_month,
        cik_permno  = cik_permno,
        crsp        = crsp.drop(columns=["_be_tmp"], errors="ignore"),
        be_monthly  = be_monthly,
        routine_agg = routine_agg,
    )

    # ── Save ──────────────────────────────────────────────────────────────────
    os.makedirs(os.path.dirname(args.out_path) or ".", exist_ok=True)
    final_panel.to_parquet(args.out_path, index=False)

    # Also save CSV for easy inspection
    csv_path = args.out_path.replace(".parquet", ".csv")
    final_panel.to_csv(csv_path, index=False)

    print(f"\n✓ Final panel saved to: {args.out_path}")
    print(f"✓ CSV copy saved to:    {csv_path}")
    print("\nColumn summary:")
    print(final_panel.dtypes.to_string())
    print("\nFirst 5 rows:")
    print(final_panel.head().to_string())


if __name__ == "__main__":
    main()
