# Сценарии пробной сборки (задачи 1.5 и 1.6 user-logon-autostart).
# Скрипт не падает на первой неудаче: нужен полный список наблюдений,
# поэтому каждый шаг пишет PASS, FAIL или INFO в results.jsonl.
param(
    [Parameter(Mandatory)][string]$Scenario,
    [Parameter(Mandatory)][string]$Packages,
    [Parameter(Mandatory)][string]$ResultsDir
)

$ErrorActionPreference = 'Stop'
$Packages = (Resolve-Path $Packages).Path
New-Item -ItemType Directory -Force $ResultsDir | Out-Null
$ResultsDir = (Resolve-Path $ResultsDir).Path
$installDir = "$env:ProgramFiles\FilePickerProbe"
$exe = "$installDir\probe.exe"
$runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$sourceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\FilePickerProbe'
$logDir = 'C:\ProgramData\FilePickerProbe'
$logFile = "$logDir\probe.jsonl"
$tool = (Resolve-Path "$PSScriptRoot\tool.py").Path
$summary = [System.Collections.Generic.List[string]]::new()
$msiCount = 0

New-Item -ItemType Directory -Force $logDir | Out-Null
& icacls.exe $logDir /grant 'Everyone:(OI)(CI)M' | Out-Null

function Record([string]$status, [string]$name, [string]$detail = '') {
    $line = "- **$status** $name" + $(if ($detail) { " — $detail" } else { '' })
    $summary.Add($line)
    Write-Output $line
    @{ status = $status; name = $name; detail = $detail } | ConvertTo-Json -Compress |
        Add-Content -Encoding utf8 "$ResultsDir\results.jsonl"
}
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    Record $(if ($ok) { 'PASS' } else { 'FAIL' }) $name $detail
}
function Note([string]$name, [string]$detail) { Record 'INFO' $name $detail }
function Step([string]$name, [scriptblock]$body) {
    Write-Output "=== $name"
    try { & $body } catch { Record 'ERROR' $name "$_" }
}

