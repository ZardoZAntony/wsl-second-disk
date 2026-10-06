# WSL second disk

[English](#wsl-second-disk) · [Русский](#русская-версия)

Create and attach ext4 VHDX data disks to WSL2 with two PowerShell scripts.
`install_win.ps1` handles Windows and Linux setup; `uninstall_win.ps1` removes it.
Both support interactive and command-line use. No repository clone or separate WSL script is needed.

## Quick start

You need **Windows 11, WSL2 with an installed Linux distribution, and PowerShell 5.1+**.
Run PowerShell **as administrator under the Windows account that owns WSL**:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1 | iex
```

Choose a VHDX path, disk name, distribution and regular Linux user. If the file is missing,
the installer offers to create a dynamic ext4 disk, **100 GiB by default**.
Your disk is available at `/mnt/wsl/<name>`; the default name is `data`.

**Existing VHDX files are never formatted.** They must already contain whole-disk ext4,
without a partition table. Standard Ubuntu tools are sufficient; the Hyper-V module is not required.

## Directory bindings

Optionally expose a directory on the disk at a convenient Linux path:

| Installer input | Example |
| --- | --- |
| Source, relative to the disk | `workspace` |
| Destination, absolute Linux path | `/home/user/workspace` |
| Result | `/mnt/wsl/data/workspace` is also available at `/home/user/workspace` |

Leave the source blank to finish or skip bindings. Existing data is not migrated;
destinations must be empty and cannot overlap other bindings. Use Linux paths, not PowerShell's `$HOME`.

<details>
<summary><strong>Command-line installation and parameters</strong></summary>

Download `install_win.ps1`, then run it in administrator PowerShell:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Name data -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
```

| Parameter | Purpose |
| --- | --- |
| `-VhdPath` | Full VHDX path |
| `-Name` | Unique disk name; default `data` |
| `-Distro` | WSL2 distribution; default `Ubuntu` for CLI |
| `-LinuxUser` | Existing regular Linux user; detected when omitted |
| `-Bind` | Array of `SOURCE=DESTINATION` mappings |
| `-Create`, `-SizeGB` | Create a missing disk; maximum size in GiB, default `100` |
| `-DockerRecovery`, `-NoDockerRecovery` | Enable or disable Compose recovery |
| `-NonInteractive` | Disable prompts |
| `-Check` | Inspect the VHDX and current mount without installation |

Omit `-Create` to require an existing disk. Repeat installation with the same profile to
retain saved bindings and Docker preferences; `-Bind` replaces the list, so unmount removed bindings first.

To pass parameters without downloading a file:

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing `
  https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1).Content)) `
  -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user -Create -NonInteractive
```

</details>

## Multiple disks and automatic recovery

Run the installer for each disk with a **different name and VHDX path**. For example,
`projects` and `databases` appear at `/mnt/wsl/projects` and `/mnt/wsl/databases`.
Names use lowercase letters, digits and hyphens, start with a letter and are at most 31 characters.

- **One Windows task**, `WslSecondDisk`, attaches all registered disks sequentially at sign-in.
- **One coordinator per WSL distribution** restores bindings and requests attachment of missing disks.
- Optional Docker recovery waits for Docker Desktop and recreates affected running Compose services
  whose mounts point at stale directories. Intentionally stopped containers remain stopped.

The scripts **do not start Docker Desktop**. Enable its startup at sign-in or launch it manually.
For recovery, enable Docker's WSL integration and ensure the selected Linux user can access Docker and Compose files.

## Check or recover

Run inside WSL:

```bash
wsl-disk --check   # Inspect registered disks, bindings and container mounts
wsl-disk          # Restore bindings and affected Compose services
sudo cat /var/log/wsl-second-disk/recovery.log
```

Add `--name data` to check or recover one disk. If installation fails, resolve the reported
conflict and rerun with the same profile. An unrelated WSL boot command in `/etc/wsl.conf`
must be integrated manually before installation.

## Uninstall

Stop applications and containers using the disk. In administrator PowerShell:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/uninstall_win.ps1 | iex
```

Enter the disk name and confirm. **The VHDX and its data are preserved by default.**
With a downloaded `uninstall_win.ps1`:

```powershell
.\uninstall_win.ps1 -Name data -WhatIf                    # Preview removal
.\uninstall_win.ps1 -Name data -NonInteractive            # Disconnect; keep VHDX
.\uninstall_win.ps1 -Name data -DeleteVhd -NonInteractive  # Delete VHDX and all data
```

Only the selected disk's integration is removed. Shared tasks and helpers remain while other
disks need them; removing the last disk clears them. Busy bindings or a UUID mismatch stop removal.
Configuration backups remain in `%LOCALAPPDATA%\WslSecondDiskBackups` and `/var/backups/wsl-second-disk*`.

---

# Русская версия

Создание и подключение дисков ext4 VHDX к WSL2 двумя PowerShell-скриптами.
`install_win.ps1` настраивает Windows и Linux, `uninstall_win.ps1` удаляет настройки.
Есть диалоговый режим и параметры. Клонировать репозиторий или запускать отдельный WSL-скрипт не нужно.

## Быстрый старт

Нужны **Windows 11, WSL2 с установленным Linux-дистрибутивом и PowerShell 5.1+**.
Откройте PowerShell **от администратора под Windows-пользователем, которому принадлежит WSL**:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1 | iex
```

Выберите путь к VHDX, имя диска, дистрибутив и обычного Linux-пользователя. Если файла нет,
установщик предложит создать динамический диск ext4, **по умолчанию 100 GiB**.
Диск доступен в `/mnt/wsl/<имя>`; имя по умолчанию — `data`.

**Существующие VHDX не форматируются.** Они должны содержать ext4 на всём диске, без таблицы разделов.
Достаточно стандартных утилит Ubuntu; модуль Hyper-V не требуется.

## Привязки каталогов

При желании сделайте каталог на диске доступным по удобному Linux-пути:

| Ввод в установщике | Пример |
| --- | --- |
| Источник относительно диска | `workspace` |
| Назначение — абсолютный Linux-путь | `/home/user/workspace` |
| Результат | `/mnt/wsl/data/workspace` также доступен в `/home/user/workspace` |

Пустой источник завершает ввод или пропускает привязки. Данные автоматически не переносятся;
назначения должны быть пустыми и не пересекаться с другими привязками. Используйте Linux-пути, не `$HOME` из PowerShell.

<details>
<summary><strong>Установка с параметрами</strong></summary>

Скачайте `install_win.ps1` и запустите в PowerShell от администратора:

```powershell
.\install_win.ps1 -VhdPath "D:\WSLData\data.vhdx" -Name data -Distro Ubuntu `
  -LinuxUser user -Bind "workspace=/home/user/workspace" -Create -SizeGB 100 -NonInteractive
```

| Параметр | Назначение |
| --- | --- |
| `-VhdPath` | Полный путь к VHDX |
| `-Name` | Уникальное имя диска; по умолчанию `data` |
| `-Distro` | WSL2-дистрибутив; для CLI по умолчанию `Ubuntu` |
| `-LinuxUser` | Обычный Linux-пользователь; определяется автоматически |
| `-Bind` | Массив привязок `ИСТОЧНИК=НАЗНАЧЕНИЕ` |
| `-Create`, `-SizeGB` | Создать отсутствующий диск; максимальный размер в GiB, по умолчанию `100` |
| `-DockerRecovery`, `-NoDockerRecovery` | Включить или выключить восстановление Compose |
| `-NonInteractive` | Отключить вопросы |
| `-Check` | Проверить VHDX и текущее подключение без установки |

Без `-Create` требуется готовый диск. Повторная установка с тем же профилем сохраняет
привязки и настройку Docker; `-Bind` заменяет список, поэтому сначала отключите удаляемые привязки.

Для передачи параметров без скачивания файла:

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing `
  https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/install_win.ps1).Content)) `
  -VhdPath "D:\WSLData\data.vhdx" -Distro Ubuntu -LinuxUser user -Create -NonInteractive
```

</details>

## Несколько дисков и автовосстановление

Запускайте установщик для каждого диска с **отдельным именем и путём к VHDX**. Например,
`projects` и `databases` появятся в `/mnt/wsl/projects` и `/mnt/wsl/databases`.
Имя начинается со строчной латинской буквы, содержит строчные буквы, цифры и дефисы, не длиннее 31 символа.

- **Одна задача Windows `WslSecondDisk`** последовательно подключает все зарегистрированные диски при входе.
- **Один обработчик на WSL-дистрибутив** восстанавливает привязки и запрашивает подключение отсутствующих дисков.
- Необязательное восстановление Docker ждёт Docker Desktop и пересоздаёт затронутые работающие сервисы Compose,
  чьи подключения указывают на устаревшие каталоги. Намеренно остановленные контейнеры не запускаются.

Скрипты **не запускают Docker Desktop**. Включите его автозапуск при входе или запустите вручную.
Для восстановления включите WSL-интеграцию Docker и обеспечьте выбранному Linux-пользователю доступ к Docker и файлам Compose.

## Проверка и восстановление

Выполните внутри WSL:

```bash
wsl-disk --check   # Проверить диски, привязки и подключения контейнеров
wsl-disk          # Восстановить привязки и затронутые сервисы Compose
sudo cat /var/log/wsl-second-disk/recovery.log
```

Добавьте `--name data` для одного диска. При ошибке установки устраните указанный конфликт
и повторите запуск с тем же профилем. Стороннюю команду автозапуска в `/etc/wsl.conf`
нужно объединить вручную до установки.

## Удаление

Остановите приложения и контейнеры, использующие диск. В PowerShell от администратора:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/ZardoZAntony/wsl-second-disk/main/uninstall_win.ps1 | iex
```

Введите имя диска и подтвердите действие. **VHDX и данные по умолчанию сохраняются.**
Если `uninstall_win.ps1` скачан локально:

```powershell
.\uninstall_win.ps1 -Name data -WhatIf                    # Посмотреть действия
.\uninstall_win.ps1 -Name data -NonInteractive            # Отключить, сохранить VHDX
.\uninstall_win.ps1 -Name data -DeleteVhd -NonInteractive  # Удалить VHDX со всеми данными
```

Удаляются настройки выбранного диска. Общая задача и обработчики остаются, пока нужны другим
дискам; после удаления последнего убираются. Занятые привязки или несовпадение UUID останавливают удаление.
Резервные копии настроек остаются в `%LOCALAPPDATA%\WslSecondDiskBackups` и `/var/backups/wsl-second-disk*`.

---

Automated checks / Автоматические проверки: [GitHub Actions](.github/workflows/checks.yml), [tests](tests).

Apache License 2.0 — [LICENSE](LICENSE).
