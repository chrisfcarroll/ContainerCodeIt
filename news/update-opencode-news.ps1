#!/usr/bin/env pwsh

<#
.SYNOPSIS
Refreshes the OpenCode models page (news/opencode/*.html) from models.dev.

.DESCRIPTION
Updates the model list and the pricings in the page's inline `const DATA=[...]`
array with the up-to-date values, and the "snapshot <Month Year>" date in its
header, so the page shows the current models and prices after

    ./update-opencode-news.ps1

The whole page is data-driven from that one array: everything else (the stats
cards, the filters, the table) is rendered client-side from it, so replacing
the array is the entire update.

Each model entry keeps the page's existing format:
    name, id, free, feats, inp, out, cr, cw, en
where inp/out/cr/cw are input, output, cache-read and cache-write prices in USD
per 1M tokens (null where the provider has no such price), and the manual
"enabled" (en) flag of a model already on the page is carried over: models.dev
has no such field. New models start enabled.

The data source is models.dev, the model registry OpenCode itself reads:
OpenCode's docs (https://opencode.ai/docs/models/) and lib/models.txt both point
there. models.dev's JSON API is public and needs no authentication:

    https://models.dev/api.json

which lists every provider with each model's capabilities and
cost.input/output/cache_read/cache_write prices per 1M tokens. The page cites
the same source in its header. A local copy of the JSON can be passed with
-ApiUrl, which is how the tests run offline.

.PARAMETER Page
The page to update. Default: the first *.html under news/opencode/ next to
this script.

.PARAMETER Provider
The models.dev provider whose models the page lists: 'opencode' (the catalog
OpenCode's own inference serves, the default) or 'opencode-go'.

.PARAMETER ApiUrl
The models.dev JSON to read: the public api (default
https://models.dev/api.json) or a local file with the same shape.

.EXAMPLE
    ./update-opencode-news.ps1
    Updates news/opencode/opencode-go-models-2026-10.html with today's models
    and prices from https://models.dev/api.json.

.EXAMPLE
    ./update-opencode-news.ps1 -Provider opencode-go -ApiUrl models.json
    Updates the page from the local file models.json with the opencode-go
    provider's models.

.LINK
https://models.dev/api.json
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$Page     = "",
    [string]$Provider = "opencode",
    [string]$ApiUrl   = "https://models.dev/api.json"
)

$ErrorActionPreference = 'Stop'

if (-not $Page) {
    $newsDir = Join-Path $PSScriptRoot 'opencode'
    $firstPage = Get-ChildItem -Path $newsDir -Filter *.html | Select-Object -First 1
    if (-not $firstPage) { throw "No *.html page found under $newsDir; pass -Page." }
    $Page = $firstPage.FullName
}
if (-not (Test-Path -Path $Page -PathType Leaf)) { throw "Page not found: $Page" }

# --- Read the data: the public api, or a local file with the same shape
if (Test-Path -Path $ApiUrl -PathType Leaf) {
    $registry = Get-Content -Path $ApiUrl -Raw | ConvertFrom-Json
} else {
    $registry = Invoke-RestMethod -Uri $ApiUrl
}
$providerEntry = $registry.$Provider
if (-not $providerEntry -or -not $providerEntry.models) {
    $known = @($registry.PSObject.Properties.Name) -join ', '
    throw "Provider '$Provider' not found in the models.dev data. Known: $known"
}

# --- The page's current entries, to carry each model's manual 'en' flag over
$html = Get-Content -Path $Page -Raw
$enabled = @{}
if ($html -match 'const DATA=\[(?<data>.*)\];' -and $Matches.data) {
    # Re-wrap in [ ] so the comma-separated objects parse as one JSON array
    foreach ($entry in @(ConvertFrom-Json ('[' + $Matches.data + ']'))) {
        if ($entry.id) { $enabled["$($entry.id)"] = [bool]$entry.en }
    }
}

# A price as the page spells it: "12.5", "0.13", whole numbers as "10.0"
# (null stays null, which the page renders as "-")
function Format-Price([object]$value) {
    if ($null -eq $value) { return 'null' }
    $v = [double]$value
    $s = $v.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($v -eq [Math]::Floor($v) -and -not $s.Contains('.')) { $s += '.0' }
    return $s
}

# --- Map each models.dev entry to the page's format, in the page's order:
# name, id, free, feats, inp, out, cr, cw, en. The features come from the
# model's capabilities and input modalities, in the page's established order.
function Convert-ToPageEntry($model, [string]$modelId) {
    $cost = $model.cost
    $name = $modelId
    if ($model.name) { $name = "$($model.name)" }

    $feats = @()
    $inputs = @()
    if ($model.modalities -and $model.modalities.input) { $inputs = @($model.modalities.input) }
    if ($inputs -contains 'video') { $feats += 'Video' }
    if ($inputs -contains 'audio') { $feats += 'Audio' }
    if ($model.reasoning)          { $feats += 'Reasoning' }
    if ($inputs -contains 'image') { $feats += 'Image' }
    if ($inputs -contains 'pdf')   { $feats += 'PDF' }
    if ($model.tool_call)          { $feats += 'Tools' }
    if ($inputs -contains 'text' -or $feats.Count -eq 0) { $feats += 'Text' }

    $free = $false
    if ($cost -and $null -ne $cost.input -and $null -ne $cost.output) {
        $free = ([double]$cost.input -eq 0 -and [double]$cost.output -eq 0)
    }
    $en = $true
    if ($enabled.ContainsKey($modelId)) { $en = $enabled[$modelId] }

    $freeText = 'false'; if ($free) { $freeText = 'true' }
    $enText = 'false';    if ($en)  { $enText = 'true' }
    $featsText = ($feats | ForEach-Object { '"{0}"' -f $_ }) -join ', '

    return ('{{"name": "{0}", "id": "{1}", "free": {2}, "feats": [{3}], "inp": {4}, "out": {5}, "cr": {6}, "cw": {7}, "en": {8}}}' -f `
        $name, $modelId, $freeText, $featsText, `
        (Format-Price $cost.input), (Format-Price $cost.output), `
        (Format-Price $cost.cache_read), (Format-Price $cost.cache_write), `
        $enText)
}

# The page's list is ordered by model name; models.dev's JSON object is not
$models = @($providerEntry.models.PSObject.Properties | Sort-Object `
    { if ($_.Value.name) { "$($_.Value.name)" } else { $_.Name } })
$entries = @($models | ForEach-Object { Convert-ToPageEntry $_.Value $_.Name })
if ($entries.Count -eq 0) { throw "Provider '$Provider' has no models in the models.dev data" }

# The page renders everything from one array literal on one line. -replace's
# replacement reads $ specially, so escape it first.
$newData = 'const DATA=[' + ($entries -join ', ') + '];'

# The snapshot date in the header, and the source link (kept if already there)
$monthYear = (Get-Date -Format 'MMMM yyyy')
$newHtml = $html
if ($newHtml -match 'const DATA=\[.*\];') {
    $newHtml = $newHtml -replace 'const DATA=\[.*\];', $newData.Replace('$', '$$')
} else {
    throw "The page has no 'const DATA=[...];' line to update: $Page"
}
$newHtml = $newHtml -replace 'snapshot [A-Z][a-z]+ \d{4}', "snapshot $monthYear"
if ($newHtml -notmatch 'models\.dev') {
    $sourceNote = ' &middot; model list and prices from <a class="link-light" href="https://models.dev">models.dev</a>'
    $newHtml = $newHtml -replace '(?s)(<p class="lead[^>]*>.*?)(</p>)', ('$1' + $sourceNote.Replace('$', '$$') + '$2')
}

if ($WhatIfPreference) {
    "What if: updating ${Page} with $($entries.Count) models from the $Provider provider (snapshot $monthYear)"
} elseif ($PSCmdlet.ShouldProcess($Page, "refresh the models from $ApiUrl ($Provider)")) {
    # Write back the same string with only the changed stretches, so the rest
    # of the page's bytes are preserved
    [IO.File]::WriteAllText($Page, $newHtml)
    "Updated ${Page}: $($entries.Count) models from the $Provider provider, snapshot $monthYear"
}
