@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title Настройка роутера TL-WR840N
set "R=192.168.1.1"
set "SCRIPT=site-setup.sh"
set "SSH=%SystemRoot%\System32\OpenSSH\ssh.exe"
if not exist "%SSH%" set "SSH=ssh"
set "FIND=%SystemRoot%\System32\find.exe"
set "SSHOPT=-T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=known_hosts.tmp -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 -o LogLevel=ERROR"

echo.
echo   Настройка роутера TL-WR840N: PPPoE, сеть камер, WireGuard
echo   ---------------------------------------------------------
echo.

if not "%SSH%"=="ssh" goto :have_ssh
where ssh >nul 2>&1
if errorlevel 1 goto :no_ssh
:have_ssh
del "known_hosts.tmp" >nul 2>&1
if not exist "%SCRIPT%" goto :no_script
set "R2=%R%"
for /f "tokens=2 delims='" %%a in ('findstr /b /c:"LAN_IP=" "%SCRIPT%"') do set "R2=%%a"

echo [1/4] Проверяю связь с роутером %R% ...
call :ping %R%
if errorlevel 1 goto :no_router
"%SSH%" %SSHOPT% root@%R% true > "0-ssh.log" 2>&1
if errorlevel 1 goto :ssh_failed

echo [2/4] Записываю настройки в роутер ...
"%SSH%" %SSHOPT% root@%R% sh -s < "%SCRIPT%" > "1-setup.log" 2>&1
findstr /v /c:"SETUP_OK" "1-setup.log"
findstr /c:"SETUP_OK" "1-setup.log" >nul
if errorlevel 1 goto :setup_failed

echo.
echo [3/4] Роутер перезагружается, это 1-2 минуты ...
set /a n=0
:wait_down
call :ping %R%
if errorlevel 1 goto :wait_up_start
set /a n+=1
if %n% geq 40 goto :wait_up_start
call :sleep 2
goto :wait_down
:wait_up_start
set /a n=0
:wait_up
call :ping %R2%
if not errorlevel 1 goto :router_up
set /a n+=1
if %n% geq 90 goto :no_return
call :sleep 2
goto :wait_up
:router_up

echo [4/4] Проверяю интернет, камеры и WireGuard, до 2 минут ...
set /a n=0
:check
call :sleep 10
"%SSH%" %SSHOPT% root@%R2% sh /root/site-check.sh > "2-check.log" 2>&1
findstr /c:"CHECK_DONE" "2-check.log" >nul
if not errorlevel 1 goto :checked
set /a n+=1
if %n% lss 6 goto :check
findstr /v /c:"CHECK_DONE" "2-check.log"
echo.
echo [X] Не получилось выполнить проверку на роутере.
goto :end

:checked
echo.
findstr /v /c:"CHECK_DONE" "2-check.log"
echo.
echo ===========================================================
echo   Готово. Сохраните пароль root - он показан выше.
echo   Напишите Claude в чат «готово» - он пришлёт QR-коды WireGuard.
echo ===========================================================
goto :end

:no_ssh
echo [X] Не найдена программа ssh.
echo     Параметры - Приложения - Дополнительные компоненты - добавьте «Клиент OpenSSH».
goto :end

:no_script
echo [X] Рядом с этим файлом нет %SCRIPT%.
goto :end

:no_router
echo [X] Роутер %R% не отвечает. Проверьте:
echo     - кабель от компьютера в LAN-порт роутера, не в WAN;
echo     - сетевая карта получает IP автоматически.
ipconfig | "%FIND%" "192.168.0.66" >nul && echo     Сейчас у компьютера IP 192.168.0.66 после TFTP: переключите карту на «Получить IP-адрес автоматически».
echo     Потом запустите этот файл ещё раз.
goto :end

:ssh_failed
type "0-ssh.log"
findstr /c:"Permission denied" "0-ssh.log" >nul
if errorlevel 1 goto :ssh_error
echo [X] На роутере уже задан пароль root: похоже, настройка уже выполнена.
echo     Проверка вручную: ssh root@%R% sh /root/site-check.sh
goto :end

:ssh_error
echo [X] Не удалось подключиться к роутеру по SSH - сообщение выше.
goto :end

:setup_failed
echo.
echo [X] Настройка не записалась - причина в сообщениях выше.
goto :end

:no_return
echo [X] Роутер не появился в сети после перезагрузки.
echo     Подождите минуту и запустите файл ещё раз.
goto :end

:end
echo.
pause
exit /b

:ping
ping -n 1 -w 1500 %1 | "%FIND%" "TTL=" >nul
exit /b %errorlevel%

:sleep
set /a "s=%~1+1"
ping -n %s% 127.0.0.1 >nul
exit /b 0
