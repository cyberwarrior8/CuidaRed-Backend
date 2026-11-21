-- Aplica después de aprobar la extensión pg_cron y el horario en el proyecto destino.
create extension if not exists pg_cron;
-- 06:00 UTC corresponde a las 02:00 de Santo Domingo.
select cron.schedule('cuidared-backoffice-diario','0 6 * * *','select cuidared_interno.bo_mantenimiento()');
