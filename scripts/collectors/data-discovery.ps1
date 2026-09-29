Set-StrictMode -Version Latest

function Get-MHDDProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-MHDDPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1024 -or $Path -match '[\r\n]') { return $null }
    if (Test-MHSecretText -Text $Path) { return $null }
    try { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\') }
    catch { return $null }
}

function Get-MHDDPathId {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $value = $Kind.ToLowerInvariant() + '|' + $Path.ToLowerInvariant()
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-', '').ToLowerInvariant()
        return 'discovery:' + $Kind.ToLowerInvariant() + ':' + $hash.Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Test-MHDDExcluded {
    param([string]$Path, [string[]]$Excludes)
    foreach ($exclude in $Excludes) {
        $safe = ConvertTo-MHDDPath -Path $exclude
        if ($safe -and ($Path.Equals($safe, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith(($safe.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase))) { return $true }
    }
    return $false
}

function Test-MHDDReparse {
    param([Parameter(Mandatory)][string]$Path)
    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) }
    catch { return $true }
}

function Confirm-MHDDGitRepository {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)

    $result = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $Path, 'rev-parse', '--is-inside-work-tree') -Context $Context
    if (-not $result.found) { $result = Invoke-MHSafeProcess -Name 'git' -Arguments @('-C', $Path, 'rev-parse', '--is-inside-work-tree') -Context $Context }
    if ($result.found -and -not $result.errorCode -and -not $result.timedOut -and $result.exitCode -eq 0 -and $result.stdout.Trim() -eq 'true') { return 'PRESENT' }
    if (-not $result.found -or $result.timedOut -or $result.errorCode -in @('OUTPUT_LIMIT', 'CANCELLED', 'TIMEOUT')) { return 'UNKNOWN' }
    return 'ABSENT'
}

function Add-MHDDCandidate {
    param(
        [System.Collections.ArrayList]$Items,
        [System.Collections.IDictionary]$Seen,
        [string]$Kind,
        [string]$Path,
        [string]$State = 'PRESENT',
        [string]$Evidence,
        [string]$Reason
    )
    $safePath = ConvertTo-MHDDPath -Path $Path
    if (-not $safePath) { return }
    $key = $Kind.ToLowerInvariant() + '|' + $safePath.ToLowerInvariant()
    if ($Seen.Contains($key)) { return }
    $Seen[$key] = $true
    [void]$Items.Add([pscustomobject]@{
        id = Get-MHDDPathId -Kind $Kind -Path $safePath
        type = $Kind
        state = $State
        sourcePath = $safePath
        targetPathCandidate = $null
        ownership = 'USER'
        backupEvidence = 'UNKNOWN'
        transferAction = 'REVIEW'
        verification = 'NOT_TESTED'
        evidence = $Evidence
        reason = $Reason
        restorePolicy = 'REVIEW'
    })
}

