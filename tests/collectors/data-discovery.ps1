[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\state.ps1')

function Assert-DataDiscovery {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Data discovery check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function Confirm-MHDDGitRepository {
    param([string]$Path, $Context)
    if ((Split-Path -Leaf $Path) -eq 'verified-git') { return 'PRESENT' }
    return 'ABSENT'
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempRoot ('mh-discovery-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $fixtureRoot 'root'
$nonGit = Join-Path $root 'non-git-project'
$compose = Join-Path $root 'compose-app'
$vault = Join-Path $root 'my-vault'
$verifiedGit = Join-Path $root 'verified-git'
$fakeGit = Join-Path $root 'fake-git-marker'
$workspace = Join-Path $fixtureRoot 'editor-workspace'
$appData = Join-Path $fixtureRoot 'AppData'
[void](New-Item -ItemType Directory -Path @($nonGit, $compose, (Join-Path $vault '.obsidian'), (Join-Path $verifiedGit '.git'), (Join-Path $fakeGit '.git'), $workspace, (Join-Path $appData 'Code\User\workspaceStorage\fixture-workspace'), (Join-Path $appData 'Code\User\workspaceStorage\fixture-workspace-extra')) -Force)

try {
    [IO.File]::WriteAllText((Join-Path $nonGit 'pyproject.toml'), '[project]')
    [IO.File]::WriteAllText((Join-Path $compose 'compose.yaml'), 'services: {}')
    [IO.File]::WriteAllBytes((Join-Path $root 'app.sqlite3'), [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $appData 'Code\User\workspaceStorage\fixture-workspace\workspace.json'), ('{"folder":"' + ([Uri]::new($workspace).AbsoluteUri) + '"}'))

    $context = New-MHCollectionContext -Profile Deep -Roots @($root)
    $context | Add-Member -NotePropertyName appData -NotePropertyValue $appData -Force
    $discovery = Get-MHDataDiscovery -Context $context -Roots @($root) -UserHome $fixtureRoot
    $types = @($discovery.items | ForEach-Object { $_.type })
    Assert-DataDiscovery -Condition ($types -contains 'GIT_REPOSITORY') -Message 'Git repository markers are accepted only after rev-parse confirmation'
    Assert-DataDiscovery -Condition ($types -contains 'GIT_REPOSITORY_CANDIDATE') -Message 'an unverified .git marker remains an UNKNOWN candidate'
    Assert-DataDiscovery -Condition ($types -contains 'NON_GIT_PROJECT') -Message 'non-Git project roots are found from marker filenames'
    Assert-DataDiscovery -Condition ($types -contains 'COMPOSE_PROJECT') -Message 'Compose project directories are discovered'
    Assert-DataDiscovery -Condition ($types -contains 'OBSIDIAN_VAULT') -Message 'Obsidian Vaults are found by their .obsidian directory'
    Assert-DataDiscovery -Condition ($types -contains 'LOCAL_DATABASE') -Message 'local database candidates are recorded without opening their contents'
    Assert-DataDiscovery -Condition ($types -contains 'EDITOR_WORKSPACE') -Message 'editor workspace metadata produces a bounded path candidate'
    Assert-DataDiscovery -Condition (Test-MHDDReparse -Path (Join-Path $fixtureRoot 'missing-attributes-path')) -Message 'paths whose reparse attributes cannot be verified fail closed'
    $uncWorkspace = ConvertFrom-MHDDWorkspaceUri -Value 'file://server.invalid/share/workspace'
    Assert-DataDiscovery -Condition ($null -eq $uncWorkspace) -Message 'workspace URI hints that resolve to UNC paths are rejected without probing the network'
    $workspaceLimitContext = New-MHCollectionContext -Profile Deep
    $workspaceLimitContext | Add-Member -NotePropertyName appData -NotePropertyValue $appData -Force
    $workspaceLimitContext.budgets.maxDirectories = 1
    $workspaceLimit = Get-MHDataDiscovery -Context $workspaceLimitContext -Roots @() -UserHome $fixtureRoot
    Assert-DataDiscovery -Condition ($workspaceLimit.status -eq 'PARTIAL' -and $workspaceLimit.warnings -contains 'WORKSPACE_STORAGE_LIMIT_REACHED') -Message 'unexamined editor workspace storage entries are surfaced as partial coverage'

    $limitedContext = New-MHCollectionContext -Profile Standard -Roots @($root)
    $limitedContext.budgets.maxDirectories = 1
    $limited = Get-MHDataDiscovery -Context $limitedContext -Roots @($root) -UserHome $fixtureRoot
    Assert-DataDiscovery -Condition ($limited.status -eq 'PARTIAL' -and $limited.warnings -contains 'DATA_DISCOVERY_LIMIT_REACHED') -Message 'directory budgets return a partial result with a fixed warning'

    $queueContext = New-MHCollectionContext -Profile Deep -Roots @($root)
    $queueContext | Add-Member -NotePropertyName appData -NotePropertyValue $appData -Force
    $queueContext.budgets | Add-Member -NotePropertyName maxQueuedDirectories -NotePropertyValue 2 -Force
    $queueLimited = Get-MHDataDiscovery -Context $queueContext -Roots @($root) -UserHome $fixtureRoot
    Assert-DataDiscovery -Condition ($queueLimited.status -eq 'PARTIAL' -and $queueLimited.warnings -contains 'DIRECTORY_QUEUE_LIMIT') -Message 'directory enqueue fan-out has a global cap and reports truncated coverage'

    $junctionPath = Join-Path $root 'linked-project'
    $junctionCreated = $false
    try {
        [void](New-Item -ItemType Junction -Path $junctionPath -Target $nonGit -ErrorAction Stop)
        $junctionCreated = $true
    } catch { }
    if ($junctionCreated) {
        $junctionScan = Get-MHDataDiscovery -Context (New-MHCollectionContext -Profile Deep -Roots @($root)) -Roots @($root) -UserHome $fixtureRoot
        $followed = @($junctionScan.items | Where-Object { ([string]$_.sourcePath).StartsWith($junctionPath, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        Assert-DataDiscovery -Condition (-not $followed) -Message 'junction descendants are not traversed'
    } else {
        Assert-DataDiscovery -Condition $true -Message 'junction traversal check is skipped when the host cannot create a junction fixture'
    }

    $symlinkPath = Join-Path $root 'symbolic-project'
    $symlinkCreated = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $nonGit -ErrorAction Stop)
        $symlinkCreated = $true
    } catch { }
    if ($symlinkCreated) {
        $symlinkScan = Get-MHDataDiscovery -Context (New-MHCollectionContext -Profile Deep -Roots @($root)) -Roots @($root) -UserHome $fixtureRoot
        $followed = @($symlinkScan.items | Where-Object { ([string]$_.sourcePath).StartsWith($symlinkPath, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        Assert-DataDiscovery -Condition (-not $followed) -Message 'symbolic-link descendants are not traversed'
    } else {
        Assert-DataDiscovery -Condition $true -Message 'symbolic-link traversal check is skipped when the host cannot create a symbolic link fixture'
    }
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Data discovery suite passed.'
