#!/usr/bin/env python
# coding: utf-8

# In[1]:


import sys
print(sys.executable)


# In[2]:


import requests
import pandas as pd
import xml.etree.ElementTree as ET
import time
from typing import Optional
import re


# In[3]:


HEADERS = {"User-Agent": "BrandonLi nordera@mit.edu"}

def get_form4_index(year: int, quarter: int) -> pd.DataFrame:
    url = f"https://www.sec.gov/Archives/edgar/full-index/{year}/QTR{quarter}/crawler.idx"
    response = requests.get(url, headers=HEADERS)
    response.raise_for_status()

    lines = response.text.split("\n")

    header_line = next((l for l in lines if "Form Type" in l and "CIK" in l), None)
    sep_line    = next((l for l in lines if l.startswith("---")), None)
    data_start  = next((i for i, l in enumerate(lines) if l.startswith("---")), 8) + 1

    # Derive positions from header
    c0 = 0
    c1 = header_line.index("Form Type")
    c2 = header_line.index("CIK")
    c3 = header_line.index("Date Filed")
    c4 = header_line.index("URL")

    print(f"Col starts: company={c0}, form_type={c1}, cik={c2}, date_filed={c3}, url={c4}")

    records = []
    for line in lines[data_start:]:
        if not line.strip():
            continue
        try:
            form_type = line[c1:c2].strip()
        except IndexError:
            continue

        if form_type != "4":
            continue

        try:
            company_name = line[c0:c1].strip()
            cik          = line[c2:c3].strip()
            http_pos   = line.find("https://")
            if http_pos == -1:
                continue
            date_filed = line[c3:http_pos].strip()
            index_url  = line[http_pos:].strip()
        except IndexError:
            continue

        if "/Archives/" in index_url:
            path     = index_url.split("/Archives/")[1]
            filename = path.replace("-index.htm", ".txt")
            records.append({
                "company_name": company_name,
                "form_type":    form_type,
                "cik":          cik,
                "date_filed":   date_filed,
                "filename":     filename,
                "index_url":    index_url,
            })

    df = pd.DataFrame(records)
    print(f"Found {len(df)} Form 4 filings")
    print(df[["date_filed", "cik", "filename"]].head(5))
    return df


# In[4]:


def parse_bool(val: str) -> int:
    return 1 if str(val).strip().lower() in ("1", "true") else 0

def get_xml_url_from_index(cik: str, accession_nodash: str) -> Optional[str]:
    folder_url = f"https://www.sec.gov/Archives/edgar/data/{cik}/{accession_nodash}/"
    try:
        resp = requests.get(folder_url, headers=HEADERS, timeout=10)
        resp.raise_for_status()
    except Exception:
        return None

    matches = re.findall(
        rf'href="(/Archives/edgar/data/{cik}/{accession_nodash}/[^"]+\.xml)"',
        resp.text
    )
    for m in matches:
        if "rdgdoc" not in m.lower():
            return "https://www.sec.gov" + m
    return None


