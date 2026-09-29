[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\package.ps1')
$restoreEnginePath = Join-Path $repositoryRoot 'scripts\lib\restore-engine.ps1'
if (Test-Path -LiteralPath $restoreEnginePath -PathType Leaf) { . $restoreEnginePath }

function Assert-RestoreEngine {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Restore engine check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function New-RestoreTestSnapshot {
    param([string]$Role, [string]$SnapshotId, [object[]]$ConfigArtifacts = @())
    $status = [pscustomobject]@{ status = 'OK'; warnings = @(); provenance = 'SYNTHETIC_TEST'; collectedAt = '2026-01-01T00:00:00Z'; metadata = [pscustomobject]@{} }
    $domainStatus = [pscustomobject]@{ system = $status; env = $status; software = $status; dev = $status; shell = $status; editors = $status; agents = $status; wsl = $status; data = $status; git = $status }
    $legacy = [pscustomobject]@{
        schemaVersion = 1; snapshotId = $SnapshotId; sourceId = 'source-fixture'; role = $Role
        collectedAt = '2026-01-01T00:00:00Z'; platform = 'windows'
        collection = [pscustomobject]@{ roots = @(); excludes = @(); maxDepth = 1; safeMode = $true; domainStatus = $domainStatus }
        system = [pscustomobject]@{ computerLabel = 'fixture-host'; userProfile = 'C:\Fixture' }
        env = [pscustomobject]@{ variables = @(); path = [pscustomobject]@{ USER = @(); MACHINE = @() } }
        software = @(); dev = @(); shell = [pscustomobject]@{ id = 'shell'; state = 'PRESENT' }
        editors = @(); agents = @(); wsl = @(); dataLocations = @(); unbackedDataCandidates = @(); manualItems = @()
    }
    $snapshot = ConvertTo-MHV2Snapshot -Snapshot $legacy -Profile Deep
    $snapshot.configArtifacts = @($ConfigArtifacts)
    Test-MHSnapshot -Snapshot $snapshot
    return $snapshot
}

Assert-RestoreEngine -Condition ([bool](Get-Command -Name New-MHRestorePlan -CommandType Function -ErrorAction SilentlyContinue)) -Message 'restore planner is loaded'
Assert-RestoreEngine -Condition ([bool](Get-Command -Name Test-MHRestorePlan -CommandType Function -ErrorAction SilentlyContinue)) -Message 'restore dependency graph validator is loaded'
Assert-RestoreEngine -Condition ([bool](Get-Command -Name Invoke-MHApprovedRestoreActions -CommandType Function -ErrorAction SilentlyContinue)) -Message 'approved restore executor is loaded'

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempRoot ('mh-restore-engine-' + [guid]::NewGuid().ToString('N'))
$packagePath = Join-Path $fixtureRoot 'package'
$userProfile = Join-Path $fixtureRoot 'home'
$appData = Join-Path $userProfile 'AppData'
[void](New-Item -ItemType Directory -Path @($packagePath, $userProfile, $appData) -Force)
try {
    $context = New-MHCollectionContext -Profile Deep -SkipDefaultRoots
    $context | Add-Member -NotePropertyName userProfile -NotePropertyValue $userProfile -Force
    $context | Add-Member -NotePropertyName appData -NotePropertyValue $appData -Force
    $artifactContent = '{"command":"fixture-agent","apiKey":"<REDACTED>","mode":"safe"}' + [Environment]::NewLine
    $artifactHash = Get-MHArtifactSha256 -Text $artifactContent
    $artifact = [pscustomobject]@{
        id = 'agents:test-config'; domain = 'agents'; sourceLocator = '%USERPROFILE%\.agent\settings.json'; targetPathCandidate = '%APPDATA%\TestAgent\settings.json'
        contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE'; captureState = 'CAPTURED'; redactionStatus = 'REDACTED'
        artifactPath = 'configs/agents/settings.' + $artifactHash.Substring(0, 16) + '.json'; artifactSha256 = $artifactHash
        restorePolicy = 'RESTORE'; dependsOn = @(); validationStrategy = 'HASH'; errorCode = $null
    }
    $source = New-RestoreTestSnapshot -Role 'SOURCE' -SnapshotId 'source-restore-fixture' -ConfigArtifacts @($artifact)
    $destination = New-RestoreTestSnapshot -Role 'DESTINATION' -SnapshotId 'destination-restore-fixture'
    $decisions = New-MHDefaultDecisions
    $decisions.policyOverrides = @([pscustomobject]@{ component = 'config|agents:test-config'; restorePolicy = 'RESTORE' })
    $diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
    $files = [ordered]@{ 'manifests/source.snapshot.json' = (ConvertTo-Json -InputObject $source -Depth 60) + [Environment]::NewLine }
    $wrapper = [pscustomobject]@{ artifact = $artifact; content = $artifactContent }
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files $files -ConfigArtifacts @($wrapper) -Context $context)
    $plan = New-MHRestorePlan -PackagePath $packagePath -Source $source -Destination $destination -Diff $diff -Decisions $decisions -Context $context
    $planValidation = Test-MHRestorePlan -Plan $plan
    Assert-RestoreEngine -Condition ($plan.status -eq 'READY' -and $plan.actions.Count -eq 1 -and $plan.actions[0].actionType -eq 'COPY_CONFIG_ARTIFACT' -and $planValidation.status -eq 'READY') 'captured config becomes a validated, reviewable copy action'
    Assert-RestoreEngine -Condition ($plan.actions[0].targetPath -eq (Join-Path $appData 'TestAgent\settings.json') -and $plan.actions[0].approvalState -eq 'REQUIRED' -and $plan.planSha256 -match '^[A-Fa-f0-9]{64}$') 'plan binds a canonical local target and a stable SHA-256 approval token'
    $changedDestination = New-RestoreTestSnapshot -Role 'DESTINATION' -SnapshotId 'destination-changed-fixture'
    $changedDestination.system.computerLabel = 'different-fixture-host'
    $changedDestinationDiff = New-MHDiff -Source $source -Destination $changedDestination -Decisions $decisions
    $changedDestinationPlan = New-MHRestorePlan -PackagePath $packagePath -Source $source -Destination $changedDestination -Diff $changedDestinationDiff -Decisions $decisions -Context $context
    Assert-RestoreEngine -Condition ($changedDestinationPlan.planSha256 -ne $plan.planSha256) 'a different destination snapshot fingerprint changes the approval binding'
    $manualSource = New-RestoreTestSnapshot -Role 'SOURCE' -SnapshotId 'source-manual-fixture'
    $manualDestination = New-RestoreTestSnapshot -Role 'DESTINATION' -SnapshotId 'destination-manual-fixture'
    $manualSource.software = @([pscustomobject]@{ id = 'winget:Example.Package'; state = 'PRESENT'; name = 'Example Package'; packageId = 'Example.Package'; source = 'WINGET'; restorePolicy = 'RESTORE' })
    Test-MHSnapshot -Snapshot $manualSource
    $manualDecisions = New-MHDefaultDecisions
    $manualDecisions.policyOverrides = @([pscustomobject]@{ component = 'software|winget:Example.Package'; restorePolicy = 'RESTORE' })
    $manualDiff = New-MHDiff -Source $manualSource -Destination $manualDestination -Decisions $manualDecisions
    $manualPlan = New-MHRestorePlan -PackagePath $packagePath -Source $manualSource -Destination $manualDestination -Diff $manualDiff -Decisions $manualDecisions -Context $context
    Assert-RestoreEngine -Condition ($manualPlan.status -eq 'REVIEW_ONLY' -and $manualPlan.actions[0].actionType -eq 'REVIEW_ONLY') 'package installation remains review-only until a dedicated executor is available'

    $staleResult = Invoke-MHApprovedRestoreActions -PackagePath $packagePath -Plan $plan -ApprovedPlanSha256 ('0' * 64) -ApprovedActionIds @($plan.actions[0].actionId) -Context $context
    Assert-RestoreEngine -Condition ($staleResult.status -eq 'APPROVAL_STALE' -and -not (Test-Path -LiteralPath $plan.actions[0].targetPath)) 'a mismatched plan hash cannot execute a restore action'

    $success = Invoke-MHApprovedRestoreActions -PackagePath $packagePath -Plan $plan -ApprovedPlanSha256 $plan.planSha256 -ApprovedActionIds @($plan.actions[0].actionId) -Context $context
    Assert-RestoreEngine -Condition ($success.status -eq 'EXECUTED') -Message ('approved copy executor returns EXECUTED; actual status=' + $success.status + '; code=' + [string](Get-MHField -Object $success -Name 'errorCode' -Default ''))
    $targetContent = Get-Content -LiteralPath $plan.actions[0].targetPath -Raw -Encoding UTF8
    Assert-RestoreEngine -Condition ($success.status -eq 'EXECUTED' -and $targetContent -eq $artifactContent -and $success.actions[0].verificationStatus -eq 'PASS') 'approved config copy writes sanitized bytes and verifies the target hash'
    $matchedPlan = New-MHRestorePlan -PackagePath $packagePath -Source $source -Destination $destination -Diff $diff -Decisions $decisions -Context $context
    Assert-RestoreEngine -Condition ($matchedPlan.status -eq 'NO_ACTIONS' -and $matchedPlan.actions[0].status -eq 'NOT_NEEDED') 'a target already matching the sanitized artifact produces no restore action'
    $approval = @($success.approvals)[0]
    Assert-RestoreEngine -Condition ($approval.sourceSnapshotId -eq $source.snapshotId -and $approval.destinationSnapshotId -eq $destination.snapshotId -and $approval.planSha256 -eq $plan.planSha256 -and $approval.actionId -eq $plan.actions[0].actionId -and $approval.targetPath -eq $plan.actions[0].targetPath -and $approval.targetStateAtApproval -eq 'ABSENT') 'approval receipt binds the source, destination fingerprint, plan, action, target, and target state'

    [IO.File]::WriteAllText($plan.actions[0].targetPath, 'changed after approval', (New-Object System.Text.UTF8Encoding($false)))
    $changedTargetResult = Invoke-MHApprovedRestoreActions -PackagePath $packagePath -Plan $plan -ApprovedPlanSha256 $plan.planSha256 -ApprovedActionIds @($plan.actions[0].actionId) -Context $context
    $changedTargetContent = Get-Content -LiteralPath $plan.actions[0].targetPath -Raw -Encoding UTF8
    Assert-RestoreEngine -Condition ($changedTargetResult.status -eq 'APPROVAL_STALE' -and $changedTargetContent -eq 'changed after approval') 'a destination target state change invalidates the prior approval without overwriting it'

    $existingContent = 'existing destination data'
    [IO.File]::WriteAllText($plan.actions[0].targetPath, $existingContent, (New-Object System.Text.UTF8Encoding($false)))
    $existingArtifact = [pscustomobject]@{}
    foreach ($property in $artifact.PSObject.Properties) { $existingArtifact | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    $existingArtifact.artifactPath = 'configs/agents/settings.destination.json'
    $existingArtifact.artifactSha256 = Get-MHArtifactSha256 -Text $existingContent
    $destinationWithConfigConflict = New-RestoreTestSnapshot -Role 'DESTINATION' -SnapshotId 'destination-config-conflict-fixture' -ConfigArtifacts @($existingArtifact)
    $conflictDiff = New-MHDiff -Source $source -Destination $destinationWithConfigConflict -Decisions $decisions
    $conflictDiffItem = @($conflictDiff.items | Where-Object component -eq 'config|agents:test-config' | Select-Object -First 1)
    Assert-RestoreEngine -Condition ($conflictDiffItem.Count -eq 1 -and $conflictDiffItem[0].action -eq 'COPY') 'different source and destination config hashes produce an explicit copy proposal'
    $conflictPlan = New-MHRestorePlan -PackagePath $packagePath -Source $source -Destination $destinationWithConfigConflict -Diff $conflictDiff -Decisions $decisions -Context $context
    Assert-RestoreEngine -Condition ($conflictPlan.status -eq 'READY' -and $conflictPlan.actions[0].targetState -eq 'PRESENT' -and $conflictPlan.actions[0].status -eq 'CONFLICT' -and $conflictPlan.actions[0].backupPath) 'a real existing config conflict reaches the backup-gated restore plan'
    $conflictResult = Invoke-MHApprovedRestoreActions -PackagePath $packagePath -Plan $conflictPlan -ApprovedPlanSha256 $conflictPlan.planSha256 -ApprovedActionIds @($conflictPlan.actions[0].actionId) -Context $context
    Assert-RestoreEngine -Condition ($conflictResult.status -eq 'EXECUTED') -Message ('approved conflict executor returns EXECUTED; actual status=' + $conflictResult.status + '; code=' + [string](Get-MHField -Object $conflictResult -Name 'errorCode' -Default ''))
    $backupContent = Get-Content -LiteralPath $conflictPlan.actions[0].backupPath -Raw -Encoding UTF8
    $restoredContent = Get-Content -LiteralPath $conflictPlan.actions[0].targetPath -Raw -Encoding UTF8
    Assert-RestoreEngine -Condition ($conflictResult.status -eq 'EXECUTED' -and $backupContent -eq 'existing destination data' -and $restoredContent -eq $artifactContent) 'approved conflict replacement preserves the original target beside the destination'

    $rollbackArtifacts = @()
    $rollbackWrappers = @()
    foreach ($entry in @(@{ id = 'agents:rollback-one'; name = 'rollback-one.json' }, @{ id = 'agents:rollback-two'; name = 'rollback-two.json' })) {
        $content = '{"value":"' + $entry.id + '"}' + [Environment]::NewLine
        $hash = Get-MHArtifactSha256 -Text $content
        $rollbackArtifact = [pscustomobject]@{ id = $entry.id; domain = 'agents'; sourceLocator = '%USERPROFILE%\.agent\' + $entry.name; targetPathCandidate = '%APPDATA%\TestAgent\' + $entry.name; contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE'; captureState = 'CAPTURED'; redactionStatus = 'REDACTED'; artifactPath = 'configs/agents/' + $entry.name; artifactSha256 = $hash; restorePolicy = 'RESTORE'; dependsOn = @(); validationStrategy = 'HASH' }
        $rollbackArtifacts += $rollbackArtifact
        $rollbackWrappers += [pscustomobject]@{ artifact = $rollbackArtifact; content = $content }
    }
    $rollbackSource = New-RestoreTestSnapshot -Role 'SOURCE' -SnapshotId 'source-rollback-fixture' -ConfigArtifacts $rollbackArtifacts
    $rollbackDestination = New-RestoreTestSnapshot -Role 'DESTINATION' -SnapshotId 'destination-rollback-fixture'
    $rollbackDecisions = New-MHDefaultDecisions
    $rollbackDecisions.policyOverrides = @($rollbackArtifacts | ForEach-Object { [pscustomobject]@{ component = 'config|' + $_.id; restorePolicy = 'RESTORE' } })
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files ([ordered]@{ 'manifests/source.snapshot.json' = (ConvertTo-Json -InputObject $rollbackSource -Depth 60) + [Environment]::NewLine }) -ConfigArtifacts $rollbackWrappers -Context $context)
    $rollbackDiff = New-MHDiff -Source $rollbackSource -Destination $rollbackDestination -Decisions $rollbackDecisions
    $rollbackPlan = New-MHRestorePlan -PackagePath $packagePath -Source $rollbackSource -Destination $rollbackDestination -Diff $rollbackDiff -Decisions $rollbackDecisions -Context $context
    $script:restoreWriteCount = 0
    $script:restoreWriter = (Get-Command -Name Write-MHRestoreTemporaryContent -CommandType Function).ScriptBlock
    function Write-MHRestoreTemporaryContent {
        param([string]$Path, [string]$Content)
        $script:restoreWriteCount++
        if ($script:restoreWriteCount -eq 2) { throw 'SYNTHETIC_WRITE_FAILURE' }
        & $script:restoreWriter -Path $Path -Content $Content
    }
    try { $rollbackResult = Invoke-MHApprovedRestoreActions -PackagePath $packagePath -Plan $rollbackPlan -ApprovedPlanSha256 $rollbackPlan.planSha256 -ApprovedActionIds @($rollbackPlan.actions.actionId) -Context $context }
    finally { Set-Item -Path Function:\Write-MHRestoreTemporaryContent -Value $script:restoreWriter -Force }
    $rollbackTargetsRemain = @($rollbackPlan.actions | Where-Object { Test-Path -LiteralPath $_.targetPath }).Count
    Assert-RestoreEngine -Condition ($rollbackResult.status -eq 'ROLLED_BACK' -and $rollbackTargetsRemain -eq 0 -and @($rollbackResult.actions | Where-Object executionState -eq 'ROLLED_BACK').Count -eq 1) 'a later copy failure rolls back earlier approved file writes'

    $cyclePlan = [pscustomobject]@{ schemaVersion = 1; planSha256 = 'a' * 64; actions = @(
        [pscustomobject]@{ actionId = 'A'; actionType = 'COPY_CONFIG_ARTIFACT'; status = 'READY'; targetPath = 'C:\Fixture\a.json'; dependsOn = @('B') },
        [pscustomobject]@{ actionId = 'B'; actionType = 'COPY_CONFIG_ARTIFACT'; status = 'READY'; targetPath = 'C:\Fixture\b.json'; dependsOn = @('A') }
    ) }
    Assert-RestoreEngine -Condition ((Test-MHRestorePlan -Plan $cyclePlan).status -eq 'BLOCKED') 'dependency cycles block the restore plan'
    $missingDependencyPlan = [pscustomobject]@{ schemaVersion = 1; planSha256 = 'b' * 64; actions = @([pscustomobject]@{ actionId = 'A'; actionType = 'COPY_CONFIG_ARTIFACT'; status = 'READY'; targetPath = 'C:\Fixture\a.json'; dependsOn = @('missing') }) }
    Assert-RestoreEngine -Condition ((Test-MHRestorePlan -Plan $missingDependencyPlan).status -eq 'BLOCKED') 'missing dependencies block the restore plan'
    $targetCollisionPlan = [pscustomobject]@{ schemaVersion = 1; planSha256 = 'c' * 64; actions = @(
        [pscustomobject]@{ actionId = 'A'; actionType = 'COPY_CONFIG_ARTIFACT'; status = 'READY'; targetPath = 'C:\Fixture\same.json'; dependsOn = @() },
        [pscustomobject]@{ actionId = 'B'; actionType = 'COPY_CONFIG_ARTIFACT'; status = 'READY'; targetPath = 'c:\fixture\same.json'; dependsOn = @() }
    ) }
    Assert-RestoreEngine -Condition ((Test-MHRestorePlan -Plan $targetCollisionPlan).status -eq 'BLOCKED') 'conflicting target paths block all colliding actions'
    $unsupportedPlan = [pscustomobject]@{ schemaVersion = 1; planSha256 = 'd' * 64; actions = @([pscustomobject]@{ actionId = 'A'; actionType = 'RUN_PACKAGE_COMMAND'; status = 'READY'; targetPath = 'C:\Fixture\unsafe'; dependsOn = @() }) }
    Assert-RestoreEngine -Condition ((Test-MHRestorePlan -Plan $unsupportedPlan).status -eq 'BLOCKED') 'arbitrary Package commands are rejected by the action whitelist'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { [IO.Directory]::Delete($fixtureRoot, $true) }
}

Write-Output 'Restore engine suite passed.'
