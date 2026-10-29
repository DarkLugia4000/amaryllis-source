@echo off
setlocal
if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe" (
    start "" "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe" "%~dp0builder.py" --gui
    exit /b
)
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
