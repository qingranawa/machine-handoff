[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

function Assert-ProcessApproval {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Process approval check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$systemPowerShellPath = Join-Path $windowsRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-ProcessApproval -Condition (Test-MHWindowsSystemExecutable -Path (Join-Path $windowsRoot 'System32\cmd.exe')) -Message 'direct System32 executable is trusted for fixed system queries'
Assert-ProcessApproval -Condition (Test-MHWindowsSystemExecutable -Path $systemPowerShellPath) -Message 'Windows PowerShell system installation is trusted for fixed queries'
Assert-ProcessApproval -Condition (-not (Test-MHWindowsSystemExecutable -Path (Join-Path $windowsRoot 'System32\drivers\etc\untrusted.exe'))) -Message 'nested System32 paths are not implicitly trusted'

$unicodeSegment = [string]([char]0x5BA1) + [string]([char]0x6279)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-' + $unicodeSegment + '-process-approval-' + [guid]::NewGuid().ToString('N'))
$sourceCmd = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\cmd.exe'
$untrustedCmd = Join-Path $tempRoot 'cmd.exe'
$originalPath = $env:PATH

try {
    [void](New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop)
    Copy-Item -LiteralPath $sourceCmd -Destination $untrustedCmd -ErrorAction Stop
    $untrustedGit = Join-Path $tempRoot 'git.exe'
    Copy-Item -LiteralPath $sourceCmd -Destination $untrustedGit -ErrorAction Stop
    $env:PATH = $tempRoot + [IO.Path]::PathSeparator + $originalPath

    $resolved = Get-Command -Name 'cmd.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    Assert-ProcessApproval -Condition ([IO.Path]::GetFullPath($resolved.Source) -ieq [IO.Path]::GetFullPath($untrustedCmd)) -Message 'fixture shadows the system command through PATH'

    $unsupportedCommandPath = Join-Path $tempRoot 'untrusted.cmd'
    [IO.File]::WriteAllText($unsupportedCommandPath, "@echo off`r`nexit /b 0`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $unsupportedResult = Invoke-MHSafeProcess -Name 'untrusted.cmd' -Arguments @() -Context (New-MHCollectionContext -Profile 'Deep')
    Assert-ProcessApproval -Condition (-not $unsupportedResult.started -and $unsupportedResult.errorCode -eq 'PROCESS_EXECUTABLE_TYPE_UNSUPPORTED') -Message 'batch files are blocked instead of becoming executable approvals'

    $context = New-MHCollectionContext -Profile 'Deep'
    $result = Invoke-MHSafeProcess -Name 'cmd.exe' -Arguments @('/c', 'exit 0') -Context $context
    Assert-ProcessApproval -Condition (-not $result.started -and $result.errorCode -eq 'PROCESS_APPROVAL_REQUIRED') -Message 'unapproved PATH executable is blocked before process start'

    $requests = @(Get-MHProcessApprovalRequests -Context $context)
    Assert-ProcessApproval -Condition ($requests.Count -eq 1 -and $requests[0].path -ieq $untrustedCmd -and $requests[0].sha256 -match '^[A-Fa-f0-9]{64}$') -Message 'blocked executable produces a path-and-hash request in memory'

    $packagePath = Join-Path $tempRoot 'package'
    [void](New-Item -ItemType Directory -Path $packagePath -ErrorAction Stop)
    $packageExecutablePath = Join-Path $packagePath 'package-tool.exe'
    Copy-Item -LiteralPath $sourceCmd -Destination $packageExecutablePath -ErrorAction Stop
    $pathWithPackage = $packagePath + [IO.Path]::PathSeparator + $env:PATH
    $env:PATH = $pathWithPackage
    $packageExecutableResult = Invoke-MHSafeProcess -Name 'package-tool.exe' -Arguments @('/c', 'exit 0') -Context (New-MHCollectionContext -Profile 'Deep' -PackagePath $packagePath)
    Assert-ProcessApproval -Condition (-not $packageExecutableResult.started -and $packageExecutableResult.errorCode -eq 'PROCESS_EXECUTABLE_IN_PACKAGE') -Message 'Package-local executables are blocked even when found on PATH'
    $env:PATH = $tempRoot + [IO.Path]::PathSeparator + $originalPath

    $manifestPath = Join-Path $tempRoot 'approved-processes.json'
    $manifest = [pscustomobject]@{
        schemaVersion = 1
        approvals = @([pscustomobject]@{ path = [IO.Path]::GetFullPath($untrustedCmd); sha256 = $requests[0].sha256 })
    }
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $approvedProcesses = Read-MHProcessApprovalManifest -Path $manifestPath -PackagePath $packagePath
    $approvedContext = New-MHCollectionContext -Profile 'Deep' -ProcessApprovals $approvedProcesses
    $approvedResult = Invoke-MHSafeProcess -Name 'cmd.exe' -Arguments @('/c', 'exit 0') -Context $approvedContext
    Assert-ProcessApproval -Condition ($approvedResult.started -and $approvedResult.exitCode -eq 0) -Message 'exact absolute path and SHA-256 approval allows the audited process call'

    $wrongPathManifestPath = Join-Path $tempRoot 'wrong-path-processes.json'
    $wrongPathManifest = [pscustomobject]@{
        schemaVersion = 1
        approvals = @([pscustomobject]@{ path = [IO.Path]::GetFullPath($sourceCmd); sha256 = $requests[0].sha256 })
    }
    [IO.File]::WriteAllText($wrongPathManifestPath, (ConvertTo-Json -InputObject $wrongPathManifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $wrongPathApprovals = Read-MHProcessApprovalManifest -Path $wrongPathManifestPath -PackagePath $packagePath
    $wrongPathContext = New-MHCollectionContext -Profile 'Deep' -ProcessApprovals $wrongPathApprovals
    $wrongPathResult = Invoke-MHSafeProcess -Name 'cmd.exe' -Arguments @('/c', 'exit 0') -Context $wrongPathContext
    Assert-ProcessApproval -Condition (-not $wrongPathResult.started -and $wrongPathResult.errorCode -eq 'PROCESS_APPROVAL_REQUIRED') -Message 'matching hash at a different absolute path does not grant approval'

    $invalidManifestPath = Join-Path $tempRoot 'invalid-processes.json'
    $invalidManifest = [pscustomobject]@{ schemaVersion = 1; approvals = @(); extra = 'rejected' }
    [IO.File]::WriteAllText($invalidManifestPath, (ConvertTo-Json -InputObject $invalidManifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $invalidManifestBlocked = $false
    try { [void](Read-MHProcessApprovalManifest -Path $invalidManifestPath -PackagePath $packagePath) }
    catch { $invalidManifestBlocked = $_.Exception.Message -eq 'PROCESS_APPROVAL_MANIFEST_INVALID' }
    Assert-ProcessApproval -Condition $invalidManifestBlocked -Message 'unknown approval manifest fields fail closed'

    $bytes = [IO.File]::ReadAllBytes($untrustedCmd)
    $bytes[$bytes.Length - 1] = [byte]($bytes[$bytes.Length - 1] -bxor 1)
    [IO.File]::WriteAllBytes($untrustedCmd, $bytes)
    Get-MHProcessRunnerType
    $identityChanged = [MachineHandoff.ProcessRunner]::Run($untrustedCmd, '/c exit 0', 1000, 1024, [Threading.CancellationToken]::None, $requests[0].sha256)
    Assert-ProcessApproval -Condition (-not $identityChanged.Started -and $identityChanged.ErrorCode -eq 'EXECUTABLE_IDENTITY_CHANGED') -Message 'native runner rechecks identity immediately before process start'

    $staleContext = New-MHCollectionContext -Profile 'Deep' -ProcessApprovals $approvedProcesses
    $staleResult = Invoke-MHSafeProcess -Name 'cmd.exe' -Arguments @('/c', 'exit 0') -Context $staleContext
    Assert-ProcessApproval -Condition (-not $staleResult.started -and $staleResult.errorCode -eq 'PROCESS_APPROVAL_REQUIRED') -Message 'changed executable bytes invalidate the approved identity'

    $staleRequests = @(Get-MHProcessApprovalRequests -Context $staleContext)
    Assert-ProcessApproval -Condition ($staleRequests.Count -eq 1 -and $staleRequests[0].sha256 -ine $requests[0].sha256) -Message 'changed executable requests a new SHA-256 approval'

    $manifestInsidePackage = Join-Path $packagePath 'approvals.json'
    [IO.File]::WriteAllText($manifestInsidePackage, (ConvertTo-Json -InputObject $manifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $packageManifestBlocked = $false
    try { [void](Read-MHProcessApprovalManifest -Path $manifestInsidePackage -PackagePath $packagePath) }
    catch { $packageManifestBlocked = $_.Exception.Message -eq 'PROCESS_APPROVAL_MANIFEST_IN_PACKAGE' }
    Assert-ProcessApproval -Condition $packageManifestBlocked -Message 'approval manifest cannot be read from a transferable Package'

    $approvalForPackagePath = Join-Path $tempRoot 'approval-for-package-tool.json'
    $approvalForPackage = [pscustomobject]@{ schemaVersion = 1; approvals = @([pscustomobject]@{ path = $packageExecutablePath; sha256 = (Get-MHProcessExecutableSha256 -Path $packageExecutablePath -MaxBytes 268435456) }) }
    [IO.File]::WriteAllText($approvalForPackagePath, (ConvertTo-Json -InputObject $approvalForPackage -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $packageExecutableApprovalBlocked = $false
    try { [void](Read-MHProcessApprovalManifest -Path $approvalForPackagePath -PackagePath $packagePath) }
    catch { $packageExecutableApprovalBlocked = $_.Exception.Message -eq 'PROCESS_APPROVAL_MANIFEST_IN_PACKAGE' }
    Assert-ProcessApproval -Condition $packageExecutableApprovalBlocked -Message 'approval manifest cannot authorize a Package-local executable'

    $repositoryRootFixture = Join-Path $tempRoot 'repository'
    [void](New-Item -ItemType Directory -Path (Join-Path $repositoryRootFixture '.git') -Force -ErrorAction Stop)
    $cliPackagePath = Join-Path $tempRoot 'cli-package'
    $entryPath = Join-Path $repositoryRoot 'scripts\machine-handoff.ps1'
    $cliResult = Invoke-MHSafeProcess -Name $systemPowerShellPath -Arguments @('-NoProfile', '-File', $entryPath, '-Mode', 'Prepare', '-PackagePath', $cliPackagePath, '-Roots', $repositoryRootFixture, '-SafeMode', '-SkipDefaultRoots') -TimeoutMilliseconds 30000 -MaxOutputBytes 65536
    $approvalLine = @($cliResult.stdout -split "`r?`n" | Where-Object { $_.StartsWith('MACHINE_HANDOFF_PROCESS_APPROVAL_REQUIRED=') })
    $reportedGitRequest = $false
    foreach ($line in $approvalLine) {
        $requestJson = $line.Substring('MACHINE_HANDOFF_PROCESS_APPROVAL_REQUIRED='.Length)
        $request = ConvertFrom-Json -InputObject $requestJson -ErrorAction Stop
        if ([string]$request.path -ieq $untrustedGit -and [string]$request.sha256 -match '^[A-Fa-f0-9]{64}$') { $reportedGitRequest = $true }
    }
    if (-not $reportedGitRequest) { Write-Output ('CLI_EXIT=' + $cliResult.exitCode); Write-Output ([string]$cliResult.stdout) }
    Assert-ProcessApproval -Condition ($cliResult.exitCode -eq 0 -and $reportedGitRequest) -Message 'Prepare prints blocked executable requests without failing the rest of collection'
    $packageFiles = @(Get-ChildItem -LiteralPath $cliPackagePath -File -Recurse)
    $packageContainsApprovalHash = $false
    foreach ($packageFile in $packageFiles) {
        $content = [IO.File]::ReadAllText($packageFile.FullName)
        if ($content.Contains((Get-MHProcessExecutableSha256 -Path $untrustedGit -MaxBytes 268435456))) { $packageContainsApprovalHash = $true }
    }
    Assert-ProcessApproval -Condition (-not $packageContainsApprovalHash) -Message 'approval request hash is absent from all Package files'
} finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'Process approval suite passed.'
