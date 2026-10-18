#! /usr/bin/env pwsh

<#
.SYNOPSIS
    Sets the defaults Code-It uses when you give it no options: which agent to run,
    which model each agent uses, and which toolchain image to prefer.

.DESCRIPTION
    With no parameters it asks. With any of -agent/-model/-toolchain it sets exactly
    those and asks nothing. Everything is saved in <saveDir>/defaults (default
    ~/.config/code-it/defaults), which Code-It reads; models are also written into
    each agent's own configuration under the save dir (from AGENT_MODEL_FILE in
    agents/<name>/config), so the agent picks them up on every run.

    The model catalog offered by the picker is best effort and always incomplete,
    and any model string is accepted as free text. The bundled list lib/models.txt is
    used until -refreshModelsfetches a current catalog from https://models.dev, the
    registry OpenCode itself reads, saving it as <saveDir>/model-catalog.txt.

.PARAMETER agent
    Set the default agent, as Code-It -agent would take it. `none` clears it.

.PARAMETER model
    Set agents' default models in their own configs, one AGENT=MODEL per array
    element, e.g.
        -model 'opencode=opencode-go/glm-5.3' -model 'claude=opus'
    The picker prefers opencode-go, the provider OpenCode itself runs on,
    wherever it serves the model. An empty MODEL, as in -model 'opencode=',
    clears it. Any model string is accepted: the catalog of known models is best
    effort and always incomplete.

.PARAMETER toolchain
    Set the default toolchain list, as Code-It -toolchain would take it. Overrides
    Code-It's remembered-image heuristic; an explicit -toolchain still wins.

.PARAMETER show
    Print the current defaults and exit.

.PARAMETER refreshModels
    Refresh <saveDir>/model-catalog.txt, the model list offered by the interactive
    picker, from https://models.dev/api.json.

.PARAMETER saveDir
    Where the defaults and agent state live. Default: ~/.config/code-it

.PARAMETER dryRun
    Show what would be written; change nothing.

.EXAMPLE
    .\Code-It-Defaults.ps1
    Interactive: asks for the default agent, each agent's default model, and the
    default toolchain.

.EXAMPLE
    .\Code-It-Defaults.ps1 -agent claude -toolchain node,bun
    Sets those defaults and asks nothing.

.EXAMPLE
    .\Code-It-Defaults.ps1 -model 'claude=opus'
    Sets Claude Code's default model in <saveDir>/.claude/settings.json.

.EXAMPLE
    .\Code-It-Defaults.ps1 -show
    Prints the saved defaults.

.NOTES
    Interactive questions read answers from the console, so they can be scripted
    by piping lines to pwsh; a blank answer keeps the current value.

    Code-It (or Code-It.ps1) uses the saved defaults whenever its own options do
    not say: -agent/-claude/-opencode wins over the saved agent, and -toolchain and
    -image win over the saved toolchain, which in turn beats the remembered-image
    heuristic.
#>

# PositionalBinding is off so that each named parameter must be named.
[CmdletBinding(PositionalBinding = $false)]
param (
    [Alias('a')]
    [string]$agent          = "",
    [string[]]$model        = @(),
    [Alias('t')]
    [string]$toolchain      = "",
    [switch]$show           = $false,
    [switch]$refreshModels  = $false,
    [string]$saveDir        = "$HOME/.config/code-it",
    [Alias('h')]
    [switch]$help           = $false,
    [switch]$dryRun         = $false
)

