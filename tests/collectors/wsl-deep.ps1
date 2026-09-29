[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')
. (Join-Path $repositoryRoot 'scripts\collectors\wsl-deep.ps1')

function Assert-WslDeep {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('WSL deep collector test failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$script:processCalls = @()
$script:processFailure = $null
$script:runningListMode = 'RUNNING'
function Invoke-MHSafeProcess {
    param([string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 5000, [int]$MaxOutputBytes = 65536, $Context)
    $script:processCalls += [pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Timeout = $TimeoutMilliseconds }
    if ($script:processFailure -and $Arguments -contains '-d') { return [pscustomobject]@{ found = $true; exitCode = 1; timedOut = $false; errorCode = $null; stdout = '' } }
    if ($Arguments -contains '--version') { return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'WSL version: 2.4.0' } }
    if ($Arguments -contains '--status') { return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = "Default Distribution: Ubuntu-Running`nDefault Version: 2" } }
    if ($Arguments -contains '--running' -and $Arguments -contains '--quiet') {
        if ($script:runningListMode -eq 'FAILURE') { return [pscustomobject]@{ found = $true; exitCode = 1; timedOut = $false; errorCode = $null; stdout = '' } }
        $runningNames = if ($script:runningListMode -eq 'STOPPED') { '' } else { 'Ubuntu-Running' }
        return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = $runningNames }
    }
    if ($Arguments -contains '--verbose') { return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = "  NAME            STATE           VERSION`n* Ubuntu-Running  Running         2`n  Ubuntu-Stopped  Stopped         2" } }
    if ($Arguments -contains '-d' -and $Arguments -contains 'Ubuntu-Running') { return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = "user=devuser`nshell=bash`npackageManager=apt`ntoolchain=git,node,npm,python3,docker`ngitVersion=git version 2.43.0`ndocker=Docker version 24.0.7, build fixture`nsshDir=PRESENT`ndotfiles=.bashrc,.gitconfig`nworkRoot=/work/src`nwslconf`n[automount].enabled=true`n[automount].root=/mnt/" } }
    return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-wsl-deep-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
