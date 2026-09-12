# Fix-ClaudeOnLTSC

Подготовка Windows 10/11 LTSC к установке Claude.

## Зачем

Установка Claude не ограничена лицензией или уровнем обновлений Windows —
это техническая планка: **Windows 10 1809 (сборка 17763) или новее, x64/ARM64, от 4 ГБ ОЗУ**.

Поднять номер сборки LTSC через PowerShell, CMD или Windows Update **невозможно**:
LTSC по замыслу получает только исправления безопасности внутри своей сборки и
никогда не получает feature updates. Обновления поднимают ревизию (17763.**7xxx**),
но не саму сборку. Сменить 17763 → 19044 можно только in-place upgrade с ISO.

| Сборка | Версия | Claude | PowerShell 7 |
|--------|--------|--------|--------------|
| 10240  | LTSB 2015 | нет | нет |
| 14393  | LTSB 2016 | нет | да |
| 17763  | LTSC 2019 | да (CLI) | да |
| 19044  | LTSC 2021 | да | да |
| 26100  | Win 11 LTSC 2024 | да | да |

Проверить свою сборку:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object ProductName, DisplayVersion, CurrentBuildNumber, UBR
```

## Что делает скрипт

1. **Диагностика** — сборка, редакция, разрядность, ОЗУ, вердикт по пригодности.
2. **Корневые сертификаты** через `certutil -generateSSTFromWU`. На давно не
   обновлявшихся образах устаревший список CA ломает и проверку подписи
   установщиков, и TLS-соединение с claude.ai.
3. **TLS 1.2** для SChannel и .NET Framework.
4. **Накопительные обновления** через PSWindowsUpdate, с включением `wuauserv`
   (на LTSC часто выключена политикой) и запасным вариантом через `wusa` / `dism`.
5. **Зависимости** — VC++ 2015-2022, WebView2 Runtime, App Installer (winget).
6. **PowerShell 7** рядом с 5.1 (команда `pwsh`). Windows PowerShell 5.1 отдельным
   пакетом не обновляется — он часть ОС. Версия PowerShell 7 определяется на лету
   через GitHub API с откатом на 7.6.6 (последний релиз с MSI-пакетом).
7. **Claude Code CLI** — нативный установщик, Node.js не требуется.

## Запуск

От имени администратора:

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-ClaudeOnLTSC.ps1
```

Ключи: `-SkipWindowsUpdate` (пропустить самый долгий шаг), `-SkipClaudeInstall`.

После перезагрузки проверить: `claude doctor`

## Оговорки

- **LTSC 2019**: ставьте CLI, а не десктопное приложение. После перехода на
  Electron 40 Claude Desktop на сборке 17763 запускает основной процесс, но
  renderer не стартует — окно не появляется
  ([issue #29347](https://github.com/anthropics/claude-code/issues/29347)).
  Обновлениями Windows это не лечится. Для графики — [claude.ai/code](https://claude.ai/code).
- Claude Code ставится в профиль пользователя. Скрипт требует админа для
  обновлений, поэтому если права поднимались через другую учётку админа,
  Claude окажется в её профиле — тогда последний шаг выполните без админа:
  `irm https://claude.ai/install.ps1 | iex`
- Скрипт не проверялся запуском на Windows: писался и вычитывался в Linux-окружении.
  Синтаксис приводился к Windows PowerShell 5.1 вручную.
