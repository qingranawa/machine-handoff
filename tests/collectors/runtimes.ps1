[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\process.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')
. (Join-Path $repositoryRoot 'scripts\collectors\runtimes.ps1')

function Assert-Runtime {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Runtime collector check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function New-RuntimeProbe {
    param(
        [string]$Stdout = '',
        [string]$Stderr = '',
        [int]$ExitCode = 0,
        [bool]$Found = $true,
        [string]$ErrorCode = $null,
        [string]$Path = $null
    )
    $Stdout = $Stdout.Replace('\n', [Environment]::NewLine)
    $Stderr = $Stderr.Replace('\n', [Environment]::NewLine)
    return [pscustomobject]@{
        found = $Found; started = $Found; exitCode = $(if ($Found) { $ExitCode } else { $null })
        timedOut = $false; stdout = $Stdout; stderr = $Stderr; errorCode = $ErrorCode; path = $Path
    }
}

function New-RuntimeFixtureContext {
    param([hashtable]$Fixtures)
    $context = New-MHCollectionContext -Profile Standard -SkipDefaultRoots
    $context | Add-Member -NotePropertyName runtimeFixtures -NotePropertyValue $Fixtures -Force
    return $context
}

$fixtures = @{
    'node|--version' = New-RuntimeProbe -Stdout 'v22.11.0' -Path 'C:\Tools\node.exe'
    'npm|--version' = New-RuntimeProbe -Stdout '10.9.0' -Path 'C:\Tools\npm.cmd'
    'npm|config get registry' = New-RuntimeProbe -Stdout 'https://registry.example.invalid/'
    'npm|root --global' = New-RuntimeProbe -Stdout 'C:\Tools\node_modules'
    'npm|prefix --global' = New-RuntimeProbe -Stdout 'C:\Tools'
    'npm|ls -g --depth=0 --json' = New-RuntimeProbe -Stdout '{"dependencies":{"typescript":{"version":"5.6.3","resolved":"https://user:secret@example.invalid/typescript.tgz"}}}'
    'corepack|--version' = New-RuntimeProbe -Stdout '0.29.4'
    'fnm|--version' = New-RuntimeProbe -Stdout '1.38.1'
    'fnm|list' = New-RuntimeProbe -Stdout 'v22.11.0\nv20.18.0'
    'python|--version' = New-RuntimeProbe -Stdout 'Python 3.12.7' -Path 'C:\Tools\python.exe'
    'python|-m pip list --format=json --user' = New-RuntimeProbe -Stdout '[{"name":"ruff","version":"0.7.1","url":"https://user:secret@example.invalid/pkg"}]'
    'py|--version' = New-RuntimeProbe -Stdout 'Python 3.12.7'
    'py|-0p' = New-RuntimeProbe -Stdout '-V:3.12 * C:\Tools\Python312\python.exe\n-V:3.11   C:\Tools\Python311\python.exe'
    'pip|--version' = New-RuntimeProbe -Stdout 'pip 24.3.1 from C:\Tools\Python312\Lib\site-packages\pip (python 3.12)'
    'pipx|--version' = New-RuntimeProbe -Stdout '1.7.1'
    'pipx|list --json' = New-RuntimeProbe -Stdout '{"venvs":{"ruff":{"metadata":{"main_package":{"package":"ruff","package_version":"0.7.1"}}}}}'
    'uv|--version' = New-RuntimeProbe -Stdout 'uv 0.5.2'
    'uv|tool list' = New-RuntimeProbe -Stdout 'httpie v3.2.3\nruff v0.7.1'
    'conda|--version' = New-RuntimeProbe -Stdout 'conda 24.9.2'
    'conda|env list' = New-RuntimeProbe -Stdout '# conda environments:\nbase                  *  C:\Tools\Miniconda\nwork                     C:\Tools\Miniconda\envs\work'
    'pyenv|--version' = New-RuntimeProbe -Stdout 'pyenv 3.1.1'
    'pyenv|versions --bare' = New-RuntimeProbe -Stdout '3.12.7\n3.11.9'
    'pyenv|version-name' = New-RuntimeProbe -Stdout '3.12.7'
    'dotnet|--version' = New-RuntimeProbe -Stdout '8.0.404' -Path 'C:\Program Files\dotnet\dotnet.exe'
    'dotnet|--list-sdks' = New-RuntimeProbe -Stdout '8.0.404 [C:\Program Files\dotnet\sdk]\n9.0.100 [C:\Program Files\dotnet\sdk]'
    'dotnet|--list-runtimes' = New-RuntimeProbe -Stdout 'Microsoft.NETCore.App 8.0.11 [C:\Program Files\dotnet\shared\Microsoft.NETCore.App]\nMicrosoft.AspNetCore.App 8.0.11 [C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App]'
    'dotnet|workload list' = New-RuntimeProbe -Stdout 'android 34.0.0/8.0.100 8.0.100'
    'dotnet|tool list --global' = New-RuntimeProbe -Stdout 'dotnet-ef 8.0.11 8.0.11'
}
foreach ($name in @('pnpm', 'yarn', 'bun', 'nvm', 'volta', 'nvs', 'python3', 'pip3', 'poetry')) {
    if (-not $fixtures.ContainsKey($name)) { $fixtures[$name] = New-RuntimeProbe -Found $false -ErrorCode 'NOT_FOUND' }
}

$context = New-RuntimeFixtureContext -Fixtures $fixtures
$result = Get-MHRuntimeCollection -Context $context
Assert-Runtime -Condition ($result.domain -eq 'runtimes') -Message 'runtime domain result uses the runtime collector contract'
Assert-Runtime -Condition ($result.status -eq 'OK') -Message 'successful synthetic probes produce an OK collector result'
Assert-Runtime -Condition (@($result.items).Count -eq 3) -Message 'Node, Python, and .NET toolchains are always represented'

$node = @($result.items | Where-Object id -eq 'runtime:node')[0]
$python = @($result.items | Where-Object id -eq 'runtime:python')[0]
$dotnet = @($result.items | Where-Object id -eq 'runtime:dotnet')[0]
Assert-Runtime -Condition ($node.defaultVersion -eq 'v22.11.0' -and $node.installedVersions -contains 'v20.18.0') -Message 'Node default and version manager versions are retained'
Assert-Runtime -Condition (@($node.managers | Where-Object id -eq 'node:corepack').Count -eq 1 -and @($node.managers | Where-Object id -eq 'node:fnm').Count -eq 1) -Message 'Corepack and fnm manager probes are represented'
Assert-Runtime -Condition (@($node.globalPackages | Where-Object name -eq 'typescript').Count -eq 1) -Message 'npm global package output is normalized to name and version'
Assert-Runtime -Condition ($python.defaultVersion -eq '3.12.7' -and @($python.launcher.interpreters).Count -eq 2) -Message 'Python default and launcher interpreter paths are captured'
Assert-Runtime -Condition (@($python.globalPackages | Where-Object name -eq 'ruff').Count -ge 1 -and @($python.condaEnvironments | Where-Object name -eq 'work').Count -eq 1) -Message 'Python user packages and Conda environment metadata are captured'
Assert-Runtime -Condition (@($dotnet.sdks).Count -eq 2 -and @($dotnet.runtimes).Count -eq 2 -and @($dotnet.workloads).Count -eq 1 -and @($dotnet.globalPackages | Where-Object name -eq 'dotnet-ef').Count -eq 1) -Message '.NET SDK/runtime/workload/global tool lists are captured'

$serialized = $result | ConvertTo-Json -Depth 30
Assert-Runtime -Condition (-not $serialized.Contains('user:secret') -and -not $serialized.Contains('resolved')) -Message 'URL credentials and raw npm package fields never enter the result'

$configFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-runtime-config-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $configFixtureRoot)
try {
    $configContext = New-MHCollectionContext -Profile Deep -SkipDefaultRoots
    $npmConfigPath = Join-Path $configFixtureRoot 'npmrc'
    [IO.File]::WriteAllText($npmConfigPath, "registry=https://registry.example.invalid/`n_authToken=SYNTHETIC_NPM_TOKEN`npassword=SYNTHETIC_NPM_PASSWORD`nalways-auth=true`n", (New-Object Text.UTF8Encoding($false)))
    $pipConfigPath = Join-Path $configFixtureRoot 'pip.ini'
    [IO.File]::WriteAllText($pipConfigPath, "[global]`nindex-url = https://user:SYNTHETIC_PIP_PASSWORD@example.invalid/simple`ntrusted-host = pypi.example.invalid`ntimeout = 30`n", (New-Object Text.UTF8Encoding($false)))

    $npmArtifact = New-MHConfigArtifact -Context $configContext -Id 'node:npmrc:test' -Domain 'node' -SourcePath $npmConfigPath -TargetPathCandidate '%USERPROFILE%\.npmrc' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format INI -ArtifactPath 'configs/runtimes/npmrc-test.ini' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    if ($npmArtifact.artifact.captureState -eq 'CAPTURED') {
        $npmContent = [string]$npmArtifact.content
        Assert-Runtime -Condition (-not $npmContent.Contains('SYNTHETIC_NPM_TOKEN') -and -not $npmContent.Contains('SYNTHETIC_NPM_PASSWORD') -and $npmContent.Contains('registry.example.invalid') -and $npmContent.Contains('always-auth=true') -and $npmContent -notmatch '://[^\s:@]+:[^\s@]+@') -Message 'npm REDACTED_COPY removes auth values while retaining registry and nonsecret settings'
    } elseif ($npmArtifact.artifact.captureState -eq 'BLOCKED' -and $npmArtifact.artifact.errorCode -eq 'REDACTION_BLOCKED') {
        Write-Output 'WARN: npm REDACTED_COPY is blocked until the shared sanitizer recognizes _authToken/npmAuthToken'
    } else {
        throw 'Runtime collector check failed: npm REDACTED_COPY did not capture or fail closed'
    }

    $pipArtifact = New-MHConfigArtifact -Context $configContext -Id 'python:pip-config:test' -Domain 'python' -SourcePath $pipConfigPath -TargetPathCandidate '%USERPROFILE%\pip\pip.ini' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format INI -ArtifactPath 'configs/runtimes/pip-test.ini' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-Runtime -Condition ($pipArtifact.artifact.captureState -eq 'CAPTURED') -Message 'pip INI REDACTED_COPY captures a sanitized fixture'
    $pipContent = [string]$pipArtifact.content
    Assert-Runtime -Condition (-not $pipContent.Contains('SYNTHETIC_PIP_PASSWORD') -and $pipContent.Contains('example.invalid/simple') -and $pipContent.Contains('trusted-host = pypi.example.invalid') -and $pipContent.Contains('timeout = 30') -and $pipContent -notmatch '://[^\s:@]+:[^\s@]+@') -Message 'pip REDACTED_COPY removes URL credentials while retaining index and nonsecret settings'

    $runtimeCandidates = @(Get-MHRuntimeConfigCandidates -Context $configContext)
    $npmCandidate = $runtimeCandidates | Where-Object id -eq 'node:npmrc' | Select-Object -First 1
    $pipCandidates = @($runtimeCandidates | Where-Object { $_.id -in @('python:pip-user', 'python:pip-config', 'python:pip-appdata') })
    Assert-Runtime -Condition ($npmCandidate -and (Get-MHRuntimeProperty -Object $npmCandidate -Name 'contentPolicy') -eq 'REDACTED_COPY' -and (Get-MHRuntimeProperty -Object $npmCandidate -Name 'format') -eq 'INI' -and @($pipCandidates | Where-Object { (Get-MHRuntimeProperty -Object $_ -Name 'contentPolicy') -eq 'REDACTED_COPY' -and (Get-MHRuntimeProperty -Object $_ -Name 'format') -eq 'INI' }).Count -eq @($pipCandidates).Count) -Message 'npmrc and pip INI candidates use REDACTED_COPY with the supported INI format'
    $yarnCandidate = $runtimeCandidates | Where-Object id -eq 'node:yarnrc' | Select-Object -First 1
    $yarnYmlCandidate = $runtimeCandidates | Where-Object id -eq 'node:yarnrc-yml' | Select-Object -First 1
    Assert-Runtime -Condition ((Get-MHRuntimeProperty -Object $yarnCandidate -Name 'contentPolicy' -Default 'METADATA_ONLY') -eq 'METADATA_ONLY' -and (Get-MHRuntimeProperty -Object $yarnYmlCandidate -Name 'contentPolicy' -Default 'METADATA_ONLY') -eq 'METADATA_ONLY') -Message 'Yarn TEXT/YAML configs remain metadata-only until token-safe parsing is proven'
}
finally {
    if (Test-Path -LiteralPath $configFixtureRoot -PathType Container) { Remove-Item -LiteralPath $configFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$absentFixtures = @{}
foreach ($name in @('node', 'npm', 'pnpm', 'yarn', 'bun', 'corepack', 'fnm', 'nvm', 'volta', 'nvs', 'python', 'python3', 'py', 'pip', 'pip3', 'pipx', 'uv', 'poetry', 'conda', 'pyenv', 'dotnet')) {
    $absentFixtures[$name] = New-RuntimeProbe -Found $false -ErrorCode 'NOT_FOUND'
}
$absent = Get-MHRuntimeCollection -Context (New-RuntimeFixtureContext -Fixtures $absentFixtures)
$absentNode = @($absent.items | Where-Object id -eq 'runtime:node')[0]
$absentPython = @($absent.items | Where-Object id -eq 'runtime:python')[0]
$absentDotnet = @($absent.items | Where-Object id -eq 'runtime:dotnet')[0]
Assert-Runtime -Condition ($absent.status -eq 'OK' -and $absentNode.state -eq 'ABSENT' -and $absentNode.status -eq 'NOT_FOUND' -and $absentPython.state -eq 'ABSENT' -and $absentDotnet.state -eq 'ABSENT') -Message 'missing runtimes are reported as ABSENT/NOT_FOUND without failing the domain'

$fallbackFixtures = @{}
foreach ($name in $absentFixtures.Keys) { $fallbackFixtures[$name] = $absentFixtures[$name] }
$fallbackFixtures['python3'] = New-RuntimeProbe -Stdout 'Python 3.11.9'
$fallbackFixtures['python3|--version'] = $fallbackFixtures['python3']
$fallbackFixtures['python3|-m pip list --format=json --user'] = New-RuntimeProbe -Stdout '[]'
$fallback = Get-MHRuntimeCollection -Context (New-RuntimeFixtureContext -Fixtures $fallbackFixtures)
$fallbackPython = @($fallback.items | Where-Object id -eq 'runtime:python')[0]
Assert-Runtime -Condition ($fallbackPython.command -eq 'python3' -and $fallbackPython.defaultVersion -eq '3.11.9') -Message 'python3 is used as the default runtime when python is absent'

$failedFixtures = @{}
foreach ($name in $absentFixtures.Keys) { $failedFixtures[$name] = $absentFixtures[$name] }
$failedFixtures['node|--version'] = New-RuntimeProbe -Found $true -ErrorCode 'TIMEOUT'
$failed = Get-MHRuntimeCollection -Context (New-RuntimeFixtureContext -Fixtures $failedFixtures)
$failedNode = @($failed.items | Where-Object id -eq 'runtime:node')[0]
Assert-Runtime -Condition ($failed.status -eq 'PARTIAL' -and $failedNode.state -eq 'UNKNOWN' -and $failedNode.status -eq 'TIMEOUT') -Message 'command failures produce UNKNOWN item state and PARTIAL collection status'

Write-Output 'Runtime collector suite passed.'
