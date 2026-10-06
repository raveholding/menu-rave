package agente

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

var codMu, dialMu sync.Mutex

func leer(c *string) string { codMu.Lock(); defer codMu.Unlock(); return *c }

type pipeConn struct {
	net.Conn
	buf *bytes.Buffer
}

func (p *pipeConn) Write(b []byte) (int, error)        { return p.buf.Write(b) }
func (p *pipeConn) Close() error                       { return nil }
func (p *pipeConn) SetWriteDeadline(t time.Time) error { return nil }

func nuevoTest(t *testing.T) (*Servidor, *[]string, *bytes.Buffer, *string) {
	var dials []string
	salida := &bytes.Buffer{}
	cod := new(string)
	s := Nuevo(Config{
		Addr: "127.0.0.1:9101", Dir: t.TempDir(), Origenes: []string{"null", "https://raveholding.github.io"},
		MostrarCodigo: func(c string) { codMu.Lock(); *cod = c; codMu.Unlock() },
		Dial: func(n, a string, d time.Duration) (net.Conn, error) {
			dialMu.Lock()
			dials = append(dials, a)
			dialMu.Unlock()
			if strings.HasPrefix(a, "192.168.1.50:") || strings.HasPrefix(a, "192.168.1.77:") {
				return &pipeConn{buf: salida}, nil
			}
			return nil, net.ErrClosed
		},
		Interfaces: func() ([]net.Addr, error) {
			_, n, _ := net.ParseCIDR("192.168.1.10/24")
			return []net.Addr{&net.IPNet{IP: net.ParseIP("192.168.1.10"), Mask: n.Mask},
				&net.IPNet{IP: net.ParseIP("8.8.8.8"), Mask: net.CIDRMask(24, 32)}}, nil
		},
	})
	return s, &dials, salida, cod
}

