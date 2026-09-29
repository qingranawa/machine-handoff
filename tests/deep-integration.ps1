[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

$script:deepCollectorCalls = 0

function Assert-DeepIntegration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Deep integration check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function Get-MHSystemFacts { return [pscustomobject]@{ id = 'system'; state = 'PRESENT'; computerLabel = 'fixture-host'; userProfile = 'C:\Fixture'; windows = [pscustomobject]@{ productName = 'Windows'; version = 'fixture'; build = 1; is64Bit = $true }; volumes = @(); settings = @{} } }
function Get-MHEnvironmentFacts { return [pscustomobject]@{ id = 'env'; state = 'PRESENT'; variables = @(); path = [ordered]@{ USER = @(); MACHINE = @() } } }
function Get-MHSoftwareFacts { param($SafeMode, $Roots, $Context); return [pscustomobject]@{ id = 'software'; state = 'PRESENT'; wingetStatus = 'NOT_TESTED'; packages = @() } }
function Get-MHDevFacts { param($Context); return @([pscustomobject]@{ id = 'git'; state = 'PRESENT'; status = 'OK'; version = '2.0'; path = 'C:\Fixture\git.exe' }, [pscustomobject]@{ id = 'node'; state = 'PRESENT'; status = 'OK'; version = '18.0'; path = 'C:\Fixture\node.exe' }) }
function Get-MHShellFacts { param($Context); return [pscustomobject]@{ id = 'shell'; state = 'PRESENT'; currentPowerShell = '7'; terminal = $null; config = @() } }
function Get-MHEditorFacts { param($Context); return @([pscustomobject]@{ id = 'editor:vscode'; state = 'PRESENT'; extensions = @(); configFiles = @() }) }
function Get-MHAgentFacts { param($UserHome); return [pscustomobject]@{ id = 'agents'; state = 'PRESENT'; items = @([pscustomobject]@{ id = 'agent:codex'; state = 'PRESENT'; configPaths = @(); configFiles = @() }); configFiles = @() } }
function Get-MHWorkstationCollection { param($Context); return New-MHDomainResult -Domain 'workstation' -Status OK -Items @([pscustomobject]@{ id = 'workstation'; state = 'PRESENT'; architecture = 'X64'; cpu = @(); memoryBytes = 16GB; gpu = @(); storage = @(); optionalFeatures = @(); settings = @{}; proxy = @{}; applications = @{} }) }
function Get-MHWslFacts { param($SafeMode, $Context); return [pscustomobject]@{ id = 'wsl'; state = 'PRESENT'; status = 'NOT_TESTED'; items = @([pscustomobject]@{ id = 'wsl:global-config'; state = 'ABSENT'; configState = 'ABSENT'; safeSettings = @() }) } }
function Get-MHDataFacts { param($UserHome, $Roots, $Excludes, $MaxDepth, $SkipDefaultRoots, $Context); return [pscustomobject]@{ id = 'data'; state = 'PRESENT'; status = 'OK'; roots = @(); repositories = 0; scanTruncated = $false; skippedRootCount = 0; skippedBudgetRootCount = 0; rootsTruncated = $false; discoveryWarnings = @(); locations = @(); unbackedCandidates = @() } }

function Get-MHGitPowerShellCollection {
    param($Context)
    $script:deepCollectorCalls++
    $items = @(
        [pscustomobject]@{ id = 'git:global'; domain = 'git'; state = 'PRESENT'; settings = @([pscustomobject]@{ scope = 'global'; key = 'core.autocrlf'; value = 'false' }); includeRules = @(); credentialHelpers = @(); signing = [pscustomobject]@{ keyConfigured = $false }; globalIgnore = [pscustomobject]@{ state = 'ABSENT' }; configArtifacts = @() },
        [pscustomobject]@{ id = 'shell:powershell'; domain = 'shell'; state = 'PRESENT'; versions = @(); modules = @(); profiles = @(); configArtifacts = @() }
    )
    return New-MHDomainResult -Domain 'git-powershell' -Status OK -Items $items
}

function Get-MHEditorAgentCollection {
    param($Context)
    $script:deepCollectorCalls++
    $content = '{"apiKey":"<REDACTED>","theme":"dark"}' + [Environment]::NewLine
    $artifact = [pscustomobject]@{
        id = 'editor:vscode:settings'; domain = 'editors'; sourceLocator = 'C:\Fixture\settings.json'
        targetPathCandidate = '%APPDATA%\Code\User\settings.json'; contentPolicy = 'REDACTED_COPY'
        sensitivity = 'PRIVATE'; captureState = 'CAPTURED'; redactionStatus = 'REDACTED'
        artifactPath = 'configs/editors/settings.fixture.json'; artifactSha256 = Get-MHArtifactSha256 -Text $content
        restorePolicy = 'REVIEW'; dependsOn = @(); validationStrategy = 'NORMALIZED_CONFIG'; errorCode = $null
    }
    $wrapper = [pscustomobject]@{ artifact = $artifact; content = $content }
    $items = @(
        [pscustomobject]@{ id = 'editor:vscode'; domain = 'editors'; state = 'PRESENT'; status = 'FOUND'; extensions = @(); profiles = @(); configFiles = @(); launchStatus = 'NOT_TESTED'; restorePolicy = 'REVIEW' },
        [pscustomobject]@{ id = 'agent:codex'; domain = 'agents'; state = 'PRESENT'; status = 'FOUND'; configRoots = @(); configFiles = @(); auth = 'REAUTHENTICATE'; restorePolicy = 'REVIEW' }
    )
    return New-MHDomainResult -Domain 'editors-agents' -Status OK -Items $items -ConfigArtifacts @($wrapper)
}

function Get-MHRuntimeCollection {
    param($Context)
    $script:deepCollectorCalls++
    $items = @(
        [pscustomobject]@{ id = 'runtime:node'; state = 'PRESENT'; status = 'OK'; version = '22.1'; path = 'C:\Fixture\node.exe'; managers = @(); globalPackages = @(); installedVersions = @(); defaultVersion = '22.1'; configArtifacts = @() },
        [pscustomobject]@{ id = 'runtime:python'; state = 'ABSENT'; status = 'NOT_FOUND'; version = $null; path = $null; managers = @(); globalPackages = @(); interpreters = @(); configArtifacts = @() },
        [pscustomobject]@{ id = 'runtime:dotnet'; state = 'PRESENT'; status = 'OK'; version = '9.0'; path = 'C:\Fixture\dotnet.exe'; managers = @(); globalPackages = @(); sdks = @(); runtimes = @(); configArtifacts = @() }
    )
    return New-MHDomainResult -Domain 'runtimes' -Status OK -Items $items
}

function Get-MHDeepWslCollection {
    param($Context)
    $script:deepCollectorCalls++
    return New-MHDomainResult -Domain 'wslDeep' -Status OK -Items @([pscustomobject]@{ id = 'wslDeep'; state = 'PRESENT'; version = '2.5.7'; defaultVersion = 2; defaultDistribution = 'Ubuntu'; globalConfig = [pscustomobject]@{ state = 'ABSENT'; safeSettings = @() }; distributions = @([pscustomobject]@{ id = 'wsl:Ubuntu'; name = 'Ubuntu'; running = $false; version = 2; probeStatus = 'NOT_TESTED_NOT_RUNNING'; clues = @() }) })
}

function Get-MHToolchainCollection {
    param($Context)
    $script:deepCollectorCalls++
    return New-MHDomainResult -Domain 'toolchains' -Status OK -Items @([pscustomobject]@{ id = 'rust'; state = 'PRESENT'; rustup = [pscustomobject]@{ state = 'PRESENT'; toolchains = @('stable-x86_64-pc-windows-msvc'); defaultToolchain = 'stable-x86_64-pc-windows-msvc'; targets = @(); components = @() } }, [pscustomobject]@{ id = 'java'; state = 'ABSENT'; tools = @(); installations = @() }, [pscustomobject]@{ id = 'visual-studio'; state = 'PRESENT'; status = 'OK'; instances = @() })
}

function Get-MHPlatformToolsCollection {
    param($Context)
    $script:deepCollectorCalls++
    $items = @([pscustomobject]@{
        id = 'platformTools';
        jetbrains = [pscustomobject]@{ id = 'jetbrains'; state = 'PRESENT'; status = 'OK'; products = @([pscustomobject]@{ id = 'jetbrains:Rider2025.1'; state = 'PRESENT'; product = 'Rider'; version = '2025.1' }) };
        containers = [pscustomobject]@{ id = 'containers'; state = 'PRESENT'; status = 'OK'; versions = @(); contexts = @(); composeFiles = @() };
        ssh = [pscustomobject]@{ id = 'ssh'; state = 'PRESENT'; status = 'OK'; hosts = @(); publicKeys = @(); privateKeys = @() };
        gpg = [pscustomobject]@{ id = 'gpg'; state = 'UNKNOWN'; status = 'PARTIAL'; publicFingerprints = @(); signingMappings = @(); privateKeys = [pscustomobject]@{ state = 'PRESENT'; transfer = 'MANUAL_TRANSFER_REQUIRED' } };
        manualItems = @([pscustomobject]@{ domain = 'gpg'; fileName = 'GnuPG private key material'; reason = 'MANUAL_TRANSFER_REQUIRED'; safety = 'MANUAL' })
    })
    return New-MHDomainResult -Domain 'platformTools' -Status PARTIAL -Items $items -Warnings @('GPG_PARTIAL')
}

$deep = Collect-MachineHandoff -Profile Deep -SafeMode -SkipDefaultRoots -AsCollectionResult
Test-MHSnapshot -Snapshot $deep.snapshot
Assert-DeepIntegration -Condition ($deepCollectorCalls -eq 6) -Message 'Deep invokes the additional Git, editor, runtime, WSL, toolchain, and platform collectors'
Assert-DeepIntegration -Condition ($deep.snapshot.system.workstation.architecture -eq 'X64') -Message 'workstation metadata is attached to the system snapshot'
Assert-DeepIntegration -Condition (@($deep.snapshot.wsl | Where-Object id -eq 'wsl:deep-summary').Count -eq 1 -and $deep.snapshot.collection.domainStatus.wslDeep.status -eq 'OK') -Message 'WSL Deep metadata is projected into the v2 snapshot without losing stopped-distro state'
Assert-DeepIntegration -Condition (@($deep.snapshot.dev | Where-Object id -eq 'rust').Count -eq 1 -and @($deep.snapshot.dev | Where-Object id -eq 'java').Count -eq 1) -Message 'toolchain collector groups are projected into the developer inventory'
Assert-DeepIntegration -Condition (@($deep.snapshot.editors | Where-Object id -eq 'editors:jetbrains').Count -eq 1 -and @($deep.snapshot.dev | Where-Object id -eq 'platform:ssh').Count -eq 1 -and @($deep.snapshot.dev | Where-Object id -eq 'platform:gpg').Count -eq 1) -Message 'JetBrains, SSH, and GPG are projected into their compatible v2 domains'
Assert-DeepIntegration -Condition (@($deep.snapshot.manualItems | Where-Object status -eq 'MANUAL_TRANSFER_REQUIRED').Count -eq 1 -and $deep.snapshot.collection.domainStatus.gpg.status -eq 'PARTIAL') -Message 'private-key transfer remains manual and its domain state stays partial'
Assert-DeepIntegration -Condition (@($deep.snapshot.git).Count -eq 1 -and $deep.snapshot.git[0].id -eq 'git:global') -Message 'Git items are projected into the v2 snapshot'
Assert-DeepIntegration -Condition (@($deep.snapshot.editors | Where-Object id -eq 'editor:vscode').Count -eq 1 -and @($deep.snapshot.editors | Where-Object id -eq 'editors:jetbrains').Count -eq 1 -and @($deep.snapshot.agents).Count -eq 1) -Message 'VS Code, JetBrains, and agent inventories are projected into separate snapshot domains'
Assert-DeepIntegration -Condition (@($deep.snapshot.dev | Where-Object { $_.id -eq 'runtime:node' }).Count -eq 1) -Message 'runtime inventory replaces duplicate legacy Node metadata'
Assert-DeepIntegration -Condition (@($deep.snapshot.configArtifacts).Count -eq 1 -and $deep.snapshot.configArtifacts[0].artifactSha256) -Message 'v2 snapshot stores artifact metadata only'
$snapshotJson = ConvertTo-Json -InputObject $deep.snapshot -Depth 60
Assert-DeepIntegration -Condition (-not $snapshotJson.Contains('"content"') -and -not $snapshotJson.Contains('"theme":"dark"')) -Message 'configuration content stays outside the machine snapshot'
Assert-DeepIntegration -Condition ($deep.configArtifacts[0].content.Contains('"theme":"dark"')) -Message 'sanitized artifact payload remains available to the Package writer'
$reports = New-MHReportTexts -Snapshot $deep.snapshot
Assert-DeepIntegration -Condition $reports['SYSTEM.md'].Contains('workstation') -Message 'system report includes the workstation summary'
Assert-DeepIntegration -Condition $reports['DEVELOPMENT.md'].Contains('visual-studio') -Message 'development report includes toolchain details'
Assert-DeepIntegration -Condition $reports['DEVELOPMENT.md'].Contains('wsl:deep-summary') -Message 'development report includes WSL Deep details'

$callsBeforeStandard = $script:deepCollectorCalls
$standard = Collect-MachineHandoff -Profile Standard -SafeMode -SkipDefaultRoots -AsCollectionResult
Test-MHSnapshot -Snapshot $standard.snapshot
Assert-DeepIntegration -Condition ($script:deepCollectorCalls -eq $callsBeforeStandard) -Message 'Standard skips Deep-only collectors'

Write-Output 'Deep integration suite passed.'
