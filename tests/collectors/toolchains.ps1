[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\process.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\collectors\toolchains.ps1')

function Assert-Toolchain {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Toolchain collector check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function New-ToolchainProbe {
    param([string]$Stdout = '', [bool]$Found = $true, [int]$ExitCode = 0, [bool]$TimedOut = $false, [string]$ErrorCode = $null)
    return [pscustomobject]@{ found = $Found; started = $Found; exitCode = $(if ($Found -and -not $TimedOut) { $ExitCode } else { $null }); timedOut = $TimedOut; stdout = $Stdout; stderr = ''; errorCode = $ErrorCode }
}

function New-ToolchainFixtureDirectory {
    param([string]$Root, [string]$RelativePath)
    $path = Join-Path $Root $RelativePath
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

Assert-Toolchain -Condition (-not (Test-MHToolchainSafeLocalPath -Path '\\server.invalid\share')) -Message 'UNC toolchain roots are rejected before a filesystem metadata probe'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mhs-toolchains-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    $names = @('rustc', 'cargo', 'rustup', 'java', 'javac', 'mvn', 'gradle', 'go', 'cmake', 'ninja', 'clang', 'clang-cl', 'gcc', 'vcpkg', 'conan', 'vswhere')
    $absentFixtures = @{}
    foreach ($name in $names) { $absentFixtures[$name] = New-ToolchainProbe -Found $false -ErrorCode 'NOT_FOUND' }
    $absentContext = New-MHCollectionContext -Profile Standard -SkipDefaultRoots
    $absentContext | Add-Member -NotePropertyName toolchainFixtures -NotePropertyValue $absentFixtures -Force
    $absentContext | Add-Member -NotePropertyName toolchainRoots -NotePropertyValue @{ javaHomes = @(); windowsSdkRoot = (Join-Path $tempRoot 'no-sdk') } -Force
    $absentContext | Add-Member -NotePropertyName toolchainCommands -NotePropertyValue @{ 'vswhere.exe' = $null } -Force
    $absentContext | Add-Member -NotePropertyName toolchainEnvironment -NotePropertyValue @{} -Force
    $absentConfigPaths = @{}
    foreach ($id in @('cargo-config', 'cargo-config-legacy', 'cargo-credentials', 'cargo-credentials-legacy', 'rustup-settings', 'maven-settings', 'maven-settings-security', 'gradle-properties', 'gradle-init', 'gradle-init-kts', 'nuget-config')) { $absentConfigPaths[$id] = Join-Path $tempRoot ('absent-' + $id) }
    $absentContext | Add-Member -NotePropertyName toolchainConfigPaths -NotePropertyValue $absentConfigPaths -Force
    $absent = Get-MHToolchainCollection -Context $absentContext
    Assert-Toolchain -Condition ($absent.domain -eq 'toolchains' -and $absent.status -eq 'OK') -Message 'absent tools produce a successful stable domain result'
    Assert-Toolchain -Condition (@($absent.items | Where-Object id -eq 'rust')[0].rustup.state -eq 'ABSENT') -Message 'missing rustup is represented as ABSENT'
    $absentToolPaths = @()
    foreach ($group in $absent.items) { foreach ($tool in @(Get-MHToolchainField -Object $group -Name 'tools' -Default @())) { if ($tool.path) { $absentToolPaths += $tool.path } } }
    Assert-Toolchain -Condition ($absentToolPaths.Count -eq 0) -Message 'fixture results do not depend on host-installed command paths'
    $absentJson = ConvertTo-Json -InputObject $absent -Depth 30 -Compress
    Assert-Toolchain -Condition ($null -ne (ConvertFrom-Json -InputObject $absentJson -ErrorAction Stop)) -Message 'absent domain serializes and deserializes'

    $jdkRoot = New-ToolchainFixtureDirectory -Root $tempRoot -RelativePath 'Java'
    [void](New-ToolchainFixtureDirectory -Root $jdkRoot -RelativePath 'jdk-17')
    [void](New-ToolchainFixtureDirectory -Root $jdkRoot -RelativePath 'jdk-21')
    $sdkRoot = New-ToolchainFixtureDirectory -Root $tempRoot -RelativePath 'WindowsKits\Include'
    [void](New-ToolchainFixtureDirectory -Root $sdkRoot -RelativePath '10.0.22621.0')
    $configPaths = @{}
    foreach ($id in @('cargo-config', 'cargo-config-legacy', 'cargo-credentials', 'cargo-credentials-legacy', 'rustup-settings', 'maven-settings', 'maven-settings-security', 'gradle-properties', 'gradle-init', 'gradle-init-kts', 'nuget-config')) {
        $file = Join-Path $tempRoot ($id + '.conf')
        [IO.File]::WriteAllText($file, 'fixture metadata only')
        $configPaths[$id] = $file
    }
    $vsJson = ConvertTo-Json -InputObject @(
        [pscustomobject]@{ instanceId = 'fixture-a'; installationPath = 'C:\Fixture\VS2022'; installationVersion = '17.10.2'; productId = 'Microsoft.VisualStudio.Product.Community'; packages = @([pscustomobject]@{ id = 'Microsoft.VisualStudio.Workload.NativeDesktop' }, [pscustomobject]@{ id = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }) },
        [pscustomobject]@{ instanceId = 'fixture-b'; installationPath = 'C:\Fixture\VSPreview'; installationVersion = '17.11.0'; productId = 'Microsoft.VisualStudio.Product.BuildTools'; packages = @([pscustomobject]@{ id = 'Microsoft.VisualStudio.Workload.ManagedDesktop' }) }
    ) -Depth 8 -Compress
    $fixtures = @{
        'rustc|--version' = New-ToolchainProbe -Stdout 'rustc 1.81.0 (eeb90cda1 2024-09-04)'
        'cargo|--version' = New-ToolchainProbe -Stdout 'cargo 1.81.0 (2dbb1af80 2024-08-20)'
        'rustup|--version' = New-ToolchainProbe -Stdout 'rustup 1.27.1 (54dd3d00f 2024-04-24)'
        'rustup|toolchain list -v' = New-ToolchainProbe -Stdout "stable-x86_64-pc-windows-msvc (default)`n1.80.0-x86_64-pc-windows-msvc"
        'rustup|target list --installed' = New-ToolchainProbe -Stdout "x86_64-pc-windows-msvc`naarch64-pc-windows-msvc"
        'rustup|component list --installed' = New-ToolchainProbe -Stdout "clippy-x86_64-pc-windows-msvc`nrustfmt-x86_64-pc-windows-msvc"
        'cargo|install --list' = New-ToolchainProbe -Stdout "cargo-audit v0.21.0:`n    cargo-audit.exe`ncargo-nextest v0.9.80:"
        'java|-version' = New-ToolchainProbe -Stdout 'openjdk version "21.0.2"'
        'javac|-version' = New-ToolchainProbe -Stdout 'javac 21.0.2'
        'mvn|-version' = New-ToolchainProbe -Stdout 'Apache Maven 3.9.8'
        'gradle|--version' = New-ToolchainProbe -Stdout 'Gradle 8.10'
        'go|version' = New-ToolchainProbe -Stdout 'go version go1.23.1 windows/amd64'
        'go|env GOPATH GOROOT' = New-ToolchainProbe -Stdout "C:\Fixture\Go`nC:\Fixture\Go\sdk"
        'go|tool' = New-ToolchainProbe -Stdout "compile`nlink`nvet"
        'cmake|--version' = New-ToolchainProbe -Stdout 'cmake version 3.30.2'
        'ninja|--version' = New-ToolchainProbe -Found $true -ExitCode 17
        'clang|--version' = New-ToolchainProbe -Stdout 'clang version 18.1.8'
        'clang-cl|--version' = New-ToolchainProbe -Stdout 'clang version 18.1.8'
        'gcc|--version' = New-ToolchainProbe -Stdout 'gcc (MinGW) 13.2.0'
        'vcpkg|version' = New-ToolchainProbe -Stdout 'vcpkg package management program version 2024-09-01'
        'conan|--version' = New-ToolchainProbe -Stdout 'Conan version 2.8.1'
        'vswhere.exe|-all -products * -format json -include packages -utf8' = New-ToolchainProbe -Stdout $vsJson
    }
    $context = New-MHCollectionContext -Profile Deep -SkipDefaultRoots
    $context | Add-Member -NotePropertyName toolchainFixtures -NotePropertyValue $fixtures -Force
    $context | Add-Member -NotePropertyName toolchainRoots -NotePropertyValue @{ javaHomes = @($jdkRoot); windowsSdkRoot = $sdkRoot } -Force
    $context | Add-Member -NotePropertyName toolchainCommands -NotePropertyValue @{ 'vswhere.exe' = 'C:\Fixture\vswhere.exe' } -Force
    $context | Add-Member -NotePropertyName toolchainConfigPaths -NotePropertyValue $configPaths -Force
    $context | Add-Member -NotePropertyName toolchainEnvironment -NotePropertyValue @{ CARGO_HOME = $tempRoot; RUSTUP_HOME = $tempRoot; JAVA_HOME = (Join-Path $jdkRoot 'jdk-21'); GOPATH = 'C:\Fixture\Go'; GOROOT = 'C:\Fixture\Go\sdk' } -Force
    $result = Get-MHToolchainCollection -Context $context
    $rust = @($result.items | Where-Object id -eq 'rust')[0]
    $java = @($result.items | Where-Object id -eq 'java')[0]
    $go = @($result.items | Where-Object id -eq 'go')[0]
    $native = @($result.items | Where-Object id -eq 'native')[0]
    $vs = @($result.items | Where-Object id -eq 'visual-studio')[0]
    Assert-Toolchain -Condition ($result.status -eq 'PARTIAL') -Message 'a failing native probe makes only the toolchains collector PARTIAL'
    Assert-Toolchain -Condition ($rust.rustup.toolchains.Count -eq 2 -and $rust.rustup.defaultToolchain -eq 'stable-x86_64-pc-windows-msvc') -Message 'rustup detects multiple toolchains and the default'
    Assert-Toolchain -Condition ($rust.rustup.targets.Count -eq 2 -and $rust.rustup.components.Count -eq 2 -and $rust.cargoInstalledTools.Count -eq 2) -Message 'Rust targets, components, and installed Cargo tools are listed'
    Assert-Toolchain -Condition ($java.installations.Count -eq 2 -and $java.tools[2].version -eq '3.9.8' -and $java.tools[3].version -eq '8.10') -Message 'multiple JDK installations and Maven/Gradle versions are captured'
    Assert-Toolchain -Condition ($go.goEnvironment.Count -eq 2 -and $go.installedTools.Count -eq 3) -Message 'Go environment paths and installed Go tools are captured'
    Assert-Toolchain -Condition ($native.windowsSdks.Count -eq 1 -and (@($native.tools | Where-Object id -eq 'ninja')[0].status -eq 'COMMAND_FAILED')) -Message 'Windows SDK and localized native tool failures are reported'
    Assert-Toolchain -Condition ($vs.instances.Count -eq 2 -and $vs.instances[0].workloadsAndComponents.Count -ge 1 -and $vs.instances[0].msvc.state -eq 'PRESENT') -Message 'vswhere JSON discovers instances, workloads, and MSVC component state'
    $cargoCredential = @($result.configArtifacts | Where-Object id -eq 'toolchain:cargo-credentials')[0]
    $mavenSettings = @($result.configArtifacts | Where-Object id -eq 'toolchain:maven-settings')[0]
    Assert-Toolchain -Condition ($cargoCredential.contentPolicy -eq 'NEVER_COLLECT' -and $cargoCredential.sensitivity -eq 'SENSITIVE' -and $mavenSettings.contentPolicy -eq 'NEVER_COLLECT') -Message 'Cargo credentials and Maven/Gradle/NuGet secret-bearing settings are never copied'
    Assert-Toolchain -Condition ($cargoCredential.captureState -eq 'NOT_TESTED' -and $cargoCredential.errorCode -eq 'NEVER_COLLECT') -Message 'Cargo credential files go through the Config Artifact helper with NEVER_COLLECT policy'
    $serialized = ConvertTo-Json -InputObject $result -Depth 30 -Compress
    Assert-Toolchain -Condition ($null -ne (ConvertFrom-Json -InputObject $serialized -ErrorAction Stop) -and -not $serialized.Contains('fixture metadata only')) -Message 'populated result serializes cleanly without config contents'
    $sensitiveFixture = Join-Path $tempRoot 'redaction-fixture.ini'
    [IO.File]::WriteAllText($sensitiveFixture, "registry=https://registry.example.invalid/`npassword=synthetic-fixture-value`nretryCount=3`n")
    $redactedArtifact = New-MHConfigArtifact -Context $context -Id 'toolchain:test-redaction' -Domain 'toolchains' -SourcePath $sensitiveFixture -TargetPathCandidate $null -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format INI -ArtifactPath 'configs/toolchains/redaction-fixture.ini' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-Toolchain -Condition ($redactedArtifact.artifact.captureState -eq 'CAPTURED' -and -not $redactedArtifact.content.Contains('synthetic-fixture-value') -and $redactedArtifact.content.Contains('<REDACTED>')) -Message 'Config Artifact INI redaction strips synthetic credentials and retains safe settings'

    $failures = @{}
    foreach ($name in $names) { $failures[$name] = New-ToolchainProbe -Found $false -ErrorCode 'NOT_FOUND' }
    $failures['rustup|--version'] = New-ToolchainProbe -Stdout 'rustup 1.27.1'
    $failures['rustup|toolchain list -v'] = New-ToolchainProbe -Found $true -TimedOut $true -ErrorCode 'TIMEOUT'
    $failures['go|version'] = New-ToolchainProbe -Found $true -ExitCode 4
    $failedContext = New-MHCollectionContext -Profile Standard -SkipDefaultRoots
    $failedContext | Add-Member -NotePropertyName toolchainFixtures -NotePropertyValue $failures -Force
    $failedContext | Add-Member -NotePropertyName toolchainRoots -NotePropertyValue @{ javaHomes = @(); windowsSdkRoot = (Join-Path $tempRoot 'absent-sdk') } -Force
    $failedContext | Add-Member -NotePropertyName toolchainEnvironment -NotePropertyValue @{} -Force
    $failedContext | Add-Member -NotePropertyName toolchainConfigPaths -NotePropertyValue $absentConfigPaths -Force
    $failed = Get-MHToolchainCollection -Context $failedContext
    $failedRust = @($failed.items | Where-Object id -eq 'rust')[0]
    $failedGo = @($failed.items | Where-Object id -eq 'go')[0]
    Assert-Toolchain -Condition ($failed.status -eq 'PARTIAL' -and $failedRust.warnings -contains 'RUSTUP_TOOLCHAINS_TIMEOUT' -and $failedGo.tools[0].status -eq 'COMMAND_FAILED') -Message 'timeouts and command failures remain localized as UNKNOWN/PARTIAL'

    $expired = New-MHCollectionContext -Profile Standard -SkipDefaultRoots
    $expired.deadline = [DateTimeOffset]::UtcNow.AddSeconds(-1)
    $expiredFixtures = @{}
    foreach ($name in $names) { $expiredFixtures[$name] = New-ToolchainProbe -Found $false -ErrorCode 'NOT_FOUND' }
    $expiredFixtures['rustup|--version'] = New-ToolchainProbe -Stdout 'rustup 1.27.1'
    $expired | Add-Member -NotePropertyName toolchainFixtures -NotePropertyValue $expiredFixtures -Force
    $expired | Add-Member -NotePropertyName toolchainRoots -NotePropertyValue @{ javaHomes = @(); windowsSdkRoot = (Join-Path $tempRoot 'absent-sdk') } -Force
    $expired | Add-Member -NotePropertyName toolchainEnvironment -NotePropertyValue @{} -Force
    $expired | Add-Member -NotePropertyName toolchainConfigPaths -NotePropertyValue $absentConfigPaths -Force
    $expiredResult = Get-MHToolchainCollection -Context $expired
    Assert-Toolchain -Condition ($expiredResult.status -in @('PARTIAL', 'UNAVAILABLE') -and @($expiredResult.items | Where-Object id -eq 'rust')[0].rustup.status -eq 'TIMEOUT') -Message 'expired deadline prevents probes and reports incomplete coverage'
    Write-Output 'Toolchain collector suite passed.'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp -PathType Container)) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue }
}
