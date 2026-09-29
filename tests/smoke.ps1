[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

$scriptsDirectory = Join-Path $repositoryRoot 'scripts'
$expectedScriptNames = @('collect.ps1', 'state.ps1', 'machine-handoff.ps1')
foreach ($scriptName in $expectedScriptNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptsDirectory $scriptName) -PathType Leaf)) {
        throw ('Required PowerShell script is missing: ' + $scriptName)
    }
}
$scriptFiles = @(Get-ChildItem -LiteralPath $scriptsDirectory -Filter '*.ps1' -File -Recurse)
foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ('PowerShell syntax errors in ' + $scriptFile.Name) }
}
if ($scriptFiles.Count -eq 0) { throw 'No PowerShell scripts were found for parsing.' }
Write-Output ('PASS: PowerShell syntax in ' + $scriptFiles.Count + ' scripts')

function Assert-Smoke {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw ('Smoke check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function New-FixtureStatus {
    param([string]$Status = 'OK', $Metadata = $null)

    if ($null -eq $Metadata) { $Metadata = [pscustomobject]@{} }
    return [pscustomobject]@{ status = $Status; warnings = @(); metadata = $Metadata }
}

function New-FixtureSnapshot {
    param(
        [ValidateSet('SOURCE', 'DESTINATION')][string]$Role,
        [object[]]$SoftwareItems = @(),
        [object[]]$EnvironmentVariables = @(),
        [object[]]$WslItems = @()
    )

    $domainStatus = [ordered]@{
        system = New-FixtureStatus
        env = New-FixtureStatus
        software = New-FixtureStatus -Metadata ([pscustomobject]@{ wingetStatus = 'OK' })
        dev = New-FixtureStatus
        shell = New-FixtureStatus
        editors = New-FixtureStatus
        agents = New-FixtureStatus
        wsl = New-FixtureStatus -Metadata ([pscustomobject]@{ status = 'OK' })
        data = New-FixtureStatus -Metadata ([pscustomobject]@{ scanTruncated = $false; skippedRootCount = 0 })
    }

    return [pscustomobject]@{
        schemaVersion = 1
        snapshotId = [guid]::NewGuid().ToString()
        sourceId = 'smoke-source'
        role = $Role
        collectedAt = [DateTimeOffset]::Now.ToString('o')
        platform = 'windows'
        collection = [pscustomobject]@{ roots = @(); excludes = @(); maxDepth = 0; domainStatus = [pscustomobject]$domainStatus }
        system = [pscustomobject]@{ computerLabel = 'smoke-host'; userProfile = 'C:\SmokeProfile' }
        env = [pscustomobject]@{ variables = @($EnvironmentVariables); path = [pscustomobject]@{ USER = @(); MACHINE = @() } }
        software = @($SoftwareItems)
        dev = @()
        shell = [pscustomobject]@{}
        editors = @()
        agents = @()
        wsl = @($WslItems)
        dataLocations = @()
        unbackedDataCandidates = @()
        manualItems = @()
    }
}

$source = New-FixtureSnapshot -Role SOURCE
$destination = New-FixtureSnapshot -Role DESTINATION
Test-MHSnapshot -Snapshot $source
Test-MHSnapshot -Snapshot $destination
Assert-Smoke -Condition $true -Message 'synthetic source and destination snapshots satisfy schema v1'

$emptyDecisions = New-MHDefaultDecisions
Test-MHDecisions -Decisions $emptyDecisions
Assert-Smoke -Condition ($emptyDecisions.pathMappings.Count -eq 0 -and $emptyDecisions.exclusions.Count -eq 0 -and $emptyDecisions.policyOverrides.Count -eq 0 -and $emptyDecisions.approvals.Count -eq 0) -Message 'empty decisions arrays validate'

$source = New-FixtureSnapshot -Role SOURCE -SoftwareItems @(
    [pscustomobject]@{ id = 'review-me'; state = 'PRESENT'; restorePolicy = 'RESTORE' },
    [pscustomobject]@{ id = 'restore-me'; state = 'PRESENT'; restorePolicy = 'REVIEW' },
    [pscustomobject]@{ id = 'skip-me'; state = 'PRESENT'; restorePolicy = 'RESTORE' },
    [pscustomobject]@{ id = 'exclude-me'; state = 'PRESENT'; restorePolicy = 'REVIEW' }
)
$destination = New-FixtureSnapshot -Role DESTINATION
$decisions = New-MHDefaultDecisions
$decisions.policyOverrides = @(
    [pscustomobject]@{ component = 'software|review-me'; restorePolicy = 'REVIEW' },
    [pscustomobject]@{ component = 'software|restore-me'; restorePolicy = 'RESTORE' },
    [pscustomobject]@{ component = 'software|skip-me'; restorePolicy = 'SKIP' },
    [pscustomobject]@{ component = 'software|exclude-me'; restorePolicy = 'RESTORE' }
)
$decisions.exclusions = @('software|exclude-me')
Test-MHDecisions -Decisions $decisions
$diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
$itemsByComponent = @{}
foreach ($item in $diff.items) { $itemsByComponent[$item.component] = $item }
Assert-Smoke -Condition ($itemsByComponent['software|review-me'].action -eq 'REVIEW') -Message 'REVIEW policy produces REVIEW action'
Assert-Smoke -Condition ($itemsByComponent['software|restore-me'].action -eq 'INSTALL') -Message 'RESTORE policy produces an install suggestion for an absent software item'
Assert-Smoke -Condition ($itemsByComponent['software|skip-me'].action -eq 'SKIP') -Message 'SKIP policy produces SKIP action'
Assert-Smoke -Condition ($itemsByComponent['software|exclude-me'].action -eq 'SKIP') -Message 'explicit exclusion takes precedence over a RESTORE override'

$incompleteSource = New-FixtureSnapshot -Role SOURCE -SoftwareItems @(
    [pscustomobject]@{ id = 'needs-review'; state = 'PRESENT'; restorePolicy = 'RESTORE' }
)
$incompleteDestination = New-FixtureSnapshot -Role DESTINATION
$incompleteDestination.collection.domainStatus.software.status = 'ERROR'
$incompleteDiff = New-MHDiff -Source $incompleteSource -Destination $incompleteDestination -Decisions (New-MHDefaultDecisions)
Assert-Smoke -Condition ($incompleteDiff.items[0].action -eq 'REVIEW' -and $incompleteDiff.items[0].status -eq 'REVIEW') -Message 'incomplete destination collector downgrades install to REVIEW'

$safeSource = New-FixtureSnapshot -Role SOURCE -EnvironmentVariables @(
    [pscustomobject]@{ scope = 'USER'; name = 'SMOKE_SAFE_PATH'; value = 'C:\SafeA'; isSecret = $false }
)
$safeDestination = New-FixtureSnapshot -Role DESTINATION -EnvironmentVariables @(
    [pscustomobject]@{ scope = 'USER'; name = 'SMOKE_SAFE_PATH'; value = 'C:\SafeB'; isSecret = $false }
)
$validation = New-MHValidation -Diff ([pscustomobject]@{ items = @() }) -Source $safeSource -Destination $safeDestination -Decisions (New-MHDefaultDecisions)
$environmentCheck = @($validation.checks | Where-Object component -eq 'env:variables')[0]
Assert-Smoke -Condition ($environmentCheck.status -eq 'WARN') -Message 'different same-name safe environment values validate as WARN'

$stoppedDistro = [pscustomobject]@{
    id = 'wsl:smoke-distro'; name = 'smoke-distro'; state = 'PRESENT'; running = $false
    version = 2; configState = 'NOT_TESTED_NOT_RUNNING'; safeSettings = @(); restorePolicy = 'RESTORE'
}
$wslSource = New-FixtureSnapshot -Role SOURCE -WslItems @($stoppedDistro)
$wslDestination = New-FixtureSnapshot -Role DESTINATION -WslItems @($stoppedDistro)
$wslDecisions = New-MHDefaultDecisions
$wslDecisions.policyOverrides = @([pscustomobject]@{ component = 'wsl|wsl:smoke-distro'; restorePolicy = 'RESTORE' })
$wslValidation = New-MHValidation -Diff ([pscustomobject]@{ items = @() }) -Source $wslSource -Destination $wslDestination -Decisions $wslDecisions
$wslCheck = @($wslValidation.checks | Where-Object component -eq 'wsl-config:wsl:smoke-distro')[0]
Assert-Smoke -Condition ($wslCheck.status -eq 'UNKNOWN' -and $wslCheck.status -ne 'PASS') -Message 'stopped WSL config remains UNKNOWN and never PASS'
$wslMainDiffItem = [pscustomobject]@{
    component = 'wsl|wsl:smoke-distro'; sourceState = $stoppedDistro; destinationState = $stoppedDistro
    action = 'RECREATE'; reason = 'synthetic stopped WSL distro'
}
$wslMainValidation = New-MHValidation -Diff ([pscustomobject]@{ items = @($wslMainDiffItem) }) -Source $wslSource -Destination $wslDestination -Decisions $wslDecisions
$wslMainCheck = @($wslMainValidation.checks | Where-Object component -eq 'wsl|wsl:smoke-distro')[0]
Assert-Smoke -Condition ($wslMainCheck.status -eq 'UNKNOWN') -Message 'stopped WSL main component remains UNKNOWN'

$sentinel = 'SMOKE_' + [guid]::NewGuid().ToString('N')
$sentinelText = '{"api_key":"' + $sentinel + '"}'
$blocked = $false
try {
    Test-MHSerializedText -Text $sentinelText
} catch {
    $blocked = $_.Exception.Message -eq 'REDACTION_BLOCKED' -and -not $_.Exception.Message.Contains($sentinel)
}
Assert-Smoke -Condition $blocked -Message 'synthetic api_key is blocked without echoing its value'

$skillText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'SKILL.md') -Raw -Encoding UTF8
$references = @([regex]::Matches($skillText, '\]\((references/[^)]+)\)') | ForEach-Object { $_.Groups[1].Value })
$referencesExist = $references.Count -gt 0
foreach ($reference in $references) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $reference) -PathType Leaf)) { $referencesExist = $false }
}
Assert-Smoke -Condition $referencesExist -Message 'all linked Skill reference files exist'

