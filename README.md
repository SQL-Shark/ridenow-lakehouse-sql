# ridenow-sql

Pure-SQL analytics lakehouse over NYC TLC yellow taxi data, run by the DuckDB CLI.

No dbt, no Spark, no Docker. The pipeline is a set of numbered `.sql` files in `sql/`,
executed in order by a PowerShell runner.

## Layout

```
sql/01_raw.sql          raw landing from parquet (glob over all months)
sql/02_dimensions.sql   dim_zone, dim_date, dim_payment_type, dim_vendor
sql/03_silver.sql       cleaned + deduplicated trips, plus quarantine
sql/04_gold.sql         fact_trip (star schema, surrogate FKs)
sql/05_assertions.sql   fail-fast data quality gates
sql/06_marts.sql        v_daily_metrics, v_top_od_pairs,
                        v_tip_rate_by_borough_hour, v_payment_share, v_vendor_share
sql/07_incremental.sql  delete-then-insert reload of one source_month

data/raw/             downloaded TLC source files       (gitignored)
data/ridenow.duckdb   the database                      (gitignored)
scripts/download_data.py
bin/duckdb.exe        vendored DuckDB CLI               (gitignored)
run.ps1               the orchestrator
```

Over Jan-Apr 2024 a full run takes roughly 55s, dominated by `03_silver.sql` (~32s):

| stage | rows |
|---|---|
| `raw_yellow_trips` | 13,069,067 |
| `silver_trips` / `fact_trip` | 12,859,098 |
| removed by cleaning rules | 209,969 |
| `quarantine_trips` | 13 |

## Setup

DuckDB CLI **v1.5.5 (Variegata)** is vendored in `bin/`, so nothing needs installing
system-wide. `run.ps1` uses it automatically. To use `duckdb` directly in a shell:

```powershell
$env:Path = "C:\Users\yovch\ridenow-sql\bin;$env:Path"
```

