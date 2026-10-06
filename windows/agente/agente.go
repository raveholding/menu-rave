// Package agente: puente local entre Sistema RAVE (en el navegador) y las
// impresoras de red (Wi-Fi / LAN, puerto 9100).
//
// Seguridad (todo se verifica ACÁ, nunca se confía en el navegador):
//   - Sólo escucha en 127.0.0.1 y sólo acepta Host 127.0.0.1/localhost (anti DNS-rebinding).
//   - Sólo acepta orígenes de una lista permitida (el sistema instalado y la página oficial).
//   - Se vincula con un código de 6 dígitos que aparece en la pantalla de la PC y sirve una vez.
//   - Cada pedido va firmado (HMAC-SHA256) con fecha y número único: sin firma, vencido o repetido, se rechaza.
//   - Sólo imprime a IPs de red privada (10.x, 172.16-31.x, 192.168.x), puerto 9100, máximo 256 KB.
//   - Límite de pedidos por minuto y bloqueo si adivinan mal el código.
package agente

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	Version       = 1
	MaxCuerpo     = 400 * 1024 // JSON con base64
	MaxDatos      = 256 * 1024 // bytes ESC/POS
	VentanaFirma  = 120 * time.Second
	VidaCodigo    = 3 * time.Minute
	MaxPorMinuto  = 120
	PuertoImpresa = 9100
)

type Config struct {
	Addr          string   // "127.0.0.1:9101"
	Dir           string   // carpeta donde se guarda la clave vinculada
	Origenes      []string // orígenes permitidos (incluye "null" para file://)
	MostrarCodigo func(codigo string)
	// ConfirmarVinculo se llama ANTES de generar un código: muestra en la PC quién lo pide
	// (origen) y si ya había una vinculación. Si devuelve false, no se genera nada.
	// nil = se acepta (sólo pruebas).
	ConfirmarVinculo func(origen string, yaVinculado bool) bool
	Dial             func(network, addr string, timeout time.Duration) (net.Conn, error)
	Ahora            func() time.Time
	Interfaces       func() ([]net.Addr, error)
}

type Servidor struct {
	cfg      Config
	mu       sync.Mutex
	clave    []byte
	codigo   string
	codigoEn time.Time
	fallos   int
	bloqueo  time.Time
	ultCod   time.Time
	avisando bool // hay un cartel de vinculación abierto: no se apilan otros
	vistos   map[string]time.Time
	ventana  []time.Time
	hechos   map[string]time.Time // trabajos de impresión ya enviados (idempotencia)
}

func Nuevo(c Config) *Servidor {
	if c.Addr == "" {
		c.Addr = "127.0.0.1:9101"
	}
	if c.Ahora == nil {
		c.Ahora = time.Now
	}
	if c.Dial == nil {
		c.Dial = net.DialTimeout
	}
	if c.Interfaces == nil {
		c.Interfaces = net.InterfaceAddrs
	}
	s := &Servidor{cfg: c, vistos: map[string]time.Time{}, hechos: map[string]time.Time{}}
	s.cargarClave()
	return s
}

func (s *Servidor) archivoClave() string { return filepath.Join(s.cfg.Dir, "agente.key") }

func (s *Servidor) cargarClave() {
	if s.cfg.Dir == "" {
		return
	}
	b, err := os.ReadFile(s.archivoClave())
	if err != nil {
		return
	}
	k, err := hex.DecodeString(strings.TrimSpace(string(b)))
	if err == nil && len(k) == 32 {
		s.clave = k
	}
}

func (s *Servidor) guardarClave() error {
	if s.cfg.Dir == "" {
		return nil
	}
	if err := os.MkdirAll(s.cfg.Dir, 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.archivoClave(), []byte(hex.EncodeToString(s.clave)), 0o600)
}

// Servir escucha SOLO en loopback. Si el puerto ya está tomado (otra copia del agente) devuelve error.
func (s *Servidor) Servir() error {
	host, _, err := net.SplitHostPort(s.cfg.Addr)
	if err != nil || (host != "127.0.0.1" && host != "::1") {
		return errors.New("el agente sólo puede escuchar en 127.0.0.1")
	}
	ln, err := net.Listen("tcp", s.cfg.Addr)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 30 * time.Second, MaxHeaderBytes: 8 << 10}
	return srv.Serve(ln)
}

func (s *Servidor) puerto() string {
	_, p, _ := net.SplitHostPort(s.cfg.Addr)
	return p
}

func (s *Servidor) hostOK(h string) bool {
	p := s.puerto()
	return h == "127.0.0.1:"+p || h == "localhost:"+p
}

