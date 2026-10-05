-- =====================================================================
-- Sistema RAVE 1.2 · Compras con IA y auditoría de cajas cerradas
-- Rave Holding · correr DESPUÉS de 01-esquema.sql y 02-sincronizacion.sql.
-- Se puede correr las veces que haga falta (no borra datos).
--
-- Qué agrega:
--   1. Funciones auxiliares de lectura segura del JSON.
--   2. Vistas de consulta (endpoints REST con permisos por comercio):
--        /rest/v1/comprobantes_gasto   ·   /rest/v1/cierres_caja
--   3. Funciones para los gráficos y alertas:
--        /rest/v1/rpc/resumen_gastos   ·   /rest/v1/rpc/alertas_precios
--   4. Cuota diaria de la IA (la usa la función extraer-comprobante).
--   5. Depósito privado "comprobantes" para las fotos/PDF (cifrados en el
--      navegador antes de subir: la nube no puede ver la imagen).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Auxiliares
-- ---------------------------------------------------------------------
create or replace function public.jnum(x jsonb)
returns numeric language sql immutable set search_path = public, pg_temp as $$
  select case when jsonb_typeof(x) = 'number' then round((x #>> '{}')::numeric, 2) end
$$;

create or replace function public.jfecha(x text)
returns date language plpgsql immutable set search_path = public, pg_temp as $$
begin
  if x ~ '^\d{4}-\d{2}-\d{2}$' then return x::date; end if;
  return null;
exception when others then return null;
end $$;

create or replace function public.jts(x jsonb)
returns timestamptz language sql immutable set search_path = public, pg_temp as $$
  -- un valor absurdo (fuera de 1970-2100) da NULL en vez de romper las vistas y los reportes
  select case when jsonb_typeof(x) = 'number' and (x #>> '{}')::numeric between 0 and 4102444800000
              then to_timestamp((x #>> '{}')::double precision / 1000) end
$$;

create or replace function public.uuid_o_null(x text)
returns uuid language plpgsql immutable set search_path = public, pg_temp as $$
begin
  return x::uuid;
exception when others then return null;
end $$;

-- ---------------------------------------------------------------------
-- 2. Vistas (security_invoker: se aplican los permisos de "registros")
-- ---------------------------------------------------------------------
create or replace view public.comprobantes_gasto with (security_invoker = on) as
select r.comercio_id                                  as id_tenant,
       r.id                                           as id,
       r.datos->>'provId'                             as id_proveedor,
       r.datos#>>'{prov,nombre}'                      as proveedor,
       r.datos#>>'{prov,cuit}'                        as cuit_proveedor,
       r.datos->>'tipo'                               as tipo_comprobante,
       r.datos->>'nroCompleto'                        as numero_comprobante,
       public.jfecha(r.datos->>'fecha')               as fecha_emision,
       public.jfecha(r.datos->>'vence')               as fecha_vencimiento,
       r.datos->>'cat'                                as categoria,
       public.jnum(r.datos->'neto')                   as total_neto,
       public.jnum(r.datos->'iva')                    as total_iva,
       public.jnum(r.datos->'perc')                   as total_percepciones,
       public.jnum(r.datos->'otros')                  as otros_impuestos,
       public.jnum(r.datos->'total')                  as total_general,
       coalesce(r.datos->'extraido', '{}'::jsonb)     as datos_extraidos_json,
       coalesce(r.datos->'items', '[]'::jsonb)        as items_json,
       case when r.datos->>'estado' = 'verificado' then 'verificado' else 'pendiente' end as estado_revision,
       r.datos#>>'{adj,ruta}'                         as url_adjunto,
       r.datos#>>'{fuente,motor}'                     as motor_extraccion,
       r.datos->>'u'                                  as creado_por,
       public.jts(r.datos->'ts')                      as created_at,
       r.actualizado                                  as updated_at,
       case when r.datos->>'tipo' like 'NC%' then -1 else 1 end as signo,
       (r.datos->>'cuenta') is distinct from 'false'  as suma_gasto
  from public.registros r
 where r.coleccion = 'compras' and not r.borrado;

create or replace view public.cierres_caja with (security_invoker = on) as
select r.comercio_id                                  as id_tenant,
       r.id                                           as id,
       coalesce(r.datos->>'caja', r.datos->>'disp', 'principal') as id_caja,
       r.datos->>'disp'                               as id_dispositivo,
       r.datos->>'u'                                  as id_usuario_apertura,
       coalesce(r.datos->>'uCierre', r.datos->>'u')   as id_usuario_cierre,
       public.jts(r.datos->'abierto')                 as fecha_apertura,
       public.jts(r.datos->'cerrado')                 as fecha_cierre,
       public.jnum(r.datos->'inicial')                as saldo_inicial,
       public.jnum(r.datos#>'{resumen,ingresos}')     as total_ingresos,
       public.jnum(r.datos#>'{resumen,egresos}')      as total_egresos,
       public.jnum(coalesce(r.datos->'esperado', r.datos#>'{resumen,esperado}')) as saldo_esperado,
       public.jnum(r.datos->'contado')                as saldo_declarado,
       public.jnum(r.datos->'dif')                    as diferencia,
       r.datos->>'obs'                                as observaciones,
       jsonb_build_object('resumen', coalesce(r.datos->'resumen', '{}'::jsonb),
                          'movimientos', coalesce(r.datos->'movs', '[]'::jsonb),
                          'revision', coalesce(r.datos->'revision', '[]'::jsonb)) as log_detallado_json
  from public.registros r
 where r.coleccion = 'turnos' and not r.borrado and (r.datos->>'cerrado') is not null;

revoke all on public.comprobantes_gasto, public.cierres_caja from anon;
grant select on public.comprobantes_gasto, public.cierres_caja to authenticated;

-- ---------------------------------------------------------------------
-- 3. Datos para gráficos y alertas (sólo administradores del comercio)
-- ---------------------------------------------------------------------
create or replace function public.resumen_gastos(p_comercio uuid, p_desde date, p_hasta date)
returns jsonb
language plpgsql stable security invoker set search_path = public
as $$
declare
  v_res jsonb;
begin
  if public.rol_en(p_comercio) is distinct from 'admin' then
    raise exception 'sólo el administrador' using errcode = '42501';
  end if;
  if p_hasta < p_desde or p_hasta - p_desde > 800 then
    raise exception 'rango de fechas inválido (máximo 800 días)';
  end if;

  with c as (
    -- sólo lo que suma al gasto; las notas de crédito restan (igual que en la pantalla)
    select id_tenant, categoria, proveedor, cuit_proveedor, fecha_emision,
           signo * total_general as total_general, signo * total_iva as total_iva
      from public.comprobantes_gasto
     where id_tenant = p_comercio and estado_revision = 'verificado' and suma_gasto
       and fecha_emision between p_desde and p_hasta
  ), v as (
    select public.jts(r.datos->'ts') as ts, public.jnum(r.datos->'total') as total
      from public.registros r
     where r.comercio_id = p_comercio and r.coleccion = 'ventas' and not r.borrado
       and coalesce(r.datos->>'estado', 'ok') not in ('anulada','presupuesto','presupuesto_convertido','acreditada','nc')
       and public.jts(r.datos->'ts') >= (p_desde::timestamp at time zone 'America/Argentina/Salta')
       and public.jts(r.datos->'ts') < ((p_hasta + 1)::timestamp at time zone 'America/Argentina/Salta')
  ), meses as (
    select to_char(m, 'YYYY-MM') as mes
      from generate_series(date_trunc('month', p_desde::timestamp), date_trunc('month', p_hasta::timestamp), interval '1 month') m
  )
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'total_compras', coalesce((select sum(total_general) from c), 0),
    'total_iva', coalesce((select sum(total_iva) from c), 0),
    'comprobantes', (select count(*) from c),
    'pendientes', (select count(*) from public.comprobantes_gasto
                    where id_tenant = p_comercio and estado_revision = 'pendiente'),
    'por_categoria', coalesce((select jsonb_agg(jsonb_build_object('categoria', categoria, 'total', t) order by t desc)
                                 from (select coalesce(categoria, 'Sin categoría') as categoria, sum(total_general) as t
                                         from c group by 1) x), '[]'::jsonb),
    'por_proveedor', coalesce((select jsonb_agg(jsonb_build_object('proveedor', proveedor, 'cuit', cuit_proveedor, 'total', t) order by t desc)
                                 from (select coalesce(proveedor, 'Sin proveedor') as proveedor, cuit_proveedor, sum(total_general) as t
                                         from c group by 1, 2 order by 3 desc limit 10) x), '[]'::jsonb),
    'compras_vs_ventas', coalesce((select jsonb_agg(jsonb_build_object(
                                     'mes', meses.mes,
                                     'compras', coalesce((select sum(total_general) from c where to_char(fecha_emision, 'YYYY-MM') = meses.mes), 0),
                                     'ventas', coalesce((select sum(total) from v where to_char(v.ts at time zone 'America/Argentina/Salta', 'YYYY-MM') = meses.mes), 0))
                                     order by meses.mes) from meses), '[]'::jsonb)
  ) into v_res;
  return v_res;
end $$;

create or replace function public.alertas_precios(p_comercio uuid, p_umbral numeric default 15)
returns table (proveedor text, cuit text, insumo text, fecha date, precio numeric, precio_referencia numeric, variacion_pct numeric)
language plpgsql stable security invoker set search_path = public
as $$
begin
  if public.rol_en(p_comercio) is distinct from 'admin' then
    raise exception 'sólo el administrador' using errcode = '42501';
  end if;
  return query
  with it as (
    select c.proveedor, c.cuit_proveedor as cuit, c.fecha_emision as fecha,
           lower(regexp_replace(trim(i->>'desc'), '\s+', ' ', 'g')) as insumo,
           public.jnum(i->'pu') as pu
      from public.comprobantes_gasto c, jsonb_array_elements(c.items_json) i
     where c.id_tenant = p_comercio and c.estado_revision = 'verificado' and c.signo = 1
       and jsonb_typeof(i->'pu') = 'number' and (i->>'pu')::numeric > 0
       and length(trim(coalesce(i->>'desc', ''))) >= 3
  ), ord as (
    select it.*, row_number() over (partition by it.cuit, it.insumo order by it.fecha desc) as n
      from it
  ), ult as (
    select * from ord where n = 1
  ), ref as (
    select o.cuit, o.insumo, percentile_cont(0.5) within group (order by o.pu) as mediana, count(*) as cant
      from ord o where o.n between 2 and 4 group by 1, 2
  )
  select u.proveedor, u.cuit, u.insumo, u.fecha, u.pu,
         round(r.mediana::numeric, 2),
         round(((u.pu - r.mediana::numeric) / r.mediana::numeric) * 100, 1)
    from ult u join ref r on r.cuit is not distinct from u.cuit and r.insumo = u.insumo
   where r.mediana > 0 and abs((u.pu - r.mediana::numeric) / r.mediana::numeric) * 100 >= p_umbral
   order by abs((u.pu - r.mediana::numeric) / r.mediana::numeric) desc
   limit 50;
end $$;

revoke all on function public.resumen_gastos(uuid, date, date) from public, anon;
revoke all on function public.alertas_precios(uuid, numeric) from public, anon;
grant execute on function public.resumen_gastos(uuid, date, date) to authenticated;
grant execute on function public.alertas_precios(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Cuota diaria de la IA por comercio
-- ---------------------------------------------------------------------
create table if not exists public.uso_ia (
  comercio_id uuid not null,
  dia         date not null,
  cantidad    int  not null default 0,
  primary key (comercio_id, dia)
);
alter table public.uso_ia enable row level security;
revoke all on public.uso_ia from anon, authenticated;

-- Suma 1 al uso del día y devuelve cuántos quedan. Falla si no es admin o si
-- se pasó del límite. La llama la función extraer-comprobante con la sesión
-- del usuario (no con claves secretas).
create or replace function public.ia_consumir(p_comercio uuid, p_limite int default 100)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_dia date := (now() at time zone 'America/Argentina/Salta')::date;
  v_cant int;
  v_lim int := least(greatest(coalesce(p_limite, 100), 1), 1000);
begin
  if public.rol_en(p_comercio) is distinct from 'admin' then
    raise exception 'sólo el administrador puede usar la IA' using errcode = '42501';
  end if;
  insert into public.uso_ia (comercio_id, dia, cantidad) values (p_comercio, v_dia, 1)
  on conflict (comercio_id, dia) do update set cantidad = public.uso_ia.cantidad + 1
  returning cantidad into v_cant;
  if v_cant > v_lim then
    raise exception 'se alcanzó el límite diario de lecturas con IA (%)', v_lim using errcode = 'P0001';
  end if;
  return v_lim - v_cant;
end $$;
revoke all on function public.ia_consumir(uuid, int) from public, anon;
grant execute on function public.ia_consumir(uuid, int) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Depósito privado de comprobantes (sólo si existe Storage: en Supabase sí)
--    Ruta de cada archivo: {comercio_id}/{id_del_comprobante}.bin
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('comprobantes', 'comprobantes', false, 12582912, array['application/octet-stream'])
    on conflict (id) do update set public = false,
                                   file_size_limit = excluded.file_size_limit,
                                   allowed_mime_types = excluded.allowed_mime_types;

    execute 'drop policy if exists "comprobantes: ver" on storage.objects';
    execute 'drop policy if exists "comprobantes: subir" on storage.objects';
    execute 'drop policy if exists "comprobantes: reemplazar" on storage.objects';
    execute 'drop policy if exists "comprobantes: borrar" on storage.objects';
    execute $p$create policy "comprobantes: ver" on storage.objects for select to authenticated
      using (bucket_id = 'comprobantes' and public.rol_en(public.uuid_o_null((storage.foldername(name))[1])) = 'admin')$p$;
    execute $p$create policy "comprobantes: subir" on storage.objects for insert to authenticated
      with check (bucket_id = 'comprobantes' and public.rol_en(public.uuid_o_null((storage.foldername(name))[1])) = 'admin')$p$;
    execute $p$create policy "comprobantes: reemplazar" on storage.objects for update to authenticated
      using (bucket_id = 'comprobantes' and public.rol_en(public.uuid_o_null((storage.foldername(name))[1])) = 'admin')$p$;
    execute $p$create policy "comprobantes: borrar" on storage.objects for delete to authenticated
      using (bucket_id = 'comprobantes' and public.rol_en(public.uuid_o_null((storage.foldername(name))[1])) = 'admin')$p$;
  end if;
end $$;