function Log { if (Test-Path $logFile) { @(Get-Content -Encoding utf8 $logFile | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
function Mark { (Log).Count }
function Since([int]$mark) { @(Log | Select-Object -Skip $mark) }
function WaitFor([int]$mark, [string]$kind, [int]$seconds = 20) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        $found = @(Since $mark | Where-Object kind -eq $kind)
        if ($found) { return $found[-1] }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Kinds([int]$mark) { (Since $mark | ForEach-Object kind) -join ', ' }

function Probes { @(Get-CimInstance Win32_Process -Filter "Name='probe.exe'") }
function Describe-Probes {
    (Probes | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        "pid=$($_.ProcessId) user=$($owner.Domain)\$($owner.User) session=$($_.SessionId) path=$($_.ExecutablePath)"
    }) -join '; '
}
function Stop-Probes {
    Probes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}
function Tool { & python $tool @args; $LASTEXITCODE }

function Msi([string[]]$arguments, [string]$label) {
    $script:msiCount++
    $log = "$ResultsDir\msi-$('{0:d2}' -f $script:msiCount)-$label.log"
    $all = @($arguments) + @('/qn', '/norestart', '/l*v', "`"$log`"")
    # Не -Wait: он ждёт и дочерние процессы, а Restart Manager запускает exe
    # от msiexec, и ожидание длилось бы, пока exe работает
    $process = Start-Process msiexec.exe -ArgumentList $all -PassThru
    $null = $process.Handle
    if (-not $process.WaitForExit(300000)) { throw 'msiexec не завершился за 5 минут' }
    $process.ExitCode
}
function Install([string]$name, [string]$extra = '') {
    $arguments = @('/i', "`"$Packages\probe-$name.msi`"")
    if ($extra) { $arguments += $extra }
    Msi $arguments "install-$name"
}
function Uninstall([string]$name) { Msi @('/x', "`"$Packages\probe-$name.msi`"") "remove-$name" }

function FileDiff([string]$name, [string[]]$exclude = @()) {
    $root = "$Packages\$name"
    $source = Get-ChildItem -Recurse -File $root
    $diff = foreach ($file in $source) {
        $relative = $file.FullName.Substring($root.Length + 1)
        if ($relative -in $exclude) { continue }
        $target = Join-Path $installDir $relative
        if (-not (Test-Path $target)) { "missing $relative"; continue }
        if ((Get-FileHash $file.FullName).Hash -ne (Get-FileHash $target).Hash) { "differs $relative" }
    }
    @($diff)
}
function Products {
    (Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object DisplayName -like 'File Picker Probe*' |
        ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; '
}
function InConsole([string]$file, [string]$arguments) {
    Start-Process $file -ArgumentList $arguments -PassThru
}
function Dump([int]$id) { (& python $tool dump $id | Out-String) }

function Run-Basic {
    Step 'установка' {
        Check 'msiexec /i /qn /norestart' ((Install 'a') -eq 0)
        $value = (Get-ItemProperty $runKey).FilePickerProbe
        Check 'значение Run' ($value -eq "`"$exe`"") $value
        Check 'файлы' ((FileDiff 'a').Count -eq 0) ((FileDiff 'a') -join ', ')
        Check 'источник событий' (Test-Path $sourceKey) (Get-ItemProperty $sourceKey).EventMessageFile
        Note 'название с кириллицей' (Products)
        Set-Content "$installDir\.env" 'CORS_ORIGINS=https://example.com'
    }

    Step 'свойство с другой папкой' {
        $product = (Uninstall 'a')
        $code = Install 'a' 'InstallDir=C:\ProbeElsewhere INSTALLDIR=C:\ProbeElsewhere'
        Check 'папку нельзя подменить' ($code -eq 0 -and (Test-Path $exe) -and -not (Test-Path 'C:\ProbeElsewhere')) "uninstall=$product install=$code"
        Check '.env пережил удаление и установку' (Test-Path "$installDir\.env")
    }

    Step '1.5 без консоли' {
        $mark = Mark
        $process = Start-Process $exe -PassThru
        $start = WaitFor $mark 'start'
        Check 'запуск без консоли' ($null -ne $start) "console_window=$($start.console_window) stdout=$($start.stdout) version=$($start.version) local_appdata=$($start.local_appdata) restart_result=$($start.restart_result) user=$($start.user) session=$($start.session)"
        Check 'нет окна консоли' (-not $start.console_window)
        $window = WaitFor $mark 'window_created'
        Note 'скрытое окно' "hwnd=$($window.hwnd) visible=$($window.visible)"
        Tool window-close | Out-Null
        Check 'WM_CLOSE останавливает' ($process.WaitForExit(15000)) (Kinds $mark)
    }

    foreach ($shell in @(@('cmd', 'cmd.exe', '/k', ''), @('PowerShell', 'powershell.exe', '-NoExit -NoLogo -NoProfile', '& '))) {
        Step "1.5 интерактивный $($shell[0])" {
            $marker = "$ResultsDir\marker-$($shell[0]).txt"
            $host_ = InConsole $shell[1] $shell[2]
            Start-Sleep -Seconds 4
            $mark = Mark
            Tool type $host_.Id "$($shell[3])`"$exe`"" | Out-Null
            $start = WaitFor $mark 'start'
            Check 'exe запущен из консоли' ($null -ne $start) "console_window=$($start.console_window) stdout=$($start.stdout)"
            Start-Sleep -Seconds 2
            Tool type $host_.Id "echo done > `"$marker`"" | Out-Null
            Start-Sleep -Seconds 3
            Note 'приглашение вернулось, пока exe работает' "marker=$(Test-Path $marker)"
            $screen = Dump $host_.Id
            Set-Content -Encoding utf8 "$ResultsDir\console-$($shell[0]).txt" $screen
            Check 'вывод виден в консоли' ($screen -match 'probe console line') ($screen -replace '\s+', ' ')
            Tool ctrl-c $host_.Id | Out-Null
            $stopped = WaitFor $mark 'stopped' 10
            Check 'Ctrl+C останавливает' ($null -ne $stopped) (Kinds $mark)
            Start-Sleep -Seconds 1
            Stop-Probes
            Stop-Process -Id $host_.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Step '1.5 закрытие окна консоли' {
        $host_ = InConsole 'cmd.exe' '/k'
        Start-Sleep -Seconds 4
        $mark = Mark
        Tool type $host_.Id "`"$exe`"" | Out-Null
        WaitFor $mark 'start' | Out-Null
        Start-Sleep -Seconds 2
        Note 'инструмент закрытия' ((Tool close-console $host_.Id) -join ' ')
        $done = WaitFor $mark 'close_done' 10
        Check 'событие записано до возврата из обработчика' ($null -ne $done) (Kinds $mark)
        $event = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'FilePickerProbe'; Id = 1001 } -MaxEvents 1 -ErrorAction SilentlyContinue
        Check 'текст события с кириллицей' ($event.Message -eq 'Пробный exe остановлен: закрытие консоли, ёЁ') $event.Message
        Stop-Probes
    }

    Step '1.5 run_test.bat' {
        $bat = "$installDir\run_probe.bat"
        (Get-Content run_test.bat -Raw).Replace('FilePickerAPI.exe', 'probe.exe') | Set-Content $bat -Encoding ascii
        $host_ = InConsole 'cmd.exe' "/c `"$bat`""
        $mark = Mark
        $start = WaitFor $mark 'start'
        Check 'bat запустил exe' ($null -ne $start) "console_window=$($start.console_window)"
        Start-Sleep -Seconds 2
        $before = Dump $host_.Id
        Check 'bat ждёт exe' ($before -notmatch 'Press any key') ($before -replace '\s+', ' ')
        Check 'вывод в окне bat' ($before -match 'probe console line')
        Tool window-close | Out-Null
        WaitFor $mark 'stopped' 10 | Out-Null
        Start-Sleep -Seconds 2
        $after = Dump $host_.Id
        Check 'после выхода exe bat дошёл до pause' ($after -match 'Press any key') ($after -replace '\s+', ' ')
        Stop-Process -Id $host_.Id -Force -ErrorAction SilentlyContinue

        $host_ = InConsole 'cmd.exe' "/c `"$bat`""
        $mark = Mark
        WaitFor $mark 'start' | Out-Null
        Start-Sleep -Seconds 2
        Tool ctrl-c $host_.Id | Out-Null
        WaitFor $mark 'stopped' 10 | Out-Null
        Start-Sleep -Seconds 2
        $screen = Dump $host_.Id
        Note 'Ctrl+C в bat' ($screen -replace '\s+', ' ')
        Stop-Process -Id $host_.Id -Force -ErrorAction SilentlyContinue
        Stop-Probes
        Remove-Item $bat -Force
    }

    Step '1.5 start /wait' {
        $marker = "$ResultsDir\marker-start-wait.txt"
        $bat = "$ResultsDir\start-wait.bat"
        Set-Content $bat "start /wait `"`" `"$exe`"`r`necho done > `"$marker`"" -Encoding ascii
        $host_ = InConsole 'cmd.exe' "/c `"$bat`""
        $mark = Mark
        WaitFor $mark 'start' | Out-Null
        Start-Sleep -Seconds 3
        Check 'start /wait ждёт' (-not (Test-Path $marker))
        Tool window-close | Out-Null
        Start-Sleep -Seconds 3
        Check 'после выхода продолжает' (Test-Path $marker)
        Stop-Process -Id $host_.Id -Force -ErrorAction SilentlyContinue
        Stop-Probes
    }

    Step 'та же версия другой сборки поверх' {
        Note 'до' (Products)
        $code = Install 'c'
        Check 'отказ' ($code -ne 0) "code=$code"
        Check 'продукт прежний' ((Products) -like '*5400*' -and (Products) -notlike '*5100*') (Products)
        Check 'exe не заменён' ((FileDiff 'a').Count -eq 0) ((FileDiff 'a') -join ', ')
    }

    Step 'неудачное обновление' {
        $code = Install 'b' 'PROBEFAIL=1'
        Check 'установка упала' ($code -ne 0) "code=$code"
        Check 'файлы вернулись' ((FileDiff 'a').Count -eq 0) ((FileDiff 'a') -join ', ')
        Check 'значение Run на месте' ($null -ne (Get-ItemProperty $runKey).FilePickerProbe)
        Check '.env на месте' (Test-Path "$installDir\.env")
        Check 'один продукт прежней версии' ((Products) -like '*1.0.0*' -and (Products) -notlike '*;*') (Products)
    }

    Step 'обновление на остановленном сервисе' {
        $code = Install 'b'
        Check 'код 0' ($code -eq 0) "code=$code"
        Check 'SHA-256 как у b' ((FileDiff 'b').Count -eq 0) ((FileDiff 'b') -join ', ')
        Check 'один продукт' ((Products) -like '*1.0.1*' -and (Products) -notlike '*;*') (Products)
        Check '.env на месте' (Test-Path "$installDir\.env")
    }

    Step 'старая версия поверх' {
        $code = Install 'a'
        Check 'отказ' ($code -ne 0) "code=$code"
        Check 'файлы b остались' ((FileDiff 'b').Count -eq 0) ((FileDiff 'b') -join ', ')
    }

    Step 'откат' {
        $removed = Uninstall 'b'
        Check 'удаление' ($removed -eq 0) "code=$removed"
        Check 'источник и файл сообщений остались' ((Test-Path $sourceKey) -and (Test-Path "$installDir\FilePickerProbe.messages.dll"))
        Check 'значения Run нет' ($null -eq (Get-ItemProperty $runKey).FilePickerProbe)
        Check 'текст старого события читается' ((Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'FilePickerProbe'; Id = 1001 } -MaxEvents 1).Message -match 'Пробный exe')
        $code = Install 'a'
        Check 'установка первого' ($code -eq 0) "code=$code"
        $diff = FileDiff 'a' @('FilePickerProbe.messages.dll')
        Check 'SHA-256 как у a, кроме файла сообщений' ($diff.Count -eq 0) ($diff -join ', ')
        $dll = (Get-Item "$installDir\FilePickerProbe.messages.dll").VersionInfo
        Check 'файл сообщений остался новейшим' ((Get-FileHash "$installDir\FilePickerProbe.messages.dll").Hash -eq (Get-FileHash "$Packages\b\FilePickerProbe.messages.dll").Hash) "$($dll.FileMajorPart).$($dll.FileMinorPart).$($dll.FileBuildPart)"
        Check '.env на месте' (Test-Path "$installDir\.env")
    }

    Step 'смена филиала' {
        Check 'удаление' ((Uninstall 'a') -eq 0)
        $code = Install 'c'
        Check 'установка' ($code -eq 0) "code=$code"
        $diff = FileDiff 'c' @('FilePickerProbe.messages.dll')
        Check 'SHA-256 как у c' ($diff.Count -eq 0) ($diff -join ', ')
        Check '.env на месте' (Test-Path "$installDir\.env")
        Check 'продукт' ((Products) -like '*5100*') (Products)
    }

    Step 'повторный запуск того же MSI' {
        $code = Install 'c'
        Note 'тот же файл MSI' "code=$code products=$(Products)"
    }
}

function Run-RestartManager([string]$kind) {
    Step 'установка' { Check 'msiexec' ((Install 'a') -eq 0) }
    Set-Content "$installDir\.env" 'CORS_ORIGINS=https://example.com'

    $password = $null
    Step 'запуск экземпляра' {
        $mark = Mark
        if ($kind -eq 'rm-other-user') {
            # Экземпляр другого пользователя в том же сеансе: так устроена
            # установка, когда администратор вводит свой пароль за оператора
            $password = "aA1!$([guid]::NewGuid())"
            $secure = ConvertTo-SecureString $password -AsPlainText -Force
            New-LocalUser probeuser -Password $secure -PasswordNeverExpires | Out-Null
            $credential = [pscredential]::new('probeuser', $secure)
            Start-Process $exe -Credential $credential -LoadUserProfile -WorkingDirectory $env:SystemRoot | Out-Null
        } else {
            Start-Process $exe | Out-Null
        }
        $start = WaitFor $mark 'start' 30
        Check 'экземпляр запущен' ($null -ne $start) "user=$($start.user) session=$($start.session) restart_result=$($start.restart_result)"
        WaitFor $mark 'window_created' | Out-Null
        Note 'runner' "$(whoami) session=$((Get-Process -Id $PID).SessionId)"
    }

    Step 'обновление поверх работающего' {
        $mark = Mark
        Note 'до' (Describe-Probes)
        if ($kind -eq 'rm-system') {
            $log = "$ResultsDir\msi-system-install-b.log"
            $action = New-ScheduledTaskAction -Execute msiexec.exe -Argument "/i `"$Packages\probe-b.msi`" /qn /norestart /l*v `"$log`""
            Register-ScheduledTask ProbeInstall -Action $action -User SYSTEM -RunLevel Highest | Out-Null
            Start-ScheduledTask ProbeInstall
            Start-Sleep -Seconds 3
            while ((Get-ScheduledTask ProbeInstall).State -eq 'Running') { Start-Sleep -Seconds 1 }
            $code = (Get-ScheduledTaskInfo ProbeInstall).LastTaskResult
        } else {
            $code = Install 'b'
        }
        Note 'код msiexec' "$code"
        $after = @()
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Seconds 2
            $after = @(Since $mark | Where-Object kind -eq 'start')
        } while (-not $after -and (Get-Date) -lt $deadline)
        Note 'записи экземпляров' (Kinds $mark)
        Note 'получил ли WM_ENDSESSION' ((Since $mark | Where-Object kind -eq 'end_session' | ForEach-Object { "wparam=$($_.wparam) lparam=$($_.lparam) pid=$($_.pid)" }) -join '; ')
        Note 'перезапущенный процесс' (($after | ForEach-Object { "pid=$($_.pid) user=$($_.user) session=$($_.session) version=$($_.version) local_appdata=$($_.local_appdata)" }) -join '; ')
        Note 'после' (Describe-Probes)
        $diff = FileDiff 'b'
        Note 'SHA-256 как у b' $(if ($diff.Count) { $diff -join ', ' } else { 'совпадает' })
        Check '.env на месте' (Test-Path "$installDir\.env")
        Check 'значение Run на месте' ($null -ne (Get-ItemProperty $runKey).FilePickerProbe)
        Note 'продукт' (Products)
        Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue |
            ForEach-Object { Note 'отложенные замены' (($_.PendingFileRenameOperations | Select-Object -First 6) -join ' | ') }
    }

    Step 'удаление при работающем' {
        $mark = Mark
        $code = Uninstall 'b'
        Start-Sleep -Seconds 10
        Note 'код удаления' "$code"
        Note 'записи экземпляров' (Kinds $mark)
        Note 'после' (Describe-Probes)
    }
}

function Run-Crash {
    Step 'установка' { Check 'msiexec' ((Install 'a') -eq 0) }
    foreach ($case in @(@('с флагами', ''), @('контроль без флагов', '--no-flags'))) {
        Step "сбой процесса $($case[0])" {
            Note 'WER' (Get-Service WerSvc | ForEach-Object { "$($_.Status) $($_.StartType)" })
            $mark = Mark
            if ($case[1]) { $process = Start-Process $exe -ArgumentList $case[1] -PassThru } else { $process = Start-Process $exe -PassThru }
            $start = WaitFor $mark 'start'
            Check 'RegisterApplicationRestart' ($start.restart_result -eq 0) "hresult=$($start.restart_result)"
            WaitFor $mark 'window_created' | Out-Null
            # Windows не перезапускает процессы моложе 60 секунд
            Start-Sleep -Seconds 70
            Tool window-crash | Out-Null
            Check 'процесс упал' ($process.WaitForExit(15000)) (Kinds $mark)
            Start-Sleep -Seconds 60
            Note 'запусков' "$(@(Since $mark | Where-Object kind -eq 'start').Count)"
            Note 'записи' (Kinds $mark)
            Note 'процессы' (Describe-Probes)
            Stop-Probes
        }
    }
}

try {
    if ($Scenario -eq 'basic') { Run-Basic }
    elseif ($Scenario -eq 'crash') { Run-Crash }
    else { Run-RestartManager $Scenario }
}
finally {
    Stop-Probes
    Copy-Item $logFile $ResultsDir -ErrorAction SilentlyContinue
    if ($env:GITHUB_STEP_SUMMARY) {
        "## $Scenario`n" + ($summary -join "`n") | Add-Content -Encoding utf8 $env:GITHUB_STEP_SUMMARY
    }
}
