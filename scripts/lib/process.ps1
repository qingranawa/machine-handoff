Set-StrictMode -Version Latest

function ConvertTo-MHProcessArgument {
    param([Parameter(Mandatory)][string]$Argument)

    if ($Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        [void]$builder.Append(('\' * $slashes))
        [void]$builder.Append($character)
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-MHProcessRunnerType {
    if ('MachineHandoff.ProcessRunner' -as [type]) { return }
    $sourcePath = Join-Path $PSScriptRoot 'process-runner.cs'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'PROCESS_RUNNER_MISSING' }
    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Read-MHProcessApprovalManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PackagePath
    )

    try {
        $manifestPath = [IO.Path]::GetFullPath($Path)
        $packageRoot = [IO.Path]::GetFullPath($PackagePath).TrimEnd('\')
    } catch { throw 'PROCESS_APPROVAL_MANIFEST_PATH_INVALID' }
    $packagePrefix = $packageRoot + '\'
    if ($manifestPath.Equals($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or $manifestPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PROCESS_APPROVAL_MANIFEST_IN_PACKAGE'
    }

    $document = Read-MHJson -Path $manifestPath -MaxBytes 65536 -MaxDepth 8 -MaxCollectionItems 256 -MaxStringLength 2048 -MaxTokens 4096
    if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
    $rootNames = @($document.PSObject.Properties.Name | Sort-Object)
    if (($rootNames -join ',') -ne 'approvals,schemaVersion' -or ($document.schemaVersion -isnot [int] -and $document.schemaVersion -isnot [long]) -or $document.schemaVersion -ne 1) {
        throw 'PROCESS_APPROVAL_MANIFEST_INVALID'
    }
    if ($null -eq $document.approvals -or -not $document.approvals.GetType().IsArray) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }

    $entries = @($document.approvals)
    if ($entries.Count -gt 128) { throw 'PROCESS_APPROVAL_MANIFEST_LIMIT' }
    $approvals = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
        $entryNames = @($entry.PSObject.Properties.Name | Sort-Object)
        if (($entryNames -join ',') -ne 'path,sha256') { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
        $approvedPath = [string]$entry.path
        $approvedHash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($approvedPath) -or $approvedPath.Length -gt 1024 -or $approvedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'PROCESS_APPROVAL_MANIFEST_INVALID'
        }
        try {
            if (-not [IO.Path]::IsPathRooted($approvedPath)) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
            $canonicalPath = [IO.Path]::GetFullPath($approvedPath)
        } catch { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
        if (-not $canonicalPath.Equals($approvedPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
        if ($canonicalPath.Equals($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or $canonicalPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'PROCESS_APPROVAL_MANIFEST_IN_PACKAGE'
        }
        $key = $canonicalPath.ToUpperInvariant()
        if ($approvals.ContainsKey($key)) { throw 'PROCESS_APPROVAL_MANIFEST_INVALID' }
        $approvals[$key] = $approvedHash.ToLowerInvariant()
    }
    return $approvals
}

function Test-MHWindowsSystemExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) { return $false }
    $trustedRoots = @(
        (Join-Path $windowsRoot 'System32'),
        (Join-Path $windowsRoot 'SysWOW64'),
        (Join-Path $windowsRoot 'System32\WindowsPowerShell\v1.0')
    )
    foreach ($directory in $trustedRoots) {
        $trustedRoot = [IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
        if (-not $Path.StartsWith($trustedRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $Path.Substring($trustedRoot.Length)
        if ($relative.Length -gt 0 -and $relative.IndexOf('\') -lt 0) { return $true }
    }
    return $false
}

function Get-MHProcessExecutableSha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaxBytes)

    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $MaxBytes) { throw 'PROCESS_EXECUTABLE_SIZE_LIMIT' }
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } catch {
        if ($_.Exception.Message -eq 'PROCESS_EXECUTABLE_SIZE_LIMIT') { throw }
        throw 'PROCESS_EXECUTABLE_IDENTITY_FAILED'
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-MHProcessExecutableIdentity {
    param([Parameter(Mandatory)]$Command, $Context)

    try {
        $path = [IO.Path]::GetFullPath([string]$(if ($Command.Source) { $Command.Source } else { $Command.Path }))
        if ($Context -and $Context.PSObject.Properties['packagePath'] -and -not [string]::IsNullOrWhiteSpace([string]$Context.packagePath)) {
            $packageRoot = [IO.Path]::GetFullPath([string]$Context.packagePath).TrimEnd('\')
            $packagePrefix = $packageRoot + '\'
            if ($path.Equals($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'PROCESS_EXECUTABLE_IN_PACKAGE' }
        }
        $extension = [IO.Path]::GetExtension($path)
        if ($extension -notin @('.exe', '.com')) { throw 'PROCESS_EXECUTABLE_TYPE_UNSUPPORTED' }
        [void](Assert-MHNoReparseAncestors -Path $path)
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PROCESS_EXECUTABLE_UNSAFE' }
    } catch {
        if ($_.Exception.Message -in @('PROCESS_EXECUTABLE_IN_PACKAGE', 'PROCESS_EXECUTABLE_UNSAFE', 'PROCESS_EXECUTABLE_TYPE_UNSUPPORTED')) { throw }
        throw 'PROCESS_EXECUTABLE_IDENTITY_FAILED'
    }

    $maxBytes = if ($Context -and $Context.budgets -and $Context.budgets.maxProcessExecutableHashBytes) { [long]$Context.budgets.maxProcessExecutableHashBytes } else { 268435456L }
    if ([long]$file.Length -gt $maxBytes) { throw 'PROCESS_EXECUTABLE_SIZE_LIMIT' }
    $cacheKey = $path.ToUpperInvariant() + '|' + [string]$file.Length + '|' + [string]$file.LastWriteTimeUtc.Ticks
    $sha256 = $null
    if ($Context -and $Context.PSObject.Properties['processIdentityCache'] -and $Context.processIdentityCache.ContainsKey($cacheKey)) {
        $sha256 = [string]$Context.processIdentityCache[$cacheKey]
    } else {
        $sha256 = Get-MHProcessExecutableSha256 -Path $path -MaxBytes $maxBytes
        if ($Context -and $Context.PSObject.Properties['processIdentityCache']) { $Context.processIdentityCache[$cacheKey] = $sha256 }
    }
    return [pscustomobject]@{ path = $path; sha256 = $sha256; isWindowsSystem = (Test-MHWindowsSystemExecutable -Path $path) }
}

function Add-MHProcessApprovalRequest {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Identity)

    if (-not $Context.PSObject.Properties['processApprovalRequests'] -or -not $Context.PSObject.Properties['processApprovalRequestKeys']) { return }
    if ((Get-Command -Name 'Test-MHSecretText' -CommandType Function -ErrorAction SilentlyContinue) -and (Test-MHSecretText -Text ([string]$Identity.path))) {
        throw 'PROCESS_APPROVAL_PATH_REDACTED'
    }
    $key = ([string]$Identity.path).ToUpperInvariant() + '|' + [string]$Identity.sha256
    if ($Context.processApprovalRequestKeys.ContainsKey($key)) { return }
    if ($Context.processApprovalRequests.Count -ge 128) { throw 'PROCESS_APPROVAL_REQUEST_LIMIT' }
    $Context.processApprovalRequestKeys[$key] = $true
    [void]$Context.processApprovalRequests.Add([pscustomobject]@{ name = $Name; path = [string]$Identity.path; sha256 = [string]$Identity.sha256 })
}

function Get-MHProcessApprovalRequests {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.PSObject.Properties['processApprovalRequests']) { return @() }
    return @($Context.processApprovalRequests.ToArray())
}

function Invoke-MHSafeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 120000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(1024, 1048576)][int]$MaxOutputBytes = 65536,
        $Context
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [pscustomobject]@{ found = $false; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = 'NOT_FOUND' }
    }

    if ($Context) {
        if ($Context.cancellationSource -and $Context.cancellationSource.IsCancellationRequested) {
            return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; cancelled = $true; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = 'CANCELLED' }
        }
        $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
        $TimeoutMilliseconds = [Math]::Min([Math]::Min($TimeoutMilliseconds, [int]$Context.budgets.processTimeoutMs), $remaining)
        $MaxOutputBytes = [Math]::Min($MaxOutputBytes, [int]$Context.budgets.maxProcessOutputBytes)
    }

    if ($TimeoutMilliseconds -le 0) {
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $true; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = 'TIMEOUT' }
    }

    try {
        $identity = Get-MHProcessExecutableIdentity -Command $command -Context $Context
    } catch {
        $errorCode = if ($_.Exception.Message -match '^PROCESS_EXECUTABLE_[A-Z_]+$') { $_.Exception.Message } else { 'PROCESS_EXECUTABLE_IDENTITY_FAILED' }
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; cancelled = $false; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = $errorCode }
    }

    $isApproved = [bool]$identity.isWindowsSystem
    if (-not $isApproved -and $Context -and $Context.PSObject.Properties['processApprovals'] -and $Context.processApprovals) {
        $approvalKey = $identity.path.ToUpperInvariant()
        if ($Context.processApprovals.ContainsKey($approvalKey) -and [string]$Context.processApprovals[$approvalKey] -ieq [string]$identity.sha256) { $isApproved = $true }
    }
    if (-not $isApproved) {
        try { Add-MHProcessApprovalRequest -Context $Context -Name $Name -Identity $identity }
        catch {
            $errorCode = if ($_.Exception.Message -eq 'PROCESS_APPROVAL_PATH_REDACTED') { 'PROCESS_APPROVAL_PATH_REDACTED' } else { 'PROCESS_APPROVAL_REQUEST_LIMIT' }
            return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; cancelled = $false; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = $errorCode }
        }
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; cancelled = $false; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = 'PROCESS_APPROVAL_REQUIRED' }
    }

    try {
        Get-MHProcessRunnerType
        $argumentText = (@($Arguments | ForEach-Object { ConvertTo-MHProcessArgument -Argument ([string]$_) }) -join ' ')
        $cancellationToken = if ($Context -and $Context.cancellationSource) { $Context.cancellationSource.Token } else { [Threading.CancellationToken]::None }
        $result = [MachineHandoff.ProcessRunner]::Run($identity.path, $argumentText, $TimeoutMilliseconds, $MaxOutputBytes, $cancellationToken, $identity.sha256)
        return [pscustomobject]@{
            found = $true
            started = [bool]$result.Started
            exitCode = $(if ($result.Started -and -not $result.TimedOut) { [int]$result.ExitCode } else { $null })
            timedOut = [bool]$result.TimedOut
            cancelled = [bool]$result.Cancelled
            stdout = [string]$result.Stdout
            stderr = [string]$result.Stderr
            stdoutTruncated = [bool]$result.StdoutTruncated
            stderrTruncated = [bool]$result.StderrTruncated
            errorCode = $result.ErrorCode
        }
    } catch {
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; cancelled = $false; stdout = ''; stderr = ''; stdoutTruncated = $false; stderrTruncated = $false; errorCode = 'PROCESS_FAILED' }
    }
}
