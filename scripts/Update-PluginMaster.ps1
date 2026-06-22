param(
    [string] $ConfigPath = "plugins.json",
    [string] $PluginMasterPath = "pluginmaster.json",
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"

function Get-GitHubHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "SekhmetPlugins-Updater"
    }

    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $env:GITHUB_TOKEN"
    }

    return $headers
}

function Get-GitHubJson {
    param([string] $Uri)
    $response = Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubHeaders)
    if ($response -is [array]) {
        foreach ($item in $response) {
            $item
        }
    }
    else {
        $response
    }
}

function Get-ReleaseAsset {
    param(
        [object] $Release,
        [string] $AssetName
    )

    $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) {
        $asset = $Release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    }

    return $asset
}

function Get-ManifestFromZip {
    param(
        [string] $ZipUrl,
        [string] $InternalName
    )

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $workDir "plugin.zip"
    $extractPath = Join-Path $workDir "extract"

    try {
        New-Item -ItemType Directory -Force -Path $workDir, $extractPath | Out-Null
        Invoke-WebRequest -Uri $ZipUrl -Headers (Get-GitHubHeaders) -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $manifest = $null
        if ($InternalName) {
            $manifest = Get-ChildItem -Path $extractPath -Recurse -Filter "$InternalName.json" | Select-Object -First 1
        }

        if (-not $manifest) {
            $manifest = Get-ChildItem -Path $extractPath -Recurse -Filter "*.json" |
                Where-Object { $_.Name -notlike "*.deps.json" -and $_.Name -ne "packages.lock.json" } |
                Select-Object -First 1
        }

        if (-not $manifest) {
            throw "No plugin manifest json found in $ZipUrl"
        }

        return Get-Content -Raw $manifest.FullName | ConvertFrom-Json
    }
    finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}

function Merge-Value {
    param(
        [object] $Primary,
        [object] $Secondary,
        [object] $Existing,
        [string] $Name
    )

    if ($Primary -and $Primary.PSObject.Properties.Name -contains $Name -and $null -ne $Primary.$Name) {
        return $Primary.$Name
    }

    if ($Secondary -and $Secondary.PSObject.Properties.Name -contains $Name -and $null -ne $Secondary.$Name) {
        return $Secondary.$Name
    }

    if ($Existing -and $Existing.PSObject.Properties.Name -contains $Name -and $null -ne $Existing.$Name) {
        return $Existing.$Name
    }

    return $null
}

function Merge-ConfiguredValue {
    param(
        [object] $Plugin,
        [object] $Primary,
        [object] $Secondary,
        [object] $Existing,
        [string] $Name
    )

    if ($Plugin.metadata -and $Plugin.metadata.PSObject.Properties.Name -contains $Name -and $null -ne $Plugin.metadata.$Name) {
        return $Plugin.metadata.$Name
    }

    return Merge-Value $Primary $Secondary $Existing $Name
}

function Set-EntryValue {
    param(
        [System.Collections.Specialized.OrderedDictionary] $Entry,
        [string] $Name,
        [object] $Value
    )

    if ($null -ne $Value) {
        $Entry[$Name] = $Value
    }
}