func (s *Servidor) origenOK(o string) bool {
	for _, x := range s.cfg.Origenes {
		if x == o {
			return true
		}
	}
	return false
}

func responder(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Servidor) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/hello", s.hello)
	mux.HandleFunc("/pair-start", s.pairStart)
	mux.HandleFunc("/pair", s.pair)
	mux.HandleFunc("/print", s.firmado(s.imprimir))
	mux.HandleFunc("/probe", s.firmado(s.probar))
	mux.HandleFunc("/scan", s.firmado(s.escanear))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.hostOK(r.Host) {
			responder(w, http.StatusForbidden, map[string]string{"error": "host no permitido"})
			return
		}
		o := r.Header.Get("Origin")
		if o != "" {
			if !s.origenOK(o) {
				responder(w, http.StatusForbidden, map[string]string{"error": "origen no permitido"})
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", o)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Rave-Ts, X-Rave-Id, X-Rave-Mac")
			w.Header().Set("Access-Control-Allow-Private-Network", "true")
			w.Header().Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, MaxCuerpo)
		mux.ServeHTTP(w, r)
	})
}

func (s *Servidor) hello(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	p := s.clave != nil
	s.mu.Unlock()
	responder(w, 200, map[string]interface{}{"app": "rave-agente", "v": Version, "pareado": p})
}

func codigo6() (string, error) {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	n := (uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])) % 1000000
	return fmt.Sprintf("%06d", n), nil
}

func (s *Servidor) pairStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		responder(w, 405, map[string]string{"error": "método"})
		return
	}
	s.mu.Lock()
	ahora := s.cfg.Ahora()
	if ahora.Before(s.bloqueo) {
		s.mu.Unlock()
		responder(w, 429, map[string]string{"error": "demasiados intentos: esperá unos minutos"})
		return
	}
	if ahora.Sub(s.ultCod) < 10*time.Second {
		s.mu.Unlock()
		responder(w, 429, map[string]string{"error": "esperá unos segundos"})
		return
	}
	if s.avisando {
		s.mu.Unlock()
		responder(w, 429, map[string]string{"error": "ya hay un pedido de vinculación en la pantalla de la PC"})
		return
	}
	s.avisando = true
	ya := s.clave != nil
	s.ultCod = ahora
	s.mu.Unlock()
	// la confirmación se hace SIN el candado tomado (es un cartel que espera a la persona)
	permitido := true
	if s.cfg.ConfirmarVinculo != nil {
		o := r.Header.Get("Origin")
		if o == "" {
			o = "(sin origen)"
		}
		permitido = s.cfg.ConfirmarVinculo(o, ya)
	}
	s.mu.Lock()
	s.avisando = false
	if !permitido {
		s.mu.Unlock()
		responder(w, 403, map[string]string{"error": "se rechazó la vinculación en la PC"})
		return
	}
	c, err := codigo6()
	if err != nil {
		s.mu.Unlock()
		responder(w, 500, map[string]string{"error": "sin aleatorio"})
		return
	}
	s.codigo, s.codigoEn, s.fallos = c, s.cfg.Ahora(), 0
	s.mu.Unlock()
	if s.cfg.MostrarCodigo != nil {
		go s.cfg.MostrarCodigo(c) // aparece SÓLO en la pantalla de la PC; no se devuelve por la red
	}
	responder(w, 200, map[string]bool{"ok": true})
}

func (s *Servidor) pair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		responder(w, 405, map[string]string{"error": "método"})
		return
	}
	var in struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		responder(w, 400, map[string]string{"error": "pedido inválido"})
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ahora := s.cfg.Ahora()
	if ahora.Before(s.bloqueo) {
		responder(w, 429, map[string]string{"error": "demasiados intentos: esperá unos minutos"})
		return
	}
	if s.codigo == "" || ahora.Sub(s.codigoEn) > VidaCodigo {
		s.codigo = ""
		responder(w, 400, map[string]string{"error": "el código venció: pedí uno nuevo"})
		return
	}
	if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(in.Code)), []byte(s.codigo)) != 1 {
		s.fallos++
		if s.fallos >= 5 {
			s.codigo = ""
			s.bloqueo = ahora.Add(5 * time.Minute)
		}
		responder(w, 401, map[string]string{"error": "código incorrecto"})
		return
	}
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		responder(w, 500, map[string]string{"error": "sin aleatorio"})
		return
	}
	s.clave, s.codigo = k, "" // el código sirve UNA sola vez
	if err := s.guardarClave(); err != nil {
		s.clave = nil
		responder(w, 500, map[string]string{"error": "no pude guardar la vinculación"})
		return
	}
	responder(w, 200, map[string]string{"key": base64.StdEncoding.EncodeToString(k)})
}

