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
        Get-MHProcessRunnerType
        $argumentText = (@($Arguments | ForEach-Object { ConvertTo-MHProcessArgument -Argument ([string]$_) }) -join ' ')
        $cancellationToken = if ($Context -and $Context.cancellationSource) { $Context.cancellationSource.Token } else { [Threading.CancellationToken]::None }
        $result = [MachineHandoff.ProcessRunner]::Run($command.Source, $argumentText, $TimeoutMilliseconds, $MaxOutputBytes, $cancellationToken)
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
