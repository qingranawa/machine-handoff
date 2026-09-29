[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\process.ps1')

function Assert-Unit {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Unit check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$standard = New-MHCollectionContext -Profile Standard -Roots @('C:\Fixture')
$deep = New-MHCollectionContext -Profile Deep -Roots @('C:\Fixture')
Assert-Unit -Condition ($standard.profile -eq 'Standard' -and $deep.profile -eq 'Deep') -Message 'collection context preserves selected profile'
Assert-Unit -Condition ($standard.budgets.globalTimeoutMs -lt $deep.budgets.globalTimeoutMs) -Message 'Deep budget exceeds Standard while both remain bounded'
Assert-Unit -Condition ($standard.roots.Count -eq 1 -and $standard.roots[0] -eq 'C:\Fixture') -Message 'collection context preserves explicit roots'
$standard | Add-Member -NotePropertyName syntheticCollectorFixture -NotePropertyValue 'fixture-only' -Force
$domainContext = New-MHDomainContext -Context $standard
Assert-Unit -Condition ($domainContext.syntheticCollectorFixture -eq 'fixture-only' -and [object]::ReferenceEquals($domainContext.budgets, $standard.budgets)) -Message 'domain contexts preserve injected fixture metadata and shared mutable budget state'

$legacy = [pscustomobject]@{
    schemaVersion = 1; snapshotId = 'legacy-snapshot'; sourceId = 'legacy-source'; role = 'SOURCE'
    collectedAt = [DateTimeOffset]::Now.ToString('o'); platform = 'windows'
    collection = [pscustomobject]@{ roots = @(); excludes = @(); maxDepth = 3; domainStatus = [pscustomobject]@{} }
    system = [pscustomobject]@{}; env = [pscustomobject]@{}; software = @(); dev = @(); shell = [pscustomobject]@{}
    editors = @(); agents = @(); wsl = @(); dataLocations = @(); unbackedDataCandidates = @(); manualItems = @()
}
$upgraded = ConvertTo-MHV2Snapshot -Snapshot $legacy -Profile Standard -ConfigArtifacts @()
Assert-Unit -Condition ($upgraded.schemaVersion -eq 2 -and $upgraded.configArtifacts.Count -eq 0) -Message 'v1 snapshot adapts to v2 without inventing config artifacts'
Assert-Unit -Condition ($upgraded.sourceId -eq $legacy.sourceId -and $upgraded.snapshotId -eq $legacy.snapshotId) -Message 'v1 adapter preserves snapshot identity'
Test-MHSnapshot -Snapshot $legacy
Test-MHSnapshot -Snapshot $upgraded
$oversizedSnapshot = ConvertTo-MHV2Snapshot -Snapshot $legacy -Profile Standard
$oversizedSnapshot.software = @(for ($index = 0; $index -lt 513; $index++) { [pscustomobject]@{ id = ('software:test:' + $index); state = 'PRESENT' } })
$snapshotLimitError = $null
try { Test-MHSnapshot -Snapshot $oversizedSnapshot } catch { $snapshotLimitError = $_.Exception.Message }
Assert-Unit -Condition ($snapshotLimitError -eq 'SNAPSHOT_LIMIT') -Message 'snapshot list sizes respect the persisted collection profile budget'
$oversizedDecisions = New-MHDefaultDecisions
$oversizedDecisions.exclusions = @(for ($index = 0; $index -lt 4097; $index++) { 'component:test:' + $index })
$decisionLimitError = $null
try { Test-MHDecisions -Decisions $oversizedDecisions } catch { $decisionLimitError = $_.Exception.Message }
Assert-Unit -Condition ($decisionLimitError -eq 'DECISIONS_LIMIT') -Message 'decision arrays have a hard item ceiling'

$destinationLegacy = [pscustomobject]@{}
foreach ($property in $legacy.PSObject.Properties) { $destinationLegacy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$destinationLegacy.role = 'DESTINATION'
$destinationLegacy.snapshotId = 'legacy-destination'
$sourceV2 = ConvertTo-MHV2Snapshot -Snapshot $legacy -Profile Deep
$destinationV2 = ConvertTo-MHV2Snapshot -Snapshot $destinationLegacy -Profile Deep
$gitStatus = [pscustomobject]@{ status = 'OK'; warnings = @(); metadata = [pscustomobject]@{} }
foreach ($domain in @('git', 'dev', 'editors', 'agents')) {
    $sourceV2.collection.domainStatus | Add-Member -NotePropertyName $domain -NotePropertyValue $gitStatus -Force
    $destinationV2.collection.domainStatus | Add-Member -NotePropertyName $domain -NotePropertyValue $gitStatus -Force
}
$sourceV2.git = @([pscustomobject]@{
    id = 'git:global'; state = 'PRESENT'; scope = 'global'; restorePolicy = 'RESTORE'
    settings = @([pscustomobject]@{ scope = 'system'; origin = 'C:\ProgramData\Git\config'; key = 'core.autocrlf'; value = 'false' })
    systemSettings = @([pscustomobject]@{ scope = 'system'; origin = 'C:\ProgramData\Git\config'; key = 'core.autocrlf'; value = 'false' })
})
$artifactHash = ('a' * 64)
$sourceV2.configArtifacts = @([pscustomobject]@{
    id = 'agents:mcp'; domain = 'agents'; sourceLocator = 'C:\Fixture\mcp.json'; targetPathCandidate = '%USERPROFILE%\.config\agent\mcp.json'
    contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE'; captureState = 'CAPTURED'; redactionStatus = 'REDACTED'
    artifactPath = 'configs/agents/mcp.' + $artifactHash.Substring(0, 16) + '.json'; artifactSha256 = $artifactHash
    restorePolicy = 'RESTORE'; dependsOn = @(); validationStrategy = 'NORMALIZED_CONFIG'
})
Test-MHSnapshot -Snapshot $sourceV2
Test-MHSnapshot -Snapshot $destinationV2
$diff = New-MHDiff -Source $sourceV2 -Destination $destinationV2 -Decisions (New-MHDefaultDecisions)
$diffByComponent = @{}
foreach ($item in $diff.items) { $diffByComponent[$item.component] = $item }
Assert-Unit -Condition ($diffByComponent['config|agents:mcp'].action -eq 'COPY') -Message 'a captured configuration artifact becomes a reviewed copy action'
Assert-Unit -Condition ($diffByComponent['git|git:global'].action -eq 'RECREATE') -Message 'Git settings participate in the v2 migration diff'

$destinationWithSystemGit = [pscustomobject]@{}
foreach ($property in $destinationV2.PSObject.Properties) { $destinationWithSystemGit | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$destinationWithSystemGit.git = @([pscustomobject]@{
    id = 'git:global'; state = 'PRESENT'; scope = 'global'; restorePolicy = 'RESTORE'
    settings = @([pscustomobject]@{ scope = 'system'; origin = 'C:\ProgramData\Git\config'; key = 'core.autocrlf'; value = 'false' })
    systemSettings = @([pscustomobject]@{ scope = 'system'; origin = 'C:\ProgramData\Git\config'; key = 'core.autocrlf'; value = 'true' })
})
$systemGitDiff = New-MHDiff -Source $sourceV2 -Destination $destinationWithSystemGit -Decisions (New-MHDefaultDecisions)
Assert-Unit -Condition (@($systemGitDiff.items | Where-Object component -eq 'git|git:global').Count -eq 1) -Message 'system-scope Git configuration differences remain visible in the diff'

$destinationV2.configArtifacts = @($sourceV2.configArtifacts)
$destinationV2.snapshotId = 'matching-destination'
$matchingDiff = New-MHDiff -Source $sourceV2 -Destination $destinationV2 -Decisions (New-MHDefaultDecisions)
$selected = New-MHDefaultDecisions
$selected.policyOverrides = @([pscustomobject]@{ component = 'config|agents:mcp'; restorePolicy = 'RESTORE' })
$matchingValidation = New-MHValidation -Diff $matchingDiff -Source $sourceV2 -Destination $destinationV2 -Decisions $selected
$configCheck = @($matchingValidation.checks | Where-Object component -eq 'config|agents:mcp' | Select-Object -First 1)
Assert-Unit -Condition ($configCheck.Count -eq 1 -and $configCheck[0].status -eq 'PASS') -Message 'matching sanitized artifact hashes validate as PASS'

$conflictingDestinationArtifact = [pscustomobject]@{}
foreach ($property in $sourceV2.configArtifacts[0].PSObject.Properties) { $conflictingDestinationArtifact | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$conflictingDestinationArtifact.artifactSha256 = ('b' * 64)
$destinationV2.configArtifacts = @($conflictingDestinationArtifact)
$conflictDecisions = New-MHDefaultDecisions
$conflictDecisions.policyOverrides = @([pscustomobject]@{ component = 'config|agents:mcp'; restorePolicy = 'RESTORE' })
$conflictDiff = New-MHDiff -Source $sourceV2 -Destination $destinationV2 -Decisions $conflictDecisions
$conflictItem = @($conflictDiff.items | Where-Object component -eq 'config|agents:mcp' | Select-Object -First 1)
Assert-Unit -Condition ($conflictItem.Count -eq 1 -and $conflictItem[0].action -eq 'COPY') -Message 'approved policy plans a backup-gated copy when a different config already exists'

$powerShellCommand = if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
$boundedOutput = Invoke-MHSafeProcess -Name $powerShellCommand -Arguments @('-NoProfile', '-Command', "Write-Output ('x' * 100000)") -TimeoutMilliseconds 10000 -MaxOutputBytes 1024 -Context $deep
Assert-Unit -Condition ($boundedOutput.stdout.Length -le 1024 -and $boundedOutput.stdoutTruncated) -Message 'process output is capped while the child is running'
$timedOut = Invoke-MHSafeProcess -Name $powerShellCommand -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -TimeoutMilliseconds 250 -MaxOutputBytes 1024 -Context $deep
Assert-Unit -Condition ($timedOut.timedOut -and $timedOut.errorCode -eq 'TIMEOUT') -Message 'process timeout terminates a slow child and reports a fixed code'
$cancelContext = New-MHCollectionContext -Profile Deep
$cancelContext.cancellationSource.CancelAfter(250)
$cancelled = Invoke-MHSafeProcess -Name $powerShellCommand -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -TimeoutMilliseconds 10000 -MaxOutputBytes 1024 -Context $cancelContext
Assert-Unit -Condition ($cancelled.cancelled -and $cancelled.errorCode -eq 'CANCELLED') -Message 'cancellation token stops a running child and returns a fixed code'

Write-Output 'Unit suite passed.'
