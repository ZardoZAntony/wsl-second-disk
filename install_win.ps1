#Requires -Version 5.1
<#
.SYNOPSIS
Set up an ext4 VHDX, directory bindings and optional Docker recovery from Windows.
.EXAMPLE
.\install_win.ps1
.EXAMPLE
.\install_win.ps1 -VhdPath D:\WSLData\data.vhdx -Create -SizeGB 100 -NonInteractive
#>
[CmdletBinding()]
param(
    [string]$VhdPath,
    [string]$Distro = 'Ubuntu',
    [string]$Name = 'data',
    [string]$LinuxUser,
    [string[]]$Bind = @(),
    [switch]$DockerRecovery,
    [switch]$NoDockerRecovery,
    [ValidateRange(1, 65536)]
    [int]$SizeGB = 100,
    [switch]$Create,
    [switch]$NonInteractive,
    [switch]$Check,
    [switch]$AttachOnly,
    [switch]$AttachAll
)

function Invoke-WslSecondDiskSetup {
    [CmdletBinding()]
    param(
        [string]$VhdPath,
        [string]$Distro = 'Ubuntu',
        [ValidatePattern('^[a-z][a-z0-9-]{0,30}$')]
        [string]$Name = 'data',
        [string]$LinuxUser,
        [string[]]$Bind = @(),
        [switch]$DockerRecovery,
        [switch]$NoDockerRecovery,
        [ValidateRange(1, 65536)]
        [int]$SizeGB = 100,
        [switch]$Create,
        [switch]$NonInteractive,
        [switch]$Check,
        [switch]$AttachOnly,
        [switch]$AttachAll
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

    function Get-WslDistributions {
        $names = @(& wsl.exe --list --quiet)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot list installed WSL distributions.' }
        $versions = @(& wsl.exe --list --verbose)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect installed WSL versions.' }
        foreach ($entry in $names) {
            $candidate = $entry.Replace("`0", '').Trim().Trim([char]0xFEFF)
            if (-not $candidate -or $candidate -like 'docker-desktop*') { continue }
            $pattern = '^\s*\*?\s*' + [regex]::Escape($candidate) + '\s+.+\s+2\s*$'
            if (@($versions | Where-Object { $_.Replace("`0", '') -match $pattern }).Count) { $candidate }
        }
    }

    function Get-LinuxProfile {
        $metadata = @'
set -Eeuo pipefail
name="$1"
[[ "${name}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || exit 1
config="/usr/local/lib/wsl-second-disk/${name}/config.sh"
if [[ -f "${config}" ]]; then
    source "${config}"
    printf 'USER:%s\nDOCKER:%s\n' "${LINUX_USER}" "${DOCKER_RECOVERY}"
    for index in "${!BIND_SOURCES[@]}"; do
        printf 'BIND:'
        printf '%s=%s' "${BIND_SOURCES[${index}]#"${DATA_ROOT}/"}" "${BIND_TARGETS[${index}]}" | base64 -w 0
        printf '\n'
    done
fi
'@
        $profile = [pscustomobject]@{ User=''; Docker=$false; Bindings=@() }
        foreach ($line in @(Invoke-LinuxScript -Script $metadata -Arguments @($Name))) {
            if ($line.StartsWith('USER:')) { $profile.User = $line.Substring(5) }
            elseif ($line.StartsWith('DOCKER:')) { $profile.Docker = $line.Substring(7) -eq '1' }
            elseif ($line.StartsWith('BIND:')) {
                $profile.Bindings += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(5)))
            }
        }
        return $profile
    }

    function Get-LinuxArguments {
        param([switch]$PrerequisitesOnly)
        $arguments = @('--name', $Name, '--user', $LinuxUser, '--non-interactive')
        foreach ($mapping in $Bind) { $arguments += @('--bind', $mapping) }
        if ($DockerRecovery) { $arguments += '--docker-recovery' }
        elseif ($NoDockerRecovery) { $arguments += '--no-docker-recovery' }
        if ($PrerequisitesOnly) { $arguments += '--prerequisites-only' }
        return $arguments
    }

    function Write-AttachRuntime {
        param([string]$Path)
        # Generate a standalone dispatcher; this also works when the installer is evaluated with iex.
        $content = "#Requires -Version 5.1`n[CmdletBinding()]`nparam([switch]`$AttachAll, [switch]`$NonInteractive)`n" +
            "Set-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n"
        foreach ($functionName in @('Invoke-Wsl', 'Get-MountInfo', 'Mount-DataDisk', 'Invoke-AllAttachments', 'Invoke-AttachAll')) {
            $definition = (Get-Item -LiteralPath "Function:\$functionName").ScriptBlock.ToString()
            $content += "function $functionName {`n$definition`n}`n"
        }
        $content += "Invoke-AttachAll`n"
        [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($false)))
    }

    function Get-LinuxInstaller {
        # BEGIN EMBEDDED LINUX INSTALLER
        return @'
#!/usr/bin/env bash
# Private Linux backend, invoked by install_win.ps1 as root in the distro mount namespace.
set -Eeuo pipefail
((EUID == 0)) || {
    echo 'Linux setup requires root.' >&2
    exit 1
}
name='data'
owner="${SUDO_USER:-$(id -un)}"
check_only=0
docker_recovery=0
docker_option_given=0
prerequisites_only=0
declare -a mappings=()
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}
while (($#)); do
    case "$1" in
    --name | --user | --bind)
        (($# >= 2)) || die "Missing value for $1"
        case "$1" in --name) name="$2" ;; --user)
            owner="$2"
            ;;
        --bind) mappings+=("$2") ;; esac
        shift 2
        ;;
    --check)
        check_only=1
        shift
        ;;
    --docker-recovery)
        docker_recovery=1
        docker_option_given=1
        shift
        ;;
    --no-docker-recovery)
        docker_recovery=0
        docker_option_given=1
        shift
        ;;
    --non-interactive) shift ;;
    --prerequisites-only)
        prerequisites_only=1
        shift
        ;;
    *) die "Unknown option: $1" ;;
    esac
