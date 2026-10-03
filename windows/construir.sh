#!/bin/sh
# Arma el programa de Windows con el HTML actual. Uso: ./construir.sh 1.0.0.0
set -e
cd "$(dirname "$0")/app"
cp /home/claude/build/sistema-rave.html recursos/sistema-rave.html
/tmp/mkres/mkres ../icono.png rsrc_windows_amd64.syso "${1:-1.0.0.0}"
export GOPROXY=direct GOSUMDB=off GOFLAGS=-mod=mod
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-H windowsgui -s -w" -o SistemaRAVE.exe .
cd ..
rm -rf paquete && mkdir -p "paquete/Sistema RAVE"
cp app/SistemaRAVE.exe "paquete/Sistema RAVE/Instalar Sistema RAVE.exe"
cp LEEME.txt "paquete/Sistema RAVE/LEEME.txt"
(cd paquete && rm -f ../RAVE-Windows.zip && zip -qr ../RAVE-Windows.zip "Sistema RAVE")
cp app/SistemaRAVE.exe Instalar-Sistema-RAVE.exe
ls -la RAVE-Windows.zip Instalar-Sistema-RAVE.exe
