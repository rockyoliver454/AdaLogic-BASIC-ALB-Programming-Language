@echo off
rem Self-improvement loop: rebuild albagent from ai-experiment source,
rem deploy to sdk\bin, and smoke-test. Fully automated — no manual steps.
rem
rem Toolchain search order: ALB_AI_SRC / ALB_DEPS env vars,
rem sdk\deps\, C:\ALB\deps\, then PATH.
setlocal
set "ROOT=%~dp0.."

if "%ALB_AI_SRC%"=="" set "ALB_AI_SRC=H:\GNATSTUDIO\bin\ai-experiment"
if not exist "%ALB_AI_SRC%\ternary_ai.gpr" (
    echo FAIL: ai-experiment source not found at %ALB_AI_SRC%
    exit /b 1
)

set "DEPS="
for %%D in ("%ROOT%\deps" "C:\ALB\deps" "%ALB_DEPS%") do (
    if exist "%%~fD\gprbuild_25.0.1\bin\gprbuild.exe" set "DEPS=%%~fD"
)
if "%DEPS%"=="" (
    where gprbuild >nul 2>&1 || (echo FAIL: no gprbuild toolchain found & exit /b 1)
) else (
    set "PATH=%DEPS%\gnat_native_15.2.1\bin;%DEPS%\gprbuild_25.0.1\bin;%PATH%"
)

echo [1/3] Building ternary_ai in %ALB_AI_SRC% ...
pushd "%ALB_AI_SRC%"
gprbuild -P ternary_ai.gpr -p || (popd & echo FAIL: gprbuild & exit /b 1)
popd

echo [2/3] Deploying albagent.exe ...
copy /y "%ALB_AI_SRC%\bin\main.exe" "%ROOT%\bin\albagent.exe" >nul || (
    echo FAIL: main.exe not produced & exit /b 1)

echo [3/3] Smoke test ...
call "%~dp0test_albagent.cmd" || exit /b 1
echo DONE: albagent rebuilt, deployed, verified.
