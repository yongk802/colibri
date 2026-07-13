<#
.SYNOPSIS
  Download the full pre-converted GLM-5.2 int4 model for colibri (~379 GB). Resumable.

.DESCRIPTION
  Run this in a SEPARATE PowerShell window on the Windows machine so it downloads in
  parallel while you run test-windows.ps1. It is fully resumable - if it drops, just
  run it again and it continues from where it stopped.

  Default source: mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp
    A COMPLETE int4 model that ALREADY ships the working int8 MTP head, so speculative
    decoding engages out of the box (avoids the int4-MTP problem described in issue #8).

  Alternative (canonical, but verify the MTP head): -Repo jlnsrk/GLM-5.2-colibri-int4

.PARAMETER ModelDir
  Destination directory on your fast NVMe. Default D:\glm52_i4

.PARAMETER Repo
  Hugging Face repo id to pull. Default mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp

.EXAMPLE
  .\download-model.ps1
  .\download-model.ps1 -ModelDir E:\models\glm52_i4
#>
param(
  [string]$ModelDir = "D:\glm52_i4",
  [string]$Repo     = "mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp"
)

$ErrorActionPreference = "Stop"
Write-Host "colibri - model download" -ForegroundColor White
Write-Host "  repo   : $Repo"
Write-Host "  dest   : $ModelDir"

# --- ensure a python + huggingface_hub CLI ---
$py = $null
foreach ($c in @("py","python")) { if (Get-Command $c -ErrorAction SilentlyContinue) { $py = $c; break } }
if (-not $py) { Write-Host "ERROR: no python on PATH. Install Python 3.12." -ForegroundColor Red; exit 2 }

# huggingface-cli present? if not, install the hub + fast transfer into the user site
$hasCli = [bool](Get-Command "huggingface-cli" -ErrorAction SilentlyContinue)
if (-not $hasCli) {
  Write-Host "  installing huggingface_hub[cli] + hf_transfer..." -ForegroundColor DarkGray
  & $py -m pip install -q --user "huggingface_hub[cli]" hf_transfer
}

# --- free-space guard (~379 GB + headroom) ---
$drive = (Split-Path -Qualifier $ModelDir)
try {
  $free = (Get-PSDrive ($drive.TrimEnd(':'))).Free
  $freeGB = [math]::Round($free / 1GB)
  Write-Host "  free on $drive $freeGB GB"
  if ($freeGB -lt 400) {
    Write-Host "  WARNING: < 400 GB free. The model is ~379 GB; you want headroom. Continue? (Ctrl+C to abort)" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
} catch { Write-Host "  (could not read free space for $drive - continuing)" -ForegroundColor DarkGray }

New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

# fast parallel transfer; resumable. HF_HUB_ENABLE_HF_TRANSFER speeds large files.
$env:HF_HUB_ENABLE_HF_TRANSFER = "1"

Write-Host ""
Write-Host "  starting download (this takes HOURS - leave it running; it resumes if interrupted)..." -ForegroundColor Cyan
Write-Host ""

# Prefer the modern 'hf download'; fall back to legacy 'huggingface-cli download'.
$useHf = [bool](Get-Command "hf" -ErrorAction SilentlyContinue)
if ($useHf) {
  & hf download $Repo --local-dir $ModelDir
} else {
  & huggingface-cli download $Repo --local-dir $ModelDir
}

if ($LASTEXITCODE -eq 0) {
  Write-Host ""
  Write-Host "DONE. Model at $ModelDir" -ForegroundColor Green
  Write-Host "Verify with:  python coli doctor --model $ModelDir" -ForegroundColor Green
  Write-Host "Then chat  :  `$env:COLI_MODEL='$ModelDir'; python coli chat" -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "Download exited $LASTEXITCODE. It is resumable - re-run this script to continue." -ForegroundColor Yellow
  exit $LASTEXITCODE
}
