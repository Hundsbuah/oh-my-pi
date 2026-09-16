@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem OMP local source build + safe install
rem
rem install.bat must live in the root of the oh-my-pi repository.
rem The repository path is derived from the location of this BAT.
rem
rem IMPORTANT VERSIONING DESIGN
rem ---------------------------
rem Internal OMP VERSION stays the official version, e.g.:
rem     18.1.16
rem
rem Only the DISPLAY paths in packages\coding-agent\src\cli.ts are patched
rem temporarily while building so the local binary shows:
rem     omp/18.1.16+local-git
rem
rem This means update logic continues to compare the official internal VERSION
rem against the published release. The source file cli.ts is restored
rem byte-identically immediately after the build.
rem
rem This avoids changing packages\utils\src\dirs.ts for local version labeling.
rem
rem Branch safety:
rem   - bun install runs on every invocation.
rem   - native Cargo artifacts for x86_64-pc-windows-msvc/local are cleaned
rem     on every invocation before the native build.
rem   - CARGO_INCREMENTAL=0 disables Cargo incremental compilation for this
rem     script so pi-natives is rebuilt from clean native artifacts.
rem   - OMP_NATIVE_CARGO_PROFILE=local pins the native build to the same
rem     profile that is cleaned above.
rem   - bun run build:native runs on every invocation.
rem   - the coding-agent dist binary is deleted and rebuilt from the active
rem     checkout on every invocation.
rem ============================================================

for %%I in ("%~dp0.") do set "REPO=%%~fI"

set "INSTALLED=%LOCALAPPDATA%\omp\omp.exe"
set "BUILD_EXE=%REPO%\packages\coding-agent\dist\omp.exe"
set "BUILD_NOEXT=%REPO%\packages\coding-agent\dist\omp"

set "VERSION_FILE=%REPO%\packages\utils\src\dirs.ts"
set "CLI_FILE=%REPO%\packages\coding-agent\src\cli.ts"
set "CLI_BACKUP=%CLI_FILE%.install-local-git.backup"
set "CLI_TEMP=%CLI_FILE%.install-local-git.tmp"
set "CLI_REPLACE_BACKUP=%CLI_FILE%.install-local-git.replace-backup"

set "EXIT_REPO=2"
set "EXIT_BUN=3"
set "EXIT_POWERSHELL=4"
set "EXIT_INSTALLED=5"
set "EXIT_PATH=6"
set "EXIT_VERSION_SOURCE=7"
set "EXIT_DISPLAY_PATCH=8"
set "EXIT_DISPLAY_RESTORE=9"
set "EXIT_OMP_RUNNING=10"
set "EXIT_BUN_INSTALL=11"
set "EXIT_NATIVE_BUILD=12"
set "EXIT_CARGO=13"
set "EXIT_NATIVE_CLEAN=14"
set "EXIT_TYPECHECK=20"
set "EXIT_BUILD=30"
set "EXIT_BUILD_ARTIFACT=31"
set "EXIT_STAGE=40"
set "EXIT_BACKUP=41"
set "EXIT_REPLACE=42"
set "EXIT_VERIFY=50"
set "EXIT_START=51"
set "EXIT_FINAL_PATH=60"
set "EXIT_ROLLBACK=90"

echo.
echo ============================================================
echo OMP Build und sichere Installation
echo ============================================================
echo Repo:      %REPO%
echo Install:   %INSTALLED%
echo.

rem ============================================================
rem PRE-FLIGHT
rem ============================================================

if not defined LOCALAPPDATA (
    echo [FEHLER] LOCALAPPDATA ist nicht gesetzt.
    exit /b %EXIT_INSTALLED%
)

if not exist "%REPO%\packages\coding-agent\package.json" (
    echo [FEHLER] install.bat liegt nicht im Root eines gueltigen oh-my-pi Repositories.
    echo Erwartet:
    echo   %REPO%\packages\coding-agent\package.json
    exit /b %EXIT_REPO%
)

if not exist "%VERSION_FILE%" (
    echo [FEHLER] OMP-Versionsdatei wurde nicht gefunden:
    echo   %VERSION_FILE%
    exit /b %EXIT_VERSION_SOURCE%
)

if not exist "%CLI_FILE%" (
    echo [FEHLER] OMP-CLI-Quelldatei wurde nicht gefunden:
    echo   %CLI_FILE%
    exit /b %EXIT_DISPLAY_PATCH%
)

where.exe bun >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] bun wurde nicht im PATH gefunden.
    exit /b %EXIT_BUN%
)

call bun --version >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] bun wurde gefunden, konnte aber nicht erfolgreich gestartet werden.
    exit /b %EXIT_BUN%
)

where.exe cargo.exe >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] cargo wurde nicht im PATH gefunden.
    exit /b %EXIT_CARGO%
)

