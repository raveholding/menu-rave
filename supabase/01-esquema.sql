-- =====================================================================
-- SISTEMA RAVE · Base multicomercio para Supabase
-- Etapa 1: tablas, aislamiento por comercio (RLS), roles y numeración
--
-- Cómo se corre: panel de Supabase → SQL Editor → New query → pegar todo
-- esto → Run. Se puede volver a correr sin romper nada.
--
-- La idea de fondo: TODAS las tablas llevan comercio_id, y una sola regla
-- por tabla dice "sólo ves las filas de los comercios donde sos miembro".
-- Esa regla la aplica Postgres, no el navegador: aunque alguien manipule el
-- código de la página, no puede leer datos de otro comercio.
-- =====================================================================

create extension if not exists pgcrypto;

-- =====================================================================
-- 1. COMERCIOS Y MIEMBROS
-- =====================================================================
create table if not exists public.comercios (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null check (length(nombre) between 2 and 90),
  rubro      text not null default 'comercio'
             check (rubro in ('comercio','gastronomia','servicios')),
  cuit       text,
  domicilio  text,
  whatsapp   text,
  plan       text not null default 'free',
  activo     boolean not null default true,
  creado     timestamptz not null default now()
);

do $$ begin
  create type public.rol_comercio as enum ('admin','mostrador','operador');
exception when duplicate_object then null; end $$;

create table if not exists public.miembros (
  usuario_id  uuid not null references auth.users(id) on delete cascade,
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  rol         public.rol_comercio not null default 'mostrador',
  creado      timestamptz not null default now(),
  primary key (usuario_id, comercio_id)
);
create index if not exists miembros_comercio on public.miembros (comercio_id);

-- --- Funciones de apoyo -------------------------------------------------
-- Van como SECURITY DEFINER a propósito: necesitan leer "miembros" sin que
-- las propias reglas de miembros se llamen a sí mismas en círculo.

create or replace function public.mis_comercios()
returns setof uuid
language sql stable security definer set search_path = public
as $$ select comercio_id from public.miembros where usuario_id = auth.uid() $$;

create or replace function public.rol_en(c uuid)
returns public.rol_comercio
language sql stable security definer set search_path = public
as $$ select rol from public.miembros where usuario_id = auth.uid() and comercio_id = c $$;

create or replace function public.es_admin(c uuid)
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.miembros
   where usuario_id = auth.uid() and comercio_id = c and rol = 'admin'
) $$;

-- =====================================================================
-- 2. CONFIGURACIÓN DEL COMERCIO
-- =====================================================================
create table if not exists public.config (
  comercio_id        uuid primary key references public.comercios(id) on delete cascade,
  sellos             int not null default 8 check (sellos between 3 and 20),
  premio             text default 'Un producto de regalo a elección del local',
  alcohol_desde      time not null default '07:00',
  alcohol_hasta      time not null default '00:00',
  permitir_sin_stock boolean not null default true,
  punto_venta        text not null default '0001',
  alias_mp           text,
  menu_url           text,
  wifi               jsonb not null default '{}'::jsonb,
  terminales         text[] not null default '{}',
  ip_local           inet,                -- red del local, para validar el fichaje
  contador_ventas    int not null default 0,
  contador_ot        int not null default 0,
  actualizado        timestamptz not null default now()
);

-- El secreto con el que se firman los códigos de sellos y de fichaje.
-- Esta tabla tiene RLS activo y NINGUNA política: con la clave pública del
-- navegador es ilegible. Sólo las Edge Functions (que usan la secret key)
-- pueden leerla. Así el secreto deja de viajar al cliente.
create table if not exists public.secretos (
  comercio_id uuid primary key references public.comercios(id) on delete cascade,
  hmac        text not null default encode(gen_random_bytes(32), 'base64'),
  creado      timestamptz not null default now()
);

