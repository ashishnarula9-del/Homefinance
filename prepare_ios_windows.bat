@echo off
setlocal
cd /d "%~dp0"

echo ===============================================
echo Home Finance 1.0.2 - Prepare iPhone project
echo ===============================================
echo.
where flutter >nul 2>nul
if errorlevel 1 (
  echo ERROR: Flutter was not found in PATH.
  exit /b 1
)
if not exist ios\Runner\Info.plist (
  echo Creating Flutter iOS platform files...
  call flutter create --platforms=ios .
  if errorlevel 1 exit /b 1
) else (
  echo Existing iOS platform files found.
)
echo Applying Home Finance iOS permissions...
call dart run tool\prepare_ios.dart
if errorlevel 1 exit /b 1
call flutter pub get
if errorlevel 1 exit /b 1
call dart run flutter_launcher_icons
if errorlevel 1 exit /b 1
echo.
echo iOS project preparation complete.
echo Windows cannot compile/sign the iPhone app; use macOS/Xcode or Codemagic.
endlocal