function ConvertTo-UnixSeconds {
    param([object] $Value)

    if ($Value -is [DateTime]) {
        return [int64]([DateTimeOffset]$Value.ToUniversalTime()).ToUnixTimeSeconds()
    }

    if ($Value -is [DateTimeOffset]) {
        return [int64]$Value.ToUniversalTime().ToUnixTimeSeconds()
    }

    $text = [string]$Value
    return [int64]([DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeSeconds())
}

function ConvertTo-ObjectArray {
    param([object] $Value)

    $items = @()
    if ($Value -is [array]) {
        foreach ($item in $Value) {
            $items += $item
        }
    }
    elseif ($null -ne $Value) {
        $items += $Value
    }

    return $items
}

function Format-Json {
    param([string] $Json)

    $builder = [System.Text.StringBuilder]::new()
    $indent = 0
    $inString = $false
    $escape = $false

    foreach ($char in $Json.ToCharArray()) {
        if ($inString) {
            [void]$builder.Append($char)
            if ($escape) {
                $escape = $false
            }
            elseif ($char -eq "\") {
                $escape = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        switch ($char) {
            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }
            { $_ -eq "{" -or $_ -eq "[" } {
                [void]$builder.Append($char)
                [void]$builder.AppendLine()
                $indent++
                [void]$builder.Append(("  " * $indent))
            }
            { $_ -eq "}" -or $_ -eq "]" } {
                [void]$builder.AppendLine()
                $indent--
                [void]$builder.Append(("  " * $indent))
                [void]$builder.Append($char)
            }
            "," {
                [void]$builder.Append($char)
                [void]$builder.AppendLine()
                [void]$builder.Append(("  " * $indent))
            }
            ":" {
                [void]$builder.Append(": ")
            }
            { [char]::IsWhiteSpace($_) } {
            }
            default {
                [void]$builder.Append($char)
            }
        }
    }

    return $builder.ToString()
}

$config = ConvertTo-ObjectArray (Get-Content -Raw $ConfigPath | ConvertFrom-Json)
$existingEntries = @()
if (Test-Path $PluginMasterPath) {
    $existingEntries = ConvertTo-ObjectArray (Get-Content -Raw $PluginMasterPath | ConvertFrom-Json)
}

$existingByRepo = @{}
$existingByInternalName = @{}
foreach ($entry in $existingEntries) {
    if ($entry.RepoUrl) {
        $existingByRepo[$entry.RepoUrl.TrimEnd("/")] = $entry
    }
    if ($entry.InternalName) {
        $existingByInternalName[$entry.InternalName] = $entry
    }
}

$output = @()
foreach ($plugin in $config) {
    $repoFullName = "$($plugin.owner)/$($plugin.repo)"
    $repoUrl = "https://github.com/$repoFullName"
    $existing = $existingByRepo[$repoUrl]
    if (-not $existing -and $existingByInternalName.ContainsKey($plugin.repo)) {
        $existing = $existingByInternalName[$plugin.repo]
    }

    Write-Host "Updating $repoFullName"

    try {
        $sourceRef = "main"
        if ($plugin.PSObject.Properties.Name -contains "sourceRef" -and $plugin.sourceRef) {
            $sourceRef = $plugin.sourceRef
        }

        $sourceManifestUrl = "https://raw.githubusercontent.com/$repoFullName/$sourceRef/$($plugin.manifestPath)"
        $sourceManifest = (Invoke-WebRequest -Uri $sourceManifestUrl -UseBasicParsing).Content | ConvertFrom-Json
        $releases = @(Get-GitHubJson "https://api.github.com/repos/$repoFullName/releases?per_page=100")
        $stableRelease = $releases | Where-Object { ($_.draft -ne $true) -and ($_.prerelease -ne $true) } | Sort-Object published_at -Descending | Select-Object -First 1
        $testingRelease = $releases | Where-Object { ($_.draft -ne $true) -and ($_.prerelease -eq $true) } | Sort-Object published_at -Descending | Select-Object -First 1

        $testingOnly = $false
        if ($plugin.PSObject.Properties.Name -contains "testingOnly" -and $plugin.testingOnly -eq $true) {
            $testingOnly = $true
        }

        if (-not $stableRelease) {
            if (-not $testingOnly -or -not $testingRelease) {
                throw "No stable release found for $repoFullName"
            }

            $stableRelease = $testingRelease
        }

        $stableAsset = Get-ReleaseAsset $stableRelease $plugin.assetName
        if (-not $stableAsset) {
            throw "No zip asset found on stable release $($stableRelease.tag_name)"
        }

        $releaseManifest = Get-ManifestFromZip $stableAsset.browser_download_url $sourceManifest.InternalName
        $testingAsset = $null
        $testingManifest = $null
        if ($testingRelease) {
            $testingAsset = Get-ReleaseAsset $testingRelease $plugin.assetName
            if ($testingAsset) {
                $testingManifest = Get-ManifestFromZip $testingAsset.browser_download_url $sourceManifest.InternalName
            }
        }

        $entry = [ordered]@{}
        foreach ($field in @(
            "Author",
            "Name",
            "Punchline",
            "Description",
            "InternalName",
            "AssemblyVersion",
            "RepoUrl",
            "ApplicableVersion",
            "DalamudApiLevel",
            "Tags",
            "CategoryTags",
            "IsHide",
            "IsTestingExclusive"
        )) {
            if ($field -in @("AssemblyVersion", "DalamudApiLevel")) {
                Set-EntryValue $entry $field (Merge-Value $releaseManifest $sourceManifest $existing $field)
            }
            elseif ($field -eq "RepoUrl") {
                Set-EntryValue $entry $field (Merge-Value $sourceManifest $releaseManifest $existing $field)
                if (-not $entry.Contains("RepoUrl")) {
                    $entry[$field] = $repoUrl
                }
            }
            else {
                Set-EntryValue $entry $field (Merge-ConfiguredValue $plugin $sourceManifest $releaseManifest $existing $field)
            }
        }

        foreach ($field in @("LoadRequiredState", "LoadSync", "CanUnloadAsync", "LoadPriority", "AcceptsFeedback")) {
            Set-EntryValue $entry $field (Merge-Value $releaseManifest $sourceManifest $existing $field)
        }

        $downloadCount = 0
        foreach ($release in @($stableRelease, $testingRelease)) {
            if (-not $release) {
                continue
            }

            foreach ($asset in @($release.assets)) {
                if ($asset.download_count) {
                    $downloadCount += [int]$asset.download_count
                }
            }
        }

        if ($existing -and $existing.DownloadCount -and [int]$existing.DownloadCount -gt $downloadCount) {
            $downloadCount = [int]$existing.DownloadCount
        }

        $publishedAt = $stableRelease.published_at
        $lastUpdate = ConvertTo-UnixSeconds -Value $publishedAt
        $entry["DownloadCount"] = $downloadCount
        $entry["LastUpdate"] = $lastUpdate
        if ($stableRelease.body) {
            $entry["Changelog"] = $stableRelease.body
        }

        if ($testingOnly) {
            $entry["IsTestingExclusive"] = $true
        }

        $entry["DownloadLinkInstall"] = $stableAsset.browser_download_url
        $entry["DownloadLinkUpdate"] = $stableAsset.browser_download_url
        if ($testingAsset) {
            $entry["DownloadLinkTesting"] = $testingAsset.browser_download_url
            Set-EntryValue $entry "TestingAssemblyVersion" (Merge-Value $testingManifest $null $existing "AssemblyVersion")
        }
        else {
            $entry["DownloadLinkTesting"] = $stableAsset.browser_download_url
        }

        $output += [pscustomobject]$entry
    }
    catch {
        if ($existing) {
            Write-Warning "Preserving existing $repoFullName entry: $($_.Exception.Message)"
            $output += $existing
            continue
        }

        throw
    }
}

$json = Format-Json ($output | ConvertTo-Json -Depth 20 -Compress)
if ($DryRun) {
    Write-Output $json
}
else {
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PluginMasterPath)
    [System.IO.File]::WriteAllText($resolvedPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}