-- =====================================================================
-- 3. CATÁLOGO E INVENTARIO
-- =====================================================================
create table if not exists public.categorias (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  clave       text not null,
  nombre      text not null,
  titulo      text,
  bajada      text default '',
  layout      text not null default 'grid' check (layout in ('grid','bodegas','rows')),
  alcohol     boolean not null default false,
  en_menu     boolean not null default true,
  orden       int not null default 0,
  unique (comercio_id, clave)
);

create table if not exists public.productos (
  id            uuid primary key default gen_random_uuid(),
  comercio_id   uuid not null references public.comercios(id) on delete cascade,
  categoria_id  uuid references public.categorias(id) on delete set null,
  nombre        text not null check (length(nombre) between 1 and 120),
  subtitulo     text default '',
  agrupado_en   text default '',
  precio        numeric(12,2) not null default 0 check (precio >= 0),
  costo         numeric(12,2) not null default 0 check (costo >= 0),
  stock         int not null default 0,
  minimo        int not null default 0,
  codigo_barras text default '',
  alcohol       boolean not null default false,
  en_menu       boolean not null default false,
  destacado     boolean not null default false,
  foto_url      text,
  activo        boolean not null default true,
  actualizado   timestamptz not null default now()
);
create index if not exists productos_comercio on public.productos (comercio_id);
create index if not exists productos_cb on public.productos (comercio_id, codigo_barras);

create table if not exists public.mov_stock (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  delta       int not null,
  motivo      text default '',
  usuario_id  uuid references auth.users(id) on delete set null,
  ts          timestamptz not null default now()
);
create index if not exists mov_stock_comercio_ts on public.mov_stock (comercio_id, ts desc);

-- =====================================================================
-- 4. VENTAS Y CAJA
-- =====================================================================
create table if not exists public.turnos (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  abierto     timestamptz not null default now(),
  cerrado     timestamptz,
  inicial     numeric(12,2) not null default 0,
  contado     numeric(12,2),
  diferencia  numeric(12,2),
  obs         text default '',
  usuario_id  uuid references auth.users(id) on delete set null
);
create index if not exists turnos_comercio on public.turnos (comercio_id, abierto desc);

create table if not exists public.ventas (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  nro         int,
  ts          timestamptz not null default now(),
  bruto       numeric(12,2) not null default 0,
  descuento   numeric(12,2) not null default 0,
  total       numeric(12,2) not null default 0,
  pago        text not null default 'efectivo'
              check (pago in ('efectivo','transferencia','debito','credito','cuenta')),
  cliente_id  uuid,
  usuario_id  uuid references auth.users(id) on delete set null,
  turno_id    uuid references public.turnos(id) on delete set null,
  mesa_nro    int,
  mozo_id     uuid,
  ot_id       uuid,
  fiscal      jsonb not null default '{}'::jsonb,
  arca        text not null default 'pendiente'
              check (arca in ('pendiente','facturada','no_fiscal')),
  estado      text not null default 'ok' check (estado in ('ok','anulada')),
  unique (comercio_id, nro)
);
create index if not exists ventas_comercio_ts on public.ventas (comercio_id, ts desc);

