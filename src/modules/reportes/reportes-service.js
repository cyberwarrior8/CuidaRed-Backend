/* Reglas de acceso por tipo y plan, y armado de las descargas · ID07/RF-08. © 2026 Equipo CuidaRed – INTEC. */
import { AppError } from '../../lib/errors.js';
import { reporteCsv } from './reportes-csv.js';

/*
 * Comprobaciones tempranas con el contexto de la cuenta (res.locals.cuenta); cada RPC las repite en la base.
 * Una funcionalidad ausente del plan responde 403 FORBIDDEN, el mismo mecanismo que las series de visitas.
 */

const sinPermiso = () =>
  new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.');

/** Permisos adicionales del tipo: el reporte de visitas exige `visitas:ver` (solo Organización, D05). */
export function permisosDelTipo(tipo) {
  return tipo === 'visitas' ? ['visitas:ver'] : [];
}

/** Funcionalidades del plan: `dashboard_metricas` siempre; Excel y análisis avanzado, también `reportes_avanzados`. */
export function funcionalidadesDe({ tipo, formato } = {}) {
  return formato === 'xlsx' || tipo === 'analisis_avanzado'
    ? ['dashboard_metricas', 'reportes_avanzados']
    : ['dashboard_metricas'];
}

/** Exige permisos y funcionalidades; requiere que requirePermiso ya haya comprobado el acceso operativo. */
export function exigirRequisitos(cuenta, { permisos = [], funcionalidades = [] }) {
  if (
    !permisos.every((p) => cuenta.permisos.has(p)) ||
    !funcionalidades.every((f) => cuenta.funcionalidades.has(f))
  ) {
    throw sinPermiso();
  }
}

const fechaNegocio = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Santo_Domingo',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

/** Descarga CSV: nombre seguro (tipo de la lista cerrada y fecha de negocio) y cuerpo con BOM. */
export function descargaCsv(tipoRuta, exportado, ahora) {
  const nombre = `reporte-${tipoRuta.replace(/[^a-z-]/g, '')}-${fechaNegocio.format(ahora)}.csv`;
  return { nombre, contenido: Buffer.from(reporteCsv(exportado), 'utf8') };
}