try {
    $globalConfig = Join-Path $fixtureRoot '.wslconfig'
    Set-Content -LiteralPath $globalConfig -Value "[wsl2]`nmemory=8GB`nprocessors=4`npassword=fixture-only" -Encoding UTF8
    $context = New-MHCollectionContext -Profile Deep
    $context | Add-Member -NotePropertyName wslDeepConfigPath -NotePropertyValue $globalConfig
    $result = Get-MHDeepWslCollection -Context $context
    $payload = $result.items[0]
    $stopped = @($payload.distributions | Where-Object name -eq 'Ubuntu-Stopped')[0]
    $running = @($payload.distributions | Where-Object name -eq 'Ubuntu-Running')[0]
    $stoppedProbes = @($script:processCalls | Where-Object { $_.Arguments -contains '-d' -and $_.Arguments -contains 'Ubuntu-Stopped' })
    $runningProbeCall = @($script:processCalls | Where-Object { $_.Arguments -contains '-d' -and $_.Arguments -contains 'Ubuntu-Running' })[0]
    Assert-WslDeep ($result.domain -eq 'wslDeep' -and $stopped.running -eq $false -and $stopped.probeStatus -eq 'NOT_TESTED_NOT_RUNNING') 'stopped distro has explicit not-tested status'
    Assert-WslDeep ($stoppedProbes.Count -eq 0) 'stopped distro is never passed to a -d probe'
    $shellIndex = [Array]::IndexOf([string[]]$runningProbeCall.Arguments, 'sh')
    Assert-WslDeep ($shellIndex -ge 0 -and $runningProbeCall.Arguments[$shellIndex + 1] -eq '-c' -and $runningProbeCall.Arguments -notcontains '-l' -and $runningProbeCall.Arguments -notcontains '-lc') 'running distro probe uses a non-login shell and does not load profile files'
    Assert-WslDeep (@($running.clues).Count -gt 0 -and @($running.clues | Where-Object name -eq 'docker').Count -eq 1) 'running distro returns bounded toolchain clues'
    Assert-WslDeep (@($running.clues | Where-Object { $_.name -eq 'docker' -and $_.value -eq '24.0.7' }).Count -eq 1) 'Docker version is reduced to its version number'
    Assert-WslDeep ($running.wslConfigState -eq 'PRESENT' -and @($running.wslConfigSettings | Where-Object name -eq '[automount].enabled').Count -eq 1) 'running distro returns allowlisted wsl.conf settings'
    Assert-WslDeep ($payload.defaultDistribution -eq 'Ubuntu-Running' -and $payload.version -eq '2.4.0' -and $payload.defaultVersion -eq 2) 'default distro and WSL default/app versions are captured'
    Assert-WslDeep (@($payload.globalConfig.safeSettings).Count -eq 2) 'only allowlisted .wslconfig keys are retained'
    Assert-WslDeep ((ConvertTo-Json $result -Depth 10 -Compress) -notmatch 'password|fixture-only') 'unknown global settings are discarded'

    $script:processCalls = @()
    $safeContext = New-MHCollectionContext -Profile Deep -SafeMode
    $safeContext | Add-Member -NotePropertyName wslDeepConfigPath -NotePropertyValue $globalConfig
    $safeResult = Get-MHDeepWslCollection -Context $safeContext
    Assert-WslDeep ($script:processCalls.Count -eq 0 -and $safeResult.status -eq 'PARTIAL' -and $safeResult.warnings -contains 'WSL_SAFE_MODE_NOT_TESTED' -and @($safeResult.items[0].globalConfig.safeSettings).Count -eq 2) 'SafeMode keeps allowlisted global config but performs no WSL process probes'

    $script:processCalls = @()
    $script:runningListMode = 'STOPPED'
    $stoppedBetweenChecksResult = Get-MHDeepWslCollection -Context $context
    $stoppedBetweenChecksDistro = @($stoppedBetweenChecksResult.items[0].distributions | Where-Object name -eq 'Ubuntu-Running')[0]
    $stoppedBetweenChecksCalls = @($script:processCalls | Where-Object { $_.Arguments -contains 'Ubuntu-Running' -and $_.Arguments -contains '-d' })
    Assert-WslDeep (@($script:processCalls | Where-Object { $_.Arguments -contains '--running' -and $_.Arguments -contains '--quiet' }).Count -eq 1 -and $stoppedBetweenChecksCalls.Count -eq 0 -and $stoppedBetweenChecksDistro.probeStatus -eq 'NOT_TESTED_NOT_RUNNING') 'distro that stops between listings is not started by a -d probe'

    $script:processCalls = @()
    $script:runningListMode = 'FAILURE'
    $runningListFailureResult = Get-MHDeepWslCollection -Context $context
    $runningListFailureDistro = @($runningListFailureResult.items[0].distributions | Where-Object name -eq 'Ubuntu-Running')[0]
    $runningListFailureCalls = @($script:processCalls | Where-Object { $_.Arguments -contains 'Ubuntu-Running' -and $_.Arguments -contains '-d' })
    Assert-WslDeep ($runningListFailureCalls.Count -eq 0 -and $runningListFailureDistro.probeStatus -eq 'UNKNOWN') 'failed running-only recheck leaves running distro unknown without starting it'

    $externalRoot = Join-Path $fixtureRoot 'external-config-home'
    [void](New-Item -ItemType Directory -Path $externalRoot)
    $externalConfig = Join-Path $externalRoot '.wslconfig'
    Set-Content -LiteralPath $externalConfig -Value "[wsl2]`nmemory=99GB`nfixtureSentinel=OUTSIDE_TARGET" -Encoding UTF8
    $junctionHome = Join-Path $fixtureRoot 'junction-home'
    $junctionCreated = $false
    try {
        [void](New-Item -ItemType Junction -Path $junctionHome -Target $externalRoot -ErrorAction Stop)
        $junctionCreated = $true
    } catch { }
    if ($junctionCreated) {
        $junctionContext = New-MHCollectionContext -Profile Deep
        $junctionContext | Add-Member -NotePropertyName wslDeepConfigPath -NotePropertyValue (Join-Path $junctionHome '.wslconfig')
        $junctionConfig = Get-MHDeepWslGlobalConfig -Context $junctionContext
        Assert-WslDeep ($junctionConfig.state -eq 'UNKNOWN' -and @($junctionConfig.safeSettings).Count -eq 0) 'junction-backed config is refused before reading the external file'
        try { [IO.Directory]::Delete($junctionHome, $false) }
        catch { [void](& $env:ComSpec /d /c rmdir $junctionHome 2>$null) }
    } else {
        Assert-WslDeep $false 'test host must create a temporary junction to verify external config is not followed'
    }
    $script:originalPathGuard = (Get-Command -Name Assert-MHNoReparseAncestors -CommandType Function).ScriptBlock
    $script:forcedPathCheckFailure = $externalConfig
    function Assert-MHNoReparseAncestors {
        param([Parameter(Mandatory)][string]$Path)
        if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:forcedPathCheckFailure)) { throw 'PATH_CHECK_FAILED' }
        & $script:originalPathGuard -Path $Path
    }
    $guardFailureContext = New-MHCollectionContext -Profile Deep
    $guardFailureContext | Add-Member -NotePropertyName wslDeepConfigPath -NotePropertyValue $externalConfig
    $guardFailureResult = Get-MHDeepWslGlobalConfig -Context $guardFailureContext
    Assert-WslDeep ($guardFailureResult.state -eq 'UNKNOWN' -and @($guardFailureResult.safeSettings).Count -eq 0) 'attribute-check failure fails closed without reading config content'
    $uncConfigContext = New-MHCollectionContext -Profile Deep
    $uncConfigContext | Add-Member -NotePropertyName wslDeepConfigPath -NotePropertyValue '\\server.invalid\share\.wslconfig' -Force
    $uncConfigResult = Get-MHDeepWslGlobalConfig -Context $uncConfigContext
    Assert-WslDeep ($uncConfigResult.state -eq 'UNKNOWN' -and @($uncConfigResult.safeSettings).Count -eq 0) 'UNC global config path is rejected without a filesystem probe'

    $script:originalBoundedReader = (Get-Command -Name Read-MHBoundedUtf8Text -CommandType Function).ScriptBlock
    $script:boundedReaderCalls = 0
    function Read-MHBoundedUtf8Text {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaxBytes)
        if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:globalConfig)) {
            [IO.File]::WriteAllText($Path, ('x' * ($MaxBytes + 1)), [Text.Encoding]::UTF8)
        }
        $script:boundedReaderCalls++
        & $script:originalBoundedReader -Path $Path -MaxBytes $MaxBytes
    }
    $racingConfigResult = Get-MHDeepWslGlobalConfig -Context $context
    Assert-WslDeep ($script:boundedReaderCalls -eq 1 -and $racingConfigResult.state -eq 'UNKNOWN' -and @($racingConfigResult.safeSettings).Count -eq 0) 'global config growth between metadata check and read stays bounded and fails closed'
    Set-Item -Path Function:\Read-MHBoundedUtf8Text -Value $script:originalBoundedReader
    Set-Content -LiteralPath $globalConfig -Value "[wsl2]`nmemory=8GB`nprocessors=4`npassword=fixture-only" -Encoding UTF8

    $script:processCalls = @()
    $script:processFailure = $true
    $script:runningListMode = 'RUNNING'
    $failed = Get-MHDeepWslCollection -Context $context
    $failedRunning = @($failed.items[0].distributions | Where-Object name -eq 'Ubuntu-Running')[0]
    Assert-WslDeep ($failed.status -eq 'PARTIAL' -and $failedRunning.probeStatus -eq 'UNKNOWN') 'failed running-distro probe creates a local unknown status'

    $script:processCalls = @()
    $script:processFailure = $false
    $script:runningListMode = 'RUNNING'
    function Invoke-MHSafeProcess { param([string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 5000, [int]$MaxOutputBytes = 65536, $Context); return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' } }
    $missing = Get-MHDeepWslCollection -Context $context
    Assert-WslDeep ($missing.status -in @('PARTIAL', 'UNAVAILABLE') -and @($missing.warnings).Count -gt 0) 'missing WSL command produces a local unavailable status and fixed warning'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Output 'WSL deep collector tests passed.'
