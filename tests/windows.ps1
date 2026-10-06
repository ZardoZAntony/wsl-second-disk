#Requires -Version 5.1
# Non-destructive checks: never invoke DiskPart, mkfs, mount or task registration.
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install_win.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or $message -notlike "*$ExpectedMessage*") {
        throw "Expected rejection containing '$ExpectedMessage', received: $message"
    }
}

Assert-Rejected -Action { & $installer -NonInteractive } -ExpectedMessage '-VhdPath is required'
Assert-Rejected -Action { & $installer -Name '../invalid' -NonInteractive } -ExpectedMessage 'Name'
Assert-Rejected -Action { & $installer -SizeGB 0 -NonInteractive } -ExpectedMessage 'SizeGB'

$sizeParameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SizeGB' })[0]
if ($sizeParameter.DefaultValue.Value -ne 100) { throw 'Default size must be 100 GiB.' }

# Exercise the actual DiskPart script writer; UTF-16/BOM output must never regress.
$writerAst = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-DiskPartScript'
}, $true)
. ([scriptblock]::Create($writerAst.Extent.Text))
$diskpartFixture = [IO.Path]::GetTempFileName()
try {
    $commands = "create vdisk file=`"C:\test disk.vhdx`" maximum=1024 type=expandable`r`nexit`r`n"
    Write-DiskPartScript -Path $diskpartFixture -Commands $commands
    $bytes = [IO.File]::ReadAllBytes($diskpartFixture)
    if ($bytes[0] -ne 99 -or $bytes[1] -ne 114 -or $bytes -contains 0) { throw 'DiskPart script contains a BOM or UTF-16 bytes.' }
    if ([Text.Encoding]::Default.GetString($bytes) -cne $commands) { throw 'DiskPart commands changed during encoding.' }
} finally { Remove-Item -LiteralPath $diskpartFixture -Force }

# Load only the formatting function to exercise its existing-file guard before any native call.
$functionAst = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-Ext4Vhd'
}, $true)
. ([scriptblock]::Create($functionAst.Extent.Text))
$fixture = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($fixture, 'Existing data must remain unchanged.')
    $VhdPath = $fixture
    $before = (Get-FileHash -LiteralPath $fixture).Hash
    Assert-Rejected -Action { New-Ext4Vhd } -ExpectedMessage 'Refusing to format an existing VHDX'
    if ((Get-FileHash -LiteralPath $fixture).Hash -ne $before) { throw 'Existing file was modified.' }
} finally { Remove-Item -LiteralPath $fixture -Force }

# The no-arguments entry point must ask for a path instead of installing silently.
function Read-Host { param([string]$Prompt) return '' }
Assert-Rejected -Action { & $installer } -ExpectedMessage 'A VHDX file path is required'
Write-Output 'Windows non-destructive checks passed.'

# Native mount messages must not leak into Mount-DataDisk's structured return value.
$mountAst = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Mount-DataDisk'
}, $true)
. ([scriptblock]::Create($mountAst.Extent.Text))
$global:WslMountProbeCalls = 0
function Get-MountInfo {
    $global:WslMountProbeCalls++
    if ($global:WslMountProbeCalls -eq 1) { return $null }
    return [pscustomobject]@{ uuid='probe-uuid'; fstype='ext4' }
}
function wsl.exe { $global:LASTEXITCODE=0; 'Native mount success message' }
$mountFixture = [IO.Path]::GetTempFileName()
try {
    $value = Mount-DataDisk -Configuration ([pscustomobject]@{ Name='probe'; Distro='Ubuntu'; VhdPath=$mountFixture; FileSystemUuid='probe-uuid' })
    if ($value -is [array] -or $value.uuid -cne 'probe-uuid') { throw 'Native mount output polluted the return value.' }
} finally { Remove-Item -LiteralPath $mountFixture -Force }

# One dispatcher must read all configurations in order and continue after a disk fails.
foreach ($functionName in @('Invoke-AllAttachments')) {
    $node = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsl-disks-test-' + [guid]::NewGuid())
$global:WslTestvisited = @()
$global:WslTestfailFirst = $false
function Mount-DataDisk {
    param($Configuration)
    $global:WslTestvisited += $Configuration.Name
    if ($global:WslTestfailFirst -and $Configuration.Name -eq 'alpha') { throw 'Simulated unavailable VHDX.' }
    return [pscustomobject]@{ uuid=$Configuration.FileSystemUuid; fstype='ext4' }
}
try {
    foreach ($diskName in @('alpha', 'beta')) {
        $directory = Join-Path $fixtureRoot $diskName
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        @{ Name=$diskName; Distro='Ubuntu'; VhdPath="D:\$diskName.vhdx"; FileSystemUuid="uuid-$diskName" } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'config.json') -Encoding UTF8
    }
    Invoke-AllAttachments -StateRoot $fixtureRoot
    if (($global:WslTestvisited -join ',') -ne 'alpha,beta') { throw 'Shared attachment did not process both disks sequentially.' }
    $global:WslTestvisited = @()
    $global:WslTestfailFirst = $true
    Assert-Rejected -Action { Invoke-AllAttachments -StateRoot $fixtureRoot } -ExpectedMessage 'Failed to attach 1 disk(s)'
    if (($global:WslTestvisited -join ',') -ne 'alpha,beta') { throw 'A failing disk prevented attachment of another disk.' }
} finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }

$uninstaller = Join-Path (Split-Path -Parent $PSScriptRoot) 'uninstall_win.ps1'
$uninstallAst = [Management.Automation.Language.Parser]::ParseFile($uninstaller, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
Assert-Rejected -Action { & $uninstaller -NonInteractive } -ExpectedMessage '-Name is required'
Assert-Rejected -Action { & $uninstaller -Name '../invalid' -NonInteractive } -ExpectedMessage 'Name'

# Run actual removal code against temporary files with Windows/WSL calls replaced by fixtures.
# The administrator check is omitted only in this disposable test copy.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsl-remove-test-' + [guid]::NewGuid())
$savedLocalAppData = $env:LOCALAPPDATA
$global:WslTestlinuxConfigured = $false
$global:WslTestdetachFailed = $false
$global:WslTestlinuxRemovalFailed = $false
$global:WslTestlinuxRemovals = 0
$global:WslTestremovedTasks = 0
$global:WslTestdetached = @()
$global:WslTestwrongUuid = $false
$global:WslTestunrelatedTask = $false
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args -contains 'test') {
        $global:LASTEXITCODE = 1
        if ($global:WslTestlinuxConfigured) { $global:LASTEXITCODE = 0 }
    } elseif ($args -contains 'wslpath') {
        $global:WslTestscript = Get-Content -LiteralPath $args[-1] -Raw
        '/tmp/unmount-fixture.sh'
    } elseif ($args -contains 'bash') {
        # The embedded Linux backend is exercised with real mounts in integration.sh.
        if ($global:WslTestscript.Contains('Stop the one coordinator')) {
            if ($global:WslTestlinuxRemovalFailed) { $global:LASTEXITCODE = 1 }
            else { $global:WslTestlinuxRemovals++; $global:WslTestlinuxConfigured = $false }
        }
    } elseif ($args -contains 'findmnt') {
        if ($global:WslTestwrongUuid) { '{"filesystems":[{"uuid":"wrong-uuid"}]}' }
        else { '{"filesystems":[{"uuid":"fixture-uuid"}]}' }
    } elseif ($args -contains '--unmount') {
        $global:WslTestdetached += $args[1]
        if ($global:WslTestdetachFailed) { $global:LASTEXITCODE = 1 }
    } else { throw 'Unexpected WSL fixture invocation.' }
}
function Get-ScheduledTask {
    $arguments = $global:WslTestfixtureRuntime
    if ($global:WslTestunrelatedTask) { $arguments = 'unrelated.ps1' }
    [pscustomobject]@{ Actions=@([pscustomobject]@{ Execute='powershell.exe'; Arguments=$arguments }) }
}
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) $global:WslTestremovedTasks++ }
try {
    $env:LOCALAPPDATA = $fixtureRoot
    $state = Join-Path $fixtureRoot 'WslSecondDisk'
    $global:WslTestfixtureRuntime = Join-Path $state 'attach.ps1'
    foreach ($diskName in @('alpha','beta')) {
        $directory = Join-Path $state $diskName
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $vhd = Join-Path $fixtureRoot "$diskName.vhdx"
        [IO.File]::WriteAllText($vhd, 'Preserve this disk data.')
        @{ Name=$diskName; Distro='Ubuntu'; VhdPath=$vhd; FileSystemUuid='fixture-uuid' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'config.json') -Encoding UTF8
    }
    [IO.File]::WriteAllText($global:WslTestfixtureRuntime, 'Fixture runtime.')
    $source = Get-Content -LiteralPath $uninstaller -Raw
    $roleCheck = $uninstallAst.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if (-not $principal.IsInRole')
    }, $true)
    $testCopy = Join-Path $fixtureRoot 'uninstall.ps1'
    [IO.File]::WriteAllText($testCopy, $source.Replace($roleCheck.Extent.Text, ''))
    $alphaConfig = Join-Path (Join-Path $state 'alpha') 'config.json'
    & $testCopy -Name alpha -NonInteractive -WhatIf
    if (-not (Test-Path $alphaConfig) -or $global:WslTestdetached.Count) { throw 'WhatIf changed disk state.' }
    $global:WslTestlinuxConfigured = $true
    $global:WslTestlinuxRemovalFailed = $true
    Assert-Rejected -Action { & $testCopy -Name alpha -NonInteractive } -ExpectedMessage 'Linux operation failed'
    if (-not (Test-Path $alphaConfig) -or $global:WslTestdetached.Count) { throw 'Failed Linux removal changed Windows state.' }
    $global:WslTestlinuxRemovalFailed = $false
    $global:WslTestlinuxConfigured = $true
    $global:WslTestdetachFailed = $true
    Assert-Rejected -Action { & $testCopy -Name alpha -NonInteractive } -ExpectedMessage 'Could not detach'
    if (-not (Test-Path $alphaConfig)) { throw 'Failed detachment removed configuration.' }
    $global:WslTestdetachFailed = $false
    $global:WslTestlinuxConfigured = $true
    $removalCount = $global:WslTestlinuxRemovals
    $global:WslTestwrongUuid = $true
    Assert-Rejected -Action { & $testCopy -Name alpha -NonInteractive -DeleteVhd } -ExpectedMessage 'Mounted disk UUID does not match'
    if (-not (Test-Path $alphaConfig) -or -not (Test-Path (Join-Path $fixtureRoot 'alpha.vhdx'))) { throw 'Wrong UUID changed disk state.' }
    if ($global:WslTestlinuxRemovals -ne $removalCount) { throw 'Wrong UUID removed Linux integration.' }
    $global:WslTestwrongUuid = $false
    & $testCopy -Name alpha -NonInteractive
    if (-not (Test-Path (Join-Path $fixtureRoot 'alpha.vhdx'))) { throw 'Default removal deleted data.' }
    if ((Test-Path $alphaConfig) -or $global:WslTestremovedTasks -ne 0) { throw 'First removal affected the shared task or retained its config.' }
    $global:WslTestunrelatedTask = $true
    Assert-Rejected -Action { & $testCopy -Name beta -NonInteractive -DeleteVhd } -ExpectedMessage 'unrelated task'
    if (-not (Test-Path (Join-Path $fixtureRoot 'beta.vhdx'))) { throw 'Task conflict was detected after data deletion.' }
    $global:WslTestunrelatedTask = $false
    & $testCopy -Name beta -NonInteractive -DeleteVhd
    if ((Test-Path (Join-Path $fixtureRoot 'beta.vhdx')) -or $global:WslTestremovedTasks -ne 1) { throw 'Explicit deletion or final task removal failed.' }
    if (Test-Path $state) { throw 'Active Windows state directory was left behind.' }
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
Write-Output 'Windows shared attachment and uninstallation checks passed.'

# Evaluate the complete installer without a source file, using only disposable files and native-call fixtures.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsl-stream-test-' + [guid]::NewGuid())
$savedLocalAppData = $env:LOCALAPPDATA
$global:WslTeststreamTask = 0
$global:WslTeststreamLinux = 0
$global:WslTeststreamSourcePrompt = 0
$global:WslTeststreamQueries = 0
function Read-Host {
    param([string]$Prompt)
    if ($Prompt -like 'VHDX file path*') { return $global:WslTeststreamVhd }
    if ($Prompt -like 'Disk mount name*' -or $Prompt -like 'Disk name to disconnect*') { return 'stream' }
    if ($Prompt -like 'Source directory*') {
        $global:WslTeststreamSourcePrompt++
        if ($global:WslTeststreamSourcePrompt -eq 1) { return 'workspace' }
    }
    if ($Prompt -like 'Absolute target*') { return '/home/tester/data' }
    if ($Prompt -like 'Enable automatic*') { return 'y' }
    return ''
}
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args -contains '--list') {
        if ($args -contains '--quiet') { 'Ubuntu'; 'Legacy'; 'docker-desktop' }
        else { '* Ubuntu    Running    2'; '  Legacy    Stopped    1'; '  docker-desktop    Running    2' }
    } elseif ($args -contains 'wslpath') {
        $global:WslTeststreamScript = Get-Content -LiteralPath $args[-1] -Raw
        '/tmp/stream-fixture.sh'
    } elseif ($args -contains 'bash') {
        if ($args -notcontains 'nsenter' -or $args -notcontains '-m') { throw 'Linux backend did not enter the distro mount namespace.' }
        if ($global:WslTeststreamScript.Contains("printf 'USER:")) { 'USER:tester'; 'DOCKER:0' }
        elseif ($global:WslTeststreamScript.Contains("'--prerequisites-only'")) { 'Linux prerequisites OK' }
        else {
            $global:WslTeststreamLinux++
            if (-not $global:WslTeststreamScript.Contains("'--bind' 'workspace=/home/tester/data' '--docker-recovery'")) {
                throw 'PowerShell choices were not passed to the Linux backend.'
            }
        }
    } elseif ($args -contains 'getent') { 'tester:x:1000:1000::/home/tester:/bin/bash' }
    elseif ($args -contains 'findmnt') {
        $global:WslTeststreamQueries++
        if ($args -notcontains 'nsenter') { throw 'Mount probe used the elevated session namespace.' }
        '{"filesystems":[{"target":"/mnt/wsl/stream","fstype":"ext4","uuid":"fixture-uuid"}]}'
    } else { throw ('Unexpected stream fixture invocation: ' + ($args -join ' ')) }
}
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $null }
function New-ScheduledTaskAction { param($Execute, $Argument) return @{ Execute=$Execute; Arguments=$Argument } }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) return @{ User=$User } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return @{ User=$UserId } }
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable,
        $MultipleInstances, $ExecutionTimeLimit)
    return @{}
}
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
    $global:WslTeststreamTask++
}
try {
    $env:LOCALAPPDATA = $fixtureRoot
    $state = Join-Path $fixtureRoot 'WslSecondDisk'
    $directory = Join-Path $state 'stream'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $global:WslTeststreamVhd = Join-Path $fixtureRoot 'stream.vhdx'
    [IO.File]::WriteAllText($global:WslTeststreamVhd, 'Existing data must remain unchanged.')
    @{ Name='stream'; Distro='Ubuntu'; VhdPath=$global:WslTeststreamVhd; FileSystemUuid='fixture-uuid' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'config.json') -Encoding UTF8
    $source = Get-Content -LiteralPath $installer -Raw
    $roleChecks = $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if (-not $principal.IsInRole')
    }, $true)
    foreach ($roleCheck in $roleChecks) { $source = $source.Replace($roleCheck.Extent.Text, '') }
    Assert-Rejected -Action { & ([scriptblock]::Create($source)) -VhdPath $global:WslTeststreamVhd -Distro Legacy -NonInteractive } -ExpectedMessage 'installed user WSL2 distribution'
    Assert-Rejected -Action { & ([scriptblock]::Create($source)) -VhdPath $global:WslTeststreamVhd -Distro Ubuntu -LinuxUser root -NonInteractive } -ExpectedMessage 'existing regular Linux user'
    Assert-Rejected -Action { & ([scriptblock]::Create($source)) -DockerRecovery -NoDockerRecovery } -ExpectedMessage 'only one of'
    Invoke-Expression $source
    if ($global:WslTeststreamTask -ne 1 -or $global:WslTeststreamLinux -ne 1) {
        throw 'Streaming installation did not configure both Windows and Linux.'
    }
    if ([IO.File]::ReadAllText($global:WslTeststreamVhd) -cne 'Existing data must remain unchanged.') {
        throw 'Streaming installation changed existing VHDX contents.'
    }
    $runtime = Join-Path $state 'attach.ps1'
    $runtimeAst = [Management.Automation.Language.Parser]::ParseFile($runtime, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $runtimeSource = Get-Content -LiteralPath $runtime -Raw
    if ($runtimeSource.Contains('Get-LinuxInstaller') -or $runtimeSource.Contains('PSCommandPath')) {
        throw 'Dispatcher depends on an installer file or includes the Linux installer.'
    }
    # Running the generated dispatcher must attach configured disks without replaying installation.
    & ([scriptblock]::Create($runtimeSource)) -AttachAll -NonInteractive
    if ($global:WslTeststreamLinux -ne 1 -or $global:WslTeststreamTask -ne 1 -or $global:WslTeststreamQueries -ne 2) {
        throw 'Generated dispatcher replayed setup or failed to inspect the saved disk.'
    }
    # Evaluate removal immediately after setup in the same console; iex must not attach validation
    # attributes to caller variables or lose the advanced function's ShouldProcess context.
    $removalSource = Get-Content -LiteralPath $uninstaller -Raw
    $removalAst = [Management.Automation.Language.Parser]::ParseInput($removalSource, [ref]$tokens, [ref]$parseErrors)
    $removalRoleChecks = $removalAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if (-not $principal.IsInRole')
    }, $true)
    foreach ($roleCheck in $removalRoleChecks) { $removalSource = $removalSource.Replace($roleCheck.Extent.Text, '') }
    $savedWhatIfPreference = $WhatIfPreference
    try {
        $WhatIfPreference = $true
        Invoke-Expression $removalSource
    } finally { $WhatIfPreference = $savedWhatIfPreference }
    if (-not (Test-Path -LiteralPath $global:WslTeststreamVhd) -or
        -not (Test-Path -LiteralPath (Join-Path $directory 'config.json'))) {
        throw 'Streaming WhatIf removal changed the disk or its profile.'
    }
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
Write-Output 'Streaming setup and generated dispatcher checks passed.'
