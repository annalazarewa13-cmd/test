<#
    Fix-ClaudeOnLTSC.ps1
    ---------------------------------------------------------------
    Подготовка Windows 10/11 LTSC к установке Claude.

    Что делает:
      1. Диагностика: реальная сборка, редакция, разрядность, ОЗУ.
      2. Обновление корневых сертификатов (частая причина "installer failed"
         и ошибок TLS на старых LTSC-образах).
      3. Включение TLS 1.2 для .NET / WinHTTP.
      4. Установка ВСЕХ доступных обновлений через PSWindowsUpdate
         (накопительные + SSU). Это поднимает ревизию (UBR), но НЕ меняет
         номер сборки — LTSC по определению не получает feature updates.
      5. Установка зависимостей: VC++ 2015-2022, WebView2 Runtime,
         App Installer (winget).
      6. Обновление PowerShell: установка актуального PowerShell 7 рядом с 5.1.
      7. Установка Claude Code CLI (нативный установщик, без Node.js).

    Запускать ТОЛЬКО от имени администратора:
        powershell -ExecutionPolicy Bypass -File .\Fix-ClaudeOnLTSC.ps1

    Параметры:
        -SkipWindowsUpdate   пропустить шаг 4 (он самый долгий)
        -SkipClaudeInstall   не ставить Claude Code CLI в конце
#>

[CmdletBinding()]
param(
    [switch]$SkipWindowsUpdate,
    [switch]$SkipClaudeInstall
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # заметно ускоряет Invoke-WebRequest

# --- Минимальная поддерживаемая сборка Claude Code: Windows 10 1809 -----------
$MinBuild = 17763

# --- PowerShell 7 работает на .NET 10: минимум Windows 10 1607 (сборка 14393) ---
$MinBuildPwsh = 14393
# Последний релиз PowerShell с MSI-пакетом (начиная с 7.7.0 MSI не выпускают)
$PwshFallback = '7.6.6'

function Write-Step { param($n, $t) Write-Host "`n=== [$n] $t ===" -ForegroundColor Cyan }
function Write-Ok   { param($t)     Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn { param($t)     Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Write-Err  { param($t)     Write-Host "  [FAIL] $t" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Скачивание с ретраями и экспоненциальной задержкой
function Get-FileWithRetry {
    param([string]$Url, [string]$OutFile, [int]$Retries = 4)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            if ((Get-Item $OutFile -ErrorAction SilentlyContinue).Length -gt 0) { return $true }
        } catch {
            $wait = [math]::Pow(2, $i + 1)
            Write-Warn "Не скачалось ($($_.Exception.Message)). Повтор через $wait c..."
            Start-Sleep -Seconds $wait
        }
    }
    return $false
}

if (-not (Test-Admin)) {
    Write-Err 'Скрипт должен запускаться от имени администратора. Откройте PowerShell -> "Запуск от имени администратора".'
    exit 1
}

$tmp = Join-Path $env:TEMP 'claude-ltsc-prep'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# =============================================================================
Write-Step 1 'Диагностика системы'
# =============================================================================
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuildNumber
$ubr   = $cv.UBR
$ram   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)

Write-Host "  Редакция     : $($cv.ProductName) ($($cv.EditionID))"
$verName = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { 'н/д' }
Write-Host "  Версия       : $verName"
Write-Host "  Сборка       : $build.$ubr"
Write-Host "  Разрядность  : $env:PROCESSOR_ARCHITECTURE"
Write-Host "  ОЗУ          : $ram ГБ"

$ltscName = switch ($build) {
    10240   { 'LTSB 2015 (1507)' }
    14393   { 'LTSB 2016 (1607)' }
    17763   { 'LTSC 2019 (1809)' }
    19044   { 'LTSC 2021 (21H2)' }
    26100   { 'Windows 11 LTSC 2024 (24H2)' }
    default { 'не-LTSC или неизвестная сборка' }
}
Write-Host "  Определено   : $ltscName"

if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'ARM64')) {
    Write-Err 'Нужна 64-битная Windows. 32-битная (x86) не поддерживается — обновления это не исправят.'
    exit 1
}
if ($ram -lt 4) { Write-Warn 'Меньше 4 ГБ ОЗУ — это ниже минимальных требований.' }

if ($build -lt $MinBuild) {
    Write-Err "Сборка $build ниже минимальной $MinBuild (Windows 10 1809)."
    Write-Host @"

  ВАЖНО: поднять номер сборки через PowerShell/CMD/Windows Update НЕВОЗМОЖНО.
  LTSC по замыслу не получает feature updates — только исправления безопасности
  в пределах своей сборки. Единственный путь: in-place upgrade с ISO-образа
  (LTSC 2021 / Windows 11 LTSC 2024 / обычная Pro или Enterprise) с действующей
  лицензией. Скрипт продолжит выполнять остальные шаги, но Claude Desktop на
  этой сборке не заработает.

"@ -ForegroundColor Yellow
} else {
    Write-Ok "Сборка $build удовлетворяет минимуму ($MinBuild)."
}

