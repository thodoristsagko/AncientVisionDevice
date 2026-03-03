@echo off
REM Build AncientVision with API keys injected via --dart-define
REM Usage: scripts\build_with_keys.bat [run|build|apk]

setlocal

REM Load from .env file if it exists
if exist "%~dp0..\.env" (
    for /f "usebackq tokens=1,2 delims==" %%a in ("%~dp0..\.env") do (
        if not "%%a"=="" if not "%%a:~0,1%"=="#" set "%%a=%%b"
    )
)

set DEFINES=--dart-define=IMGBB_API_KEY=%IMGBB_API_KEY% --dart-define=NUMISTA_API_KEY=%NUMISTA_API_KEY% --dart-define=GEMINI_API_KEY=%GEMINI_API_KEY% --dart-define=OPENSCAN_USERNAME=%OPENSCAN_USERNAME% --dart-define=OPENSCAN_PASSWORD=%OPENSCAN_PASSWORD%

set CMD=%1
if "%CMD%"=="" set CMD=run

if "%CMD%"=="apk" (
    flutter build apk %DEFINES%
) else if "%CMD%"=="build" (
    flutter build %DEFINES%
) else (
    flutter run %DEFINES%
)
