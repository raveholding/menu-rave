// =====================================================================
// Sistema RAVE · Rave Holding
// Edge Function "extraer-comprobante": lee una factura, remito o boleta
// (foto o PDF) con IA de visión y devuelve los datos estructurados para
// que el administrador los REVISE antes de guardarlos.
//
//   POST {SUPABASE_URL}/functions/v1/extraer-comprobante
//   Headers: Authorization: Bearer <sesión del usuario>, apikey: <clave publicable>
//   Body JSON: { "comercio": uuid, "archivo": { "mime": "image/jpeg|image/png|image/webp|application/pdf",
//                "nombre": "factura.jpg", "base64": "..." }, "pistas": { "texto": "...", "qr": {...} } }
//
// Seguridad:
//   · La clave de la IA vive SÓLO en los secretos de Supabase (ANTHROPIC_API_KEY).
//   · Se valida la sesión con Supabase Auth y la cuota/rol con la función
//     ia_consumir() usando la MISMA sesión del usuario (sin claves secretas).
//   · Sólo administradores del comercio; límite diario por comercio.
//   · No guarda el archivo: lo manda a la IA y lo descarta.
//   · Tipos y tamaño limitados; la salida de la IA se valida y se recorta.
//
// Secretos / variables (Supabase → Edge Functions → Secrets):
//   ANTHROPIC_API_KEY   obligatoria para que funcione (si falta, responde 503 y
//                       el sistema sigue con la lectura local).
//   IA_MODELO           opcional (por defecto claude-sonnet-5-5) [VERIFICAR modelo y
//                       precio vigentes en https://docs.claude.com]
//   IA_LIMITE_DIARIO    opcional (por defecto 100 lecturas por comercio y día)
//   ANTHROPIC_URL       opcional, sólo para pruebas locales.
// SUPABASE_URL la pone Supabase sola.
// =====================================================================

const TIPOS = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX_B64 = 7_000_000; // ≈ 5 MB de archivo
const CATEGORIAS = [
  "Mercadería", "Bebidas", "Carnes y fiambres", "Almacén y secos", "Limpieza e higiene",
  "Insumos", "Servicios (luz, agua, gas)", "Internet y teléfono", "Alquiler", "Mantenimiento",
  "Transporte y fletes", "Impuestos y tasas", "Honorarios", "Sueldos", "Comisiones", "Otros",
];

const CORS = {
  // La API usa tokens Bearer (no cookies): no hay riesgo de CSRF al abrirla a
  // cualquier origen, y el programa de Windows corre desde file:// (origen "null").
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

const PROMPT = `Sos un auditor contable argentino. Leé el comprobante adjunto (factura A/B/C/M, nota de crédito o débito, remito, boleta, ticket o recibo de un proveedor o de un gasto) y registrá sus datos con la herramienta "registrar_comprobante".
Reglas:
- Copiá los datos tal como figuran; NO inventes. Si un dato no está o no se lee, dejalo vacío (null) y bajá su confianza.
- CUIT: 11 dígitos sin guiones. Es el CUIT del EMISOR (el proveedor), no el del comprador.
- Fechas en formato AAAA-MM-DD.
- Importes como números con punto decimal (ej. 15432.5), sin símbolo de moneda ni separador de miles.
- Tipo: FA, FB, FC, FM (facturas), NCA, NCB, NCC (notas de crédito), NDA, NDB, NDC (notas de débito), R (remito), TK (ticket o boleta), REC (recibo) u OTRO.
- Punto de venta y número por separado, sólo dígitos.
- Ítems: cantidad, descripción, precio unitario y subtotal de cada renglón (máximo 60 renglones).
- IVA: un renglón por alícuota (21, 10.5, 27, 5, 2.5). Percepciones (IVA, IIBB, etc.) aparte.
- Sugerí una categoría de gasto de esta lista: ${CATEGORIAS.join(", ")}.
- "confianza" de 0 a 1 por campo según qué tan seguro estás de la lectura.`;

const SCHEMA = {
  type: "object",
  properties: {
    proveedor: {
      type: "object",
      properties: { nombre: { type: ["string", "null"] }, cuit: { type: ["string", "null"] } },
    },
    comprobante: {
      type: "object",
      properties: {
        tipo: { type: ["string", "null"] },
        punto_venta: { type: ["string", "null"] },
        numero: { type: ["string", "null"] },
      },
    },
    fecha_emision: { type: ["string", "null"] },
    fecha_vencimiento: { type: ["string", "null"] },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          cantidad: { type: ["number", "null"] },
          descripcion: { type: ["string", "null"] },
          precio_unitario: { type: ["number", "null"] },
          subtotal: { type: ["number", "null"] },
        },
      },
    },
    subtotal_neto: { type: ["number", "null"] },
    iva: {
      type: "array",
      items: { type: "object", properties: { alicuota: { type: ["number", "null"] }, importe: { type: ["number", "null"] } } },
    },
    percepciones: {
      type: "array",
      items: { type: "object", properties: { concepto: { type: ["string", "null"] }, importe: { type: ["number", "null"] } } },
    },
    otros_impuestos: { type: ["number", "null"] },
    total: { type: ["number", "null"] },
    moneda: { type: ["string", "null"] },
    categoria_sugerida: { type: ["string", "null"] },
    confianza: {
      type: "object",
      properties: {
        proveedor: { type: "number" }, cuit: { type: "number" }, comprobante: { type: "number" },
        fecha: { type: "number" }, items: { type: "number" }, total: { type: "number" },
      },
    },
    observaciones: { type: ["string", "null"] },
  },
  required: ["proveedor", "comprobante", "total"],
};

