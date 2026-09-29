[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')

function Assert-GitProbeSafety {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Git probe safety check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$script:gitConfigValue = $null
$script:gitConfigError = $null
$script:gitProbeCalls = New-Object System.Collections.ArrayList

function Invoke-MHSafeProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [int]$TimeoutMilliseconds = 5000,
        [int]$MaxOutputBytes = 65536,
        $Context
    )

    $argumentCopy = @($Arguments)
    [void]$script:gitProbeCalls.Add([pscustomobject]@{ name = $Name; arguments = $argumentCopy })
    if ($argumentCopy -contains 'config' -and $argumentCopy -contains 'core.fsmonitor') {
        if ($script:gitConfigError) {
            return [pscustomobject]@{ found = $true; started = $true; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = $script:gitConfigError }
        }
        if ($null -eq $script:gitConfigValue) {
            return [pscustomobject]@{ found = $true; started = $true; exitCode = 1; timedOut = $false; stdout = ''; stderr = ''; errorCode = $null }
        }
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = [string]$script:gitConfigValue; stderr = ''; errorCode = $null }
    }
    if ($argumentCopy -contains 'status') {
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = "## main`n"; stderr = ''; errorCode = $null }
    }
    if ($argumentCopy -contains 'branch') {
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = "main`n"; stderr = ''; errorCode = $null }
    }
    if ($argumentCopy -contains 'remote') {
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = "origin`n"; stderr = ''; errorCode = $null }
    }
    return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = ''; stderr = ''; errorCode = $null }
}

$context = New-MHCollectionContext -Profile Standard
$script:gitConfigValue = 'C:\Fixture\untrusted-fsmonitor.cmd'
$script:gitProbeCalls.Clear()
$hookResult = Get-MHGitFact -Path 'C:\Fixture\repo' -Context $context
$statusWasCalled = @($script:gitProbeCalls | Where-Object { $_.arguments -contains 'status' }).Count -gt 0
Assert-GitProbeSafety -Condition (-not $hookResult.checked -and $hookResult.errorCode -eq 'GIT_FSMONITOR_HOOK_SKIPPED' -and -not $statusWasCalled) -Message 'an executable core.fsmonitor hook prevents Git status from running'

$script:gitConfigValue = 'false'
$script:gitConfigError = $null
$script:gitProbeCalls.Clear()
$disabledResult = Get-MHGitFact -Path 'C:\Fixture\repo' -Context $context
$statusWasCalled = @($script:gitProbeCalls | Where-Object { $_.arguments -contains 'status' }).Count -gt 0
Assert-GitProbeSafety -Condition ($disabledResult.checked -and $statusWasCalled) -Message 'explicitly disabled core.fsmonitor permits the read-only Git status probe'

Write-Output 'Git probe safety suite passed.'
