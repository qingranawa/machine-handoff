Set-StrictMode -Version Latest

function Get-MHEAContextValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -ne $Context) {
        $property = $Context.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Get-MHEAUserPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $userHome = [string](Get-MHEAContextValue -Context $Context -Name 'userHome' -Default ([Environment]::GetEnvironmentVariable('USERPROFILE')))
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = [Environment]::GetEnvironmentVariable('HOME') }

    $appData = [string](Get-MHEAContextValue -Context $Context -Name 'appData' -Default ([Environment]::GetEnvironmentVariable('APPDATA')))
    if ([string]::IsNullOrWhiteSpace($appData) -and -not [string]::IsNullOrWhiteSpace($userHome)) { $appData = Join-Path $userHome 'AppData\Roaming' }

    $localAppData = [string](Get-MHEAContextValue -Context $Context -Name 'localAppData' -Default ([Environment]::GetEnvironmentVariable('LOCALAPPDATA')))
    if ([string]::IsNullOrWhiteSpace($localAppData) -and -not [string]::IsNullOrWhiteSpace($userHome)) { $localAppData = Join-Path $userHome 'AppData\Local' }

    return [pscustomobject]@{
        userHome = $userHome
        appData = $appData
        localAppData = $localAppData
    }
}

function ConvertTo-MHEASafePath {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)]$Paths
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = $Path
    foreach ($replacement in @(
        @{ value = [string]$Paths.userHome; token = '%USERPROFILE%' },
        @{ value = [string]$Paths.appData; token = '%APPDATA%' },
        @{ value = [string]$Paths.localAppData; token = '%LOCALAPPDATA%' }
    )) {
        if (-not [string]::IsNullOrWhiteSpace($replacement.value)) {
            $escaped = [Regex]::Escape($replacement.value.TrimEnd('\'))
            $value = $value -replace ('(?i)^' + $escaped + '(?=[\\/]|$)'), $replacement.token
        }
    }
    return $value
}

function Test-MHEAExcludedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context
    )

    $excludes = @(Get-MHEAContextValue -Context $Context -Name 'excludes' -Default @())
    foreach ($exclude in $excludes) {
        if ([string]::IsNullOrWhiteSpace([string]$exclude)) { continue }
        try {
            $fullExclude = [IO.Path]::GetFullPath([string]$exclude).TrimEnd('\')
            $fullPath = [IO.Path]::GetFullPath($Path)
            if ($fullPath.Equals($fullExclude, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($fullExclude + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { return $true }
    }
    return $false
}

function Test-MHEAReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $attributes = [IO.File]::GetAttributes($Path)
        return (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $true }
}

function Test-MHEADirectory {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or (Test-MHEAExcludedPath -Path $Path -Context $Context)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return -not (Test-MHEAReparsePoint -Path $Path)
}

function Test-MHEAFile {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or (Test-MHEAExcludedPath -Path $Path -Context $Context)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return -not (Test-MHEAReparsePoint -Path $Path)
}

function Get-MHEARemainingMilliseconds {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    try {
        $deadlineProperty = if ($Context.PSObject.Properties['domainDeadline']) { $Context.PSObject.Properties['domainDeadline'] } else { $Context.PSObject.Properties['deadline'] }
        if ($null -ne $deadlineProperty) {
            return [Math]::Max(0, [int][Math]::Floor(([DateTimeOffset]$deadlineProperty.Value - [DateTimeOffset]::UtcNow).TotalMilliseconds))
        }
    } catch { return 0 }
    return 2147483647
}

function Get-MHEABudgetValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default
    )

    try {
        $budgets = $Context.PSObject.Properties['budgets']
        if ($null -ne $budgets -and $null -ne $budgets.Value -and $budgets.Value.PSObject.Properties[$Name]) {
            return [int]$budgets.Value.PSObject.Properties[$Name].Value
        }
    } catch { }
    return $Default
}

function Get-MHEAChildDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$Limit
    )

    $result = @()
    if (-not (Test-MHEADirectory -Path $Path -Context $Context)) { return $result }
    try {
        foreach ($child in [IO.Directory]::EnumerateDirectories($Path)) {
            if ($result.Count -ge $Limit) { break }
            if (Test-MHEAReparsePoint -Path $child) { continue }
            if (Test-MHEAExcludedPath -Path $child -Context $Context) { continue }
            $result += $child
        }
    } catch { }
    return @($result | Sort-Object -Unique)
}

function Get-MHEAFormat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        '.json' { return 'JSON' }
        '.jsonc' { return 'JSONC' }
        '.toml' { return $null }
        '.yaml' { return $null }
        '.yml' { return $null }
        '.md' { return 'TEXT' }
        '.mdc' { return 'TEXT' }
        '.txt' { return 'TEXT' }
        default { return $null }
    }
}

function Get-MHEAFileLength {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try { return [int64]([IO.FileInfo]$Path).Length } catch { return -1 }
}

function Get-MHEAArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Path
    )

    $leaf = [IO.Path]::GetFileName($Path)
    $relative = $leaf
    try {
        $parent = [IO.Path]::GetDirectoryName($Path)
        $parentLeaf = [IO.Path]::GetFileName($parent)
        if (-not [string]::IsNullOrWhiteSpace($parentLeaf)) { $relative = $parentLeaf + '-' + $leaf }
    } catch { }
    $safeLeaf = ($relative -replace '[^A-Za-z0-9._-]', '_')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $suffix = ([BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 10).ToLowerInvariant()
        $safeLeaf = [IO.Path]::GetFileNameWithoutExtension($safeLeaf) + '-' + $suffix + [IO.Path]::GetExtension($safeLeaf)
    } catch { }
    return ('configs/' + $Prefix + '/' + $safeLeaf)
}

