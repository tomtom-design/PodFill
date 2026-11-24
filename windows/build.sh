#!/bin/bash
# Builds dist/PodFill-Windows.zip (PodFill.exe + README.txt) on macOS or Linux; CI does the same on Windows.
# Needs the .NET 10 SDK (dotnet on PATH, or a user-local install in ~/.dotnet).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v dotnet >/dev/null 2>&1 && [ -x "$HOME/.dotnet/dotnet" ]; then
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$DOTNET_ROOT:$PATH"
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

dotnet test PodFill.slnx

OUT=dist/publish
rm -rf "$OUT"
dotnet publish src/PodFill/PodFill.csproj -c Release -r win-x64 --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "$OUT"

mkdir -p dist
rm -f dist/PodFill-Windows.zip
zip -j -X dist/PodFill-Windows.zip "$OUT/PodFill.exe"
zip -j -X -l dist/PodFill-Windows.zip README.txt     # -l: CRLF line endings for Notepad
unzip -l dist/PodFill-Windows.zip