$originalSafeProcess = (Get-Item Function:Invoke-MHSafeProcess).ScriptBlock
$originalGetCommandFunction = Get-Item Function:Get-Command -ErrorAction SilentlyContinue
try {
    Set-Item Function:Get-Command -Value {
        param([string]$Name, [object]$CommandType, [string]$ErrorAction)
        if ($Name -eq 'winget.exe') { return [pscustomobject]@{ Name = 'winget.exe'; Source = 'synthetic-winget.exe' } }
        return Microsoft.PowerShell.Core\Get-Command -Name $Name -CommandType $CommandType -ErrorAction $ErrorAction
    }
    Set-Item Function:Invoke-MHSafeProcess -Value {
        param([string]$Name, [string[]]$Arguments, [int]$TimeoutMilliseconds, [int]$MaxOutputBytes, $Context)
        $manifest = '{"Packages":[{"PackageIdentifier":"Synthetic.App","Version":"1.0"}]}'
        [IO.File]::WriteAllText($Arguments[2], $manifest, (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; errorCode = $null }
    }
    $wingetContext = New-MHCollectionContext -Profile Standard
    $wingetContext.budgets.maxPackageBytes = 16
    $wingetFacts = Get-MHWingetFacts -Context $wingetContext
} finally {
    if ($originalGetCommandFunction) { Set-Item Function:Get-Command -Value $originalGetCommandFunction.ScriptBlock }
    else { Remove-Item Function:Get-Command -ErrorAction SilentlyContinue }
    Set-Item Function:Invoke-MHSafeProcess -Value $originalSafeProcess
}
Assert-Smoke -Condition ($wingetFacts.status -eq 'EXPORT_UNAVAILABLE' -and @($wingetFacts.packages).Count -eq 0) -Message 'oversized winget export is rejected before unbounded JSON parsing'

Write-Output 'Smoke suite passed.'
