[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Update', 'Restore', 'Validate', 'Diff')][string]$Mode,
    [string]$PackagePath,
    [string[]]$Roots = @(),
    [string[]]$Excludes = @(),
    [ValidateRange(0, 12)][int]$MaxDepth = 3,
    [switch]$SafeMode,
    [switch]$SkipDefaultRoots,
    [ValidateSet('Standard', 'Deep')][string]$Profile = 'Standard',
    [string]$SourceSnapshotPath,
    [string]$DestinationSnapshotPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ApprovePlanSha256,
    [string[]]$ApproveActionIds = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'collect.ps1')
. (Join-Path $PSScriptRoot 'state.ps1')
. (Join-Path $PSScriptRoot 'lib\restore-engine.ps1')

function Stop-MH {
    param([string]$Code)
    Write-Output ('MACHINE_HANDOFF_STATUS=ERROR CODE=' + $Code)
    exit 1
}

function Assert-MHPackagePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Create)
    $full = [IO.Path]::GetFullPath($Path)
    [void](Assert-MHNoReparseAncestors -Path $full)
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) { throw 'PACKAGE_NOT_DIRECTORY' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
    } elseif ($Create) {
        [void](New-Item -ItemType Directory -Path $full -ErrorAction Stop)
        [void](Assert-MHNoReparseAncestors -Path $full)
    } else { throw 'PACKAGE_NOT_FOUND' }
    return $full
}

function Initialize-MHPackage {
    param([string]$Path)
    foreach ($relative in @('manifests', 'evidence')) {
        $directory = Join-Path $Path $relative
        [void](Assert-MHNoReparseAncestors -Path $directory)
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
        } else { [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop) }
    }
}

function Assert-MHWritablePackageTargets {
    param([Parameter(Mandatory)][string]$Path)
    $relativeTargets = @(
        'manifests\source.previous.json', 'manifests\source.snapshot.json', 'manifests\destination.snapshot.json',
        'manifests\decisions.json', 'manifests\diff.json', 'manifests\validation.json',
        'manifests\restore-plan.json', 'manifests\restore-result.json',
        'manifests\configs.json',
        'evidence\collection-status.json', 'HANDOFF.md', 'SYSTEM.md', 'SOFTWARE.md', 'DEVELOPMENT.md',
        'AI_AGENTS.md', 'DATA.md', 'MIGRATION_PLAN.md'
    )
    foreach ($relative in $relativeTargets) { [void](Assert-MHNoReparseAncestors -Path (Join-Path $Path $relative)) }
}

function Get-MHSourcePath {
    param([string]$Path)
    return Join-Path $Path 'manifests\source.snapshot.json'
}

function Get-MHDecisions {
    param([string]$Path)
    $decisionsPath = Join-Path $Path 'manifests\decisions.json'
    if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) {
        $decisions = Read-MHJson -Path $decisionsPath
        Test-MHDecisions -Decisions $decisions
        return $decisions
    }
    return New-MHDefaultDecisions
}

function Write-MHCollectionStatus {
    param([string]$Path, $Snapshot)
    $status = [pscustomobject]@{ schemaVersion = 2; profile = $Snapshot.profile; collectedAt = $Snapshot.collectedAt; snapshotId = $Snapshot.snapshotId; domains = $Snapshot.collection.domainStatus }
    Write-MHJson -Path (Join-Path $Path 'evidence\collection-status.json') -Value $status
}

