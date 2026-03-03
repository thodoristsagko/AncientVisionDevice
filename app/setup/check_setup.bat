@echo off
echo ========================================
echo   AncientVision Setup Checker
echo ========================================
echo.

echo Running Flutter Doctor...
echo.
flutter doctor
echo.

echo ========================================
echo NEXT STEPS:
echo ========================================
echo.
echo If you see errors above, follow these steps:
echo.
echo 1. If "cmdline-tools component is missing":
echo    - Open Android Studio
echo    - Go to Tools -^> SDK Manager
echo    - Install "Android SDK Command-line Tools"
echo.
echo 2. If "Android license status unknown":
echo    - Run: flutter doctor --android-licenses
echo    - Type 'y' for all prompts
echo.
echo 3. See FINISH_SETUP.md for detailed instructions
echo.
pause
