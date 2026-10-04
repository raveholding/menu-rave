#!/bin/sh
# Arma el programa de Windows (64 y 32 bits) con el HTML actual. Uso: ./construir.sh 1.1.0.0
set -e
cd "$(dirname "$0")/app"
cp /home/claude/build/sistema-rave.html recursos/sistema-rave.html
export GOPROXY=direct GOSUMDB=off GOFLAGS=-mod=mod
rm -f rsrc_windows_*.syso
/tmp/mkres/mkres ../icono.png rsrc_windows_amd64.syso "${1:-1.1.0.0}" amd64
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-H windowsgui -s -w" -o SistemaRAVE.exe .
rm -f rsrc_windows_amd64.syso
/tmp/mkres/mkres ../icono.png rsrc_windows_386.syso "${1:-1.1.0.0}" 386
GOOS=windows GOARCH=386 go build -trimpath -ldflags "-H windowsgui -s -w" -o SistemaRAVE-32.exe .
rm -f rsrc_windows_386.syso
cd ..
rm -rf paquete && mkdir -p "paquete/Sistema RAVE"
cp app/SistemaRAVE.exe "paquete/Sistema RAVE/Instalar Sistema RAVE.exe"
cp app/SistemaRAVE-32.exe "paquete/Sistema RAVE/Instalar Sistema RAVE (PC de 32 bits).exe"
cp LEEME.txt "paquete/Sistema RAVE/LEEME.txt"
(cd paquete && rm -f ../RAVE-Windows.zip && zip -qr ../RAVE-Windows.zip "Sistema RAVE")
cp app/SistemaRAVE.exe Instalar-Sistema-RAVE.exe
cp app/SistemaRAVE-32.exe Instalar-Sistema-RAVE-32bits.exe
ls -la RAVE-Windows.zip Instalar-Sistema-RAVE*.exe
