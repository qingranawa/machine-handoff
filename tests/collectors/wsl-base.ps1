[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

function Assert-WslBase {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('WSL base collector check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$script:processCallCount = 0
function Invoke-MHSafeProcess {
    param([string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 5000, [int]$MaxOutputBytes = 65536, $Context)
    $script:processCallCount++
    return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempRoot ('mh-wsl-base-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $fixtureRoot 'home'
$outsideHome = Join-Path $fixtureRoot 'outside-home'
[void](New-Item -ItemType Directory -Path @($fixtureHome, $outsideHome) -Force)
try {
    $wslConfig = Join-Path $fixtureHome '.wslconfig'
    [IO.File]::WriteAllText($wslConfig, "[wsl2]`nmemory=8GB`nprocessors=4`npassword=not-retained`n", (New-Object System.Text.UTF8Encoding($false)))
    $context = New-MHCollectionContext -Profile Standard -SafeMode
    $context | Add-Member -NotePropertyName userProfile -NotePropertyValue $fixtureHome -Force
    $result = Get-MHWslFacts -SafeMode -Context $context
    Assert-WslBase ($result.configState -eq 'PRESENT' -and @($result.safeSettings).Count -eq 2) 'SafeMode keeps bounded allowlisted .wslconfig settings'
    Assert-WslBase ($script:processCallCount -eq 0) 'SafeMode performs no WSL process probes'
    Assert-WslBase ((ConvertTo-Json $result -Depth 10 -Compress) -notmatch 'password|not-retained') 'unsupported WSL settings and values are not returned'

    $externalConfig = Join-Path $outsideHome '.wslconfig'
    [IO.File]::WriteAllText($externalConfig, "[wsl2]`nmemory=99GB`n", (New-Object System.Text.UTF8Encoding($false)))
    $junctionHome = Join-Path $fixtureRoot 'junction-home'
    $junctionCreated = $false
    try { [void](New-Item -ItemType Junction -Path $junctionHome -Target $outsideHome -ErrorAction Stop); $junctionCreated = $true } catch { }
    if ($junctionCreated) {
        $script:processCallCount = 0
        $blockedContext = New-MHCollectionContext -Profile Standard -SafeMode
        $blockedContext | Add-Member -NotePropertyName userProfile -NotePropertyValue $junctionHome -Force
        $blocked = Get-MHWslFacts -SafeMode -Context $blockedContext
    Assert-WslBase ($blocked.configState -eq 'UNKNOWN' -and @($blocked.safeSettings).Count -eq 0) 'junction-backed .wslconfig is rejected before reading external content'
    Assert-WslBase ($script:processCallCount -eq 0) 'unsafe .wslconfig path does not trigger any WSL command'
    [IO.Directory]::Delete($junctionHome, $false)
    $uncContext = New-MHCollectionContext -Profile Standard -SafeMode
    $uncContext | Add-Member -NotePropertyName userProfile -NotePropertyValue '\\server.invalid\profile' -Force
    $uncResult = Get-MHWslFacts -SafeMode -Context $uncContext
    Assert-WslBase ($uncResult.configState -eq 'UNKNOWN' -and $null -eq $uncResult.configPath -and $script:processCallCount -eq 0) 'UNC profile paths are marked unknown without a filesystem probe'
    } else {
        throw 'WSL base fixture requires junction support.'
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { [IO.Directory]::Delete($fixtureRoot, $true) }
}

Write-Output 'WSL base collector tests passed.'