def parse_form4(filename: str) -> Optional[list[dict]]:
    parts            = filename.split("/")
    cik              = parts[2]
    accession_nodash = parts[3].replace(".txt", "").replace("-", "")

    xml_url = get_xml_url_from_index(cik, accession_nodash)
    if not xml_url:
        return None

    try:
        xml_resp = requests.get(xml_url, headers=HEADERS, timeout=10)
        xml_resp.raise_for_status()
        root = ET.fromstring(xml_resp.content)
    except Exception:
        return None

    issuer        = root.find(".//issuer")
    ticker        = issuer.findtext("issuerTradingSymbol", "").strip() if issuer else ""
    cik_val       = issuer.findtext("issuerCik", "").strip()           if issuer else ""

    owner         = root.find(".//reportingOwner")
    owner_name    = owner.findtext(".//rptOwnerName",  "").strip() if owner else ""
    owner_cik     = owner.findtext(".//rptOwnerCik",  "").strip() if owner else ""
    is_officer    = parse_bool(owner.findtext(".//isOfficer",  "0") if owner else "0")
    is_director   = parse_bool(owner.findtext(".//isDirector", "0") if owner else "0")
    officer_title = owner.findtext(".//officerTitle",  "").strip() if owner else ""

    # 10b5-1 check
    all_footnotes = " ".join(f.text or "" for f in root.findall(".//footnote"))
    doc_has_10b51 = "10b5-1" in all_footnotes.lower() or "10b5\u20131" in all_footnotes.lower()

    trades = []
    for txn in root.findall(".//nonDerivativeTransaction"):
        txn_footnotes = " ".join(f.text or "" for f in txn.findall(".//footnote"))
        txn_has_10b51 = "10b5-1" in txn_footnotes.lower() or "10b5\u20131" in txn_footnotes.lower()

        price  = txn.findtext(".//transactionAmounts/transactionPricePerShare/value", "") or "0"
        shares = txn.findtext(".//transactionAmounts/transactionShares/value", "") or "0"

        trades.append({
            "ticker":        ticker,
            "cik":           cik_val,
            "owner_name":    owner_name,
            "owner_cik":     owner_cik,
            "is_officer":    is_officer,
            "is_director":   is_director,
            "officer_title": officer_title,
            "txn_date":      txn.findtext(".//transactionDate/value", ""),
            "txn_code":      txn.findtext(".//transactionCoding/transactionCode", ""),
            "acq_disp":      txn.findtext(".//transactionAmounts/transactionAcquiredDisposedCode/value", ""),
            "shares":        float(shares) if shares else None,
            "price":         float(price)  if price  else None,
            "shares_after":  txn.findtext(".//postTransactionAmounts/sharesOwnedFollowingTransaction/value", ""),
            "is_10b51_doc":  doc_has_10b51,
            "is_10b51_txn":  txn_has_10b51,
            "footnotes":     txn_footnotes,
        })

    return trades if trades else None


# In[5]:


def collect_quarter(year: int, quarter: int, max_filings: int = 100) -> pd.DataFrame:
    print(f"\nFetching index for {year} Q{quarter}...")
    index_df = get_form4_index(year, quarter)
    print(f"  Found {len(index_df)} Form 4 filings")

    all_trades = []
    for i, row in index_df.head(max_filings).iterrows():
        trades = parse_form4(row["filename"])
        if trades:
            for t in trades:
                t["date_filed"] = row["date_filed"]
            all_trades.extend(trades)

        time.sleep(0.1)

        if (i + 1) % 20 == 0:
            print(f"  Processed {i+1} filings, {len(all_trades)} trades so far...")

    return pd.DataFrame(all_trades) if all_trades else pd.DataFrame()


# In[7]:


#trades_df = collect_quarter(2023, 1, max_filings=50)
#print(trades_df.head(10))


# In[ ]:


# check data quality 
# trades_df = collect_quarter(2023, 1, max_filings=200)

#print(f"Total transactions: {len(trades_df)}")
#print(f"\ntxn_code breakdown:\n{trades_df['txn_code'].value_counts()}")
#print(f"\nP/S only: {len(trades_df[trades_df['txn_code'].isin(['P','S'])])}")
#print(f"is_10b51_doc=True: {trades_df['is_10b51_doc'].sum()}")
#print(f"Price missing on P/S: {(trades_df[trades_df['txn_code'].isin(['P','S'])]['price']==0).sum()}")
#print(f"\nOfficer titles:\n{trades_df['officer_title'].value_counts().head(10)}")


# FAST + AGG

# In[ ]:


from concurrent.futures import ThreadPoolExecutor, as_completed
import os

#faster XML URL construction

def parse_bool(val: str) -> int:
    return 1 if str(val).strip().lower() in ("1", "true") else 0

COMMON_XML_NAMES = ["form4.xml", "doc1.xml", "primarydocument.xml", "doc4.xml"]

