/* Acceso a resumen, reportes, exportaciones e informe médico mediante RPC de cuenta · ID07. © 2026 Equipo CuidaRed – INTEC. */
import { paginatedResponse } from '../../lib/collection-query.js';
import {
  avanzadoDto,
  exportacionDto,
  indicadoresDto,
  informeDto,
  leerSalida,
  reporteDto,
  resumenPagina,
} from './reportes-schemas.js';
import { z } from 'zod';

const csvDto = (tipo) => z.object({ exportacion: exportacionDto, reporte: reporteDto[tipo] });

export function createReportesRepository(rpc) {
  return {
    async resumen(cuentaId, query) {
      const raw = await rpc('api_resumen_casos_listar', {
        p_cuenta_id: cuentaId,
        p_filtros: { ...query.filters },
        p_orden: query.sort.map(
          ({ field, direction }) => (direction === 'desc' ? '-' : '') + field,
        ),
        p_limite: query.limit,
        p_desplazamiento: query.offset,
      });
      const { items, total } = leerSalida(resumenPagina, raw);
      return paginatedResponse(items, { ...query, total });
    },
    async indicadores(cuentaId) {
      const raw = await rpc('api_resumen_casos_indicadores', { p_cuenta_id: cuentaId });
      return leerSalida(indicadoresDto, raw);
    },
    async reporte(cuentaId, tipo, filtros) {
      const raw = await rpc('api_reporte', {
        p_cuenta_id: cuentaId,
        p_tipo: tipo,
        p_filtros: filtros,
      });
      return leerSalida(reporteDto[tipo], raw);
    },
    async avanzado(cuentaId, filtros) {
      const raw = await rpc('api_reporte_avanzado', { p_cuenta_id: cuentaId, p_filtros: filtros });
      return leerSalida(avanzadoDto, raw);
    },
    async exportarCsv(cuentaId, tipo, filtros) {
      const raw = await rpc('api_exportar_reporte_csv', {
        p_cuenta_id: cuentaId,
        p_tipo: tipo,
        p_filtros: filtros,
      });
      return leerSalida(csvDto(tipo), raw);
    },
    async registrarExportacion(cuentaId, datos) {
      const raw = await rpc('api_registrar_exportacion_reporte', {
        p_cuenta_id: cuentaId,
        p_datos: datos,
      });
      return leerSalida(exportacionDto, raw);
    },
    async informeMedico(cuentaId, envejecienteId) {
      const raw = await rpc('api_informe_medico', {
        p_cuenta_id: cuentaId,
        p_envejeciente_id: envejecienteId,
      });
      return leerSalida(informeDto, raw);
    },
  };
}
