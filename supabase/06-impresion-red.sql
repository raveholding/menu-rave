-- =====================================================================
-- Sistema RAVE 1.5.4 · Impresión en red (Wi‑Fi) + endurecimiento del servidor
-- Correr DESPUÉS de 01 a 05. Se puede correr las veces que haga falta.
--
--   · Agrega la colección "printq" (cola de impresión): el celular o la tablet
--     deja el ticket ahí y la PC del mostrador, que tiene la impresora Wi‑Fi,
--     lo imprime y lo borra. Cualquier usuario del comercio puede dejar y borrar.
--   · El servidor descarta "arcaCert" de la configuración: los certificados ARCA
--     NUNCA se guardan en la nube.
--   · Topes de seguridad en movimientos de stock (sin NaN ni cantidades absurdas).
--   · Es la misma función sincronizar() de 05 con esos cambios.
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
  v_rev_old    jsonb;
  v_rev_new    jsonb;
  v_hay        boolean;
  v_aplicados  int := 0;
  v_rechazos   jsonb := '[]'::jsonb;
  v_delta      numeric;
  v_prod       text;
  v_pasada     int;
  v_motivo     text;
  c_todas      constant text[] := array['prod','mov','ventas','turnos','gastos','clientes','pagosCta',
                                        'mesas','mozos','ots','tecnicos','empleados','fichadas','audit','cfg',
                                        'compras','proveedores','liquidaciones','printq'];
  c_una_vez    constant text[] := array['mov','audit','fichadas'];
  c_solo_admin constant text[] := array['prod','gastos','empleados','compras','proveedores','liquidaciones'];
  c_borra_todos constant text[] := array['clientes','mesas','mozos','tecnicos','ots','printq'];
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
        if v_col = 'cfg' and jsonb_typeof(v_datos) = 'object' then
          v_datos := v_datos - 'arcaCert';   -- certificados ARCA: jamás a la nube
        end if;
        v_borrado := coalesce((v_cambio->>'x')::boolean, false);
        v_existe  := null;

        if v_col is null or v_id is null or length(v_id) > 80 or not (v_col = any(c_todas)) then
          v_motivo := 'colección o formato inválido';
        elsif jsonb_typeof(v_datos) <> 'object' or length(v_datos::text) > 400000 then
          v_motivo := 'datos inválidos o muy grandes';
        elsif v_col = 'printq' and not v_borrado
              and (length(v_datos::text) > 20000
                   or (select count(*) from public.registros
                        where comercio_id = p_comercio and coleccion = 'printq' and not borrado) >= 200) then
          v_motivo := 'cola de impresión llena o trabajo demasiado grande';
        elsif not v_admin and v_col = any(c_solo_admin) then
          v_motivo := 'sólo el administrador';
        elsif v_borrado and not v_admin and not (v_col = any(c_borra_todos)) then
          v_motivo := 'sólo el administrador puede borrar esto';
        elsif v_borrado and v_col in ('mov', 'audit', 'cfg') then
          v_motivo := 'esto no se borra';
        end if;

        if v_motivo is null then
          select datos, true into v_existe, v_hay from public.registros
           where comercio_id = p_comercio and coleccion = v_col and id = v_id
             for update;
          v_hay := coalesce(v_hay, false);

          if v_col = any(c_una_vez) and v_hay and not (v_admin and v_col = 'fichadas') then
            -- ya estaba: se da por aplicado y no se toca
            v_aplicados := v_aplicados + 1;
            continue;
          end if;

          -- Una caja CERRADA queda congelada: nadie la cambia ni la borra.
          -- El administrador sólo puede sumarle notas de auditoría ("revision").
          if v_motivo is null and v_col = 'turnos' and v_hay and (v_existe->>'cerrado') is not null then
            if v_borrado then
              v_motivo := 'una caja cerrada no se borra';
            else
              -- Notas de auditoría: sólo se pueden AGREGAR al final (las anteriores no se tocan),
              -- con el usuario verificado por el servidor y el texto recortado.
              v_rev_old := case when jsonb_typeof(v_existe->'revision') = 'array' then v_existe->'revision' else '[]'::jsonb end;
              v_rev_new := v_datos->'revision';
              v_datos := v_existe;
              if v_admin and jsonb_typeof(v_rev_new) = 'array'
                 and jsonb_array_length(v_rev_new) > jsonb_array_length(v_rev_old)
                 and jsonb_array_length(v_rev_new) <= 100
                 and (select coalesce(jsonb_agg(jsonb_build_object('ts', e->'ts', 'txt', e->'txt') order by i), '[]'::jsonb)
                        from jsonb_array_elements(v_rev_new) with ordinality t(e, i)
                       where i <= jsonb_array_length(v_rev_old))
                     = (select coalesce(jsonb_agg(jsonb_build_object('ts', e->'ts', 'txt', e->'txt') order by i), '[]'::jsonb)
                          from jsonb_array_elements(v_rev_old) with ordinality t(e, i)) then
                v_datos := v_existe || jsonb_build_object('revision', v_rev_old || (
                  select coalesce(jsonb_agg(jsonb_build_object(
                           'ts', case when jsonb_typeof(e->'ts') = 'number' then e->'ts'
                                      else to_jsonb((extract(epoch from clock_timestamp()) * 1000)::bigint) end,
                           'u', left(coalesce(e->>'u', ''), 60),
                           'uid', auth.uid()::text,
                           'txt', left(coalesce(e->>'txt', ''), 200),
                           'ok', coalesce((e->>'ok')::boolean, false)) order by i), '[]'::jsonb)
                    from jsonb_array_elements(v_rev_new) with ordinality t(e, i)
                   where i > jsonb_array_length(v_rev_old) and jsonb_typeof(e) = 'object'));
              end if;
            end if;
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
          select coalesce(sum((r.datos->>'delta')::numeric), 0) into v_delta
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
          v_delta := coalesce((v_datos->>'delta')::numeric, 0);
          if v_delta = 'NaN'::numeric or abs(v_delta) > 1000000 then
            v_rechazos := v_rechazos || jsonb_build_object('c', v_col, 'id', v_id, 'motivo', 'cantidad inválida');
            continue;
          end if;
          insert into public.registros (comercio_id, coleccion, id, datos, borrado, dispositivo, usuario_id, actualizado)
          values (p_comercio, 'mov', v_id, v_datos, false, left(p_dispositivo, 40), auth.uid(), clock_timestamp())
          on conflict (comercio_id, coleccion, id) do nothing;
          if found and not coalesce((v_datos->>'_h')::boolean, false) then
            v_prod := v_datos->>'prodId';
            if v_prod is not null and v_delta <> 0 then
              update public.registros
                 set datos = jsonb_set(datos, '{stock}',
                               to_jsonb(coalesce((datos->>'stock')::numeric, 0) + v_delta)),
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
              actualizado = clock_timestamp()
          -- una caja ya cerrada (por otro dispositivo, en este mismo instante) no se pisa con una copia distinta
          where registros.coleccion <> 'turnos'
             or (registros.datos->>'cerrado') is null
             or (excluded.datos->>'cerrado') = (registros.datos->>'cerrado');
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

-- Menos superficie: crear un comercio sólo lo puede pedir alguien que ya inició sesión.
revoke all on function public.crear_comercio(text, text) from public, anon;
grant execute on function public.crear_comercio(text, text) to authenticated;