call cargo --version >nul 2>&1
if errorlevel 1 (
    echo [FEHLER] cargo wurde gefunden, konnte aber nicht erfolgreich gestartet werden.
    exit /b %EXIT_CARGO%
)

where.exe pwsh.exe >nul 2>&1
if not errorlevel 1 (
    set "PS_EXE=pwsh.exe"
) else (
    where.exe powershell.exe >nul 2>&1
    if errorlevel 1 (
        echo [FEHLER] Weder pwsh.exe noch powershell.exe wurde gefunden.
        exit /b %EXIT_POWERSHELL%
    )
    set "PS_EXE=powershell.exe"
)

if not exist "%INSTALLED%" (
    echo [FEHLER] Die aktuell installierte OMP-Binary wurde nicht gefunden:
    echo   %INSTALLED%
    exit /b %EXIT_INSTALLED%
)

rem Verify that "omp" in PATH is really the binary we are about to replace.
set "OMP_EXPECTED=%INSTALLED%"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $expected=[IO.Path]::GetFullPath($env:OMP_EXPECTED); $cmd=Get-Command omp.exe -CommandType Application -ErrorAction Stop; $actual=[IO.Path]::GetFullPath($cmd.Source); if(-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)){ Write-Error ('PATH zeigt auf ein anderes OMP: ' + $actual + ' ; erwartet: ' + $expected); exit 1 }"
if errorlevel 1 (
    echo [FEHLER] Das ueber PATH aufgeloeste omp.exe stimmt nicht mit dem Installationsziel ueberein.
    echo Installation wurde NICHT veraendert.
    exit /b %EXIT_PATH%
)

call :EnsureOmpStopped
if errorlevel 1 (
    exit /b %EXIT_OMP_RUNNING%
)

pushd "%REPO%"
if errorlevel 1 (
    echo [FEHLER] Wechsel in das Repository ist fehlgeschlagen:
    echo   %REPO%
    exit /b %EXIT_REPO%
)

rem ============================================================
rem 1. ENSURE INTERNAL VERSION IS CLEAN/OFFICIAL
rem ============================================================

echo.
echo [1/12] Interne OMP-Version pruefen...

call :EnsureInternalVersionClean
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] Die interne VERSION konnte nicht sicher auf der offiziellen Form gehalten werden.
    popd
    exit /b %EXIT_VERSION_SOURCE%
)

rem ============================================================
rem 2. SYNC DEPENDENCIES FOR THE CURRENT BRANCH
rem ============================================================

echo.
echo [2/12] Dependencies fuer den aktuellen Branch synchronisieren...
call bun install
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] bun install ist fehlgeschlagen. Exit-Code: %CMD_RC%
    echo Build und Installation werden abgebrochen.
    popd
    exit /b %EXIT_BUN_INSTALL%
)

rem ============================================================
rem 3. CLEAN + BUILD NATIVE COMPONENTS FOR THE CURRENT BRANCH
rem ============================================================

echo.
echo [3/12] Native OMP-Komponenten vollstaendig sauber neu bauen...

rem Force the same native Cargo profile that is cleaned below. setlocal at the
rem top of this script keeps these overrides local to this install.bat process.
set "OMP_NATIVE_CARGO_PROFILE=local"
set "CARGO_INCREMENTAL=0"

echo Native Cargo-Profil: %OMP_NATIVE_CARGO_PROFILE%
echo Cargo Incremental:   %CARGO_INCREMENTAL%
echo Alte Cargo-Artefakte fuer x86_64-pc-windows-msvc/local entfernen...
call cargo clean --target x86_64-pc-windows-msvc --profile local
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] cargo clean fuer das lokale Windows-Native-Profil ist fehlgeschlagen. Exit-Code: %CMD_RC%
    echo Build und Installation werden abgebrochen.
    popd
    exit /b %EXIT_NATIVE_CLEAN%
)

echo Native OMP-Komponenten fuer den aktuellen Branch bauen...
call bun run build:native
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] build:native ist fehlgeschlagen. Exit-Code: %CMD_RC%
    echo Build und Installation werden abgebrochen.
    popd
    exit /b %EXIT_NATIVE_BUILD%
)

rem ============================================================
rem 4. TEMPORARY DISPLAY-ONLY +local-git PATCH
rem ============================================================

echo.
echo [4/12] Temporaere +local-git Anzeige vorbereiten...

call :PrepareDisplayPatch
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] Die temporaere +local-git Anzeige konnte nicht sicher vorbereitet werden.
    popd
    exit /b %EXIT_DISPLAY_PATCH%
)

rem ============================================================
rem 5. TYPECHECK
rem ============================================================

