[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

function Assert-PrepareIntegration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Prepare integration check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$packagePath = Join-Path $tempRoot ('mh-prepare-' + [guid]::NewGuid().ToString('N'))
$approvalManifestPath = Join-Path $tempRoot ('mh-process-approval-' + [guid]::NewGuid().ToString('N') + '.json')
$entryPath = Join-Path $repositoryRoot 'scripts\machine-handoff.ps1'
try {
    $emptyApprovalManifest = [pscustomobject]@{ schemaVersion = 1; approvals = @() }
    [IO.File]::WriteAllText($approvalManifestPath, (ConvertTo-Json -InputObject $emptyApprovalManifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $result = Invoke-MHSafeProcess -Name 'powershell.exe' -Arguments @('-NoProfile', '-File', $entryPath, '-Mode', 'Prepare', '-PackagePath', $packagePath, '-ProcessApprovalManifestPath', $approvalManifestPath, '-SafeMode', '-SkipDefaultRoots') -TimeoutMilliseconds 120000 -MaxOutputBytes 65536
    $failureCode = [regex]::Match([string]$result.stdout, 'MACHINE_HANDOFF_STATUS=ERROR CODE=[A-Z0-9_]+').Value
    Assert-PrepareIntegration -Condition ($result.exitCode -eq 0 -and $result.stdout -match 'MACHINE_HANDOFF_STATUS=OK MODE=PREPARE') -Message ('Standard safe prepare produces a v2 Package through the published entrypoint [exit=' + $result.exitCode + '; timedOut=' + $result.timedOut + '; error=' + $result.errorCode + '; ' + $failureCode + ']')

    $snapshotPath = Join-Path $packagePath 'manifests\source.snapshot.json'
    $snapshot = Read-MHJson -Path $snapshotPath
    Test-MHSnapshot -Snapshot $snapshot
    Assert-PrepareIntegration -Condition ($snapshot.schemaVersion -eq 2 -and $snapshot.profile -eq 'Standard') -Message 'prepared source snapshot passes v2 schema validation'
    Assert-MHPackageGeneration -PackagePath $packagePath
    Assert-PrepareIntegration -Condition (Test-Path -LiteralPath (Join-Path $packagePath 'manifests\generation.json') -PathType Leaf) -Message 'prepare publishes a verifiable generation manifest'

    $restoreResult = Invoke-MHSafeProcess -Name 'powershell.exe' -Arguments @('-NoProfile', '-File', $entryPath, '-Mode', 'Restore', '-PackagePath', $packagePath, '-ProcessApprovalManifestPath', $approvalManifestPath, '-SafeMode', '-SkipDefaultRoots') -TimeoutMilliseconds 120000 -MaxOutputBytes 65536
    Assert-PrepareIntegration -Condition ($restoreResult.exitCode -eq 0 -and $restoreResult.stdout -match 'MACHINE_HANDOFF_STATUS=OK MODE=RESTORE PLAN_STATUS=') -Message 'Restore writes a plan but requires explicit plan/action approval before execution'
    $restorePlan = Read-MHJson -Path (Join-Path $packagePath 'manifests\restore-plan.json')
    $restoreDecision = Read-MHJson -Path (Join-Path $packagePath 'manifests\restore-result.json')
    Assert-PrepareIntegration -Condition ($restorePlan.planSha256 -match '^[A-Fa-f0-9]{64}$' -and $restoreDecision.status -in @('APPROVAL_REQUIRED', 'NO_ACTIONS', 'REVIEW_ONLY', 'PLAN_BLOCKED') -and @($restoreDecision.actions | Where-Object { $null -ne $_.PSObject.Properties['executionState'] -and $_.executionState -eq 'EXECUTED' }).Count -eq 0) -Message 'Restore plan hash and pending approval status are persisted without executing actions'
    Assert-MHPackageGeneration -PackagePath $packagePath
} finally {
    if (Test-Path -LiteralPath $packagePath) { Remove-Item -LiteralPath $packagePath -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $approvalManifestPath -PathType Leaf) { Remove-Item -LiteralPath $approvalManifestPath -Force -ErrorAction SilentlyContinue }
}

Write-Output 'Prepare integration suite passed.'
