Set-StrictMode -Version Latest

function ConvertTo-MHPackageRelativePath {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or @($normalized.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { throw 'PACKAGE_PATH_BLOCKED' }
    $allowedRootFile = $normalized -in @('HANDOFF.md', 'SYSTEM.md', 'SOFTWARE.md', 'DEVELOPMENT.md', 'AI_AGENTS.md', 'DATA.md', 'MIGRATION_PLAN.md')
    $allowedManifest = $normalized -match '^manifests/(source\.snapshot\.json|source\.previous\.json|destination\.snapshot\.json|decisions\.json|diff\.json|validation\.json|configs\.json|restore-plan\.json|restore-result\.json|generation\.json)$'
    $allowedEvidence = $normalized -eq 'evidence/collection-status.json'
    $allowedConfig = $normalized -match '^configs/[A-Za-z0-9._/-]{1,240}$'
    if (-not ($allowedRootFile -or $allowedManifest -or $allowedEvidence -or $allowedConfig)) { throw 'PACKAGE_PATH_BLOCKED' }
    return $normalized
}

function Get-MHPackageFullPath {
    param([Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)][string]$RelativePath)
    $safeRelative = ConvertTo-MHPackageRelativePath -Path $RelativePath
    $full = [IO.Path]::GetFullPath((Join-Path $PackagePath ($safeRelative -replace '/', '\')))
    $root = [IO.Path]::GetFullPath($PackagePath).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'PACKAGE_PATH_BLOCKED' }
    [void](Assert-MHNoReparseAncestors -Path $full)
    return $full
}

function Get-MHTextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    if (Get-Command Get-MHArtifactSha256 -ErrorAction SilentlyContinue) { return Get-MHArtifactSha256 -Text $Text }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Remove-MHPackageTransactionDirectories {
    param([string]$PackagePath, [string]$StageName, [string]$BackupName)
    foreach ($name in @($StageName, $BackupName)) {
        if ($name -notmatch '^\.mh-(stage|backup)-[A-Fa-f0-9]{32}$') { continue }
        $path = Join-Path $PackagePath $name
        if (Test-Path -LiteralPath $path -PathType Container) {
            [void](Assert-MHNoReparseAncestors -Path $path)
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }
}

function Assert-MHPackageRecoveryPath {
    param([Parameter(Mandatory)][string]$Path)
    try { [void](Assert-MHNoReparseAncestors -Path $Path) }
    catch {
        if ($_.Exception.Message -in @('PATH_REPARSE_BLOCKED', 'PATH_CHECK_FAILED')) { throw 'PACKAGE_REPARSE_BLOCKED' }
        throw
    }
}

function Recover-MHPackageTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackagePath)

    $journalPath = Join-Path $PackagePath '.mh-transaction.json'
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return }
    $journalInfo = Get-Item -LiteralPath $journalPath -Force -ErrorAction Stop
    if (($journalInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
    $journal = Read-MHJson -Path $journalPath -MaxBytes 1048576
    if ((Get-MHField -Object $journal -Name 'schemaVersion') -ne 1 -or (Get-MHField -Object $journal -Name 'stageName') -notmatch '^\.mh-stage-[A-Fa-f0-9]{32}$' -or (Get-MHField -Object $journal -Name 'backupName') -notmatch '^\.mh-backup-[A-Fa-f0-9]{32}$') { throw 'PACKAGE_RECOVERY_REQUIRED' }
    $stageName = [string]$journal.stageName
    $backupName = [string]$journal.backupName
    $stageRoot = Join-Path $PackagePath $stageName
    $backupRoot = Join-Path $PackagePath $backupName
    if ($journal.phase -notin @('PROMOTING', 'COMMITTED')) { throw 'PACKAGE_RECOVERY_REQUIRED' }
    foreach ($transactionRoot in @($stageRoot, $backupRoot)) {
        if (Test-Path -LiteralPath $transactionRoot) {
            Assert-MHPackageRecoveryPath -Path $transactionRoot
            $transactionItem = Get-Item -LiteralPath $transactionRoot -Force -ErrorAction Stop
            if (($transactionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
        }
    }

    $recoveryActions = @()
    if ($journal.phase -ne 'COMMITTED') {
        $targets = Get-MHField -Object $journal -Name 'targets'
        if ($null -eq $targets -or $targets -is [string] -or $targets -is [System.Collections.IDictionary]) { throw 'PACKAGE_RECOVERY_REQUIRED' }
        $targets = @($targets)
        if ($targets.Count -gt 4096) { throw 'PACKAGE_GENERATION_LIMIT' }
        $seenTargets = @{}
        $totalBytes = [long]$journalInfo.Length
        foreach ($target in $targets) {
            $targetPathValue = Get-MHField -Object $target -Name 'path'
            $existedValue = Get-MHField -Object $target -Name 'existed'
            if ([string]::IsNullOrWhiteSpace([string]$targetPathValue) -or $existedValue -isnot [bool]) { throw 'PACKAGE_RECOVERY_REQUIRED' }
            $relative = ConvertTo-MHPackageRelativePath -Path ([string]$targetPathValue)
            if ($seenTargets.ContainsKey($relative)) { throw 'PACKAGE_RECOVERY_REQUIRED' }
            $seenTargets[$relative] = $true
            $targetPath = Get-MHPackageFullPath -PackagePath $PackagePath -RelativePath $relative
            $backupPath = Join-Path $backupRoot ($relative -replace '/', '\')
            if ($existedValue) {
                Assert-MHPackageRecoveryPath -Path $backupPath
                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw 'PACKAGE_RECOVERY_REQUIRED' }
                $backupItem = Get-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
                $remainingBytes = 41943040 - $totalBytes
                if ($remainingBytes -le 0 -or $backupItem.Length -gt $remainingBytes) { throw 'PACKAGE_SIZE_LIMIT' }
                $backupText = Read-MHBoundedUtf8Text -Path $backupPath -MaxBytes $remainingBytes
                $totalBytes += [long]$backupItem.Length
                $recoveryActions += [pscustomobject]@{ targetPath = $targetPath; existed = $true; content = $backupText }
            } elseif (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                $existing = Get-Item -LiteralPath $targetPath -Force
                if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
                $recoveryActions += [pscustomobject]@{ targetPath = $targetPath; existed = $false; content = $null }
            }
        }
        foreach ($action in $recoveryActions) {
            Assert-MHPackageRecoveryPath -Path $action.targetPath
            if ($action.existed) {
                $parent = Split-Path -Parent $action.targetPath
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
                Write-MHAtomicText -Path $action.targetPath -Text ([string]$action.content)
            } elseif (Test-Path -LiteralPath $action.targetPath -PathType Leaf) {
                Remove-Item -LiteralPath $action.targetPath -Force -ErrorAction Stop
            }
        }
    }
    Remove-MHPackageTransactionDirectories -PackagePath $PackagePath -StageName $stageName -BackupName $backupName
    Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
}

function Assert-MHPackageGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [ValidateRange(1, 4096)][int]$MaxEntries = 4096,
        [ValidateRange(1, 41943040)][long]$MaxBytes = 41943040
    )

    Recover-MHPackageTransaction -PackagePath $PackagePath
    $manifestPath = Join-Path $PackagePath 'manifests\generation.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    $manifestInfo = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if (($manifestInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
    $manifestMaxBytes = [Math]::Min(1048576L, $MaxBytes)
    if ($manifestInfo.Length -gt $manifestMaxBytes) { throw 'PACKAGE_SIZE_LIMIT' }
    $manifest = Read-MHJson -Path $manifestPath -MaxBytes $manifestMaxBytes
    if ((Get-MHField -Object $manifest -Name 'schemaVersion') -ne 1 -or [string]::IsNullOrWhiteSpace([string](Get-MHField -Object $manifest -Name 'generationId'))) { throw 'PACKAGE_GENERATION_INVALID' }
    $entries = @(Get-MHField -Object $manifest -Name 'files' -Default @())
    if ($entries.Count -gt $MaxEntries) { throw 'PACKAGE_GENERATION_LIMIT' }
    $totalBytes = [long]$manifestInfo.Length
    if ($totalBytes -gt $MaxBytes) { throw 'PACKAGE_SIZE_LIMIT' }
    foreach ($entry in $entries) {
        $relative = ConvertTo-MHPackageRelativePath -Path ([string]$entry.path)
        $fullPath = Get-MHPackageFullPath -PackagePath $PackagePath -RelativePath $relative
        if ($relative -eq 'manifests/decisions.json') {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'PACKAGE_GENERATION_INCOMPLETE' }
            $decisionInfo = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($decisionInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
            continue
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'PACKAGE_GENERATION_INCOMPLETE' }
        $fileInfo = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($fileInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
        $remainingBytes = $MaxBytes - $totalBytes
        if ($fileInfo.Length -gt $remainingBytes) { throw 'PACKAGE_SIZE_LIMIT' }
        $text = Read-MHBoundedUtf8Text -Path $fullPath -MaxBytes ([Math]::Max(1L, $remainingBytes))
        $totalBytes += [long]$fileInfo.Length
        if ((Get-MHTextSha256 -Text $text) -ne [string]$entry.sha256) { throw 'PACKAGE_GENERATION_INCOMPLETE' }
    }
}

function Write-MHPackageTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [object[]]$ConfigArtifacts = @(),
        [string[]]$RemovePaths = @(),
        $Context
    )

    $package = [IO.Path]::GetFullPath($PackagePath)
    [void](Assert-MHNoReparseAncestors -Path $package)
    Recover-MHPackageTransaction -PackagePath $package
    Assert-MHPackageGeneration -PackagePath $package

    $outputs = [ordered]@{}
    foreach ($key in $Files.Keys) {
        $relative = ConvertTo-MHPackageRelativePath -Path ([string]$key)
        if ($outputs.Contains($relative)) { throw 'PACKAGE_TARGET_COLLISION' }
        $outputs[$relative] = [string]$Files[$key]
    }
    $configManifest = @()
    $existingConfigManifestPath = Join-Path $package 'manifests\configs.json'
    if (Test-Path -LiteralPath $existingConfigManifestPath -PathType Leaf) {
        $existingConfigManifest = Read-MHJson -Path $existingConfigManifestPath
        foreach ($existingConfigArtifact in @($existingConfigManifest)) {
            if ($null -ne $existingConfigArtifact) { $configManifest += $existingConfigArtifact }
        }
    }
    foreach ($wrapper in $ConfigArtifacts) {
        $artifact = Get-MHField -Object $wrapper -Name 'artifact' -Default $wrapper
        if (-not $artifact) { throw 'INVALID_CONFIG_ARTIFACT' }
        $key = [string]$artifact.id + '|' + [string]$artifact.artifactSha256 + '|' + [string]$artifact.captureState
        $same = @($configManifest | Where-Object { ([string]$_.id + '|' + [string]$_.artifactSha256 + '|' + [string]$_.captureState) -eq $key })
        if ($same.Count -eq 0) { $configManifest += $artifact }
        if ($artifact.captureState -ne 'CAPTURED') { continue }
        $relative = ConvertTo-MHPackageRelativePath -Path ([string]$artifact.artifactPath)
        $content = Get-MHField -Object $wrapper -Name 'content'
        if ($null -eq $content -or (Get-MHTextSha256 -Text ([string]$content)) -ne [string]$artifact.artifactSha256) { throw 'CONFIG_ARTIFACT_HASH_MISMATCH' }
        if ($outputs.Contains($relative)) { throw 'PACKAGE_TARGET_COLLISION' }
        $outputs[$relative] = [string]$content
    }
    $configsManifestPath = Join-Path $package 'manifests\configs.json'
    if ($ConfigArtifacts.Count -gt 0 -or (-not $outputs.Contains('manifests/configs.json') -and -not (Test-Path -LiteralPath $configsManifestPath -PathType Leaf))) {
        $outputs['manifests/configs.json'] = (ConvertTo-Json -InputObject @($configManifest) -Depth 60) + [Environment]::NewLine
    }

    $removeSet = @{}
    foreach ($removePath in $RemovePaths) {
        $relative = ConvertTo-MHPackageRelativePath -Path $removePath
        if ($outputs.Contains($relative)) { throw 'PACKAGE_TARGET_COLLISION' }
        $removeSet[$relative] = $true
    }

    $previousGenerationFiles = @{}
    $oldManifestPath = Join-Path $package 'manifests\generation.json'
    if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
        $oldManifest = Read-MHJson -Path $oldManifestPath
        foreach ($entry in @(Get-MHField -Object $oldManifest -Name 'files' -Default @())) { $previousGenerationFiles[[string]$entry.path] = [string]$entry.sha256 }
    }
    foreach ($relative in $removeSet.Keys) { [void]$previousGenerationFiles.Remove($relative) }
    # Restore decisions are a user-editable control file, validated separately from generated Package integrity.
    [void]$previousGenerationFiles.Remove('manifests/decisions.json')
    foreach ($relative in $outputs.Keys) {
        if ($relative -eq 'manifests/decisions.json') { continue }
        $previousGenerationFiles[$relative] = Get-MHTextSha256 -Text ([string]$outputs[$relative])
    }

    if ($Context) {
        $totalBytes = 0L
        foreach ($relative in $outputs.Keys) { $totalBytes += [Text.Encoding]::UTF8.GetByteCount([string]$outputs[$relative]) }
        if ($totalBytes -gt [long]$Context.budgets.maxPackageBytes) { throw 'PACKAGE_SIZE_LIMIT' }
    }

    $generationId = [guid]::NewGuid().ToString('N')
    $stageName = '.mh-stage-' + $generationId
    $backupName = '.mh-backup-' + $generationId
    $stageRoot = Join-Path $package $stageName
    $backupRoot = Join-Path $package $backupName
    [void](New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $backupRoot -ErrorAction Stop)
    $journalPath = Join-Path $package '.mh-transaction.json'
    $targets = @()
    $journalWritten = $false

    try {
        $filesToWrite = [ordered]@{}
        foreach ($key in $outputs.Keys) { $filesToWrite[$key] = [string]$outputs[$key] }
        $generation = [pscustomobject]@{
            schemaVersion = 1
            generationId = $generationId
            committedAt = [DateTimeOffset]::Now.ToString('o')
            files = @($previousGenerationFiles.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ path = $_; sha256 = $previousGenerationFiles[$_] } })
        }
        $filesToWrite['manifests/generation.json'] = (ConvertTo-Json -InputObject $generation -Depth 20) + [Environment]::NewLine

        $targetPaths = @($filesToWrite.Keys) + @($removeSet.Keys | Where-Object { $_ -notin $filesToWrite.Keys })
        foreach ($relative in $targetPaths) {
            $hasOutput = $filesToWrite.Contains($relative)
            if ($hasOutput) {
                $text = [string]$filesToWrite[$relative]
                Test-MHSerializedText -Text $text
                if ($Context -and [Text.Encoding]::UTF8.GetByteCount($text) -gt [long]$Context.budgets.maxPackageBytes) { throw 'PACKAGE_SIZE_LIMIT' }
                $stagePath = Join-Path $stageRoot ($relative -replace '/', '\')
                $stageParent = Split-Path -Parent $stagePath
                if (-not (Test-Path -LiteralPath $stageParent -PathType Container)) { [void](New-Item -ItemType Directory -Path $stageParent -Force) }
                Write-MHAtomicText -Path $stagePath -Text $text
            }
            $targetPath = Get-MHPackageFullPath -PackagePath $package -RelativePath $relative
            $existed = Test-Path -LiteralPath $targetPath -PathType Leaf
            $targets += [pscustomobject]@{ path = $relative; existed = [bool]$existed }
            if ($existed) {
                $target = Get-Item -LiteralPath $targetPath -Force
                if (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'OUTPUT_REPARSE_BLOCKED' }
                $backupPath = Join-Path $backupRoot ($relative -replace '/', '\')
                $backupParent = Split-Path -Parent $backupPath
                if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) { [void](New-Item -ItemType Directory -Path $backupParent -Force) }
                Copy-Item -LiteralPath $targetPath -Destination $backupPath -ErrorAction Stop
            }
        }

        $journal = [pscustomobject]@{ schemaVersion = 1; phase = 'PROMOTING'; stageName = $stageName; backupName = $backupName; targets = @($targets) }
        Write-MHJson -Path $journalPath -Value $journal
        $journalWritten = $true

        foreach ($relative in $targetPaths) {
            $targetPath = Get-MHPackageFullPath -PackagePath $package -RelativePath $relative
            if ($removeSet.ContainsKey($relative) -and -not $filesToWrite.Contains($relative)) {
                if (Test-Path -LiteralPath $targetPath -PathType Leaf) { Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop }
                continue
            }
            $parent = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
            Write-MHAtomicText -Path $targetPath -Text ([string]$filesToWrite[$relative])
            $expectedText = [string]$filesToWrite[$relative]
            $expectedByteCount = [Math]::Max(1L, [Text.Encoding]::UTF8.GetByteCount($expectedText))
            $actualText = Read-MHBoundedUtf8Text -Path $targetPath -MaxBytes $expectedByteCount
            if ((Get-MHTextSha256 -Text $actualText) -ne (Get-MHTextSha256 -Text $expectedText)) { throw 'PACKAGE_PROMOTION_VERIFY_FAILED' }
        }

        $journal.phase = 'COMMITTED'
        Write-MHJson -Path $journalPath -Value $journal
        Remove-MHPackageTransactionDirectories -PackagePath $package -StageName $stageName -BackupName $backupName
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
        return $generation
    } catch {
        if ($journalWritten) {
            try { Recover-MHPackageTransaction -PackagePath $package }
            catch { throw 'PACKAGE_RECOVERY_REQUIRED' }
        } else {
            Remove-MHPackageTransactionDirectories -PackagePath $package -StageName $stageName -BackupName $backupName
        }
        $message = [string]$_.Exception.Message
        if ($message -match '^(PACKAGE_RECOVERY_REQUIRED|PACKAGE_GENERATION_INCOMPLETE|PACKAGE_GENERATION_INVALID|PACKAGE_PROMOTION_VERIFY_FAILED|PACKAGE_SIZE_LIMIT|CONFIG_ARTIFACT_HASH_MISMATCH|INVALID_CONFIG_ARTIFACT|OUTPUT_REPARSE_BLOCKED|PATH_REPARSE_BLOCKED|PACKAGE_PATH_BLOCKED|PACKAGE_TARGET_COLLISION|REDACTION_BLOCKED)$') { throw $message }
        throw 'PACKAGE_TRANSACTION_FAILED'
    }
}
