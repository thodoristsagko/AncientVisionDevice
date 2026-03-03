@echo off
echo ========================================
echo   Android Setup for AncientVision
echo ========================================
echo.

echo Step 1: Checking Flutter Doctor...
flutter doctor
echo.

echo ========================================
echo Step 2: Accepting Android Licenses
echo ========================================
echo Please type 'y' for each license prompt
echo.
pause
flutter doctor --android-licenses

echo.
echo ========================================
echo Step 3: Checking available emulators
echo ========================================
flutter emulators

echo.
echo ========================================
echo To create an emulator, run:
echo   flutter emulators --create
echo.
echo Or create one in Android Studio:
echo   Tools -^> Device Manager -^> Create Device
echo ========================================
pause