// Mac calcula la firma de un pedido. Es la misma cuenta que hace el navegador.
func Mac(clave []byte, ts, id, ruta string, cuerpo []byte) string {
	h := sha256.Sum256(cuerpo)
	m := hmac.New(sha256.New, clave)
	m.Write([]byte(ts + "\n" + id + "\n" + ruta + "\n" + hex.EncodeToString(h[:])))
	return hex.EncodeToString(m.Sum(nil))
}

func (s *Servidor) firmado(f func(http.ResponseWriter, *http.Request, []byte)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			responder(w, 405, map[string]string{"error": "método"})
			return
		}
		cuerpo, err := io.ReadAll(r.Body)
		if err != nil {
			responder(w, 413, map[string]string{"error": "pedido demasiado grande"})
			return
		}
		ts, id, mac := r.Header.Get("X-Rave-Ts"), r.Header.Get("X-Rave-Id"), r.Header.Get("X-Rave-Mac")
		if ts == "" || id == "" || mac == "" || len(id) > 80 {
			responder(w, 401, map[string]string{"error": "falta la firma"})
			return
		}
		ms, err := strconv.ParseInt(ts, 10, 64)
		if err != nil {
			responder(w, 401, map[string]string{"error": "fecha inválida"})
			return
		}
		s.mu.Lock()
		clave := s.clave
		ahora := s.cfg.Ahora()
		if clave == nil {
			s.mu.Unlock()
			responder(w, 401, map[string]string{"error": "el agente no está vinculado"})
			return
		}
		dif := ahora.Sub(time.UnixMilli(ms))
		if dif < -VentanaFirma || dif > VentanaFirma {
			s.mu.Unlock()
			responder(w, 401, map[string]string{"error": "pedido vencido (revisá la hora de la PC)"})
			return
		}
		esperado := Mac(clave, ts, id, r.URL.Path, cuerpo)
		if subtle.ConstantTimeCompare([]byte(esperado), []byte(strings.ToLower(mac))) != 1 {
			s.mu.Unlock()
			responder(w, 401, map[string]string{"error": "firma inválida"})
			return
		}
		for k, t := range s.vistos { // limpia lo vencido
			if ahora.Sub(t) > 2*VentanaFirma {
				delete(s.vistos, k)
			}
		}
		if _, rep := s.vistos[id]; rep {
			s.mu.Unlock()
			responder(w, 409, map[string]string{"error": "pedido repetido"})
			return
		}
		s.vistos[id] = ahora
		// tope de pedidos por minuto
		corte := ahora.Add(-time.Minute)
		n := s.ventana[:0]
		for _, t := range s.ventana {
			if t.After(corte) {
				n = append(n, t)
			}
		}
		s.ventana = n
		if len(s.ventana) >= MaxPorMinuto {
			s.mu.Unlock()
			responder(w, 429, map[string]string{"error": "demasiados pedidos"})
			return
		}
		s.ventana = append(s.ventana, ahora)
		s.mu.Unlock()
		f(w, r, cuerpo)
	}
}

// IPPermitida: sólo redes privadas IPv4 (nunca internet, nunca loopback).
func IPPermitida(ip string) (net.IP, bool) {
	p := net.ParseIP(strings.TrimSpace(ip))
	if p == nil {
		return nil, false
	}
	v4 := p.To4()
	if v4 == nil {
		return nil, false
	}
	switch {
	case v4[0] == 10:
	case v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31:
	case v4[0] == 192 && v4[1] == 168:
	default:
		return nil, false
	}
	return v4, true
}

type pedidoRed struct {
	IP    string `json:"ip"`
	Port  int    `json:"port"`
	Data  string `json:"data"`
	JobID string `json:"job"`
}

func (s *Servidor) destino(p pedidoRed) (string, error) {
	ip, ok := IPPermitida(p.IP)
	if !ok {
		return "", errors.New("sólo se permiten impresoras de la red local (192.168.x.x, 10.x.x.x, 172.16-31.x.x)")
	}
	puerto := p.Port
	if puerto == 0 {
		puerto = PuertoImpresa
	}
	if puerto != PuertoImpresa {
		return "", errors.New("puerto no permitido (se usa el 9100)")
	}
	return net.JoinHostPort(ip.String(), strconv.Itoa(puerto)), nil
}

