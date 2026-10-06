// Sólo para pruebas: corre el agente real, pero "la impresora 192.168.1.50:9100"
// es en realidad FAKE_PRINTER (un servidor TCP local de la prueba).
package main

import (
	"net"
	"os"
	"time"

	"sistemarave/agente"
)

func main() {
	fake := os.Getenv("FAKE_PRINTER")
	archivo := os.Getenv("CODE_FILE")
	s := agente.Nuevo(agente.Config{
		Addr: "127.0.0.1:9101", Dir: os.Getenv("AGENT_DIR"), Origenes: []string{"null", "http://127.0.0.1:54399"},
		MostrarCodigo: func(c string) { _ = os.WriteFile(archivo, []byte(c), 0o600) },
		Dial: func(n, a string, d time.Duration) (net.Conn, error) {
			if a == "192.168.1.50:9100" {
				return net.DialTimeout("tcp", fake, d)
			}
			return nil, net.ErrClosed
		},
		Interfaces: func() ([]net.Addr, error) {
			_, nn, _ := net.ParseCIDR("192.168.1.10/24")
			return []net.Addr{&net.IPNet{IP: net.ParseIP("192.168.1.10"), Mask: nn.Mask}}, nil
		},
	})
	if err := s.Servir(); err != nil {
		os.Exit(1)
	}
}