echo.
echo [5/12] TypeScript-Pruefung...
call bun --cwd=packages/coding-agent run check:types
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo.
    echo [FEHLER] check:types ist fehlgeschlagen. Exit-Code: %CMD_RC%
    call :RestoreDisplaySource
    if errorlevel 1 (
        echo [KRITISCHER FEHLER] cli.ts konnte nach dem Typecheck-Fehler nicht automatisch wiederhergestellt werden.
        echo Backup:
        echo   %CLI_BACKUP%
        popd
        exit /b %EXIT_DISPLAY_RESTORE%
    )
    echo CLI-Source wurde wiederhergestellt.
    popd
    exit /b %EXIT_TYPECHECK%
)

rem ============================================================
rem 6. REMOVE OLD BUILD ARTIFACTS
rem ============================================================

echo.
echo [6/12] Alte Build-Artefakte entfernen...

if exist "%BUILD_EXE%" (
    del /f /q "%BUILD_EXE%" >nul 2>&1
    if errorlevel 1 (
        echo [FEHLER] Altes Build-Artefakt konnte nicht geloescht werden:
        echo   %BUILD_EXE%
        call :RestoreDisplaySource
        if errorlevel 1 (
            echo [KRITISCHER FEHLER] cli.ts konnte nicht automatisch wiederhergestellt werden.
            echo Backup:
            echo   %CLI_BACKUP%
            popd
            exit /b %EXIT_DISPLAY_RESTORE%
        )
        popd
        exit /b %EXIT_BUILD_ARTIFACT%
    )
)

if exist "%BUILD_NOEXT%" (
    del /f /q "%BUILD_NOEXT%" >nul 2>&1
    if errorlevel 1 (
        echo [FEHLER] Altes Build-Artefakt konnte nicht geloescht werden:
        echo   %BUILD_NOEXT%
        call :RestoreDisplaySource
        if errorlevel 1 (
            echo [KRITISCHER FEHLER] cli.ts konnte nicht automatisch wiederhergestellt werden.
            echo Backup:
            echo   %CLI_BACKUP%
            popd
            exit /b %EXIT_DISPLAY_RESTORE%
        )
        popd
        exit /b %EXIT_BUILD_ARTIFACT%
    )
)

rem ============================================================
rem 7. BUILD + UNCONDITIONAL SOURCE RESTORE
rem ============================================================

echo.
echo [7/12] OMP-Binary bauen...
call bun --cwd=packages/coding-agent run build
set "BUILD_RC=%ERRORLEVEL%"

echo.
echo Temporaere Anzeige-Aenderung rueckgaengig machen...
call :RestoreDisplaySource
set "RESTORE_RC=%ERRORLEVEL%"

if not "%RESTORE_RC%"=="0" (
    echo.
    echo [KRITISCHER FEHLER] cli.ts konnte nach dem Build nicht automatisch wiederhergestellt werden.
    echo Die Installation wird NICHT fortgesetzt.
    echo Sicherungsdatei:
    echo   %CLI_BACKUP%
    popd
    exit /b %EXIT_DISPLAY_RESTORE%
)

echo CLI-Source erfolgreich byte-identisch wiederhergestellt.

if not "%BUILD_RC%"=="0" (
    echo.
    echo [FEHLER] Build ist fehlgeschlagen. Exit-Code: %BUILD_RC%
    echo Installation wurde NICHT veraendert.
    popd
    exit /b %EXIT_BUILD%
)

rem ============================================================
rem 8. VALIDATE NEW BUILD
rem ============================================================

echo.
echo [8/12] Neue OMP-Binary validieren...

set "BUILT="

if exist "%BUILD_EXE%" set "BUILT=%BUILD_EXE%"

if exist "%BUILD_NOEXT%" (
    if defined BUILT (
        echo [FEHLER] Mehrere Build-Artefakte gefunden:
        echo   %BUILD_EXE%
        echo   %BUILD_NOEXT%
        echo Auswahl waere mehrdeutig. Installation abgebrochen.
        popd
        exit /b %EXIT_BUILD_ARTIFACT%
    )
    set "BUILT=%BUILD_NOEXT%"
)

if not defined BUILT (
    echo [FEHLER] Build meldete Erfolg, aber es wurde keine neue OMP-Binary gefunden.
    echo Erwartet:
    echo   %BUILD_EXE%
    echo oder:
    echo   %BUILD_NOEXT%
    popd
    exit /b %EXIT_BUILD_ARTIFACT%
)

for %%I in ("%BUILT%") do (
    if %%~zI LEQ 0 (
        echo [FEHLER] Die gebaute Binary ist leer:
        echo   %BUILT%
        popd
        exit /b %EXIT_BUILD_ARTIFACT%
    )
)

echo.
echo Neue Binary:
echo   %BUILT%
for %%I in ("%BUILT%") do echo   Groesse: %%~zI Bytes

