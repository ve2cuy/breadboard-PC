@echo off
rem Simulateur de Solution-02 : serveur local puis navigateur (http://localhost:8088/)
cd /d "%~dp0"
python outils\serveur.py %*