function ConvertFrom-MHDDWorkspaceUri {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    try {
        $uri = $null
        if ([Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -and $uri.IsFile) { $text = $uri.LocalPath }
        elseif ($text -match '^(?i:file://)') { return $null }
        $path = ConvertTo-MHDDPath -Path ([Uri]::UnescapeDataString($text))
        if (-not $path -or $path.StartsWith('\\', [StringComparison]::Ordinal)) { return $null }
        return $path
    } catch { return $null }
}

function Get-MHDDWorkspaceCandidates {
    param([Parameter(Mandatory)]$Context, [System.Collections.ArrayList]$Items, [System.Collections.IDictionary]$Seen)

    $appData = Get-MHDDProperty -Object $Context -Name 'appData' -Default $env:APPDATA
    if ([string]::IsNullOrWhiteSpace([string]$appData)) { return @() }
    $maxDirectories = [int](Get-MHDDProperty -Object $Context.budgets -Name 'maxDirectories' -Default 2000)
    $maxConfigBytes = [long](Get-MHDDProperty -Object $Context.budgets -Name 'maxConfigBytes' -Default 262144)
    $workspaceLimit = [Math]::Min($maxDirectories, 256)
    $count = 0
    $warnings = @()

    foreach ($editor in @('Code', 'Cursor')) {
        $storageRoot = Join-Path $appData ($editor + '\User\workspaceStorage')
        if (-not (Test-Path -LiteralPath $storageRoot -PathType Container) -or (Test-MHDDReparse -Path $storageRoot)) { continue }
        try { $children = [IO.Directory]::EnumerateDirectories($storageRoot).GetEnumerator() }
        catch { $warnings += 'WORKSPACE_STORAGE_UNAVAILABLE'; continue }
        try {
            while ($count -lt $workspaceLimit -and (Get-MHRemainingBudgetMilliseconds -Context $Context) -gt 0) {
                if (-not $children.MoveNext()) { break }
                $count++
                $workspaceRoot = [string]$children.Current
                if (Test-MHDDReparse -Path $workspaceRoot) { continue }
                $workspaceFile = Join-Path $workspaceRoot 'workspace.json'
                if (-not (Test-Path -LiteralPath $workspaceFile -PathType Leaf) -or (Test-MHDDReparse -Path $workspaceFile)) { continue }
                try {
                    $file = Get-Item -LiteralPath $workspaceFile -Force -ErrorAction Stop
                    if ([long]$file.Length -gt $maxConfigBytes) { $warnings += 'WORKSPACE_METADATA_TOO_LARGE'; continue }
                    $workspaceText = Read-MHBoundedUtf8Text -Path $workspaceFile -MaxBytes $maxConfigBytes
                    $record = ConvertFrom-Json -InputObject $workspaceText -ErrorAction Stop
                    $candidate = Get-MHDDProperty -Object $record -Name 'folder'
                    if (-not $candidate) { $candidate = Get-MHDDProperty -Object $record -Name 'workspace' }
                    $path = ConvertFrom-MHDDWorkspaceUri -Value ([string]$candidate)
                    if ($path -and (Test-Path -LiteralPath $path -PathType Container) -and -not (Test-MHDDReparse -Path $path)) {
                        Add-MHDDCandidate -Items $Items -Seen $Seen -Kind 'EDITOR_WORKSPACE' -Path $path -Evidence ($editor.ToUpperInvariant() + '_WORKSPACE_JSON') -Reason 'Editor workspace path metadata; directory was not traversed from this hint.'
                    }
                } catch { $warnings += 'WORKSPACE_METADATA_UNAVAILABLE' }
            }
            if ($count -ge $workspaceLimit -or (Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0) {
                $hasUnexaminedWorkspace = $false
                try { $hasUnexaminedWorkspace = [bool]$children.MoveNext() } catch { $warnings += 'WORKSPACE_STORAGE_UNAVAILABLE'; $hasUnexaminedWorkspace = $true }
                if ($hasUnexaminedWorkspace) { $warnings += 'WORKSPACE_STORAGE_LIMIT_REACHED' }
            }
        } finally { $children.Dispose() }
    }
    return @($warnings | Sort-Object -Unique)
}

function Get-MHDataDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string[]]$Roots = @(),
        [AllowNull()][string]$UserHome
    )

    $items = New-Object System.Collections.ArrayList
    $seen = @{}
    $warnings = New-Object System.Collections.ArrayList
    $excludes = @($Context.excludes)
    $maxDirectories = [int]$Context.budgets.maxDirectories
    $maxQueuedDirectories = [int](Get-MHDDProperty -Object $Context.budgets -Name 'maxQueuedDirectories' -Default $maxDirectories)
    $maxQueuedDirectories = [Math]::Max(1, [Math]::Min($maxQueuedDirectories, 10000))
    $maxFiles = [int](Get-MHDDProperty -Object $Context.budgets -Name 'maxFilesToInspect' -Default 5000)
    $maxCandidates = [int](Get-MHDDProperty -Object $Context.budgets -Name 'maxDiscoveredItems' -Default 512)
    $maxDepth = [int]$Context.maxDepth
    $visitedDirectories = 0
    $queuedDirectories = 0
    $inspectedFiles = 0
    $truncated = $false
    $knownMarkers = @('package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'pom.xml', 'CMakeLists.txt', 'requirements.txt', 'Pipfile', '*.sln', '*.csproj', '*.fsproj', '*.vcxproj')
    $composeMarkers = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')
    $databaseExtensions = @('.db', '.sqlite', '.sqlite3', '.mdb')
    $excludedNames = @('.git', 'node_modules', '.venv', 'venv', 'bin', 'obj', 'vendor', 'target', '.cache', '.npm', '.pnpm-store', 'caches', 'cache', 'logs', 'log')

    $workspaceWarnings = @(Get-MHDDWorkspaceCandidates -Context $Context -Items $items -Seen $seen)
    foreach ($warning in $workspaceWarnings) { [void]$warnings.Add($warning) }

    foreach ($rootValue in $Roots) {
        if ((Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0 -or $visitedDirectories -ge $maxDirectories -or $items.Count -ge $maxCandidates) { $truncated = $true; break }
        $root = ConvertTo-MHDDPath -Path ([string]$rootValue)
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container) -or (Test-MHDDReparse -Path $root) -or (Test-MHDDExcluded -Path $root -Excludes $excludes)) { continue }
        if ($queuedDirectories -ge $maxQueuedDirectories) { $truncated = $true; [void]$warnings.Add('DIRECTORY_QUEUE_LIMIT'); break }

        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([pscustomobject]@{ path = $root; depth = 0 })
        $queuedDirectories++
        while ($queue.Count -gt 0) {
            if ((Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0 -or $visitedDirectories -ge $maxDirectories -or $inspectedFiles -ge $maxFiles -or $items.Count -ge $maxCandidates) {
                $truncated = $true
                break
            }
            $entry = $queue.Dequeue()
            $path = [string]$entry.path
            if (Test-MHDDExcluded -Path $path -Excludes $excludes) { continue }
            $visitedDirectories++
            $gitMarker = Join-Path $path '.git'
            $gitMarkerPresent = Test-Path -LiteralPath $gitMarker
            $verifiedGit = $false
            if ($gitMarkerPresent) {
                if (Test-MHDDReparse -Path $gitMarker) { [void]$warnings.Add('GIT_MARKER_REPARSE_SKIPPED') }
                else {
                    $gitState = Confirm-MHDDGitRepository -Path $path -Context $Context
                    if ($gitState -eq 'PRESENT') {
                        Add-MHDDCandidate -Items $items -Seen $seen -Kind 'GIT_REPOSITORY' -Path $path -Evidence 'GIT_REV_PARSE_CONFIRMED' -Reason 'Local Git work tree confirmed without fetching remote data.'
                        $verifiedGit = $true
                    } else {
                        Add-MHDDCandidate -Items $items -Seen $seen -Kind 'GIT_REPOSITORY_CANDIDATE' -Path $path -State 'UNKNOWN' -Evidence 'GIT_MARKER_UNVERIFIED' -Reason 'A .git marker exists, but Git did not confirm a readable work tree.'
                        [void]$warnings.Add('GIT_MARKER_UNVERIFIED')
                    }
                }
            }

            $hasObsidian = Test-Path -LiteralPath (Join-Path $path '.obsidian') -PathType Container
            if ($hasObsidian -and -not (Test-MHDDReparse -Path (Join-Path $path '.obsidian'))) {
                Add-MHDDCandidate -Items $items -Seen $seen -Kind 'OBSIDIAN_VAULT' -Path $path -Evidence 'OBSIDIAN_CONFIG_DIRECTORY' -Reason 'Vault config directory exists; Vault contents were not read.'
            }

            $projectMarkers = @()
            $composeFound = $false
            try {
                $entries = [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
                $localEntries = 0
                try {
                    while ($localEntries -lt 512 -and $inspectedFiles -lt $maxFiles -and $entries.MoveNext() -and (Get-MHRemainingBudgetMilliseconds -Context $Context) -gt 0) {
                        $localEntries++
                        $candidate = [string]$entries.Current
                        if (Test-MHDDReparse -Path $candidate) { continue }
                        $isDirectory = $false
                        try { $isDirectory = [IO.Directory]::Exists($candidate) } catch { continue }
                        $leaf = [IO.Path]::GetFileName($candidate)
                        if ($isDirectory) {
                            if ($leaf -eq '.obsidian') { continue }
                            if ($leaf -in $excludedNames) { continue }
                            if ([int]$entry.depth -lt $maxDepth) {
                                if ($queuedDirectories -lt $maxQueuedDirectories) {
                                    $queue.Enqueue([pscustomobject]@{ path = $candidate; depth = ([int]$entry.depth + 1) })
                                    $queuedDirectories++
                                } else {
                                    $truncated = $true
                                    [void]$warnings.Add('DIRECTORY_QUEUE_LIMIT')
                                }
                            }
                            continue
                        }
                        $inspectedFiles++
                        if ($composeMarkers -contains $leaf.ToLowerInvariant()) { $composeFound = $true }
                        elseif ($knownMarkers -contains $leaf -or $leaf -match '(?i)\.(sln|csproj|fsproj|vcxproj)$') { $projectMarkers += $leaf }
                        if ([IO.Path]::GetExtension($leaf).ToLowerInvariant() -in $databaseExtensions) {
                            Add-MHDDCandidate -Items $items -Seen $seen -Kind 'LOCAL_DATABASE' -Path $candidate -Evidence 'DATABASE_FILE_NAME' -Reason 'Local database candidate; database contents were not opened or copied.'
                        }
                    }
                } finally { $entries.Dispose() }
                if ($localEntries -ge 512) { $truncated = $true; [void]$warnings.Add('DIRECTORY_ENTRY_LIMIT') }
            } catch { [void]$warnings.Add('DIRECTORY_ENUMERATION_PARTIAL') }

            if ($composeFound) { Add-MHDDCandidate -Items $items -Seen $seen -Kind 'COMPOSE_PROJECT' -Path $path -Evidence 'COMPOSE_MANIFEST' -Reason 'Compose manifest found; volume contents and registry credentials were not read.' }
            if (-not $verifiedGit -and -not $gitMarkerPresent -and $projectMarkers.Count -gt 0) {
                Add-MHDDCandidate -Items $items -Seen $seen -Kind 'NON_GIT_PROJECT' -Path $path -Evidence ('PROJECT_MARKERS:' + (@($projectMarkers | Sort-Object -Unique | Select-Object -First 5) -join ',')) -Reason 'Project marker filenames were found; project file contents were not read.'
            }
        }
        if ($queue.Count -gt 0) { $truncated = $true }
        if ($truncated) { break }
    }

    if ($truncated) { [void]$warnings.Add('DATA_DISCOVERY_LIMIT_REACHED') }
    $uniqueWarnings = @($warnings | Sort-Object -Unique)
    $status = if ($uniqueWarnings.Count -gt 0 -or $truncated) { 'PARTIAL' } else { 'OK' }
    return New-MHDomainResult -Domain 'data-discovery' -Status $status -Items @($items.ToArray()) -Warnings $uniqueWarnings -Provenance 'BOUNDED_LOCAL_METADATA_DISCOVERY'
}