rem Test display version. Internal VERSION was not modified.
set "OMP_BUILT=%BUILT%"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; if([string]::IsNullOrWhiteSpace($env:OMP_BUILT)){ throw 'OMP_BUILT ist leer.' }; if(-not (Test-Path -LiteralPath $env:OMP_BUILT -PathType Leaf)){ throw ('Build-Binary fehlt: ' + $env:OMP_BUILT) }; $out=@(& $env:OMP_BUILT --version 2>&1); $code=$LASTEXITCODE; $out | ForEach-Object { Write-Host $_ }; if($code -ne 0){ exit $code }; $match=@($out | Where-Object { [string]$_ -match '^omp/.+\+local-git$' }); if($match.Count -ne 1){ throw 'Build enthaelt nicht genau eine erwartete +local-git Versionszeile.' }"
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo [FEHLER] Die neu gebaute OMP-Binary hat den Versions-/Starttest nicht bestanden.
    echo Installation wurde NICHT veraendert.
    popd
    exit /b %EXIT_BUILD_ARTIFACT%
)

rem ============================================================
rem 9. PREPARE STAGING + VERIFIED BACKUP
rem ============================================================

echo.
echo [9/12] Staging und Backup vorbereiten...

set "STAMP="
for /f "delims=" %%T in ('%PS_EXE% -NoLogo -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmssfff"') do set "STAMP=%%T"

if not defined STAMP (
    echo [FEHLER] Zeitstempel fuer Backup konnte nicht erzeugt werden.
    popd
    exit /b %EXIT_BACKUP%
)

set "BACKUP=%INSTALLED%.backup-%STAMP%"
set "TEMP_INSTALL=%INSTALLED%.new-%STAMP%"
set "REPLACE_BACKUP=%INSTALLED%.replace-backup-%STAMP%"

set "OMP_INSTALLED=%INSTALLED%"
set "OMP_BACKUP=%BACKUP%"
set "OMP_TEMP=%TEMP_INSTALL%"
set "OMP_REPLACE_BACKUP=%REPLACE_BACKUP%"
set "OMP_BUILT=%BUILT%"

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; foreach($name in 'OMP_INSTALLED','OMP_BACKUP','OMP_TEMP','OMP_REPLACE_BACKUP','OMP_BUILT'){ $v=[Environment]::GetEnvironmentVariable($name); if([string]::IsNullOrWhiteSpace($v)){ throw ('Pfadvariable ist leer: ' + $name) } }; if(-not (Test-Path -LiteralPath $env:OMP_INSTALLED -PathType Leaf)){ throw ('Installierte Binary fehlt: ' + $env:OMP_INSTALLED) }; if(-not (Test-Path -LiteralPath $env:OMP_BUILT -PathType Leaf)){ throw ('Build-Binary fehlt: ' + $env:OMP_BUILT) }"
if errorlevel 1 (
    echo [FEHLER] Interne Pfadvalidierung ist fehlgeschlagen.
    popd
    exit /b %EXIT_STAGE%
)

copy /y /b "%BUILT%" "%TEMP_INSTALL%" >nul
if errorlevel 1 (
    echo [FEHLER] Staging-Kopie konnte nicht erstellt werden:
    echo   %TEMP_INSTALL%
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_STAGE%
)

call :CompareHash "%BUILT%" "%TEMP_INSTALL%"
if errorlevel 1 (
    echo [FEHLER] SHA256 der Staging-Kopie stimmt nicht mit dem Build ueberein.
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_STAGE%
)

copy /y /b "%INSTALLED%" "%BACKUP%" >nul
if errorlevel 1 (
    echo [FEHLER] Backup konnte nicht erstellt werden:
    echo   %BACKUP%
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_BACKUP%
)

call :CompareHash "%INSTALLED%" "%BACKUP%"
if errorlevel 1 (
    echo [FEHLER] Backup wurde erstellt, ist aber nicht bit-identisch mit der installierten Binary.
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_BACKUP%
)

echo Backup:
echo   %BACKUP%

call :EnsureOmpStopped
if errorlevel 1 (
    echo Installation wurde NICHT veraendert.
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_OMP_RUNNING%
)

rem ============================================================
rem 10. REPLACE INSTALLED BINARY
rem ============================================================

