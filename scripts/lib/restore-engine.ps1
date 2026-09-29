Set-StrictMode -Version Latest

function ConvertTo-MHRestoreCanonicalValue {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'RESTORE_PLAN_LIMIT' }
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) { $ordered[[string]$key] = ConvertTo-MHRestoreCanonicalValue -Value $Value[$key] -Depth ($Depth + 1) }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) { $items += ConvertTo-MHRestoreCanonicalValue -Value $item -Depth ($Depth + 1) }
        return ,$items
    }
    $result = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $result[$property.Name] = ConvertTo-MHRestoreCanonicalValue -Value $property.Value -Depth ($Depth + 1)
    }
    return [pscustomobject]$result
}

function Get-MHRestoreSnapshotSha256 {
    param([Parameter(Mandatory)]$Snapshot)
    $snapshotValue = [ordered]@{}
    foreach ($property in $Snapshot.PSObject.Properties) {
        if ($property.Name -in @('snapshotId', 'collectedAt')) { continue }
        if ($property.Name -ne 'collection' -or $null -eq $property.Value) { $snapshotValue[$property.Name] = $property.Value; continue }
        $collectionValue = [ordered]@{}
        foreach ($collectionProperty in $property.Value.PSObject.Properties) {
            if ($collectionProperty.Name -ne 'domainStatus' -or $null -eq $collectionProperty.Value) { $collectionValue[$collectionProperty.Name] = $collectionProperty.Value; continue }
            $statuses = [ordered]@{}
            foreach ($statusProperty in $collectionProperty.Value.PSObject.Properties) {
                $statusValue = [ordered]@{}
                foreach ($field in $statusProperty.Value.PSObject.Properties) {
                    if ($field.Name -ne 'collectedAt') { $statusValue[$field.Name] = $field.Value }
                }
                $statuses[$statusProperty.Name] = [pscustomobject]$statusValue
            }
            $collectionValue.domainStatus = [pscustomobject]$statuses
        }
        $snapshotValue.collection = [pscustomobject]$collectionValue
    }
    $canonical = ConvertTo-MHRestoreCanonicalValue -Value ([pscustomobject]$snapshotValue)
    $json = ConvertTo-Json -InputObject $canonical -Depth 64 -Compress
    return Get-MHTextSha256 -Text $json
}

