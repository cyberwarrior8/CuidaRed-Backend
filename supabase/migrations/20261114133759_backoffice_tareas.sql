create extension if not exists pg_cron;
select cron.schedule('cuidared-backoffice-diario','0 6 * * *','select cuidared_interno.bo_mantenimiento()');
