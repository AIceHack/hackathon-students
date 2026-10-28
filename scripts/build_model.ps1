param(
    [string]$Database = 'marketplace',
    [string]$User = 'hack'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$buildId = [guid]::NewGuid().ToString('N')
$reportDir = Join-Path ([System.IO.Path]::GetTempPath()) 'hackathon-model-build'
$reportFile = Join-Path $reportDir ("build-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $buildId)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$copiedFiles = New-Object 'System.Collections.Generic.List[string]'
$localFiles = New-Object 'System.Collections.Generic.List[string]'
$failure = $null

New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
[System.IO.File]::WriteAllText($reportFile, '', $utf8)

function Write-Log {
    param([string]$Message)
    Write-Host $Message
    [System.IO.File]::AppendAllText($reportFile, $Message + [Environment]::NewLine, $utf8)
}

function Invoke-Docker {
    param([string[]]$Arguments, [string]$Step)
    Write-Log ("==> {0}" -f $Step)
    # PowerShell 5.1 can turn native stderr into non-terminating errors.
    # Capture both streams while using the actual native process exit code.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& docker @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    foreach ($line in $lines) { Write-Log ([string]$line) }
    if ($code -ne 0) {
        throw ("{0} failed with exit code {1}. See output above." -f $Step, $code)
    }
}

function Assert-TransactionSafe {
    param([string]$Path, [string]$Label, [bool]$RequireSingleSelect = $false)

    # Strip strings, quoted identifiers, dollar-quoted bodies and comments
    # before inspecting top-level statements. A BEGIN in DO $$...$$ is valid.
    $sql = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $clean = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $sql.Length) {
        $ch = $sql[$i]
        $next = if ($i + 1 -lt $sql.Length) { $sql[$i + 1] } else { [char]0 }
        if ($ch -eq '-' -and $next -eq '-') {
            $i += 2
            while ($i -lt $sql.Length -and $sql[$i] -ne "`n") { $i++ }
            [void]$clean.Append(' ')
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $depth = 1
            $i += 2
            while ($i -lt $sql.Length -and $depth -gt 0) {
                $a = $sql[$i]
                $b = if ($i + 1 -lt $sql.Length) { $sql[$i + 1] } else { [char]0 }
                if ($a -eq '/' -and $b -eq '*') { $depth++; $i += 2; continue }
                if ($a -eq '*' -and $b -eq '/') { $depth--; $i += 2; continue }
                $i++
            }
            if ($depth -ne 0) { throw "Unterminated block comment in $Label" }
            [void]$clean.Append(' ')
            continue
        }
        if ($ch -eq "'" -or $ch -eq '"') {
            $quote = $ch
            $escapeString = $quote -eq "'" -and $i -gt 0 -and
                ($sql[$i - 1] -eq 'E' -or $sql[$i - 1] -eq 'e') -and
                ($i -eq 1 -or $sql[$i - 2] -notmatch '[A-Za-z0-9_$]')
            $i++
            $closed = $false
            while ($i -lt $sql.Length) {
                if ($escapeString -and $sql[$i] -eq [char]92) { $i += 2; continue }
                if ($sql[$i] -eq $quote) {
                    if ($i + 1 -lt $sql.Length -and $sql[$i + 1] -eq $quote) { $i += 2; continue }
                    $i++
                    $closed = $true
                    break
                }
                $i++
            }
            if (-not $closed) { throw "Unterminated quoted string or identifier in $Label" }
            [void]$clean.Append(' ')
            continue
        }
        if ($ch -eq '$') {
            $match = [regex]::Match($sql.Substring($i), '^\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$')
            if ($match.Success) {
                $tag = $match.Value
                $end = $sql.IndexOf($tag, $i + $tag.Length, [System.StringComparison]::Ordinal)
                if ($end -lt 0) { throw "Unterminated dollar quote in $Label" }
                $i = $end + $tag.Length
                [void]$clean.Append(' ')
                continue
            }
        }
        if ($ch -eq [char]92) { throw "psql backslash commands are not allowed in $Label" }
        [void]$clean.Append($ch)
        $i++
    }

    $statements = @($clean.ToString().Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($statement in $statements) {
        if ($statement -match '^\s*(BEGIN|COMMIT|END|ROLLBACK|ABORT|SAVEPOINT|RELEASE)\b' -or
            $statement -match '^\s*(START|PREPARE)\s+TRANSACTION\b') {
            throw "Top-level transaction control is not allowed in $Label"
        }
    }
    if ($RequireSingleSelect -and ($statements.Count -ne 1 -or $statements[0] -notmatch '^\s*(SELECT|WITH)\b')) {
        throw "Official answer must contain exactly one SELECT or WITH statement: $Label"
    }
}

$files = @(
    'model/00_schema.sql',
    'model/10_dimensions.sql',
    'model/20_orders_items.sql',
    'model/30_payments_reviews.sql',
    'model/40_marts.sql',
    'tests/10_integrity.sql',
    'tests/20_reconciliation.sql',
    'tests/30_marts.sql',
    'queries/01_monthly.sql',
    'queries/02_top_sellers.sql',
    'queries/03_average_check.sql',
    'queries/04_retention.sql',
    'queries/05_categories.sql',
    'tests/40_official_answers.sql'
)

$answerViews = @(
    @{ File = 'queries/01_monthly.sql'; View = 'answer_01_monthly' },
    @{ File = 'queries/02_top_sellers.sql'; View = 'answer_02_top_sellers' },
    @{ File = 'queries/03_average_check.sql'; View = 'answer_03_average_check' },
    @{ File = 'queries/04_retention.sql'; View = 'answer_04_retention' },
    @{ File = 'queries/05_categories.sql'; View = 'answer_05_categories' }
)

Push-Location $root
try {
    Write-Log ("Model build started: {0}" -f (Get-Date -Format o))
    Write-Log ("Project: {0}; database: {1}; report: {2}" -f $root, $Database, $reportFile)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker command not found.' }
    $missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { throw ("Required SQL files are missing:`n  " + ($missing -join "`n  ")) }

    foreach ($file in $files) {
        Assert-TransactionSafe -Path (Join-Path $root $file) -Label $file -RequireSingleSelect ($file -like 'queries/*')
    }

    Invoke-Docker -Arguments @('compose', 'version') -Step 'Check Docker Compose'
    Invoke-Docker -Arguments @('compose', 'exec', '-T', 'postgres', 'pg_isready', '-U', $User, '-d', $Database) -Step 'Check PostgreSQL container'
    $preflight = @'
DO $$
DECLARE name text;
BEGIN
  FOREACH name IN ARRAY ARRAY['orders','order_items','order_payments','order_reviews','products','sellers','customers','product_category_translation'] LOOP
    IF to_regclass(format('raw.%I', name)) IS NULL THEN
      RAISE EXCEPTION 'required table raw.% is missing', name;
    END IF;
  END LOOP;
END;
$$;
'@
    Invoke-Docker -Arguments @('compose', 'exec', '-T', 'postgres', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', $User, '-d', $Database, '-c', $preflight) -Step 'Check database and raw tables'

    $psqlArgs = @('compose', 'exec', '-T', 'postgres', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-U', $User, '-d', $Database)
    $index = 0
    foreach ($file in $files) {
        if ($file -eq 'tests/40_official_answers.sql') {
            # Wrap the exact official SQL as temporary views so the final test
            # checks the actual outputs, not a second implementation of them.
            foreach ($answer in $answerViews) {
                $localWrapper = Join-Path $reportDir ("{0}_{1}.sql" -f $buildId, $answer.View)
                $query = [System.IO.File]::ReadAllText((Join-Path $root $answer.File), [System.Text.Encoding]::UTF8).Trim().TrimEnd(';')
                [System.IO.File]::WriteAllText($localWrapper, ("CREATE TEMP VIEW {0} AS`n{1};`n" -f $answer.View, $query), $utf8)
                $localFiles.Add($localWrapper)
                $targetWrapper = '/tmp/modelbuild_{0}_{1}.sql' -f $buildId, $answer.View
                Invoke-Docker -Arguments @('compose', 'cp', $localWrapper, ("postgres:{0}" -f $targetWrapper)) -Step ("Prepare check for {0}" -f $answer.File)
                $copiedFiles.Add($targetWrapper)
                $psqlArgs += @('-c', ("\echo CHECK OUTPUT {0}" -f $answer.File), '-f', $targetWrapper)
            }
        }
        $index++
        $source = Join-Path $root $file
        $target = '/tmp/modelbuild_{0}_{1:D2}_{2}' -f $buildId, $index, (Split-Path -Leaf $file)
        Invoke-Docker -Arguments @('compose', 'cp', $source, ("postgres:{0}" -f $target)) -Step ("Copy {0}" -f $file)
        $copiedFiles.Add($target)
        $psqlArgs += @('-c', ("\echo FILE {0}" -f $file), '-f', $target)
    }
    $psqlArgs += @('-c', 'SELECT pg_temp.assert_raw_unchanged();')
    Invoke-Docker -Arguments $psqlArgs -Step 'Execute model, checks and answers in one transaction'
    Write-Log 'SQL transaction committed successfully.'
}
catch {
    $failure = $_.Exception.Message
    Write-Log ("BUILD FAILED: {0}" -f $failure)
}
finally {
    foreach ($localFile in $localFiles) {
        try { [System.IO.File]::Delete($localFile) }
        catch {
            Write-Log ("LOCAL CLEANUP FAILED: {0}" -f $_.Exception.Message)
            if (-not $failure) { $failure = $_.Exception.Message }
        }
    }
    if ($copiedFiles.Count -gt 0) {
        try {
            $cleanupArgs = @('compose', 'exec', '-T', 'postgres', 'rm', '-f', '--') + $copiedFiles.ToArray()
            Invoke-Docker -Arguments $cleanupArgs -Step 'Remove temporary container SQL files'
        }
        catch {
            Write-Log ("CLEANUP FAILED: {0}" -f $_.Exception.Message)
            if (-not $failure) { $failure = $_.Exception.Message }
        }
    }
    Pop-Location
}

if ($failure) {
    Write-Log ("Build failed. Report: {0}" -f $reportFile)
    exit 1
}
Write-Log ("Build passed. Report: {0}" -f $reportFile)
exit 0