echo.
echo [10/12] Installierte OMP-Binary ersetzen...

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; foreach($name in 'OMP_TEMP','OMP_INSTALLED','OMP_REPLACE_BACKUP'){ $v=[Environment]::GetEnvironmentVariable($name); if([string]::IsNullOrWhiteSpace($v)){ throw ('File.Replace-Pfadvariable ist leer: ' + $name) } }; if(-not (Test-Path -LiteralPath $env:OMP_TEMP -PathType Leaf)){ throw ('Staging-Binary fehlt: ' + $env:OMP_TEMP) }; if(-not (Test-Path -LiteralPath $env:OMP_INSTALLED -PathType Leaf)){ throw ('Ziel-Binary fehlt: ' + $env:OMP_INSTALLED) }; [IO.File]::Replace($env:OMP_TEMP,$env:OMP_INSTALLED,$env:OMP_REPLACE_BACKUP,$true); if(-not (Test-Path -LiteralPath $env:OMP_INSTALLED -PathType Leaf)){ throw 'Ziel-Binary fehlt nach File.Replace.' }; if(-not (Test-Path -LiteralPath $env:OMP_REPLACE_BACKUP -PathType Leaf)){ throw 'File.Replace hat keine Sicherung der ersetzten Datei erzeugt.' }"
set "CMD_RC=%ERRORLEVEL%"

if not "%CMD_RC%"=="0" (
    echo [FEHLER] Ersetzen der installierten Binary ist fehlgeschlagen. Exit-Code: %CMD_RC%
    set "FAILCODE=%EXIT_REPLACE%"
    goto :ROLLBACK
)

call :CompareHash "%BACKUP%" "%REPLACE_BACKUP%"
if errorlevel 1 (
    echo [FEHLER] Die von File.Replace erzeugte Sicherung stimmt nicht mit dem verifizierten Backup ueberein.
    set "FAILCODE=%EXIT_REPLACE%"
    goto :ROLLBACK
)

rem ============================================================
rem 11. VERIFY INSTALLED CONTENT
rem ============================================================

echo.
echo [11/12] SHA256 der Installation verifizieren...

call :CompareHash "%BUILT%" "%INSTALLED%"
if errorlevel 1 (
    echo [FEHLER] Installierte Binary ist nicht bit-identisch mit dem Build.
    set "FAILCODE=%EXIT_VERIFY%"
    goto :ROLLBACK
)

echo SHA256-Verifikation: OK

rem ============================================================
rem 12. START + DISPLAY VERSION + PATH VERIFICATION
rem ============================================================

echo.
echo [12/12] Installierte Binary starten, Anzeige-Version und PATH pruefen...

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; if([string]::IsNullOrWhiteSpace($env:OMP_INSTALLED)){ throw 'OMP_INSTALLED ist leer.' }; $out=@(& $env:OMP_INSTALLED --version 2>&1); $code=$LASTEXITCODE; $out | ForEach-Object { Write-Host $_ }; if($code -ne 0){ exit $code }; $match=@($out | Where-Object { [string]$_ -match '^omp/.+\+local-git$' }); if($match.Count -ne 1){ throw 'Installierte Binary enthaelt nicht genau eine erwartete +local-git Versionszeile.' }"
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo [FEHLER] Die installierte OMP-Binary hat den Anzeige-Versions-/Starttest nicht bestanden. Exit-Code: %CMD_RC%
    set "FAILCODE=%EXIT_START%"
    goto :ROLLBACK
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $expected=[IO.Path]::GetFullPath($env:OMP_INSTALLED); $cmd=Get-Command omp.exe -CommandType Application -ErrorAction Stop; $actual=[IO.Path]::GetFullPath($cmd.Source); if(-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)){ Write-Error ('PATH zeigt nach Installation auf: ' + $actual + ' ; erwartet: ' + $expected); exit 1 }"
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo [FEHLER] PATH-Verifikation ist fehlgeschlagen.
    echo Die neue Binary selbst wurde erfolgreich installiert und gestartet.
    echo Ein Rollback wuerde den PATH-Fehler nicht beheben und wird deshalb NICHT ausgefuehrt.
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_FINAL_PATH%
)

where.exe omp
if errorlevel 1 (
    echo [FEHLER] where.exe konnte omp nach der Installation nicht aufloesen.
    echo Die neue Binary selbst wurde erfolgreich installiert und gestartet.
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_FINAL_PATH%
)

call :CleanupInstallTransient

echo.
echo ============================================================
echo Installation erfolgreich abgeschlossen.
echo ============================================================
echo Installiert:
echo   %INSTALLED%
echo Permanentes Binary-Backup:
echo   %BACKUP%
echo.
echo Interne OMP-Version blieb unveraendert/offiziell.
echo Nur die VersionsANZEIGE der lokalen Binary traegt:
echo   +local-git
echo.

popd
exit /b 0


rem ============================================================
rem HELPER: Ensure internal VERSION stays official
rem
rem Clean upstream form:
rem   export const VERSION: string = version;
rem
rem Old installer leftovers are safely normalized:
rem   export const VERSION: string = `${version}-local-git`;
rem   export const VERSION: string = `${version}+local-git`;
rem
rem Any other VERSION declaration fails closed.
rem ============================================================

:EnsureInternalVersionClean

