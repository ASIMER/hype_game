# Manual lint runner — Hype Raiders quality gate.
#   pwsh tools/lint/lint.ps1            -> lint EVERYTHING (scripts/, autoload/, tools/)
#   pwsh tools/lint/lint.ps1 -File p    -> lint one file (.gd via gdlint, .py via ruff)
#   pwsh tools/lint/lint.ps1 -Format    -> ALSO run gdformat --check (style drift)
# Exit code != 0 when any linter reports problems. The Claude Code PostToolUse hook
# (tools/lint/posttool_lint.py) runs the same checks automatically per edited file.
param(
    [string]$File = "",
    [switch]$Format
)

$gdlint = "C:\Users\illya\miniconda3\Scripts\gdlint.exe"
$gdformat = "C:\Users\illya\miniconda3\Scripts\gdformat.exe"
$ruff = "C:\Users\illya\.local\bin\ruff.exe"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fail = 0

function Invoke-Tool([string]$exe, [string[]]$toolArgs) {
    & $exe @toolArgs
    if ($LASTEXITCODE -ne 0) { $script:fail = 1 }
}

if ($File -ne "") {
    $ext = [System.IO.Path]::GetExtension($File).ToLower()
    if ($ext -eq ".gd") {
        Invoke-Tool $gdlint @($File)
        if ($Format) { Invoke-Tool $gdformat @("--check", $File) }
    }
    elseif ($ext -eq ".py") {
        Invoke-Tool $ruff @("check", "--no-fix", $File)
    }
    exit $fail
}

Write-Host "== gdlint scripts/ autoload/ =="
Invoke-Tool $gdlint @("$root\scripts", "$root\autoload")
if ($Format) {
    Write-Host "== gdformat --check scripts/ autoload/ =="
    Invoke-Tool $gdformat @("--check", "$root\scripts", "$root\autoload")
}
Write-Host "== ruff check tools/ =="
Invoke-Tool $ruff @("check", "--no-fix", "$root\tools")
exit $fail