def get_xml_url_fast(cik: str, accession_nodash: str) -> Optional[str]:
    """Try common filenames first before falling back to folder scrape."""
    base = f"https://www.sec.gov/Archives/edgar/data/{cik}/{accession_nodash}"
    
    # Try common names with HEAD requests (much faster than GET)
    for name in COMMON_XML_NAMES:
        url = f"{base}/{name}"
        try:
            r = requests.head(url, headers=HEADERS, timeout=5)
            if r.status_code == 200:
                return url
        except Exception:
            continue

    # Fallback: scrape folder listing (original method)
    try:
        r = requests.get(f"{base}/", headers=HEADERS, timeout=10)
        matches = re.findall(
            rf'href="(/Archives/edgar/data/{cik}/{accession_nodash}/[^"]+\.xml)"',
            r.text
        )
        for m in matches:
            if "rdgdoc" not in m.lower():
                return "https://www.sec.gov" + m
    except Exception:
        pass

    return None


def parse_form4_fast(row: dict) -> list[dict]:
    filename = row["filename"]
    parts    = filename.split("/")
    cik      = parts[2]
    accession_nodash = parts[3].replace(".txt", "").replace("-", "")

    xml_url = get_xml_url_fast(cik, accession_nodash)
    if not xml_url:
        return []

    try:
        xml_resp = requests.get(xml_url, headers=HEADERS, timeout=10)
        xml_resp.raise_for_status()
        root = ET.fromstring(xml_resp.content)
    except Exception:
        return []

    issuer    = root.find(".//issuer")
    ticker    = issuer.findtext("issuerTradingSymbol", "").strip() if issuer else ""
    cik_val   = issuer.findtext("issuerCik", "").strip()           if issuer else ""

    owner         = root.find(".//reportingOwner")
    owner_name    = owner.findtext(".//rptOwnerName", "").strip() if owner else ""
    owner_cik     = owner.findtext(".//rptOwnerCik", "").strip() if owner else ""
    officer_title = owner.findtext(".//officerTitle", "").strip() if owner else ""
    is_officer    = parse_bool(owner.findtext(".//isOfficer",  "0") if owner else "0")
    is_director   = parse_bool(owner.findtext(".//isDirector", "0") if owner else "0")

    all_footnotes = " ".join(f.text or "" for f in root.findall(".//footnote"))
    doc_has_10b51 = "10b5-1" in all_footnotes.lower() or "10b5\u20131" in all_footnotes.lower()

    trades = []
    for txn in root.findall(".//nonDerivativeTransaction"):
        txn_footnotes = " ".join(f.text or "" for f in txn.findall(".//footnote"))
        txn_has_10b51 = "10b5-1" in txn_footnotes.lower() or "10b5-1" in txn_footnotes.lower()
        shares       = txn.findtext(".//transactionAmounts/transactionShares/value", "") or "0"
        price        = txn.findtext(".//transactionAmounts/transactionPricePerShare/value", "") or "0"
        shares_after = txn.findtext(".//postTransactionAmounts/sharesOwnedFollowingTransaction/value", "") or "0"

        shares_f       = float(shares)       if shares       else None
        price_f        = float(price)        if price        else None
        shares_after_f = float(shares_after) if shares_after else None
        trade_value = shares_f * price_f if (shares_f is not None and price_f is not None) else None
        pct_owned_traded = (
            shares_f / shares_after_f
                if (shares_f is not None and shares_after_f is not None and shares_after_f > 0)
                else None
        )

        trades.append({
            "ticker":           ticker,
            "cik":              cik_val,
            "owner_name":       owner_name,
            "owner_cik":        owner_cik,
            "is_officer":       is_officer,
            "is_director":      is_director,
            "officer_title":    officer_title,
            "txn_date":         txn.findtext(".//transactionDate/value", ""),
            "txn_code":         txn.findtext(".//transactionCoding/transactionCode", ""),
            "acq_disp":         txn.findtext(".//transactionAmounts/transactionAcquiredDisposedCode/value", ""),
            "shares":           shares_f,
            "price":            price_f,
            "shares_after":     shares_after_f,
            "trade_value":      trade_value,
            "pct_owned_traded": pct_owned_traded,
            "date_filed":       row["date_filed"],
            "is_10b51_doc":     doc_has_10b51,
            "is_10b51_txn":     txn_has_10b51
        })

    return trades