# =============================================================================
Write-Step 2 'Обновление корневых сертификатов'
# =============================================================================
# На давно не обновлявшихся LTSC-образах устаревший список корневых CA ломает
# и проверку подписи установщиков, и TLS-соединение с claude.ai.
try {
    $sst = Join-Path $tmp 'roots.sst'
    Remove-Item $sst -ErrorAction SilentlyContinue
    certutil.exe -generateSSTFromWU $sst | Out-Null
    if (Test-Path $sst) {
        $count = try {
            $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $col.Import($sst)
            $col.Count
        } catch { 'н/д' }
        if (Get-Command Import-Certificate -ErrorAction SilentlyContinue) {
            Import-Certificate -FilePath $sst -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null
        } else {
            # На сборках без модуля PKI (LTSB 2015/2016) — через certutil
            certutil.exe -addstore -f Root $sst | Out-Null
        }
        Write-Ok "Корневые сертификаты обновлены (получено $count)."
    } else {
        Write-Warn 'certutil не сформировал список — пропускаю.'
    }
} catch {
    Write-Warn "Не удалось обновить сертификаты: $($_.Exception.Message)"
}

# =============================================================================
Write-Step 3 'Включение TLS 1.2'
# =============================================================================
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($fw in @(
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')) {
        if (Test-Path $fw) {
            Set-ItemProperty $fw -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord -Force
            Set-ItemProperty $fw -Name 'SchUseStrongCrypto'       -Value 1 -Type DWord -Force
        }
    }

    $sc = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
    New-Item -Path $sc -Force | Out-Null
    Set-ItemProperty $sc -Name 'Enabled'           -Value 1 -Type DWord -Force
    Set-ItemProperty $sc -Name 'DisabledByDefault' -Value 0 -Type DWord -Force
    Write-Ok 'TLS 1.2 включён для SChannel и .NET Framework.'
} catch {
    Write-Warn "TLS 1.2: $($_.Exception.Message)"
}

# =============================================================================
Write-Step 4 'Установка накопительных обновлений Windows'
# =============================================================================
if ($SkipWindowsUpdate) {
    Write-Warn 'Пропущено по ключу -SkipWindowsUpdate.'
} else {
    try {
        # На LTSC служба обновлений часто выключена политикой — временно включаем.
        Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue

        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (Test-Path $au) {
            $noUpd = (Get-ItemProperty $au -ErrorAction SilentlyContinue).NoAutoUpdate
            if ($noUpd -eq 1) { Write-Warn 'Политика NoAutoUpdate=1 активна — обновления могут не искаться.' }
        }

        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Host '  Ставлю модуль PSWindowsUpdate...'
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber
        }
        Import-Module PSWindowsUpdate -Force

        Write-Host '  Поиск обновлений (может занять 5-30 минут)...'
        $list = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop
        if (-not $list) {
            Write-Ok 'Новых обновлений нет.'
        } else {
            $list | Format-Table -AutoSize KB, Size, Title | Out-String | Write-Host
            Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose
            Write-Ok 'Обновления установлены. Перезагрузка потребуется в конце.'
        }
    } catch {
        Write-Warn "PSWindowsUpdate не отработал: $($_.Exception.Message)"
        Write-Host @"
  Ручной запасной вариант (когда Windows Update заблокирован политикой или
  службой). Накопительные обновления кумулятивны: ОДИН свежий пакет доведёт
  систему до актуальной ревизии, ставить всё подряд не нужно.

    1. Текущая сборка: $build.$ubr
    2. Каталог: https://catalog.update.microsoft.com
    3. Сначала самый свежий Servicing Stack Update для вашей версии.
       Для 1809 standalone SSU перестали выпускать в августе 2021 —
       последний KB5005112, он и нужен.
    4. Затем самый свежий Cumulative Update. Актуальный номер смотрите в
       истории обновлений: https://support.microsoft.com/help/4464619
    5. Ставьте через DISM (надёжнее wusa на комбинированных пакетах):
         dism.exe /Online /Add-Package /PackagePath:"C:\path\to\update.msu" /NoRestart
       Без ключа /Quiet виден прогресс. После LCU нужна перезагрузка,
       этап "Работа с обновлениями" может занять полчаса и дольше.
"@ -ForegroundColor Yellow
    }
}

