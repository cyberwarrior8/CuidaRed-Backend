/* Contratos de necesidades de adultos mayores · ID05/RF-03. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { ESTADOS as estadosEnvejeciente } from '../envejecientes/envejecientes-schema.js';

export const estadoNecesidad = z.enum(['pendiente', 'en_proceso', 'resuelta', 'cancelada']);
export const idCatalogo = z.int().min(1).max(32767);
const filtroIdCatalogo = z
  .string()
  .regex(/^[1-9]\d{0,4}$/)
  .transform(Number)
  .pipe(idCatalogo);
const fecha = z.iso.datetime({ offset: true });
const nullableText = z.string().nullable();
const texto = (min, max) => z.string().trim().min(min).max(max);
const responsableId = z.guid().nullable().optional();

export const crearNecesidadSchema = z
  .strictObject({
    necesidad_id: idCatalogo,
    prioridad_id: idCatalogo,
    descripcion: texto(5, 500),
    cantidad: z.number().positive().max(10000).nullish(),
    unidad_medida: texto(1, 64).nullish(),
    usuario_responsable_id: responsableId,
    indicacion_medica_id: z.guid().nullish(),
    es_recurrente: z.boolean().optional(),
  })
  .refine((datos) => (datos.cantidad != null) === (datos.unidad_medida != null));

export const actualizarNecesidadSchema = z
  .strictObject({ prioridad_id: idCatalogo.optional(), usuario_responsable_id: responsableId })
  .refine((datos) => Object.keys(datos).length > 0);

export const cambiarEstadoNecesidadSchema = z.discriminatedUnion('estado', [
  z.strictObject({ estado: z.literal('en_proceso') }),
  z.strictObject({ estado: z.enum(['resuelta', 'cancelada']), motivo: texto(3, 500) }),
]);

export const leerNecesidadesQuery = createCollectionQuery({
  sortableFields: ['fecha_necesidad', 'prioridad', 'estado', 'envejeciente_necesidad_id'],
  defaultSort: '-fecha_necesidad',
  tieBreaker: 'envejeciente_necesidad_id',
  filterSchemas: {
    envejeciente_id: z.guid(),
    estado: estadoNecesidad,
    activas: z.literal('true').transform(() => true),
    prioridad_id: filtroIdCatalogo,
    tipo_necesidad_id: filtroIdCatalogo,
  },
});

export const leerHistorialNecesidadQuery = createCollectionQuery({
  sortableFields: ['fecha', 'necesidad_evento_id'],
  defaultSort: '-fecha',
  tieBreaker: 'necesidad_evento_id',
});

export const leerCandidatosNecesidadQuery = createCollectionQuery({
  sortableFields: ['nombre', 'usuario_id'],
  defaultSort: 'nombre',
  tieBreaker: 'usuario_id',
});

export const candidatoDto = z.object({ usuario_id: z.guid(), nombre: z.string() });

export const necesidadDto = z.object({
  envejeciente_necesidad_id: z.guid(),
  envejeciente_id: z.guid(),
  envejeciente_nombre: z.string(),
  envejeciente_estado: z.enum(estadosEnvejeciente),
  necesidad_id: idCatalogo,
  necesidad_nombre: z.string(),
  tipo_necesidad_id: idCatalogo,
  tipo_necesidad_nombre: z.string(),
  prioridad_id: idCatalogo,
  prioridad: z.string(),
  estado: estadoNecesidad,
  descripcion: nullableText,
  cantidad: z.number().nullable(),
  unidad_medida: nullableText,
  fecha_necesidad: fecha,
  fecha_actualizacion: fecha,
  usuario_responsable_id: z.guid().nullable(),
  responsable: nullableText,
  indicacion_medica_id: z.guid().nullable(),
  fecha_resolucion: fecha.nullable(),
  motivo_resolucion: nullableText,
  registrado_por: z.guid().nullable(),
  resuelto_por: z.guid().nullable(),
  es_recurrente: z.boolean(),
});

export const necesidadEventoDto = z.object({
  necesidad_evento_id: z.guid(),
  fecha,
  actor: nullableText,
  estado_anterior: estadoNecesidad.nullable(),
  estado: estadoNecesidad,
  prioridad_id: idCatalogo,
  prioridad: z.string(),
  prioridad_anterior: nullableText,
  responsable_anterior: nullableText,
  responsable: nullableText,
  motivo: nullableText,
});