function Get-MHEASecretPattern {
    return '(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd|user[ _-]?id|uid|authorization|cookie|credential|private[_-]?key)\s*["' + "'" + '=:\s]+(?!\[?redacted\]?\b|<redacted>\b|null\b|none\b)[^\s,;\]}]{4,}|\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_-]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,})\b'
}

function Test-MHEASecretText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text -match (Get-MHEASecretPattern))
}

function New-MHEABlockedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowNull()][string]$TargetPathCandidate,
        [Parameter(Mandatory)][string]$ContentPolicy,
        [Parameter(Mandatory)][string]$Sensitivity,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$RestorePolicy,
        [Parameter(Mandatory)][string]$ValidationStrategy,
        [Parameter(Mandatory)][string]$BlockReason,
        [Parameter(Mandatory)]$Paths
    )

    return [pscustomobject]@{
        artifact = [pscustomobject]@{
            id = $Id
            domain = $Domain
            sourceLocator = ConvertTo-MHEASafePath -Path $SourcePath -Paths $Paths
            targetPathCandidate = $TargetPathCandidate
            contentPolicy = $ContentPolicy
            sensitivity = $Sensitivity
            format = $Format
            artifactPath = $null
            restorePolicy = $RestorePolicy
            validationStrategy = $ValidationStrategy
            captureState = 'BLOCKED'
            redactionStatus = 'BLOCKED'
            blockReason = $BlockReason
            artifactSha256 = $null
            errorCode = $BlockReason
        }
        content = $null
    }
}

function New-MHEAArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowNull()][string]$TargetPathCandidate,
        [Parameter(Mandatory)][string]$ContentPolicy,
        [Parameter(Mandatory)][string]$Sensitivity,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$RestorePolicy,
        [Parameter(Mandatory)][string]$ValidationStrategy,
        [Parameter(Mandatory)][int]$MaxConfigBytes
    )

    $length = Get-MHEAFileLength -Path $SourcePath
    if ($length -lt 0) {
        return New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy -BlockReason 'UNREADABLE' -Paths $Paths
    }
    if ($length -gt $MaxConfigBytes) {
        return New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy -BlockReason 'OVERSIZED' -Paths $Paths
    }

    if ($ContentPolicy -in @('METADATA_ONLY', 'MANUAL_TRANSFER')) {
        return [pscustomobject]@{
            artifact = [pscustomobject]@{
                id = $Id
                domain = $Domain
                sourceLocator = ConvertTo-MHEASafePath -Path $SourcePath -Paths $Paths
                targetPathCandidate = $TargetPathCandidate
                contentPolicy = $ContentPolicy
                sensitivity = $Sensitivity
                format = $Format
                artifactPath = $null
                restorePolicy = $RestorePolicy
                validationStrategy = $ValidationStrategy
                captureState = 'METADATA_ONLY'
                redactionStatus = 'NOT_APPLICABLE'
                blockReason = $null
                artifactSha256 = $null
                errorCode = $null
            }
            content = $null
        }
    }

    if (-not (Get-Command -Name 'New-MHConfigArtifact' -ErrorAction SilentlyContinue)) {
        return New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy -BlockReason 'HELPER_UNAVAILABLE' -Paths $Paths
    }

    try {
        $artifact = New-MHConfigArtifact -Context $Context -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy
        $content = if ($artifact.PSObject.Properties['content']) { [string]$artifact.content } else { $null }
        if ($null -ne $content -and (Test-MHEASecretText -Text $content)) {
            return New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy -BlockReason 'REDACTION_BLOCKED' -Paths $Paths
        }
        if ($artifact.PSObject.Properties['artifact'] -and $artifact.artifact.PSObject.Properties['sourceLocator']) {
            $artifact.artifact.sourceLocator = ConvertTo-MHEASafePath -Path ([string]$artifact.artifact.sourceLocator) -Paths $Paths
        }
        return $artifact
    } catch {
        $reason = 'ARTIFACT_FAILED'
        $message = [string]$_.Exception.Message
        if ($message -match 'REDACTION_BLOCKED') { $reason = 'REDACTION_BLOCKED' }
        elseif ($message -match 'OVERSIZE|TOO_LARGE|MAX_CONFIG') { $reason = 'OVERSIZED' }
        elseif ($message -match 'UNSUPPORTED') { $reason = 'UNSUPPORTED_FORMAT' }
        return New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate $TargetPathCandidate -ContentPolicy $ContentPolicy -Sensitivity $Sensitivity -Format $Format -ArtifactPath $ArtifactPath -RestorePolicy $RestorePolicy -ValidationStrategy $ValidationStrategy -BlockReason $reason -Paths $Paths
    }
}

function Get-MHEAArtifactMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$RestorePolicy,
        [Parameter(Mandatory)]$Paths
    )

    $artifactRecord = $null
    if ($Artifact.PSObject.Properties['artifact']) { $artifactRecord = $Artifact.artifact }
    $captureState = if ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['captureState']) { [string]$artifactRecord.captureState } else { 'UNKNOWN' }
    $redactionStatus = if ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['redactionStatus']) { [string]$artifactRecord.redactionStatus } else { 'UNKNOWN' }
    $blockReason = if ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['blockReason']) { [string]$artifactRecord.blockReason } elseif ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['errorCode']) { [string]$artifactRecord.errorCode } else { $null }
    return [pscustomobject]@{
        id = $Id
        kind = $Kind
        category = $Category
        sourcePath = ConvertTo-MHEASafePath -Path $SourcePath -Paths $Paths
        state = 'PRESENT'
        captureState = $captureState
        redactionStatus = $redactionStatus
        blockReason = $blockReason
        restorePolicy = $RestorePolicy
        artifactId = if ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['id']) { [string]$artifactRecord.id } else { $Id }
        artifactPath = if ($null -ne $artifactRecord -and $artifactRecord.PSObject.Properties['artifactPath']) { [string]$artifactRecord.artifactPath } else { $null }
    }
}

