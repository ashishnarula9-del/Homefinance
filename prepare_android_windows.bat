@echo off
setlocal
cd /d "%~dp0"

echo =================================================
echo Home Finance - Prepare Android project
echo =================================================
echo.
where flutter >nul 2>nul
if errorlevel 1 (
  echo ERROR: Flutter was not found in PATH.
  exit /b 1
)

rem A complete Android project needs BOTH the manifest and gradlew.bat.
set NEED_CREATE=0
if not exist android\app\src\main\AndroidManifest.xml set NEED_CREATE=1
if not exist android\gradlew.bat set NEED_CREATE=1

if "%NEED_CREATE%"=="1" (
  if exist android (
    echo Found an incomplete android folder. Moving it to android_old ...
    if exist android_old rmdir /s /q android_old
    ren android android_old
  )
  echo Creating Flutter Android platform files...
  call flutter create --platforms=android --org com.example --project-name family_finance .
  if errorlevel 1 exit /b 1
  if not exist android\app\src\main\AndroidManifest.xml (
    echo.
    echo ERROR: flutter create did not produce android\app\src\main\AndroidManifest.xml
    echo Your Flutter installation may be damaged or blocked by antivirus.
    echo See BUILD_ON_PC.md, Troubleshooting.
    exit /b 1
  )
)
call dart run tool\prepare_android.dart
if errorlevel 1 exit /b 1
call flutter pub get
if errorlevel 1 exit /b 1
call dart run flutter_launcher_icons
if errorlevel 1 exit /b 1
echo.
echo Android project preparation complete. Next: flutter build apk --release
endlocal