def collect_quarter_fast(year: int, quarter: int,
                         max_filings: Optional[int] = None,
                         n_workers: int = 4,
                         output_dir: str = "data/raw") -> pd.DataFrame:
    """
    Parallel quarter collector. Saves parquet after each quarter
    so you don't lose progress if something crashes.
    """
    os.makedirs(output_dir, exist_ok=True)
    suffix = f"first_{max_filings}" if max_filings else "all"
    out_path = f"{output_dir}/insider_{year}_Q{quarter}_{suffix}.parquet"

    if os.path.exists(out_path):
        print(f"  Already exists, loading: {out_path}")
        return pd.read_parquet(out_path)

    print(f"\nFetching index {year} Q{quarter}...")
    index_df = get_form4_index(year, quarter)
    if max_filings:
        index_df = index_df.head(max_filings)
    print(f"  Processing {len(index_df)} filings with {n_workers} workers...")

    rows     = index_df.to_dict("records")
    all_trades = []
    completed  = 0

    with ThreadPoolExecutor(max_workers=n_workers) as executor:
        futures = {executor.submit(parse_form4_fast, row): row for row in rows}
        for future in as_completed(futures):
            trades = future.result()
            if trades:
                all_trades.extend(trades)
            completed += 1
            if completed % 500 == 0:
                print(f"  {completed}/{len(rows)} filings, {len(all_trades)} trades...")

    df = pd.DataFrame(all_trades) if all_trades else pd.DataFrame()
    if not df.empty:
        df.to_parquet(out_path, index=False)
        print(f"  Saved {len(df)} trades to {out_path}")
    return df



# In[ ]:


