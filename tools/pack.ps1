# Pack an installable EZAssist zip under dist/ (runtime addon files only).
# Unzip into Interface/AddOns/ so the game loads Interface/AddOns/EZAssist/.
# Payload matches tools/deploy.ps1. Repo docs, tools, git, and editor files stay out.
#
# Usage:
#   pwsh ./tools/pack.ps1
#   pwsh ./tools/pack.ps1 -OutDir dist

[CmdletBinding()]
param(
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

$RootFiles = @(
    "EZAssist.mod",
    "EZAssist.lua",
    "EZAssist_Controller.lua",
    "EZAssist_Config.lua",
    "EZAssistConfig.xml",
    "EZAssist_GroupStats.lua",
    "EZAssist_ScenarioStats.lua"
)

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path)
}

function Assert-StagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$StageAddon,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$SourceLabel
    )

    $rel = ($RelativePath -replace '\\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($rel)) {
        throw "Empty file reference in $SourceLabel"
    }
    if ($rel.StartsWith('/') -or ($rel.Length -ge 2 -and $rel[1] -eq ':')) {
        throw "Absolute file reference in ${SourceLabel}: $rel"
    }
    $parts = @($rel.Split('/') | Where-Object { $_ -ne '' -and $_ -ne '.' })
    if ($parts.Count -eq 0 -or ($parts -contains '..')) {
        throw "File reference escapes the addon folder ($SourceLabel): $rel"
    }
    $normalized = ($parts -join '/')
    $full = [IO.Path]::GetFullPath((Join-Path $StageAddon ($normalized -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $stageFull = [IO.Path]::GetFullPath($StageAddon).TrimEnd('\', '/')
    $prefix = $stageFull + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File reference escapes the addon folder ($SourceLabel): $rel"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Referenced file missing from staged EZAssist/ ($SourceLabel): $normalized"
    }
}

$root = Get-RepoRoot
$modPath = Join-Path $root "EZAssist.mod"
$luaPath = Join-Path $root "EZAssist.lua"
$xmlPath = Join-Path $root "EZAssistConfig.xml"

if (-not (Test-Path -LiteralPath $modPath)) {
    throw "Missing EZAssist.mod at $modPath"
}
foreach ($name in $RootFiles) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required runtime file missing: $name"
    }
}

$modText = Read-Utf8Text -Path $modPath
# UiMod version= only, not VersionSettings gameVersion / windowsVersion / savedVariablesVersion.
if ($modText -notmatch '<UiMod\b[^>]*\bversion="([^"]+)"') {
    throw "Could not read UiMod version= from EZAssist.mod"
}
$version = $Matches[1]
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "EZAssist.mod UiMod version '$version' is not MAJOR.MINOR.PATCH"
}

$luaText = Read-Utf8Text -Path $luaPath
if ($luaText -notmatch 'EZAssist\.VERSION\s*=\s*"([^"]+)"') {
    throw "Could not read EZAssist.VERSION from EZAssist.lua"
}
$luaVersion = $Matches[1]
if ($luaVersion -ne $version) {
    throw "Version mismatch: EZAssist.mod UiMod version is $version but EZAssist.VERSION in EZAssist.lua is `"$luaVersion`". Bump both together."
}

if ([IO.Path]::IsPathRooted($OutDir)) {
    $outAbs = [IO.Path]::GetFullPath($OutDir)
} else {
    $outAbs = [IO.Path]::GetFullPath((Join-Path $root $OutDir))
}

$stageRoot = Join-Path $outAbs "_stage"
$stageAddon = Join-Path $stageRoot "EZAssist"
$zipPath = Join-Path $outAbs ("EZAssist-{0}.zip" -f $version)

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageAddon -Force | Out-Null

foreach ($name in $RootFiles) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $stageAddon $name) -Force
}

$stagedMod = Read-Utf8Text -Path (Join-Path $stageAddon "EZAssist.mod")
$fileRefs = [regex]::Matches($stagedMod, '<File\b[^>]*\bname="([^"]+)"')
if ($fileRefs.Count -eq 0) {
    throw "No <File name=`"...`" /> entries found in EZAssist.mod"
}
foreach ($fileRef in $fileRefs) {
    Assert-StagedFile -StageAddon $stageAddon -RelativePath $fileRef.Groups[1].Value -SourceLabel "EZAssist.mod"
}

