@echo off
cd /d "%~dp0"
title AYZE - SERVIDOR LOCAL
py -c "import fastapi,uvicorn,sqlalchemy,dotenv,multipart,jinja2,itsdangerous" >nul 2>&1
if errorlevel 1 (
 echo Instalando dependencias...
 py -m pip install -r requirements.txt
 if errorlevel 1 (echo Falha na instalacao. & pause & exit /b 1)
)
echo.
echo PAINEL NO PC: http://127.0.0.1:8080/login
echo.
echo Mantenha esta janela aberta enquanto testa.
echo.
py app.py
pause