function Get-MHRestoreFileSha256 {
    param([Parameter(Mandatory)][string]$Path, [ValidateRange(1, 41943040)][long]$MaxBytes = 41943040)
    [void](Assert-MHNoReparseAncestors -Path $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RESTORE_TARGET_UNSAFE' }
    if ([long]$item.Length -gt $MaxBytes) { throw 'RESTORE_FILE_SIZE_LIMIT' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    try {
        $total = 0L
        while ($true) {
            $readLimit = [int][Math]::Min([long]$buffer.Length, ($MaxBytes - $total) + 1)
            $count = $stream.Read($buffer, 0, $readLimit)
            if ($count -le 0) { break }
            $total += $count
            if ($total -gt $MaxBytes) { throw 'RESTORE_FILE_SIZE_LIMIT' }
            $memory.Write($buffer, 0, $count)
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($memory.ToArray()))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    } finally { $stream.Dispose(); $memory.Dispose() }
}

function Write-MHRestoreTemporaryContent {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-MHRestoreTargetPath {
    param([Parameter(Mandatory)][string]$Candidate, [Parameter(Mandatory)]$Context)
    if ($Candidate.Length -gt 1024 -or $Candidate -match '[\r\n\0]') { throw 'RESTORE_TARGET_UNSUPPORTED' }
    if ($Candidate -notmatch '^%(?<root>USERPROFILE|APPDATA|LOCALAPPDATA)%[\\/](?<relative>.+)$') { throw 'RESTORE_TARGET_UNSUPPORTED' }
    $rootName = $Matches.root
    $relative = $Matches.relative.Replace('/', '\')
    if (@($relative -split '\\' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or $relative -match '[:\*\?"<>\|]') { throw 'RESTORE_TARGET_UNSUPPORTED' }
    $rootValue = switch ($rootName) {
        'USERPROFILE' { Get-MHField -Object $Context -Name 'userProfile' -Default $env:USERPROFILE }
        'APPDATA' { Get-MHField -Object $Context -Name 'appData' -Default $env:APPDATA }
        'LOCALAPPDATA' { Get-MHField -Object $Context -Name 'localAppData' -Default $env:LOCALAPPDATA }
    }
    if ([string]::IsNullOrWhiteSpace([string]$rootValue) -or ([string]$rootValue).StartsWith('\\', [StringComparison]::Ordinal)) { throw 'RESTORE_TARGET_UNSUPPORTED' }
    $root = [IO.Path]::GetFullPath([string]$rootValue).TrimEnd('\') + '\'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'RESTORE_TARGET_ROOT_MISSING' }
    [void](Assert-MHNoReparseAncestors -Path $root)
    $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if ($target.Length -gt 1024 -or -not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'RESTORE_TARGET_UNSUPPORTED' }
    [void](Assert-MHNoReparseAncestors -Path $target)
    $rootWithoutSlash = $root.TrimEnd('\')
    $relativeTarget = $target.Substring($rootWithoutSlash.Length).TrimStart('\')
    $parent = Split-Path -Parent $target
    $targetState = 'ABSENT'
    $targetSha256 = $null
    if (Test-Path -LiteralPath $target) {
        $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($targetItem.PSIsContainer -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RESTORE_TARGET_UNSAFE' }
        $targetState = 'PRESENT'
        $targetSha256 = Get-MHRestoreFileSha256 -Path $target
    }
    return [pscustomobject]@{ root = $rootWithoutSlash; targetPath = $target; parentPath = $parent; relativePath = $relativeTarget; targetState = $targetState; targetSha256 = $targetSha256 }
}

function Get-MHRestorePlanSha256 {
    param([Parameter(Mandatory)]$Plan)
    $actions = @()
    foreach ($action in @(Get-MHField -Object $Plan -Name 'actions' -Default @() | Sort-Object actionId)) {
        $actions += [pscustomobject]@{
            actionId = Get-MHField -Object $action -Name 'actionId'
            componentId = Get-MHField -Object $action -Name 'componentId'
            actionType = Get-MHField -Object $action -Name 'actionType'
            proposedAction = Get-MHField -Object $action -Name 'proposedAction'
            status = Get-MHField -Object $action -Name 'status'
            approvalState = Get-MHField -Object $action -Name 'approvalState'
            targetPath = Get-MHField -Object $action -Name 'targetPath'
            targetPathCandidate = Get-MHField -Object $action -Name 'targetPathCandidate'
            targetState = Get-MHField -Object $action -Name 'targetState'
            targetSha256 = Get-MHField -Object $action -Name 'targetSha256'
            backupPath = Get-MHField -Object $action -Name 'backupPath'
            sourceArtifactPath = Get-MHField -Object $action -Name 'sourceArtifactPath'
            sourceArtifactSha256 = Get-MHField -Object $action -Name 'sourceArtifactSha256'
            dependsOn = @(Get-MHField -Object $action -Name 'dependsOn' -Default @())
            reason = Get-MHField -Object $action -Name 'reason'
        }
    }
    $payload = [pscustomobject]@{
        schemaVersion = Get-MHField -Object $Plan -Name 'schemaVersion'
        planStatus = Get-MHField -Object $Plan -Name 'status'
        sourceSnapshotId = Get-MHField -Object $Plan -Name 'sourceSnapshotId'
        sourceSnapshotSha256 = Get-MHField -Object $Plan -Name 'sourceSnapshotSha256'
        destinationSnapshotSha256 = Get-MHField -Object $Plan -Name 'destinationSnapshotSha256'
        actions = @($actions)
    }
    $canonical = ConvertTo-MHRestoreCanonicalValue -Value $payload
    return Get-MHTextSha256 -Text (ConvertTo-Json -InputObject $canonical -Depth 64 -Compress)
}

function Set-MHRestorePlanActionField {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)][string]$Name, $Value)
    $Action | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Test-MHRestorePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $actions = @(Get-MHField -Object $Plan -Name 'actions' -Default @())
    if ($actions.Count -gt 4096) { return [pscustomobject]@{ status = 'BLOCKED'; issues = @('PLAN_ACTION_LIMIT'); orderedActionIds = @() } }
    $issues = New-Object System.Collections.Generic.List[string]
    $byId = @{}
    $targetOwners = @{}
    foreach ($action in $actions) {
        $actionId = [string](Get-MHField -Object $action -Name 'actionId')
        if ([string]::IsNullOrWhiteSpace($actionId) -or $byId.ContainsKey($actionId)) { $issues.Add('ACTION_ID_INVALID_OR_DUPLICATE'); if ($actionId) { Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED' }; continue }
        $byId[$actionId] = $action
        $actionType = [string](Get-MHField -Object $action -Name 'actionType')
        if ($actionType -notin @('COPY_CONFIG_ARTIFACT', 'REVIEW_ONLY')) { Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $action -Name 'reason' -Value 'ACTION_TYPE_NOT_ALLOWED'; $issues.Add('ACTION_TYPE_NOT_ALLOWED') }
        if ($actionType -eq 'COPY_CONFIG_ARTIFACT') {
            $target = [string](Get-MHField -Object $action -Name 'targetPath')
            if ([string]::IsNullOrWhiteSpace($target)) { Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $action -Name 'reason' -Value 'RESTORE_TARGET_UNSUPPORTED'; $issues.Add('RESTORE_TARGET_UNSUPPORTED'); continue }
            $key = [IO.Path]::GetFullPath($target).ToLowerInvariant()
            if ($targetOwners.ContainsKey($key)) {
                Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $action -Name 'reason' -Value 'RESTORE_TARGET_COLLISION'
                Set-MHRestorePlanActionField -Action $targetOwners[$key] -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $targetOwners[$key] -Name 'reason' -Value 'RESTORE_TARGET_COLLISION'
                $issues.Add('RESTORE_TARGET_COLLISION')
            } else { $targetOwners[$key] = $action }
        }
    }

    $indegree = @{}
    $dependents = @{}
    foreach ($action in $actions) {
        $actionId = [string](Get-MHField -Object $action -Name 'actionId')
        if (-not $byId.ContainsKey($actionId)) { continue }
        $validDependencies = @()
        foreach ($dependency in @(Get-MHField -Object $action -Name 'dependsOn' -Default @())) {
            $dependencyId = [string]$dependency
            if (-not $byId.ContainsKey($dependencyId)) { Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $action -Name 'reason' -Value 'RESTORE_DEPENDENCY_MISSING'; $issues.Add('RESTORE_DEPENDENCY_MISSING'); continue }
            if ($dependencyId -eq $actionId) { Set-MHRestorePlanActionField -Action $action -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $action -Name 'reason' -Value 'RESTORE_DEPENDENCY_CYCLE'; $issues.Add('RESTORE_DEPENDENCY_CYCLE'); continue }
            $validDependencies += $dependencyId
            if (-not $dependents.ContainsKey($dependencyId)) { $dependents[$dependencyId] = New-Object System.Collections.ArrayList }
            [void]$dependents[$dependencyId].Add($actionId)
        }
        $indegree[$actionId] = $validDependencies.Count
    }
    $ready = New-Object System.Collections.Queue
    foreach ($actionId in @($byId.Keys | Sort-Object)) {
        if ($indegree.ContainsKey($actionId) -and $indegree[$actionId] -eq 0) { $ready.Enqueue($actionId) }
    }
    $ordered = @()
    while ($ready.Count -gt 0) {
        $actionId = [string]$ready.Dequeue()
        $ordered += $actionId
        if ($dependents.ContainsKey($actionId)) {
            foreach ($dependentId in @($dependents[$actionId])) {
                $indegree[$dependentId]--
                if ($indegree[$dependentId] -eq 0) { $ready.Enqueue([string]$dependentId) }
            }
        }
    }
    if ($ordered.Count -lt $byId.Count) {
        foreach ($actionId in $byId.Keys) {
            if ($ordered -notcontains $actionId) { Set-MHRestorePlanActionField -Action $byId[$actionId] -Name 'status' -Value 'BLOCKED'; Set-MHRestorePlanActionField -Action $byId[$actionId] -Name 'reason' -Value 'RESTORE_DEPENDENCY_CYCLE' }
        }
        $issues.Add('RESTORE_DEPENDENCY_CYCLE')
    }
    $blockedActions = @($actions | Where-Object { $_.status -eq 'BLOCKED' })
    return [pscustomobject]@{ status = if ($issues.Count -gt 0 -or $blockedActions.Count -gt 0) { 'BLOCKED' } else { 'READY' }; issues = @($issues | Sort-Object -Unique); orderedActionIds = @($ordered) }
}

function Get-MHRestoreAllowedGitSettings {
    param([object[]]$Settings = @())
    $allowed = @('user.name', 'user.email', 'core.autocrlf', 'core.eol', 'init.defaultbranch', 'pull.rebase', 'push.default')
    $grouped = @{}
    foreach ($setting in $Settings) {
        if ([string](Get-MHField -Object $setting -Name 'scope') -ne 'global' -or [string](Get-MHField -Object $setting -Name 'valueState' -Default 'SAFE') -ne 'SAFE') { continue }
        $key = ([string](Get-MHField -Object $setting -Name 'key')).ToLowerInvariant()
        $value = [string](Get-MHField -Object $setting -Name 'value')
        if ($key -notin $allowed -or [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 200 -or $value -match '[\r\n\0]' -or (Test-MHSecretText -Text $value)) { continue }
        $validValue = switch ($key) {
            'user.name' { $value -notmatch '[\x00-\x1F\x7F]' }
            'user.email' { $value -match '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]{1,128}@[A-Za-z0-9.-]{1,120}$' }
            'core.autocrlf' { $value -match '^(?i:true|false|input)$' }
            'core.eol' { $value -match '^(?i:native|lf|crlf)$' }
            'init.defaultbranch' { $value -match '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -and $value -notmatch '(?:\.\.|//|/$)' }
            'pull.rebase' { $value -match '^(?i:true|false|merges|interactive)$' }
            'push.default' { $value -match '^(?i:nothing|current|upstream|simple|matching)$' }
            default { $false }
        }
        if (-not $validValue) { continue }
        if (-not $grouped.ContainsKey($key)) { $grouped[$key] = New-Object System.Collections.ArrayList }
        [void]$grouped[$key].Add($value)
    }
    $normalized = @()
    foreach ($key in @($grouped.Keys | Sort-Object)) {
        $values = @($grouped[$key] | Sort-Object -Unique)
        if ($values.Count -eq 1) { $normalized += [pscustomobject]@{ key = $key; value = [string]$values[0] } }
    }
    return @($normalized)
}

function Resolve-MHRestoreGitTarget {
    param($GitItem, [Parameter(Mandatory)]$Context)
    $userProfile = [string](Get-MHField -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    if ([string]::IsNullOrWhiteSpace($userProfile) -or $userProfile.StartsWith('\\', [StringComparison]::Ordinal)) { throw 'RESTORE_TARGET_UNSUPPORTED' }
    $userRoot = [IO.Path]::GetFullPath($userProfile).TrimEnd('\') + '\'
    $candidatePath = $null
    foreach ($file in @(Get-MHField -Object $GitItem -Name 'configFiles' -Default @())) {
        if ([string](Get-MHField -Object $file -Name 'scope') -ne 'global' -or [string](Get-MHField -Object $file -Name 'state') -ne 'PRESENT') { continue }
        $path = [string](Get-MHField -Object $file -Name 'path')
        if ($path -and -not $path.StartsWith('\\', [StringComparison]::Ordinal)) { $candidatePath = $path; break }
    }
    if (-not $candidatePath) { $candidatePath = Join-Path $userRoot '.gitconfig' }
    $targetPath = [IO.Path]::GetFullPath($candidatePath)
    if ($targetPath.Length -gt 1024 -or -not $targetPath.StartsWith($userRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RESTORE_TARGET_UNSUPPORTED' }
    [void](Assert-MHNoReparseAncestors -Path $targetPath)
    $parentPath = Split-Path -Parent $targetPath
    if (-not $parentPath.StartsWith($userRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'RESTORE_TARGET_UNSUPPORTED' }
    $targetState = 'ABSENT'
    $targetSha256 = $null
    if (Test-Path -LiteralPath $targetPath) {
        $item = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RESTORE_TARGET_UNSAFE' }
        $targetState = 'PRESENT'
        $targetSha256 = Get-MHRestoreFileSha256 -Path $targetPath
    }
    return [pscustomobject]@{ root = $userRoot.TrimEnd('\'); targetPath = $targetPath; parentPath = $parentPath; targetState = $targetState; targetSha256 = $targetSha256 }
}

function New-MHRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Destination,
        [Parameter(Mandatory)]$Diff,
        $Decisions,
        [Parameter(Mandatory)]$Context
    )
    Test-MHSnapshot -Snapshot $Source
    Test-MHSnapshot -Snapshot $Destination
    $sourceHash = Get-MHRestoreSnapshotSha256 -Snapshot $Source
    $destinationHash = Get-MHRestoreSnapshotSha256 -Snapshot $Destination
    $sourceArtifacts = @(Get-MHField -Object $Source -Name 'configArtifacts' -Default @())
    $actions = @()
    foreach ($item in @(Get-MHField -Object $Diff -Name 'items' -Default @())) {
        $componentId = [string](Get-MHField -Object $item -Name 'component')
        if ([string]::IsNullOrWhiteSpace($componentId) -or (Get-MHField -Object $item -Name 'action') -eq 'SKIP') { continue }
        $domain = $componentId.Split('|')[0]
        $action = [pscustomobject]@{
            actionId = $null; componentId = $componentId; actionType = 'REVIEW_ONLY'; proposedAction = [string](Get-MHField -Object $item -Name 'action')
            status = 'REVIEW'; approvalState = 'NOT_APPLICABLE'; risk = [string](Get-MHField -Object $item -Name 'risk' -Default 'MEDIUM')
            safety = 'MANUAL'; reason = 'ACTION_NOT_SUPPORTED_BY_RESTORE_EXECUTOR'; dependsOn = @(); targetPathCandidate = $null; targetPath = $null
            targetState = 'NOT_APPLICABLE'; targetSha256 = $null; backupPath = $null; sourceArtifactPath = $null; sourceArtifactSha256 = $null
            preconditions = @(); verificationStrategy = 'MANUAL'
        }
        if ($domain -eq 'config' -and [string](Get-MHField -Object $item -Name 'action') -eq 'COPY') {
            $artifactId = $componentId.Substring($componentId.IndexOf('|') + 1)
            $artifact = @($sourceArtifacts | Where-Object { [string]$_.id -eq $artifactId } | Select-Object -First 1)
            if ($artifact.Count -eq 0) { $action.reason = 'SOURCE_CONFIG_ARTIFACT_MISSING'; $action.status = 'BLOCKED' }
            else {
                $artifactRecord = $artifact[0]
                $policy = Get-MHEffectiveRestorePolicy -Component $componentId -Entry $artifactRecord -Decisions $Decisions
                $action.targetPathCandidate = [string]$artifactRecord.targetPathCandidate
                $action.sourceArtifactPath = [string]$artifactRecord.artifactPath
                $action.sourceArtifactSha256 = [string]$artifactRecord.artifactSha256
                $action.dependsOn = @($artifactRecord.dependsOn)
                if ($policy -ne 'RESTORE') { $action.reason = 'CONFIG_POLICY_NOT_RESTORE'; $action.status = 'REVIEW' }
                elseif ($artifactRecord.captureState -ne 'CAPTURED' -or $artifactRecord.contentPolicy -notin @('SAFE_COPY', 'REDACTED_COPY')) { $action.reason = 'CONFIG_CONTENT_NOT_RESTORABLE'; $action.status = 'REVIEW' }
                else {
                    try {
                        $target = Resolve-MHRestoreTargetPath -Candidate ([string]$artifactRecord.targetPathCandidate) -Context $Context
                        $action.actionType = 'COPY_CONFIG_ARTIFACT'
                        $action.safety = 'CONFIRM'
                        $action.reason = if ($target.targetState -eq 'PRESENT' -and $target.targetSha256 -eq [string]$artifactRecord.artifactSha256) { 'TARGET_ALREADY_MATCHES_ARTIFACT' } elseif ($target.targetState -eq 'PRESENT') { 'TARGET_CONFLICT_REQUIRES_BACKUP_AND_APPROVAL' } else { 'COPY_SANITIZED_CONFIG_AFTER_EXPLICIT_APPROVAL' }
                        $action.status = if ($target.targetState -eq 'PRESENT' -and $target.targetSha256 -eq [string]$artifactRecord.artifactSha256) { 'NOT_NEEDED' } elseif ($target.targetState -eq 'PRESENT') { 'CONFLICT' } else { 'READY' }
                        $action.approvalState = if ($action.status -eq 'NOT_NEEDED') { 'NOT_REQUIRED' } else { 'REQUIRED' }
                        $action.targetPath = $target.targetPath
                        $action.targetState = $target.targetState
                        $action.targetSha256 = $target.targetSha256
                        $action.verificationStrategy = 'HASH'
                        $action.preconditions = @('PACKAGE_ARTIFACT_HASH_MATCHES', ('TARGET_STATE=' + $target.targetState))
                    } catch {
                        $action.status = 'BLOCKED'
                        $action.reason = if ($_.Exception.Message -match '^RESTORE_[A-Z_]+$|^PATH_(?:REPARSE_BLOCKED|CHECK_FAILED)$') { $_.Exception.Message } else { 'RESTORE_TARGET_UNSAFE' }
                    }
                }
            }
        }
        if (-not $action.actionId) {
            $idSeed = $componentId + '|' + [string]$action.actionType + '|' + [string]$action.sourceArtifactSha256 + '|' + [string]$action.targetPathCandidate
            $action.actionId = 'restore:' + (Get-MHTextSha256 -Text $idSeed).Substring(0, 16)
        }
        if ($action.actionType -eq 'COPY_CONFIG_ARTIFACT' -and $action.status -eq 'CONFLICT') {
            $action.backupPath = $action.targetPath + '.machine-handoff-backup-' + $action.actionId.Substring('restore:'.Length) + '.bak'
            try {
                [void](Assert-MHNoReparseAncestors -Path $action.backupPath)
                if (Test-Path -LiteralPath $action.backupPath) { $action.status = 'BLOCKED'; $action.reason = 'BACKUP_PATH_EXISTS' }
            } catch { $action.status = 'BLOCKED'; $action.reason = 'BACKUP_PATH_UNSAFE' }
        }
        $actions += $action
    }

    $componentToAction = @{}
    foreach ($action in $actions) { $componentToAction[[string]$action.componentId] = $action }
    foreach ($action in $actions) {
        if ($action.actionType -ne 'COPY_CONFIG_ARTIFACT' -or @($action.dependsOn).Count -eq 0) { continue }
        $resolvedDependencies = @()
        foreach ($dependency in @($action.dependsOn)) {
            $dependencyText = [string]$dependency
            if ($componentToAction.ContainsKey($dependencyText)) { $resolvedDependencies += [string]$componentToAction[$dependencyText].actionId; continue }
            $destinationMatches = @(ConvertTo-MHComparableItems -Snapshot $Destination | Where-Object { $_.id -eq $dependencyText -or ($_.domain + '|' + $_.id) -eq $dependencyText } | Where-Object { $_.value.state -eq 'PRESENT' })
            if ($destinationMatches.Count -eq 0) { $action.status = 'BLOCKED'; $action.reason = 'RESTORE_DEPENDENCY_MISSING' }
        }
        $action.dependsOn = @($resolvedDependencies | Sort-Object -Unique)
    }

    $plan = [pscustomobject]@{
        schemaVersion = 1; sourceSnapshotId = [string]$Source.snapshotId; sourceSnapshotSha256 = $sourceHash
        destinationSnapshotId = [string]$Destination.snapshotId; destinationSnapshotSha256 = $destinationHash
        createdAt = [DateTimeOffset]::Now.ToString('o'); status = 'READY'; actions = @($actions); issues = @()
        approvalPolicy = 'PLAN_HASH_AND_ACTION_IDS'
    }
    $validation = Test-MHRestorePlan -Plan $plan
    $executableActions = @($actions | Where-Object { $_.actionType -eq 'COPY_CONFIG_ARTIFACT' -and $_.status -in @('READY', 'CONFLICT') })
    $reviewActions = @($actions | Where-Object { $_.status -in @('REVIEW', 'BLOCKED') })
    $plan.status = if ($validation.status -eq 'BLOCKED') { 'BLOCKED' } elseif ($executableActions.Count -gt 0) { 'READY' } elseif ($reviewActions.Count -gt 0) { 'REVIEW_ONLY' } else { 'NO_ACTIONS' }
    $plan.issues = @($validation.issues)
    $plan | Add-Member -NotePropertyName planSha256 -NotePropertyValue (Get-MHRestorePlanSha256 -Plan $plan) -Force
    return $plan
}

function Invoke-MHApprovedRestoreActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ApprovedPlanSha256,
        [string[]]$ApprovedActionIds = @(),
        [Parameter(Mandatory)]$Context
    )
    $planSha = [string](Get-MHField -Object $Plan -Name 'planSha256')
    if ($ApprovedPlanSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $ApprovedPlanSha256 -ine $planSha -or (Get-MHRestorePlanSha256 -Plan $Plan) -ine $planSha) {
        return [pscustomobject]@{ schemaVersion = 1; status = 'APPROVAL_STALE'; planSha256 = $planSha; actions = @(); approvals = @() }
    }
    if ([string](Get-MHField -Object $Plan -Name 'status') -ne 'READY') { return [pscustomobject]@{ schemaVersion = 1; status = 'PLAN_BLOCKED'; planSha256 = $planSha; actions = @(); approvals = @() } }
    $graph = Test-MHRestorePlan -Plan $Plan
    if ($graph.status -ne 'READY') { return [pscustomobject]@{ schemaVersion = 1; status = 'PLAN_BLOCKED'; planSha256 = $planSha; actions = @(); approvals = @() } }
    $approvedIds = @($ApprovedActionIds | Where-Object { $_ } | Sort-Object -Unique)
    if ($approvedIds.Count -eq 0) { return [pscustomobject]@{ schemaVersion = 1; status = 'APPROVAL_REQUIRED'; planSha256 = $planSha; actions = @(); approvals = @() } }
    $actionById = @{}
    foreach ($action in $Plan.actions) { $actionById[[string]$action.actionId] = $action }
    foreach ($actionId in $approvedIds) {
        if (-not $actionById.ContainsKey($actionId) -or $actionById[$actionId].actionType -ne 'COPY_CONFIG_ARTIFACT' -or $actionById[$actionId].status -notin @('READY', 'CONFLICT', 'NOT_NEEDED')) {
            return [pscustomobject]@{ schemaVersion = 1; status = 'APPROVAL_INVALID'; planSha256 = $planSha; actions = @(); approvals = @() }
        }
        foreach ($dependencyId in @($actionById[$actionId].dependsOn)) {
            if ($approvedIds -notcontains [string]$dependencyId -and $actionById[[string]$dependencyId].status -ne 'NOT_NEEDED') {
                return [pscustomobject]@{ schemaVersion = 1; status = 'APPROVAL_DEPENDENCY_REQUIRED'; planSha256 = $planSha; actions = @(); approvals = @() }
            }
        }
    }
    $approvalReceipts = @($approvedIds | ForEach-Object {
        $action = $actionById[$_]
        [pscustomobject]@{
            approvedAt = [DateTimeOffset]::Now.ToString('o')
            sourceSnapshotId = $Plan.sourceSnapshotId
            destinationSnapshotId = $Plan.destinationSnapshotId
            sourceSnapshotSha256 = $Plan.sourceSnapshotSha256
            destinationSnapshotSha256 = $Plan.destinationSnapshotSha256
            planSha256 = $planSha
            actionId = [string]$action.actionId
            componentId = [string]$action.componentId
            targetPath = [string]$action.targetPath
            backupPath = [string](Get-MHField -Object $action -Name 'backupPath' -Default '')
            targetStateAtApproval = [string](Get-MHField -Object $action -Name 'targetState' -Default '')
            targetSha256AtApproval = [string](Get-MHField -Object $action -Name 'targetSha256' -Default '')
        }
    })

    $prepared = @()
    foreach ($actionId in $graph.orderedActionIds) {
        if ($approvedIds -notcontains [string]$actionId) { continue }
        $action = $actionById[[string]$actionId]
        if ($action.status -eq 'NOT_NEEDED') { $prepared += [pscustomobject]@{ action = $action; content = $null; result = 'NOT_NEEDED' }; continue }
        try {
            $target = Resolve-MHRestoreTargetPath -Candidate ([string]$action.targetPathCandidate) -Context $Context
            $targetSha = [string](Get-MHField -Object $target -Name 'targetSha256' -Default '')
            $plannedTargetSha = [string](Get-MHField -Object $action -Name 'targetSha256' -Default '')
            if ($target.targetPath -ine [string]$action.targetPath -or $target.targetState -ne [string]$action.targetState -or $targetSha -ine $plannedTargetSha) { throw 'RESTORE_APPROVAL_STALE' }
            if ($action.status -eq 'CONFLICT' -and ((Test-Path -LiteralPath $action.backupPath) -or [string]::IsNullOrWhiteSpace([string]$action.backupPath))) { throw 'RESTORE_APPROVAL_STALE' }
            $artifactFullPath = Get-MHPackageFullPath -PackagePath $PackagePath -RelativePath ([string]$action.sourceArtifactPath)
            $maxConfigBytes = [long](Get-MHField -Object $Context.budgets -Name 'maxConfigBytes' -Default 1048576)
            $content = Read-MHBoundedUtf8Text -Path $artifactFullPath -MaxBytes $maxConfigBytes
            Test-MHSerializedText -Text $content
            if ((Get-MHTextSha256 -Text $content) -ine [string]$action.sourceArtifactSha256) { throw 'CONFIG_ARTIFACT_HASH_MISMATCH' }
            $prepared += [pscustomobject]@{ action = $action; content = $content; result = 'READY' }
        } catch {
            $code = if ($_.Exception.Message -match '^(RESTORE_[A-Z_]+|PATH_(?:REPARSE_BLOCKED|CHECK_FAILED)|PACKAGE_PATH_BLOCKED|CONFIG_ARTIFACT_HASH_MISMATCH|JSON_SIZE_LIMIT|REDACTION_BLOCKED)$') { $_.Exception.Message } else { 'RESTORE_PREFLIGHT_FAILED' }
            return [pscustomobject]@{ schemaVersion = 1; status = if ($code -eq 'RESTORE_APPROVAL_STALE') { 'APPROVAL_STALE' } else { 'PREFLIGHT_FAILED' }; planSha256 = $planSha; actions = @(); errorCode = $code; approvals = @() }
        }
    }

    $completed = @()
    $results = @()
    try {
        foreach ($entry in $prepared) {
            $action = $entry.action
            if ($entry.result -eq 'NOT_NEEDED') {
                $results += [pscustomobject]@{ actionId = $action.actionId; componentId = $action.componentId; actionType = $action.actionType; targetPath = $action.targetPath; backupPath = $action.backupPath; executionState = 'NOT_NEEDED'; verificationStatus = 'PASS'; errorCode = $null }
                continue
            }
            $target = Resolve-MHRestoreTargetPath -Candidate ([string]$action.targetPathCandidate) -Context $Context
            $targetSha = [string](Get-MHField -Object $target -Name 'targetSha256' -Default '')
            $plannedTargetSha = [string](Get-MHField -Object $action -Name 'targetSha256' -Default '')
            if ($target.targetPath -ine [string]$action.targetPath -or $target.targetState -ne [string]$action.targetState -or $targetSha -ine $plannedTargetSha) { throw 'RESTORE_APPROVAL_STALE' }
            $parent = [string]$target.parentPath
            [void](Assert-MHNoReparseAncestors -Path $parent)
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop) }
            [void](Assert-MHNoReparseAncestors -Path $parent)
            $hadOriginal = $target.targetState -eq 'PRESENT'
            if ($hadOriginal) {
                [void](Assert-MHNoReparseAncestors -Path $action.backupPath)
                if (Test-Path -LiteralPath $action.backupPath) { throw 'RESTORE_APPROVAL_STALE' }
            }
            $tempPath = Join-Path $parent ('.mh-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Write-MHRestoreTemporaryContent -Path $tempPath -Content ([string]$entry.content)
                if ((Get-MHRestoreFileSha256 -Path $tempPath -MaxBytes ([Math]::Max(1, [Text.Encoding]::UTF8.GetByteCount([string]$entry.content)))) -ine [string]$action.sourceArtifactSha256) { throw 'RESTORE_VERIFY_FAILED' }
                if ($hadOriginal) { [IO.File]::Replace($tempPath, $target.targetPath, $action.backupPath) } else { [IO.File]::Move($tempPath, $target.targetPath) }
                $completed += [pscustomobject]@{ action = $action; hadOriginal = $hadOriginal; targetPath = $target.targetPath; backupPath = $action.backupPath }
                $targetHash = Get-MHRestoreFileSha256 -Path $target.targetPath -MaxBytes ([Math]::Max(1, [Text.Encoding]::UTF8.GetByteCount([string]$entry.content)))
                if ($targetHash -ine [string]$action.sourceArtifactSha256) { throw 'RESTORE_VERIFY_FAILED' }
                $results += [pscustomobject]@{ actionId = $action.actionId; componentId = $action.componentId; actionType = $action.actionType; targetPath = $target.targetPath; backupPath = $(if ($hadOriginal) { $action.backupPath } else { $null }); executionState = 'EXECUTED'; verificationStatus = 'PASS'; errorCode = $null }
            } finally {
                if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
            }
        }
        return [pscustomobject]@{ schemaVersion = 1; status = 'EXECUTED'; planSha256 = $planSha; sourceSnapshotId = $Plan.sourceSnapshotId; destinationSnapshotId = $Plan.destinationSnapshotId; destinationSnapshotSha256 = $Plan.destinationSnapshotSha256; actions = @($results); approvals = @($approvalReceipts) }
    } catch {
        $failureCode = if ($_.Exception.Message -match '^RESTORE_[A-Z_]+$') { $_.Exception.Message } else { 'RESTORE_ACTION_FAILED' }
        $rollbackErrors = @()
        for ($index = $completed.Count - 1; $index -ge 0; $index--) {
            $entry = $completed[$index]
            try {
                if ($entry.hadOriginal -and (Test-Path -LiteralPath $entry.backupPath -PathType Leaf)) {
                    $rollbackTemp = Join-Path (Split-Path -Parent $entry.targetPath) ('.mh-rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
                    $rollbackCurrent = Join-Path (Split-Path -Parent $entry.targetPath) ('.mh-rollback-current-' + [guid]::NewGuid().ToString('N') + '.tmp')
                    [IO.File]::Copy($entry.backupPath, $rollbackTemp, $false)
                    if (Test-Path -LiteralPath $entry.targetPath -PathType Leaf) {
                        [IO.File]::Replace($rollbackTemp, $entry.targetPath, $rollbackCurrent)
                        if (Test-Path -LiteralPath $rollbackCurrent -PathType Leaf) { [IO.File]::Delete($rollbackCurrent) }
                    } else { [IO.File]::Move($rollbackTemp, $entry.targetPath) }
                } elseif (-not $entry.hadOriginal -and (Test-Path -LiteralPath $entry.targetPath -PathType Leaf)) {
                    [void](Assert-MHNoReparseAncestors -Path $entry.targetPath)
                    [IO.File]::Delete($entry.targetPath)
                }
                $matchingResults = @($results | Where-Object { $_.actionId -eq $entry.action.actionId })
                if ($matchingResults.Count -gt 0) {
                    $matchingResults[0] | Add-Member -NotePropertyName executionState -NotePropertyValue 'ROLLED_BACK' -Force
                    $matchingResults[0] | Add-Member -NotePropertyName verificationStatus -NotePropertyValue 'ROLLED_BACK' -Force
                } else {
                    $results += [pscustomobject]@{ actionId = $entry.action.actionId; componentId = $entry.action.componentId; actionType = $entry.action.actionType; targetPath = $entry.targetPath; backupPath = $(if ($entry.hadOriginal) { $entry.backupPath } else { $null }); executionState = 'ROLLED_BACK'; verificationStatus = 'ROLLED_BACK'; errorCode = $null }
                }
            } catch {
                $rollbackErrors += [string]$entry.action.actionId
                $matchingResults = @($results | Where-Object { $_.actionId -eq $entry.action.actionId })
                if ($matchingResults.Count -gt 0) {
                    $matchingResults[0] | Add-Member -NotePropertyName executionState -NotePropertyValue 'ROLLBACK_FAILED' -Force
                    $matchingResults[0] | Add-Member -NotePropertyName verificationStatus -NotePropertyValue 'UNKNOWN' -Force
                    $matchingResults[0] | Add-Member -NotePropertyName errorCode -NotePropertyValue 'ROLLBACK_FAILED' -Force
                } else {
                    $results += [pscustomobject]@{ actionId = $entry.action.actionId; componentId = $entry.action.componentId; actionType = $entry.action.actionType; targetPath = $entry.targetPath; backupPath = $entry.backupPath; executionState = 'ROLLBACK_FAILED'; verificationStatus = 'UNKNOWN'; errorCode = 'ROLLBACK_FAILED' }
                }
            }
        }
        return [pscustomobject]@{ schemaVersion = 1; status = $(if ($rollbackErrors.Count) { 'ROLLBACK_FAILED' } else { 'ROLLED_BACK' }); planSha256 = $planSha; actions = @($results); errorCode = $failureCode; rollbackFailedActionIds = @($rollbackErrors); approvals = @($approvalReceipts) }
    }
}