if ($help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

. "$PSScriptRoot/lib/CodeItCommon.ps1"

$agentsDir   = Join-Path $PSScriptRoot 'agents'
$toolchainsDir = Join-Path $PSScriptRoot 'toolchains'
$defaultsFile = Join-Path $saveDir 'defaults'
$catalogBundled = Join-Path $PSScriptRoot (Join-Path 'lib' 'models.txt')
$catalogCache   = Join-Path $saveDir 'model-catalog.txt'
$modelsUrl      = 'https://models.dev/api.json'
# Claude Code's model aliases, offered by the picker alongside full model names
$claudeAliases  = @('opus', 'sonnet', 'haiku', 'opusplan')
# The provider OpenCode itself runs on: where it serves a model, the picker
# offers it as opencode-go/MODEL instead of the provider the catalog names
$opencodeGoProvider = 'opencode-go'
$defaultsHeader = '# code-it defaults, written by Code-It-Defaults, read by Code-It.'

function Get-Default([string]$key) {
    $v = Get-CodeItDefault $defaultsFile $key
    if ($null -eq $v) { return "" } else { return "$v" }
}

# Set-DefaultLine KEY VALUE: set KEY=VALUE in the defaults file, preserving the rest
# of the file; empty VALUE removes the line. -dryRun prints what would change.
function Set-DefaultLine([string]$key, [string]$value) {
    if ($dryRun) {
        if ($value) { Write-Host "    would set in ${defaultsFile}: $key=$value" }
        else        { Write-Host "    would remove from ${defaultsFile}: $key" }
        return
    }
    # The save dir may not exist yet on a machine that has not run Code-It
    New-Item -ItemType Directory -Force -Path $saveDir | Out-Null
    $lines = @()
    if (Test-Path -Path $defaultsFile -PathType Leaf) { $lines = @(Get-Content $defaultsFile) }
    $out = @()
    $found = $false
    foreach ($l in $lines) {
        if ($l -match "^$([regex]::Escape($key))=") {
            $found = $true
            if ($value) { $out += "$key=$value" }
        } else {
            $out += $l
        }
    }
    if (-not $found -and $value) {
        if (-not $out) { $out = @($defaultsHeader) }
        $out += "$key=$value"
    }
    if ($out.Count) {
        [IO.File]::WriteAllLines($defaultsFile, $out, [System.Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -Path $defaultsFile -PathType Leaf) {
        [IO.File]::WriteAllText($defaultsFile, "")
    }
}

# Get-JsonKey FILE KEY: the string value of the top-level KEY, or ""
function Get-JsonKey([string]$file, [string]$key) {
    if (-not (Test-Path -Path $file -PathType Leaf)) { return "" }
    try { $obj = Get-Content $file -Raw | ConvertFrom-Json } catch { return "" }
    $prop = $obj.PSObject.Properties[$key]
    if ($prop) { return "$($prop.Value)" }
    return ""
}

# Set-JsonKey FILE KEY VALUE: set the top-level KEY of the JSON object in FILE,
# creating FILE if absent and otherwise preserving the rest.
function Set-JsonKey([string]$file, [string]$key, [string]$value) {
    if (Test-Path -Path $file -PathType Leaf) {
        try { $obj = Get-Content $file -Raw | ConvertFrom-Json }
        catch {
            Write-Warning "Cannot edit $file (not JSON this script can read). Add `"$key`": `"$value`" to it by hand."
            return $false
        }
    } else {
        $obj = New-Object System.Management.Automation.PSObject
    }
    if ($obj.PSObject.Properties[$key]) {
        $obj.($key) = $value
    } else {
        $obj | Add-Member -NotePropertyName $key -NotePropertyValue $value
    }
    $json = $obj | ConvertTo-Json -Depth 20
    $dir = Split-Path $file -Parent
    if ($dir -and -not (Test-Path -Path $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllText($file, "$json`n", [System.Text.UTF8Encoding]::new($false))
    return $true
}

# Remove-JsonKey FILE KEY: remove the top-level KEY from the JSON object in FILE.
function Remove-JsonKey([string]$file, [string]$key) {
    if (-not (Test-Path -Path $file -PathType Leaf)) { return $true }
    try { $obj = Get-Content $file -Raw | ConvertFrom-Json }
    catch {
        Write-Warning "Cannot edit $file (not JSON this script can read). Remove `"$key`" from it by hand."
        return $false
    }
    if (-not $obj.PSObject.Properties[$key]) { return $true }
    $obj.PSObject.Properties.Remove($key)
    $json = $obj | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($file, "$json`n", [System.Text.UTF8Encoding]::new($false))
    return $true
}

# AgentSavePath AGENT REL: where AGENT's REL lives under the save dir, including
# any AGENT_SAVE_SUBDIR
function AgentSavePath([string]$agentName, [string]$rel) {
    $subdir = Get-CodeItAgentConfig $agentsDir $agentName 'AGENT_SAVE_SUBDIR'
    if ($subdir) {
        return (Join-Path $saveDir (Join-Path $subdir $rel))
    }
    return (Join-Path $saveDir $rel)
}

# Set-Model AGENT MODEL: write MODEL into the agent's own config, the
# AGENT_MODEL_FILE of its definition, and record it as model.AGENT in the defaults
# file. Empty MODEL clears both.
function Set-Model([string]$agentName, [string]$modelValue) {
    if (-not (Test-CodeItAgentExists $agentsDir $agentName)) {
        Write-Warning "Unknown agent '$agentName'. Known agents: $((Get-CodeItListAgents $agentsDir) -join ' ')"
        return $false
    }
    $spec = Get-CodeItAgentConfig $agentsDir $agentName 'AGENT_MODEL_FILE'
    if (-not $spec -or -not $spec.Contains(':')) {
        Write-Warning "agents/$agentName/config has no AGENT_MODEL_FILE, so there is no known way to set its default model."
        return $false
    }
    $path = $spec.Substring(0, $spec.IndexOf(':'))
    $key  = $spec.Substring($spec.IndexOf(':') + 1)
    $target = AgentSavePath $agentName $path
    if (-not $modelValue) {
        if ($dryRun) {
            Write-Host "    would clear $agentName's model in $target"
        } else {
            if ((Test-Path -Path $target -PathType Leaf) -and -not (Remove-JsonKey $target $key)) { return $false }
            Write-Host "    Cleared $agentName's model in $target"
        }
        Set-DefaultLine "model.$agentName" ""
        return $true
    }
    if ($modelValue -match '[\r\n\t]') {
        Write-Warning "'$modelValue' is not a model name I can save."
        return $false
    }
    if ($dryRun) {
        Write-Host "    would set $agentName's model in ${target}: `"$key`": `"$modelValue`""
    } else {
        if (-not (Set-JsonKey $target $key $modelValue)) { return $false }
        Write-Host "    Set $agentName's model in ${target}: $modelValue"
    }
    Set-DefaultLine "model.$agentName" $modelValue
    return $true
}

# Get-ModelCatalog: the model catalog to offer: the refreshed cache when present,
# else the bundled list. Returns "provider/model" strings.
function Get-ModelCatalog {
    $file = if (Test-Path -Path $catalogCache -PathType Leaf) { $catalogCache } else { $catalogBundled }
    if (-not (Test-Path -Path $file -PathType Leaf)) { return @() }
    return @(Get-Content $file | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
}

# Update-ModelCatalog: refresh the cache from models.dev, the registry OpenCode
# itself reads.
function Update-ModelCatalog {
    if ($dryRun) {
        Write-Host "    would fetch $modelsUrl into $catalogCache"
        return $true
    }
    try {
        $data = Invoke-RestMethod -Uri $modelsUrl -TimeoutSec 30 -ErrorAction Stop
    } catch {
        Write-Warning "Could not fetch the model catalog from $modelsUrl."
        return $false
    }
    $entries = @()
    foreach ($provider in $data.PSObject.Properties) {
        $models = $provider.Value.models
        if ($null -eq $models) { continue }
        foreach ($m in $models.PSObject.Properties) { $entries += "$($provider.Name)/$($m.Name)" }
    }
    if (-not $entries) {
        Write-Warning "The model catalog at $modelsUrl listed no models."
        return $false
    }
    $header = "# model catalog refreshed from $modelsUrl on $([DateTime]::Today.ToString('yyyy-MM-dd'))"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $catalogCache -Parent)
    [IO.File]::WriteAllLines($catalogCache, (@($header) + @($entries | Sort-Object -Unique)), [System.Text.UTF8Encoding]::new($false))
    Write-Host "    Refreshed $catalogCache ($($entries.Count) models)"
    return $true
}

function Show-Defaults {
    if (-not (Test-Path -Path $defaultsFile -PathType Leaf)) {
        Write-Host "No defaults saved yet in $defaultsFile."
        Write-Host "Run Code-It-Defaults with no parameters to set them."
        return
    }
    Write-Host "Saved defaults in ${defaultsFile}:"
    $savedAgent = Get-Default 'default-agent'
    if ($savedAgent) { Write-Host ("  {0,-22} {1}" -f 'default agent:', $savedAgent) }
    $savedToolchain = Get-Default 'default-toolchain'
    if ($savedToolchain) { Write-Host ("  {0,-22} {1}" -f 'default toolchain:', $savedToolchain) }
    foreach ($a in (Get-CodeItListAgents $agentsDir)) {
        $m = Get-Default "model.$a"
        $mFile = ""
        $spec = Get-CodeItAgentConfig $agentsDir $a 'AGENT_MODEL_FILE'
        if ($spec -and $spec.Contains(':')) {
            $mFile = AgentSavePath $a ($spec.Substring(0, $spec.IndexOf(':')))
            $live = Get-JsonKey $mFile ($spec.Substring($spec.IndexOf(':') + 1))
            # The agent's own config is the source of truth for its model
            if ($live) { $m = "$live" }
        }
        if ($m) {
            Write-Host ("  {0,-22} {1}" -f "model for ${a}:", $m)
            if ($mFile) { Write-Host "    (set in $mFile)" }
        }
    }
}

# Read-Choice LABEL DEFAULT DETECTED CURRENT ITEMS: print a numbered list and read a
# choice from the console, echoing the answer ('none' clears, blank keeps DEFAULT)
function Read-Choice([string]$label, [string]$default, [string]$detected, [string]$current, [string[]]$items) {
    Write-Host "$label (detected marked *):"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $flag = ''
        if ($items[$i] -eq $current) { $flag = ' (current)' }
        if ($detected -contains $items[$i]) { $flag = " *$flag" }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $items[$i], $flag)
    }
    $shown = if ($default) { $default } else { 'none' }
    $answer = Read-Host "Choose $label [$shown, or none]"
    if (-not $answer) { $answer = $default }
    return $answer
}

function Invoke-Interactive {
    $agentsAvailable = Get-CodeItListAgents $agentsDir
    $detectedAgents = @($agentsAvailable | Where-Object { Test-CodeItAgentDetected $agentsDir $_ })

    Write-Host "Setting code-it defaults, saved in ${defaultsFile}. A blank answer keeps the"
    Write-Host "current value; code-it uses them whenever its own options do not say."

    # 1. Default agent
    $savedAgent = Get-Default 'default-agent'
    $preselect = $savedAgent
    if (-not $preselect) { $preselect = if ($detectedAgents.Count) { $detectedAgents[0] } else { '' } }
    if (-not $preselect) { $preselect = $script:CodeItDefaultAgents[0] }
    $answer = Read-Choice 'default agent' $preselect ($detectedAgents -join ' ') $savedAgent $agentsAvailable
    if (-not $answer -or $answer -eq 'none') {
        $chosen = $null
        Set-DefaultLine 'default-agent' ""
    } elseif ($agentsAvailable -contains $answer) {
        $chosen = $answer
        Set-DefaultLine 'default-agent' $answer
        Write-Host "    Default agent: $answer"
    } elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $agentsAvailable.Count) {
        $chosen = $agentsAvailable[[int]$answer - 1]
        Set-DefaultLine 'default-agent' $chosen
        Write-Host "    Default agent: $chosen"
    } else {
        Write-Host "    Unknown agent '$answer'; keeping what is saved."
        $chosen = $null
    }
    if ($chosen -and $chosen -ne $savedAgent) {
        Write-Host "    Note: each agent keeps its own state, and its own login, under the"
        Write-Host "    save dir, so switching the default agent switches that state too."
        Write-Host "    opencode-v2 keeps its login in the database under its own directory,"
        Write-Host "    so its first run there can ask you to log in again."
    }

    # 2. Default model, for each agent that has a known mechanism
    foreach ($a in $agentsAvailable) {
        $spec = Get-CodeItAgentConfig $agentsDir $a 'AGENT_MODEL_FILE'
        if (-not $spec -or -not $spec.Contains(':')) {
            Write-Host ""
            Write-Host "No known way to set $a's default model (no AGENT_MODEL_FILE in its definition); skipping."
            continue
        }
        $path = $spec.Substring(0, $spec.IndexOf(':'))
        $target = AgentSavePath $a $path
        $live = Get-JsonKey $target ($spec.Substring($spec.IndexOf(':') + 1))
        Write-Host ""
        Write-Host "Default model for $a [current: $(if ($live) { $live } else { 'none' })]. The catalog below is best"
        Write-Host "effort and always incomplete: any model string is accepted."
        $models = @()
        $claudeStyle = $path.StartsWith('.claude/')
        if ($claudeStyle) { $models += $claudeAliases }
        $catalog = @(Get-ModelCatalog)
        # opencode-go is the provider OpenCode itself runs on: where it serves a
        # model, offer it as opencode-go/MODEL rather than the catalog's provider
        $goModels = @()
        if (-not $claudeStyle) {
            $goPrefix = "$script:opencodeGoProvider/"
            $goModels = @($catalog | Where-Object { $_.StartsWith($goPrefix) } |
                ForEach-Object { $_.Substring($goPrefix.Length) })
        }
        foreach ($entry in $catalog) {
            if ($claudeStyle) {
                if ($entry -like 'anthropic/*') { $models += $entry.Substring('anthropic/'.Length) }
            } else {
                $bare = if ($entry -like '*/*') { $entry.Substring($entry.IndexOf('/') + 1) } else { $entry }
                if ($goModels -contains $bare) { $entry = "$script:opencodeGoProvider/$bare" }
                # The preference maps two catalog lines to one model; offer it once
                if ($models -contains $entry) { continue }
                $models += $entry
            }
        }
        for ($i = 0; $i -lt $models.Count; $i++) {
            $flag = if ($models[$i] -eq $live) { ' (current)' } else { '' }
            Write-Host ("  {0}) {1}{2}" -f ($i + 1), $models[$i], $flag)
        }
        $answer = Read-Host "Choose model for $a [$(if ($live) { $live } else { 'none' }), 'none' clears]"
        if (-not $answer) { continue }
        if ($answer -eq 'none') {
            $null = Set-Model $a ""
        } elseif ($answer -match '^\d+$') {
            if ([int]$answer -ge 1 -and [int]$answer -le $models.Count) {
                $null = Set-Model $a $models[[int]$answer - 1]
            } else {
                Write-Host "    No such entry: $answer; keeping $a's model as it is."
            }
        } else {
            $null = Set-Model $a $answer
        }
    }

    # 3. Default toolchain, as Code-It-Build's selection. Running this script means
    # PowerShell is present, so preselect it too.
    $toolchainAvailable = Get-CodeItListToolchains $toolchainsDir
    $detectedToolchain = @($toolchainAvailable | Where-Object { Test-CodeItToolchainDetected $toolchainsDir $_ })
    $savedToolchain = Get-Default 'default-toolchain'
    if ($savedToolchain) {
        $preselect = $savedToolchain
        $preselectItems = @($savedToolchain -split ',')
    } else {
        $preselect = (@($detectedToolchain | Where-Object { $_ -ne 'powershell' }) + 'powershell') -join ','
        $preselectItems = $detectedToolchain + 'powershell'
    }
    $answer = Read-Choice 'default toolchain' $preselect ($detectedToolchain -join ' ') $savedToolchain $toolchainAvailable
    if (-not $answer -or $answer -eq 'none') {
        Set-DefaultLine 'default-toolchain' ""
        Write-Host "    Default toolchain cleared"
    } else {
        $chosen = @($answer -split '[,\s]+' | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '^\d+$') {
                $idx = [int]$_
                if ($idx -ge 1 -and $idx -le $toolchainAvailable.Count) { $toolchainAvailable[$idx - 1] }
            } elseif ($toolchainAvailable -contains $_) { $_ }
        } | Select-Object -Unique)
        $resolved = $null
        if ($chosen.Count) { $resolved = Resolve-CodeItToolchain ($chosen -join ',') $toolchainsDir }
        if ($null -ne $resolved -and $resolved.Count) {
            $joined = $resolved -join ','
            Set-DefaultLine 'default-toolchain' $joined
            Write-Host "    Default toolchain: $joined"
        }
    }
    Write-Host ""
    Show-Defaults
}

if ($refreshModels) {
    if (-not (Update-ModelCatalog)) { exit 1 }
}

if ($show) {
    Show-Defaults
    exit 0
}

if (-not $agent -and -not $toolchain -and $model.Count -eq 0) {
    Invoke-Interactive
    exit 0
}

# Parameterised: set exactly what was given, ask nothing
$rc = 0
if ($agent) {
    if ($agent -eq 'none') {
        Set-DefaultLine 'default-agent' ""
    } elseif (Test-CodeItAgentExists $agentsDir $agent) {
        Set-DefaultLine 'default-agent' $agent
        Write-Host "    Default agent: $agent"
    } else {
        Write-Warning "Unknown agent '$agent'. Known agents: $((Get-CodeItListAgents $agentsDir) -join ' ')"
        $rc = 1
    }
}
foreach ($m in $model) {
    if (-not $m.Contains('=')) {
        Write-Warning "-model needs AGENT=MODEL, not '$m'."
        $rc = 1
        continue
    }
    $sep = $m.IndexOf('=')
    if (-not (Set-Model ($m.Substring(0, $sep)) ($m.Substring($sep + 1)))) { $rc = 1 }
}
if ($toolchain) {
    $resolved = Resolve-CodeItToolchain $toolchain $toolchainsDir
    if ($null -eq $resolved -or $resolved.Count -eq 0) {
        Write-Warning "-toolchain needs at least one known toolchain."
        $rc = 1
    } else {
        $joined = $resolved -join ','
        Set-DefaultLine 'default-toolchain' $joined
        Write-Host "    Default toolchain: $joined"
    }
}
exit $rc
