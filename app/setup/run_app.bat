@echo off
echo ========================================
echo   AncientVision Flutter App Launcher
echo ========================================
echo.

REM Check if Flutter is installed
flutter --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Flutter is not installed or not in PATH!
    echo.
    echo Please follow INSTALLATION.md to install Flutter first.
    echo.
    pause
    exit /b 1
)

echo Flutter is installed!
echo.

REM Install dependencies
echo Installing dependencies...
flutter pub get

echo.
echo ========================================
echo Select how to run the app:
echo ========================================
echo 1. Run on Chrome (web browser)
echo 2. Run on Android emulator/device
echo 3. List available devices
echo 4. Exit
echo.

set /p choice="Enter your choice (1-4): "

if "%choice%"=="1" (
    echo.
    echo Launching app in Chrome...
    flutter run -d chrome
) else if "%choice%"=="2" (
    echo.
    echo Launching app on Android...
    flutter run
) else if "%choice%"=="3" (
    echo.
    echo Available devices:
    flutter devices
    echo.
    pause
) else if "%choice%"=="4" (
    exit /b 0
) else (
    echo Invalid choice!
    pause
)

pause