function Set-MHJsonOutput {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Files, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $Files[$Path.Replace('\', '/')] = (ConvertTo-Json -InputObject $Value -Depth 60) + [Environment]::NewLine
}

function Add-MHReportOutputs {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Files, [Parameter(Mandatory)]$Snapshot, $Diff, $Validation, $RestorePlan)
    $reports = New-MHReportTexts -Snapshot $Snapshot -Diff $Diff -Validation $Validation -RestorePlan $RestorePlan
    foreach ($name in $reports.Keys) { $Files[$name] = [string]$reports[$name] }
}

function New-MHCollectionStatusDocument {
    param([Parameter(Mandatory)]$Snapshot)
    return [pscustomobject]@{ schemaVersion = 2; profile = $Snapshot.profile; collectedAt = $Snapshot.collectedAt; snapshotId = $Snapshot.snapshotId; domains = $Snapshot.collection.domainStatus }
}

function Invoke-MHCollect {
    param([string]$Role, [string]$SourceId)
    $context = New-MHCollectionContext -Profile $Profile -Roots $Roots -Excludes $Excludes -MaxDepth $MaxDepth -SafeMode:$SafeMode -SkipDefaultRoots:$SkipDefaultRoots
    return Collect-MachineHandoff -Roots $Roots -Excludes $Excludes -MaxDepth $MaxDepth -SafeMode:$SafeMode -SkipDefaultRoots:$SkipDefaultRoots -Profile $Profile -Context $context -AsCollectionResult -Role $Role -SourceId $SourceId
}

try {
    if (($ApprovePlanSha256 -or @($ApproveActionIds).Count -gt 0) -and $Mode -ne 'Restore') { throw 'RESTORE_APPROVAL_MODE_REQUIRED' }
    if ($Mode -eq 'Diff') {
        if (-not $SourceSnapshotPath -or -not $DestinationSnapshotPath) { throw 'DIFF_INPUT_REQUIRED' }
        $decisions = New-MHDefaultDecisions
        $package = $null
        if ($PackagePath) {
            $package = Assert-MHPackagePath -Path $PackagePath -Create
            Initialize-MHPackage -Path $package
            Recover-MHPackageTransaction -PackagePath $package
            Assert-MHPackageGeneration -PackagePath $package
            $decisions = Get-MHDecisions -Path $package
        }
        $source = Read-MHJson -Path $SourceSnapshotPath
        $destination = Read-MHJson -Path $DestinationSnapshotPath
        Test-MHSnapshot -Snapshot $source
        Test-MHSnapshot -Snapshot $destination
        $diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
        if ($package) {
            $files = [ordered]@{}
            Set-MHJsonOutput -Files $files -Path 'manifests/diff.json' -Value $diff
            [void](Write-MHPackageTransaction -PackagePath $package -Files $files -Context (New-MHCollectionContext -Profile $Profile))
        } else {
            $diffJson = ConvertTo-Json -InputObject $diff -Depth 50
            Test-MHSerializedText -Text $diffJson
            Write-Output $diffJson
            exit 0
        }
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=DIFF ITEMS=' + @($diff.items).Count)
        exit 0
    }

    if (-not $PackagePath) { throw 'PACKAGE_PATH_REQUIRED' }
    $package = Assert-MHPackagePath -Path $PackagePath -Create:($Mode -eq 'Prepare')
    Recover-MHPackageTransaction -PackagePath $package
    Assert-MHPackageGeneration -PackagePath $package
    if ($Mode -eq 'Prepare') {
        $existing = @(Get-ChildItem -LiteralPath $package -Force -ErrorAction Stop)
        if ($existing.Count -gt 0) { throw 'PACKAGE_NOT_EMPTY' }
        Initialize-MHPackage -Path $package
        $collectionResult = Invoke-MHCollect -Role 'SOURCE' -SourceId $null
        $snapshot = $collectionResult.snapshot
        Test-MHSnapshot -Snapshot $snapshot
        $decisions = New-MHDefaultDecisions
        $files = [ordered]@{}
        Set-MHJsonOutput -Files $files -Path 'manifests/source.snapshot.json' -Value $snapshot
        Set-MHJsonOutput -Files $files -Path 'manifests/decisions.json' -Value $decisions
        Set-MHJsonOutput -Files $files -Path 'evidence/collection-status.json' -Value (New-MHCollectionStatusDocument -Snapshot $snapshot)
        Add-MHReportOutputs -Files $files -Snapshot $snapshot
        [void](Write-MHPackageTransaction -PackagePath $package -Files $files -ConfigArtifacts $collectionResult.configArtifacts -Context $collectionResult.context)
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=PREPARE DOMAINS=' + $snapshot.collection.domainStatus.Count)
        exit 0
    }

    if ($Mode -eq 'Update') {
        $sourcePath = Get-MHSourcePath -Path $package
        $previous = Read-MHJson -Path $sourcePath
        Test-MHSnapshot -Snapshot $previous
        if ($previous.role -ne 'SOURCE') { throw 'SOURCE_SNAPSHOT_REQUIRED' }
        $collectionResult = Invoke-MHCollect -Role 'SOURCE' -SourceId $previous.sourceId
        $snapshot = $collectionResult.snapshot
        $previousArtifacts = @(Get-MHField -Object $previous -Name 'configArtifacts' -Default @())
        if ($Profile -eq 'Standard' -and $previousArtifacts.Count -gt 0) {
            $carriedArtifacts = @()
            foreach ($artifact in $previousArtifacts) {
                $copy = [ordered]@{}
                foreach ($property in $artifact.PSObject.Properties) { $copy[$property.Name] = $property.Value }
                $copy.freshness = 'CARRIED_FORWARD_NOT_RECHECKED'
                $carriedArtifacts += [pscustomobject]$copy
            }
            $snapshot.configArtifacts = @($carriedArtifacts)
        }
        Test-MHSnapshot -Snapshot $snapshot
        $previousLabel = [string]$previous.system.computerLabel
        $currentLabel = [string]$snapshot.system.computerLabel
        $previousProfile = [string]$previous.system.userProfile
        $currentProfile = [string]$snapshot.system.userProfile
        if ([string]::IsNullOrWhiteSpace($previousLabel) -or [string]::IsNullOrWhiteSpace($previousProfile) -or $previousLabel -ine $currentLabel -or $previousProfile -ine $currentProfile) { throw 'SOURCE_MACHINE_MISMATCH' }
        $decisions = Get-MHDecisions -Path $package
        $diff = $null
        $validation = $null
        $destinationPath = Join-Path $package 'manifests\destination.snapshot.json'
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $destination = Read-MHJson -Path $destinationPath
            Test-MHSnapshot -Snapshot $destination
            if ($destination.role -ne 'DESTINATION') { throw 'DESTINATION_SNAPSHOT_REQUIRED' }
            $diff = New-MHDiff -Source $snapshot -Destination $destination -Decisions $decisions
            $validation = New-MHValidation -Diff $diff -Source $snapshot -Destination $destination -Decisions $decisions
        }
        $reportTexts = New-MHReportTexts -Snapshot $snapshot -Diff $diff -Validation $validation
        Assert-MHWritablePackageTargets -Path $package
        $files = [ordered]@{}
        $removePaths = @('manifests/restore-plan.json', 'manifests/restore-result.json')
        Set-MHJsonOutput -Files $files -Path 'manifests/source.previous.json' -Value $previous
        Set-MHJsonOutput -Files $files -Path 'manifests/source.snapshot.json' -Value $snapshot
        Set-MHJsonOutput -Files $files -Path 'evidence/collection-status.json' -Value (New-MHCollectionStatusDocument -Snapshot $snapshot)
        if ($null -ne $diff) {
            Set-MHJsonOutput -Files $files -Path 'manifests/diff.json' -Value $diff
            Set-MHJsonOutput -Files $files -Path 'manifests/validation.json' -Value $validation
        } else { $removePaths += @('manifests/diff.json', 'manifests/validation.json') }
        foreach ($name in $reportTexts.Keys) { $files[$name] = [string]$reportTexts[$name] }
        [void](Write-MHPackageTransaction -PackagePath $package -Files $files -ConfigArtifacts $collectionResult.configArtifacts -RemovePaths @($removePaths) -Context $collectionResult.context)
        Write-Output 'MACHINE_HANDOFF_STATUS=OK MODE=UPDATE'
        exit 0
    }

    $sourcePath = Get-MHSourcePath -Path $package
    $source = Read-MHJson -Path $sourcePath
    Test-MHSnapshot -Snapshot $source
    if ($source.role -ne 'SOURCE') { throw 'SOURCE_SNAPSHOT_REQUIRED' }
    $decisions = Get-MHDecisions -Path $package
    $collectionResult = Invoke-MHCollect -Role 'DESTINATION' -SourceId $source.sourceId
    $destination = $collectionResult.snapshot
    Test-MHSnapshot -Snapshot $destination
    $diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
    $validation = New-MHValidation -Diff $diff -Source $source -Destination $destination -Decisions $decisions
    $restorePlan = $null
    $restoreResult = $null
    if ($Mode -eq 'Restore') {
        $restorePlan = New-MHRestorePlan -PackagePath $package -Source $source -Destination $destination -Diff $diff -Decisions $decisions -Context $collectionResult.context
        $hasPlanApproval = -not [string]::IsNullOrWhiteSpace($ApprovePlanSha256)
        $hasActionApproval = @($ApproveActionIds | Where-Object { $_ }).Count -gt 0
        if ($hasPlanApproval -xor $hasActionApproval) {
            $restoreResult = [pscustomobject]@{ schemaVersion = 1; status = 'APPROVAL_INVALID'; planSha256 = $restorePlan.planSha256; sourceSnapshotId = $restorePlan.sourceSnapshotId; destinationSnapshotId = $restorePlan.destinationSnapshotId; actions = @(); approvals = @() }
        } elseif ($hasPlanApproval -and $hasActionApproval) {
            $restoreResult = Invoke-MHApprovedRestoreActions -PackagePath $package -Plan $restorePlan -ApprovedPlanSha256 $ApprovePlanSha256 -ApprovedActionIds $ApproveActionIds -Context $collectionResult.context
            if ($restoreResult.status -eq 'EXECUTED') {
                try {
                    $postCollectionResult = Invoke-MHCollect -Role 'DESTINATION' -SourceId $source.sourceId
                    $postDestination = $postCollectionResult.snapshot
                    Test-MHSnapshot -Snapshot $postDestination
                    $destination = $postDestination
                    $diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
                    $validation = New-MHValidation -Diff $diff -Source $source -Destination $destination -Decisions $decisions
                    $postValidationStatus = if ($validation.counts.fail -gt 0) { 'FAIL' } elseif ($validation.counts.warn -gt 0 -or $validation.counts.unknown -gt 0) { 'WARN' } elseif ($validation.counts.notTested -gt 0) { 'NOT_TESTED' } else { 'PASS' }
                    $restoreResult | Add-Member -NotePropertyName postDestinationSnapshotId -NotePropertyValue $destination.snapshotId -Force
                    $restoreResult | Add-Member -NotePropertyName postValidationStatus -NotePropertyValue $postValidationStatus -Force
                    $restoreResult | Add-Member -NotePropertyName postValidationCounts -NotePropertyValue $validation.counts -Force
                    foreach ($actionResult in @($restoreResult.actions)) {
                        $postCheck = @($validation.checks | Where-Object { $_.component -eq $actionResult.componentId } | Select-Object -First 1)
                        $actionResult | Add-Member -NotePropertyName postValidationStatus -NotePropertyValue $(if ($postCheck.Count -gt 0) { $postCheck[0].status } else { 'UNKNOWN' }) -Force
                    }
                    $restoreResult.status = if ($postValidationStatus -eq 'FAIL') { 'EXECUTED_VALIDATION_FAILED' } elseif ($postValidationStatus -in @('WARN', 'UNKNOWN', 'NOT_TESTED')) { 'EXECUTED_VALIDATION_INCOMPLETE' } else { 'EXECUTED_AND_VALIDATED' }
                    $collectionResult = $postCollectionResult
                } catch {
                    $restoreResult.status = 'EXECUTED_RECOLLECTION_FAILED'
                    $restoreResult | Add-Member -NotePropertyName postValidationStatus -NotePropertyValue 'UNKNOWN' -Force
                    $restoreResult | Add-Member -NotePropertyName postValidationErrorCode -NotePropertyValue 'POST_RECOLLECTION_FAILED' -Force
                }
            }
        } else {
            $pendingStatus = if ($restorePlan.status -eq 'BLOCKED') { 'PLAN_BLOCKED' } elseif ($restorePlan.status -eq 'NO_ACTIONS') { 'NO_ACTIONS' } elseif ($restorePlan.status -eq 'REVIEW_ONLY') { 'REVIEW_ONLY' } else { 'APPROVAL_REQUIRED' }
            $restoreActionSummaries = @($restorePlan.actions | ForEach-Object { [pscustomobject]@{ actionId = $_.actionId; componentId = $_.componentId; actionType = $_.actionType; status = $_.status; approvalState = $_.approvalState; targetPath = $_.targetPath; backupPath = $_.backupPath; reason = $_.reason } })
            $restoreResult = [pscustomobject]@{ schemaVersion = 1; status = $pendingStatus; planSha256 = $restorePlan.planSha256; sourceSnapshotId = $restorePlan.sourceSnapshotId; destinationSnapshotId = $restorePlan.destinationSnapshotId; destinationSnapshotSha256 = $restorePlan.destinationSnapshotSha256; actions = @($restoreActionSummaries); approvals = @() }
        }
    }
    $files = [ordered]@{}
    Set-MHJsonOutput -Files $files -Path 'manifests/destination.snapshot.json' -Value $destination
    Set-MHJsonOutput -Files $files -Path 'evidence/collection-status.json' -Value (New-MHCollectionStatusDocument -Snapshot $destination)
    Set-MHJsonOutput -Files $files -Path 'manifests/diff.json' -Value $diff
    Set-MHJsonOutput -Files $files -Path 'manifests/validation.json' -Value $validation
    if ($Mode -eq 'Restore') {
        Set-MHJsonOutput -Files $files -Path 'manifests/restore-plan.json' -Value $restorePlan
        Set-MHJsonOutput -Files $files -Path 'manifests/restore-result.json' -Value $restoreResult
    }
    Add-MHReportOutputs -Files $files -Snapshot $source -Diff $diff -Validation $validation -RestorePlan $restorePlan
    [void](Write-MHPackageTransaction -PackagePath $package -Files $files -ConfigArtifacts $collectionResult.configArtifacts -Context $collectionResult.context)
    $resultMode = $Mode.ToUpperInvariant()
    if ($Mode -eq 'Restore') {
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=RESTORE PLAN_STATUS=' + $restorePlan.status + ' PLAN_SHA256=' + $restorePlan.planSha256 + ' RESTORE_STATUS=' + $restoreResult.status + ' ACTIONS=' + @($restorePlan.actions).Count)
    } else {
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=' + $resultMode + ' DIFF_ITEMS=' + @($diff.items).Count)
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    if ($message -match '^(REDACTION_BLOCKED|OUTPUT_REPARSE_BLOCKED|PACKAGE_REPARSE_BLOCKED|PATH_REPARSE_BLOCKED|PATH_CHECK_FAILED|PACKAGE_NOT_EMPTY|PACKAGE_NOT_FOUND|PACKAGE_NOT_DIRECTORY|PACKAGE_PATH_REQUIRED|DIFF_INPUT_REQUIRED|RESTORE_APPROVAL_MODE_REQUIRED|INPUT_FILE_MISSING|INVALID_JSON|JSON_SIZE_LIMIT|JSON_ENCODING_INVALID|JSON_DEPTH_LIMIT|JSON_COLLECTION_LIMIT|JSON_STRING_LIMIT|JSON_TOKEN_LIMIT|INVALID_SNAPSHOT|SNAPSHOT_LIMIT|INVALID_DECISIONS|DECISIONS_LIMIT|UNSUPPORTED_SCHEMA|SOURCE_SNAPSHOT_REQUIRED|DESTINATION_SNAPSHOT_REQUIRED|SOURCE_MACHINE_MISMATCH|OUTPUT_PARENT_MISSING|PACKAGE_PATH_BLOCKED|PACKAGE_TARGET_COLLISION|PACKAGE_TRANSACTION_FAILED|PACKAGE_RECOVERY_REQUIRED|PACKAGE_GENERATION_INVALID|PACKAGE_GENERATION_INCOMPLETE|PACKAGE_GENERATION_LIMIT|PACKAGE_PROMOTION_VERIFY_FAILED|PACKAGE_SIZE_LIMIT|CONFIG_ARTIFACT_HASH_MISMATCH|INVALID_CONFIG_ARTIFACT)$') { Stop-MH -Code $message }
    Stop-MH -Code 'OPERATION_FAILED'
}