func pedir(h http.Handler, metodo, ruta, host, origen string, cuerpo []byte, hdr map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(metodo, "http://"+host+ruta, bytes.NewReader(cuerpo))
	r.Host = host
	if origen != "" {
		r.Header.Set("Origin", origen)
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func firmar(clave []byte, ruta, id string, cuerpo []byte, ts time.Time) map[string]string {
	t := strconv.FormatInt(ts.UnixMilli(), 10)
	return map[string]string{"X-Rave-Ts": t, "X-Rave-Id": id, "X-Rave-Mac": Mac(clave, t, id, ruta, cuerpo)}
}

func vincular(t *testing.T, s *Servidor, cod *string) []byte {
	h := s.Handler()
	if w := pedir(h, "POST", "/pair-start", "127.0.0.1:9101", "null", nil, nil); w.Code != 200 {
		t.Fatal("pair-start", w.Code)
	}
	time.Sleep(50 * time.Millisecond)
	if len(leer(cod)) != 6 {
		t.Fatal("no mostró el código")
	}
	w := pedir(h, "POST", "/pair", "127.0.0.1:9101", "null", []byte(`{"code":"`+leer(cod)+`"}`), nil)
	if w.Code != 200 {
		t.Fatal("pair", w.Code, w.Body.String())
	}
	var r struct{ Key string }
	json.Unmarshal(w.Body.Bytes(), &r)
	k, _ := base64.StdEncoding.DecodeString(r.Key)
	if len(k) != 32 {
		t.Fatal("clave")
	}
	return k
}

func TestHostYOrigen(t *testing.T) {
	s, _, _, _ := nuevoTest(t)
	h := s.Handler()
	if w := pedir(h, "GET", "/hello", "evil.com:9101", "", nil, nil); w.Code != 403 {
		t.Error("rebinding debería bloquearse", w.Code)
	}
	if w := pedir(h, "GET", "/hello", "127.0.0.1:9101", "https://evil.com", nil, nil); w.Code != 403 {
		t.Error("origen ajeno debería bloquearse", w.Code)
	}
	w := pedir(h, "OPTIONS", "/print", "127.0.0.1:9101", "https://raveholding.github.io", nil, nil)
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Private-Network") != "true" {
		t.Error("preflight PNA", w.Code)
	}
	if w := pedir(h, "GET", "/hello", "localhost:9101", "null", nil, nil); w.Code != 200 {
		t.Error("hello", w.Code)
	}
}

func TestSoloLoopback(t *testing.T) {
	s := Nuevo(Config{Addr: "0.0.0.0:9101"})
	if err := s.Servir(); err == nil {
		t.Fatal("no debe escuchar fuera de 127.0.0.1")
	}
}

func TestVinculacionYFirma(t *testing.T) {
	s, _, salida, cod := nuevoTest(t)
	h := s.Handler()
	cuerpo := []byte(`{"ip":"192.168.1.50","port":9100,"data":"` + base64.StdEncoding.EncodeToString([]byte("HOLA")) + `","job":"j1"}`)
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, firmar([]byte("x"), "/print", "a1", cuerpo, time.Now())); w.Code != 401 {
		t.Error("sin vincular debe rechazar", w.Code)
	}
	k := vincular(t, s, cod)
	// el código sirve una sola vez
	if w := pedir(h, "POST", "/pair", "127.0.0.1:9101", "null", []byte(`{"code":"`+leer(cod)+`"}`), nil); w.Code == 200 {
		t.Error("el código no puede reutilizarse")
	}
	// firma mala
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, firmar([]byte("otra"), "/print", "a2", cuerpo, time.Now())); w.Code != 401 {
		t.Error("firma mala", w.Code)
	}
	// cuerpo alterado
	hd := firmar(k, "/print", "a3", cuerpo, time.Now())
	alt := bytes.Replace(cuerpo, []byte("192.168.1.50"), []byte("192.168.1.77"), 1)
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", alt, hd); w.Code != 401 {
		t.Error("cuerpo alterado", w.Code)
	}
	// vencida
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, firmar(k, "/print", "a4", cuerpo, time.Now().Add(-10*time.Minute))); w.Code != 401 {
		t.Error("vencida", w.Code)
	}
	// ok
	hd = firmar(k, "/print", "a5", cuerpo, time.Now())
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, hd); w.Code != 200 {
		t.Fatal("imprimir", w.Code, w.Body.String())
	}
	if salida.String() != "HOLA" {
		t.Error("no llegó a la impresora:", salida.String())
	}
	// repetición del mismo pedido (replay)
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, hd); w.Code != 409 {
		t.Error("replay", w.Code)
	}
	// mismo trabajo con otra firma: no se duplica la impresión
	salida.Reset()
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, firmar(k, "/print", "a6", cuerpo, time.Now())); w.Code != 200 || salida.Len() != 0 {
		t.Error("el trabajo j1 no debe imprimirse dos veces", w.Code, salida.Len())
	}
}

func TestDestinosProhibidos(t *testing.T) {
	s, dials, _, cod := nuevoTest(t)
	k := vincular(t, s, cod)
	h := s.Handler()
	for i, ip := range []string{"8.8.8.8", "127.0.0.1", "169.254.169.254", "172.32.0.1", "::1", "192.168.1.50:80", "localhost", "0.0.0.0"} {
		c := []byte(`{"ip":"` + ip + `","port":9100,"data":"QQ=="}`)
		if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", c, firmar(k, "/print", "p"+strconv.Itoa(i), c, time.Now())); w.Code != 400 {
			t.Errorf("%s debería rechazarse (%d)", ip, w.Code)
		}
	}
	c := []byte(`{"ip":"192.168.1.50","port":22,"data":"QQ=="}`)
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", c, firmar(k, "/print", "pp", c, time.Now())); w.Code != 400 {
		t.Error("puerto 22 debe rechazarse", w.Code)
	}
	big := base64.StdEncoding.EncodeToString(make([]byte, MaxDatos+1))
	c = []byte(`{"ip":"192.168.1.50","port":9100,"data":"` + big + `"}`)
	if w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", c, firmar(k, "/print", "pg", c, time.Now())); w.Code != 400 {
		t.Error("muy grande", w.Code)
	}
	if len(*dials) != 0 {
		t.Error("no debió conectar a nada", *dials)
	}
}

