# WSL second disk

[English](#wsl-second-disk) | [Русская версия](#русская-версия)

Create and manage separate ext4 VHDX data disks for WSL2 from Windows PowerShell.
Two standalone scripts handle the complete Windows and Linux setup:

- `install_win.ps1` creates or attaches a disk, configures directory bindings and installs automatic recovery.
- `uninstall_win.ps1` removes both integrations and detaches the disk, preserving the VHDX by default.

Both scripts support interactive setup, command-line parameters and execution from downloaded
text. No repository clone or separate Linux installer is required. The Linux backends are embedded
in the PS1 files; the installer generates the permanent recovery helpers locally.
The project is independent of any application or Docker Compose project.

## Requirements

- Windows 11 with a current WSL2 installation and an installed Linux distribution.
- Windows PowerShell 5.1 or later, run as administrator **under the Windows account that owns WSL**.
- Inside the selected distribution: Bash, util-linux (including `nsenter`), coreutils and awk.
  Creating a disk also requires `mkfs.ext4`, `wipefs` and `udevadm`; Ubuntu normally includes them.
- Docker Desktop and Docker Compose are optional. Enable WSL integration for the selected
  distribution before enabling Docker recovery.
- The Hyper-V PowerShell module is not required.

Check WSL with `wsl --version` and `wsl -l -v`. The installer lists installed user WSL2
distributions; WSL1 and internal `docker-desktop` distributions are excluded.

## Install with one command

Open administrator PowerShell and run:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1 | iex
```

The installer asks for:

1. The VHDX file path and disk mount name, defaulting to `data`.
2. An installed WSL2 distribution and an existing regular Linux user.
3. Optional directory bindings: source relative to the disk, absolute destination inside Linux.
4. Whether to enable automatic Docker Compose recovery, disabled by default.
5. If the VHDX is missing, whether to create it and its maximum size, defaulting to **100 GiB**.

For example, source `workspace` and target `/home/user/workspace` expose
`/mnt/wsl/data/workspace` at `/home/user/workspace`. Leave the source blank to finish.
With no bindings, the disk remains available directly at `/mnt/wsl/data`.
Existing local data is never migrated automatically; nonempty unmounted targets are refused.

A new VHDX is dynamic: its file grows as data is written, up to the requested maximum.
It is formatted as ext4 immediately. **Existing VHDX files are never formatted** and must
already contain a whole-disk ext4 filesystem; partitioned VHDX files are not supported.

The installer configures both Windows and Linux. All questions are asked in PowerShell;
there is no second installation step inside WSL and no Linux sudo prompt.
A pre-existing unrelated WSL boot command is preserved and causes setup to stop before
creating a new disk; integrate that command manually before retrying.

Alternatively, download `install_win.ps1` and run it locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_win.ps1
```

## Command-line setup

Create a missing disk, or attach it if it already exists:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Name data -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
```

Omit `-Create` to require an existing VHDX. Repeat mappings in the `-Bind` array:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user `
  -Bind "workspace=/home/user/workspace","uploads=/home/user/project/upload" `
  -DockerRecovery -NonInteractive
```

Downloaded scripts also accept parameters through a script block:

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing `
  https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1).Content)) `
  -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user -Create -NonInteractive
```

Use Linux paths for binding targets; PowerShell's `$HOME` is a Windows path.
The default Linux user is detected automatically. Supply `-LinuxUser` when the distribution's
default user is `root`. On a repeated installation, saved bindings and Docker preferences are
retained when omitted. Providing `-Bind` replaces the binding list; unmount any removed bindings first.

### Multiple disks

Run the installer once per disk with a unique name:

```powershell
.\install_win.ps1 -Name projects -VhdPath "D:\WSLData\projects.vhdx" -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
.\install_win.ps1 -Name databases -VhdPath "E:\WSLData\databases.vhdx" -Distro Ubuntu `
  -LinuxUser user -Bind "storage=/home/user/database" -Create -SizeGB 200 -DockerRecovery -NonInteractive
```

The disks appear at `/mnt/wsl/projects` and `/mnt/wsl/databases`. Each disk has its own
configuration and fstab block. Binding targets must be distinct and cannot be nested,
including targets belonging to another registered disk. Names start with a lowercase letter
and contain only lowercase letters, digits and hyphens, with a maximum length of 31 characters.

There is **one Windows task**, `WslSecondDisk`, for every registered disk and **one background
coordinator per WSL distribution**. Adding a disk updates this shared installation.
Disks may use different distributions; names remain unique across the Windows account.

### Installer parameters

| Parameter | Purpose |
| --- | --- |
| `-VhdPath` | Full VHDX path; prompted when omitted |
| `-Name` | Unique mount name, default `data` |
| `-Distro` | Installed user WSL2 distribution; interactive selection, default `Ubuntu` for CLI |
| `-LinuxUser` | Existing regular Linux user; detected from the saved profile or distribution default |
| `-Bind` | Array of `SOURCE=TARGET` directory bindings |
| `-DockerRecovery` | Enable automatic recovery of affected Compose containers |
| `-NoDockerRecovery` | Disable previously enabled recovery |
| `-Create` | Create a missing VHDX without asking for confirmation |
| `-SizeGB` | New disk maximum size in GiB, default `100` |
| `-NonInteractive` | Disable prompts |
| `-Check` | Inspect the VHDX and current mount without installing anything |

## How automatic recovery works

1. At Windows logon, the scheduled task reads all registered profiles and attaches the VHDX
   files sequentially. A failing disk does not prevent the remaining disks from being processed.
   Setup, attachment and removal share a Windows mutex and wait up to two minutes for their turn.
2. The WSL boot hook starts one coordinator. It checks filesystem UUIDs, restores available
   directory bindings and triggers the Windows task when a disk is missing. It retries for up
   to 30 minutes. Containers dependent on an unavailable disk are skipped.
3. If Docker recovery is enabled, the coordinator waits up to 12 hours for Docker Desktop,
   then allows another 60 seconds for startup before checking container mounts.
4. Only affected Compose services with stale mounts are recreated. Intentionally stopped
   containers are preserved. Services shared by several disks are recreated once, and a shared
   Docker engine is processed once even when several Linux users use it.

The installer **does not start Docker Desktop**. Enable its launch at Windows sign-in or start
it manually; the recovery worker waits for it. Container restart policies alone cannot refresh
an existing bind mount that still points at a directory created before disk attachment.

Docker recovery uses the Compose labels stored on containers to locate their project and files.
Those files must remain available to the configured Linux user, and that user must have working
Docker access. Containers outside Compose are reported but not automatically recreated.
Only stale Docker Desktop mount proxies associated with registered bindings or direct disk paths are removed.
Recovery and Linux removal share a lock.

Windows starts Linux setup as root in the distribution's main mount namespace. This ensures
bindings are visible to normal WSL sessions even when the Windows terminal is elevated.
Unrelated boot settings, fstab entries, disks and scheduled tasks are preserved.

### Generated files

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\WslSecondDisk\<name>\config.json` | Windows disk profile and ext4 UUID |
| `%LOCALAPPDATA%\WslSecondDisk\attach.ps1` | Shared standalone attachment dispatcher |
| `/usr/local/lib/wsl-second-disk/<name>/config.sh` | Linux disk profile and bindings |
| `/usr/local/lib/wsl-second-disk/fix-mount` | Shared recovery helper |
| `/usr/local/sbin/wsl-disk-boot` | Shared background coordinator |
| `/usr/local/bin/wsl-disk` | Manual recovery command |
| `/var/log/wsl-second-disk/recovery.log` | Recovery log |

`/etc/fstab` entries are marked per disk. `/etc/wsl.conf` contains the shared boot command.
The temporary Linux setup script is deleted after each invocation. The installed attachment
dispatcher works independently of the downloaded installer, including installation through `iex`.

## Check and recover manually

From PowerShell:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -Name data -Check
```

Inside your normal WSL terminal:

```bash
wsl-disk --check               # Inspect all configured disks and container mounts
wsl-disk                      # Restore bindings and affected Compose services
wsl-disk --name data --check   # Inspect one disk
wsl-disk --name data           # Recover one disk
sudo cat /var/log/wsl-second-disk/recovery.log
```

If Windows attachment fails, check that the VHDX path is available and that the task runs as
its owning Windows account. If a target contains local data or another mount, resolve that
conflict before installing. If Windows setup succeeds but Linux configuration fails, the disk
remains registered; correct the reported problem and rerun the installer with the same profile.

## Uninstall

Stop applications and containers using the selected disk, then run administrator PowerShell:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/uninstall_win.ps1 | iex
```

The script asks for the disk name and confirms removal. It removes Linux bindings, profile and
recovery settings, detaches the selected VHDX, and removes its Windows profile. **The VHDX and
its data are preserved by default.** No separate Linux command is required.

Local or parameterized invocation:

```powershell
.\uninstall_win.ps1 -Name data -Check
.\uninstall_win.ps1 -Name data -WhatIf
.\uninstall_win.ps1 -Name data -NonInteractive
.\uninstall_win.ps1 -Name data -DeleteVhd -NonInteractive
```

`-DeleteVhd` explicitly deletes the VHDX and all its data. Busy bindings, an unexpected
filesystem UUID or an unrelated task named `WslSecondDisk` stop removal. Bindings are unmounted
normally; live application data is not lazily detached. If detachment fails after Linux removal,
Windows settings and the VHDX remain available for a retry.

Removing one of several disks retains the shared task and helpers. Removing the last disk
removes the task, active Windows registry, shared Linux helpers, boot command, log and locks.
Empty former binding targets are preserved.

Configuration backups are retained under `%LOCALAPPDATA%\WslSecondDiskBackups` and
`/var/backups/wsl-second-disk*`. Files created underneath a mounted VHDX's mount point are
preserved under `/var/backups/wsl-second-disk-placeholder.*` before detachment.
Backups are separate from active configuration and can be deleted after verification.

## Checks

Linux tests extract the embedded backends and install into a **disposable Docker container**
with temporary ext4 images. They do not install into the host or attach its VHDX files.
Python 3 is required only for extracting the backends in tests.

```bash
docker build -f tests/Dockerfile -t wsl-second-disk-test .
docker run --rm wsl-second-disk-test bash -c \
  'python3 /src/tests/extract_linux.py /tmp/backends && bash -n /tmp/backends/*.sh /src/tests/integration.sh && shellcheck /tmp/backends/*.sh /src/tests/integration.sh'
docker run --rm --privileged wsl-second-disk-test
```

The integration tests use real loop-device mounts to check installation, repeated runs, UUID
validation, occupied and busy targets, preservation of unrelated settings, multiple disks and
users, and complete removal with data preserved. Docker fixtures verify selective recovery,
missing-disk handling, shared-service deduplication and propagation of Compose errors.
The exact embedded formatter and placeholder-preservation helper are also exercised.

Windows PowerShell fixtures check parameters, interactive choices, downloaded-text execution,
generation and execution of the standalone dispatcher, multi-disk attachment and coordinated
Linux/Windows removal. Native disk and task commands are replaced by fixtures in these tests.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows.ps1
```

A real end-to-end check uses a disposable WSL2 distribution and a 1 GiB VHDX to verify setup,
container mount recovery, file write/read, scheduled-task reattachment after a WSL restart,
and removal. This does not replace checking an actual Windows reboot and sign-in.

## Documentation and license

- [Microsoft: WSL commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- [Microsoft: mounting VHDX files](https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk)
- [Microsoft: WSL boot and fstab configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)

Apache License 2.0. See [LICENSE](LICENSE).

---

# Русская версия

Установка и управление отдельными дисками ext4 VHDX для WSL2 из Windows PowerShell.
Достаточно двух файлов, выполняющих всю настройку Windows и Linux:

- `install_win.ps1` создаёт или подключает диск, настраивает привязки каталогов и автовосстановление.
- `uninstall_win.ps1` удаляет настройки обеих систем и отключает диск, сохраняя VHDX по умолчанию.

Оба скрипта поддерживают диалоговый режим, параметры и запуск загруженного текста.
Клонировать репозиторий и запускать отдельный Linux-установщик не требуется.
Bash-код встроен в PS1; постоянные обработчики восстановления создаются при установке.
Проект не зависит от конкретного приложения или проекта Docker Compose.

## Требования

- Windows 11, актуальный WSL2 и установленный Linux-дистрибутив.
- Windows PowerShell 5.1 или новее, запущенный от администратора **под Windows-пользователем,
  которому принадлежит WSL**.
- В выбранном дистрибутиве: Bash, util-linux с `nsenter`, coreutils и awk.
  Для создания диска также нужны `mkfs.ext4`, `wipefs` и `udevadm`; обычно они есть в Ubuntu.
- Docker Desktop и Compose необязательны. Для восстановления контейнеров заранее включите
  интеграцию Docker Desktop с выбранным дистрибутивом WSL.
- Модуль PowerShell Hyper-V не требуется.

Проверить WSL можно командами `wsl --version` и `wsl -l -v`. Установщик предлагает
установленные пользовательские дистрибутивы WSL2; WSL1 и внутренние `docker-desktop` исключены.

## Установка одной командой

Откройте PowerShell от администратора:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1 | iex
```

Установщик запросит:

1. Путь к VHDX и имя подключения, по умолчанию `data`.
2. Установленный WSL2-дистрибутив и существующего обычного Linux-пользователя.
3. Необязательные привязки: исходный каталог относительно диска и абсолютный путь назначения в Linux.
4. Нужно ли восстанавливать контейнеры Docker Compose; по умолчанию выключено.
5. Если VHDX отсутствует — создавать ли его и какого максимального размера; по умолчанию **100 GiB**.

Например, источник `workspace` и назначение `/home/user/workspace` предоставляют
`/mnt/wsl/data/workspace` по пути `/home/user/workspace`. Пустой источник завершает ввод.
Без привязок диск доступен напрямую в `/mnt/wsl/data`.
Существующие локальные данные автоматически не переносятся; непустой неподключённый каталог
назначения установщик не принимает.

Новый VHDX динамический: файл увеличивается по мере записи данных до заданного максимума.
Сразу создаётся ext4. **Существующие VHDX никогда не форматируются**: они должны содержать
ext4 на всём диске. Образы с таблицей разделов пока не поддерживаются.

Все вопросы задаются в PowerShell, затем настраиваются обе системы. Отдельный запуск в WSL
и ввод пароля sudo не нужны. Сторонняя команда автозапуска WSL сохраняется: при её наличии
установка остановится до создания нового диска. Сначала объедините команды вручную.

Можно скачать файл и запустить его локально:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_win.ps1
```

## Параметры командной строки

Создать отсутствующий диск или подключить существующий:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Name data -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
```

Без `-Create` требуется готовый VHDX. Несколько привязок задаются массивом:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user `
  -Bind "workspace=/home/user/workspace","uploads=/home/user/project/upload" `
  -DockerRecovery -NonInteractive
```

Для запуска загруженного скрипта с параметрами:

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing `
  https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1).Content)) `
  -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user -Create -NonInteractive
```

Назначения привязок — Linux-пути; `$HOME` в PowerShell указывает на Windows-каталог.
Linux-пользователь определяется автоматически. Если пользователь по умолчанию — `root`,
задайте `-LinuxUser`. Повторная установка сохраняет привязки и настройку Docker, если они
не переданы заново. `-Bind` заменяет список; предварительно отключите удаляемые привязки.

### Несколько дисков

Для каждого диска запустите установщик с уникальным именем:

```powershell
.\install_win.ps1 -Name projects -VhdPath "D:\WSLData\projects.vhdx" -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
.\install_win.ps1 -Name databases -VhdPath "E:\WSLData\databases.vhdx" -Distro Ubuntu `
  -LinuxUser user -Bind "storage=/home/user/database" -Create -SizeGB 200 -DockerRecovery -NonInteractive
```

Диски появятся в `/mnt/wsl/projects` и `/mnt/wsl/databases`. Настройки и блоки fstab отдельные.
Назначения привязок должны различаться и не пересекаться, в том числе с привязками других дисков.
Имя начинается со строчной латинской буквы, содержит строчные буквы, цифры и дефисы,
максимальная длина — 31 символ.

Для всех дисков создаётся **одна задача Windows `WslSecondDisk`**, а для каждого дистрибутива —
**один фоновый обработчик WSL**. Добавление диска обновляет общую установку.
Можно использовать разные дистрибутивы; имена дисков уникальны в пределах Windows-пользователя.

### Параметры установщика

| Параметр | Назначение |
| --- | --- |
| `-VhdPath` | Полный путь к VHDX; запрашивается, если не указан |
| `-Name` | Уникальное имя подключения, по умолчанию `data` |
| `-Distro` | Пользовательский WSL2-дистрибутив; выбор в диалоге, для CLI по умолчанию `Ubuntu` |
| `-LinuxUser` | Обычный Linux-пользователь; определяется из сохранённого профиля или настроек дистрибутива |
| `-Bind` | Массив привязок `ИСТОЧНИК=НАЗНАЧЕНИЕ` |
| `-DockerRecovery` | Включить восстановление затронутых контейнеров Compose |
| `-NoDockerRecovery` | Выключить ранее включённое восстановление |
| `-Create` | Создать отсутствующий VHDX без запроса подтверждения |
| `-SizeGB` | Максимальный размер нового диска в GiB, по умолчанию `100` |
| `-NonInteractive` | Отключить вопросы |
| `-Check` | Проверить файл VHDX и текущее подключение без установки |

## Как работает автовосстановление

1. При входе в Windows задача последовательно подключает VHDX из всех зарегистрированных
   профилей. Ошибка одного диска не мешает остальным. Установка, подключение и удаление
   используют общую Windows-блокировку с ожиданием до двух минут.
2. При старте WSL запускается один обработчик. Он сверяет UUID, восстанавливает доступные
   привязки и вызывает задачу Windows, если диск отсутствует. Ожидание — до 30 минут;
   контейнеры, которым нужен недоступный диск, пропускаются.
3. При включённом восстановлении Docker обработчик ждёт Docker Desktop до 12 часов,
   затем ещё 60 секунд даёт ему завершить запуск.
4. Пересоздаются только затронутые сервисы Compose с устаревшими подключениями.
   Намеренно остановленные контейнеры сохраняются. Общий для нескольких дисков сервис
   пересоздаётся один раз; общий Docker-движок проверяется один раз для нескольких пользователей.

Установщик **не запускает Docker Desktop**. Включите его запуск при входе в Windows либо
запустите вручную — обработчик дождётся доступности. Политика перезапуска контейнера сама
не обновляет bind mount, который остался привязан к каталогу, созданному до подключения диска.

Проекты и файлы Compose определяются по меткам контейнеров. Эти файлы должны быть доступны
выбранному Linux-пользователю, у которого должен работать Docker. Контейнеры вне Compose
попадают в диагностику и автоматически не пересоздаются. Удаляются только устаревшие
прокси подключений Docker Desktop, относящиеся к зарегистрированным привязкам или прямым путям на дисках.
Восстановление и удаление Linux-настроек используют общую блокировку.

Linux-настройка запускается от root в основном пространстве монтирования дистрибутива.
Привязки видны обычным WSL-сессиям даже при запуске PowerShell от администратора.
Сторонние настройки автозапуска, записи fstab, диски и задачи планировщика сохраняются.

### Создаваемые файлы

| Расположение | Содержимое |
| --- | --- |
| `%LOCALAPPDATA%\WslSecondDisk\<name>\config.json` | Windows-профиль диска и UUID ext4 |
| `%LOCALAPPDATA%\WslSecondDisk\attach.ps1` | Общий самостоятельный обработчик подключения |
| `/usr/local/lib/wsl-second-disk/<name>/config.sh` | Linux-профиль и привязки |
| `/usr/local/lib/wsl-second-disk/fix-mount` | Общий обработчик восстановления |
| `/usr/local/sbin/wsl-disk-boot` | Фоновый обработчик |
| `/usr/local/bin/wsl-disk` | Команда ручного восстановления |
| `/var/log/wsl-second-disk/recovery.log` | Журнал восстановления |

Записи `/etc/fstab` помечены именем диска; в `/etc/wsl.conf` добавляется общая команда запуска.
Временный сценарий Linux удаляется после каждого вызова. Обработчик подключения работает
самостоятельно, независимо от загруженного установщика, в том числе после установки через `iex`.

## Проверка и ручное восстановление

В PowerShell:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -Name data -Check
```

В обычном WSL-терминале:

```bash
wsl-disk --check               # Проверить все диски и подключения контейнеров
wsl-disk                      # Восстановить привязки и затронутые сервисы Compose
wsl-disk --name data --check   # Проверить один диск
wsl-disk --name data           # Восстановить один диск
sudo cat /var/log/wsl-second-disk/recovery.log
```

При ошибке подключения проверьте доступность VHDX и Windows-пользователя задачи.
Если назначение содержит локальные данные или другое подключение, сначала устраните конфликт.
Если Windows-настройка завершилась, а Linux-настройка дала ошибку, диск остаётся зарегистрирован:
исправьте указанную проблему и повторите установку с тем же профилем.

## Удаление

Остановите приложения и контейнеры, использующие выбранный диск, затем в PowerShell
от администратора выполните:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/uninstall_win.ps1 | iex
```

Скрипт запросит имя и подтверждение. Он удалит Linux-привязки, профиль и настройки
восстановления, отключит выбранный VHDX и удалит Windows-профиль. **Сам VHDX с данными
по умолчанию сохраняется.** Отдельная команда в Linux не нужна.

Локальный запуск или запуск с параметрами:

```powershell
.\uninstall_win.ps1 -Name data -Check
.\uninstall_win.ps1 -Name data -WhatIf
.\uninstall_win.ps1 -Name data -NonInteractive
.\uninstall_win.ps1 -Name data -DeleteVhd -NonInteractive
```

`-DeleteVhd` явно разрешает удалить VHDX со всеми данными. Занятые привязки, несовпадение
UUID или сторонняя задача с именем `WslSecondDisk` останавливают удаление.
Используется обычное размонтирование, без ленивого отключения работающих приложений.
Если после удаления Linux-настроек отключение диска не удалось, Windows-настройки
и VHDX сохраняются для повторного запуска.

Удаление одного из нескольких дисков сохраняет общую задачу и обработчики. После удаления
последнего убираются задача, активный Windows-реестр установки, Linux-обработчики,
команда автозапуска, журнал и блокировки. Пустые бывшие каталоги назначения сохраняются.

Резервные копии настроек остаются в `%LOCALAPPDATA%\WslSecondDiskBackups` и
`/var/backups/wsl-second-disk*`. Данные, созданные под точкой подключения VHDX,
сохраняются в `/var/backups/wsl-second-disk-placeholder.*` перед отключением.
Копии отделены от активных настроек; после проверки их можно удалить.

## Проверки

Тесты извлекают встроенный Bash-код и устанавливают его в **одноразовом Docker-контейнере**
с временными образами ext4. Основная система и её VHDX не изменяются.
Python 3 нужен только для извлечения сценариев в тестах.

```bash
docker build -f tests/Dockerfile -t wsl-second-disk-test .
docker run --rm wsl-second-disk-test bash -c \
  'python3 /src/tests/extract_linux.py /tmp/backends && bash -n /tmp/backends/*.sh /src/tests/integration.sh && shellcheck /tmp/backends/*.sh /src/tests/integration.sh'
docker run --rm --privileged wsl-second-disk-test
```

Реальные loop-подключения проверяют установку, повторные запуски, UUID, непустые и занятые
назначения, сохранение сторонних настроек, несколько дисков и пользователей, полное удаление
с сохранением данных. Подмена Docker-команд проверяет выборочное восстановление, отсутствие
одного диска, однократное восстановление общего сервиса и обработку ошибок Compose.
Также выполняются встроенные форматировщик и обработчик сохранения скрытых каталогов.

Проверки Windows PowerShell охватывают параметры, диалоговый режим, выполнение загруженного
текста, создание и запуск самостоятельного обработчика, несколько дисков и согласованное
удаление Linux/Windows-настроек. Системные команды дисков и планировщика подменяются.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows.ps1
```

Реальная сквозная проверка использует временный WSL2-дистрибутив и VHDX размером 1 GiB:
установка, восстановление контейнера, запись и чтение файла, повторное подключение через
планировщик после перезапуска WSL и удаление. Она не заменяет проверку реальной перезагрузки
Windows и входа пользователя.

## Документация и лицензия

- [Microsoft: команды WSL](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- [Microsoft: подключение VHDX](https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk)
- [Microsoft: автозапуск WSL и fstab](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)

Apache License 2.0. См. [LICENSE](LICENSE).
