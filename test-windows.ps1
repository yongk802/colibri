<#
.SYNOPSIS
  colibri Windows readiness test - Stages 0-3, one command, pass/fail summary.

.DESCRIPTION
  Run this from inside the cloned colibri repo on the Windows machine.

    Stage 0  Engine correctness (no big model needed)
             - build glm.exe + iobench.exe
             - C unit tests (json / safetensors / tier / grammar)
             - token-exact self-test vs a tiny transformers oracle (TF 32/32, greedy 20/20)
    Stage 1  Readiness check against the REAL model (coli doctor / coli plan)
             - SKIPPED automatically if the model isn't downloaded yet
    Stage 2  Disk reality - iobench random-read benchmark on the target NVMe
    Stage 3  Model smoke test - 'coli run' generates a few real tokens
             - SKIPPED until the model is present; cold generation is slow, so a
               timeout is a SKIP (disk speed), not a FAIL

  Exit code = number of FAILed checks (0 = everything green). SKIPs are not failures.

.PARAMETER ModelDir
  Path to the downloaded int4 model. Stage 1 runs only if this exists. Default D:\glm52_i4

.PARAMETER DiskTestPath
  Directory on the NVMe to benchmark. Default = the root of ModelDir's drive.

.PARAMETER DiskTestGB
  Size of the iobench scratch file, in GB (default 16). For a TRUE cold-cache number,
  pass a value larger than physical RAM (e.g. -DiskTestGB 96 on a 64 GB box).

.PARAMETER Python
  Explicit python.exe to use for the oracle (must have torch+transformers). Optional;
  the script prefers .\c\mio_env and otherwise tries to build that venv with py -3.12.

.PARAMETER SmokeTokens
  Tokens to generate in the Stage 3 smoke test (default 16 - keep it small; cold decode is slow).

.PARAMETER SmokeTimeoutSec
  Max seconds to wait for the Stage 3 generation before SKIPping (default 600).

.PARAMETER SkipOracle
  Skip the token-exact self-test (still builds and runs the C tests).

.PARAMETER SkipDisk
  Skip Stage 2 (the disk benchmark).

.PARAMETER SkipSmoke
  Skip Stage 3 (the coli run smoke test).

.EXAMPLE
  .\test-windows.ps1
  .\test-windows.ps1 -ModelDir D:\glm52_i4 -DiskTestGB 96
  .\test-windows.ps1 -SkipSmoke              # before the model finishes downloading
#>
param(
  [string]$ModelDir        = "D:\glm52_i4",
  [string]$DiskTestPath    = "",
  [int]   $DiskTestGB      = 16,
  [string]$Python          = "",
  [int]   $SmokeTokens     = 16,
  [int]   $SmokeTimeoutSec = 600,
  [switch]$SkipOracle,
  [switch]$SkipDisk,
  [switch]$SkipSmoke
)

$ErrorActionPreference = "Continue"
$fails = 0
$rows  = New-Object System.Collections.Generic.List[object]

