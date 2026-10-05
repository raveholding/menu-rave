/**
 * Aviso por mail de los pedidos de ayuda de Sistema RAVE  ·  Rave Holding
 * ---------------------------------------------------------------------
 * Se publica como "Aplicación web" desde la cuenta de Rave Holding (raveholding@gmail.com).
 * Supabase (función pedir_soporte) le hace un POST con { token, solicitud } y este script
 * te manda un mail con los datos. El TOKEN no está en el código: se guarda en
 * Configuración del proyecto → Propiedades de la secuencia de comandos (SOPORTE_TOKEN).
 */
var DESTINO = 'raveholding@gmail.com';

function doPost(e) {
  try {
    var datos = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var esperado = PropertiesService.getScriptProperties().getProperty('SOPORTE_TOKEN');
    if (!esperado || datos.token !== esperado) {
      return salida({ ok: false, error: 'token' });
    }
    var s = datos.solicitud || {};
    var motivos = { clave: 'Olvidó la contraseña', sistema: 'Problema con el sistema', ventas: 'Quiere el sistema', otro: 'Consulta' };
    var asunto = '[Sistema RAVE] #' + limpio(s.numero, 12) + ' · ' + (motivos[s.motivo] || 'Consulta') + ' · ' + limpio(s.comercio, 60);
    var cuerpo = [
      'Pedido de ayuda N.º ' + limpio(s.numero, 12),
      'Motivo: ' + (motivos[s.motivo] || s.motivo),
      'Comercio: ' + limpio(s.comercio, 80),
      'Nombre: ' + limpio(s.nombre, 80),
      'Contacto: ' + limpio(s.contacto, 120),
      'Usuario: ' + limpio(s.usuario, 120),
      'Versión: ' + limpio(s.version, 20) + ' · Equipo: ' + limpio(s.equipo, 120),
      'Fecha: ' + limpio(s.creado, 40),
      '',
      limpio(s.detalle, 1000),
      '',
      '— Si es una clave olvidada: verificá que sea quien dice ser (llamada o WhatsApp al número del comercio) ANTES de restablecer.',
      '— Restablecer: select public.soporte_restablecer_clave(\'correo@cliente.com\', \'ClaveTemporal-2026\');  (SQL Editor de Supabase)'
    ].join('\n');
    MailApp.sendEmail({ to: DESTINO, subject: asunto, body: cuerpo, name: 'Sistema RAVE' });
    return salida({ ok: true });
  } catch (err) {
    return salida({ ok: false, error: 'interno' });
  }
}

function limpio(v, max) {
  return String(v == null ? '' : v).replace(/[\u0000-\u001f]+/g, ' ').slice(0, max);
}
function salida(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
