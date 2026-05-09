res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'crsp' LIMIT 20")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'crsp' AND table_name IN ('msf', 'msenames', 'ccmxpf_linktable')")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'comp' AND table_name IN ('funda', 'company')")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'tfn' LIMIT 20")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'insidertrading' LIMIT 20")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT schema_name FROM information_schema.schemata")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'tr_insiders'")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT * FROM tr_insiders.table1 LIMIT 5")
data <- dbFetch(res)
print(data)
names(data)
insider_raw <- dbGetQuery(wrds, "
SELECT trandate, secid, ticker, cusip6, personid, owner,
rolecode1, rolecode2, trancode_ar, acqdisp_ar,
shares_adj, tprice_adj, sharesheld_adj, optionsell
FROM tr_insiders.table1
WHERE trandate >= '2010-01-01'
AND trandate <= '2025-12-31'
AND trancode_ar IN ('P', 'S')
AND cleanse = 'Y'
AND acqdisp_ar = 'D'
")
nrow(insider_raw)
head(insider_raw)
insider_raw <- dbGetQuery(wrds, "
SELECT trandate, secid, ticker, cusip6, personid, owner,
rolecode1, rolecode2, trancode_ar, acqdisp_ar,
shares_adj, tprice_adj, sharesheld_adj, optionsell
FROM tr_insiders.table1
WHERE trandate >= '2010-01-01'
AND trandate <= '2025-12-31'
AND trancode_ar IN ('P', 'S')
AND cleanse = 'Y'
")
nrow(insider_raw)
head(insider_raw)
res <- dbSendQuery(wrds, "SELECT trancode_ar, cleanse, acqdisp_ar, COUNT(*) as n FROM tr_insiders.table1 GROUP BY trancode_ar, cleanse, acqdisp_ar LIMIT 20")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT DISTINCT trancode_ar FROM tr_insiders.table1 ORDER BY trancode_ar LIMIT 30")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT DISTINCT trancode_ar FROM tr_insiders.table1 WHERE trancode_ar LIKE '%P%' OR trancode_ar LIKE '%S%' ORDER BY trancode_ar")
dbFetch(res)
res <- dbSendQuery(wrds, "
SELECT COUNT(*) as n
FROM tr_insiders.table1
WHERE trandate >= '2010-01-01'
AND trandate <= '2025-12-31'
AND trancode_ar IN ('P', 'S')
AND cleanse = 'A'
")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT table_name FROM information_schema.tables WHERE table_schema = 'wrdssec_insiders'")
dbFetch(res)
res <- dbSendQuery(wrds, "SELECT COUNT(*) as n FROM wrdssec_insiders.nonderivatives WHERE period_of_report >= '2010-01-01' AND period_of_report <= '2025-12-31'")
res <- dbSendQuery(wrds, "SELECT * FROM wrdssec_insiders.nonderivatives LIMIT 3")
data <- dbFetch(res)
names(data)
res <- dbSendQuery(wrds, "
SELECT COUNT(*) as n
FROM wrdssec_insiders.nonderivatives
WHERE transactiondate >= '2010-01-01'
AND transactiondate <= '2025-12-31'
AND transactioncode IN ('P', 'S')
")
dbFetch(res)
insider_raw <- dbGetQuery(wrds, "
SELECT transactiondate, issuercik, issuertradingsymbol,
transactioncode, transactionacquireddisposedcode,
transactionshares, transactionpricepershare,
sharesownedfollowingtransaction, fdate,
transactionformtype, directorindirectownership
FROM wrdssec_insiders.nonderivatives
WHERE transactiondate >= '2010-01-01'
AND transactiondate <= '2025-12-31'
AND transactioncode IN ('P', 'S')
")
nrow(insider_raw)
write.csv(insider_raw, "~/nordera/data/raw/insider_wrds.csv", row.names=FALSE)
saveRDS(insider_raw, "insider_wrds.rds")
# Summary e check NaN
summary(insider_raw)
colSums(is.na(insider_raw))
# Salva campione 100 righe
sample_100 <- head(insider_raw, 100)
write.csv(sample_100, "insider_sample_100.csv", row.names=FALSE)
getwd()
list.files("/home/mit/nordera/")
list.files(getwd())
insider_clean <- insider_raw[
insider_raw$transactionformtype == "4" &
!is.na(insider_raw$transactionpricepershare) &
insider_raw$transactionpricepershare > 0,
]
nrow(insider_clean)
write.csv(insider_clean, "insider_clean.csv", row.names=FALSE)
# Lista CIK unici dal dataset insider
cik_list <- unique(insider_clean$issuercik)
length(cik_list)
# Converti CIK in formato per SQL
cik_sql <- paste0("('", paste(cik_list, collapse="','"), "')")
# CRSP monthly returns - prima dobbiamo linkare CIK a PERMNO via Compustat
crsp_monthly <- dbGetQuery(wrds, "
SELECT permno, date, ret, prc, shrout, exchcd, siccd
FROM crsp.msf
WHERE date >= '2010-01-01'
AND date <= '2025-12-31'
AND exchcd IN (1, 2, 3)
")
crsp_monthly <- dbGetQuery(wrds, "
SELECT permno, date, ret, prc, shrout, hexcd, hsiccd
FROM crsp.msf
WHERE date >= '2010-01-01'
AND date <= '2025-12-31'
AND hexcd IN (1, 2, 3)
")
nrow(crsp_monthly)
saveRDS(crsp_monthly, "crsp_monthly.rds")
# Link CIK -> PERMNO tramite CCM
ccm_link <- dbGetQuery(wrds, "
SELECT gvkey, lpermno AS permno, linktype, linkprim,
liid, linkdt, linkenddt
FROM crsp.ccmxpf_linktable
WHERE linktype IN ('LU', 'LC')
AND linkprim IN ('P', 'C')
")
nrow(ccm_link)
cik_gvkey <- dbGetQuery(wrds, "
SELECT gvkey, cik
FROM comp.company
WHERE cik IS NOT NULL
")
nrow(cik_gvkey)
# Unisci CIK→GVKEY→PERMNO
link_table <- merge(cik_gvkey, ccm_link, by="gvkey")
# Filtra solo le aziende che hanno fatto insider trading
link_insider <- link_table[link_table$cik %in% cik_list, ]
nrow(link_insider)
length(unique(link_insider$cik))
length(unique(link_insider$permno))
# Unisci CRSP con link table
crsp_linked <- merge(crsp_monthly, link_insider[, c("cik", "permno", "linkdt", "linkenddt")],
by="permno")
# Filtra per date valide del link
crsp_linked <- crsp_linked[
(is.na(crsp_linked$linkdt) | crsp_linked$date >= crsp_linked$linkdt) &
(is.na(crsp_linked$linkenddt) | crsp_linked$date <= crsp_linked$linkenddt), ]
nrow(crsp_linked)
saveRDS(crsp_linked, "crsp_linked.rds")
# Compustat - variabili fondamentali
# Prendiamo solo le aziende che ci interessano
gvkey_list <- unique(link_insider$gvkey)
gvkey_sql <- paste0("('", paste(gvkey_list, collapse="','"), "')")
compustat <- dbGetQuery(wrds, paste0("
SELECT gvkey, datadate, fyear, fqtr,
atq, ceqq, ltq, revtq, cogsq, niq, oancfq,
cshoq, prccq, dlcq, dlttq, sstky, prstkq
FROM comp.fundq
WHERE gvkey IN ", gvkey_sql, "
AND datadate >= '2009-01-01'
AND datadate <= '2025-12-31'
AND indfmt = 'INDL'
AND datafmt = 'STD'
AND popsrc = 'D'
AND consol = 'C'
"))
compustat <- dbGetQuery(wrds, paste0("
SELECT gvkey, datadate, fyearq, fqtr,
atq, ceqq, ltq, revtq, cogsq, niq, oancfq,
cshoq, prccq, dlcq, dlttq, sstky, prstkq
FROM comp.fundq
WHERE gvkey IN ", gvkey_sql, "
AND datadate >= '2009-01-01'
AND datadate <= '2025-12-31'
AND indfmt = 'INDL'
AND datafmt = 'STD'
AND popsrc = 'D'
AND consol = 'C'
"))
compustat <- dbGetQuery(wrds, paste0("
SELECT gvkey, datadate, fyearq, fqtr,
atq, ceqq, ltq, revtq, cogsq, niq, oancfy,
cshoq, prccq, dlcq, dlttq, sstky, prstkq
FROM comp.fundq
WHERE gvkey IN ", gvkey_sql, "
AND datadate >= '2009-01-01'
AND datadate <= '2025-12-31'
AND indfmt = 'INDL'
AND datafmt = 'STD'
AND popsrc = 'D'
AND consol = 'C'
"))
compustat <- dbGetQuery(wrds, paste0("
SELECT gvkey, datadate, fyearq, fqtr,
atq, ceqq, ltq, revtq, cogsq, niq, oancfy,
cshoq, prccq, dlcq, dlttq, sstky, pstkq
FROM comp.fundq
WHERE gvkey IN ", gvkey_sql, "
AND datadate >= '2009-01-01'
AND datadate <= '2025-12-31'
AND indfmt = 'INDL'
AND datafmt = 'STD'
AND popsrc = 'D'
AND consol = 'C'
"))
nrow(compustat)
saveRDS(compustat, "compustat.rds")
# Book-to-Market
compustat$booktomarket <- compustat$ceqq / (compustat$cshoq * compustat$prccq)
# Gross Profitability
compustat$grossprofit <- (compustat$revtq - compustat$cogsq) / compustat$atq
# Accruals
compustat$accruals <- (compustat$niq - compustat$oancfy) / compustat$atq
# External Financing
compustat$xfin <- (compustat$sstky - compustat$pstkq + compustat$dlttq + compustat$dlcq) / compustat$atq
# Summary
summary(compustat[, c("booktomarket", "grossprofit", "accruals", "xfin")])
# Funzione winsorize al 1% e 99%
winsorize <- function(x, p=0.01) {
q <- quantile(x, c(p, 1-p), na.rm=TRUE)
x[x < q[1]] <- q[1]
x[x > q[2]] <- q[2]
return(x)
}
# Rimuovi infiniti e poi winsorize
for(col in c("booktomarket", "grossprofit", "accruals", "xfin")) {
compustat[[col]][is.infinite(compustat[[col]])] <- NA
compustat[[col]] <- winsorize(compustat[[col]])
}
summary(compustat[, c("booktomarket", "grossprofit", "accruals", "xfin")])
saveRDS(compustat, "compustat_clean.rds")
# Momentum e Volatility da CRSP daily
crsp_daily <- dbGetQuery(wrds, paste0("
SELECT permno, date, ret
FROM crsp.dsf
WHERE date >= '2009-01-01'
AND date <= '2025-12-31'
AND permno IN (", paste(unique(link_insider$permno), collapse=","), ")
"))
nrow(crsp_daily)
saveRDS(crsp_daily, "crsp_daily.rds")
library(dplyr)
crsp_daily <- crsp_daily %>%
arrange(permno, date) %>%
group_by(permno) %>%
mutate(
# Volatility: std dev ritorni ultimi 252 giorni
volatility = zoo::rollapply(ret, 252, sd, na.rm=TRUE, fill=NA, align="right"),
# Momentum: ritorno cumulativo mesi 2-12 (escludi ultimo mese)
momentum = zoo::rollapply(ret, 252, function(x) prod(1 + x[1:231], na.rm=TRUE) - 1,
fill=NA, align="right")
) %>%
ungroup()
# Momentum e Volatility da CRSP mensile
library(dplyr)
crsp_monthly <- crsp_monthly %>%
arrange(permno, date) %>%
group_by(permno) %>%
mutate(
# Volatility: std dev ritorni ultimi 12 mesi
volatility = zoo::rollapply(ret, 12, sd, na.rm=TRUE, fill=NA, align="right"),
# Momentum: ritorno cumulativo mesi 2-12 (escludi ultimo mese)
momentum = zoo::rollapply(ret, 12, function(x) prod(1 + x[1:11], na.rm=TRUE) - 1,
fill=NA, align="right")
) %>%
ungroup()
nrow(crsp_monthly)
summary(crsp_monthly[, c("ret", "volatility", "momentum")])
for(col in c("ret", "volatility", "momentum")) {
crsp_monthly[[col]][is.infinite(crsp_monthly[[col]])] <- NA
crsp_monthly[[col]] <- winsorize(crsp_monthly[[col]])
}
summary(crsp_monthly[, c("ret", "volatility", "momentum")])
saveRDS(crsp_monthly, "crsp_monthly_clean.rds")
# Aggiungi anno-mese a entrambi per il merge
crsp_monthly$yearmon <- format(crsp_monthly$date, "%Y-%m")
compustat$yearmon <- format(compustat$datadate, "%Y-%m")
# Unisci compustat con link table per avere permno
compustat_linked <- merge(compustat,
link_insider[, c("gvkey", "permno")],
by="gvkey")
# Unisci CRSP con Compustat
panel <- merge(crsp_monthly,
compustat_linked[, c("permno", "yearmon", "booktomarket",
"grossprofit", "accruals", "xfin")],
by=c("permno", "yearmon"),
all.x=TRUE)
nrow(panel)
summary(panel[, c("ret", "volatility", "momentum", "booktomarket", "grossprofit", "accruals", "xfin")])
library(dplyr)
panel <- panel %>%
arrange(permno, yearmon) %>%
group_by(permno) %>%
fill(booktomarket, grossprofit, accruals, xfin, .direction="down") %>%
ungroup()
library(tidyr)
panel <- panel %>%
arrange(permno, yearmon) %>%
group_by(permno) %>%
fill(booktomarket, grossprofit, accruals, xfin, .direction="down") %>%
ungroup()
colSums(is.na(panel[, c("booktomarket", "grossprofit", "accruals", "xfin")]))
saveRDS(panel, "panel_final.rds")
# Aggrega insider trading a livello firma-mese
insider_monthly <- insider_clean %>%
mutate(yearmon = format(as.Date(transactiondate), "%Y-%m")) %>%
group_by(issuercik, yearmon) %>%
summarise(
n_purchases = sum(transactioncode == "P"),
n_sales = sum(transactioncode == "S"),
vol_purchases = sum(transactionshares[transactioncode == "P"], na.rm=TRUE),
vol_sales = sum(transactionshares[transactioncode == "S"], na.rm=TRUE),
net_shares = vol_purchases - vol_sales,
.groups = "drop"
)
nrow(insider_monthly)
# Aggiungi CIK al panel
panel <- merge(panel,
link_insider[, c("permno", "cik")],
by="permno",
all.x=TRUE)
# Unisci con insider monthly
panel_full <- merge(panel,
insider_monthly,
by.x=c("cik", "yearmon"),
by.y=c("issuercik", "yearmon"),
all.x=TRUE)
# Mesi senza insider trading -> 0
panel_full$n_purchases[is.na(panel_full$n_purchases)] <- 0
panel_full$n_sales[is.na(panel_full$n_sales)] <- 0
panel_full$net_shares[is.na(panel_full$net_shares)] <- 0
nrow(panel_full)
summary(panel_full[, c("ret", "volatility", "momentum", "booktomarket",
"grossprofit", "accruals", "xfin",
"n_purchases", "n_sales", "net_shares")])
panel_full$net_shares <- winsorize(panel_full$net_shares)
saveRDS(panel_full, "panel_full.rds")
write.csv(panel_full, "panel_full.csv", row.names=FALSE)
cat("Dataset finale salvato!\n")
cat("Righe:", nrow(panel_full), "\n")
cat("Colonne:", ncol(panel_full), "\n")
names(panel_full)
savehistory("data_pipeline.R")
savehistory("data_pipeline.R")
