-- =====================================================================
-- SISTEMA RAVE · Volver a probar desde cero (SÓLO PARA PRUEBAS)
--
-- Borra lo que los equipos subieron a la nube (productos, ventas, clientes,
-- llaves y menús publicados) de TODOS los comercios. Las cuentas y los
-- comercios quedan: al conectar de nuevo, "Usar este" vuelve a funcionar.
--
-- NO correr cuando el sistema ya está en uso real: no se puede deshacer.
-- =====================================================================
delete from public.registros;
delete from public.menus;
delete from public.llaves;

-- Para comprobar: las tres tienen que dar 0
select (select count(*) from public.registros) as registros,
       (select count(*) from public.menus)     as menus,
       (select count(*) from public.llaves)    as llaves;
