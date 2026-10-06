#!/usr/bin/env bash
# Run only inside a disposable Linux container (see README).
set -Eeuo pipefail
[[ "${WSL_SECOND_DISK_TEST_CONTAINER:-}" == 1 ]] || {
    echo 'Run in the documented disposable container.' >&2
    exit 1
}
cleanup() {
    mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/owned && umount /mnt/wsl/docker-desktop-bind-mounts/Fixture/owned
    mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/unrelated && umount /mnt/wsl/docker-desktop-bind-mounts/Fixture/unrelated
    mountpoint -q /home/tester/workspace && umount /home/tester/workspace
    mountpoint -q '/home/tester/path with spaces' && umount '/home/tester/path with spaces'
    mountpoint -q /home/tester/database && umount /home/tester/database
    mountpoint -q /mnt/wsl/databases && umount /mnt/wsl/databases
    mountpoint -q /mnt/wsl/data && umount /mnt/wsl/data
    [[ -z "${second_device:-}" ]] || losetup -d "${second_device}"
    [[ -z "${loop_device:-}" ]] || losetup -d "${loop_device}"
    [[ -z "${blank_device:-}" ]] || losetup -d "${blank_device}"
    mountpoint -q /mnt/wsl && umount /mnt/wsl
}
trap cleanup EXIT
python3 /src/tests/extract_linux.py /tmp/backends
useradd -m tester
useradd -m tester2
mkdir -p /mnt/wsl
mount -t tmpfs tmpfs /mnt/wsl
mkdir -p /mnt/wsl/data/workspace /mnt/wsl/unrelated /mnt/wsl/docker-desktop-bind-mounts/Fixture/{owned,unrelated}
mount --bind /mnt/wsl/data/workspace /mnt/wsl/docker-desktop-bind-mounts/Fixture/owned
mount --bind /mnt/wsl/unrelated /mnt/wsl/docker-desktop-bind-mounts/Fixture/unrelated
truncate -s 64M /tmp/data.img
mkfs.ext4 -q /tmp/data.img
loop_device="$(losetup --find --show /tmp/data.img)"
mount "${loop_device}" /mnt/wsl/data
printf '# unrelated entry\ntmpfs /unrelated tmpfs defaults 0 0\n' >/etc/fstab
printf '[user]\ndefault=tester\n[boot]\nsystemd=false\n' >/etc/wsl.conf

# A default installation with no bindings must generate genuinely empty arrays.
bash /tmp/backends/install_wsl.sh --name data --user tester --non-interactive
# shellcheck source=/dev/null
source /usr/local/lib/wsl-second-disk/data/config.sh
[[ "${#BIND_SOURCES[@]}" == 0 && "${#BIND_TARGETS[@]}" == 0 ]]

# Installation, generated helpers, preservation of settings, and missing HOME.
bash /tmp/backends/install_wsl.sh --name data --user tester --bind workspace=/home/tester/workspace --non-interactive
sleep 1
shellcheck /usr/local/lib/wsl-second-disk/fix-mount /usr/local/sbin/wsl-disk-boot /usr/local/bin/wsl-disk
mountpoint -q /home/tester/workspace
[[ "$(stat -c %i /home/tester/workspace)" == "$(stat -c %i /mnt/wsl/data/workspace)" ]]
env -u HOME wsl-disk --name data --check
awk '$0 == "default=tester" { found=1 } END { exit !found }' /etc/wsl.conf
awk '$0 == "systemd=false" { found=1 } END { exit !found }' /etc/wsl.conf
awk '$2 == "/unrelated" { found=1 } END { exit !found }' /etc/fstab
cp /etc/fstab /tmp/fstab.first
cp /etc/wsl.conf /tmp/wsl.first
cp /usr/local/lib/wsl-second-disk/data/config.sh /tmp/config.first

# Re-running without mappings must preserve the previous bindings without duplicates.
bash /tmp/backends/install_wsl.sh --name data --user tester --non-interactive
cmp /etc/fstab /tmp/fstab.first
cmp /etc/wsl.conf /tmp/wsl.first
cmp /usr/local/lib/wsl-second-disk/data/config.sh /tmp/config.first

# Spaces in source and destination must be encoded correctly in fstab and recovered.
bash /tmp/backends/install_wsl.sh --name data --user tester --bind workspace=/home/tester/workspace \
    --bind 'source with spaces=/home/tester/path with spaces' --non-interactive
mountpoint -q '/home/tester/path with spaces'
env -u HOME wsl-disk --name data --check
bash /tmp/backends/install_wsl.sh --name data --user tester --non-interactive

