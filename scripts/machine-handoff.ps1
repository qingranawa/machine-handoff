[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Update', 'Restore', 'Validate', 'Diff')][string]$Mode,
    [string]$PackagePath,
    [string[]]$Roots = @(),
    [string[]]$Excludes = @(),
    [ValidateRange(0, 12)][int]$MaxDepth = 3,
    [switch]$SafeMode,
    [switch]$SkipDefaultRoots,
    [string]$SourceSnapshotPath,
    [string]$DestinationSnapshotPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'collect.ps1')
. (Join-Path $PSScriptRoot 'state.ps1')

function Stop-MH {
    param([string]$Code)
    Write-Output ('MACHINE_HANDOFF_STATUS=ERROR CODE=' + $Code)
    exit 1
}

function Assert-MHPackagePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Create)
    $full = [IO.Path]::GetFullPath($Path)
    [void](Assert-MHNoReparseAncestors -Path $full)
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) { throw 'PACKAGE_NOT_DIRECTORY' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
    } elseif ($Create) {
        [void](New-Item -ItemType Directory -Path $full -ErrorAction Stop)
        [void](Assert-MHNoReparseAncestors -Path $full)
    } else { throw 'PACKAGE_NOT_FOUND' }
    return $full
}

function Initialize-MHPackage {
    param([string]$Path)
    foreach ($relative in @('manifests', 'evidence')) {
        $directory = Join-Path $Path $relative
        [void](Assert-MHNoReparseAncestors -Path $directory)
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PACKAGE_REPARSE_BLOCKED' }
        } else { [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop) }
    }
}

function Assert-MHWritablePackageTargets {
    param([Parameter(Mandatory)][string]$Path)
    $relativeTargets = @(
        'manifests\source.previous.json', 'manifests\source.snapshot.json', 'manifests\destination.snapshot.json',
        'manifests\decisions.json', 'manifests\diff.json', 'manifests\validation.json',
        'evidence\collection-status.json', 'HANDOFF.md', 'SYSTEM.md', 'SOFTWARE.md', 'DEVELOPMENT.md',
        'AI_AGENTS.md', 'DATA.md', 'MIGRATION_PLAN.md'
    )
    foreach ($relative in $relativeTargets) { [void](Assert-MHNoReparseAncestors -Path (Join-Path $Path $relative)) }
}

function Get-MHSourcePath {
    param([string]$Path)
    return Join-Path $Path 'manifests\source.snapshot.json'
}

function Get-MHDecisions {
    param([string]$Path)
    $decisionsPath = Join-Path $Path 'manifests\decisions.json'
    if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) {
        $decisions = Read-MHJson -Path $decisionsPath
        Test-MHDecisions -Decisions $decisions
        return $decisions
    }
    return New-MHDefaultDecisions
}

function Write-MHCollectionStatus {
    param([string]$Path, $Snapshot)
    $status = [pscustomobject]@{ schemaVersion = 1; collectedAt = $Snapshot.collectedAt; snapshotId = $Snapshot.snapshotId; domains = $Snapshot.collection.domainStatus }
    Write-MHJson -Path (Join-Path $Path 'evidence\collection-status.json') -Value $status
}

function Invoke-MHCollect {
    param([string]$Role, [string]$SourceId)
    return Collect-MachineHandoff -Roots $Roots -Excludes $Excludes -MaxDepth $MaxDepth -SafeMode:$SafeMode -SkipDefaultRoots:$SkipDefaultRoots -Role $Role -SourceId $SourceId
}