// ---------- saneo de la salida de la IA (nunca se confía ciegamente) ----------
const txt = (v: unknown, max = 120): string | null =>
  typeof v === "string" && v.trim() ? v.replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, max) : null;
const num = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v.replace(",", ".")) : NaN;
  return Number.isFinite(n) && Math.abs(n) < 1e12 ? Math.round(n * 100) / 100 : null;
};
const dig = (v: unknown, max: number): string | null => {
  const d = typeof v === "string" || typeof v === "number" ? String(v).replace(/\D/g, "").slice(0, max) : "";
  return d || null;
};
const fecha = (v: unknown): string | null =>
  typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
const conf = (v: unknown): number => {
  const n = typeof v === "number" ? v : 0.5;
  return Math.max(0, Math.min(1, n));
};
const TIPOS_CMP = ["FA", "FB", "FC", "FM", "NCA", "NCB", "NCC", "NDA", "NDB", "NDC", "R", "TK", "REC", "OTRO"];

// deno-lint-ignore no-explicit-any
export function sanear(d: any) {
  d = d && typeof d === "object" ? d : {};
  const c = d.confianza && typeof d.confianza === "object" ? d.confianza : {};
  const items = Array.isArray(d.items) ? d.items.slice(0, 60) : [];
  return {
    proveedor: { nombre: txt(d.proveedor?.nombre, 90), cuit: dig(d.proveedor?.cuit, 11) },
    comprobante: {
      tipo: TIPOS_CMP.includes(String(d.comprobante?.tipo || "").toUpperCase())
        ? String(d.comprobante.tipo).toUpperCase() : null,
      punto_venta: dig(d.comprobante?.punto_venta, 5),
      numero: dig(d.comprobante?.numero, 8),
    },
    fecha_emision: fecha(d.fecha_emision),
    fecha_vencimiento: fecha(d.fecha_vencimiento),
    // deno-lint-ignore no-explicit-any
    items: items.map((i: any) => ({
      cantidad: num(i?.cantidad), descripcion: txt(i?.descripcion, 90),
      precio_unitario: num(i?.precio_unitario), subtotal: num(i?.subtotal),
    })).filter((i: { descripcion: string | null; subtotal: number | null }) => i.descripcion || i.subtotal),
    subtotal_neto: num(d.subtotal_neto),
    iva: (Array.isArray(d.iva) ? d.iva.slice(0, 6) : [])
      // deno-lint-ignore no-explicit-any
      .map((x: any) => ({ alicuota: num(x?.alicuota), importe: num(x?.importe) }))
      .filter((x: { importe: number | null }) => x.importe != null),
    percepciones: (Array.isArray(d.percepciones) ? d.percepciones.slice(0, 8) : [])
      // deno-lint-ignore no-explicit-any
      .map((x: any) => ({ concepto: txt(x?.concepto, 40), importe: num(x?.importe) }))
      .filter((x: { importe: number | null }) => x.importe != null),
    otros_impuestos: num(d.otros_impuestos),
    total: num(d.total),
    moneda: txt(d.moneda, 5),
    categoria_sugerida: CATEGORIAS.includes(d.categoria_sugerida) ? d.categoria_sugerida : null,
    confianza: {
      proveedor: conf(c.proveedor), cuit: conf(c.cuit), comprobante: conf(c.comprobante),
      fecha: conf(c.fecha), items: conf(c.items), total: conf(c.total),
    },
    observaciones: txt(d.observaciones, 200),
  };
}

