# ridenow-sql

Pure-SQL analytics lakehouse over NYC TLC yellow taxi data, run by the DuckDB CLI.

No dbt, no Spark, no Docker. The pipeline is a set of numbered `.sql` files in `sql/`,
executed in order by a PowerShell runner.

## Layout

```
sql/01_raw.sql          raw landing from parquet
sql/02_dimensions.sql   dim_zone, dim_date
sql/03_silver.sql       cleaned trips + quarantine
sql/04_gold.sql         fact_trip
sql/05_assertions.sql   fail-fast data quality gates
sql/06_marts.sql        analytics outputs
sql/07_incremental.sql  incremental load demo

data/raw/             downloaded TLC source files       (gitignored)
data/ridenow.duckdb   the database                      (gitignored)
scripts/download_data.py
bin/duckdb.exe        vendored DuckDB CLI               (gitignored)
run.ps1               the orchestrator
```

A full run over Jan-Mar 2024 takes roughly 65s, dominated by `03_silver.sql` (~47s).

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
.\run.ps1 -Only 20_silver.sql          # one file
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

## Gotchas worth knowing

**`.read` escapes backslashes.** A Windows path passed to the `.read` dot-command
corrupts silently — `...\bad.sql` loses `\b` as a backspace and reports "cannot open".
`run.ps1` converts to forward slashes before every `.read`. The database *argument*
accepts either style; only dot-commands are affected.

**`1/0` does NOT raise in DuckDB — it returns `inf`, exit code 0.** This matters because
`05_assertions.sql` uses `case when count(*) > 0 then 1/0 else 0 end` to abort the
pipeline on a violation, and that idiom silently passes. Nor does integer division help:
`1//0` returns `NULL`, also exit 0. Verified:

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

**`payment_type = 0`** appears on 140,162 January rows and is absent from the TLC data
dictionary (which documents 1-6). An accepted-values check restricted to 1-6 will fail.

**Zone `Borough` values `'Unknown'` and `'N/A'` are literal strings, not NULL**, so
`WHERE Borough IS NOT NULL` filters nothing. `LocationID` 264 and 265 are these sentinel
non-places, and they resolve against the lookup like any real zone.
