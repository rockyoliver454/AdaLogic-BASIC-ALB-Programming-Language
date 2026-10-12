@echo off
rem Swarm Attack — deploy the local AI swarm against a task file.
rem   swarm_attack.cmd backlog\task_01.md [--target path] [--retries N]
rem Needs Python with the `mcp` package (system python qualifies).
where python >nul 2>&1 && (python "%~dp0swarm_attack.py" %* & exit /b %errorlevel%)
"D:\.local\python\cpython-3.12.15-windows-x86_64-none\python.exe" "%~dp0swarm_attack.py" %*