def aggregate_to_insider_filing_day(df: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate multiple P/S transactions by the same insider and firm
    using the public filing date. This creates the intermediate layer:
    firm × filing_date x insider.
    """
    # First filter to only P and S — ignore grants, tax withholdings etc.
    ps = df[df["txn_code"].isin(["P", "S"])].copy()

    ps["txn_date"] = pd.to_datetime(ps["txn_date"], errors="coerce")
    ps["date_filed"] = pd.to_datetime(ps["date_filed"], errors="coerce")
    ps["filing_month"] = ps["date_filed"].dt.to_period("M").astype(str)
    
    # Sign shares: purchases positive, sales negative
    ps["signed_shares"] = ps.apply(
        lambda r: r["shares"] if r["txn_code"] == "P" else -r["shares"], axis=1
    )
    ps["signed_value"] = ps.apply(
        lambda r: r["trade_value"] if r["txn_code"] == "P" else -r["trade_value"],
        axis=1
    )

    ps["buy_value"] = ps.apply(lambda r: r["trade_value"] if r["txn_code"] == "P" else 0, axis=1)
    ps["sell_value"] = ps.apply(lambda r: r["trade_value"] if r["txn_code"] == "S" else 0, axis=1)
    ps["buy_shares"] = ps.apply(lambda r: r["shares"] if r["txn_code"] == "P" else 0, axis=1)
    ps["sell_shares"] = ps.apply(lambda r: r["shares"] if r["txn_code"] == "S" else 0, axis=1)

    agg = ps.groupby(["cik", "ticker", "date_filed", "owner_cik", "owner_name", "is_officer", "is_director"]).agg(
        n_transactions   = ("txn_code",        "count"),   # how many trades this insider-day
        net_shares       = ("signed_shares",   "sum"),     # net buy/sell in shares
        net_value        = ("signed_value",    "sum"),     # net buy/sell in dollars
        avg_price        = ("price",           "mean"),    # avg execution price
        shares_after     = ("shares_after",    "last"),    # final ownership
        pct_owned_traded = ("pct_owned_traded","max"),     # largest single trade fraction
        is_10b51_doc     = ("is_10b51_doc",    "max"),     # any trade under 10b5-1
        officer_title    = ("officer_title",   "last"),    # descriptive metadata for this insider-day
        buy_value        = ("buy_value", "sum"),
        sell_value       = ("sell_value", "sum"),
        buy_shares       = ("buy_shares", "sum"),
        sell_shares      = ("sell_shares", "sum"),
        first_txn_date=("txn_date", "min"),
        last_txn_date=("txn_date", "max")
    ).reset_index()

    # Net direction: +1 net buyer, -1 net seller, 0 mixed
    agg["trade_direction"] = agg["net_shares"].apply(
        lambda x: 1 if x > 0 else (-1 if x < 0 else 0)
    )

    return agg


# In[ ]:


#trades_df = collect_quarter_fast(2023, 1, max_filings=200, n_workers=4)
#insider_filing_df = aggregate_to_insider_filing_day(trades_df)
#print(f"Raw P/S transactions:       {len(trades_df[trades_df['txn_code'].isin(['P','S'])])}")
#print(f"Insider-filing-day observations:   {len(insider_filing_df)}")
#print(f"\nSample:")
#print(insider_filing_df[["ticker","date_filed","owner_cik","owner_name","officer_title","is_officer","net_shares","net_value","n_transactions","trade_direction"]].head(10))


# In[ ]:


def aggregate_to_firm_month(insider_filing_df: pd.DataFrame) -> pd.DataFrame:
    """
    Roll up firm x filing_date x insider observations into firm x filing_month.
    This is the regression-level panel required by the proposal.
    """
    df = insider_filing_df.copy()

    df["date_filed"] = pd.to_datetime(df["date_filed"], errors="coerce")
    df["filing_month"] = df["date_filed"].dt.to_period("M").astype(str)

    firm_month = df.groupby(["cik", "ticker", "filing_month"]).agg(
        n_insider_days=("owner_cik", "count"),
        n_unique_insiders=("owner_cik", "nunique"),
        n_transactions=("n_transactions", "sum"),

        net_shares=("net_shares", "sum"),
        net_value=("net_value", "sum"),
        gross_buy_value=("buy_value", "sum"),
        gross_sell_value=("sell_value", "sum"),
        gross_buy_shares=("buy_shares", "sum"),
        gross_sell_shares=("sell_shares", "sum"),

        n_officer_insider_days=("is_officer", "sum"),
        n_director_insider_days=("is_director", "sum"),
        any_10b51=("is_10b51_doc", "max"),

        first_filing_date=("date_filed", "min"),
        last_filing_date=("date_filed", "max"),
    ).reset_index()

    firm_month["trade_direction"] = firm_month["net_value"].apply(
        lambda x: 1 if x > 0 else (-1 if x < 0 else 0)
    )

    firm_month["coordination_dummy"] = (firm_month["n_unique_insiders"] >= 2).astype(int)

    return firm_month


# In[ ]:


#firm_month_df = aggregate_to_firm_month(insider_filing_df)

#print(f"Firm-month observations: {len(firm_month_df)}")
#print(firm_month_df.head(10))


# In[ ]:


#ps_df = trades_df[trades_df["txn_code"].isin(["P", "S"])].copy()
#ps_df.to_csv("example_trades.csv", index=False)


# In[ ]:


#insider_filing_df.to_csv("example_insider_filing_day.csv", index=False)
#firm_month_df.to_csv("example_firm_month.csv", index=False)



# Run full data collection
if __name__ == "__main__":
    import os
    import time
    os.makedirs("data/raw", exist_ok=True)
    for year in range(2010, 2026):
        for quarter in range(1, 5):
            print(f"Collecting {year} Q{quarter}...")
            try:
                collect_quarter_fast(year, quarter, n_workers=8, output_dir="data/raw")
                time.sleep(10)
            except Exception as e:
                print(f"Error {year} Q{quarter}: {e}")
                time.sleep(60)