export async function manejar(req: Request, env: (k: string) => string | undefined = (k) => Deno.env.get(k)): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json(405, { error: "metodo", mensaje: "Usá POST" });

  const base = env("SUPABASE_URL");
  const apikey = req.headers.get("apikey") || "";
  const auth = req.headers.get("authorization") || "";
  if (!base || !apikey || !/^Bearer\s+\S+/.test(auth)) {
    return json(401, { error: "sesion", mensaje: "Falta la sesión del usuario" });
  }

  // 1. Sesión válida (Supabase Auth)
  let u: Response;
  try {
    u = await fetch(`${base}/auth/v1/user`, { headers: { apikey, Authorization: auth }, signal: AbortSignal.timeout(15_000) });
  } catch {
    return json(502, { error: "auth_red", mensaje: "No se pudo verificar la sesión. Probá de nuevo." });
  }
  if (!u.ok) return json(401, { error: "sesion", mensaje: "La sesión venció: volvé a ingresar" });

  // 2. Cuerpo
  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    const t = await req.text();
    if (t.length > MAX_B64 + 200_000) return json(413, { error: "tamano", mensaje: "El archivo es muy grande (máximo 5 MB)" });
    body = JSON.parse(t);
  } catch {
    return json(400, { error: "formato", mensaje: "Pedido inválido" });
  }
  const comercio = String(body?.comercio || "");
  const mime = String(body?.archivo?.mime || "");
  const b64 = String(body?.archivo?.base64 || "");
  if (!/^[0-9a-f-]{36}$/i.test(comercio)) return json(400, { error: "formato", mensaje: "Comercio inválido" });
  if (!TIPOS.includes(mime)) return json(415, { error: "tipo", mensaje: "Sólo JPG, PNG, WEBP o PDF" });
  if (!b64 || b64.length > MAX_B64 || !/^[A-Za-z0-9+/=]+$/.test(b64)) {
    return json(413, { error: "tamano", mensaje: "Archivo vacío, inválido o mayor a 5 MB" });
  }

  // 3. IA configurada
  const clave = env("ANTHROPIC_API_KEY");
  if (!clave) {
    return json(503, { error: "ia_no_configurada", mensaje: "La lectura con IA en la nube todavía no está activada" });
  }

  // 4. Rol y cuota (con la sesión del usuario: ia_consumir verifica que sea admin)
  const limite = Number(env("IA_LIMITE_DIARIO") || 100);
  let q: Response;
  try {
    q = await fetch(`${base}/rest/v1/rpc/ia_consumir`, {
      method: "POST",
      headers: { apikey, Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ p_comercio: comercio, p_limite: limite }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return json(502, { error: "cuota_red", mensaje: "No se pudo verificar la cuota. Probá de nuevo." });
  }
  if (!q.ok) {
    const e = await q.json().catch(() => ({}));
    const msg = String(e?.message || "");
    if (/límite/.test(msg)) return json(429, { error: "cuota", mensaje: msg });
    if (q.status >= 500 || /42883|PGRST202|does not exist|no existe/i.test(msg + (e?.code || ""))) {
      return json(503, { error: "ia_no_lista", mensaje: "Falta correr el script 03-compras-cajas.sql en Supabase" });
    }
    return json(403, { error: "permiso", mensaje: "Sólo el administrador del comercio puede leer comprobantes con IA" });
  }
  const restantes = await q.json().catch(() => null);

  // 5. Pedido a la IA (salida estructurada con una herramienta obligatoria)
  const pistas = body?.pistas && typeof body.pistas === "object" ? body.pistas : {};
  const pistaTxt = [
    pistas.qr ? `Datos del QR fiscal de ARCA ya leídos (son confiables): ${JSON.stringify(pistas.qr).slice(0, 600)}` : "",
    typeof pistas.texto === "string" && pistas.texto ? `Texto extraído del documento (puede tener errores):\n${pistas.texto.slice(0, 6000)}` : "",
  ].filter(Boolean).join("\n\n");
  const adjunto = mime === "application/pdf"
    ? { type: "document", source: { type: "base64", media_type: mime, data: b64 } }
    : { type: "image", source: { type: "base64", media_type: mime, data: b64 } };

  let r: Response;
  try {
    r = await fetch(env("ANTHROPIC_URL") || "https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": clave, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: env("IA_MODELO") || "claude-sonnet-5-5",
        max_tokens: 4096,
        tools: [{ name: "registrar_comprobante", description: "Registra los datos leídos del comprobante", input_schema: SCHEMA }],
        tool_choice: { type: "tool", name: "registrar_comprobante" },
        messages: [{ role: "user", content: [adjunto, { type: "text", text: PROMPT + (pistaTxt ? "\n\n" + pistaTxt : "") }] }],
      }),
      signal: AbortSignal.timeout(90_000),
    });
  } catch {
    return json(504, { error: "ia_red", mensaje: "La IA no respondió a tiempo. Probá de nuevo o cargalo a mano." });
  }
  if (!r.ok) {
    return json(502, { error: "ia", mensaje: `La IA devolvió un error (${r.status}). Probá de nuevo o cargalo a mano.` });
  }
  const res = await r.json().catch(() => null);
  // deno-lint-ignore no-explicit-any
  const uso = Array.isArray(res?.content) ? res.content.find((c: any) => c?.type === "tool_use") : null;
  if (!uso) return json(502, { error: "ia", mensaje: "La IA no pudo leer el comprobante" });
  if (res?.stop_reason === "max_tokens") {
    return json(502, { error: "ia_truncada", mensaje: "El comprobante tiene demasiados renglones para leerlo completo: cargalo a mano o por partes." });
  }

  return json(200, {
    ok: true,
    motor: "ia",
    modelo: String(res.model || ""),
    restantes_hoy: typeof restantes === "number" ? restantes : null,
    datos: sanear(uso.input),
  });
}

// En las pruebas locales se importa sin levantar el servidor.
if (Deno.env.get("RAVE_TEST") !== "1") Deno.serve((req) => manejar(req));
