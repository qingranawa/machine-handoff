[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\package.ps1')

function Assert-PackageTransaction {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Package transaction check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$packagePath = Join-Path $tempRoot ('mh-package-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $packagePath)
try {
    $context = New-MHCollectionContext -Profile Standard
    $initialFiles = [ordered]@{
        'manifests/source.snapshot.json' = '{"schemaVersion":2,"snapshotId":"synthetic-source"}' + [Environment]::NewLine
        'manifests/decisions.json' = '{"schemaVersion":1,"pathMappings":[],"exclusions":[],"policyOverrides":[],"approvals":[]}' + [Environment]::NewLine
        'HANDOFF.md' = '# Synthetic handoff' + [Environment]::NewLine
    }
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files $initialFiles -Context $context)
    Assert-MHPackageGeneration -PackagePath $packagePath
    Assert-PackageTransaction -Condition ((Test-Path -LiteralPath (Join-Path $packagePath 'HANDOFF.md')) -and (Test-Path -LiteralPath (Join-Path $packagePath 'manifests\generation.json'))) -Message 'staged generation publishes reports and a verifiable commit manifest'
    $generationAfterPrepare = Read-MHJson -Path (Join-Path $packagePath 'manifests\generation.json')
    $decisionEntries = @($generationAfterPrepare.files | Where-Object path -eq 'manifests/decisions.json')
    Assert-PackageTransaction -Condition ($decisionEntries.Count -eq 0) -Message 'user-editable decisions are excluded from generated-content hashes'
    $editedDecisions = New-MHDefaultDecisions
    $editedDecisions.policyOverrides = @([pscustomobject]@{ component = 'config|editors:vscode'; restorePolicy = 'RESTORE' })
    Write-MHJson -Path (Join-Path $packagePath 'manifests\decisions.json') -Value $editedDecisions
    $editedDecisionGenerationError = $null
    try { Assert-MHPackageGeneration -PackagePath $packagePath } catch { $editedDecisionGenerationError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($null -eq $editedDecisionGenerationError) -Message 'editing valid restore decisions does not invalidate the Package generation'
    $metadataArtifact = New-MHConfigArtifact -Context $context -Id 'toolchains:cargo-credentials' -Domain 'toolchains' -SourcePath (Join-Path $packagePath 'absent-credentials.toml') -TargetPathCandidate $null -ContentPolicy NEVER_COLLECT -Sensitivity SENSITIVE -Format UNKNOWN -ArtifactPath 'configs/toolchains/cargo-credentials.metadata.json' -RestorePolicy REVIEW -ValidationStrategy METADATA_ONLY
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files ([ordered]@{ 'SOFTWARE.md' = '# Synthetic software' }) -ConfigArtifacts @($metadataArtifact.artifact) -Context $context)
    $storedConfigRecords = @(Read-MHJson -Path (Join-Path $packagePath 'manifests\configs.json'))
    Assert-PackageTransaction -Condition (@($storedConfigRecords | Where-Object { $null -ne $_ -and $_.id -eq 'toolchains:cargo-credentials' }).Count -eq 1) -Message 'Package accepts metadata-only ConfigArtifact records without requiring a content wrapper'
    $entryLimitError = $null
    try { Assert-MHPackageGeneration -PackagePath $packagePath -MaxEntries 1 } catch { $entryLimitError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($entryLimitError -eq 'PACKAGE_GENERATION_LIMIT') -Message 'generation manifests are rejected when their file entry count exceeds the configured limit'
    $generationManifestPath = Join-Path $packagePath 'manifests\generation.json'
    $generationManifestBytes = [long](Get-Item -LiteralPath $generationManifestPath).Length
    $aggregateLimitError = $null
    try { Assert-MHPackageGeneration -PackagePath $packagePath -MaxBytes ($generationManifestBytes + 1) } catch { $aggregateLimitError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($aggregateLimitError -eq 'PACKAGE_SIZE_LIMIT') -Message 'generation verification enforces one aggregate read budget across its manifest and files'

    $boundedInputPath = Join-Path $packagePath '.bounded-input.json'
    [IO.File]::WriteAllText($boundedInputPath, '{"payload":"SYNTHETIC-OVERSIZE"}', (New-Object System.Text.UTF8Encoding($false)))
    $boundedInputError = $null
    try { Read-MHJson -Path $boundedInputPath -MaxBytes 8 | Out-Null } catch { $boundedInputError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($boundedInputError -eq 'JSON_SIZE_LIMIT') -Message 'JSON input is rejected before reading beyond its configured byte limit'
    $nestedInputPath = Join-Path $packagePath '.nested-input.json'
    [IO.File]::WriteAllText($nestedInputPath, '{"a":{"b":1}}', (New-Object System.Text.UTF8Encoding($false)))
    $depthLimitError = $null
    try { Read-MHJson -Path $nestedInputPath -MaxDepth 1 | Out-Null } catch { $depthLimitError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($depthLimitError -eq 'JSON_DEPTH_LIMIT') -Message 'JSON nesting depth is rejected before deserialization'
    $collectionInputPath = Join-Path $packagePath '.collection-input.json'
    [IO.File]::WriteAllText($collectionInputPath, '[1,2,3]', (New-Object System.Text.UTF8Encoding($false)))
    $collectionLimitError = $null
    try { Read-MHJson -Path $collectionInputPath -MaxCollectionItems 2 | Out-Null } catch { $collectionLimitError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($collectionLimitError -eq 'JSON_COLLECTION_LIMIT') -Message 'JSON arrays and objects are capped by a per-container item budget'
    $stringInputPath = Join-Path $packagePath '.string-input.json'
    [IO.File]::WriteAllText($stringInputPath, '{"value":"123456"}', (New-Object System.Text.UTF8Encoding($false)))
    $stringLimitError = $null
    try { Read-MHJson -Path $stringInputPath -MaxStringLength 4 | Out-Null } catch { $stringLimitError = $_.Exception.Message }
    Assert-PackageTransaction -Condition ($stringLimitError -eq 'JSON_STRING_LIMIT') -Message 'JSON string values are capped before object deserialization'

    $updateFiles = [ordered]@{ 'manifests/source.snapshot.json' = '{"schemaVersion":2,"snapshotId":"synthetic-next"}' + [Environment]::NewLine }
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files $updateFiles -RemovePaths @('HANDOFF.md') -Context $context)
    Assert-MHPackageGeneration -PackagePath $packagePath
    Assert-PackageTransaction -Condition (-not (Test-Path -LiteralPath (Join-Path $packagePath 'HANDOFF.md'))) -Message 'controlled promotion applies explicit generated-file removals'

    $transactionId = [guid]::NewGuid().ToString('N')
    $stageName = '.mh-stage-' + $transactionId
    $backupName = '.mh-backup-' + $transactionId
    $backupPath = Join-Path $packagePath ($backupName + '\HANDOFF.md')
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
    [IO.File]::WriteAllText($backupPath, '# Previous handoff' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $packagePath 'HANDOFF.md'), '# Interrupted handoff' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    $journal = [pscustomobject]@{
        schemaVersion = 1; phase = 'PROMOTING'; stageName = $stageName; backupName = $backupName
        targets = @([pscustomobject]@{ path = 'HANDOFF.md'; existed = $true })
    }
    Write-MHJson -Path (Join-Path $packagePath '.mh-transaction.json') -Value $journal
    Recover-MHPackageTransaction -PackagePath $packagePath
    $restored = Get-Content -LiteralPath (Join-Path $packagePath 'HANDOFF.md') -Raw -Encoding UTF8
    Assert-PackageTransaction -Condition ($restored -eq ('# Previous handoff' + [Environment]::NewLine)) -Message 'interrupted promotion recovers the previous file from its transaction journal'
    Assert-PackageTransaction -Condition (-not (Test-Path -LiteralPath (Join-Path $packagePath '.mh-transaction.json'))) -Message 'recovery removes the completed transaction journal'

    $junctionId = [guid]::NewGuid().ToString('N')
    $junctionOutside = Join-Path $tempRoot ('mh-backup-outside-' + $junctionId)
    $junctionBackupName = '.mh-backup-' + $junctionId
    $junctionBackupRoot = Join-Path $packagePath $junctionBackupName
    [void](New-Item -ItemType Directory -Path $junctionOutside)
    [IO.File]::WriteAllText((Join-Path $junctionOutside 'HANDOFF.md'), '# Synthetic external backup', (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $packagePath 'HANDOFF.md'), '# Preserve package target', (New-Object System.Text.UTF8Encoding($false)))
    try {
        [void](New-Item -ItemType Junction -Path $junctionBackupRoot -Target $junctionOutside)
        $junctionJournal = [pscustomobject]@{
            schemaVersion = 1; phase = 'PROMOTING'; stageName = '.mh-stage-' + $junctionId; backupName = $junctionBackupName
            targets = @([pscustomobject]@{ path = 'HANDOFF.md'; existed = $true })
        }
        Write-MHJson -Path (Join-Path $packagePath '.mh-transaction.json') -Value $junctionJournal
        $junctionRecoveryError = $null
        try { Recover-MHPackageTransaction -PackagePath $packagePath } catch { $junctionRecoveryError = $_.Exception.Message }
        $preservedContent = Get-Content -LiteralPath (Join-Path $packagePath 'HANDOFF.md') -Raw -Encoding UTF8
        Assert-PackageTransaction -Condition ($junctionRecoveryError -eq 'PACKAGE_REPARSE_BLOCKED' -and $preservedContent -eq '# Preserve package target') -Message 'recovery validates backup ancestry before reading or replacing package targets'
    } finally {
        if (Test-Path -LiteralPath $junctionBackupRoot) { [IO.Directory]::Delete($junctionBackupRoot, $false) }
        if (Test-Path -LiteralPath $junctionOutside) { [IO.Directory]::Delete($junctionOutside, $true) }
        $junctionRecord = Join-Path $packagePath '.mh-transaction.json'
        if (Test-Path -LiteralPath $junctionRecord) { Remove-Item -LiteralPath $junctionRecord -Force -ErrorAction SilentlyContinue }
    }
} finally {
    Remove-Item -LiteralPath $packagePath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Package transaction suite passed.'