The downloader needs a venv (its only dependency is `requests`):

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
```

## Get the data

```powershell
.venv\Scripts\python scripts\download_data.py --months 2024-01
.venv\Scripts\python scripts\download_data.py --months 2024-01 2024-02 2024-03
```

Downloads yellow taxi parquet plus the taxi zone lookup CSV into `data/raw/`. Existing
files are skipped and logged rather than re-fetched. January is ~50 MB, 2,964,624 rows.

## Run the pipeline

```powershell
.\run.ps1                              # everything in sql/, in order
.\run.ps1 -Only 03_silver              # one file (substring match, must be unambiguous)
.\run.ps1 -Database data\scratch.duckdb
```

Files are ordered **numerically by filename prefix**, not lexically, so `2_x.sql` runs
before `10_y.sql`. The runner stops at the first failure, names the file that broke, and
exits non-zero — which is what lets a hand-written assertion file abort the run before
downstream models are built on bad data.

## Connecting to the database

DuckDB is embedded: there are **no credentials**. The file path is the whole connection.

```powershell
.\bin\duckdb.exe data\ridenow.duckdb              # interactive
.\bin\duckdb.exe data\ridenow.duckdb -c "select 1;"
.\bin\duckdb.exe -readonly data\ridenow.duckdb    # read-only
.\bin\duckdb.exe :memory: -c "select count(*) from read_parquet('data/raw/yellow_tripdata_2024-01.parquet');"
```

## Design notes

The decisions worth explaining, and why they went the way they did.

**Quarantine, not drop.** Rows whose foreign keys cannot be resolved go to
`quarantine_trips` with a reason column rather than being discarded, so the volume of
bad references is measurable instead of invisible. A lookup that goes stale would
otherwise look like a quiet fall in demand. Quarantine is built from `raw_yellow_trips`,
not from the cleaned set, so it measures the *source* regardless of what the cleaning
rules would also have removed.

**Referential integrity is enforced by joins, not asserted afterwards.** `03_silver.sql`
inner-joins `dim_zone` twice and `dim_date` once, so a row that cannot resolve every key
never reaches silver. The FK gates in `05_assertions.sql` are belt-and-braces: they only
fire if the fact was built from something other than silver, or a dimension was later
rebuilt narrower.

**`dim_date` is joined for a real reason.** A handful of source rows carry junk pickup
timestamps — 2002, 2008 and 2009 dates inside the 2024 files — which pass every cleaning
rule, since a 2002 trip can still have a positive fare and a plausible duration. Without
the join they reach the fact with no matching calendar row, and `v_daily_metrics`
inner-joins `dim_date`, so they would vanish from daily reporting while still inflating
`fact_trip`. Thirteen such rows land in quarantine as
`pickup_date_outside_calendar`, and fact now reconciles exactly against the daily mart.

**`source_month` is file lineage, not a calendar.** It is extracted from the filename, not
derived from the row timestamp, because the January file legitimately contains trips that
started on 31 December. Deriving it from the data would scatter one input file across
partitions and make the incremental delete-then-insert remove rows it should not.

**Tip rate is gated on payment type.** Only credit-card trips have tips captured by the
meter, so `v_tip_rate_by_borough_hour` filters on `dim_payment_type.records_tip`.
Averaging tips across cash trips would roughly halve every rate for a reason that has
nothing to do with tipping behaviour. The view also reports incidence and
tip-when-tipped separately, and suppresses groups under 100 trips — Staten Island
produced a 146% rate on two trips before that threshold.

**Dimensions seed the full code domain, not just observed values.** `dim_vendor` carries
code 7 although it never appears in Jan-Apr 2024. Seeding only what you have seen means
the referential gate fails on perfectly valid data the first month a new vendor appears.

**`payment_type = 0` is undocumented but real** — 4.7% of trips. It is seeded as
`Flex Fare` and the accepted-values gate allows 0-6, not the 1-6 the TLC dictionary
documents. A check restricted to the documented range would fail on the real feed.

## What I'd do next

- **Factor out the duplicated cleaning logic.** `03_silver.sql` and `07_incremental.sql`
  carry the same cleaning rules, surrogate key and referential joins. If they drift, an
  incrementally loaded month silently differs from a fully rebuilt one — the failure this
  design is most exposed to. A macro or a generated file would remove the duplication.
- **Record why each row was dropped.** 209,969 raw rows are removed between raw and
  silver, but only referential failures are attributable by reason. A per-rule rejection
  count would make the funnel fully auditable.
- **Parameterise the incremental month properly.** `07_incremental.sql` hardcodes
  `set variable target_month = '2024-04'`; passing it on the command line would make the
  script reusable without editing.
- **Add freshness and volume checks** — assert the newest `source_month` is within an
  expected window, and that a month's row count is within a tolerance of its neighbours,
  which catches a truncated download that every current gate would pass.

## Gotchas worth knowing

**`.read` escapes backslashes.** A Windows path passed to the `.read` dot-command
corrupts silently — `...\bad.sql` loses `\b` as a backspace and reports "cannot open".
`run.ps1` converts to forward slashes before every `.read`. The database *argument*
accepts either style; only dot-commands are affected.

**`1/0` does NOT raise in DuckDB — it returns `inf`, exit code 0.** This is why the gates
in `05_assertions.sql` use `error('...')` rather than the usual divide-by-zero trick: a
`case when count(*) > 0 then 1/0 end` gate evaluates, returns `inf`, and exits 0, so it
looks like it passed. Integer division does not help either — `1//0` returns `NULL`, also
exit 0. Verified:

| expression | result | exit |
|---|---|---|
| `1/0` | `inf` | 0 |
| `1//0` | `NULL` | 0 |
| `error('msg')` | raises | **1** |
| `cast(1/0 as integer)` | raises | **1** |

Use `error('assert_x failed')`, which aborts *and* prints a readable message.

**One writer, or many readers — never both.** An interactive `duckdb` shell left open on
the database will make `run.ps1` fail with `The process cannot access the file because it
is being used by another process`. The error names the blocking PID. `.quit` first.

**`payment_type = 0`** appears on 137,912 January fact rows (4.72%) and is absent from
the TLC data dictionary, which documents only 1-6. An accepted-values check restricted to
1-6 would fail on real data; `dim_payment_type` seeds it as `Flex Fare` and
`assert_payment_type` accepts `0..6`, which is the right call.

Note that `dim_payment_type.records_tip` is doing real analytical work, not decoration:
only credit-card trips have tips captured by the meter, so
`v_tip_rate_by_borough_hour` filters on it. Averaging tips across cash trips would halve
every rate for a reason that has nothing to do with tipping behaviour.

**Zone `Borough` values `'Unknown'` and `'N/A'` are literal strings, not NULL**, so
`WHERE Borough IS NOT NULL` filters nothing. `LocationID` 264 and 265 are these sentinel
non-places, and they resolve against the lookup like any real zone.
