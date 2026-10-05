// Pruebas locales: RAVE_TEST=1 deno test --allow-net --allow-env test.ts
import { manejar, sanear } from "./index.ts";
const ok = (c: unknown, m: string) => { if (!c) throw new Error("FALLA: " + m); console.log("  ✔ " + m); };

// servidor falso de Supabase (auth + rpc) y de la IA
let rolAdmin = true, cuota = 3, iaPedido: any = null;
const srv = Deno.serve({ port: 8787, onListen() {} }, async (req) => {
  const u = new URL(req.url);
  if (u.pathname === "/auth/v1/user") return req.headers.get("authorization") === "Bearer bueno" ? Response.json({ id: "u1" }) : new Response("{}", { status: 401 });
  if (u.pathname === "/rest/v1/rpc/ia_consumir") {
    if (!rolAdmin) return Response.json({ message: "sólo el administrador puede usar la IA" }, { status: 403 });
    if (--cuota < 0) return Response.json({ message: "se alcanzó el límite diario de lecturas con IA (3)" }, { status: 400 });
    return Response.json(cuota);
  }
  if (u.pathname === "/v1/messages") {
    iaPedido = await req.json();
    return Response.json({ model: "modelo-prueba", content: [{ type: "tool_use", name: "registrar_comprobante", input: {
      proveedor: { nombre: "Distribuidora <script>Norte</script> SRL", cuit: "30-71234567-9" },
      comprobante: { tipo: "fa", punto_venta: "0003", numero: "00012345" },
      fecha_emision: "2026-10-01", fecha_vencimiento: "31/10/2026",
      items: [{ cantidad: 12, descripcion: "Fernet 750", precio_unitario: 9500, subtotal: 114000 }],
      subtotal_neto: 114000, iva: [{ alicuota: 21, importe: 23940 }], percepciones: [], total: "137940",
      categoria_sugerida: "Bebidas", confianza: { total: 1.7 } } }] });
  }
  return new Response("no", { status: 404 });
});
const env = (k: string): string | undefined => ({ SUPABASE_URL: "http://localhost:8787", ANTHROPIC_API_KEY: "x", ANTHROPIC_URL: "http://localhost:8787/v1/messages", IA_LIMITE_DIARIO: "3" } as Record<string, string>)[k];
const pedir = (body: unknown, auth = "Bearer bueno", e: (k: string) => string | undefined = env) => manejar(new Request("http://x/", {
  method: "POST", headers: { apikey: "sb_publishable_x", authorization: auth, "content-type": "application/json" }, body: JSON.stringify(body) }), e);
const ARCH = { comercio: "11111111-1111-1111-1111-111111111111", archivo: { mime: "image/jpeg", nombre: "f.jpg", base64: btoa("hola") } };

Deno.test("extraer-comprobante", async () => {
  let r = await pedir(ARCH, "Bearer malo"); ok(r.status === 401, "sin sesión válida → 401"); await r.body?.cancel();
  r = await pedir({ ...ARCH, archivo: { ...ARCH.archivo, mime: "text/html" } }); ok(r.status === 415, "tipo de archivo no permitido → 415"); await r.body?.cancel();
  r = await pedir({ ...ARCH, archivo: { ...ARCH.archivo, base64: "a".repeat(7_100_000) } }); ok(r.status === 413, "archivo muy grande → 413"); await r.body?.cancel();
  r = await pedir(ARCH, "Bearer bueno", (k) => k === "ANTHROPIC_API_KEY" ? undefined : env(k)); ok(r.status === 503, "sin clave de IA → 503 (el sistema sigue con lectura local)"); await r.body?.cancel();
  rolAdmin = false; r = await pedir(ARCH); ok(r.status === 403, "no admin → 403"); await r.body?.cancel(); rolAdmin = true;
  r = await pedir({ ...ARCH, pistas: { qr: { cuit: 30712345679 } } });
  const j = await r.json();
  ok(r.status === 200 && j.ok && j.motor === "ia", "lectura correcta → 200");
  ok(j.datos.proveedor.cuit === "30712345679", "CUIT normalizado a 11 dígitos");
  ok(!/[<>]/.test(j.datos.proveedor.nombre), "sin < > en textos de la IA");
  ok(j.datos.comprobante.tipo === "FA" && j.datos.fecha_vencimiento === null, "tipo normalizado y fecha inválida descartada");
  ok(j.datos.total === 137940 && j.datos.confianza.total === 1, "números saneados y confianza acotada");
  ok(iaPedido.tool_choice.name === "registrar_comprobante" && iaPedido.messages[0].content[0].type === "image", "pide salida estructurada con la imagen");
  ok(JSON.stringify(iaPedido).includes("QR fiscal"), "pasa las pistas del QR a la IA");
  r = await pedir(ARCH); await r.body?.cancel(); r = await pedir(ARCH); await r.body?.cancel();
  r = await pedir(ARCH); ok(r.status === 429, "límite diario → 429"); await r.body?.cancel();
  ok(sanear(null).items.length === 0, "sanear tolera basura");
  await srv.shutdown();
});
