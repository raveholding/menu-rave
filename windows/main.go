// Sistema RAVE · programa para Windows 10/11
//
// Un solo ejecutable con el ícono del comercio que hace tres cosas:
//   - Fuera de su carpeta (recién descargado): INSTALA el sistema.
//   - Dentro de C:\SistemaRAVE (el acceso directo): ABRE el sistema en una
//     ventana propia de Edge o Chrome, sin barra de direcciones.
//   - /actualizar y /desinstalar: lo que dicen.
//
// No pide permisos de administrador, no abre ventanas negras y queda
// registrado en "Aplicaciones instaladas" de Windows.
package main

import (
	_ "embed"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"sistemarave/agente"

	ole "github.com/go-ole/go-ole"
	"github.com/go-ole/go-ole/oleutil"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed recursos/sistema-rave.html
var paginaHTML []byte

//go:embed recursos/rave.ico
var iconoICO []byte

const (
	nombre      = "Sistema RAVE"
	empresa     = "Rave Holding"
	contacto    = "WhatsApp +54 9 387 514-3900"
	version     = "1.1"
	exeNombre   = "SistemaRAVE.exe"
	urlNueva    = "https://raveholding.github.io/menu-rave/index.html"
	claveDesins = `Software\Microsoft\Windows\CurrentVersion\Uninstall\SistemaRAVE`
)

// ---------------------------------------------------------------- avisos
var (
	user32      = windows.NewLazySystemDLL("user32.dll")
	pMessageBox = user32.NewProc("MessageBoxW")
)

const (
	mbOK          = 0x0
	mbYesNo       = 0x4
	mbIconInfo    = 0x40
	mbIconWarn    = 0x30
	mbIconError   = 0x10
	mbIconQuest   = 0x20
	mbDefButton2  = 0x100
	mbSetForegrnd = 0x10000
	idYes         = 6
)

func aviso(texto string, flags uintptr) int {
	t, _ := windows.UTF16PtrFromString(texto)
	c, _ := windows.UTF16PtrFromString(nombre)
	r, _, _ := pMessageBox.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), flags|mbSetForegrnd)
	return int(r)
}
func error_(texto string) { aviso(texto, mbOK|mbIconError) }

// ---------------------------------------------------------------- rutas
func carpetaDestino() string {
	// C:\SistemaRAVE: ruta corta y sin espacios (la usa la dirección file:///)
	d := `C:\SistemaRAVE`
	if err := os.MkdirAll(d, 0o755); err == nil {
		return d
	}
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "SistemaRAVE")
}
func carpetaInstalada() string {
	if k, err := registry.OpenKey(registry.CURRENT_USER, claveDesins, registry.QUERY_VALUE); err == nil {
		defer k.Close()
		if v, _, err := k.GetStringValue("InstallLocation"); err == nil && v != "" {
			return v
		}
	}
	return `C:\SistemaRAVE`
}
func carpetaConocida(id *windows.KNOWNFOLDERID) string {
	p, err := windows.KnownFolderPath(id, 0)
	if err != nil {
		return ""
	}
	return p
}
func urlArchivo(p string) string {
	u := url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(p)}
	return u.String()
}