set "OMP_VERSION_FILE=%VERSION_FILE%"

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $file=$env:OMP_VERSION_FILE; $clean='export const VERSION: string = version;'; $oldMinus='export const VERSION: string = `${version}-local-git`;'; $oldPlus='export const VERSION: string = `${version}+local-git`;'; $pattern='(?m)^(?<indent>[ \t]*)export const VERSION: string = [^\r\n]*;[ \t]*$'; if([string]::IsNullOrWhiteSpace($file)){ throw 'OMP_VERSION_FILE ist leer.' }; if(-not (Test-Path -LiteralPath $file -PathType Leaf)){ throw ('Versionsdatei fehlt: ' + $file) }; $text=[IO.File]::ReadAllText($file); $matches=@([regex]::Matches($text,$pattern)); if($matches.Count -ne 1){ throw ('Erwartet genau eine VERSION-Deklaration, gefunden: ' + $matches.Count) }; $m=$matches[0]; $current=$m.Value.Trim(); if($current -eq $clean){ Write-Host ('Interne VERSION ist sauber: ' + $clean) -ForegroundColor Green; exit 0 }; if($current -ne $oldMinus -and $current -ne $oldPlus){ throw ('Unerwartete VERSION-Deklaration; keine automatische Aenderung: ' + $current) }; Write-Host ('Alte persistente Local-Markierung wird entfernt: ' + $current) -ForegroundColor Yellow; $replacement=$m.Groups['indent'].Value+$clean; $newText=$text.Substring(0,$m.Index)+$replacement+$text.Substring($m.Index+$m.Length); $bytes=[IO.File]::ReadAllBytes($file); $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF; $enc=[Text.UTF8Encoding]::new($hasBom); $tmp=$file+'.normalize-'+[Guid]::NewGuid().ToString('N'); $bak=$file+'.normalize-backup-'+[Guid]::NewGuid().ToString('N'); try { [IO.File]::WriteAllText($tmp,$newText,$enc); [IO.File]::Replace($tmp,$file,$bak,$true); $verify=[IO.File]::ReadAllText($file); $vm=@([regex]::Matches($verify,$pattern)); if($vm.Count -ne 1 -or $vm[0].Value.Trim() -ne $clean){ throw 'Normalisierung der internen VERSION konnte nicht verifiziert werden.' }; if(Test-Path -LiteralPath $bak){ Remove-Item -LiteralPath $bak -Force -ErrorAction Stop }; Write-Host ('Interne VERSION normalisiert: ' + $clean) -ForegroundColor Green } catch { if(Test-Path -LiteralPath $bak){ Copy-Item -LiteralPath $bak -Destination $file -Force -ErrorAction SilentlyContinue }; throw } finally { if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; if(Test-Path -LiteralPath $bak){ Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } }"
exit /b %ERRORLEVEL%


rem ============================================================
rem HELPER: Prepare temporary display-only +local-git patch
rem
rem Only two display call sites are changed:
rem 1) Startup/TUI header
rem 2) CLI --version output
rem
rem Internal VERSION and update comparison logic are NOT changed.
rem ============================================================

:PrepareDisplayPatch

