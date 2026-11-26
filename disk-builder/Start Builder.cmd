@echo off
setlocal
rem BEGIN pinned Python
rem The Disk Builder runs on one pinned Python with Tcl/Tk: a python-build-standalone
rem CPython build, downloaded on first start, checked against its SHA-256 and kept
rem in .python next to this file. To change the pin, update all four values and
rem the version check in the install step below.
set "PIN_VERSION=3.12.16+20261124"
set "PIN_SHA256=96694b50dcfde13d56e40346ddaa552a9cd650290e9b933cecf83c1d82226960"
set "PIN_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261124/cpython-3.12.16%%2B20261124-x86_64-pc-windows-msvc-install_only_stripped.tar.gz"
set "PIN_HOME=%~dp0.python"
set "PIN_DIR=%PIN_HOME%\cpython-3.12.16-20261124"
if not exist "%PIN_DIR%\python\pythonw.exe" call :pin_install
if exist "%PIN_DIR%\python\pythonw.exe" (
    start "" "%PIN_DIR%\python\pythonw.exe" "%~dp0builder.py" --gui
    exit /b
)
echo Continuing with the Python installed on this PC.
rem END pinned Python
where pyw.exe >nul 2>&1
if not errorlevel 1 (
    start "" pyw.exe -3 "%~dp0builder.py" --gui
    exit /b
)
where pythonw.exe >nul 2>&1
if not errorlevel 1 (
    start "" pythonw.exe "%~dp0builder.py" --gui
    exit /b
)
where py.exe >nul 2>&1
if not errorlevel 1 (
    py.exe -3 "%~dp0builder.py" --gui
    exit /b
)
where python.exe >nul 2>&1
if not errorlevel 1 (
    python.exe "%~dp0builder.py" --gui
    exit /b
)
echo Python 3.11 or newer with Tcl/Tk is required.
echo Install Python for Windows, then double-click this launcher again.
echo See README.md for details. No pip packages are needed.
pause
exit /b

rem BEGIN pinned Python install
:pin_install
set "PIN_ARCHIVE=%PIN_HOME%\download.tar.gz"
set "PIN_STAGE=%PIN_DIR%.partial"
if not exist "%SystemRoot%\System32\curl.exe" (echo curl.exe is missing from Windows. & goto pin_failed)
if not exist "%SystemRoot%\System32\tar.exe" (echo tar.exe is missing from Windows. & goto pin_failed)
if not exist "%PIN_HOME%" mkdir "%PIN_HOME%"
echo Downloading Python %PIN_VERSION% with Tcl/Tk, about 22 MB, on first start only...
"%SystemRoot%\System32\curl.exe" -fL --retry 3 --progress-bar -o "%PIN_ARCHIVE%" "%PIN_URL%" || goto pin_failed
powershell.exe -NoProfile -NonInteractive -Command "if ((Get-FileHash -Algorithm SHA256 -LiteralPath $env:PIN_ARCHIVE).Hash -ne $env:PIN_SHA256) { exit 1 }" || (echo The download does not match the pinned SHA-256. & goto pin_failed)
if exist "%PIN_STAGE%" rmdir /s /q "%PIN_STAGE%"
mkdir "%PIN_STAGE%"
"%SystemRoot%\System32\tar.exe" -xzf "%PIN_ARCHIVE%" -C "%PIN_STAGE%" || goto pin_failed
"%PIN_STAGE%\python\python.exe" -I -c "import sys, tkinter; tkinter.Tcl(); sys.exit(sys.version_info[:3] != (3, 12, 16))" || (echo The downloaded Python failed its Tcl/Tk check. & goto pin_failed)
move "%PIN_STAGE%" "%PIN_DIR%" >nul || goto pin_failed
del "%PIN_ARCHIVE%"
echo Python %PIN_VERSION% is ready.
exit /b 0
:pin_failed
if exist "%PIN_STAGE%" rmdir /s /q "%PIN_STAGE%"
if exist "%PIN_ARCHIVE%" del "%PIN_ARCHIVE%"
echo The pinned Python could not be installed.
exit /b 1
rem END pinned Python install