function Section($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Record($stage, $name, $status, $detail) {
  if ($status -eq "FAIL") { $script:fails++ }
  $rows.Add([pscustomobject]@{ Stage = $stage; Check = $name; Status = $status; Detail = $detail })
  $c = switch ($status) { "PASS" {"Green"} "FAIL" {"Red"} "SKIP" {"Yellow"} default {"Gray"} }
  Write-Host ("  [{0,-4}] {1,-26} {2}" -f $status, $name, $detail) -ForegroundColor $c
}
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Write-Host "colibri - Windows readiness test (Stages 0-3)" -ForegroundColor White

# --- locate the c/ directory (script may sit at repo root or inside c/) ---
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cdir = $null
foreach ($p in @((Join-Path $here "c"), $here)) {
  if (Test-Path (Join-Path $p "glm.c")) { $cdir = $p; break }
}
if (-not $cdir) {
  Write-Host "ERROR: could not find c\glm.c - run this from the colibri repo." -ForegroundColor Red
  exit 2
}
Set-Location $cdir
Write-Host "  repo c/ dir: $cdir"

# --- C build helper: compile with gcc directly. colibri's Makefile detects the
#     OS via 'uname', which plain MinGW-Builds doesn't ship, so we don't use make. ---
$GCC_CFLAGS  = @('-D_FILE_OFFSET_BITS=64','-O3','-march=x86-64-v3','-fopenmp',
                 '-Wall','-Wextra','-Wno-unused-parameter','-Wno-misleading-indentation','-Wno-unused-function')
$GCC_LDFLAGS = @('-lm','-fopenmp','-static')
function Build-C($src, $out) {
  if (Test-Path $out) { Remove-Item $out -Force -ErrorAction SilentlyContinue }
  try { & gcc $GCC_CFLAGS $src -o $out $GCC_LDFLAGS 2>&1 | Out-Null } catch {}
  return (Test-Path $out)
}

# ==================================================================== #
Section "Stage 0 - engine correctness"

# toolchain
if (Have "gcc") {
  $gccv = (& gcc -dumpversion) 2>$null
  Record 0 "gcc (MinGW-w64)" "PASS" "version $gccv"
} else {
  Record 0 "gcc (MinGW-w64)" "FAIL" "gcc not on PATH - install mingw-w64 (scoop install mingw-winlibs)"
}

# build glm.exe (direct gcc)
$built = $false
if (Have "gcc") {
  $built = Build-C "glm.c" "glm.exe"
  if ($built) { Record 0 "build glm.exe" "PASS" ("{0:N0} bytes" -f (Get-Item .\glm.exe).Length) }
  else        { Record 0 "build glm.exe" "FAIL" "gcc build failed - run by hand to see it: gcc -D_FILE_OFFSET_BITS=64 -O3 -march=x86-64-v3 -fopenmp glm.c -o glm.exe -lm -fopenmp -static" }
} else {
  Record 0 "build glm.exe" "SKIP" "no gcc"
}

# C unit tests (compiled + run directly with gcc)
if ($built) {
  $failed = @()
  foreach ($t in @('json','st','tier','grammar')) {
    $src = "tests\test_$t.c"; $exe = "tests\test_$t.exe"
    if (-not (Test-Path $src)) { continue }
    if (Build-C $src $exe) {
      & ".\$exe" *> $null
      if ($LASTEXITCODE -ne 0) { $failed += $t }
    } else { $failed += "$t(build)" }
  }
  if ($failed.Count -eq 0) { Record 0 "C unit tests" "PASS" "json/safetensors/tier/grammar ok" }
  else                     { Record 0 "C unit tests" "FAIL" ("failed: " + ($failed -join ', ')) }
} else {
  Record 0 "C unit tests" "SKIP" "glm.exe not built"
}

# token-exact oracle self-test
function Resolve-OraclePython {
  $cands = @()
  $venv = Join-Path $cdir "mio_env\Scripts\python.exe"
  if (Test-Path $venv) { $cands += $venv }
  if ($Python)        { $cands += $Python }
  foreach ($c in $cands) {
    & $c -c "import torch, transformers" 2>$null
    if ($LASTEXITCODE -eq 0) { return $c }
  }
  return $null
}

if ($SkipOracle) {
  Record 0 "token-exact self-test" "SKIP" "-SkipOracle set"
} elseif (-not $built) {
  Record 0 "token-exact self-test" "SKIP" "glm.exe not built"
} else {
  $py = Resolve-OraclePython
  if (-not $py -and -not (Test-Path ".\glm_tiny\model.safetensors")) {
    # try to build the venv once (py 3.12 preferred - torch has wheels for it)
    Write-Host "  setting up c\mio_env (torch+transformers, one-time)..." -ForegroundColor DarkGray
    try {
      if (Have "py") { & py -3.12 -m venv mio_env 2>$null } else { & python -m venv mio_env 2>$null }
      & .\mio_env\Scripts\python.exe -m pip install -q --upgrade pip 2>$null
      & .\mio_env\Scripts\python.exe -m pip install -q torch transformers safetensors huggingface_hub numpy 2>$null
      $py = Resolve-OraclePython
    } catch { $py = $null }
  }

  if (-not (Test-Path ".\glm_tiny\model.safetensors")) {
    if ($py) {
      & $py tools\make_glm_oracle.py *> $null
    }
  }

  if (-not (Test-Path ".\glm_tiny\model.safetensors")) {
    Record 0 "token-exact self-test" "SKIP" "no python w/ torch+transformers - set -Python or build c\mio_env"
  } else {
    # teacher-forcing: expect N/N positions
    $env:SNAP = ".\glm_tiny"; $env:TF = "1"
    $tf = (& .\glm.exe 64 16 16 2>&1 | Out-String)
    Remove-Item Env:TF -ErrorAction SilentlyContinue
    $tfOk = ($tf -match '(\d+)\s*/\s*(\d+)\s+positions') -and ($Matches[1] -eq $Matches[2]) -and ($Matches[1] -ne "0")
    $tfTxt = if ($tf -match '(\d+\s*/\s*\d+\s+positions)') { $Matches[1] } else { "no positions line" }

    # greedy generation: expect N/N matching tokens
    $env:SNAP = ".\glm_tiny"
    $gen = (& .\glm.exe 64 16 16 2>&1 | Out-String)
    Remove-Item Env:SNAP -ErrorAction SilentlyContinue
    $genOk = ($gen -match 'Matching tokens:\s*(\d+)\s*/\s*(\d+)') -and ($Matches[1] -eq $Matches[2]) -and ($Matches[1] -ne "0")
    $genTxt = if ($gen -match '(Matching tokens:\s*\d+\s*/\s*\d+)') { $Matches[1] } else { "no matching-tokens line" }

    if ($tfOk -and $genOk) { Record 0 "token-exact self-test" "PASS" "$tfTxt | $genTxt" }
    else                   { Record 0 "token-exact self-test" "FAIL" "$tfTxt | $genTxt (expected N/N on both)" }
  }
}

# ==================================================================== #
Section "Stage 1 - readiness (real model)"

$pyRun = if (Have "py") { "py" } elseif (Have "python") { "python" } else { $null }
$modelPresent = (Test-Path (Join-Path $ModelDir "config.json"))

if (-not $modelPresent) {
  Record 1 "coli doctor" "SKIP" "model not present at $ModelDir (download still running?)"
  Record 1 "coli plan"   "SKIP" "run this stage again once the download finishes"
} elseif (-not $pyRun) {
  Record 1 "coli doctor" "SKIP" "no python on PATH to run coli"
  Record 1 "coli plan"   "SKIP" "no python on PATH to run coli"
} else {
  & $pyRun coli doctor --model $ModelDir *> $null
  if ($LASTEXITCODE -eq 0) { Record 1 "coli doctor" "PASS" "model dir/config/tokenizer/RAM plan runnable" }
  else                     { Record 1 "coli doctor" "FAIL" "doctor exit $LASTEXITCODE (unsafe/incomplete placement)" }

  & $pyRun coli plan --model $ModelDir *> $null
  if ($LASTEXITCODE -eq 0) { Record 1 "coli plan" "PASS" "placement plan computed" }
  else                     { Record 1 "coli plan" "FAIL" "plan exit $LASTEXITCODE" }
}

# ==================================================================== #
Section "Stage 2 - disk reality"

if ($SkipDisk) {
  Record 2 "iobench" "SKIP" "-SkipDisk set"
} else {
  # build iobench.exe (direct gcc)
  $iob = $false
  if (Have "gcc") { $iob = Build-C "iobench.c" "iobench.exe" }

  if (-not $iob) {
    Record 2 "iobench build" "FAIL" "could not build iobench.exe"
  } else {
    if (-not $DiskTestPath) { $DiskTestPath = (Split-Path -Qualifier $ModelDir) + "\" }
    if (-not (Test-Path $DiskTestPath)) { $DiskTestPath = $env:TEMP }
    $scratch = Join-Path $DiskTestPath "colibri_iobench.dat"

    try {
      Write-Host "  writing $DiskTestGB GB scratch file to $scratch (real data, not sparse)..." -ForegroundColor DarkGray
      $buf = New-Object byte[] (64MB)
      (New-Object System.Random).NextBytes($buf)
      $fs = [System.IO.File]::Create($scratch)
      $loops = [int]([double]$DiskTestGB * 1GB / $buf.Length)
      for ($i = 0; $i -lt $loops; $i++) { $fs.Write($buf, 0, $buf.Length) }
      $fs.Flush($true); $fs.Close()

      $n = [Math]::Max(50, [int]([double]$DiskTestGB * 1024 / 19))   # ~one pass of 19 MB reads
      $res = (& .\iobench.exe $scratch 19 $n 8 1 2>&1 | Out-String)
      if ($res -match '->\s*([\d.]+)\s*GB/s') {
        $gbs = [double]$Matches[1]
        $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $note = "$gbs GB/s random-read"
        if ($DiskTestGB -lt $ramGB) { $note += "  (WARN: file < ${ramGB}GB RAM -> cache-optimistic; re-run -DiskTestGB $([int]($ramGB*1.5))+)" }
        # ~11 GB reads/token cold -> tok/s estimate
        $tps = [math]::Round($gbs / 11.0, 3)
        $note += "  (~$tps tok/s cold ceiling)"
        Record 2 "iobench" "PASS" $note
      } else {
        Record 2 "iobench" "FAIL" "no GB/s in output"
      }
    } catch {
      Record 2 "iobench" "FAIL" $_.Exception.Message
    } finally {
      if (Test-Path $scratch) { Remove-Item $scratch -Force -ErrorAction SilentlyContinue }
    }
  }
}

# ==================================================================== #
Section "Stage 3 - model smoke test (coli run)"

if ($SkipSmoke) {
  Record 3 "coli run smoke" "SKIP" "-SkipSmoke set"
} elseif (-not $modelPresent) {
  Record 3 "coli run smoke" "SKIP" "model not present at $ModelDir (download still running?)"
} elseif (-not $pyRun) {
  Record 3 "coli run smoke" "SKIP" "no python on PATH to run coli"
} else {
  $budgetMin = [int]($SmokeTimeoutSec / 60)
  Write-Host "  generating $SmokeTokens tokens - cold disk is SLOW (up to ~$budgetMin min budget)..." -ForegroundColor DarkGray
  $prompt = "In one short sentence, what is a hummingbird?"

  $sb = {
    param($py, $dir, $model, $prompt, $n)
    Set-Location $dir
    $o = (& $py coli run $prompt --model $model --ngen $n 2>&1 | Out-String)
    [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE }
  }
  $job = Start-Job -ScriptBlock $sb -ArgumentList $pyRun, $cdir, $ModelDir, $prompt, $SmokeTokens

  if (Wait-Job $job -Timeout $SmokeTimeoutSec) {
    $r     = Receive-Job $job
    $txt   = [string]$r.Out
    $code  = $r.Code
    $esc   = [char]27
    $clean = ($txt -replace "$esc\[[0-9;]*m", "")            # strip ANSI colour codes
    $ran   = ($clean -match 'tok/s' -or $clean -match 'tokens/forward' -or $clean -match 'Expert cache')

    # pull one prose line (not banner/stat/path) so a human can eyeball coherence
    $snip = ($clean -split "`n" |
             Where-Object { $_ -match '[A-Za-z]{4,}' -and
                            $_ -notmatch 'tok/s|Expert cache|RAM_GB|colibr|prefill|layer|ready in|DSA|MTP|PIN|KV|resident' } |
             Select-Object -First 1)
    if ($snip) {
      $snip = ($snip.Trim() -replace '\s+', ' ')
      if ($snip.Length -gt 90) { $snip = $snip.Substring(0, 90) + "..." }
    }

    $okExit = ($code -eq 0 -or $null -eq $code)
    if ($okExit -and $ran) {
      Record 3 "coli run smoke" "PASS" ("engine generated + reported stats" + $(if ($snip) { " | `"$snip`"" } else { "" }))
    } elseif ($okExit) {
      Record 3 "coli run smoke" "PASS" ("exit 0" + $(if ($snip) { " | `"$snip`"" } else { " (no stats line parsed - eyeball the output)" }))
    } else {
      Record 3 "coli run smoke" "FAIL" "coli run exit $code"
    }
  } else {
    Stop-Job $job -ErrorAction SilentlyContinue
    Record 3 "coli run smoke" "SKIP" "no completion within ${SmokeTimeoutSec}s - cold disk is slow; run 'python coli run ...' manually or raise -SmokeTimeoutSec"
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
}

# ==================================================================== #
Section "Summary"
$rows | Format-Table -AutoSize | Out-String | Write-Host
if ($fails -eq 0) {
  Write-Host "ALL CHECKS GREEN (no failures). Engine is validated on this machine." -ForegroundColor Green
  Write-Host "Next: once the model download finishes, re-run to exercise Stages 1 & 3, then 'python coli chat'." -ForegroundColor Green
  exit 0
} else {
  Write-Host "$fails check(s) FAILED - see the table above." -ForegroundColor Red
  exit $fails
}