// ---------------------------------------------------------------- navegador
func buscarNavegador() string {
	cands := []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Google\Chrome\Application\chrome.exe`),
		filepath.Join(os.Getenv("LOCALAPPDATA"), `Google\Chrome\Application\chrome.exe`),
	}
	for _, c := range cands {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}

// impresionDirecta: acceso opcional "(impresión directa)". El acceso normal no cambia.
var impresionDirecta bool

func abrirSistema(dir string) error {
	nav := buscarNavegador()
	if nav == "" {
		return fmt.Errorf("no encontré Microsoft Edge ni Google Chrome en esta PC")
	}
	pagina := filepath.Join(dir, "sistema-rave.html")
	if _, err := os.Stat(pagina); err != nil {
		return fmt.Errorf("falta el archivo del sistema en %s: volvé a instalar", dir)
	}
	args := []string{
		"--app=" + urlArchivo(pagina) + "#panel",
		"--user-data-dir=" + filepath.Join(dir, "perfil"),
		"--no-first-run", "--no-default-browser-check"}
	if impresionDirecta {
		// imprime sin la ventana de impresión, directo a la impresora predeterminada de Windows
		args = append(args, "--kiosk-printing")
	}
	iniciarAgente()
	return exec.Command(nav, args...).Start()
}

// ---------------------------------------------------------------- agente de impresoras de red
const agenteExe = "RaveAgente.exe"

func carpetaAgente() string {
	b := os.Getenv("LOCALAPPDATA")
	if b == "" {
		b = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
	}
	return filepath.Join(b, "SistemaRAVE")
}

// iniciarAgente copia este programa a una carpeta propia (así no traba las
// actualizaciones) y lo deja corriendo en segundo plano, sólo en 127.0.0.1.
// Si ya hay uno corriendo, la copia nueva se cierra sola (el puerto está tomado).
func iniciarAgente() {
	yo, err := os.Executable()
	if err != nil {
		return
	}
	dir := carpetaAgente()
	os.MkdirAll(dir, 0o700)
	copia := filepath.Join(dir, agenteExe)
	if a, e1 := os.Stat(yo); e1 == nil {
		if b, e2 := os.Stat(copia); e2 != nil || b.Size() != a.Size() || b.ModTime().Before(a.ModTime()) {
			if datos, e3 := os.ReadFile(yo); e3 == nil {
				os.WriteFile(copia, datos, 0o700) // si está en uso, queda la anterior
			}
		}
	}
	c := exec.Command(copia, "/agente")
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	c.Start()
}

func detenerAgente() {
	c := exec.Command("taskkill", "/F", "/IM", agenteExe)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	c.Run()
}

func correrAgente() {
	srv := agente.Nuevo(agente.Config{
		Addr:     "127.0.0.1:9101",
		Dir:      carpetaAgente(),
		Origenes: []string{"null", "https://raveholding.github.io"},
		ConfirmarVinculo: func(origen string, ya bool) bool {
			t := "Una página pidió vincular el agente de impresión de red con este equipo.\n\nOrigen: " + origen + "\n\n"
			if ya {
				t += "ATENCIÓN: ya hay una vinculación hecha. Si seguís, la anterior se reemplaza.\n\n"
			}
			t += "¿Fuiste vos, desde el Sistema RAVE, en Configuración → Periféricos?"
			return aviso(t, mbYesNo|mbIconQuest|mbDefButton2) == idYes
		},
		MostrarCodigo: func(codigo string) {
			aviso("Código para vincular las impresoras de red con el Sistema RAVE:\n\n        "+codigo+"\n\nEscribilo en el sistema (Configuración → Periféricos). Vale 3 minutos y sirve una sola vez.\nSi no fuiste vos quien lo pidió, tocá Aceptar y no lo uses.", mbOK|mbIconInfo)
		},
	})
	_ = srv.Servir() // si el puerto ya está tomado, otra copia ya está corriendo: se cierra sin avisar
}

// ---------------------------------------------------------------- accesos directos
func crearAcceso(ruta, destino, args, icono, descr, carpetaTrabajo string) error {
	unk, err := oleutil.CreateObject("WScript.Shell")
	if err != nil {
		return err
	}
	defer unk.Release()
	sh, err := unk.QueryInterface(ole.IID_IDispatch)
	if err != nil {
		return err
	}
	defer sh.Release()
	v, err := oleutil.CallMethod(sh, "CreateShortcut", ruta)
	if err != nil {
		return err
	}
	lnk := v.ToIDispatch()
	defer lnk.Release()
	oleutil.PutProperty(lnk, "TargetPath", destino)
	oleutil.PutProperty(lnk, "Arguments", args)
	oleutil.PutProperty(lnk, "IconLocation", icono+",0")
	oleutil.PutProperty(lnk, "Description", descr)
	oleutil.PutProperty(lnk, "WorkingDirectory", carpetaTrabajo)
	_, err = oleutil.CallMethod(lnk, "Save")
	return err
}

// ---------------------------------------------------------------- instalar
func copiarEste(dest string) error {
	yo, err := os.Executable()
	if err != nil {
		return err
	}
	in, err := os.ReadFile(yo)
	if err != nil {
		return err
	}
	tmp := dest + ".nuevo"
	if err := os.WriteFile(tmp, in, 0o755); err != nil {
		return err
	}
	_ = os.Remove(dest + ".viejo")
	if _, err := os.Stat(dest); err == nil {
		// el .exe puede estar en uso: se renombra en lugar de pisarlo
		if err := os.Rename(dest, dest+".viejo"); err != nil {
			return err
		}
	}
	return os.Rename(tmp, dest)
}

// protegerCarpeta: en C:\ Windows suele dar escritura a "Usuarios autenticados", y con eso otra
// persona de la PC podría cambiar el programa o los datos. Se deja acceso sólo a esta persona,
// a los administradores y al sistema. Si algo falla antes de sacar la herencia, no se toca nada.
func protegerCarpeta(dir string) {
	usuario := os.Getenv("USERNAME")
	if usuario == "" {
		return
	}
	if dom := os.Getenv("USERDOMAIN"); dom != "" {
		usuario = dom + `\` + usuario
	}
	correr := func(args ...string) bool {
		c := exec.Command("icacls", args...)
		c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
		return c.Run() == nil
	}
	if !correr(dir, "/grant:r", usuario+":(OI)(CI)F", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F") {
		return
	}
	correr(dir, "/inheritance:r")
}

func instalar() {
	if aviso("Se va a instalar "+nombre+" en este equipo.\n\n"+
		"• No hace falta ser administrador.\n"+
		"• Queda un ícono en el Escritorio y en el menú Inicio.\n"+
		"• Si ya estaba instalado, se actualiza y los datos se conservan.\n\n"+
		"Desarrollado por "+empresa+" · "+contacto+"\n\n¿Continuar?",
		mbYesNo|mbIconQuest) != idYes {
		return
	}
	if buscarNavegador() == "" {
		error_("No encontré Microsoft Edge ni Google Chrome en esta PC.\nInstalá uno de los dos y volvé a abrir el instalador.")
		return
	}
	dir := carpetaDestino()
	for _, d := range []string{dir, filepath.Join(dir, "perfil")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			error_("No se pudo crear la carpeta " + d + ":\n" + err.Error())
			return
		}
	}
	exe := filepath.Join(dir, exeNombre)
	ico := filepath.Join(dir, "rave.ico")
	pasos := []func() error{
		func() error { return os.WriteFile(filepath.Join(dir, "sistema-rave.html"), paginaHTML, 0o644) },
		func() error { return os.WriteFile(ico, iconoICO, 0o644) },
		func() error { return copiarEste(exe) },
	}
	for _, p := range pasos {
		if err := p(); err != nil {
			error_("No se pudo copiar el sistema:\n" + err.Error())
			return
		}
	}
	protegerCarpeta(dir)
	// restos del instalador anterior (archivos .bat y scripts)
	for _, f := range []string{"ACTUALIZAR.bat", "DESINSTALAR.bat", "actualizar.ps1", "desinstalar.ps1", "LEEME.txt"} {
		os.Remove(filepath.Join(dir, f))
	}
	os.RemoveAll(filepath.Join(dir, "scripts"))

	// accesos directos
	ole.CoInitializeEx(0, ole.COINIT_APARTMENTTHREADED)
	defer ole.CoUninitialize()
	detenerAgente()
	os.RemoveAll(carpetaAgente()) // copia del agente y la clave de vinculación
	escritorio := carpetaConocida(windows.FOLDERID_Desktop)
	programas := carpetaConocida(windows.FOLDERID_Programs)
	menu := filepath.Join(programas, nombre)
	os.MkdirAll(menu, 0o755)
	// el acceso suelto del instalador anterior en el menú Inicio
	os.Remove(filepath.Join(programas, nombre+".lnk"))
	var fallos []string
	accesos := []struct{ ruta, args, descr string }{
		{filepath.Join(escritorio, nombre+".lnk"), "", nombre + " · gestión del comercio"},
		{filepath.Join(menu, nombre+".lnk"), "", nombre + " · gestión del comercio"},
		{filepath.Join(escritorio, nombre+" (impresión directa).lnk"), "/directa", "Igual que el sistema, pero imprime sin preguntar en la impresora predeterminada de Windows"},
		{filepath.Join(menu, "Actualizar "+nombre+".lnk"), "/actualizar", "Trae la última versión publicada"},
		{filepath.Join(menu, "Desinstalar "+nombre+".lnk"), "/desinstalar", "Quita el sistema de este equipo"},
	}
	for _, a := range accesos {
		if err := crearAcceso(a.ruta, exe, a.args, ico, a.descr, dir); err != nil {
			fallos = append(fallos, filepath.Base(a.ruta))
		}
	}
	registrar(dir, exe)

	msg := nombre + " quedó instalado.\n\n" +
		"Para entrar: ícono \"" + nombre + "\" del Escritorio.\n" +
		"Si querés imprimir tickets sin que aparezca la ventana de impresión: ícono \"" + nombre + " (impresión directa)\" (cerrá antes el sistema si estaba abierto).\n" +
		"Primera vez: asistente para crear el comercio, o \"Conectar este dispositivo a la nube\".\n\n" +
		"Soporte y sistemas a medida: " + empresa + " · " + contacto
	if len(fallos) > 0 {
		msg += "\n\nNo se pudieron crear algunos accesos directos: " + strings.Join(fallos, ", ") +
			".\nAbrí el sistema desde " + exe
	}
	aviso(msg, mbOK|mbIconInfo)
	if err := abrirSistema(dir); err != nil {
		error_(err.Error())
	}
}

// "Aplicaciones instaladas" de Windows (por usuario: no pide administrador)
func registrar(dir, exe string) {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, claveDesins, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	k.SetStringValue("DisplayName", nombre)
	k.SetStringValue("DisplayIcon", exe+",0")
	k.SetStringValue("DisplayVersion", version)
	k.SetStringValue("Publisher", empresa)
	k.SetStringValue("HelpLink", "https://wa.me/5493875143900")
	k.SetStringValue("URLInfoAbout", "https://raveholding.github.io/menu-rave/")
	k.SetStringValue("Contact", contacto)
	k.SetStringValue("InstallLocation", dir)
	k.SetStringValue("InstallDate", time.Now().Format("20060102"))
	k.SetStringValue("UninstallString", `"`+exe+`" /desinstalar`)
	k.SetDWordValue("NoModify", 1)
	k.SetDWordValue("NoRepair", 1)
	k.SetDWordValue("EstimatedSize", uint32((len(paginaHTML)+8<<20)/1024))
}

// ---------------------------------------------------------------- actualizar
func actualizar(dir string) {
	cli := &http.Client{Timeout: 60 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) > 5 {
			return fmt.Errorf("redirección no permitida")
		}
		return nil
	}}
	r, err := cli.Get(urlNueva + "?v=" + fmt.Sprint(time.Now().Unix()))
	if err != nil {
		error_("No se pudo descargar la versión nueva.\nRevisá que haya internet y probá de nuevo.\n\n" + err.Error())
		return
	}
	defer r.Body.Close()
	datos, err := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	if err != nil || r.StatusCode != 200 {
		error_(fmt.Sprintf("No se pudo descargar la versión nueva (respuesta %d).", r.StatusCode))
		return
	}
	if len(datos) < 500_000 || !strings.Contains(string(datos), "SISTEMA <em>RAVE</em>") {
		error_("Lo que se descargó no parece el Sistema RAVE. No se cambió nada.")
		return
	}
	pag := filepath.Join(dir, "sistema-rave.html")
	if viejo, err := os.ReadFile(pag); err == nil {
		// no se acepta una versión MÁS VIEJA que la instalada (evita que alguien te haga retroceder)
		if versionDe(datos) == nil || (versionDe(viejo) != nil && menorVersion(versionDe(datos), versionDe(viejo))) {
			error_("La versión descargada no es válida o es más vieja que la instalada. No se cambió nada.")
			return
		}
		if string(viejo) == string(datos) {
			aviso("Ya tenés la última versión del sistema.", mbOK|mbIconInfo)
			return
		}
		os.WriteFile(filepath.Join(dir, "sistema-rave.anterior.html"), viejo, 0o644)
	}
	if err := os.WriteFile(pag, datos, 0o644); err != nil {
		error_("No se pudo guardar la versión nueva:\n" + err.Error())
		return
	}
	aviso("Listo: el sistema quedó actualizado.\n\nSi estaba abierto, cerralo y volvé a abrirlo.\nLos datos no se tocaron.", mbOK|mbIconInfo)
}

var reVersion = regexp.MustCompile(`APP_VERSION = '(\d+)\.(\d+)\.(\d+)'`)

func versionDe(b []byte) []int {
	m := reVersion.FindSubmatch(b)
	if m == nil {
		return nil
	}
	v := make([]int, 3)
	for i := 0; i < 3; i++ {
		fmt.Sscan(string(m[i+1]), &v[i])
	}
	return v
}

func menorVersion(a, b []int) bool {
	for i := 0; i < 3; i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// ---------------------------------------------------------------- desinstalar
func desinstalar(dir string) {
	if aviso("¿Quitar "+nombre+" de este equipo?\n\nSe borran los accesos directos y el programa.", mbYesNo|mbIconWarn|mbDefButton2) != idYes {
		return
	}
	borrarDatos := aviso("¿Borrar también los DATOS guardados en este equipo?\n\n"+
		"• Sí: se borran productos, ventas y clientes de este equipo (si el comercio está en la nube, allá siguen).\n"+
		"• No: quedan guardados en "+filepath.Join(dir, "perfil")+" y vuelven si reinstalás.",
		mbYesNo|mbIconWarn|mbDefButton2) == idYes

	escritorio := carpetaConocida(windows.FOLDERID_Desktop)
	programas := carpetaConocida(windows.FOLDERID_Programs)
	os.Remove(filepath.Join(escritorio, nombre+".lnk"))
	os.Remove(filepath.Join(escritorio, nombre+" (impresión directa).lnk"))
	os.RemoveAll(filepath.Join(programas, nombre))
	os.Remove(filepath.Join(programas, nombre+".lnk"))
	registry.DeleteKey(registry.CURRENT_USER, claveDesins)
	for _, f := range []string{"sistema-rave.html", "sistema-rave.anterior.html", "rave.ico", exeNombre + ".viejo"} {
		os.Remove(filepath.Join(dir, f))
	}
	if borrarDatos {
		if err := os.RemoveAll(filepath.Join(dir, "perfil")); err != nil {
			aviso("No se pudieron borrar todos los datos: cerrá la ventana del sistema y borrá a mano la carpeta\n"+filepath.Join(dir, "perfil"), mbOK|mbIconWarn)
		}
	}
	// el propio .exe no se puede borrar mientras corre: lo borra cmd al terminar
	exe := filepath.Join(dir, exeNombre)
	borrar := fmt.Sprintf(`ping 127.0.0.1 -n 3 >nul & del /f /q "%s" & rmdir "%s"`, exe, dir)
	c := exec.Command("cmd.exe", "/c", borrar)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	c.Start()
	aviso(nombre+" se quitó de este equipo.", mbOK|mbIconInfo)
}

// ---------------------------------------------------------------- arranque
func main() {
	// COM (accesos directos) exige quedarse en el mismo hilo del sistema
	runtime.LockOSThread()
	yo, _ := os.Executable()
	yoDir := filepath.Dir(yo)
	instalado := carpetaInstalada()
	modo := ""
	if len(os.Args) > 1 {
		modo = strings.ToLower(strings.TrimLeft(os.Args[1], "/-"))
	}
	switch {
	case modo == "actualizar":
		actualizar(instalado)
	case modo == "desinstalar":
		desinstalar(instalado)
	case modo == "agente":
		correrAgente()
	case modo == "instalar":
		instalar()
	case modo == "directa":
		impresionDirecta = true
		if err := abrirSistema(yoDir); err != nil {
			error_(err.Error())
		}
	case strings.EqualFold(filepath.Clean(yoDir), filepath.Clean(instalado)):
		if err := abrirSistema(yoDir); err != nil {
			error_(err.Error())
		}
	default:
		instalar()
	}
}