set "OMP_CLI_FILE=%CLI_FILE%"
set "OMP_CLI_BACKUP=%CLI_BACKUP%"
set "OMP_CLI_TEMP=%CLI_TEMP%"
set "OMP_CLI_REPLACE_BACKUP=%CLI_REPLACE_BACKUP%"

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $file=$env:OMP_CLI_FILE; $backup=$env:OMP_CLI_BACKUP; $tmp=$env:OMP_CLI_TEMP; $replaceBackup=$env:OMP_CLI_REPLACE_BACKUP; $orig1='beginStartupComposer({ version: VERSION });'; $patch1='beginStartupComposer({ version: `${VERSION}+local-git` });'; $orig2='await run({ bin: APP_NAME, version: VERSION, argv: resolved.argv, commands, metadataHelp: showHelp });'; $patch2='await run({ bin: APP_NAME, version: `${VERSION}+local-git`, argv: resolved.argv, commands, metadataHelp: showHelp });'; function Count([string]$text,[string]$needle){ if($needle.Length -eq 0){ return 0 }; $n=0; $p=0; while(($i=$text.IndexOf($needle,$p,[StringComparison]::Ordinal)) -ge 0){ $n++; $p=$i+$needle.Length }; return $n }; function Get-Utf8([string]$p){ $b=[IO.File]::ReadAllBytes($p); $bom=$b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF; return [Text.UTF8Encoding]::new($bom) }; if([string]::IsNullOrWhiteSpace($file) -or [string]::IsNullOrWhiteSpace($backup)){ throw 'Interner CLI-Pfad ist leer.' }; if(-not (Test-Path -LiteralPath $file -PathType Leaf)){ throw ('CLI-Datei fehlt: ' + $file) }; if(Test-Path -LiteralPath $backup -PathType Leaf){ Write-Host 'Stale CLI-Backup eines unterbrochenen Installer-Laufs gefunden - Source wird zuerst wiederhergestellt.' -ForegroundColor Yellow; $expected=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash; Copy-Item -LiteralPath $backup -Destination $tmp -Force; $staged=(Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash; if($expected -ne $staged){ throw 'Stale CLI-Backup konnte nicht sicher gestaged werden.' }; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; [IO.File]::Replace($tmp,$file,$replaceBackup,$true); $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; if($expected -ne $actual){ throw 'Recovery aus stale CLI-Backup hat falschen SHA256.' }; Remove-Item -LiteralPath $backup -Force; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; Write-Host 'CLI-Source-Recovery erfolgreich.' -ForegroundColor Green }; $text=[IO.File]::ReadAllText($file); $o1=Count $text $orig1; $o2=Count $text $orig2; $p1=Count $text $patch1; $p2=Count $text $patch2; if($p1 -eq 1 -and $p2 -eq 1 -and $o1 -eq 0 -and $o2 -eq 0){ Write-Host 'Persistente alte Display-Patches werden vor dem neuen Build normalisiert.' -ForegroundColor Yellow; $text=$text.Replace($patch1,$orig1).Replace($patch2,$orig2); $bytes=[IO.File]::ReadAllBytes($file); $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF; [IO.File]::WriteAllText($tmp,$text,[Text.UTF8Encoding]::new($hasBom)); if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; [IO.File]::Replace($tmp,$file,$replaceBackup,$true); if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; $text=[IO.File]::ReadAllText($file); $o1=Count $text $orig1; $o2=Count $text $orig2; $p1=Count $text $patch1; $p2=Count $text $patch2 }; if($o1 -ne 1 -or $o2 -ne 1 -or $p1 -ne 0 -or $p2 -ne 0){ throw ('CLI-Struktur unerwartet. Treffer orig1/orig2/patch1/patch2 = ' + $o1 + '/' + $o2 + '/' + $p1 + '/' + $p2 + '. Aus Sicherheitsgruenden abgebrochen.') }; if(Test-Path -LiteralPath $backup){ throw ('CLI-Backup existiert unerwartet bereits: ' + $backup) }; Copy-Item -LiteralPath $file -Destination $backup -Force; $baseHash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; $backupHash=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash; if($baseHash -ne $backupHash){ throw 'Baseline-Backup von cli.ts ist nicht bit-identisch.' }; $patched=$text.Replace($orig1,$patch1).Replace($orig2,$patch2); $bytes=[IO.File]::ReadAllBytes($file); $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF; try { [IO.File]::WriteAllText($tmp,$patched,[Text.UTF8Encoding]::new($hasBom)); $verify=[IO.File]::ReadAllText($tmp); if((Count $verify $patch1) -ne 1 -or (Count $verify $patch2) -ne 1 -or (Count $verify $orig1) -ne 0 -or (Count $verify $orig2) -ne 0){ throw 'Temporaerer CLI-Display-Patch konnte vor Replace nicht verifiziert werden.' }; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; [IO.File]::Replace($tmp,$file,$replaceBackup,$true); $final=[IO.File]::ReadAllText($file); if((Count $final $patch1) -ne 1 -or (Count $final $patch2) -ne 1){ throw 'Temporaerer CLI-Display-Patch konnte nach Replace nicht verifiziert werden.' }; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; Write-Host 'Nur VersionsANZEIGE temporaer auf +local-git gesetzt.' -ForegroundColor Green } catch { try { if(Test-Path -LiteralPath $backup){ Copy-Item -LiteralPath $backup -Destination $file -Force } } catch {}; throw } finally { if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue } }"
exit /b %ERRORLEVEL%


rem ============================================================
rem HELPER: Restore cli.ts byte-identically
rem ============================================================

:RestoreDisplaySource

set "OMP_CLI_FILE=%CLI_FILE%"
set "OMP_CLI_BACKUP=%CLI_BACKUP%"
set "OMP_CLI_TEMP=%CLI_TEMP%"
set "OMP_CLI_REPLACE_BACKUP=%CLI_REPLACE_BACKUP%"

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $file=$env:OMP_CLI_FILE; $backup=$env:OMP_CLI_BACKUP; $tmp=$env:OMP_CLI_TEMP; $replaceBackup=$env:OMP_CLI_REPLACE_BACKUP; if(-not (Test-Path -LiteralPath $backup -PathType Leaf)){ throw ('CLI-Backup fehlt: ' + $backup) }; if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force }; Copy-Item -LiteralPath $backup -Destination $tmp -Force; $expected=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash; $staged=(Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash; if($expected -ne $staged){ throw 'Restore-Staging ist nicht bit-identisch mit dem CLI-Backup.' }; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; [IO.File]::Replace($tmp,$file,$replaceBackup,$true); $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; if($expected -ne $actual){ throw 'Wiederhergestellte cli.ts ist nicht bit-identisch mit dem Baseline-Backup.' }; Remove-Item -LiteralPath $backup -Force; if(Test-Path -LiteralPath $replaceBackup){ Remove-Item -LiteralPath $replaceBackup -Force }; if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force }; Write-Host 'cli.ts byte-identisch zur sauberen Baseline wiederhergestellt.' -ForegroundColor Green"
exit /b %ERRORLEVEL%


