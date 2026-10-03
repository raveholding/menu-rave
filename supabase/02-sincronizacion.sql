-- =====================================================================
-- SISTEMA RAVE · Etapa 2: varios dispositivos compartiendo los datos
--
-- Se corre DESPUÉS de 01-esquema.sql, igual que aquel: SQL Editor → pegar
-- todo → Run (si aparece el aviso de Supabase, "Ejecuta y habilita RLS").
-- Se puede correr más de una vez sin romper nada.
--
-- Cómo funciona:
--   · Cada registro del sistema (un producto, una venta, un cliente, una
--     fichada...) se guarda como una fila de "registros", con el mismo
--     formato que usa el panel. Así el panel no cambia y sincronizar es
--     simplemente subir las filas que cambiaron y bajar las nuevas.
--   · Las escrituras pasan SIEMPRE por la función sincronizar(), nunca
--     directo a la tabla. Ahí el servidor aplica sus reglas: quién puede
--     escribir qué, y el cálculo del stock.
--   · El stock NO lo manda el navegador: lo calcula el servidor sumando los
--     movimientos. Si dos cajas venden la misma botella al mismo tiempo, las
--     dos restan y el total cierra, en lugar de pisarse una a la otra.
--   · Los datos sensibles (teléfono, correo de clientes, DNI del personal)
--     llegan ya cifrados desde el navegador: el servidor no los puede leer.
-- =====================================================================

-- =====================================================================
-- 1. REGISTROS SINCRONIZADOS
-- =====================================================================
create table if not exists public.registros (
  comercio_id  uuid not null references public.comercios(id) on delete cascade,
  coleccion    text not null check (coleccion ~ '^[a-zA-Z]{2,24}$'),
  id           text not null check (length(id) between 1 and 80),
  datos        jsonb not null default '{}'::jsonb,
  borrado      boolean not null default false,
  dispositivo  text,
  usuario_id   uuid references auth.users(id) on delete set null,
  actualizado  timestamptz not null default clock_timestamp(),
  primary key (comercio_id, coleccion, id)
);
create index if not exists registros_cursor on public.registros (comercio_id, actualizado);

alter table public.registros enable row level security;

-- Leer: cualquier miembro del comercio. Escribir directo: nadie.
-- (sin políticas de escritura, la única vía es la función sincronizar)
drop policy if exists "leer registros de mi comercio" on public.registros;
create policy "leer registros de mi comercio" on public.registros for select to authenticated
  using (comercio_id in (select public.mis_comercios()));

revoke all on public.registros from anon;
revoke insert, update, delete, truncate on public.registros from authenticated;
grant select on public.registros to authenticated;

