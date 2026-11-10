/* Casos de uso de la agenda de cuidado y las evidencias privadas · RF-16, RS-013, D12/D13. © 2026 Equipo CuidaRed – INTEC. */
import { AppError, unavailable } from '../../lib/errors.js';
import { createAgendaRepository } from './agenda-repository.js';
import { EVIDENCIA_MAX_BYTES, EVIDENCIA_TIPOS } from './agenda-schemas.js';

export const EVIDENCIAS_BUCKET = 'evidencias';
export const DESCARGA_SEGUNDOS = 300;
// Vigencia de la URL de subida que emite Supabase Storage (createSignedUploadUrl): 2 horas.
export const SUBIDA_SEGUNDOS = 7200;

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/*
 * Reglas de negocio de fondo (series, estados, D12, alcance) viven en las RPC. Este servicio orquesta lo que la base no
 * puede hacer: firmar URLs de Storage con el JWT del usuario (las políticas de storage.objects deciden otra vez) y
 * comprobar que lo devuelto cumple el contrato (un contrato roto es indisponibilidad, nunca un resultado inventado).
 */
export function createAgendaService(access, { now = () => new Date() } = {}) {
  const repo = createAgendaRepository(access);

  return {
    async listTareas(cuentaId, query) {
      const result = await repo.listTareas(cuentaId, query);
      if (!isObject(result) || !Array.isArray(result.data) || !Number.isSafeInteger(result.total)) {
        throw unavailable();
      }
      return { rows: result.data, total: result.total };
    },
    getTarea: (cuentaId, tareaId) => repo.getTarea(cuentaId, tareaId),
    createTareas: (cuentaId, datos) => repo.createTareas(cuentaId, datos),
    updateTarea: (cuentaId, tareaId, datos) => repo.updateTarea(cuentaId, tareaId, datos),
    cancelTarea: (cuentaId, tareaId, datos) => repo.cancelTarea(cuentaId, tareaId, datos),
    startTarea: (cuentaId, tareaId) => repo.startTarea(cuentaId, tareaId),
    completeTarea: (cuentaId, tareaId) => repo.completeTarea(cuentaId, tareaId),
    registerEvidence: (cuentaId, tareaId, datos) => repo.registerEvidence(cuentaId, tareaId, datos),
    validateEvidence: (cuentaId, evidenciaId) => repo.validateEvidence(cuentaId, evidenciaId),
    rejectEvidence: (cuentaId, evidenciaId, motivo) =>
      repo.rejectEvidence(cuentaId, evidenciaId, motivo),

    /**
     * La base autoriza (cuidador asignado, tarea abierta, cupo) y genera la ruta
     * cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<ext>; solo entonces se firma la subida. El cliente nunca elige la ruta.
     */
    async requestUpload(cuentaId, tareaId, datos) {
      const prepared = await repo.prepareUpload(cuentaId, tareaId, datos);
      if (!isObject(prepared) || typeof prepared.ruta !== 'string') throw unavailable();
      const signed = await access.storage(EVIDENCIAS_BUCKET).signedUploadUrl(prepared.ruta);
      return {
        ruta: prepared.ruta,
        url_subida: signed.signedUrl,
        token: signed.token,
        bucket: EVIDENCIAS_BUCKET,
        expira_en_segundos: SUBIDA_SEGUNDOS,
        tipos_permitidos: EVIDENCIA_TIPOS,
        tamano_maximo_bytes: EVIDENCIA_MAX_BYTES,
      };
    },

    /**
     * Evidencias de la tarea, cada una con una URL firmada de descarga de 5 minutos. La ruta interna del bucket no se
     * devuelve. Las evidencias históricas y los objetos faltantes se devuelven sin URL de descarga.
     */
    async listEvidences(cuentaId, tareaId) {
      const rows = await repo.listEvidences(cuentaId, tareaId);
      if (!Array.isArray(rows)) throw unavailable();
      const storage = access.storage(EVIDENCIAS_BUCKET);
      const expira = new Date(now().getTime() + DESCARGA_SEGUNDOS * 1000).toISOString();
      return Promise.all(
        rows.map(async ({ ruta, ...evidencia }) => {
          if (evidencia.es_historica === true) {
            return { ...evidencia, url_descarga: null, url_expira_en: null };
          }
          if (typeof ruta !== 'string') throw unavailable();
          try {
            const url = await storage.signedDownloadUrl(ruta, DESCARGA_SEGUNDOS);
            return { ...evidencia, url_descarga: url, url_expira_en: expira };
          } catch (error) {
            if (error instanceof AppError && error.status === 404) {
              return { ...evidencia, url_descarga: null, url_expira_en: null };
            }
            throw error;
          }
        }),
      );
    },
  };
}