func TestBloqueoDeCodigo(t *testing.T) {
	s, _, _, cod := nuevoTest(t)
	h := s.Handler()
	pedir(h, "POST", "/pair-start", "127.0.0.1:9101", "null", nil, nil)
	time.Sleep(50 * time.Millisecond)
	for i := 0; i < 5; i++ {
		w := pedir(h, "POST", "/pair", "127.0.0.1:9101", "null", []byte(`{"code":"000000x"}`), nil)
		if w.Code == 200 {
			t.Fatal("no")
		}
	}
	w := pedir(h, "POST", "/pair", "127.0.0.1:9101", "null", []byte(`{"code":"`+leer(cod)+`"}`), nil)
	if w.Code != 429 {
		t.Error("tras 5 fallos debe bloquear, aun con el código bueno", w.Code)
	}
}

func TestSondeoYEscaneo(t *testing.T) {
	s, _, _, cod := nuevoTest(t)
	k := vincular(t, s, cod)
	h := s.Handler()
	c := []byte(`{"ip":"192.168.1.50","port":9100}`)
	w := pedir(h, "POST", "/probe", "127.0.0.1:9101", "null", c, firmar(k, "/probe", "s1", c, time.Now()))
	if !strings.Contains(w.Body.String(), `"ok":true`) {
		t.Error("probe", w.Body.String())
	}
	c = []byte(`{}`)
	w = pedir(h, "POST", "/scan", "127.0.0.1:9101", "null", c, firmar(k, "/scan", "s2", c, time.Now()))
	var r struct{ Impresoras []string }
	json.Unmarshal(w.Body.Bytes(), &r)
	if len(r.Impresoras) != 2 {
		t.Error("el escaneo debía hallar 2 (50 y 77), halló", r.Impresoras)
	}
}

func TestPersisteLaClave(t *testing.T) {
	s, _, _, cod := nuevoTest(t)
	k := vincular(t, s, cod)
	s2 := Nuevo(Config{Dir: s.cfg.Dir})
	if !bytes.Equal(s2.clave, k) {
		t.Error("la clave debe sobrevivir al reinicio")
	}
}

func TestConfirmarVinculoYSimultaneos(t *testing.T) {
	s, _, salida, cod := nuevoTest(t)
	var origen string
	var ya bool
	rechazar := true
	s.cfg.ConfirmarVinculo = func(o string, v bool) bool { origen, ya = o, v; return !rechazar }
	h := s.Handler()
	if w := pedir(h, "POST", "/pair-start", "127.0.0.1:9101", "null", nil, nil); w.Code != 403 {
		t.Fatal("si la persona rechaza no se debe generar código", w.Code)
	}
	time.Sleep(50 * time.Millisecond)
	if leer(cod) != "" || origen != "null" || ya {
		t.Error("no debía mostrarse código y sí el origen", leer(cod), origen)
	}
	rechazar = false
	time.Sleep(11 * time.Second)
	k := vincular(t, s, cod)
	// re-vincular avisa que ya había una vinculación
	rechazar = false
	time.Sleep(11 * time.Second)
	pedir(h, "POST", "/pair-start", "127.0.0.1:9101", "null", nil, nil)
	if !ya {
		t.Error("debía avisar que ya estaba vinculado")
	}
	// dos /print simultáneos del mismo trabajo con distinta firma: sale una sola vez
	cuerpo := []byte(`{"ip":"192.168.1.50","port":9100,"data":"` + base64.StdEncoding.EncodeToString([]byte("UNA")) + `","job":"dup"}`)
	done := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func(i int) {
			w := pedir(h, "POST", "/print", "127.0.0.1:9101", "null", cuerpo, firmar(k, "/print", "sim"+strconv.Itoa(i), cuerpo, time.Now()))
			done <- w.Code
		}(i)
	}
	<-done
	<-done
	dialMu.Lock()
	n := strings.Count(salida.String(), "UNA")
	dialMu.Unlock()
	if n != 1 {
		t.Error("el trabajo debía imprimirse una sola vez, salió", n)
	}
}