rem ============================================================
rem ROLLBACK installed OMP binary
rem ============================================================

:ROLLBACK
echo.
echo ============================================================
echo ROLLBACK
echo ============================================================
echo Wiederherstellung aus:
echo   %BACKUP%

if not exist "%BACKUP%" (
    echo [KRITISCHER FEHLER] Backup fehlt. Automatischer Rollback ist nicht moeglich.
    echo Ziel:
    echo   %INSTALLED%
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_ROLLBACK%
)

copy /y /b "%BACKUP%" "%INSTALLED%" >nul
set "CMD_RC=%ERRORLEVEL%"
if not "%CMD_RC%"=="0" (
    echo [KRITISCHER FEHLER] Backup konnte nicht zurueckkopiert werden. Exit-Code: %CMD_RC%
    echo Backup:
    echo   %BACKUP%
    echo Ziel:
    echo   %INSTALLED%
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_ROLLBACK%
)

call :CompareHash "%BACKUP%" "%INSTALLED%"
if errorlevel 1 (
    echo [KRITISCHER FEHLER] Rollback-Datei wurde kopiert, aber SHA256 stimmt nicht.
    echo Backup:
    echo   %BACKUP%
    echo Ziel:
    echo   %INSTALLED%
    call :CleanupInstallTransient
    popd
    exit /b %EXIT_ROLLBACK%
)

call :CleanupInstallTransient

echo Rollback erfolgreich. Die vorherige OMP-Binary wurde wiederhergestellt.
echo Urspruenglicher Fehlercode: %FAILCODE%
echo.
popd
exit /b %FAILCODE%


rem ============================================================
rem HELPER: Ensure no omp.exe process is running
rem ============================================================

:EnsureOmpStopped
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=@(Get-Process -Name omp -ErrorAction SilentlyContinue); if($p.Count -gt 0){ Write-Host '[FEHLER] OMP laeuft noch:' -ForegroundColor Red; $p | Format-Table Id,ProcessName,Path -AutoSize; exit 1 }; exit 0"
if errorlevel 1 (
    echo Bitte alle OMP-Sessions beenden und install.bat erneut starten.
    exit /b 1
)
exit /b 0


rem ============================================================
rem HELPER: Compare SHA256 of two files
rem ============================================================

:CompareHash
set "HASH_A=%~1"
set "HASH_B=%~2"

if not exist "%HASH_A%" (
    echo [FEHLER] Hash-Quelldatei fehlt:
    echo   %HASH_A%
    exit /b 1
)

if not exist "%HASH_B%" (
    echo [FEHLER] Hash-Zieldatei fehlt:
    echo   %HASH_B%
    exit /b 1
)

set "OMP_HASH_A=%HASH_A%"
set "OMP_HASH_B=%HASH_B%"

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $a=(Get-FileHash -LiteralPath $env:OMP_HASH_A -Algorithm SHA256).Hash; $b=(Get-FileHash -LiteralPath $env:OMP_HASH_B -Algorithm SHA256).Hash; if($a -ne $b){ Write-Error ('SHA256 mismatch: ' + $a + ' != ' + $b); exit 1 }; exit 0"
exit /b %ERRORLEVEL%


rem ============================================================
rem HELPER: Remove transient binary install files
rem Permanent %BACKUP% is deliberately never deleted here.
rem ============================================================

:CleanupInstallTransient
if defined TEMP_INSTALL (
    if exist "%TEMP_INSTALL%" (
        del /f /q "%TEMP_INSTALL%" >nul 2>&1
        if errorlevel 1 (
            echo [WARNUNG] Temporaere Staging-Datei konnte nicht geloescht werden:
            echo   %TEMP_INSTALL%
        )
    )
)

if defined REPLACE_BACKUP (
    if exist "%REPLACE_BACKUP%" (
        del /f /q "%REPLACE_BACKUP%" >nul 2>&1
        if errorlevel 1 (
            echo [WARNUNG] Temporaeres File.Replace-Backup konnte nicht geloescht werden:
            echo   %REPLACE_BACKUP%
        )
    )
)

exit /b 0
