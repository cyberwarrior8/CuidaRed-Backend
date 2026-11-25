/* Contratos de las rutas públicas de solicitudes de visita · V2 §Visita. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { ESTADOS_SOLICITUD } from '../visitas/visitas-schemas.js';

const texto = (min, max) => z.string().trim().min(min).max(max);
const persona = z
  .string()
  .trim()
  .min(2)
  .max(60)
  .regex(/^[\p{L}][\p{L}\s'.-]*$/u);
// Se aceptan los formatos habituales (000-0000000-0, 809 555 0100) y se envía la forma canónica.
const cedula = z
  .string()
  .trim()
  .transform((valor) => valor.replace(/[\s-]/g, ''))
  .pipe(z.string().regex(/^\d{11}$/));
const telefono = z
  .string()
  .trim()
  .transform((valor) => valor.replace(/[\s().-]/g, ''))
  .pipe(z.string().regex(/^\+?\d{10,15}$/));

// Toda solicitud nueva debe poder recibir los avisos de seguimiento.
const correo = z.string().trim().max(254).pipe(z.email());

export const crearSolicitudSchema = z
  .strictObject({
    idempotencia: z.uuid().optional(),
    cuenta_id: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
    nombres: persona,
    apellidos: persona,
    cedula,
    telefono,
    correo,
    tipo_visita: z.enum(['personal', 'institucional']).default('personal'),
    entidad_visitante: texto(2, 160).nullish(),
    tipo_entidad: z
      .enum([
        'fundacion',
        'iglesia',
        'universidad',
        'centro_educativo',
        'empresa',
        'grupo_comunitario',
        'otro',
      ])
      .nullish(),
    cantidad_visitantes: z.number().int().min(1).max(2147483647).default(1),
    aporte_previsto: texto(1, 300).nullish(),
    persona_a_visitar: texto(3, 120).nullish(),
    fecha_propuesta: z.iso.date(),
    hora_propuesta: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
    hora_fin_propuesta: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
    motivo: texto(3, 300),
  })
  .superRefine((datos, ctx) => {
    if (datos.hora_fin_propuesta <= datos.hora_propuesta)
      ctx.addIssue({
        code: 'custom',
        path: ['hora_fin_propuesta'],
        message: 'La hora de fin debe ser posterior al inicio.',
      });
    if (datos.tipo_visita === 'institucional') {
      for (const campo of ['entidad_visitante', 'tipo_entidad']) {
        if (!datos[campo])
          ctx.addIssue({ code: 'custom', path: [campo], message: 'Campo requerido.' });
      }
      if (datos.persona_a_visitar)
        ctx.addIssue({
          code: 'custom',
          path: ['persona_a_visitar'],
          message: 'La visita se dirige a la organización.',
        });
    } else if (
      !datos.persona_a_visitar ||
      datos.entidad_visitante ||
      datos.tipo_entidad ||
      datos.aporte_previsto
    ) {
      ctx.addIssue({
        code: 'custom',
        path: ['persona_a_visitar'],
        message: 'Revisa los datos de la visita personal.',
      });
    }
  });

// El código llega como texto libre; su formato se comprueba aparte para responder 404 genérico, no 422.
export const consultaSchema = z.strictObject({ codigo: z.string().max(64) });
export const observacionSchema = z.strictObject({
  codigo: z.string().max(64),
  observacion: z.string(),
});
export const textoObservacion = texto(3, 600);

// Salidas: lista cerrada de campos. Lo que la RPC devuelva de más nunca llega al público.
export const organizacionesSchema = z.array(
  z.object({ cuenta_id: z.number().int().positive(), nombre: z.string() }),
);
export const solicitudCreadaSchema = z.object({
  organizacion: z.string(),
  estado: z.literal('pendiente'),
  fecha_propuesta: z.string(),
  hora_propuesta: z.string(),
  hora_fin_propuesta: z.string().optional(),
});
export const estadoPublicoSchema = z.object({
  organizacion: z.string(),
  estado: z.enum(ESTADOS_SOLICITUD),
  fecha: z.string(),
  hora: z.string(),
  hora_fin_programada: z.string().nullish(),
  reprogramada: z.boolean().optional(),
  motivo_rechazo: z.string().nullable(),
  puede_registrar_observacion: z.boolean(),
  observacion: z.string().nullable(),
  puede_adjuntar_evidencias: z.boolean().optional(),
  inicio_observaciones: z.string().nullable().optional(),
  evidencias: z
    .array(z.object({ evidencia_id: z.uuid(), nombre_archivo: z.string(), fecha: z.string() }))
    .optional(),
});

export const ESTADO_TEXTO = {
  pendiente: 'Pendiente de autorización',
  autorizada: 'Autorizada',
  rechazada: 'No autorizada',
  realizada: 'Visita realizada',
  cancelada: 'Cancelada',
};
