# Aviso por mail de los pedidos de ayuda (Rave Holding)

Los pedidos de ayuda (clave olvidada, problemas, consultas comerciales) **siempre quedan guardados** en
Supabase → Table Editor → `solicitudes_soporte`. El aviso por mail es un extra: sin configurarlo, igual
llegan a la tabla (y el cliente puede escribirte por WhatsApp desde la misma pantalla).

## Activar el mail (una sola vez, ~10 minutos)

1. Entrá a https://script.google.com con la cuenta **raveholding@gmail.com** → *Proyecto nuevo*.
2. Pegá el contenido de `Code.gs`.
3. *Configuración del proyecto → Propiedades de la secuencia de comandos* → agregá `SOPORTE_TOKEN` con un valor largo y
   aleatorio (por ejemplo 40 caracteres). Guardalo, lo vas a necesitar en el paso 5.
4. *Implementar → Nueva implementación → Aplicación web*: ejecutar como **Yo**, acceso **Cualquier persona**. Autorizá el envío de
   correo y copiá la URL que termina en `/exec`.
5. En Supabase → SQL Editor:
   ```sql
   insert into public.soporte_config (id, url, token) values (1, 'URL_DEL_PASO_4', 'TOKEN_DEL_PASO_3')
   on conflict (id) do update set url = excluded.url, token = excluded.token;
   ```
6. Supabase → Database → Extensions: activá **pg_net** (si no está). [VERIFICAR] nombre y disponibilidad en tu plan.
7. Probá: en la pantalla de ingreso del sistema, "Necesito ayuda" → enviá un pedido. Tiene que llegar el mail.

## Cuando alguien olvida la clave

1. Te llega el pedido (mail o tabla `solicitudes_soporte`).
2. **Verificá que sea el dueño** (llamalo o escribile al WhatsApp que tenés del comercio).
3. Si tiene su **código de recuperación**: no necesita nada de vos, lo usa en "Olvidé mi contraseña".
4. Si es de la nube y no tiene el código: en el SQL Editor corré  
   `select public.soporte_restablecer_clave('correo@cliente.com', 'ClaveTemporal-2026');`  
   y pasale esa clave temporal en persona. Al entrar con ella el sistema le pide su código de recuperación o su
   clave anterior para volver a abrir la llave de los datos.
5. Sin contraseña **ni** código, los datos cifrados no se pueden recuperar (por diseño: ni Rave Holding puede abrirlos).
   Se puede crear una llave nueva y bajar los datos de la nube; se pierden los campos cifrados (WhatsApp, correo, DNI) y los adjuntos viejos.
