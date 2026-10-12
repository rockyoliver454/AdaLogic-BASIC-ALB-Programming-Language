@echo off
rem Automated smoke test for the local albagent inference engine.
rem Verifies: binary present, accepts stdin, completes offline inference.
setlocal
set "BIN=%~dp0..\bin\albagent.exe"
set "MODEL=%~dp0..\models\alb_seq.albm"

if not exist "%BIN%" (echo FAIL: albagent.exe missing & exit /b 1)
if not exist "%MODEL%" (echo FAIL: model missing & exit /b 1)

echo LET x = 1 | "%BIN%" --model "%MODEL%" --context 8 > "%TEMP%\albagent_out.txt" 2>&1
findstr /C:"Engine complete" "%TEMP%\albagent_out.txt" >nul
if errorlevel 1 (
    echo FAIL: inference did not complete
    type "%TEMP%\albagent_out.txt"
    exit /b 1
)
echo PASS: albagent inference OK
exit /b 0