done
[[ "${name}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die 'Name must match [a-z][a-z0-9-]{0,30}.'
[[ "${owner}" != root ]] || die 'Run as a regular user or specify --user.'
owner_entry="$(getent passwd "${owner}")" || die "Unknown user: ${owner}"
IFS=: read -r _ _ owner_uid owner_gid _ owner_home _ <<<"${owner_entry}"
[[ "${owner_uid}" != 0 ]] || die 'Choose a user with a nonzero UID.'
readonly data_root="/mnt/wsl/${name}"
readonly runtime_dir="/usr/local/lib/wsl-second-disk/${name}"
readonly marker_begin="# BEGIN WSL SECOND DISK ${name}"
readonly marker_end="# END WSL SECOND DISK ${name}"
# Re-running without new mappings preserves the saved bindings and Docker preference.
if [[ -f "${runtime_dir}/config.sh" ]]; then
    # Generated configuration is installed at runtime, not stored in the repository.
    # shellcheck source=/dev/null
    source "${runtime_dir}/config.sh"
    # shellcheck disable=SC2153
    [[ "${DATA_ROOT}" == "${data_root}" ]] || die 'Saved configuration has an unexpected data root.'
    if ((${#mappings[@]} == 0)); then
        for index in "${!BIND_SOURCES[@]}"; do
            mappings+=("${BIND_SOURCES[${index}]#"${data_root}/"}=${BIND_TARGETS[${index}]}")
        done
    fi
    # shellcheck disable=SC2153
    if ((docker_option_given == 0)); then docker_recovery="${DOCKER_RECOVERY}"; fi
fi
for command in findmnt mountpoint stat awk install cmp mktemp getent flock realpath; do
    command -v "${command}" >/dev/null || die "Required command is missing: ${command}"
done
if ((docker_recovery)); then command -v docker >/dev/null || die 'Docker CLI is required for --docker-recovery.'; fi
boot_command=''
if [[ -f /etc/wsl.conf ]]; then
    boot_command="$(awk '/^[[:space:]]*\[/ { b=($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/) }
        b && /^[[:space:]]*command[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print}' /etc/wsl.conf)"
fi
[[ -z "${boot_command}" || "${boot_command}" == /usr/local/sbin/wsl-disk-boot ]] ||
    die "An existing WSL boot command must be integrated manually: ${boot_command}"
if ((prerequisites_only)); then
    printf 'Linux prerequisites OK: user=%s\n' "${owner}"
    exit 0
fi
mountpoint -q "${data_root}" || die "Run install_win.ps1 first; ${data_root} is not mounted."
[[ "$(findmnt -n -o FSTYPE --mountpoint "${data_root}")" == ext4 ]] || die "Expected ext4 at ${data_root}."
filesystem_uuid="$(findmnt -n -o UUID --mountpoint "${data_root}")"
[[ -n "${filesystem_uuid}" ]] || die 'Could not determine filesystem UUID.'
if [[ -n "${FILESYSTEM_UUID:-}" && "${FILESYSTEM_UUID}" != "${filesystem_uuid}" ]]; then
    die 'The mounted disk does not match the saved filesystem UUID.'
fi

fstab_escape() {
    local value="$1"
    value="${value//\\/\\134}"
    value="${value// /\\040}"
    printf '%s' "${value}"
}
declare -a sources=() targets=()
for mapping in "${mappings[@]}"; do
    [[ "${mapping}" == *=* ]] || die "Expected SOURCE=TARGET: ${mapping}"
    relative="${mapping%%=*}"
    target="${mapping#*=}"
    [[ -n "${relative}" && "${relative}" != /* && "${relative}" != *$'\n'* && "${relative}" != *$'\t'* ]] ||
        die "Invalid source: ${relative}"
    [[ "/${relative}/" != */../* && "/${relative}/" != */./* ]] || die 'Relative source must not contain . or .. components.'
    [[ "${target}" == /* && "${target}" != *$'\n'* && "${target}" != *$'\t'* ]] || die "Expected absolute target: ${target}"
    [[ ! -L "${target}" ]] || die "Target is a symlink: ${target}"
    target="$(realpath -m -- "${target}")"
    source="$(realpath -m -- "${data_root}/${relative}")"
    [[ "${source}" == "${data_root}"/* ]] || die 'Source escapes the data disk.'
    [[ "${target}" != / && "${target}" != "${data_root}" && "${target}" != "${data_root}"/* ]] || die 'Target overlaps the data disk.'
    for previous in "${targets[@]}"; do
        [[ "${target}" != "${previous}" && "${target}" != "${previous}"/* && "${previous}" != "${target}"/* ]] ||
            die 'Duplicate or nested targets are not supported.'
    done
    if mountpoint -q "${target}"; then
        [[ -d "${source}" && "$(stat -c '%d:%i' -- "${source}")" == "$(stat -c '%d:%i' -- "${target}")" ]] ||
            die "Another directory is mounted at ${target}"
    elif [[ -e "${target}" ]]; then
        [[ -d "${target}" ]] || die "Target is not a directory: ${target}"
        [[ -z "$(find "${target}" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
            die "Target contains local data: ${target}. Move the data before installation."
    fi
    escaped_target="$(fstab_escape "${target}")"
    configured_source="$(WSL_DISK_TARGET="${escaped_target}" awk 'BEGIN {t=ENVIRON["WSL_DISK_TARGET"]} $0 !~ /^[[:space:]]*#/ && $2 == t {print $1}' /etc/fstab)"
    [[ -z "${configured_source}" || "${configured_source}" == "$(fstab_escape "${source}")" ]] ||
        die "Conflicting fstab entry for ${target}"
    sources+=("${source}")
    targets+=("${target}")
done
if [[ -f "${runtime_dir}/config.sh" ]]; then
    for previous in "${BIND_TARGETS[@]}"; do
        retained=0
        for target in "${targets[@]}"; do [[ "${target}" != "${previous}" ]] || retained=1; done
        ((retained)) || ! mountpoint -q "${previous}" || die "Unmount ${previous} before removing its binding."
    done
fi
shopt -s nullglob
for other_config in /usr/local/lib/wsl-second-disk/*/config.sh; do
    [[ "${other_config}" != "${runtime_dir}/config.sh" ]] || continue
    while IFS= read -r other_target; do
        for target in "${targets[@]}"; do
            [[ "${target}" != "${other_target}" && "${target}" != "${other_target}"/* && "${other_target}" != "${target}"/* ]] ||
                die "Target overlaps another disk binding: ${other_target}"
        done
    done < <(bash -c 'source "$1"; for target in "${BIND_TARGETS[@]}"; do printf "%s\n" "${target}"; done' bash "${other_config}")
done
printf 'Preflight OK: user=%s disk=%s UUID=%s binds=%s Docker=%s\n' "${owner}" "${data_root}" "${filesystem_uuid}" "${#sources[@]}" "${docker_recovery}"
((check_only == 0)) || exit 0
work_dir="$(mktemp -d /tmp/wsl-second-disk.XXXXXX)"
trap 'rm -rf -- "${work_dir}"' EXIT
backup_dir="$(mktemp -d /var/backups/wsl-second-disk.XXXXXXXX)"
replace_file() {
    local staged="$1" destination="$2" mode="$3"
    cmp -s -- "${staged}" "${destination}" && return 0
    if [[ -e "${destination}" ]]; then
        mkdir -p -- "${backup_dir}$(dirname -- "${destination}")"
        cp -a -- "${destination}" "${backup_dir}${destination}"
    fi
    install -o root -g root -m "${mode}" -- "${staged}" "${destination}"
}
{
    printf 'DISK_NAME=%q\nLINUX_USER=%q\nLINUX_HOME=%q\nDATA_ROOT=%q\nFILESYSTEM_UUID=%q\nWINDOWS_TASK=%q\nDOCKER_RECOVERY=%q\n' \
        "${name}" "${owner}" "${owner_home}" "${data_root}" "${filesystem_uuid}" "WslSecondDisk" "${docker_recovery}"
    printf 'BIND_SOURCES=('
    if ((${#sources[@]})); then printf ' %q' "${sources[@]}"; fi
    printf ' )\n'
    printf 'BIND_TARGETS=('
    if ((${#targets[@]})); then printf ' %q' "${targets[@]}"; fi
    printf ' )\n'
} >"${work_dir}/config"
cat >"${work_dir}/fix-mount" <<'WSL_DISK_RECOVERY'
#!/usr/bin/env bash
# Generated recovery coordinator. Run through wsl-disk; per-disk configurations are in subdirectories.
set -Eeuo pipefail

readonly config_root='/usr/local/lib/wsl-second-disk'
readonly proxy_root='/mnt/wsl/docker-desktop-bind-mounts'
readonly field=$'\x1f'
readonly item=$'\x1e'
readonly pair=$'\x1d'

check_only=0
system_only=0
problems=0
declare -a bind_sources=()
declare -a bind_targets=()
declare -a blocked_targets=() ready_sources=() ready_targets=() ready_docker=()
declare -A owner_homes=()
docker_user=''
docker_home=''

docker() {
    if ((EUID == 0)); then
        runuser -u "${docker_user}" -- env HOME="${docker_home}" docker "$@"
    else
        command docker "$@"
    fi
}

log() { printf '%s\n' "$*"; }
warn() {
    printf '* %s\n' "$*"
    problems=1
}
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Boot runs the system part as root, without a sudo prompt.
as_root() {
    if ((EUID == 0)); then
        "$@"
    else
        sudo "$@"
    fi
}

is_within() {
    [[ "$1" == "$2" || "$1" == "$2"/* ]]
}

# Read every disk before recovery so a container using several disks is handled once.
# shellcheck disable=SC2153
load_disks() {
    local config='' index=0 disk_ready=0 source='' target=''
    shopt -s nullglob
    for config in "${config_root}"/*/config.sh; do
        # shellcheck source=/dev/null
        source "${config}"
        disk_ready=0
        if mountpoint -q "${DATA_ROOT}" &&
            [[ "$(findmnt -n -o FSTYPE --mountpoint "${DATA_ROOT}")" == ext4 ]] &&
            [[ "$(findmnt -n -o UUID --mountpoint "${DATA_ROOT}")" == "${FILESYSTEM_UUID}" ]]; then
            disk_ready=1
            if ((DOCKER_RECOVERY)); then
                ready_sources+=("${DATA_ROOT}")
                ready_targets+=("${DATA_ROOT}")
                ready_docker+=(1)
            fi
        else
            blocked_targets+=("${DATA_ROOT}")
            warn "Disk ${DATA_ROOT} is unavailable or has the wrong filesystem UUID."
        fi
        for index in "${!BIND_TARGETS[@]}"; do
            source="${BIND_SOURCES[${index}]}"
            target="${BIND_TARGETS[${index}]}"
            if ((disk_ready)) && [[ -d "${source}" ]]; then
                if ! mountpoint -q "${target}" && ((!check_only)); then
                    as_root mkdir -p -- "${target}"
                    as_root mount -- "${target}" || warn "Could not mount ${target}."
                fi
                if mountpoint -q "${target}" &&
                    [[ "$(stat -c '%d:%i' -- "${source}")" == "$(stat -c '%d:%i' -- "${target}")" ]]; then
                    ready_sources+=("${source}")
                    ready_targets+=("${target}")
                    ready_docker+=("${DOCKER_RECOVERY}")
                    continue
                fi
            fi
            blocked_targets+=("${target}")
            warn "Binding is unavailable: ${target}."
        done
        if ((DOCKER_RECOVERY)); then owner_homes["${LINUX_USER}"]="${LINUX_HOME}"; fi
    done
}

# Prevent recreation when ANY registered disk required by this container is unavailable,
# including a disk that has not opted into Docker recovery.
container_blocked() {
    local mounts="$1" entry='' source='' target=''
    local -a entries=()
    IFS="${pair}" read -r -a entries <<<"${mounts}"
    for entry in "${entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        source="${entry%%"${item}"*}"
        for target in "${blocked_targets[@]}"; do
            if is_within "${source}" "${target}" || is_within "${target}" "${source}"; then return 0; fi
        done
    done
    return 1
}

# Drop Docker Desktop proxies still pointing at the placeholder filesystem.
# Docker recreates these proxies when the affected containers are recreated.
drop_stale_proxies() {
    local target=''
    local device=''
    local root=''
    local mount_point=''
    local rest=''
    local parent_device=''
    local -A target_devices=() wsl_aliases=() stale=()

    for target in "${bind_targets[@]}"; do
        mountpoint -q "${target}" || continue
        target_devices["${target}"]="$(findmnt -n -o MAJ:MIN --target "${target}" | tr -d ' ')"
        if [[ "${target}" == /mnt/wsl/* ]]; then
            # A proxy rooted in WSL's parent tmpfs records /name/path, not /mnt/wsl/name/path.
            wsl_aliases["${target#/mnt/wsl}"]=1
        fi
    done
    if ((${#wsl_aliases[@]})); then
        parent_device="$(findmnt -n -o MAJ:MIN --target /mnt/wsl | tr -d ' ')"
    fi

    while read -r _ _ device root mount_point rest; do
        printf -v root '%b' "${root}"
        printf -v mount_point '%b' "${mount_point}"
        [[ "${mount_point}" == "${proxy_root}"/* ]] || continue
        for target in "${!target_devices[@]}"; do
            is_within "${root}" "${target}" || continue
            [[ "${device}" != "${target_devices[${target}]}" ]] && stale["${mount_point}"]=1
        done
        # Restrict relative roots to the actual parent filesystem, preserving other disks' proxies.
        if [[ -n "${parent_device}" && "${device}" == "${parent_device}" ]]; then
            for target in "${!wsl_aliases[@]}"; do
                is_within "${root}" "${target}" && stale["${mount_point}"]=1
            done
        fi
    done </proc/self/mountinfo

    ((${#stale[@]} > 0)) || return 0
    if ((check_only)); then
        warn "Stale Docker Desktop mount proxies: ${#stale[@]}."

        return 0
    fi

    as_root umount --lazy -- "${!stale[@]}"
    log "Removed stale Docker Desktop mount proxies: ${#stale[@]}."
}

# Does this path belong to a currently unmounted target?
under_unmounted_target() {
    local path="$1"
    local target=''

    for target in "${bind_targets[@]}"; do
        is_within "${path}" "${target}" || continue
        mountpoint -q "${target}" || return 0
    done

    return 1
}

under_any_target() {
    local path="$1"
    local target=''

    for target in "${bind_targets[@]}"; do
        is_within "${path}" "${target}" && return 0
    done

    return 1
}

# Compare directory inodes. If a container cannot be inspected, do not recreate it blindly.
sees_same() {
    local id="$1"
    local host_path="$2"
    local container_path="$3"
    local host_inode=''
    local container_inode=''

    host_inode="$(stat -c %i -- "${host_path}" 2>/dev/null || true)"
    container_inode="$(docker exec "${id}" stat -c %i -- "${container_path}" 2>/dev/null || true)"
    [[ -z "${host_inode}" || -z "${container_inode}" || "${host_inode}" == "${container_inode}" ]]
}

# Return the reason for recreating a container, or an empty string.
# Check both direct mounts and directories exposed through a parent mount.
stale_reason() {
    local id="$1"
    local status="$2"
    local policy="$3"
    local error="$4"
    local mounts="$5"
    local entry=''
    local source=''
    local destination=''
    local target=''
    local touches=0
    local -a entries=()

    IFS="${pair}" read -r -a entries <<<"${mounts}"
    for entry in "${entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        source="${entry%%"${item}"*}"
        destination="${entry#*"${item}"}"
        if under_any_target "${source}"; then
            touches=1
            [[ "${status}" == 'running' ]] || continue
            if under_unmounted_target "${source}"; then
                printf 'requires mounting %s\n' "${source}"

                return
            fi
            if ! sees_same "${id}" "${source}" "${destination}"; then
                printf 'sees a placeholder instead of %s\n' "${source}"

                return
            fi
            continue
        fi

        for target in "${bind_targets[@]}"; do
            [[ "${target}" == "${source}"/* ]] || continue
            touches=1
            [[ "${status}" == 'running' ]] || continue
            if ! mountpoint -q "${target}"; then
                printf 'requires mounting %s\n' "${target}"

                return
            fi
            if ! sees_same "${id}" "${target}" "${destination}${target#"${source}"}"; then
                printf 'sees a placeholder instead of %s\n' "${target}"

                return
            fi
        done
    done

    ((touches)) || return 0
    if [[ "${status}" == 'restarting' ]]; then
        printf 'is restarting repeatedly\n'
    elif [[ "${status}" != 'running' && -n "${error}" ]] &&
        [[ "${policy}" == 'unless-stopped' || "${policy}" == 'always' ]]; then
        printf 'failed to start\n'
    fi
}

declare -A project_services=()
declare -A project_dir=()
declare -A project_files=()
declare -A project_env=()

collect_stale() {
    local listing=''
    local id=''
    local name=''
    local status=''
    local policy=''
    local error=''
    local project=''
    local service=''
    local dir=''
    local files=''
    local env=''
    local mounts=''
    local reason=''
    local -a ids=()

    mapfile -t ids < <(docker ps -aq)
    ((${#ids[@]} > 0)) || return 0
    local label='{{index .Config.Labels "com.docker.compose.'
    local format=''

    format="{{.Id}}${field}{{.Name}}${field}{{.State.Status}}${field}{{.HostConfig.RestartPolicy.Name}}${field}"
    format+="{{.State.Error}}${field}${label}project\"}}${field}${label}service\"}}${field}"
    format+="${label}project.working_dir\"}}${field}${label}project.config_files\"}}${field}"
    format+="${label}project.environment_file\"}}${field}"
    format+="{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}}${item}{{.Destination}}${pair}{{end}}{{end}}"
    listing="$(docker inspect --format "${format}" "${ids[@]}")"

    while IFS="${field}" read -r id name status policy error project service dir files env mounts; do
        [[ -n "${id}" ]] || continue
        # Missing Docker labels are rendered as "<no value>".
        [[ "${project}" != '<no value>' ]] || project=''
        [[ "${service}" != '<no value>' ]] || service=''
        [[ "${dir}" != '<no value>' ]] || dir=''
        [[ "${files}" != '<no value>' ]] || files=''
        [[ "${env}" != '<no value>' ]] || env=''
        if container_blocked "${mounts}"; then
            warn "${name#/}: recovery skipped because a required disk binding is unavailable."
            continue
        fi
        reason="$(stale_reason "${id}" "${status}" "${policy}" "${error}" "${mounts}")"
        [[ -n "${reason}" ]] || continue
        if [[ -z "${project}" || -z "${service}" ]]; then
            warn "${name#/}: ${reason}; not a Compose container, recreate it manually."
            continue
        fi
        warn "${name#/}: ${reason}."
        project_services["${project}"]+=" ${service}"
        project_dir["${project}"]="${dir}"
        project_files["${project}"]="${files}"
        project_env["${project}"]="${env}"
    done <<<"${listing}"
}

recreate_projects() {
    local project=''
    local file=''
    local -a compose=(docker-compose)
    local -a command=()
    local -a files=()
    local -a services=()
    local -a failed=()

    ! docker compose version >/dev/null 2>&1 || compose=(docker compose)
    for project in "${!project_services[@]}"; do
        command=("${compose[@]}" --project-name "${project}" --project-directory "${project_dir[${project}]}")
        IFS=',' read -r -a files <<<"${project_files[${project}]}"
        for file in "${files[@]}"; do
            command+=(--file "${file}")
        done
        [[ -z "${project_env[${project}]}" ]] || command+=(--env-file "${project_env[${project}]}")

        IFS=' ' read -r -a services <<<"${project_services[${project}]}"
        mapfile -t services < <(printf '%s\n' "${services[@]}" | sort -u)
        log "Recreating ${project}: ${services[*]}..."
        "${command[@]}" up -d --no-deps --force-recreate "${services[@]}" || failed+=("${project}")

    done

    # Continue with other projects when one project fails.
    if ((${#failed[@]})); then
        printf 'Failed to recreate: %s\n' "${failed[*]}" >&2
        return 1
    fi
}

main() {
    local selected='' index=0 mount_problems=0 docker_only=0 engine=''
    local -A seen_engines=()
    if [[ "${1:-}" == --name ]]; then
        (($# >= 2)) || die 'Missing disk name.'
        selected="$2"
        shift 2
        [[ "${selected}" =~ ^[a-z][a-z0-9-]{0,30}$ && -f "${config_root}/${selected}/config.sh" ]] || die 'Unknown disk name.'
    fi
    (($# <= 1)) || die 'Too many arguments.'
    case "${1:-}" in
    --check) check_only=1 ;;
    --system) system_only=1 ;;
    --docker-only) docker_only=1 ;;
    '') ;;
    -h | --help)
        printf 'Usage: wsl-disk [--name NAME] [--check]\nRecovery coordinates all registered disks and Compose services.\n'
        return 0
        ;;
    *) die "Unknown argument: $1" ;;
    esac
    if ((!check_only)); then
        if ((EUID != 0)); then
            local -a arguments=()
            [[ -z "${selected}" ]] || arguments+=(--name "${selected}")
            exec sudo "$0" "${arguments[@]}" "$@"
        fi
        exec 8>/run/wsl-second-disk-recovery.lock
        flock 8
        if ((!system_only && !docker_only)); then
            /mnt/c/Windows/System32/schtasks.exe /run /tn WslSecondDisk >/dev/null 2>&1 || true
            local deadline=$((SECONDS + 90)) pending=0 config=''
            while true; do
                pending=0
                shopt -s nullglob
                for config in "${config_root}"/*/config.sh; do
                    # shellcheck source=/dev/null
                    source "${config}"
                    mountpoint -q "${DATA_ROOT}" || pending=1
                done
                ((pending && SECONDS < deadline)) || break
                sleep 3
            done
        fi
    fi
    load_disks
    mount_problems="${problems}"
    if ((system_only)); then return "${problems}"; fi

    for docker_user in "${!owner_homes[@]}"; do
        docker_home="${owner_homes[${docker_user}]}"
        if ((EUID != 0)) && [[ "$(id -un)" != "${docker_user}" ]]; then
            warn "Run recovery with sudo to inspect Docker for ${docker_user}."
            continue
        fi
        bind_sources=() bind_targets=()
        for index in "${!ready_targets[@]}"; do
            if ((ready_docker[index])); then
                bind_sources+=("${ready_sources[${index}]}")
                bind_targets+=("${ready_targets[${index}]}")
            fi
        done
        ((${#bind_targets[@]})) || continue
        if ! docker info >/dev/null 2>&1; then
            warn "Docker is unavailable for ${docker_user}; disk mounts were checked."
            continue
        fi
        engine="$(docker info --format '{{.ID}}' 2>/dev/null || true)"
        # If the daemon supplies no ID, use the owner as a conservative fallback.
        engine="${engine:-owner:${docker_user}}"
        [[ -z "${seen_engines[${engine}]:-}" ]] || continue
        seen_engines["${engine}"]=1
        # Proxy removal needs root; read-only checks can run as the ordinary owner.
        drop_stale_proxies
        project_services=() project_dir=() project_files=() project_env=()
        collect_stale
        if ((!check_only)); then
            recreate_projects || return 1
            problems="${mount_problems}"
            project_services=()
            collect_stale
        fi
    done
    ((problems == 0)) || return 1
    log 'Ready: disks, bind mounts and container paths are ready.'
}

main "$@"
WSL_DISK_RECOVERY
cat >"${work_dir}/boot" <<'WSL_DISK_BACKGROUND'
#!/usr/bin/env bash
# One background coordinator per WSL distribution.
set -Eeuo pipefail
readonly fix_mount='/usr/local/lib/wsl-second-disk/fix-mount'
readonly schtasks='/mnt/c/Windows/System32/schtasks.exe'
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
if [[ "${1:-}" != '--run' ]]; then
    mkdir -p /var/log/wsl-second-disk
    setsid -f "$0" --run >>/var/log/wsl-second-disk/recovery.log 2>&1 </dev/null
    exit 0
fi
exec 9>/run/wsl-second-disk-boot.lock
flock -n 9 || exit 0
printf '%s\n' "$$" >/run/wsl-second-disk-boot.pid
trap 'rm -f /run/wsl-second-disk-boot.pid' EXIT
log 'Waiting for registered disks; restoring available bindings.'
deadline=$((SECONDS + 1800))
until "${fix_mount}" --system; do
    if ((SECONDS >= deadline)); then
        log 'Some disks are still unavailable after 30 minutes; their containers will be skipped.'
        break
    fi
    "${schtasks}" /run /tn WslSecondDisk >/dev/null 2>&1 || log 'Could not trigger the Windows task.'
    sleep 15
done
shopt -s nullglob
declare -A owners=()
for config in /usr/local/lib/wsl-second-disk/*/config.sh; do
    # shellcheck source=/dev/null
    source "${config}"
    if ((DOCKER_RECOVERY)); then owners["${LINUX_USER}"]="${LINUX_HOME}"; fi
done
((${#owners[@]})) || exit 0
log 'Waiting for Docker Desktop.'
deadline=$((SECONDS + 43200))
while true; do
    available=1
    for owner in "${!owners[@]}"; do
        runuser -u "${owner}" -- env HOME="${owners[${owner}]}" timeout 20 docker info >/dev/null 2>&1 || available=0
    done
    ((available)) && break
    ((SECONDS < deadline)) || { log 'Docker did not become available within 12 hours.'; exit 1; }
    sleep 15
done
sleep 60
"${fix_mount}" --docker-only || { log 'Recovery incomplete. Run: wsl-disk'; exit 1; }
log 'Recovery complete.'
WSL_DISK_BACKGROUND
bash -n "${work_dir}/fix-mount" "${work_dir}/boot"

# Preserve unrelated settings; replace only this disk's marked fstab block.
awk -v begin="${marker_begin}" -v end="${marker_end}" '
    $0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }
' /etc/fstab >"${work_dir}/fstab"
printf '%s\n' "${marker_begin}" >>"${work_dir}/fstab"
for index in "${!sources[@]}"; do
    printf '%s %s none bind,nofail 0 0\n' "$(fstab_escape "${sources[${index}]}")" "$(fstab_escape "${targets[${index}]}")" >>"${work_dir}/fstab"
done
printf '%s\n' "${marker_end}" >>"${work_dir}/fstab"
: >"${work_dir}/wsl-source"
[[ ! -f /etc/wsl.conf ]] || cp -- /etc/wsl.conf "${work_dir}/wsl-source"
awk '
    function add() {if (b && !written) {print "command = /usr/local/sbin/wsl-disk-boot"; written=1}}
    /^[[:space:]]*\[/ {add(); b=($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/); if (b) seen=1}
    b && /^[[:space:]]*command[[:space:]]*=/ {if (!written) print "command = /usr/local/sbin/wsl-disk-boot"; written=1; next}
    {print}
    END {add(); if (!seen) print "\n[boot]\ncommand = /usr/local/sbin/wsl-disk-boot"}
' "${work_dir}/wsl-source" >"${work_dir}/wsl.conf"
cat >"${work_dir}/dispatcher" <<'DISPATCHER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/local/lib/wsl-second-disk/fix-mount "$@"
DISPATCHER
install -d -o root -g root -m 0755 -- "${runtime_dir}"
for index in "${!sources[@]}"; do
    [[ -d "${sources[${index}]}" ]] || install -d -o "${owner_uid}" -g "${owner_gid}" -m 0755 -- "${sources[${index}]}"
    [[ -d "${targets[${index}]}" ]] || install -d -o "${owner_uid}" -g "${owner_gid}" -m 0755 -- "${targets[${index}]}"
done
replace_file "${work_dir}/config" "${runtime_dir}/config.sh" 0644
replace_file "${work_dir}/fix-mount" /usr/local/lib/wsl-second-disk/fix-mount 0755
replace_file "${work_dir}/boot" /usr/local/sbin/wsl-disk-boot 0755
replace_file "${work_dir}/dispatcher" /usr/local/bin/wsl-disk 0755
replace_file "${work_dir}/fstab" /etc/fstab 0644
replace_file "${work_dir}/wsl.conf" /etc/wsl.conf 0644
# Remove obsolete per-disk executables after backing them up.
for legacy in "${runtime_dir}/fix-mount" "${runtime_dir}/boot"; do
    if [[ -f "${legacy}" ]]; then
        cp -a -- "${legacy}" "${backup_dir}/$(basename -- "${legacy}").${name}"
        rm -- "${legacy}"
    fi
done
env -u HOME /usr/local/lib/wsl-second-disk/fix-mount --system || printf 'Some other disks are not ready; recovery will retry.\n'
/usr/local/sbin/wsl-disk-boot
printf 'Installed. Backups: %s\n' "${backup_dir}"
printf 'Recovery log: /var/log/wsl-second-disk/recovery.log\n'
printf 'Check: wsl-disk --name %s --check\n' "${name}"
'@
        # END EMBEDDED LINUX INSTALLER
    }

    function Invoke-Wsl {
        param([string[]]$Arguments)
        $result = @(& wsl.exe -d $Distro -u root --exec nsenter -t 1 -m -- @Arguments)
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
        }
        return $result
    }

    function Get-MountInfo {
        $result = @(& wsl.exe -d $Distro -u root --exec nsenter -t 1 -m -- findmnt --json --mountpoint "/mnt/wsl/$Name" -o TARGET,FSTYPE,UUID)
        if ($LASTEXITCODE -eq 1) { return $null }
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the WSL mount point.' }
        $decoded = ($result -join "`n") | ConvertFrom-Json
        return @($decoded.filesystems)[0]
    }

    function Get-WslDisks {
        $json = (Invoke-Wsl -Arguments @('lsblk', '--json', '--bytes', '--nodeps', '-o', 'PATH,TYPE,SIZE')) -join "`n"
        return @(($json | ConvertFrom-Json).blockdevices | Where-Object { $_.type -eq 'disk' })
    }

    function Write-DiskPartScript {
        param([string]$Path, [string]$Commands)
        # DiskPart does not accept a UTF-16 script. Write bytes without a BOM.
        $encoding = [Text.Encoding]::Default
        $bytes = $encoding.GetBytes($Commands)
        if ($encoding.GetString($bytes) -cne $Commands) {
            throw 'The VHDX path cannot be represented in the Windows system code page. Choose another path.'
        }
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    function New-Ext4Vhd {
        # Only this function's newly created VHDX is ever formatted. Existing files are rejected.
        if (Test-Path -LiteralPath $VhdPath) { throw 'Refusing to format an existing VHDX.' }
        $parent = Split-Path -Parent $VhdPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $before = @(Get-WslDisks | ForEach-Object { $_.path })
        $diskpartFile = [IO.Path]::GetTempFileName()
        $formatterFile = Join-Path ([IO.Path]::GetTempPath()) ("wsl-ext4-{0}.sh" -f [guid]::NewGuid())
        $attached = $false
        try {
            $maximumMB = [long]$SizeGB * 1024
            Write-DiskPartScript -Path $diskpartFile -Commands "create vdisk file=`"$VhdPath`" maximum=$maximumMB type=expandable`r`nexit`r`n"
            & diskpart.exe /s $diskpartFile | Out-Host
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $VhdPath)) {
                throw 'DiskPart could not create the VHDX.'
            }
            $stream = [IO.File]::OpenRead($VhdPath)
            try {
                $header = New-Object byte[] 8
                $bytesRead = $stream.Read($header, 0, 8)
                if ($bytesRead -ne 8 -or [Text.Encoding]::ASCII.GetString($header) -ne 'vhdxfile') {
                    throw 'The created file does not have a valid VHDX header.'
                }
            } finally { $stream.Dispose() }

            & wsl.exe --mount $VhdPath --vhd --bare
            if ($LASTEXITCODE -ne 0) { throw 'Could not attach the new VHDX to WSL.' }
            $attached = $true
            Invoke-Wsl -Arguments @('udevadm', 'settle') | Out-Null
            $added = @(Get-WslDisks | Where-Object { $_.path -notin $before })
            $expectedBytes = [long]$SizeGB * 1GB
            if ($added.Count -ne 1 -or [long]$added[0].size -ne $expectedBytes) {
                throw 'Cannot uniquely identify the new disk. Nothing has been formatted.'
            }
            $device = [string]$added[0].path
            $uuid = [guid]::NewGuid().ToString()
            $formatter = @'
#!/usr/bin/env bash
set -Eeuo pipefail
device="$1"; expected_bytes="$2"; uuid="$3"; label="$4"
[[ -b "${device}" ]] || { echo 'Not a block device.' >&2; exit 1; }
[[ "$(blockdev --getsize64 "${device}")" == "${expected_bytes}" ]] || exit 1
[[ "$(lsblk -nr -o NAME "${device}" | wc -l)" -eq 1 ]] || { echo 'Disk has partitions; refusing to format.' >&2; exit 1; }
[[ -z "$(lsblk -nr -o MOUNTPOINTS "${device}" | tr -d '[:space:]')" ]] || { echo 'Disk is mounted; refusing to format.' >&2; exit 1; }
[[ -z "$(wipefs --noheadings --output TYPE "${device}")" ]] || { echo 'Disk has signatures; refusing to format.' >&2; exit 1; }
mkfs.ext4 -U "${uuid}" -L "${label:0:16}" "${device}"
'@
            [IO.File]::WriteAllText($formatterFile, $formatter.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
            $linuxFormatter = (Invoke-Wsl -Arguments @('wslpath', '-u', $formatterFile.Replace('\', '/'))) -join ''
            Invoke-Wsl -Arguments @('bash', $linuxFormatter.Trim(), $device, "$expectedBytes", $uuid, $Name) | Out-Host
            Write-Host "Created a $SizeGB GiB ext4 VHDX."
        } finally {
            if ($attached) {
                & wsl.exe --unmount $VhdPath | Out-Host
                if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not detach the newly created disk; detach it before retrying.' }
            }
            Remove-Item -LiteralPath $diskpartFile, $formatterFile -Force -ErrorAction SilentlyContinue
        }
    }

    function Mount-DataDisk {
        param($Configuration)
        $Name = [string]$Configuration.Name
        $Distro = [string]$Configuration.Distro
        $VhdPath = [string]$Configuration.VhdPath
        $previous = $null
        if (-not [string]::IsNullOrWhiteSpace($Configuration.FileSystemUuid)) { $previous = $Configuration }
        if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) { throw "VHDX does not exist: $VhdPath" }
        $info = Get-MountInfo
        if ($null -ne $info) {
            if ($null -eq $previous -or $info.uuid -cne $previous.FileSystemUuid) {
                throw "Mount point /mnt/wsl/$Name is already occupied by an unverified disk. Choose a different -Name."
            }
        } else {
            & wsl.exe --mount $VhdPath --vhd --name $Name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Could not mount the VHDX. It may already be attached under another name.' }
            $info = Get-MountInfo
        }
        if ($null -eq $info -or $info.fstype -cne 'ext4' -or [string]::IsNullOrWhiteSpace($info.uuid)) {
            throw 'Expected a whole-disk ext4 filesystem with a UUID.'
        }
        if ($null -ne $previous -and $info.uuid -cne $previous.FileSystemUuid) {
            throw 'Filesystem UUID does not match the saved configuration.'
        }
        return $info
    }

    function Invoke-AllAttachments {
        param([string]$StateRoot)
        $failed = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $StateRoot -Filter config.json -Recurse -File | Sort-Object FullName)) {
            try {
                $configuration = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if ($configuration.Name -cnotmatch '^[a-z][a-z0-9-]{0,30}$' -or
                    [string]::IsNullOrWhiteSpace($configuration.FileSystemUuid)) { throw 'Invalid saved disk configuration.' }
                Mount-DataDisk -Configuration $configuration | Out-Null
                Write-Host "Attached: /mnt/wsl/$($configuration.Name)"
            } catch {
                $failed += $file.FullName
                Write-Warning "Cannot attach disk configured in $($file.FullName): $($_.Exception.Message)"
            }
        }
        if ($failed.Count) { throw "Failed to attach $($failed.Count) disk(s). Other disks were still processed." }
    }

    function Invoke-AttachAll {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Automatic attachment requires administrator rights.'
        }
        $mutex = New-Object Threading.Mutex($false, 'Global\WslSecondDisk-Setup')
        $lockTaken = $false
        try {
            try { $lockTaken = $mutex.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
            if (-not $lockTaken) { throw 'Timed out waiting for another disk setup or attachment.' }
            Invoke-AllAttachments -StateRoot (Join-Path $env:LOCALAPPDATA 'WslSecondDisk')
        } finally {
            if ($lockTaken) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }

    if ($AttachAll) { Invoke-AttachAll; return }

    $interactiveInput = -not $NonInteractive -and -not $AttachOnly -and -not $Check
    if ($DockerRecovery -and $NoDockerRecovery) { throw 'Use only one of -DockerRecovery and -NoDockerRecovery.' }
    if ([string]::IsNullOrWhiteSpace($VhdPath)) {
        if ($NonInteractive -or $AttachOnly) { throw '-VhdPath is required in non-interactive mode.' }
        $VhdPath = (Read-Host 'VHDX file path (for example D:\WSLData\data.vhdx)').Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($VhdPath)) { throw 'A VHDX file path is required.' }
    }
    if ($interactiveInput) {
        if (-not $PSBoundParameters.ContainsKey('Name')) {
            $answer = Read-Host "Disk mount name [$Name]"
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $Name = $answer.Trim() }
        }
    }
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{0,30}$') { throw 'Invalid disk name.' }
    $VhdPath = [IO.Path]::GetFullPath($VhdPath)
    if ([IO.Path]::GetExtension($VhdPath) -ine '.vhdx') { throw 'The file must have the .vhdx extension.' }
    if ($VhdPath -match '[\r\n"]' -or $Distro -match '[\r\n"]') { throw 'Invalid path or distro name.' }
    $stateRoot = Join-Path $env:LOCALAPPDATA 'WslSecondDisk'
    $stateDir = Join-Path $stateRoot $Name
    $configPath = Join-Path $stateDir 'config.json'
    $taskName = 'WslSecondDisk'
    $previous = $null

    if ($Check) {
        if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) { throw "VHDX does not exist: $VhdPath" }
        Write-Host "VHDX: $VhdPath"
        Write-Host "Distro: $Distro; mount point: /mnt/wsl/$Name; task: $taskName"
        $info = Get-MountInfo
        if ($null -eq $info) { Write-Host 'Disk is not currently mounted.' }
        else { Write-Host "Mounted filesystem: $($info.fstype); UUID: $($info.uuid)" }
        exit 0
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as administrator, using the Windows account that owns the WSL distro.'
    }
    if (-not $AttachOnly) {
        $distros = @(Get-WslDistributions)
        if (-not $distros.Count) { throw 'No user WSL2 distributions are installed.' }
        if ($interactiveInput -and -not $PSBoundParameters.ContainsKey('Distro')) {
            Write-Host ('Installed WSL2 distributions: ' + ($distros -join ', '))
            if ($distros -cnotcontains $Distro) { $Distro = $distros[0] }
            $answer = Read-Host "WSL distribution [$Distro]"
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $Distro = $answer.Trim() }
        }
        if ($distros -cnotcontains $Distro) { throw "Choose an installed user WSL2 distribution: $Distro" }
        $profile = Get-LinuxProfile
        if ([string]::IsNullOrWhiteSpace($LinuxUser)) {
            $LinuxUser = $profile.User
            if ([string]::IsNullOrWhiteSpace($LinuxUser)) {
                $defaultUser = @(& wsl.exe -d $Distro --exec id -un)
                if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the default Linux user.' }
                $LinuxUser = ($defaultUser -join '').Trim()
            }
        }
        if ($interactiveInput) {
            if (-not $PSBoundParameters.ContainsKey('LinuxUser')) {
                $users = @(Invoke-Wsl -Arguments @('getent', 'passwd')) | ForEach-Object {
                    $fields = $_.Split(':')
                    if ($fields.Count -ge 7 -and [int]$fields[2] -ge 1000 -and [int]$fields[2] -lt 65534) { $fields[0] }
                }
                Write-Host ('Linux users: ' + ($users -join ', '))
                $answer = Read-Host "Linux user [$LinuxUser]"
                if (-not [string]::IsNullOrWhiteSpace($answer)) { $LinuxUser = $answer.Trim() }
            }
            if (-not $PSBoundParameters.ContainsKey('Bind')) {
                foreach ($mapping in $profile.Bindings) { Write-Host "Saved binding: $mapping" }
                Write-Host 'Enter directory bindings. Leave the source blank to finish or retain saved bindings.'
                while ($true) {
                    $source = Read-Host 'Source directory relative to the disk root'
                    if ([string]::IsNullOrWhiteSpace($source)) { break }
                    $target = Read-Host 'Absolute target directory in Linux'
                    if ([string]::IsNullOrWhiteSpace($target)) { throw 'Target directory is required.' }
                    $Bind += "$source=$target"
                }
            }
            if (-not $PSBoundParameters.ContainsKey('DockerRecovery') -and -not $PSBoundParameters.ContainsKey('NoDockerRecovery')) {
                $prompt = 'y/N'
                if ($profile.Docker) { $prompt = 'Y/n' }
                $answer = Read-Host "Enable automatic Docker Compose recovery? [$prompt]"
                if ([string]::IsNullOrWhiteSpace($answer)) { $DockerRecovery = $profile.Docker }
                elseif ($answer -match '^(?i)y(es)?$') { $DockerRecovery = $true }
                elseif ($answer -match '^(?i)n(o)?$') { $DockerRecovery = $false }
                else { throw 'Expected yes or no.' }
                $NoDockerRecovery = -not $DockerRecovery
            }
        }
        if ([string]::IsNullOrWhiteSpace($LinuxUser) -or $LinuxUser -eq 'root') {
            throw '-LinuxUser must identify an existing regular Linux user.'
        }
        Invoke-LinuxScript -Script (Get-LinuxInstaller) -Arguments (Get-LinuxArguments -PrerequisitesOnly) | Out-Host
    }
    $previous = $null
    if (Test-Path -LiteralPath $configPath) {
        $previous = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($previous.VhdPath -ine $VhdPath -or $previous.Distro -cne $Distro -or $previous.Name -cne $Name) {
            throw "Disk name '$Name' is already configured for another path or distro. Choose a different -Name."
        }
    }

    $mutex = New-Object Threading.Mutex($false, 'Global\WslSecondDisk-Setup')
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'Timed out waiting for another disk setup or attachment.' }

        $runtimePath = Join-Path $stateRoot 'attach.ps1'
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $existingTask) {
            if (@($existingTask.Actions)[0].Execute -ine 'powershell.exe' -or @($existingTask.Actions)[0].Arguments.IndexOf($runtimePath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw "An unrelated scheduled task already uses the name $taskName."
            }
        }
        $exists = Test-Path -LiteralPath $VhdPath -PathType Leaf
        if (-not $exists) {
            if ($AttachOnly) { throw "VHDX does not exist: $VhdPath" }
            $shouldCreate = $Create.IsPresent
            if (-not $shouldCreate -and -not $NonInteractive) {
                $shouldCreate = (Read-Host "File not found. Create a new ext4 VHDX? [y/N]") -match '^(?i)y(es)?$'
                if ($shouldCreate -and -not $PSBoundParameters.ContainsKey('SizeGB')) {
                    $sizeInput = Read-Host 'Maximum size in GiB [100]'
                    if (-not [string]::IsNullOrWhiteSpace($sizeInput)) {
                        $parsedSize = 0
                        if (-not [int]::TryParse($sizeInput, [ref]$parsedSize) -or $parsedSize -lt 1 -or $parsedSize -gt 65536) {
                            throw 'Size must be an integer between 1 and 65536 GiB.'
                        }
                        $SizeGB = $parsedSize
                    }
                }
            }
            if (-not $shouldCreate) { throw 'No disk was created. Use -Create to create a new VHDX.' }
            New-Ext4Vhd
        }

        $configuration = [pscustomobject]@{ Name=$Name; Distro=$Distro; VhdPath=$VhdPath; FileSystemUuid=$null }
        if ($null -ne $previous) { $configuration = $previous }
        # A newly configured disk has no saved UUID until its first successful attachment.
        $info = Mount-DataDisk -Configuration $configuration
        if ($AttachOnly) { Write-Host "Attached: /mnt/wsl/$Name"; exit 0 }

        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        if (Test-Path -LiteralPath $configPath) {
            Copy-Item -LiteralPath $configPath -Destination ($configPath + '.bak-' + [guid]::NewGuid())
        }
        [ordered]@{ Name=$Name; Distro=$Distro; VhdPath=$VhdPath; FileSystemUuid=$info.uuid } |
            ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        Write-AttachRuntime -Path $runtimePath
        if ($null -ne $existingTask) {
            Export-ScheduledTask -TaskName $taskName |
                Set-Content -LiteralPath (Join-Path $stateDir ('task-backup-' + [guid]::NewGuid() + '.xml')) -Encoding Unicode
        }
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runtimePath`" -AttachAll -NonInteractive"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal `
            -Settings $settings -Description 'Attach all registered ext4 data disks to WSL' -Force | Out-Null
        # Upgrade prior per-disk tasks only when their action belongs to our saved state.
        foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -Filter config.json -Recurse -File)) {
            $saved = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $legacyName = "WslSecondDisk-$($saved.Name)"
            $legacy = Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue
            $legacyRuntime = Join-Path $file.DirectoryName 'attach.ps1'
            if ($null -ne $legacy -and @($legacy.Actions)[0].Execute -ieq 'powershell.exe' -and
                @($legacy.Actions)[0].Arguments.IndexOf($legacyRuntime, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Export-ScheduledTask -TaskName $legacyName |
                    Set-Content -LiteralPath (Join-Path $file.DirectoryName ('legacy-task-' + [guid]::NewGuid() + '.xml')) -Encoding Unicode
                Unregister-ScheduledTask -TaskName $legacyName -Confirm:$false
            }
        }
        Write-Host "Installed task: $taskName"
        Write-Host "Disk ready at /mnt/wsl/$Name"
        Invoke-LinuxScript -Script (Get-LinuxInstaller) -Arguments (Get-LinuxArguments) | Out-Host
        Write-Host "Windows and $Distro integration installed."
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

$entryOptions = @{}
foreach ($key in @('VhdPath', 'Distro', 'Name', 'LinuxUser', 'Bind', 'DockerRecovery', 'NoDockerRecovery', 'SizeGB', 'Create', 'NonInteractive', 'Check', 'AttachOnly', 'AttachAll', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction')) {
    if ($PSBoundParameters.ContainsKey($key)) { $entryOptions[$key] = $PSBoundParameters[$key] }
}
Invoke-WslSecondDiskSetup @entryOptions