function Get-MHEACommandFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string[]]$Names,
        [string[]]$Arguments = @('--version')
    )

    $command = $null
    foreach ($name in $Names) {
        try {
            $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        } catch { $command = $null }
        if ($null -ne $command) { break }
    }
    if ($null -eq $command) {
        return [pscustomobject]@{ status = 'NOT_FOUND'; state = 'ABSENT'; command = $null; path = $null; version = $null; errorCode = 'NOT_FOUND' }
    }
    if ([bool](Get-MHEAContextValue -Context $Context -Name 'skipProcessProbes' -Default $false)) {
        return [pscustomobject]@{ status = 'NOT_TESTED'; state = 'PRESENT'; command = [string]$command.Name; path = [string]$command.Source; version = $null; errorCode = 'NOT_TESTED' }
    }

    $version = $null
    $status = 'UNKNOWN'
    $errorCode = $null
    try {
        if ((Get-MHEARemainingMilliseconds -Context $Context) -le 0) {
            $status = 'NOT_TESTED'
            $errorCode = 'TIMEOUT'
        } else {
            $result = Invoke-MHSafeProcess -Name $command.Name -Arguments $Arguments -TimeoutMilliseconds 5000 -MaxOutputBytes 4096 -Context $Context
            if ($result.timedOut) { $status = 'NOT_TESTED'; $errorCode = 'TIMEOUT' }
            elseif ($result.errorCode -eq 'NOT_FOUND') { $status = 'NOT_FOUND'; $errorCode = 'NOT_FOUND' }
            elseif ($result.errorCode) { $status = 'UNKNOWN'; $errorCode = 'PROCESS_FAILED' }
            elseif ($result.exitCode -ne 0) { $status = 'UNKNOWN'; $errorCode = 'PROCESS_FAILED' }
            else {
                $status = 'FOUND'
                $output = ([string]$result.stdout).Trim()
                $match = [Regex]::Match($output, '(?<![A-Za-z0-9])\d+(?:\.\d+){1,3}(?![A-Za-z0-9])')
                if ($match.Success) { $version = $match.Value }
            }
        }
    } catch { $status = 'UNKNOWN'; $errorCode = 'PROCESS_FAILED' }
    return [pscustomobject]@{
        status = $status
        state = 'PRESENT'
        command = [string]$command.Name
        path = [string]$command.Source
        version = $version
        errorCode = $errorCode
    }
}

function Get-MHEAExtensionFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$Limit
    )

    $items = @()
    if (-not (Test-MHEADirectory -Path $Root -Context $Context)) { return $items }
    foreach ($extensionPath in @(Get-MHEAChildDirectories -Path $Root -Context $Context -Limit $Limit)) {
        if ($items.Count -ge $Limit) { break }
        $name = [IO.Path]::GetFileName($extensionPath)
        if ($name -match '^(?i)(cache|cacheddata|logs|log|storage|state|user-data)$') { continue }
        $manifestPath = Join-Path $extensionPath 'package.json'
        $extensionId = $null
        $version = $null
        if (Test-MHEAFile -Path $manifestPath -Context $Context) {
            try {
                $length = Get-MHEAFileLength -Path $manifestPath
                if ($length -ge 0 -and $length -le 262144) {
                    $raw = Read-MHBoundedUtf8Text -Path $manifestPath -MaxBytes ([Math]::Max(1L, [long]$length))
                    $manifest = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                    if ($manifest.PSObject.Properties['publisher'] -and $manifest.PSObject.Properties['name']) {
                        $publisher = [string]$manifest.publisher
                        $extensionName = [string]$manifest.name
                        if ($publisher -match '^[A-Za-z0-9._-]{1,100}$' -and $extensionName -match '^[A-Za-z0-9._-]{1,100}$') { $extensionId = $publisher + '.' + $extensionName }
                    }
                    if ($manifest.PSObject.Properties['version'] -and ([string]$manifest.version -match '^[0-9A-Za-z][0-9A-Za-z._+-]{0,80}$')) { $version = [string]$manifest.version }
                }
            } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($extensionId) -and $name -match '^(?<id>[A-Za-z0-9._+-]{2,180})-(?<version>\d+(?:\.\d+){1,4}(?:[-+][A-Za-z0-9._-]+)?)$') {
            $extensionId = $Matches.id
            if ([string]::IsNullOrWhiteSpace($version)) { $version = $Matches.version }
        }
        if ([string]::IsNullOrWhiteSpace($extensionId)) { continue }
        $items += [pscustomobject]@{
            id = $extensionId
            version = $version
            path = ConvertTo-MHEASafePath -Path $extensionPath -Paths $script:MHEAPaths
            state = 'PRESENT'
        }
    }
    return @($items | Sort-Object id, version -Unique)
}

