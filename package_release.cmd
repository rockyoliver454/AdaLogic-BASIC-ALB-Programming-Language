@echo off
rem package_release.cmd — build a fully self-contained ALB_Release folder.
rem Nothing here is committed to git; this assembles the "thicc" drop.
rem Usage: package_release.cmd [outdir]   (default D:\ALB_Release)
setlocal enabledelayedexpansion

set "REPO=%~dp0"
set "OUT=%~1"
if "%OUT%"=="" set "OUT=D:\ALB_Release"
set "DEPS=C:\ALB\deps"
set "STAGE=%OUT%\_stage"
set "ZIP=%OUT%.zip"

echo === ALB Release Packager ===
echo Output: %OUT%

rmdir /s /q "%OUT%" 2>nul
mkdir "%OUT%\bin" "%OUT%\config" "%OUT%\stdlib" "%OUT%\support" "%OUT%\models" "%OUT%\agent" "%OUT%\tools" "%OUT%\docs" "%OUT%\examples" "%OUT%\deps" "%OUT%\tmp"

echo [1/6] Compiler binaries ...
robocopy "%REPO%sdk\bin"    "%OUT%\bin"    /E /NFL /NDL /NJH /NJS >nul
robocopy "%REPO%sdk\config" "%OUT%\config" /E /NFL /NDL /NJH /NJS >nul
robocopy "%REPO%sdk\support" "%OUT%\support" /E /NFL /NDL /NJH /NJS >nul

echo [2/6] albagent + models ...
robocopy "%REPO%sdk\models" "%OUT%\models" /E /NFL /NDL /NJH /NJS >nul
robocopy "%REPO%sdk\agent"  "%OUT%\agent"  /E /NFL /NDL /NJH /NJS >nul

echo [3/6] stdlib headers + examples + docs ...
robocopy "%REPO%sdk\stdlib" "%OUT%\stdlib" /E /NFL /NDL /NJH /NJS >nul
robocopy "%REPO%examples"   "%OUT%\examples" /E /NFL /NDL /NJH /NJS /XF *_build >nul
robocopy "%REPO%tools"      "%OUT%\tools"  /E /NFL /NDL /NJH /NJS /XD __pycache__ *_build >nul
robocopy "%REPO%docs"       "%OUT%\docs"   /E /NFL /NDL /NJH /NJS >nul
copy /y "%REPO%.albproj" "%OUT%\" >nul
copy /y "%REPO%SWARM_HANDOFF.md" "%OUT%\" >nul 2>&1
copy /y "%REPO%CHANGELOG.md" "%OUT%\" >nul 2>&1
copy /y "%REPO%README.md" "%OUT%\" >nul

echo [4/6] Heavy deps (gnat, gprbuild, w64devkit, FASM, python, node) ...
if exist "%DEPS%" (
    for %%D in (gnat_native_15.2.1 gprbuild_25.0.1 w64devkit FASM python node) do (
        if exist "%DEPS%\%%D" (
            echo   - %%D
            robocopy "%DEPS%\%%D" "%OUT%\deps\%%D" /E /NFL /NDL /NJH /NJS >nul
        )
    )
) else (
    echo   WARN: %DEPS% not found — release will lack bundled toolchains
)

echo [5/6] Root shim: alb.cmd ...
(
echo @echo off
echo rem ALB entry point — zero-setup wrapper
echo set "ALB_HOME=%%~dp0"
echo set "PATH=%%ALB_HOME%%bin;%%ALB_HOME%%deps\gnat_native_15.2.1\bin;%%ALB_HOME%%deps\gprbuild_25.0.1\bin;%%ALB_HOME%%deps\w64devkit\bin;%%PATH%%"
echo "%%ALB_HOME%%bin\albt.exe" %%*
) > "%OUT%\alb.cmd"

echo [6/6] Compressing to %ZIP% ...
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath '%ZIP%' -Force -CompressionLevel Optimal" && echo Wrote %ZIP%

echo === Release staged at %OUT% ===