-- =====================================================================
-- 2. SINCRONIZAR: la única puerta de escritura
--
-- Recibe una lista de cambios:  [{ "c": coleccion, "id": id, "d": {datos},
--                                  "x": true si se borró, "h": true si es
--                                  un movimiento histórico ya aplicado }]
-- Devuelve cuántos aplicó, cuáles rechazó y por qué, y la hora del servidor.
--
-- Reglas (las aplica el servidor, no el navegador):
--   · Sólo se aceptan las colecciones del sistema.
--   · Movimientos de stock, auditoría y fichadas se escriben UNA vez y no se
--     tocan más (el dueño puede corregir fichadas).
--   · Mostrador y operador: no tocan productos, gastos ni personal; de la
--     configuración sólo pueden cambiar la clave del Wi-Fi.
--   · Un cambio con error se rechaza solo, sin trabar a los demás.
-- =====================================================================
create or replace function public.sincronizar(p_comercio uuid, p_dispositivo text, p_cambios jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_rol        public.rol_comercio;
  v_admin      boolean;
  v_cambio     jsonb;
  v_col        text;
  v_id         text;
  v_datos      jsonb;
  v_borrado    boolean;
  v_existe     jsonb;
  v_hay        boolean;
  v_aplicados  int := 0;
  v_rechazos   jsonb := '[]'::jsonb;
  v_delta      int;
  v_prod       text;
  v_pasada     int;
  v_motivo     text;
  c_todas      constant text[] := array['prod','mov','ventas','turnos','gastos','clientes','pagosCta',
                                        'mesas','mozos','ots','tecnicos','empleados','fichadas','audit','cfg'];
  c_una_vez    constant text[] := array['mov','audit','fichadas'];
  c_solo_admin constant text[] := array['prod','gastos','empleados'];
  c_borra_todos constant text[] := array['clientes','mesas','mozos','tecnicos','ots'];
begin
  v_rol := public.rol_en(p_comercio);
  if v_rol is null then
    raise exception 'no sos miembro de este comercio' using errcode = '42501';
  end if;
  v_admin := (v_rol = 'admin');
  if jsonb_typeof(p_cambios) <> 'array' then
    raise exception 'formato de cambios inválido';
  end if;
  if jsonb_array_length(p_cambios) > 500 then
    raise exception 'demasiados cambios juntos (máximo 500 por envío)';
  end if;

  -- Dos pasadas: primero todo lo que no es movimiento de stock (así un
  -- producto nuevo ya existe), después los movimientos.
  for v_pasada in 1..2 loop
    for v_cambio in select * from jsonb_array_elements(p_cambios) loop
      v_col    := v_cambio->>'c';
      v_id     := v_cambio->>'id';
      v_motivo := null;
      continue when (v_pasada = 1 and v_col = 'mov') or (v_pasada = 2 and v_col is distinct from 'mov');

      begin   -- cada cambio en su propia sub-transacción
        v_datos   := coalesce(v_cambio->'d', '{}'::jsonb);
        v_borrado := coalesce((v_cambio->>'x')::boolean, false);
        v_existe  := null;

        if v_col is null or v_id is null or length(v_id) > 80 or not (v_col = any(c_todas)) then
          v_motivo := 'colección o formato inválido';
        elsif jsonb_typeof(v_datos) <> 'object' or length(v_datos::text) > 400000 then
          v_motivo := 'datos inválidos o muy grandes';
        elsif not v_admin and v_col = any(c_solo_admin) then
          v_motivo := 'sólo el administrador';
        elsif v_borrado and not v_admin and not (v_col = any(c_borra_todos)) then
          v_motivo := 'sólo el administrador puede borrar esto';
        elsif v_borrado and v_col in ('mov', 'audit', 'cfg') then
          v_motivo := 'esto no se borra';
        end if;

        if v_motivo is null then
          select datos, true into v_existe, v_hay from public.registros
           where comercio_id = p_comercio and coleccion = v_col and id = v_id;
          v_hay := coalesce(v_hay, false);

          if v_col = any(c_una_vez) and v_hay and not (v_admin and v_col = 'fichadas') then
            -- ya estaba: se da por aplicado y no se toca
            v_aplicados := v_aplicados + 1;
            continue;
          end if;

          if v_col = 'cfg' and not v_admin then
            if not v_hay then
              v_motivo := 'la configuración la crea el administrador';
            elsif v_datos ? 'wifi' then
              v_datos := v_existe || jsonb_build_object('wifi', v_datos->'wifi');
            else
              v_datos := v_existe;
            end if;
          end if;
        end if;

        if v_motivo is not null then
          v_rechazos := v_rechazos || jsonb_build_object('c', v_col, 'id', v_id, 'motivo', v_motivo);
          continue;
        end if;

        if v_col = 'prod' and not v_hay then
          -- Producto nuevo: su stock es la suma de los movimientos que ya hayan
          -- llegado antes que él (normalmente ninguno). Después lo lleva el servidor.
          select coalesce(sum((r.datos->>'delta')::int), 0) into v_delta
            from public.registros r
           where r.comercio_id = p_comercio and r.coleccion = 'mov'
             and r.datos->>'prodId' = v_id and not coalesce((r.datos->>'_h')::boolean, false);
          v_datos := jsonb_set(v_datos, '{stock}', to_jsonb(v_delta));
        end if;

        if v_col = 'mov' then
          -- Un movimiento se escribe y se aplica UNA sola vez. Si dos cajas mandan
          -- el mismo a la vez, sólo la que lo inserta primero lo aplica.
          if coalesce((v_cambio->>'h')::boolean, false) then
            v_datos := v_datos || '{"_h": true}'::jsonb;
          else
            v_datos := v_datos - '_h';
          end if;
          v_delta := coalesce((v_datos->>'delta')::int, 0);
          insert into public.registros (comercio_id, coleccion, id, datos, borrado, dispositivo, usuario_id, actualizado)
          values (p_comercio, 'mov', v_id, v_datos, false, left(p_dispositivo, 40), auth.uid(), clock_timestamp())
          on conflict (comercio_id, coleccion, id) do nothing;
          if found and not coalesce((v_datos->>'_h')::boolean, false) then
            v_prod := v_datos->>'prodId';
            if v_prod is not null and v_delta <> 0 then
              update public.registros
                 set datos = jsonb_set(datos, '{stock}',
                               to_jsonb(coalesce((datos->>'stock')::int, 0) + v_delta)),
                     actualizado = clock_timestamp()
               where comercio_id = p_comercio and coleccion = 'prod' and id = v_prod;
            end if;
          end if;
          v_aplicados := v_aplicados + 1;
          continue;
        end if;

        -- El resto: gana el último que guardó. En los productos, el stock que
        -- queda es SIEMPRE el del servidor (se lee en el mismo momento de escribir).
        insert into public.registros (comercio_id, coleccion, id, datos, borrado, dispositivo, usuario_id, actualizado)
        values (p_comercio, v_col, v_id, v_datos, v_borrado, left(p_dispositivo, 40), auth.uid(), clock_timestamp())
        on conflict (comercio_id, coleccion, id) do update
          set datos       = case when registros.coleccion = 'prod'
                                 then jsonb_set(excluded.datos, '{stock}', coalesce(registros.datos->'stock', '0'::jsonb))
                                 else excluded.datos end,
              borrado     = excluded.borrado,
              dispositivo = excluded.dispositivo,
              usuario_id  = excluded.usuario_id,
              actualizado = clock_timestamp();
        v_aplicados := v_aplicados + 1;

      exception when others then
        v_rechazos := v_rechazos || jsonb_build_object('c', v_col, 'id', v_id, 'motivo', left(sqlerrm, 160));
      end;
    end loop;
  end loop;

  return jsonb_build_object('aplicados', v_aplicados, 'rechazos', v_rechazos, 'ahora', clock_timestamp());
end $$;

revoke all on function public.sincronizar(uuid, text, jsonb) from public, anon;
grant execute on function public.sincronizar(uuid, text, jsonb) to authenticated;

-- =====================================================================
-- 3. LLAVES: la misma llave de cifrado en todos los dispositivos
--
-- Los datos sensibles se cifran en el navegador con una llave del comercio.
-- Esa llave se guarda acá "envuelta" con la contraseña de cada usuario
-- (PBKDF2): el servidor guarda la caja cerrada, nunca la llave.
-- =====================================================================
create table if not exists public.llaves (
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  usuario_id  uuid not null references auth.users(id) on delete cascade,
  kdf         jsonb not null,
  wrap        jsonb not null,
  actualizado timestamptz not null default now(),
  primary key (comercio_id, usuario_id)
);
alter table public.llaves enable row level security;

drop policy if exists "mi llave" on public.llaves;
create policy "mi llave" on public.llaves for select to authenticated
  using (usuario_id = auth.uid());

drop policy if exists "guardar mi llave" on public.llaves;
create policy "guardar mi llave" on public.llaves for insert to authenticated
  with check (usuario_id = auth.uid() and comercio_id in (select public.mis_comercios()));

drop policy if exists "actualizar mi llave" on public.llaves;
create policy "actualizar mi llave" on public.llaves for update to authenticated
  using (usuario_id = auth.uid())
  with check (usuario_id = auth.uid() and comercio_id in (select public.mis_comercios()));

-- el dueño le entrega la llave a un usuario nuevo de su comercio
drop policy if exists "admin entrega llaves" on public.llaves;
create policy "admin entrega llaves" on public.llaves for all to authenticated
  using (public.es_admin(comercio_id)) with check (public.es_admin(comercio_id));

revoke all on public.llaves from anon;
grant select, insert, update, delete on public.llaves to authenticated;

-- =====================================================================
-- 4. MIEMBROS: un nombre visible para cada usuario del comercio
-- =====================================================================
alter table public.miembros add column if not exists email  text;
alter table public.miembros add column if not exists nombre text;

create or replace function public.crear_comercio(p_nombre text, p_rubro text default 'comercio')
returns uuid
language plpgsql security definer set search_path = public
as $$
declare nuevo uuid;
begin
  if auth.uid() is null then
    raise exception 'hay que iniciar sesión para crear un comercio';
  end if;
  insert into public.comercios (nombre, rubro)
       values (p_nombre, coalesce(p_rubro, 'comercio'))
    returning id into nuevo;
  insert into public.miembros (usuario_id, comercio_id, rol, email, nombre)
       values (auth.uid(), nuevo, 'admin',
               (select email from auth.users where id = auth.uid()), 'admin');
  insert into public.config   (comercio_id) values (nuevo);
  insert into public.secretos (comercio_id) values (nuevo);
  return nuevo;
end $$;

-- Mis comercios con mi rol: lo primero que pide el panel al iniciar sesión
create or replace function public.mis_comercios_info()
returns table (id uuid, nombre text, rubro text, rol public.rol_comercio)
language sql stable security definer set search_path = public
as $$
  select c.id, c.nombre, c.rubro, m.rol
    from public.miembros m join public.comercios c on c.id = m.comercio_id
   where m.usuario_id = auth.uid() and c.activo
   order by c.creado
$$;

-- El dueño suma a alguien de su equipo (el usuario ya tiene que existir)
create or replace function public.sumar_miembro(p_comercio uuid, p_usuario uuid, p_rol text, p_email text, p_nombre text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.es_admin(p_comercio) then
    raise exception 'sólo el administrador puede sumar usuarios' using errcode = '42501';
  end if;
  insert into public.miembros (usuario_id, comercio_id, rol, email, nombre)
       values (p_usuario, p_comercio, p_rol::public.rol_comercio, p_email, p_nombre)
  on conflict (usuario_id, comercio_id) do update
       set rol = excluded.rol, email = excluded.email, nombre = excluded.nombre;
end $$;

-- El dueño quita a alguien (nunca a sí mismo)
create or replace function public.quitar_miembro(p_comercio uuid, p_usuario uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.es_admin(p_comercio) then
    raise exception 'sólo el administrador puede quitar usuarios' using errcode = '42501';
  end if;
  if p_usuario = auth.uid() then
    raise exception 'no te podés quitar a vos mismo';
  end if;
  delete from public.llaves   where comercio_id = p_comercio and usuario_id = p_usuario;
  delete from public.miembros where comercio_id = p_comercio and usuario_id = p_usuario;
end $$;

-- Sumar por correo: para alguien que ya se había creado su cuenta
create or replace function public.sumar_miembro_email(p_comercio uuid, p_email text, p_rol text, p_nombre text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.es_admin(p_comercio) then
    raise exception 'sólo el administrador puede sumar usuarios' using errcode = '42501';
  end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'no existe ninguna cuenta con ese correo';
  end if;
  perform public.sumar_miembro(p_comercio, v_id, p_rol, lower(trim(p_email)), p_nombre);
  return v_id;
end $$;

-- El equipo del comercio (sólo lo ve el dueño)
create or replace function public.miembros_de(p_comercio uuid)
returns table (usuario_id uuid, email text, nombre text, rol public.rol_comercio, tiene_llave boolean)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.es_admin(p_comercio) then
    raise exception 'sólo el administrador ve el equipo' using errcode = '42501';
  end if;
  return query
    select m.usuario_id, coalesce(m.email, u.email::text), m.nombre, m.rol,
           exists (select 1 from public.llaves l where l.comercio_id = p_comercio and l.usuario_id = m.usuario_id)
      from public.miembros m left join auth.users u on u.id = m.usuario_id
     where m.comercio_id = p_comercio
     order by m.rol, m.email;
end $$;

revoke all on function public.sumar_miembro_email(uuid, text, text, text) from public, anon;
revoke all on function public.miembros_de(uuid) from public, anon;
revoke all on function public.sumar_miembro(uuid, uuid, text, text, text) from public, anon;
revoke all on function public.quitar_miembro(uuid, uuid) from public, anon;
revoke all on function public.mis_comercios_info() from public, anon;
grant execute on function public.sumar_miembro_email(uuid, text, text, text) to authenticated;
grant execute on function public.miembros_de(uuid) to authenticated;
grant execute on function public.crear_comercio(text, text) to authenticated;
grant execute on function public.mis_comercios_info() to authenticated;
grant execute on function public.sumar_miembro(uuid, uuid, text, text, text) to authenticated;
grant execute on function public.quitar_miembro(uuid, uuid) to authenticated;

-- =====================================================================
-- 5. MENÚ PÚBLICO POR COMERCIO
-- El catálogo que ve el cliente desde el QR. Lo escribe el panel cada vez
-- que se toca Inventario; lo lee cualquiera, sin iniciar sesión.
-- Sólo lleva lo publicable: nombre, precio, foto, categoría. Nada de costos,
-- stock ni clientes.
-- =====================================================================
create table if not exists public.menus (
  comercio_id uuid primary key references public.comercios(id) on delete cascade,
  datos       jsonb not null,
  actualizado timestamptz not null default now()
);
-- dirección corta del menú: ...github.io/menu-rave/?m=rave
alter table public.menus add column if not exists slug text;
do $$ begin
  alter table public.menus add constraint menus_slug_formato check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$');
exception when duplicate_object then null; end $$;
create unique index if not exists menus_slug_unico on public.menus (slug);
alter table public.menus enable row level security;

drop policy if exists "el menu es publico" on public.menus;
create policy "el menu es publico" on public.menus for select to anon, authenticated
  using (true);

drop policy if exists "publicar mi menu" on public.menus;
create policy "publicar mi menu" on public.menus for insert to authenticated
  with check (public.es_admin(comercio_id));

drop policy if exists "actualizar mi menu" on public.menus;
create policy "actualizar mi menu" on public.menus for update to authenticated
  using (public.es_admin(comercio_id))
  with check (public.es_admin(comercio_id));

revoke all on public.menus from anon, authenticated;
grant select on public.menus to anon, authenticated;
grant insert, update on public.menus to authenticated;

-- que la API vea las funciones y tablas nuevas enseguida
notify pgrst, 'reload schema';

-- Listo. Para comprobar: select count(*) from public.registros;  (tiene que dar 0)
