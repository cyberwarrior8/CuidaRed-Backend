/* Resumen de casos, reportes estadísticos, exportaciones e informe médico · ID07/RF-07/RF-08. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { createReportesRepository } from './reportes-repository.js';
import {
  leerEnvejecienteId,
  leerExportacion,
  leerFiltrosReporte,
  leerTipo,
  queryResumen,
  sinParametros,
} from './reportes-schemas.js';
import {
  descargaCsv,
  exigirRequisitos,
  funcionalidadesDe,
  permisosDelTipo,
} from './reportes-service.js';

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió el contexto). requirePermiso responde antes con el
 * permiso y el acceso operativo (D07); el plan y los permisos por tipo se comprueban aquí y otra vez en la RPC.
 * Contrato: docs/contratos/reportes.md. Todas las respuestas llevan Cache-Control: no-store.
 */
export function createReportesRouter({ audit, now = () => new Date() }) {
  const router = Router({ mergeParams: true });
  const repo = (res) => createReportesRepository(res.locals.access.repository.rpc);
  const cuenta = (res) => res.locals.cuenta.cuentaId;
  const sinCache = (_req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  };
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });
  // El tipo de la ruta se valida antes que el permiso: un tipo desconocido es 404 sin consultar la base.
  const tipoDeRuta = (req, res, next) => {
    res.locals.tipoReporte = leerTipo(req.params.tipo);
    next();
  };
  const requisitosDelTipo = (_req, res, next) => {
    const tipo = res.locals.tipoReporte;
    exigirRequisitos(res.locals.cuenta, {
      permisos: permisosDelTipo(tipo),
      funcionalidades: funcionalidadesDe({ tipo }),
    });
    next();
  };

  router.use(
    ['/resumen-casos', '/reportes', '/envejecientes/:envejecienteId/informe-medico'],
    sinCache,
  );

  router.get('/resumen-casos', requirePermiso('resumen:ver'), async (req, res) => {
    res.json(await repo(res).resumen(cuenta(res), queryResumen(req.query)));
  });

  router.get('/resumen-casos/indicadores', requirePermiso('resumen:ver'), async (req, res) => {
    sinParametros(req.query);
    res.json({ data: await repo(res).indicadores(cuenta(res)) });
  });

  router.get('/resumen-casos/opciones', requirePermiso('resumen:ver'), async (req, res) => {
    sinParametros(req.query);
    res.json({ data: await repo(res).opciones(cuenta(res), 'resumen') });
  });

  router.get('/reportes/opciones', requirePermiso('reportes:ver'), async (req, res) => {
    exigirRequisitos(res.locals.cuenta, { funcionalidades: funcionalidadesDe() });
    sinParametros(req.query);
    res.json({ data: await repo(res).opciones(cuenta(res), 'reportes') });
  });

  router.get('/reportes/analisis-avanzado', requirePermiso('reportes:ver'), async (req, res) => {
    exigirRequisitos(res.locals.cuenta, {
      funcionalidades: funcionalidadesDe({ tipo: 'analisis_avanzado' }),
    });
    const filtros = leerFiltrosReporte(req.query, { tipo: 'analisis_avanzado' });
    res.json({ data: await repo(res).avanzado(cuenta(res), filtros) });
  });

  router.post('/reportes/exportaciones', requirePermiso('reportes:ver'), async (req, res) => {
    const datos = leerExportacion(req.body);
    exigirRequisitos(res.locals.cuenta, {
      permisos: permisosDelTipo(datos.tipo),
      funcionalidades: funcionalidadesDe(datos),
    });
    const data = await repo(res).registrarExportacion(cuenta(res), datos);
    registrar(res, 'reporte.exportacion_registrada');
    res.status(201).json({ data });
  });

  router.get(
    '/reportes/:tipo/exportacion',
    tipoDeRuta,
    requirePermiso('reportes:ver'),
    requisitosDelTipo,
    async (req, res) => {
      const tipo = res.locals.tipoReporte;
      const filtros = leerFiltrosReporte(req.query, { tipo, conFormato: true });
      const exportado = await repo(res).exportarCsv(cuenta(res), tipo, filtros);
      const { nombre, contenido } = descargaCsv(req.params.tipo, exportado, now());
      registrar(res, 'reporte.exportado_csv');
      res.set({
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="${nombre}"`,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      res.send(contenido);
    },
  );

  router.get(
    '/reportes/:tipo',
    tipoDeRuta,
    requirePermiso('reportes:ver'),
    requisitosDelTipo,
    async (req, res) => {
      const tipo = res.locals.tipoReporte;
      const filtros = leerFiltrosReporte(req.query, { tipo });
      res.json({ data: await repo(res).reporte(cuenta(res), tipo, filtros) });
    },
  );

  router.get(
    '/envejecientes/:envejecienteId/informe-medico',
    requirePermiso('informe:exportar'),
    async (req, res) => {
      sinParametros(req.query);
      const envejecienteId = leerEnvejecienteId(req.params.envejecienteId);
      const data = await repo(res).informeMedico(cuenta(res), envejecienteId);
      registrar(res, 'informe_medico.generado');
      res.json({ data });
    },
  );

  return router;
}
