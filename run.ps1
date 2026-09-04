<#
.SYNOPSIS
    Runs the numbered SQL pipeline in sql/ against a DuckDB database.

.DESCRIPTION
    Discovers sql/*.sql, orders them numerically by filename prefix, and executes each
    with `duckdb <db> -c ".read <file>"`. Stops at the first failure.

.PARAMETER Database
    Path to the DuckDB database file. Defaults to data/ridenow.duckdb.

.PARAMETER Only
    Run a single file instead of the whole pipeline. Matches on filename, so
    `-Only 01` and `-Only 01_raw.sql` both work provided the match is unambiguous.

.EXAMPLE
    .\run.ps1
    .\run.ps1 -Database data\scratch.duckdb
    .\run.ps1 -Only 20_silver.sql
#>
[CmdletBinding()]
param(
    [string]$Database = "data/ridenow.duckdb",
    [string]$Only
)

# Anchor everything to the script's own directory so the runner behaves identically
# whether it is invoked from the project root or from somewhere else entirely.
$root   = $PSScriptRoot
$sqlDir = Join-Path $root "sql"

# --- locate the duckdb executable -------------------------------------------------
# Prefer the vendored copy in bin/, so the pipeline runs with a known version even on
# a machine where duckdb is not on PATH. Fall back to PATH if bin/ is absent.
$duckdb = Join-Path $root "bin\duckdb.exe"
if (-not (Test-Path $duckdb)) {
    $onPath = Get-Command duckdb -ErrorAction SilentlyContinue
    if ($null -eq $onPath) {
        Write-Error "duckdb not found in $root\bin and not on PATH."
        exit 127
    }
    $duckdb = $onPath.Source
}

if (-not (Test-Path $sqlDir)) {
    Write-Error "No sql/ directory at $sqlDir"
    exit 2
}

# Resolve the database path relative to the project root when it is not absolute, so
# the default `data/ridenow.duckdb` means the same thing from any working directory.
if (-not [System.IO.Path]::IsPathRooted($Database)) {
    $Database = Join-Path $root $Database
}
$dbDir = Split-Path -Parent $Database
if ($dbDir -and -not (Test-Path $dbDir)) {
    New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
}

# --- discover and order the pipeline ----------------------------------------------
# Sort numerically on the leading digits, NOT lexically: a plain string sort puts
# "10_marts.sql" before "2_silver.sql", which would run the pipeline out of order.
# Files with no numeric prefix sort last, then alphabetically, so they cannot silently
# jump the queue.
$files = Get-ChildItem -Path $sqlDir -Filter *.sql -File | Sort-Object `
    @{ Expression = { if ($_.Name -match '^(\d+)') { [int]$Matches[1] } else { [int]::MaxValue } } },
    @{ Expression = { $_.Name } }

if ($Only) {
    $files = @($files | Where-Object { $_.Name -like "*$Only*" })
    if ($files.Count -eq 0) {
        Write-Error "-Only '$Only' matched no file in $sqlDir"
        exit 2
    }
    if ($files.Count -gt 1) {
        Write-Error "-Only '$Only' is ambiguous, matched: $($files.Name -join ', ')"
        exit 2
    }
}

if ($files.Count -eq 0) {
    Write-Warning "No .sql files found in $sqlDir - nothing to do."
    exit 0
}

Write-Output "database : $Database"
Write-Output "duckdb   : $duckdb"
Write-Output "steps    : $($files.Count)"
Write-Output ("-" * 64)

$failed = $null
$overall = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($f in $files) {
    # DuckDB's `.read` dot-command treats backslashes as escape sequences, so a Windows
    # path silently corrupts: "...\bad.sql" loses the \b as a backspace character and
    # the file is reported as not found. Forward slashes are accepted on Windows and
    # avoid the escaping entirely. This is not cosmetic - it is the difference between
    # the runner working and every step failing with a confusing "cannot open" error.
    $sqlPath = $f.FullName.Replace('\', '/')

    Write-Output "RUN  $($f.Name)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Call the native executable directly. Its stdout/stderr stream straight to the
    # console rather than being captured, which keeps DuckDB's own error text and
    # result tables visible as they happen.
    & $duckdb $Database -c ".read $sqlPath"

    # --- exit-code handling: the core of the design -------------------------------
    # $LASTEXITCODE holds the exit code of the most recent NATIVE process, and it must
    # be captured immediately - any later command overwrites it. Do NOT use $? here:
    # for native executables in PowerShell 5.1 it reflects whether the call itself was
    # dispatched, not what the process returned, so a failing query can leave $? true.
    #
    # DuckDB returns 0 on success and non-zero when a statement errors, and `.read`
    # aborts at the first failing statement rather than continuing through the file.
    # Verified: a file whose second statement references a missing table exits 1 and
    # never executes the third statement.
    #
    # That is what lets a hand-written assertion file halt the whole pipeline: raise an
    # error in SQL and this loop stops here rather than building marts on bad data.
    $code = $LASTEXITCODE
    $sw.Stop()

    if ($code -ne 0) {
        Write-Output ("-" * 64)
        Write-Error "FAILED  $($f.Name)  (exit $code) after $([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
        $failed = $f.Name
        break   # stop immediately; later steps would run against a broken state
    }

    Write-Output "OK   $($f.Name)  $([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
    Write-Output ""
}

$overall.Stop()
Write-Output ("-" * 64)

if ($failed) {
    Write-Output "PIPELINE FAILED at $failed after $([math]::Round($overall.Elapsed.TotalSeconds, 2))s"
    # Propagate failure to the caller so CI, a scheduler, or a wrapping script can see
    # it. Without this the script would exit 0 and a broken run would look successful.
    exit 1
}

Write-Output "PIPELINE OK  $($files.Count) step(s) in $([math]::Round($overall.Elapsed.TotalSeconds, 2))s"
exit 0