# Check mode must leave files unchanged.
cp /etc/fstab /tmp/fstab.before-check
cp /etc/wsl.conf /tmp/wsl.before-check
bash /tmp/backends/install_wsl.sh --name data --user tester --check
cmp /etc/fstab /tmp/fstab.before-check
cmp /etc/wsl.conf /tmp/wsl.before-check

# Mock only Docker commands; real mounts and generated recovery code remain in use.
cp /usr/local/lib/wsl-second-disk/data/config.sh /tmp/config.before-docker
sed -i 's/^DOCKER_RECOVERY=.*/DOCKER_RECOVERY=1/' /usr/local/lib/wsl-second-disk/data/config.sh
mkdir -p /tmp/mock-bin
cat >/tmp/mock-bin/docker <<'DOCKER_MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
    info)
        [[ "${2:-}" != --format ]] || printf 'shared-fixture-daemon\n'
        exit 0
        ;;
    ps) printf 'test-container\n'; [[ "${MOCK_DOCKER_INDEPENDENT:-0}" != 1 ]] || printf 'test-independent\n' ;;
    inspect)
        state=running
        [[ "${MOCK_DOCKER_STOPPED:-0}" != 1 ]] || state=exited
        printf '%s\x1f' test-container /sample "${state}" unless-stopped '' sample web /tmp /tmp/sample.yml ''
        printf '/home/tester/workspace\x1e/data\x1d'
        database_source=/home/tester/database
        [[ "${MOCK_DOCKER_DIRECT:-0}" != 1 ]] || database_source=/mnt/wsl/databases/storage
        [[ "${MOCK_DOCKER_MULTI:-0}" != 1 ]] || printf '%s\x1e/database\x1d' "${database_source}"
        printf '\n'
        if [[ "${MOCK_DOCKER_INDEPENDENT:-0}" == 1 ]]; then
            printf '%s\x1f' test-independent /independent running unless-stopped '' sample worker /tmp /tmp/sample.yml ''
            printf '/home/tester/workspace\x1e/data\x1d\n'
        fi
        ;;
    exec)
        if [[ -f /tmp/mock-docker-fixed ]]; then
            target=/home/tester/workspace
            [[ "${@: -1}" != /database ]] || target=/home/tester/database
            stat -c %i "${target}"
        else printf 'wrong-inode\n'; fi
        ;;
    compose)
        [[ "${2:-}" != version ]] || exit 0
        printf '%s\n' "$*" >> /tmp/mock-docker-calls
        [[ "${MOCK_DOCKER_FAIL:-0}" != 1 ]] || exit 1
        touch /tmp/mock-docker-fixed
        ;;
    *) exit 1 ;;
esac
DOCKER_MOCK
chmod +x /tmp/mock-bin/docker
# Read-only diagnostics must keep both proxies; recovery must remove only the registered placeholder.
if PATH="/tmp/mock-bin:${PATH}" wsl-disk --name data --check; then
    echo 'Stale direct-disk proxy was not reported.' >&2
    exit 1
fi
mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/owned
mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/unrelated
PATH="/tmp/mock-bin:${PATH}" MOCK_DOCKER_STOPPED=1 wsl-disk --name data
if mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/owned; then
    echo 'Stale direct-disk proxy survived recovery.' >&2
    exit 1
fi
mountpoint -q /mnt/wsl/docker-desktop-bind-mounts/Fixture/unrelated
[[ ! -f /tmp/mock-docker-calls ]]
PATH="/tmp/mock-bin:${PATH}" wsl-disk --name data
[[ -f /tmp/mock-docker-fixed ]]
grep -q -- '--force-recreate web' /tmp/mock-docker-calls
rm /tmp/mock-docker-fixed
if PATH="/tmp/mock-bin:${PATH}" MOCK_DOCKER_FAIL=1 wsl-disk --name data; then
    echo 'Recovery ignored a failed Compose command.' >&2
    exit 1
fi
cp /tmp/config.before-docker /usr/local/lib/wsl-second-disk/data/config.sh

# Existing local data must not be hidden or modified.
mkdir -p /home/tester/occupied
printf 'keep this\n' >/home/tester/occupied/file
if bash /tmp/backends/install_wsl.sh --name data --user tester --bind other=/home/tester/occupied --non-interactive; then
    echo 'Installer accepted a nonempty target.' >&2
    exit 1
fi
cmp /etc/fstab /tmp/fstab.before-check
[[ "$(cat /home/tester/occupied/file)" == 'keep this' ]]

