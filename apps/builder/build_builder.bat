@echo off
rem Rebuilds "NexGrab Builder.exe" from builder\rsk_builder.py (only needed if you change the source).
cd /d "%~dp0"
py -3 -m venv .venv_builder || python -m venv .venv_builder
call .venv_builder\Scripts\python.exe -m pip install -q -U pip customtkinter pillow pyinstaller
call .venv_builder\Scripts\python.exe -m PyInstaller --noconfirm --clean --onefile --windowed --name "NexGrab Builder" --icon "..\pc\assets\nexgrab.ico" --add-data "..\pc\assets;assets" --collect-all customtkinter --hidden-import PIL._tkinter_finder rsk_builder.py
if exist "dist\NexGrab Builder.exe" copy /Y "dist\NexGrab Builder.exe" "..\NexGrab Builder.exe" >nul
echo Done: ..\NexGrab Builder.exe
pause