try {
    if ($Mode -eq 'Diff') {
        if (-not $SourceSnapshotPath -or -not $DestinationSnapshotPath) { throw 'DIFF_INPUT_REQUIRED' }
        $source = Read-MHJson -Path $SourceSnapshotPath
        $destination = Read-MHJson -Path $DestinationSnapshotPath
        Test-MHSnapshot -Snapshot $source
        Test-MHSnapshot -Snapshot $destination
        $diff = New-MHDiff -Source $source -Destination $destination -Decisions (New-MHDefaultDecisions)
        if ($PackagePath) {
            $package = Assert-MHPackagePath -Path $PackagePath -Create
            Initialize-MHPackage -Path $package
            Write-MHJson -Path (Join-Path $package 'manifests\diff.json') -Value $diff
        } else {
            $diffJson = ConvertTo-Json -InputObject $diff -Depth 50
            Test-MHSerializedText -Text $diffJson
            Write-Output $diffJson
            exit 0
        }
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=DIFF ITEMS=' + @($diff.items).Count)
        exit 0
    }

    if (-not $PackagePath) { throw 'PACKAGE_PATH_REQUIRED' }
    $package = Assert-MHPackagePath -Path $PackagePath -Create:($Mode -eq 'Prepare')
    if ($Mode -eq 'Prepare') {
        $existing = @(Get-ChildItem -LiteralPath $package -Force -ErrorAction Stop)
        if ($existing.Count -gt 0) { throw 'PACKAGE_NOT_EMPTY' }
        Initialize-MHPackage -Path $package
        $snapshot = Invoke-MHCollect -Role 'SOURCE' -SourceId $null
        Test-MHSnapshot -Snapshot $snapshot
        $decisions = New-MHDefaultDecisions
        Write-MHJson -Path (Get-MHSourcePath -Path $package) -Value $snapshot
        Write-MHJson -Path (Join-Path $package 'manifests\decisions.json') -Value $decisions
        Write-MHCollectionStatus -Path $package -Snapshot $snapshot
        Write-MHReports -PackagePath $package -Snapshot $snapshot
        Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=PREPARE DOMAINS=' + $snapshot.collection.domainStatus.Count)
        exit 0
    }

    if ($Mode -eq 'Update') {
        $sourcePath = Get-MHSourcePath -Path $package
        $previous = Read-MHJson -Path $sourcePath
        Test-MHSnapshot -Snapshot $previous
        if ($previous.role -ne 'SOURCE') { throw 'SOURCE_SNAPSHOT_REQUIRED' }
        $snapshot = Invoke-MHCollect -Role 'SOURCE' -SourceId $previous.sourceId
        Test-MHSnapshot -Snapshot $snapshot
        $previousLabel = [string]$previous.system.computerLabel
        $currentLabel = [string]$snapshot.system.computerLabel
        $previousProfile = [string]$previous.system.userProfile
        $currentProfile = [string]$snapshot.system.userProfile
        if ([string]::IsNullOrWhiteSpace($previousLabel) -or [string]::IsNullOrWhiteSpace($previousProfile) -or $previousLabel -ine $currentLabel -or $previousProfile -ine $currentProfile) { throw 'SOURCE_MACHINE_MISMATCH' }
        $decisions = Get-MHDecisions -Path $package
        $diff = $null
        $validation = $null
        $destinationPath = Join-Path $package 'manifests\destination.snapshot.json'
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $destination = Read-MHJson -Path $destinationPath
            Test-MHSnapshot -Snapshot $destination
            if ($destination.role -ne 'DESTINATION') { throw 'DESTINATION_SNAPSHOT_REQUIRED' }
            $diff = New-MHDiff -Source $snapshot -Destination $destination -Decisions $decisions
            $validation = New-MHValidation -Diff $diff -Source $snapshot -Destination $destination -Decisions $decisions
        }
        $reportTexts = New-MHReportTexts -Snapshot $snapshot -Diff $diff -Validation $validation
        Assert-MHWritablePackageTargets -Path $package
        Initialize-MHPackage -Path $package
        Write-MHJson -Path (Join-Path $package 'manifests\source.previous.json') -Value $previous
        Write-MHJson -Path $sourcePath -Value $snapshot
        Write-MHCollectionStatus -Path $package -Snapshot $snapshot
        if ($null -ne $diff) {
            Write-MHJson -Path (Join-Path $package 'manifests\diff.json') -Value $diff
            Write-MHJson -Path (Join-Path $package 'manifests\validation.json') -Value $validation
        }
        Write-MHReports -PackagePath $package -Snapshot $snapshot -Diff $diff -Validation $validation -ReportTexts $reportTexts
        Write-Output 'MACHINE_HANDOFF_STATUS=OK MODE=UPDATE'
        exit 0
    }

    $sourcePath = Get-MHSourcePath -Path $package
    $source = Read-MHJson -Path $sourcePath
    Test-MHSnapshot -Snapshot $source
    if ($source.role -ne 'SOURCE') { throw 'SOURCE_SNAPSHOT_REQUIRED' }
    $decisions = Get-MHDecisions -Path $package
    $destination = Invoke-MHCollect -Role 'DESTINATION' -SourceId $source.sourceId
    Test-MHSnapshot -Snapshot $destination
    Initialize-MHPackage -Path $package
    Write-MHJson -Path (Join-Path $package 'manifests\destination.snapshot.json') -Value $destination
    Write-MHCollectionStatus -Path $package -Snapshot $destination
    $diff = New-MHDiff -Source $source -Destination $destination -Decisions $decisions
    Write-MHJson -Path (Join-Path $package 'manifests\diff.json') -Value $diff
    $validation = New-MHValidation -Diff $diff -Source $source -Destination $destination -Decisions $decisions
    if ($Mode -eq 'Validate') { Write-MHJson -Path (Join-Path $package 'manifests\validation.json') -Value $validation }
    Write-MHReports -PackagePath $package -Snapshot $source -Diff $diff -Validation $validation
    $resultMode = $Mode.ToUpperInvariant()
    Write-Output ('MACHINE_HANDOFF_STATUS=OK MODE=' + $resultMode + ' DIFF_ITEMS=' + @($diff.items).Count)
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    if ($message -match '^(REDACTION_BLOCKED|OUTPUT_REPARSE_BLOCKED|PACKAGE_REPARSE_BLOCKED|PATH_REPARSE_BLOCKED|PATH_CHECK_FAILED|PACKAGE_NOT_EMPTY|PACKAGE_NOT_FOUND|PACKAGE_NOT_DIRECTORY|PACKAGE_PATH_REQUIRED|DIFF_INPUT_REQUIRED|INPUT_FILE_MISSING|INVALID_JSON|INVALID_SNAPSHOT|INVALID_DECISIONS|UNSUPPORTED_SCHEMA|SOURCE_SNAPSHOT_REQUIRED|DESTINATION_SNAPSHOT_REQUIRED|SOURCE_MACHINE_MISMATCH|OUTPUT_PARENT_MISSING)$') { Stop-MH -Code $message }
    Stop-MH -Code 'OPERATION_FAILED'
}