# Existing unrelated WSL boot commands must not be overwritten.
printf '[boot]\ncommand = /usr/local/bin/existing-command\n' >/etc/wsl.conf
cp /etc/wsl.conf /tmp/wsl.other-command
if bash /tmp/backends/install_wsl.sh --name data --user tester --non-interactive; then
    echo 'Installer overwrote another boot command.' >&2
    exit 1
fi
cmp /etc/wsl.conf /tmp/wsl.other-command
cp /tmp/wsl.before-check /etc/wsl.conf

# A different UUID at the same mount point must be rejected.
sed -i 's/^FILESYSTEM_UUID=.*/FILESYSTEM_UUID=wrong-uuid/' /usr/local/lib/wsl-second-disk/data/config.sh
if env -u HOME wsl-disk --name data --check; then
    echo 'Recovery accepted a different filesystem UUID.' >&2
    exit 1
fi
cp /tmp/config.before-docker /usr/local/lib/wsl-second-disk/data/config.sh

# Two real ext4 disks share one coordinator and must not recreate a shared service twice.
mkdir -p /mnt/wsl/databases
truncate -s 64M /tmp/databases.img
mkfs.ext4 -q /tmp/databases.img
second_device="$(losetup --find --show /tmp/databases.img)"
mount "${second_device}" /mnt/wsl/databases
# An empty second profile must not conflict with bindings on the first disk.
bash /tmp/backends/install_wsl.sh --name databases --user tester --non-interactive
bash /tmp/backends/install_wsl.sh --name data --user tester --non-interactive
PATH="/tmp/mock-bin:${PATH}" bash /tmp/backends/install_wsl.sh --name databases --user tester2 \
    --bind storage=/home/tester/database --docker-recovery --non-interactive
sed -i 's/^DOCKER_RECOVERY=.*/DOCKER_RECOVERY=1/' /usr/local/lib/wsl-second-disk/data/config.sh
[[ ! -e /usr/local/lib/wsl-second-disk/databases/boot ]]
[[ "$(grep -c '^command = /usr/local/sbin/wsl-disk-boot$' /etc/wsl.conf)" == 1 ]]
for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -f /run/wsl-second-disk-boot.pid ]] && break
    sleep 0.1
done
boot_pid="$(cat /run/wsl-second-disk-boot.pid)"
/usr/local/sbin/wsl-disk-boot
/usr/local/sbin/wsl-disk-boot
sleep 0.2
[[ "$(cat /run/wsl-second-disk-boot.pid)" == "${boot_pid}" ]]
rm -f /tmp/mock-docker-calls /tmp/mock-docker-fixed
PATH="/tmp/mock-bin:${PATH}" MOCK_DOCKER_MULTI=1 wsl-disk
[[ "$(wc -l </tmp/mock-docker-calls)" == 1 ]]

# Detached disk blocks a dependent service, while a separate service can recover.
umount /home/tester/database
umount /mnt/wsl/databases
rm -f /tmp/mock-docker-calls /tmp/mock-docker-fixed
if PATH="/tmp/mock-bin:${PATH}" MOCK_DOCKER_MULTI=1 MOCK_DOCKER_INDEPENDENT=1 wsl-disk --docker-only; then
    echo 'Missing disk was not reported.' >&2
    exit 1
fi
grep -q -- '--force-recreate worker' /tmp/mock-docker-calls
if grep -q -- '--force-recreate web' /tmp/mock-docker-calls; then
    echo 'Recreated a service with a missing disk.' >&2
    exit 1
fi

# Direct Docker mounts under an unavailable disk root are also blocked.
rm -f /tmp/mock-docker-calls /tmp/mock-docker-fixed
if PATH="/tmp/mock-bin:${PATH}" MOCK_DOCKER_MULTI=1 MOCK_DOCKER_DIRECT=1 MOCK_DOCKER_INDEPENDENT=1 wsl-disk --docker-only; then
    echo 'Direct mount under a missing disk was not reported.' >&2
    exit 1
fi
grep -q -- '--force-recreate worker' /tmp/mock-docker-calls
if grep -q -- '--force-recreate web' /tmp/mock-docker-calls; then exit 1; fi

# Cross-disk nested targets are refused even while the other disk is absent.
if PATH="/tmp/mock-bin:${PATH}" bash /tmp/backends/install_wsl.sh --name data --user tester \
    --bind workspace=/home/tester/workspace --bind 'source with spaces=/home/tester/path with spaces' \
    --bind nested=/home/tester/database/nested --non-interactive >/tmp/conflict.log 2>&1; then
    echo 'Overlapping bindings on different disks were accepted.' >&2
    exit 1
