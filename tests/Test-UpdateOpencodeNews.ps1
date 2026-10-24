#!/usr/bin/env pwsh
# Tests for news/update-opencode-news.ps1, run offline: the models.dev data
# comes from a fixture file (-ApiUrl), the page from a copy of the real one.
# Run with:
#   pwsh -NoProfile -File tests/Test-UpdateOpencodeNews.ps1

$ErrorActionPreference = 'Continue'

$testsDir  = $PSScriptRoot
$scriptDir = Split-Path $testsDir -Parent
$updater   = Join-Path $scriptDir 'news/update-opencode-news.ps1'
$page      = Join-Path $scriptDir 'news/opencode/opencode-go-models-2026-10.html'

# Find a pwsh that actually runs (as Test-CodeIt.ps1 does)
function Test-PwshWorks([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    try { $null = & $exe -NoProfile -Command 'exit 0' 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
$pwshExe = @((Get-Command pwsh -EA Silent).Source, "$HOME/.local/bin/pwsh", "$HOME/.dotnet/tools/pwsh") |
    Where-Object { Test-PwshWorks $_ } | Select-Object -First 1
if (-not $pwshExe) { throw "No working pwsh found" }

$sep = [IO.Path]::PathSeparator
$origPath = $env:PATH

function Invoke-Updater([string[]]$updaterArgs, [string]$path = $origPath) {
    $env:PATH = $path
    try {
        $out = & $pwshExe -NoProfile -File $updater @updaterArgs 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    } finally { $env:PATH = $origPath }
}

$script:pass = 0
$script:fail = 0
function Assert([string]$desc, [bool]$ok) {
    if ($ok) { "  ok: $desc";   $script:pass++ }
    else     { "  FAIL: $desc"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "code-it-news-tests-$PID"
$null = New-Item -ItemType Directory -Force -Path $tmp

# ---------------------------------------------------------------------------
"1. The fixture: models.dev-shaped JSON, offline"
$fixture = @'
{
  "opencode": {
    "id": "opencode",
    "name": "OpenCode",
    "models": {
      "gpt-9-zeta": {
        "id": "gpt-9-zeta", "name": "GPT-9 Zeta", "reasoning": true, "tool_call": true,
        "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
        "cost": { "input": 1.25, "output": 9.5, "cache_read": 0.125 }
      },
      "glm-9.9-flash": {
        "id": "glm-9.9-flash", "name": "GLM-9.9-Flash", "reasoning": true, "tool_call": true,
        "modalities": { "input": ["text"], "output": ["text"] },
        "cost": { "input": 0, "output": 0, "cache_read": 0 }
      },
      "claude-haiku-9-9": {
        "id": "claude-haiku-9-9", "name": "Claude Haiku 9.9", "reasoning": false, "tool_call": true,
        "modalities": { "input": ["text"], "output": ["text"] },
        "cost": { "input": 0.07, "output": 0.5, "cache_read": 0.01, "cache_write": 0.8 }
      },
      "claude-fable-5": {
        "id": "claude-fable-5", "name": "Claude Fable 5", "reasoning": true, "tool_call": true,
        "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
        "cost": { "input": 9.0, "output": 45.0, "cache_read": 0.9, "cache_write": 11.25 }
      }
    }
  }
}
'@
$fixtureFile = Join-Path $tmp 'models.json'
Set-Content -Path $fixtureFile -Value $fixture
Assert "the fixture has four models" ((ConvertFrom-Json $fixture).opencode.models.PSObject.Properties.Name.Count -eq 4)

# ---------------------------------------------------------------------------
"2. The updater refreshes the model list and the prices from the data source"
$testPage = Join-Path $tmp 'page.html'
Copy-Item $page $testPage
$r = Invoke-Updater @('-Page', $testPage, '-ApiUrl', $fixtureFile)
Assert "updater exit code 0" ($r.code -eq 0)
Assert "updater reports the model count" ($r.out.Contains('models from the opencode provider'))

$newHtml = Get-Content $testPage -Raw
$dataLine = [regex]::Match($newHtml, 'const DATA=\[.*\];').Value
Assert "the DATA line is replaced with the fixture's models" ($dataLine.Contains('"id": "gpt-9-zeta"'))
Assert "the page's old models are gone" (-not $dataLine.Contains('"id": "kimi-k3"'))
Assert "input prices are written as the page spells them" ($dataLine.Contains('"inp": 1.25, "out": 9.5, "cr": 0.125, "cw": null'))
Assert "whole-number prices keep the page's .0 style" ($dataLine.Contains('"inp": 0.0, "out": 0.0'))
Assert "cache-write prices are written when the source has them" ($dataLine.Contains('"cw": 0.8'))
Assert "free models are flagged free" ($dataLine -match '"id": "glm-9\.9-flash"[^}]*"free": true')
Assert "capabilities map to the page's features" ($dataLine.Contains('"feats": ["Reasoning", "Image", "PDF", "Tools", "Text"]'))
Assert "a model already on the page keeps its manual enabled flag" ($dataLine -match '"id": "claude-fable-5"[^}]*"en": false')
Assert "new models start enabled" ($dataLine -match '"id": "gpt-9-zeta"[^}]*"en": true')
Assert "the model list is ordered by name" ($dataLine.IndexOf('Claude Fable 5') -lt $dataLine.IndexOf('Claude Haiku 9.9') -and `
                                             $dataLine.IndexOf('Claude Haiku 9.9') -lt $dataLine.IndexOf('GLM-9.9-Flash'))
Assert "the snapshot date is this month" ($newHtml.Contains("snapshot $((Get-Date -Format 'MMMM yyyy'))"))
Assert "the page still cites its source" ($newHtml.Contains('href="https://models.dev'))
Assert "the rest of the page is untouched" ($newHtml.Contains('<h1 class="fw-bold mb-2">OpenCode Models</h1>') -and $newHtml.TrimEnd().EndsWith('</html>'))

# ---------------------------------------------------------------------------
"3. -WhatIf changes nothing"
$before = Get-Content $testPage -Raw
$r = Invoke-Updater @('-Page', $testPage, '-ApiUrl', $fixtureFile, '-WhatIf')
Assert "-WhatIf exit code 0" ($r.code -eq 0)
Assert "-WhatIf says what it would do" ($r.out.Contains('What if:'))
Assert "-WhatIf leaves the page alone" ((Get-Content $testPage -Raw) -eq $before)

# ---------------------------------------------------------------------------
"4. Help and errors"
$help = @(& $pwshExe -NoProfile -Command "Get-Help '$updater' -Full | Out-String -Width 200") -join "`n"
Assert "the script has full help" ($help.Contains('SYNOPSIS') -and $help.Contains('DESCRIPTION'))
Assert "help links to the source of the data" ($help.Contains('https://models.dev/api.json'))
$r = Invoke-Updater @('-Page', $testPage, '-ApiUrl', $fixtureFile, '-Provider', 'nosuch-provider')
Assert "an unknown provider fails readably" ($r.code -ne 0 -and $r.out.Contains("Provider 'nosuch-provider' not found"))
$r = Invoke-Updater @('-Page', (Join-Path $tmp 'no-such-page.html'), '-ApiUrl', $fixtureFile)
Assert "a missing page fails readably" ($r.code -ne 0 -and $r.out.Contains('Page not found'))

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -EA Silent
""
"Results: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }
