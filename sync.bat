@echo off
REM ─────────────────────────────────────────────────────────────────────────
REM  sync.bat  —  Copy shared index.html into both Android and iOS bundles
REM  Run this from the repo root after editing shared\index.html
REM ─────────────────────────────────────────────────────────────────────────

SET SRC=shared\index.html

IF NOT EXIST "%SRC%" (
    echo ERROR: %SRC% not found. Run this script from the repo root.
    exit /b 1
)

SET ANDROID=garajku-android\app\src\main\assets\index.html
SET IOS=garajku-ios\garajku-ios\garajku-ios\index.html

echo Copying to Android...
copy /Y "%SRC%" "%ANDROID%"

echo Copying to iOS...
copy /Y "%SRC%" "%IOS%"

echo.
echo Done! Both platforms updated.
echo Rebuild Android in Android Studio.
echo Push to GitHub to trigger iOS build (GitHub Actions).