if (-not (Test-Path -LiteralPath (Join-Path $stageAddon "EZAssistConfig.xml") -PathType Leaf)) {
    throw "Staged addon is missing EZAssistConfig.xml"
}
$stagedXml = Read-Utf8Text -Path (Join-Path $stageAddon "EZAssistConfig.xml")
$scriptRefs = [regex]::Matches($stagedXml, '<Script\b[^>]*\bfile="([^"]+)"')
if ($scriptRefs.Count -eq 0) {
    throw "No <Script file=`"...`" /> entries found in EZAssistConfig.xml"
}
foreach ($scriptRef in $scriptRefs) {
    Assert-StagedFile -StageAddon $stageAddon -RelativePath $scriptRef.Groups[1].Value -SourceLabel "EZAssistConfig.xml"
}

New-Item -ItemType Directory -Path $outAbs -Force | Out-Null
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$expected = @(
    "EZAssist/EZAssist.mod",
    "EZAssist/EZAssist.lua",
    "EZAssist/EZAssist_Controller.lua",
    "EZAssist/EZAssist_Config.lua",
    "EZAssist/EZAssistConfig.xml",
    "EZAssist/EZAssist_GroupStats.lua",
    "EZAssist/EZAssist_ScenarioStats.lua"
)

$zipStream = $null
$archive = $null
try {
    $zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive(
        $zipStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false)
    $zipStream = $null

    $stageFull = [IO.Path]::GetFullPath($stageAddon).TrimEnd('\', '/')
    Get-ChildItem -LiteralPath $stageAddon -Recurse -File | Sort-Object FullName | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_.FullName)
        $prefix = $stageFull + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to zip a file outside the staged addon: $full"
        }
        $rel = $full.Substring($stageFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel -match '(^|/)\.\.(/|$)' -or [string]::IsNullOrWhiteSpace($rel)) {
            throw "Refusing unsafe staged path: $rel"
        }
        $entryName = "EZAssist/$rel"
        $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $fileStream = [IO.File]::OpenRead($full)
        try {
            $fileStream.CopyTo($entryStream)
        } finally {
            $fileStream.Dispose()
            $entryStream.Dispose()
        }
    }
} finally {
    if ($archive) { $archive.Dispose() }
    if ($zipStream) { $zipStream.Dispose() }
}

$seen = New-Object System.Collections.Generic.List[string]
$verify = $null
try {
    $verify = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    foreach ($entry in $verify.Entries) {
        $name = $entry.FullName
        if ($name.Contains('\')) {
            throw "Zip entry uses backslashes: $name"
        }
        if ($name.StartsWith('/') -or ($name.Length -ge 2 -and $name[1] -eq ':')) {
            throw "Zip entry is absolute: $name"
        }
        if ($name -match '(^|/)\.\.(/|$)') {
            throw "Zip entry escapes the archive: $name"
        }
        if ($name.EndsWith('/')) {
            throw "Zip contains a directory entry: $name"
        }
        if (-not $name.StartsWith('EZAssist/')) {
            throw "Zip entry is outside EZAssist/: $name"
        }
        if ($name.StartsWith('EZAssist/EZAssist/')) {
            throw "Zip is nested as EZAssist/EZAssist/: $name"
        }
        [void]$seen.Add($name)
    }
} finally {
    if ($verify) { $verify.Dispose() }
}

$missing = @($expected | Where-Object { -not $seen.Contains($_) })
if ($missing.Count -gt 0) {
    Remove-Item -LiteralPath $zipPath -Force
    throw ("Zip is missing: " + ($missing -join ", "))
}
$extra = @($seen | Where-Object { $expected -notcontains $_ })
if ($extra.Count -gt 0) {
    Remove-Item -LiteralPath $zipPath -Force
    throw ("Unexpected zip entry: " + ($extra -join ", "))
}

Remove-Item -LiteralPath $stageRoot -Recurse -Force

Write-Host ("Packed {0}" -f $zipPath)
foreach ($name in $expected) {
    Write-Host ("  {0}" -f $name)
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("version={0}" -f $version)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("zip_path={0}" -f $zipPath)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("zip_name=EZAssist-{0}.zip" -f $version)
}