fi
grep -q 'Target overlaps another disk binding' /tmp/conflict.log
mount "${second_device}" /mnt/wsl/databases
PATH="/tmp/mock-bin:${PATH}" wsl-disk --system

printf 'database data\n' >/mnt/wsl/databases/storage/important-file
printf 'workspace data\n' >/mnt/wsl/data/workspace/important-file

# Busy bindings retain their configuration; removal preserves disk data and other settings.
(cd /home/tester/database && sleep 120) &
busy_pid=$!
if bash /tmp/backends/uninstall_wsl.sh --name databases --non-interactive; then
    kill "${busy_pid}"
    echo 'Busy binding was removed.' >&2
    exit 1
fi
[[ -f /usr/local/lib/wsl-second-disk/databases/config.sh ]]
kill "${busy_pid}"
wait "${busy_pid}" || true
bash /tmp/backends/uninstall_wsl.sh --name databases --check
bash /tmp/backends/uninstall_wsl.sh --name databases --non-interactive
[[ "$(cat /mnt/wsl/databases/storage/important-file)" == "database data" ]]
[[ -f /usr/local/lib/wsl-second-disk/data/config.sh && -x /usr/local/sbin/wsl-disk-boot ]]
if grep -q 'SECOND DISK databases' /etc/fstab; then exit 1; fi
# Preserve a nonempty placeholder beneath the mounted disk without touching ext4 data.
awk '
    /^[[:space:]]*\$script = @\047$/ { copying=1; next }
    copying && $0 == "\047@" { exit }
    copying { print }
' /src/uninstall_win.ps1 >/tmp/preserve-underlying.sh
[[ -s /tmp/preserve-underlying.sh ]]
shellcheck /tmp/preserve-underlying.sh
mkdir -p /tmp/underlying-view
mount --bind /mnt/wsl /tmp/underlying-view
mkdir -p /tmp/underlying-view/data/old-placeholder
printf 'preserve old placeholder data\n' >/tmp/underlying-view/data/old-placeholder/proof.txt
umount /tmp/underlying-view
bash /tmp/preserve-underlying.sh data "$(findmnt -n -o UUID --mountpoint /mnt/wsl/data)"
[[ "$(cat /var/backups/wsl-second-disk-placeholder.*/old-placeholder/proof.txt)" == 'preserve old placeholder data' ]]
[[ "$(cat /mnt/wsl/data/workspace/important-file)" == 'workspace data' ]]
bash /tmp/backends/uninstall_wsl.sh --name data --non-interactive
[[ "$(cat /mnt/wsl/data/workspace/important-file)" == "workspace data" ]]
[[ ! -e /usr/local/bin/wsl-disk && ! -e /usr/local/sbin/wsl-disk-boot ]]
[[ ! -e /usr/local/lib/wsl-second-disk && ! -e /var/log/wsl-second-disk ]]
[[ ! -e /run/wsl-second-disk-boot.pid && ! -e /run/wsl-second-disk-boot.lock && ! -e /run/wsl-second-disk-recovery.lock ]]
if grep -q 'wsl-disk-boot' /etc/wsl.conf; then exit 1; fi
awk '$0 == "default=tester" { found=1 } END { exit !found }' /etc/wsl.conf
awk '$0 == "systemd=false" { found=1 } END { exit !found }' /etc/wsl.conf
awk '$2 == "/unrelated" { found=1 } END { exit !found }' /etc/fstab

# Exercise the exact Linux formatter embedded in the Windows installer.
awk '
    /^[[:space:]]*\$formatter = @\047$/ { copying=1; next }
    copying && $0 == "\047@" { exit }
    copying { print }
' /src/install_win.ps1 >/tmp/formatter.sh
[[ -s /tmp/formatter.sh ]]
bash -n /tmp/formatter.sh
truncate -s 64M /tmp/blank.img
blank_device="$(losetup --find --show /tmp/blank.img)"
new_uuid="$(cat /proc/sys/kernel/random/uuid)"
bash /tmp/formatter.sh "${blank_device}" 67108864 "${new_uuid}" test-data
[[ "$(blkid -s UUID -o value "${blank_device}")" == "${new_uuid}" ]]
if bash /tmp/formatter.sh "${blank_device}" 67108864 "${new_uuid}" test-data; then
    echo 'Formatter accepted an existing filesystem.' >&2
    exit 1
fi
[[ "$(blkid -s UUID -o value "${blank_device}")" == "${new_uuid}" ]]
if bash /tmp/formatter.sh "${blank_device}" 100 "${new_uuid}" test-data; then
    echo 'Formatter accepted an incorrect device size.' >&2
    exit 1
fi
printf 'Integration checks passed.\n'