create table if not exists public.venta_items (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  venta_id    uuid not null references public.ventas(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre      text not null,
  cantidad    int not null check (cantidad > 0),
  precio      numeric(12,2) not null default 0,
  costo       numeric(12,2) not null default 0
);
create index if not exists venta_items_venta on public.venta_items (venta_id);

create table if not exists public.caja_movs (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  turno_id    uuid not null references public.turnos(id) on delete cascade,
  ts          timestamptz not null default now(),
  tipo        text not null check (tipo in ('venta','ingreso','egreso','gasto')),
  monto       numeric(12,2) not null default 0,
  detalle     text default ''
);
create index if not exists caja_movs_turno on public.caja_movs (turno_id, ts);

create table if not exists public.gastos (
  id                  uuid primary key default gen_random_uuid(),
  comercio_id         uuid not null references public.comercios(id) on delete cascade,
  ts                  timestamptz not null default now(),
  categoria           text not null default 'Otros',
  detalle             text default '',
  monto               numeric(12,2) not null default 0,
  pagado_en_efectivo  boolean not null default false,
  usuario_id          uuid references auth.users(id) on delete set null
);
create index if not exists gastos_comercio_ts on public.gastos (comercio_id, ts desc);

-- Numeración de comprobantes: corrida por comercio, sin saltos ni choques
create or replace function public.asignar_nro_venta()
returns trigger language plpgsql as $$
begin
  if new.nro is null then
    update public.config
       set contador_ventas = contador_ventas + 1
     where comercio_id = new.comercio_id
     returning contador_ventas into new.nro;
    if new.nro is null then
      raise exception 'el comercio % no tiene config creada', new.comercio_id;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists ventas_nro on public.ventas;
create trigger ventas_nro before insert on public.ventas
  for each row execute function public.asignar_nro_venta();

-- =====================================================================
-- 5. CLIENTES Y CUENTA CORRIENTE
-- =====================================================================
create table if not exists public.clientes (
  id               uuid primary key default gen_random_uuid(),
  comercio_id      uuid not null references public.comercios(id) on delete cascade,
  nombre           text not null,
  whatsapp_cifrado text,          -- cifrado en el navegador antes de subir
  email_cifrado    text,          -- idem
  cumple           date,
  consentimiento   boolean not null default false,
  sellos           int not null default 0,
  ultimo_sello     timestamptz,
  canjes           int not null default 0,
  notas            text default '',
  ts               timestamptz not null default now()
);
create index if not exists clientes_comercio on public.clientes (comercio_id);

create table if not exists public.pagos_cuenta (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  ts          timestamptz not null default now(),
  monto       numeric(12,2) not null check (monto > 0),
  medio       text not null default 'efectivo',
  detalle     text default '',
  usuario_id  uuid references auth.users(id) on delete set null
);
create index if not exists pagos_cuenta_cliente on public.pagos_cuenta (cliente_id, ts);

-- Saldo de la cuenta corriente: lo fiado menos lo pagado
create or replace function public.saldo_cliente(p_cliente uuid)
returns numeric language sql stable as $$
  select coalesce((select sum(total) from public.ventas
                    where cliente_id = p_cliente and pago = 'cuenta' and estado <> 'anulada'), 0)
       - coalesce((select sum(monto) from public.pagos_cuenta
                    where cliente_id = p_cliente), 0)
$$;

-- =====================================================================
-- 6. RUBRO GASTRONÓMICO
-- =====================================================================
create table if not exists public.mozos (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  nombre      text not null,
  comision    numeric(5,2) not null default 0 check (comision between 0 and 100)
);

create table if not exists public.mesas (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  nro         int not null,
  capacidad   int not null default 4,
  estado      text not null default 'libre' check (estado in ('libre','ocupada','cuenta')),
  mozo_id     uuid references public.mozos(id) on delete set null,
  abierta     timestamptz,
  unique (comercio_id, nro)
);

create table if not exists public.mesa_items (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  mesa_id     uuid not null references public.mesas(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre      text not null,
  cantidad    int not null check (cantidad > 0),
  precio      numeric(12,2) not null default 0,
  costo       numeric(12,2) not null default 0
);
create index if not exists mesa_items_mesa on public.mesa_items (mesa_id);

-- =====================================================================
-- 7. RUBRO SERVICIOS
-- =====================================================================
create table if not exists public.tecnicos (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  nombre      text not null,
  comision    numeric(5,2) not null default 0 check (comision between 0 and 100)
);

create table if not exists public.ots (
  id           uuid primary key default gen_random_uuid(),
  comercio_id  uuid not null references public.comercios(id) on delete cascade,
  cod          text not null,
  cliente_id   uuid references public.clientes(id) on delete set null,
  cliente_nom  text default '',
  equipo       text not null,
  falla        text default '',
  diagnostico  text default '',
  repuestos    text default '',
  costo_rep    numeric(12,2) not null default 0,
  total        numeric(12,2) not null default 0,
  estado       text not null default 'recibida'
               check (estado in ('recibida','diagnostico','presupuesto','reparacion','lista','entregada')),
  tecnico_id   uuid references public.tecnicos(id) on delete set null,
  urgente      boolean not null default false,
  cobrada_ts   timestamptz,
  ts           timestamptz not null default now(),
  unique (comercio_id, cod)
);
create index if not exists ots_comercio_estado on public.ots (comercio_id, estado);

create table if not exists public.ot_hist (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  ot_id       uuid not null references public.ots(id) on delete cascade,
  ts          timestamptz not null default now(),
  de          text,
  a           text,
  usuario_id  uuid references auth.users(id) on delete set null
);

-- =====================================================================
-- 8. PERSONAL Y ASISTENCIA
-- =====================================================================
create table if not exists public.empleados (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  nombre      text not null,
  puesto      text default '',
  dni_cifrado text,                -- cifrado en el navegador antes de subir
  ingreso     date,
  emitido     bigint not null default (extract(epoch from now()) * 1000)::bigint,
  activo      boolean not null default true
);
create index if not exists empleados_comercio on public.empleados (comercio_id);

create table if not exists public.fichadas (
  id           uuid primary key default gen_random_uuid(),
  comercio_id  uuid not null references public.comercios(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,
  ts           timestamptz not null default now(),
  tipo         text not null check (tipo in ('entrada','salida')),
  metodo       text not null default 'nfc' check (metodo in ('nfc','qr','lector','manual')),
  ip           inet,               -- para dejar asentado desde dónde se fichó
  usuario_id   uuid references auth.users(id) on delete set null
);
create index if not exists fichadas_emp_ts on public.fichadas (empleado_id, ts);

-- =====================================================================
-- 9. AUDITORÍA
-- =====================================================================
create table if not exists public.auditoria (
  id          uuid primary key default gen_random_uuid(),
  comercio_id uuid not null references public.comercios(id) on delete cascade,
  ts          timestamptz not null default now(),
  usuario_id  uuid references auth.users(id) on delete set null,
  accion      text not null,
  detalle     text default ''
);
create index if not exists auditoria_comercio_ts on public.auditoria (comercio_id, ts desc);

-- =====================================================================
-- 10. ALTA DE UN COMERCIO
-- Crea el comercio, deja al que lo crea como administrador, y le arma la
-- configuración y el secreto de firmas. Va como SECURITY DEFINER porque en
-- el momento del insert todavía no sos miembro de nada.
-- =====================================================================
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
  insert into public.miembros (usuario_id, comercio_id, rol) values (auth.uid(), nuevo, 'admin');
  insert into public.config   (comercio_id) values (nuevo);
  insert into public.secretos (comercio_id) values (nuevo);
  return nuevo;
end $$;

-- =====================================================================
-- 11. AISLAMIENTO POR COMERCIO (RLS)
-- Una regla por tabla: sólo ves y sólo escribís filas de tus comercios.
-- =====================================================================
alter table public.comercios enable row level security;
alter table public.miembros  enable row level security;
alter table public.secretos  enable row level security;   -- sin políticas: ilegible desde el navegador

drop policy if exists "mis comercios" on public.comercios;
create policy "mis comercios" on public.comercios for select to authenticated
  using (id in (select public.mis_comercios()));

drop policy if exists "editar mi comercio" on public.comercios;
create policy "editar mi comercio" on public.comercios for update to authenticated
  using (public.es_admin(id)) with check (public.es_admin(id));

drop policy if exists "mis membresias" on public.miembros;
create policy "mis membresias" on public.miembros for select to authenticated
  using (usuario_id = auth.uid() or public.es_admin(comercio_id));

drop policy if exists "admin gestiona miembros" on public.miembros;
create policy "admin gestiona miembros" on public.miembros for all to authenticated
  using (public.es_admin(comercio_id)) with check (public.es_admin(comercio_id));

-- Tablas comunes: cualquier miembro del comercio
do $$
declare t text;
begin
  foreach t in array array[
    'categorias','productos','mov_stock','ventas','venta_items','turnos','caja_movs',
    'gastos','clientes','pagos_cuenta','mesas','mesa_items','mozos','ots','ot_hist',
    'tecnicos','empleados','fichadas'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "mi comercio" on public.%I', t);
    execute format(
      'create policy "mi comercio" on public.%I for all to authenticated '
      'using (comercio_id in (select public.mis_comercios())) '
      'with check (comercio_id in (select public.mis_comercios()))', t);
  end loop;
end $$;

-- Config: todos la leen (el mostrador necesita el horario de alcohol), sólo el admin la toca
alter table public.config enable row level security;
drop policy if exists "leer config" on public.config;
create policy "leer config" on public.config for select to authenticated
  using (comercio_id in (select public.mis_comercios()));
drop policy if exists "admin edita config" on public.config;
create policy "admin edita config" on public.config for all to authenticated
  using (public.es_admin(comercio_id)) with check (public.es_admin(comercio_id));

-- Empleados: los ve cualquiera (la terminal valida contra ellos), los edita el admin
drop policy if exists "mi comercio" on public.empleados;
drop policy if exists "leer empleados" on public.empleados;
create policy "leer empleados" on public.empleados for select to authenticated
  using (comercio_id in (select public.mis_comercios()));
drop policy if exists "admin edita empleados" on public.empleados;
create policy "admin edita empleados" on public.empleados for all to authenticated
  using (public.es_admin(comercio_id)) with check (public.es_admin(comercio_id));

-- Auditoría: escribe cualquiera, lee sólo el admin
alter table public.auditoria enable row level security;
drop policy if exists "escribir auditoria" on public.auditoria;
create policy "escribir auditoria" on public.auditoria for insert to authenticated
  with check (comercio_id in (select public.mis_comercios()));
drop policy if exists "admin lee auditoria" on public.auditoria;
create policy "admin lee auditoria" on public.auditoria for select to authenticated
  using (public.es_admin(comercio_id));

-- =====================================================================
-- 11 bis. PERMISOS
-- RLS decide QUÉ filas ve cada uno; esto decide que el rol del navegador
-- pueda hablar con las tablas. Sin esto, da "permission denied" aunque la
-- regla de aislamiento esté bien.
-- =====================================================================
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to anon, authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
revoke all on public.secretos from anon, authenticated;

-- =====================================================================
-- 12. MENÚ PÚBLICO
-- El catálogo que ve el cliente desde el QR, sin iniciar sesión y sin
-- exponer costos ni stock. Es una vista: sólo lo que se muestra en el menú.
-- =====================================================================
create or replace view public.menu_publico
with (security_invoker = false) as
  select p.comercio_id, p.id, p.nombre, p.subtitulo, p.agrupado_en, p.precio,
         p.foto_url, p.destacado, c.clave as categoria, c.nombre as categoria_nombre,
         c.titulo as categoria_titulo, c.bajada, c.layout, c.alcohol, c.orden
    from public.productos p
    join public.categorias c on c.id = p.categoria_id
   where p.en_menu and p.activo and c.en_menu;

-- El menú se mira sin iniciar sesión: la vista corre con los permisos de su
-- dueño y sólo muestra lo publicado (ni costos, ni stock, ni clientes).
grant select on public.menu_publico to anon, authenticated;

-- =====================================================================
-- 13. TIEMPO REAL
-- Para que la segunda caja vea el stock y las mesas al instante.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['productos','ventas','mesas','mesa_items','ots','fichadas','caja_movs'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null;   -- en local no existe la publicación
    end;
  end loop;
end $$;

-- =====================================================================
-- 14. FOTOS DEL CATÁLOGO
-- =====================================================================
do $$ begin
  insert into storage.buckets (id, name, public) values ('catalogo','catalogo',true)
  on conflict (id) do nothing;
exception when undefined_table then null; end $$;