function Get-MHEAEditorDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    return @(
        [pscustomobject]@{ id = 'vscode'; name = 'VS Code'; commands = @('code.exe', 'code.cmd', 'code'); extensionRoot = (Join-Path $Paths.userHome '.vscode\extensions'); userRoot = (Join-Path $Paths.appData 'Code\User') },
        [pscustomobject]@{ id = 'cursor'; name = 'Cursor'; commands = @('cursor.exe', 'cursor.cmd', 'cursor'); extensionRoot = (Join-Path $Paths.userHome '.cursor\extensions'); userRoot = (Join-Path $Paths.appData 'Cursor\User') }
    )
}

function Get-MHEAEditorConfigCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Prefix
    )

    $candidates = @()
    $root = [string]$Definition.userRoot
    if (-not (Test-MHEADirectory -Path $root -Context $Context)) { return $candidates }
    $known = @(
        @{ relative = 'settings.json'; category = 'SETTINGS'; format = 'JSON' },
        @{ relative = 'keybindings.json'; category = 'KEYBINDINGS'; format = 'JSON' },
        @{ relative = 'profiles.json'; category = 'PROFILES'; format = 'JSON' }
    )
    foreach ($entry in $known) {
        $path = Join-Path $root $entry.relative
        if (Test-MHEAFile -Path $path -Context $Context) { $candidates += [pscustomobject]@{ path = $path; category = $entry.category; format = $entry.format; restorePolicy = 'REVIEW'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' } }
    }

    $snippets = Join-Path $root 'snippets'
    if (Test-MHEADirectory -Path $snippets -Context $Context) {
        foreach ($file in @(Get-ChildItem -LiteralPath $snippets -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.jsonc') } | Select-Object -First 64)) {
            if (Test-MHEAFile -Path $file.FullName -Context $Context) { $candidates += [pscustomobject]@{ path = $file.FullName; category = 'SNIPPETS:' + $file.Name.ToLowerInvariant(); format = (Get-MHEAFormat -Path $file.FullName); restorePolicy = 'REVIEW'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' } }
        }
    }

    $profileRoot = Join-Path $root 'profiles'
    foreach ($profile in @(Get-MHEAChildDirectories -Path $profileRoot -Context $Context -Limit 64)) {
        $profileName = [IO.Path]::GetFileName($profile)
        foreach ($entry in @(
            @{ relative = 'settings.json'; category = 'PROFILE_SETTINGS'; format = 'JSON' },
            @{ relative = 'keybindings.json'; category = 'PROFILE_KEYBINDINGS'; format = 'JSON' }
        )) {
            $path = Join-Path $profile $entry.relative
            if (Test-MHEAFile -Path $path -Context $Context) { $candidates += [pscustomobject]@{ path = $path; category = $entry.category + ':' + $profileName; format = $entry.format; restorePolicy = 'REVIEW'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' } }
        }
        $profileSnippets = Join-Path $profile 'snippets'
        if (Test-MHEADirectory -Path $profileSnippets -Context $Context) {
            foreach ($file in @(Get-ChildItem -LiteralPath $profileSnippets -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.jsonc') } | Select-Object -First 64)) {
                if (Test-MHEAFile -Path $file.FullName -Context $Context) { $candidates += [pscustomobject]@{ path = $file.FullName; category = 'PROFILE_SNIPPETS:' + $profileName.ToLowerInvariant() + ':' + $file.Name.ToLowerInvariant(); format = (Get-MHEAFormat -Path $file.FullName); restorePolicy = 'REVIEW'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' } }
            }
        }
    }
    return @($candidates)
}

function Get-MHEAAgentDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    return @(
        [pscustomobject]@{ id = 'codex'; name = 'Codex'; commands = @('codex'); roots = @((Join-Path $Paths.userHome '.codex'), (Join-Path $Paths.userHome '.agents')); skillRoots = @((Join-Path $Paths.userHome '.codex\skills'), (Join-Path $Paths.userHome '.agents\skills')); ruleRoots = @((Join-Path $Paths.userHome '.codex\rules'), (Join-Path $Paths.userHome '.agents\rules')); pluginRoots = @((Join-Path $Paths.userHome '.codex\plugins'), (Join-Path $Paths.userHome '.agents\plugins')); globalFiles = @([pscustomobject]@{ path = (Join-Path $Paths.userHome 'AGENTS.md'); category = 'RULES' }) },
        [pscustomobject]@{ id = 'claude-code'; name = 'Claude Code'; commands = @('claude'); roots = @((Join-Path $Paths.userHome '.claude')); skillRoots = @((Join-Path $Paths.userHome '.claude\skills')); ruleRoots = @((Join-Path $Paths.userHome '.claude\rules')); pluginRoots = @((Join-Path $Paths.userHome '.claude\plugins')); globalFiles = @([pscustomobject]@{ path = (Join-Path $Paths.userHome '.claude.json'); category = 'SETTINGS' }, [pscustomobject]@{ path = (Join-Path $Paths.userHome 'CLAUDE.md'); category = 'RULES' }) },
        [pscustomobject]@{ id = 'gemini-cli'; name = 'Gemini CLI'; commands = @('gemini'); roots = @((Join-Path $Paths.userHome '.gemini')); skillRoots = @((Join-Path $Paths.userHome '.gemini\skills')); ruleRoots = @((Join-Path $Paths.userHome '.gemini\rules')); pluginRoots = @((Join-Path $Paths.userHome '.gemini\extensions')); globalFiles = @([pscustomobject]@{ path = (Join-Path $Paths.userHome 'GEMINI.md'); category = 'RULES' }) },
        [pscustomobject]@{ id = 'opencode'; name = 'OpenCode'; commands = @('opencode'); roots = @((Join-Path $Paths.userHome '.config\opencode'), (Join-Path $Paths.userHome '.opencode')); skillRoots = @((Join-Path $Paths.userHome '.config\opencode\skills'), (Join-Path $Paths.userHome '.opencode\skills')); ruleRoots = @((Join-Path $Paths.userHome '.config\opencode\rules'), (Join-Path $Paths.userHome '.opencode\rules')); pluginRoots = @((Join-Path $Paths.userHome '.config\opencode\plugins'), (Join-Path $Paths.userHome '.opencode\plugins')); globalFiles = @() },
        [pscustomobject]@{ id = 'cursor-agent'; name = 'Cursor Agent'; commands = @('cursor-agent'); roots = @((Join-Path $Paths.userHome '.cursor'), (Join-Path $Paths.appData 'Cursor\User')); skillRoots = @((Join-Path $Paths.userHome '.cursor\skills')); ruleRoots = @((Join-Path $Paths.userHome '.cursor\rules')); pluginRoots = @((Join-Path $Paths.userHome '.cursor\plugins')); globalFiles = @([pscustomobject]@{ path = (Join-Path $Paths.userHome '.cursorrules'); category = 'RULES' }) }
    )
}

function Get-MHEAAgentFileDefinitions {
    return @(
        @{ names = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.cursorrules'); category = 'RULES'; format = 'MARKDOWN'; contentPolicy = 'REDACTED_COPY'; validation = 'MANUAL' },
        @{ names = @('config.toml'); category = 'SETTINGS'; format = 'TOML'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' },
        @{ names = @('settings.json', 'config.json', 'opencode.json'); category = 'SETTINGS'; format = 'JSON'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' },
        @{ names = @('mcp.json', '.mcp.json'); category = 'MCP'; format = 'JSON'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' },
        @{ names = @('mcp.toml'); category = 'MCP'; format = 'TOML'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' },
        @{ names = @('mcp.yaml', 'mcp.yml'); category = 'MCP'; format = 'YAML'; contentPolicy = 'REDACTED_COPY'; validation = 'NORMALIZED_CONFIG' },
        @{ names = @('hooks.json', 'tasks.json'); category = 'EXECUTABLE_RULES'; format = 'JSON'; contentPolicy = 'METADATA_ONLY'; validation = 'MANUAL' },
        @{ names = @('permissions.json', 'rules.json'); category = 'PERMISSIONS'; format = 'JSON'; contentPolicy = 'REDACTED_COPY'; validation = 'MANUAL' }
    )
}

function Test-MHEAExcludedName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '(?i)(^|[._-])(auth|credential|credentials|cookie|cookies|cache|cached|session|sessions|token|tokens|secret|secrets|storage|state|logs?|history)([._-]|$)' -or $Name -match '(?i)^(node_modules|\.git)$')
}

function Get-MHEAShallowManifestCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$Limit
    )

    $items = @()
    $manifestNames = @('SKILL.md', 'README.md', 'package.json', 'plugin.json', 'mcp.json', 'rules.json', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md')
    $roots = @(
        @{ path = $Definition.skillRoots; category = 'SKILLS' },
        @{ path = $Definition.ruleRoots; category = 'RULES' },
        @{ path = $Definition.pluginRoots; category = 'PLUGINS' }
    )
    foreach ($rootGroup in $roots) {
        foreach ($base in @($rootGroup.path)) {
            if ($items.Count -ge $Limit) { break }
            if (Test-MHEADirectory -Path $base -Context $Context) {
                $rootIdentity = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($base))
                if ([string]::IsNullOrWhiteSpace($rootIdentity)) { $rootIdentity = [IO.Path]::GetFileName($base) }
                try {
                    foreach ($filePath in [IO.Directory]::EnumerateFiles($base)) {
                        if ($items.Count -ge $Limit) { break }
                        $fileName = [IO.Path]::GetFileName($filePath)
                        if (Test-MHEAExcludedName -Name $fileName -or -not (Test-MHEAFile -Path $filePath -Context $Context)) { continue }
                        $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
                        if ($extension -notin @('.md', '.mdc', '.json', '.jsonc', '.toml', '.yaml', '.yml', '.txt')) { continue }
                        $items += [pscustomobject]@{
                            id = $Definition.id + ':' + $rootIdentity.ToLowerInvariant() + ':' + $rootGroup.category.ToLowerInvariant() + ':file:' + $fileName.ToLowerInvariant()
                            kind = 'manifest'
                            name = $fileName
                            path = ConvertTo-MHEASafePath -Path $filePath -Paths $script:MHEAPaths
                            sourcePath = $filePath
                            state = 'PRESENT'
                            parent = $Definition.id + ':' + $rootIdentity.ToLowerInvariant() + ':' + $rootGroup.category.ToLowerInvariant()
                            restorePolicy = 'REVIEW'
                        }
                    }
                } catch { }
            }
            foreach ($directory in @(Get-MHEAChildDirectories -Path $base -Context $Context -Limit $Limit)) {
                if ($items.Count -ge $Limit) { break }
                $directoryName = [IO.Path]::GetFileName($directory)
                if (Test-MHEAExcludedName -Name $directoryName) { continue }
                $rootIdentity = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($base))
                if ([string]::IsNullOrWhiteSpace($rootIdentity)) { $rootIdentity = [IO.Path]::GetFileName($base) }
                $manifestPaths = @()
                foreach ($name in $manifestNames) {
                    $candidate = Join-Path $directory $name
                    if (Test-MHEAFile -Path $candidate -Context $Context) { $manifestPaths += $candidate }
                }
                $items += [pscustomobject]@{
                    id = $Definition.id + ':' + $rootIdentity.ToLowerInvariant() + ':' + $rootGroup.category.ToLowerInvariant() + ':' + $directoryName
                    kind = $rootGroup.category.ToLowerInvariant().TrimEnd('S')
                    name = $directoryName
                    path = ConvertTo-MHEASafePath -Path $directory -Paths $script:MHEAPaths
                    sourcePath = $directory
                    state = 'PRESENT'
                    manifestPaths = @($manifestPaths | ForEach-Object { ConvertTo-MHEASafePath -Path $_ -Paths $script:MHEAPaths })
                    restorePolicy = 'REVIEW'
                }
                foreach ($manifestPath in $manifestPaths) {
                    if ($items.Count -ge $Limit) { break }
                    $items += [pscustomobject]@{
                        id = $Definition.id + ':manifest:' + ([IO.Path]::GetFileName($directory)) + ':' + ([IO.Path]::GetFileName($manifestPath))
                        kind = 'manifest'
                        name = [IO.Path]::GetFileName($manifestPath)
                        path = ConvertTo-MHEASafePath -Path $manifestPath -Paths $script:MHEAPaths
                        sourcePath = $manifestPath
                        state = 'PRESENT'
                        parent = $Definition.id + ':' + $rootIdentity.ToLowerInvariant() + ':' + $rootGroup.category.ToLowerInvariant() + ':' + $directoryName
                        restorePolicy = 'REVIEW'
                    }
                }
            }
        }
    }
    return @($items)
}

function Get-MHEAArtifactPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Category)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $executable = ($Category -eq 'EXECUTABLE_RULES' -or $Path -match '(?i)(^|[._-])(hook|hooks|task|tasks)([._-]|$)' -or $extension -in @('.ps1', '.cmd', '.bat', '.exe', '.sh'))
    if ($executable) {
        return [pscustomobject]@{ contentPolicy = 'METADATA_ONLY'; restorePolicy = 'REVIEW'; validation = 'MANUAL'; sensitivity = 'PRIVATE' }
    }
    $format = Get-MHEAFormat -Path $Path
    if ($null -eq $format) {
        return [pscustomobject]@{ contentPolicy = 'REDACTED_COPY'; restorePolicy = 'REVIEW'; validation = 'MANUAL'; sensitivity = 'UNKNOWN' }
    }
    return [pscustomobject]@{ contentPolicy = 'REDACTED_COPY'; restorePolicy = 'REVIEW'; validation = $(if ($format -in @('JSON', 'JSONC')) { 'NORMALIZED_CONFIG' } else { 'MANUAL' }); sensitivity = 'PRIVATE' }
}

function Get-MHEACollectionConfigArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$MaxConfigBytes
    )

    $policy = Get-MHEAArtifactPolicy -Path $SourcePath -Category $Category
    $format = Get-MHEAFormat -Path $SourcePath
    if ($null -eq $format) { $format = 'UNKNOWN' }
    $artifactPath = Get-MHEAArtifactPath -Prefix $Prefix -Path $SourcePath
    return [pscustomobject]@{
        value = New-MHEAArtifact -Context $Context -Paths $Paths -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate (ConvertTo-MHEASafePath -Path $SourcePath -Paths $Paths) -ContentPolicy $policy.contentPolicy -Sensitivity $policy.sensitivity -Format $format -ArtifactPath $artifactPath -RestorePolicy $policy.restorePolicy -ValidationStrategy $policy.validation -MaxConfigBytes $MaxConfigBytes
        policy = $policy
    }
}

function Get-MHEditorAgentCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $paths = Get-MHEAUserPaths -Context $Context
    $script:MHEAPaths = $paths
    $items = @()
    $artifactState = [pscustomobject]@{
        artifacts = New-Object System.Collections.ArrayList
        warnings = New-Object System.Collections.ArrayList
        seen = @{}
    }
    $maxConfigBytes = Get-MHEABudgetValue -Context $Context -Name 'maxConfigBytes' -Default 262144
    $maxArtifacts = Get-MHEABudgetValue -Context $Context -Name 'maxConfigArtifacts' -Default 64
    $maxEntries = [Math]::Min(512, [Math]::Max(16, (Get-MHEABudgetValue -Context $Context -Name 'maxDirectories' -Default 2000)))

    if ((Get-MHEARemainingMilliseconds -Context $Context) -le 0) {
        return New-MHDomainResult -Domain 'editors-agents' -Status 'UNAVAILABLE' -Items @() -Warnings @('COLLECTION_BUDGET_EXHAUSTED') -ErrorCode 'COLLECTION_BUDGET_EXHAUSTED' -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @()
    }
    if ([string]::IsNullOrWhiteSpace($paths.userHome)) {
        return New-MHDomainResult -Domain 'editors-agents' -Status 'UNAVAILABLE' -Items @() -Warnings @('USER_HOME_UNAVAILABLE') -ErrorCode 'USER_HOME_UNAVAILABLE' -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @()
    }

    $addArtifact = {
        param($Prefix, $Domain, $SourcePath, $Category, $Id)
        $key = $SourcePath.ToLowerInvariant()
        if ($artifactState.seen.ContainsKey($key)) { return (Get-MHEAArtifactMetadata -Artifact $artifactState.seen[$key] -Id $Id -SourcePath $SourcePath -Kind 'config' -Category $Category -RestorePolicy 'REVIEW' -Paths $paths) }
        $capturedBefore = 0
        try { $capturedBefore = [int](Get-MHEAContextValue -Context $Context -Name 'artifactBudget' -Default ([pscustomobject]@{ capturedCount = 0 })).capturedCount } catch { $capturedBefore = 0 }
        if (($artifactState.artifacts.Count + $capturedBefore) -ge $maxArtifacts) {
            [void]$artifactState.warnings.Add('CONFIG_ARTIFACT_LIMIT')
            $formatForLimit = Get-MHEAFormat -Path $SourcePath
            if ($null -eq $formatForLimit) { $formatForLimit = 'UNKNOWN' }
            $blocked = New-MHEABlockedArtifact -Id $Id -Domain $Domain -SourcePath $SourcePath -TargetPathCandidate (ConvertTo-MHEASafePath -Path $SourcePath -Paths $paths) -ContentPolicy 'REDACTED_COPY' -Sensitivity 'PRIVATE' -Format $formatForLimit -ArtifactPath (Get-MHEAArtifactPath -Prefix $Prefix -Path $SourcePath) -RestorePolicy 'REVIEW' -ValidationStrategy 'MANUAL' -BlockReason 'ARTIFACT_LIMIT' -Paths $paths
            [void]$artifactState.artifacts.Add($blocked)
            $artifactState.seen[$key] = $blocked
            return (Get-MHEAArtifactMetadata -Artifact $blocked -Id $Id -SourcePath $SourcePath -Kind 'config' -Category $Category -RestorePolicy 'REVIEW' -Paths $paths)
        }
        $artifactResult = Get-MHEACollectionConfigArtifact -Context $Context -Paths $paths -Prefix $Prefix -Domain $Domain -SourcePath $SourcePath -Category $Category -Id $Id -MaxConfigBytes $maxConfigBytes
        $artifact = $artifactResult.value
        [void]$artifactState.artifacts.Add($artifact)
        $artifactState.seen[$key] = $artifact
        $metadata = Get-MHEAArtifactMetadata -Artifact $artifact -Id $Id -SourcePath $SourcePath -Kind 'config' -Category $Category -RestorePolicy $artifactResult.policy.restorePolicy -Paths $paths
        if ($metadata.captureState -in @('BLOCKED', 'UNKNOWN')) { [void]$artifactState.warnings.Add(('CONFIG_' + $(if ($metadata.blockReason) { $metadata.blockReason } else { 'BLOCKED' }))) }
        return $metadata
    }

    $editorDefinitions = Get-MHEAEditorDefinitions -Paths $paths
    foreach ($definition in $editorDefinitions) {
        $commandFact = Get-MHEACommandFact -Context $Context -Names @($definition.commands)
        if ($commandFact.errorCode -and $commandFact.errorCode -ne 'NOT_FOUND') { [void]$artifactState.warnings.Add('EDITOR_PROCESS_UNAVAILABLE') }
        $extensionFacts = Get-MHEAExtensionFacts -Root $definition.extensionRoot -Context $Context -Limit $maxEntries
        $configFiles = @()
        foreach ($candidate in @(Get-MHEAEditorConfigCandidates -Definition $definition -Context $Context -Prefix $definition.id)) {
            $key = $candidate.path.ToLowerInvariant()
            if ($artifactState.seen.ContainsKey($key)) { $metadata = Get-MHEAArtifactMetadata -Artifact $artifactState.seen[$key] -Id ('editor:' + $definition.id + ':' + $candidate.category.ToLowerInvariant()) -SourcePath $candidate.path -Kind 'config' -Category $candidate.category -RestorePolicy $candidate.restorePolicy -Paths $paths }
            else { $metadata = & $addArtifact $definition.id 'editors' $candidate.path $candidate.category ('editor:' + $definition.id + ':' + $candidate.category.ToLowerInvariant()) }
            $configFiles += $metadata
        }
        $userRootPresent = Test-MHEADirectory -Path $definition.userRoot -Context $Context
        $extensionRootPresent = Test-MHEADirectory -Path $definition.extensionRoot -Context $Context
        $state = if ($commandFact.state -eq 'PRESENT' -or $userRootPresent -or $extensionRootPresent) { 'PRESENT' } else { 'ABSENT' }
        $status = if ($commandFact.status -eq 'FOUND') { 'FOUND' } elseif ($commandFact.status -eq 'NOT_TESTED') { 'NOT_TESTED' } elseif ($userRootPresent -or $extensionRootPresent) { 'CONFIG_ONLY' } elseif ($commandFact.state -eq 'PRESENT') { 'UNKNOWN' } else { 'NOT_FOUND' }
        $items += [pscustomobject]@{
            id = 'editor:' + $definition.id
            domain = 'editors'
            kind = 'editor'
            name = $definition.name
            state = $state
            status = $status
            command = $commandFact.command
            executablePath = ConvertTo-MHEASafePath -Path $commandFact.path -Paths $paths
            version = $commandFact.version
            extensionRoot = if ($extensionRootPresent) { ConvertTo-MHEASafePath -Path $definition.extensionRoot -Paths $paths } else { $null }
            extensions = @($extensionFacts)
            configFiles = @($configFiles)
            launchStatus = 'NOT_TESTED'
            restorePolicy = 'REVIEW'
        }
    }

    $agentDefinitions = Get-MHEAAgentDefinitions -Paths $paths
    foreach ($definition in $agentDefinitions) {
        $commandFact = Get-MHEACommandFact -Context $Context -Names @($definition.commands)
        if ($commandFact.errorCode -and $commandFact.errorCode -ne 'NOT_FOUND') { [void]$artifactState.warnings.Add('AGENT_PROCESS_UNAVAILABLE') }
        $presentRoots = @($definition.roots | Where-Object { Test-MHEADirectory -Path $_ -Context $Context })
        $agentFiles = @()
        foreach ($root in $definition.roots) {
            if (-not (Test-MHEADirectory -Path $root -Context $Context)) { continue }
            foreach ($fileDefinition in Get-MHEAAgentFileDefinitions) {
                foreach ($name in $fileDefinition.names) {
                    if (Test-MHEAExcludedName -Name $name) { continue }
                    $candidate = Join-Path $root $name
                    if (-not (Test-MHEAFile -Path $candidate -Context $Context)) { continue }
                    $category = [string]$fileDefinition.category
                    $rootName = [IO.Path]::GetFileName($root)
                    $metadata = & $addArtifact $definition.id 'agents' $candidate $category ('agent:' + $definition.id + ':' + $rootName.ToLowerInvariant() + ':' + $name.ToLowerInvariant().TrimStart('.'))
                    $agentFiles += $metadata
                }
            }
        }
        foreach ($globalFile in @($definition.globalFiles)) {
            $globalPath = [string]$globalFile.path
            if (-not (Test-MHEAFile -Path $globalPath -Context $Context)) { continue }
            $globalName = [IO.Path]::GetFileName($globalPath)
            if (Test-MHEAExcludedName -Name $globalName) { continue }
            $metadata = & $addArtifact $definition.id 'agents' $globalPath ([string]$globalFile.category) ('agent:' + $definition.id + ':global:' + $globalName.ToLowerInvariant())
            $agentFiles += $metadata
        }
        $manifestItems = @(Get-MHEAShallowManifestCandidates -Definition $definition -Context $Context -Limit $maxEntries)
        foreach ($manifest in $manifestItems | Where-Object { $_.kind -ne 'manifest' }) {
            $directoryCategory = if ($manifest.id -match ':plugins:') { 'PLUGINS' } elseif ($manifest.id -match ':rules:') { 'RULES' } else { 'SKILLS' }
            $agentFiles += [pscustomobject]@{
                id = [string]$manifest.id
                kind = [string]$manifest.kind
                category = $directoryCategory
                sourcePath = ConvertTo-MHEASafePath -Path ([string]$manifest.sourcePath) -Paths $paths
                state = 'PRESENT'
                captureState = 'METADATA_ONLY'
                redactionStatus = 'NOT_APPLICABLE'
                blockReason = $null
                restorePolicy = 'REVIEW'
                artifactId = $null
                artifactPath = $null
                manifestPaths = @($manifest.manifestPaths)
            }
        }
        foreach ($manifest in $manifestItems | Where-Object { $_.kind -eq 'manifest' }) {
            $manifestPath = [string]$manifest.sourcePath
            if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-MHEAFile -Path $manifestPath -Context $Context)) { continue }
            $category = if ($manifest.id -match ':plugins:') { 'PLUGINS' } elseif ($manifest.id -match ':rules:') { 'RULES' } else { 'SKILLS' }
            $manifestName = [IO.Path]::GetFileName($manifestPath)
            if (Test-MHEAExcludedName -Name $manifestName) { continue }
            $manifestParent = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($manifestPath))
            $manifestRootIdentity = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($manifestPath)))
            $metadata = & $addArtifact $definition.id 'agents' $manifestPath $category ('agent:' + $definition.id + ':' + $manifestRootIdentity.ToLowerInvariant() + ':' + $manifestParent.ToLowerInvariant() + ':' + $manifestName.ToLowerInvariant())
            $agentFiles += $metadata
        }
        $rootsPresent = $presentRoots.Count -gt 0
        $state = if ($rootsPresent -or $commandFact.state -eq 'PRESENT') { 'PRESENT' } else { 'ABSENT' }
        $status = if ($commandFact.status -eq 'FOUND') { 'FOUND' } elseif ($commandFact.status -eq 'NOT_TESTED') { 'NOT_TESTED' } elseif ($rootsPresent) { 'CONFIG_ONLY' } elseif ($commandFact.state -eq 'PRESENT') { 'UNKNOWN' } else { 'NOT_FOUND' }
        $items += [pscustomobject]@{
            id = 'agent:' + $definition.id
            domain = 'agents'
            kind = 'agent'
            name = $definition.name
            state = $state
            status = $status
            command = $commandFact.command
            executablePath = ConvertTo-MHEASafePath -Path $commandFact.path -Paths $paths
            version = $commandFact.version
            configRoots = @($presentRoots | ForEach-Object { ConvertTo-MHEASafePath -Path $_ -Paths $paths })
            configFiles = @($agentFiles)
            terminalIntegration = 'UNKNOWN'
            auth = 'REAUTHENTICATE'
            excludedCategories = @('AUTH', 'CREDENTIALS', 'COOKIES', 'CACHE', 'TOKENS')
            restorePolicy = 'REVIEW'
        }
    }

    if ((Get-MHEARemainingMilliseconds -Context $Context) -le 0) { [void]$artifactState.warnings.Add('COLLECTION_BUDGET_EXHAUSTED') }
    $uniqueWarnings = @($artifactState.warnings | Sort-Object -Unique)
    $status = if ($uniqueWarnings.Count -gt 0) { 'PARTIAL' } else { 'OK' }
    return New-MHDomainResult -Domain 'editors-agents' -Status $status -Items @($items) -Warnings $uniqueWarnings -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @($artifactState.artifacts)
}
