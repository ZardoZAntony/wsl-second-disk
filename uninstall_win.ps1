#Requires -Version 5.1
<#
.SYNOPSIS
Remove one registered disk's Windows and Linux integration, then detach it.
The VHDX is preserved unless -DeleteVhd is explicitly specified.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$Name,
    [switch]$NonInteractive,
    [switch]$DeleteVhd,
    [switch]$Check
)

function Invoke-WslSecondDiskRemoval {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [ValidatePattern('^[a-z][a-z0-9-]{0,30}$')]
        [string]$Name,
        [switch]$NonInteractive,
        [switch]$DeleteVhd,
        [switch]$Check
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    function Invoke-LinuxScript {
        param([string]$Script, [string[]]$Arguments = @())
        $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ('wsl-second-disk-' + [guid]::NewGuid() + '.sh')
        try {
            $quoted = foreach ($argument in $Arguments) { "'" + $argument.Replace("'", "'\''") + "'" }
            $content = "#!/usr/bin/env bash`nset -- " + ($quoted -join ' ') + "`n" + $Script.Replace("`r`n", "`n") + "`n"
            [IO.File]::WriteAllText($scriptPath, $content, (New-Object Text.UTF8Encoding($false)))
            $linuxPath = @(& wsl.exe -d $Distro -u root --exec wslpath -u $scriptPath.Replace('\', '/'))
            if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the Linux setup script path.' }
            # Elevated Windows sessions can have a separate mount namespace.
            $result = @(& wsl.exe -d $Distro -u root --exec nsenter -t 1 -m -- bash (($linuxPath -join '').Trim()))
            if ($LASTEXITCODE -ne 0) { throw "Linux operation failed (exit $LASTEXITCODE)." }
            return $result
        } finally { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    }

    function Invoke-LinuxRemoval {
        param([switch]$CheckOnly)
        & wsl.exe -d $Distro -u root --exec nsenter -t 1 -m -- test -f "/usr/local/lib/wsl-second-disk/$Name/config.sh"
        if ($LASTEXITCODE -eq 1) { return }
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the Linux disk configuration; settings have been retained.' }
        $arguments = @('--name', $Name, '--non-interactive')
        if ($CheckOnly) { $arguments += '--check' }
        Invoke-LinuxScript -Script (Get-LinuxUninstaller) -Arguments $arguments | Out-Host
    }

    function Get-LinuxUninstaller {
        # BEGIN EMBEDDED LINUX UNINSTALLER
        return @'
#!/usr/bin/env bash
# Remove one disk's WSL integration. Data directories are always preserved.
set -Eeuo pipefail
name=''
check=0
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
while (($#)); do
    case "$1" in
    --name)
        (($# >= 2)) || die 'Missing disk name.'
        name="$2"
        shift 2
        ;;
    --non-interactive)
        shift
        ;;
    --check)
        check=1
        shift
        ;;
    -h | --help)
        printf 'Usage: bash uninstall_wsl.sh [--name NAME] [--non-interactive] [--check]\nStop dependent containers and processes first. Data is never deleted.\n'
        exit 0
        ;;
    *) die "Unknown option: $1" ;;
    esac
done
[[ -n "${name}" ]] || die 'A disk name is required.'
[[ "${name}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die 'Invalid disk name.'
config="/usr/local/lib/wsl-second-disk/${name}/config.sh"
[[ -f "${config}" ]] || die "Disk is not configured: ${name}"
# shellcheck source=/dev/null
source "${config}"
printf 'Disconnect %s; retain all data at %s.\n' "${name}" "${DATA_ROOT}"
for target in "${BIND_TARGETS[@]}"; do printf 'Remove binding: %s\n' "${target}"; done
((check == 0)) || exit 0
((EUID == 0)) || die 'Linux removal requires root.'

# Stop the one coordinator before modifying its configuration, then serialize with manual recovery.
if [[ -f /run/wsl-second-disk-boot.pid ]]; then
    pid="$(cat /run/wsl-second-disk-boot.pid)"
    if [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cmdline" ]] &&
        tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -q '/usr/local/sbin/wsl-disk-boot --run'; then
        group="$(awk '{print $5}' "/proc/${pid}/stat")"
        if [[ "${group}" == "${pid}" ]]; then
            # setsid creates a private group; stop children that also hold recovery locks.
            kill -TERM -- "-${pid}"
        else
            kill "${pid}"
        fi
        for ((attempt = 0; attempt < 50; attempt++)); do
            [[ -r "/proc/${pid}/cmdline" ]] || break
            sleep 0.1
        done
    fi
fi
trap 'if [[ -x /usr/local/sbin/wsl-disk-boot ]]; then /usr/local/sbin/wsl-disk-boot; fi' EXIT
exec 8>/run/wsl-second-disk-recovery.lock
flock 8
# Abort on a busy mount; never lazily unmount live application data.
for index in "${!BIND_TARGETS[@]}"; do
    target="${BIND_TARGETS[${index}]}"
    if mountpoint -q "${target}"; then
        [[ -d "${BIND_SOURCES[${index}]}" &&
            "$(stat -c '%d:%i' -- "${target}")" == "$(stat -c '%d:%i' -- "${BIND_SOURCES[${index}]}")" ]] || die "Unexpected mount at ${target}."
        umount -- "${target}" || die "Mount is busy: ${target}. Stop dependent processes and retry."
    fi
done
backup="$(mktemp -d /var/backups/wsl-second-disk-uninstall.XXXXXXXX)"
cp -a /etc/fstab "${backup}/fstab"
cp -a "${config}" "${backup}/config.sh"
[[ ! -f /etc/wsl.conf ]] || cp -a /etc/wsl.conf "${backup}/wsl.conf"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"; if [[ -x /usr/local/sbin/wsl-disk-boot ]]; then /usr/local/sbin/wsl-disk-boot; fi' EXIT
awk -v begin="# BEGIN WSL SECOND DISK ${name}" -v end="# END WSL SECOND DISK ${name}" '
    $0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }
' /etc/fstab >"${work}/fstab"
install -o root -g root -m 0644 "${work}/fstab" /etc/fstab
rm -- "${config}"
for legacy in "$(dirname -- "${config}")/boot" "$(dirname -- "${config}")/fix-mount"; do
    [[ ! -f "${legacy}" ]] || {
        cp -a -- "${legacy}" "${backup}/$(basename -- "${legacy}")"
        rm -- "${legacy}"
    }
done
rmdir -- "$(dirname -- "${config}")" 2>/dev/null || true
shopt -s nullglob
remaining=(/usr/local/lib/wsl-second-disk/*/config.sh)
if ((${#remaining[@]} == 0)); then
    if [[ -f /etc/wsl.conf ]]; then
        awk '/^[[:space:]]*\[/ { boot=($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/) }
            boot && /^[[:space:]]*command[[:space:]]*=[[:space:]]*\/usr\/local\/sbin\/wsl-disk-boot[[:space:]]*$/ {next} {print}' \
            /etc/wsl.conf >"${work}/wsl.conf"
        install -o root -g root -m 0644 "${work}/wsl.conf" /etc/wsl.conf
    fi
    rm -f /usr/local/bin/wsl-disk /usr/local/sbin/wsl-disk-boot /usr/local/lib/wsl-second-disk/fix-mount
    rm -f /run/wsl-second-disk-boot.pid /run/wsl-second-disk-boot.lock /run/wsl-second-disk-recovery.lock
    rm -f /var/log/wsl-second-disk/recovery.log
    rmdir /var/log/wsl-second-disk /usr/local/lib/wsl-second-disk 2>/dev/null || true
fi
printf 'Removed WSL integration. Backups: %s\n' "${backup}"
'@
        # END EMBEDDED LINUX UNINSTALLER
    }

    function Save-UnderlyingMountData {
        param([string]$DiskName, [string]$Distribution, [string]$Uuid)
        # A normal bind of the parent exposes the directory underneath the mounted VHDX.
        # Preserve placeholder contents so WSL can remove its mount-point directory on detach.
        $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ('wsl-unmount-' + [guid]::NewGuid() + '.sh')
        $script = @'
#!/usr/bin/env bash
set -Eeuo pipefail
name="$1"; uuid="$2"; root="/mnt/wsl/$1"
[[ "${name}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || exit 1
[[ "$(findmnt -n -o UUID --mountpoint "${root}")" == "${uuid}" ]] || exit 1
view="$(mktemp -d /run/wsl-disk-unmount.XXXXXX)"
cleanup() { mountpoint -q "${view}" && umount "${view}"; rmdir "${view}"; }
trap cleanup EXIT
mount --bind /mnt/wsl "${view}"
underlying="${view}/${name}"
[[ -d "${underlying}" && ! -L "${underlying}" ]] || exit 1
! mountpoint -q "${underlying}" || exit 1
[[ "$(stat -c %d "${underlying}")" != "$(stat -c %d "${root}")" ]] || exit 1
if [[ -n "$(find "${underlying}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    backup="$(mktemp -d /var/backups/wsl-second-disk-placeholder.XXXXXXXX)"
    find "${underlying}" -mindepth 1 -maxdepth 1 -exec mv -t "${backup}" -- {} +
    printf 'Preserved underlying mount-point contents: %s\n' "${backup}"
fi
'@
        try {
            [IO.File]::WriteAllText($scriptPath, $script.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
            $linuxPath = @(& wsl.exe -d $Distribution -u root --exec wslpath -u $scriptPath.Replace('\', '/'))
            if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the unmount helper path.' }
            & wsl.exe -d $Distribution -u root --exec nsenter -t 1 -m -- bash (($linuxPath -join '').Trim()) $DiskName $Uuid | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Could not preserve the underlying mount-point contents; nothing was detached.' }
        } finally { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        if ($NonInteractive) { throw '-Name is required in non-interactive mode.' }
        $Name = (Read-Host 'Disk name to disconnect').Trim()
    }
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{0,30}$') { throw 'Invalid disk name.' }
    $stateRoot = Join-Path $env:LOCALAPPDATA 'WslSecondDisk'
    $configPath = Join-Path (Join-Path $stateRoot $Name) 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Disk is not configured: $Name" }
    $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($configuration.Name -cne $Name) { throw 'Unexpected saved disk name.' }
    $VhdPath = [string]$configuration.VhdPath
    $Distro = [string]$configuration.Distro
    Write-Host "Remove Windows integration: $Name; VHDX: $VhdPath"
    if ($DeleteVhd) { Write-Host 'The VHDX and all data inside it will be permanently deleted.' }
    else { Write-Host 'The VHDX and all data inside it will be preserved.' }
    if ($Check) {
        Invoke-LinuxRemoval -CheckOnly
        return
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as administrator under the Windows account that owns WSL.'
    }
    $mutex = New-Object Threading.Mutex($false, 'Global\WslSecondDisk-Setup')
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'Timed out waiting for disk setup or attachment.' }
        # With data deletion requested, require an existing ordinary VHDX file.
        if ($DeleteVhd -and ([IO.Path]::GetExtension($VhdPath) -ine '.vhdx' -or
            -not (Test-Path -LiteralPath $VhdPath -PathType Leaf) -or
            ((Get-Item -LiteralPath $VhdPath).Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw 'Refusing to delete an invalid or redirected VHDX path.'
        }
        $runtime = Join-Path $stateRoot 'attach.ps1'
        $otherDisks = @(Get-ChildItem -LiteralPath $stateRoot -Filter config.json -Recurse -File |
            Where-Object { $_.FullName -ine $configPath })
        $task = $null
        if ($otherDisks.Count -eq 0) {
            $task = Get-ScheduledTask -TaskName WslSecondDisk -ErrorAction SilentlyContinue
            if ($null -ne $task -and (@($task.Actions)[0].Execute -ine 'powershell.exe' -or
                @($task.Actions)[0].Arguments.IndexOf($runtime, [StringComparison]::OrdinalIgnoreCase) -lt 0)) {
                throw 'Refusing to remove an unrelated task named WslSecondDisk.'
            }
        }
        $action = 'Detach disk and remove its Windows settings'
        if ($DeleteVhd) { $action += '; permanently delete the VHDX and all its data' }
        # Non-interactive removal requires an explicit -DeleteVhd to delete data; -WhatIf still applies.
        if (-not $PSBoundParameters.ContainsKey('Confirm') -and $NonInteractive) { $ConfirmPreference = 'None' }
        if ($PSCmdlet.ShouldProcess($VhdPath, $action)) {
            $mountJson = @(& wsl.exe -d $Distro -u root --exec nsenter -t 1 -m -- findmnt --json --mountpoint "/mnt/wsl/$Name" -o UUID)
            if ($LASTEXITCODE -eq 0) {
                $mount = ($mountJson -join "`n") | ConvertFrom-Json
                if (@($mount.filesystems)[0].uuid -cne $configuration.FileSystemUuid) {
                    throw 'Mounted disk UUID does not match; nothing was removed.'
                }
                Invoke-LinuxRemoval
                Save-UnderlyingMountData -DiskName $Name -Distribution $Distro -Uuid $configuration.FileSystemUuid
                & wsl.exe --unmount $VhdPath
                if ($LASTEXITCODE -ne 0) { throw 'Could not detach the disk. Settings and VHDX have been retained.' }
            } elseif ($LASTEXITCODE -eq 1) { Invoke-LinuxRemoval }
            else { throw 'Cannot inspect the disk mount. Settings have been retained.' }
            $backupDir = Join-Path (Join-Path $env:LOCALAPPDATA 'WslSecondDiskBackups') ('removed-' + $Name + '-' + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $backup = Join-Path $backupDir 'config.json'
            Copy-Item -LiteralPath $configPath -Destination $backup
            if ($DeleteVhd) { Remove-Item -LiteralPath $VhdPath -Force }
            Remove-Item -LiteralPath $configPath
            Move-Item -LiteralPath (Split-Path -Parent $configPath) -Destination (Join-Path $backupDir 'previous-settings')
            $remaining = @(Get-ChildItem -LiteralPath $stateRoot -Filter config.json -Recurse -File)
            if ($remaining.Count -eq 0) {
                if ($null -ne $task) { Unregister-ScheduledTask -TaskName WslSecondDisk -Confirm:$false }
                Remove-Item -LiteralPath $runtime -Force -ErrorAction SilentlyContinue
                if (@(Get-ChildItem -LiteralPath $stateRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $stateRoot }
            }
            Write-Host "Removed disk settings. Backup: $backup"
        }
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

$entryOptions = @{}
foreach ($key in @('Name', 'NonInteractive', 'DeleteVhd', 'Check', 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction')) {
    if ($PSBoundParameters.ContainsKey($key)) { $entryOptions[$key] = $PSBoundParameters[$key] }
}
Invoke-WslSecondDiskRemoval @entryOptions