func (s *Servidor) imprimir(w http.ResponseWriter, r *http.Request, cuerpo []byte) {
	var p pedidoRed
	if err := json.Unmarshal(cuerpo, &p); err != nil {
		responder(w, 400, map[string]string{"error": "pedido inválido"})
		return
	}
	dest, err := s.destino(p)
	if err != nil {
		responder(w, 400, map[string]string{"error": err.Error()})
		return
	}
	datos, err := base64.StdEncoding.DecodeString(p.Data)
	if err != nil || len(datos) == 0 || len(datos) > MaxDatos {
		responder(w, 400, map[string]string{"error": "datos de impresión inválidos"})
		return
	}
	if len(p.JobID) > 80 {
		responder(w, 400, map[string]string{"error": "trabajo inválido"})
		return
	}
	// idempotencia: si ese trabajo ya salió, no se imprime dos veces
	if p.JobID != "" {
		s.mu.Lock()
		ahora := s.cfg.Ahora()
		for k, t := range s.hechos {
			if ahora.Sub(t) > time.Hour {
				delete(s.hechos, k)
			}
		}
		if _, ya := s.hechos[p.JobID]; ya {
			s.mu.Unlock()
			responder(w, 200, map[string]interface{}{"ok": true, "repetido": true})
			return
		}
		s.hechos[p.JobID] = ahora // se reserva ANTES de conectar: dos pedidos a la vez no imprimen doble
		s.mu.Unlock()
	}
	liberar := func() {
		if p.JobID != "" {
			s.mu.Lock()
			delete(s.hechos, p.JobID)
			s.mu.Unlock()
		}
	}
	c, err := s.cfg.Dial("tcp", dest, 4*time.Second)
	if err != nil {
		liberar()
		responder(w, 502, map[string]string{"error": "no pude conectar con la impresora (¿está prendida y en la misma red?)"})
		return
	}
	defer c.Close()
	_ = c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := c.Write(datos); err != nil {
		liberar()
		responder(w, 502, map[string]string{"error": "la impresora cortó la conexión"})
		return
	}
	responder(w, 200, map[string]bool{"ok": true})
}

func (s *Servidor) probar(w http.ResponseWriter, r *http.Request, cuerpo []byte) {
	var p pedidoRed
	if err := json.Unmarshal(cuerpo, &p); err != nil {
		responder(w, 400, map[string]string{"error": "pedido inválido"})
		return
	}
	dest, err := s.destino(p)
	if err != nil {
		responder(w, 400, map[string]string{"error": err.Error()})
		return
	}
	c, err := s.cfg.Dial("tcp", dest, 2*time.Second)
	if err != nil {
		responder(w, 200, map[string]bool{"ok": false})
		return
	}
	c.Close()
	responder(w, 200, map[string]bool{"ok": true})
}

// escanear busca equipos con el puerto 9100 abierto en las redes /24 de esta PC.
func (s *Servidor) escanear(w http.ResponseWriter, r *http.Request, _ []byte) {
	addrs, err := s.cfg.Interfaces()
	if err != nil {
		responder(w, 500, map[string]string{"error": "no pude leer la red"})
		return
	}
	var redes [][3]byte
	for _, a := range addrs {
		in, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		v4, ok := IPPermitida(in.IP.String())
		if !ok {
			continue
		}
		red := [3]byte{v4[0], v4[1], v4[2]}
		dup := false
		for _, x := range redes {
			if x == red {
				dup = true
			}
		}
		if !dup && len(redes) < 3 {
			redes = append(redes, red)
		}
	}
	var mu sync.Mutex
	var halladas []string
	sem := make(chan struct{}, 64)
	var wg sync.WaitGroup
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	for _, red := range redes {
		for h := 1; h <= 254; h++ {
			if ctx.Err() != nil {
				break
			}
			ip := fmt.Sprintf("%d.%d.%d.%d", red[0], red[1], red[2], h)
			sem <- struct{}{}
			wg.Add(1)
			go func(ip string) {
				defer wg.Done()
				defer func() { <-sem }()
				c, err := s.cfg.Dial("tcp", net.JoinHostPort(ip, strconv.Itoa(PuertoImpresa)), 400*time.Millisecond)
				if err == nil {
					c.Close()
					mu.Lock()
					halladas = append(halladas, ip)
					mu.Unlock()
				}
			}(ip)
		}
	}
	wg.Wait()
	if halladas == nil {
		halladas = []string{}
	}
	responder(w, 200, map[string]interface{}{"ok": true, "impresoras": halladas})
}