# =============================================================================
Write-Step 5 'Зависимости среды выполнения'
# =============================================================================

# --- Visual C++ 2015-2022 ----------------------------------------------------
$vc = Join-Path $tmp 'vc_redist.x64.exe'
if (Get-FileWithRetry 'https://aka.ms/vs/17/release/vc_redist.x64.exe' $vc) {
    $p = Start-Process $vc -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($p.ExitCode -in 0, 1638, 3010) { Write-Ok 'Visual C++ 2015-2022 x64 на месте.' }
    else { Write-Warn "vc_redist вернул код $($p.ExitCode)." }
} else { Write-Warn 'Не удалось скачать vc_redist.x64.exe.' }

# --- WebView2 Runtime --------------------------------------------------------
# Claude Desktop — это Electron (свой Chromium внутри), WebView2 ему не нужен,
# но его требуют смежные компоненты и многие другие приложения. Ставим на всякий.
$wvKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
$wvInstalled = $wvKeys | Where-Object { Test-Path $_ } |
               ForEach-Object { (Get-ItemProperty $_).pv } | Select-Object -First 1

if ($wvInstalled) {
    Write-Ok "WebView2 Runtime уже установлен (версия $wvInstalled)."
} else {
    $wv = Join-Path $tmp 'MicrosoftEdgeWebview2Setup.exe'
    if (Get-FileWithRetry 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' $wv) {
        $p = Start-Process $wv -ArgumentList '/silent', '/install' -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Ok 'WebView2 Runtime установлен.' }
        else {
            Write-Warn "WebView2 вернул код $($p.ExitCode) (0x$('{0:X}' -f $p.ExitCode))."
            Write-Host '  При 0x80040C01 удалите ветки HKLM\SOFTWARE\(WOW6432Node\)Microsoft\EdgeUpdate\Clients\{F3017226-...} и повторите.' -ForegroundColor Yellow
        }
    } else { Write-Warn 'Не удалось скачать установщик WebView2.' }
}

# --- winget (App Installer) --------------------------------------------------
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Ok "winget уже доступен ($(winget --version))."
} elseif ($build -ge $MinBuild) {
    Write-Host '  Ставлю App Installer (winget) и его зависимости...'
    $pkgs = @(
        @{ n = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'; u = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' },
        @{ n = 'winget.msixbundle';                       u = 'https://aka.ms/getwinget' }
    )
    foreach ($pkg in $pkgs) {
        $f = Join-Path $tmp $pkg.n
        if (Get-FileWithRetry $pkg.u $f) {
            try { Add-AppxPackage -Path $f -ErrorAction Stop; Write-Ok "Установлен $($pkg.n)." }
            catch { Write-Warn "$($pkg.n): $($_.Exception.Message)" }
        }
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn 'winget не установился.'
        Write-Host '  Обычная причина на 1809 — 0x80073CF3: свежему App Installer нужен' -ForegroundColor Yellow
        Write-Host '  пакет Microsoft.WindowsAppRuntime, которого нет в системе.' -ForegroundColor Yellow
        Write-Host '  Это НЕ критично: и PowerShell 7, и Claude ниже ставятся без winget.' -ForegroundColor Yellow
        Write-Host '  Если winget всё же нужен — со страницы релиза' -ForegroundColor Yellow
        Write-Host '  https://github.com/microsoft/winget-cli/releases возьмите' -ForegroundColor Yellow
        Write-Host '  DesktopAppInstaller_Dependencies.zip той же версии, распакуйте папку x64' -ForegroundColor Yellow
        Write-Host '  и поставьте все пакеты из неё через Add-AppxPackage ДО .msixbundle.' -ForegroundColor Yellow
    }
} else {
    Write-Warn "winget требует сборку $MinBuild или новее — пропускаю."
}

# =============================================================================
Write-Step 6 'Обновление PowerShell'
# =============================================================================
Write-Host "  Текущая оболочка: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

# Windows PowerShell 5.1 нельзя обновить отдельным пакетом: он часть ОС и
# приезжает только с накопительными обновлениями (шаг 4). Актуальный PowerShell 7
# ставится рядом, отдельной командой pwsh, и ничего не ломает.
$existingPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($existingPwsh) {
    try {
        $cur = & pwsh -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        Write-Host "  Уже установлен pwsh: $cur (будет обновлён до актуального)"
    } catch {
        Write-Warn 'pwsh есть в PATH, но не запускается — переустановлю.'
    }
}

if ($build -lt $MinBuildPwsh) {
    Write-Warn "PowerShell 7 требует Windows 10 1607 (сборка $MinBuildPwsh) или новее — на $build не встанет."
    Write-Host '  На LTSB 2015 максимум — Windows PowerShell 5.1 из накопительных обновлений.' -ForegroundColor Yellow
} else {
    $installed = $false

    # --- Вариант A: winget (если появился на шаге 5) -------------------------
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host '  Ставлю через winget...'
        winget install --id Microsoft.PowerShell --source winget --installer-type wix `
               --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { $installed = $true; Write-Ok 'PowerShell 7 установлен через winget.' }
        else { Write-Warn "winget вернул код $LASTEXITCODE — пробую MSI напрямую." }
    }

    # --- Вариант B: MSI с GitHub --------------------------------------------
    if (-not $installed) {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

        # Берём свежайший релиз, у которого ещё есть MSI нужной архитектуры.
        $ver = $null
        try {
            $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=30' `
                                      -Headers @{ 'User-Agent' = 'ltsc-prep' } -TimeoutSec 60
            $ver = ($rels | Where-Object { -not $_.prerelease -and -not $_.draft } |
                    Where-Object { $_.assets.name -match "win-$arch\.msi$" } |
                    Select-Object -First 1).tag_name -replace '^v', ''
        } catch {
            Write-Warn "GitHub API недоступен ($($_.Exception.Message)) — беру проверенную версию."
        }
        if (-not $ver) { $ver = $PwshFallback }

        $msiName = "PowerShell-$ver-win-$arch.msi"
        $msiPath = Join-Path $tmp $msiName
        $msiUrl  = "https://github.com/PowerShell/PowerShell/releases/download/v$ver/$msiName"

        Write-Host "  Качаю $msiName ..."
        if (Get-FileWithRetry $msiUrl $msiPath) {
            $msiArgs = @(
                '/i', "`"$msiPath`"", '/quiet', '/norestart',
                'ADD_PATH=1',             # добавить pwsh в PATH
                'REGISTER_MANIFEST=1',    # нормальные логи событий
                'USE_MU=1', 'ENABLE_MU=1' # обновлять через Microsoft Update
            )
            $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
            if ($p.ExitCode -in 0, 3010) {
                $installed = $true
                Write-Ok "PowerShell $ver установлен (код $($p.ExitCode))."
            } else {
                Write-Err "msiexec вернул код $($p.ExitCode)."
            }
        } else {
            Write-Err "Не удалось скачать $msiUrl"
        }
    }

    if ($installed) {
        Write-Host '  Запускать: pwsh (новое окно терминала). Старый powershell 5.1 остаётся на месте.'
    }
}

# =============================================================================
Write-Step 7 'Установка Claude Code CLI'
# =============================================================================
if ($SkipClaudeInstall) {
    Write-Warn 'Пропущено по ключу -SkipClaudeInstall.'
} elseif ($build -lt $MinBuild) {
    Write-Warn "Сборка $build ниже $MinBuild — установка не имеет смысла, сначала in-place upgrade."
} else {
    # ВНИМАНИЕ: Claude Code ставится в профиль ТЕКУЩЕГО пользователя.
    # Скрипт запущен с правами администратора, поэтому если вы поднимали права
    # через учётку другого администратора, Claude окажется в ЕГО профиле.
    Write-Host "  Профиль установки: $env:USERPROFILE (пользователь $env:USERNAME)"
    Write-Host '  Если это не ваша учётка — установите Claude отдельно, без прав админа:' -ForegroundColor Yellow
    Write-Host '      irm https://claude.ai/install.ps1 | iex' -ForegroundColor Yellow
    try {
        # Нативный установщик: скачивает готовый бинарник, Node.js не требуется.
        & ([scriptblock]::Create((Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')))
        $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
        if (Test-Path $claudeExe) {
            Write-Ok "Claude Code установлен: $(& $claudeExe --version)"
        } else {
            Write-Warn 'Установщик отработал, но claude.exe не найден в %USERPROFILE%\.local\bin.'
        }
    } catch {
        Write-Err "Установка Claude Code не удалась: $($_.Exception.Message)"
    }
}

# =============================================================================
Write-Step 8 'Итог'
# =============================================================================
$cv2 = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host "  Сборка ОС      : $($cv2.CurrentBuildNumber).$($cv2.UBR) (было $build.$ubr)"

$pwshNow = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshNow) { Write-Host "  PowerShell 7   : $($pwshNow.Version) -> запускать командой pwsh" }
else          { Write-Host '  PowerShell 7   : не установлен' }

if (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) {
    Write-Host '  Claude Code    : установлен'
} else {
    Write-Host '  Claude Code    : не установлен'
}

Write-Host ''
Write-Host '  Дальше: перезагрузите ПК, откройте новое окно терминала и выполните:' -ForegroundColor Cyan
Write-Host '      claude doctor' -ForegroundColor Cyan
Write-Host ''
