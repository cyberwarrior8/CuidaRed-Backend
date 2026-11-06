/* Contratos de entrada de la sincronización de visitas sin conexión · RF-10, RF-4.5, RNF-4.2. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { AppError } from '../../lib/errors.js';
import { sinNulos, visitaRealizadaSchema } from '../visitas/visitas-schemas.js';

// Propuesta técnica (D16): lote de hasta 25 operaciones, el tamaño que ya usa el cliente (TAMANO_LOTE).
export const MAX_OPERACIONES = 25;
export const RESULTADOS = ['aplicada', 'duplicada', 'conflicto', 'rechazada'];

const uuid = z.uuid();
const nombre = z.string().regex(/^[a-z][a-z_]{0,29}$/);

// ISO 8601 en UTC con «Z» (el cliente envía `new Date().toISOString()`). Se valida el día real del mes: Date.parse acepta 30 de febrero.
const MARCA_UTC =
  /^(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(\.\d{1,9})?Z$/;
function esMarcaUtc(valor) {
  const partes = MARCA_UTC.exec(valor);
  if (!partes) return false;
  const [anio, mes, dia] = [Number(partes[1]), Number(partes[2]), Number(partes[3])];
  const fecha = new Date(Date.UTC(anio, mes - 1, dia));
  return (
    fecha.getUTCFullYear() === anio && fecha.getUTCMonth() === mes - 1 && fecha.getUTCDate() === dia
  );
}
const marcaUtc = z.string().refine(esMarcaUtc);

/** Lote: solo el sobre. Cada operación se valida aparte para que una mala no bloquee a las demás. */
const loteSchema = z.strictObject({
  operaciones: z.array(z.unknown()).min(1).max(MAX_OPERACIONES),
});

/*
 * Operación del cliente. `entidad` y `tipo` admiten cualquier nombre bien formado: lo que no se soporta se responde por
 * operación (ENTIDAD_NO_SOPORTADA, TIPO_NO_SOPORTADO) en lugar de rechazar el lote, y así los pendientes de una entidad
 * que llegue en una fase posterior (necesidades, fase 5) no se pierden. El usuario, la cuenta y el rol nunca vienen aquí.
 */
const operacionSchema = z.strictObject({
  id_cliente: uuid,
  entidad: nombre,
  tipo: nombre,
  registro_id: uuid,
  datos: z.record(z.string(), z.unknown()),
  actualizado_en: marcaUtc,
  base_actualizado_en: marcaUtc.nullish(),
});

/*
 * Datos por entidad y tipo (punto de extensión: la fase 5 agrega `necesidad`). Cada esquema es el de la API en línea:
 * `registrar` equivale a POST /visitas/realizada sin `visita_id` (el id de la visita es `registro_id`) e `iniciar` a
 * POST /visitas/:id/iniciar, que no lleva datos.
 */
const ENTIDADES = Object.freeze({
  visita: Object.freeze({
    registrar: visitaRealizadaSchema.omit({ visita_id: true }),
    iniciar: z.strictObject({}),
  }),
});

const datosSchema = (entidad, tipo) =>
  Object.hasOwn(ENTIDADES, entidad) && Object.hasOwn(ENTIDADES[entidad], tipo)
    ? ENTIDADES[entidad][tipo]
    : null;

const rechazo422 = () => new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');

/** Los identificadores de la ruta son UUID; cualquier otra cosa es "no existe" (sin tocar la base). */
export function uuidParam(value) {
  if (!uuid.safeParse(value).success) {
    throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  }
  return value;
}

/** Valida el sobre del lote (1 a 25 operaciones) y devuelve las operaciones sin interpretar. 422 genérico si no cumple. */
export function leerLote(body) {
  const parsed = loteSchema.safeParse(body ?? {});
  if (!parsed.success) throw rechazo422();
  return parsed.data.operaciones;
}

const idDe = (raw, campo) => {
  const valor = raw !== null && typeof raw === 'object' ? raw[campo] : undefined;
  const parsed = uuid.safeParse(valor);
  return parsed.success ? parsed.data : null;
};

/**
 * Valida una operación. Si es válida devuelve `{ operacion }` listo para la RPC (sin nulos y, si la entidad o el tipo no están
 * soportados, con `datos` vacíos: su contenido no se envía a la base). Si no, `{ invalida: { idCliente, registroId } }`: el
 * identificador de la operación se devuelve solo si es un UUID, para poder responder esa operación como rechazada.
 */
export function leerOperacion(raw) {
  const base = operacionSchema.safeParse(raw);
  const invalida = () => ({
    invalida: { idCliente: idDe(raw, 'id_cliente'), registroId: idDe(raw, 'registro_id') },
  });
  if (!base.success) return invalida();
  const { datos, base_actualizado_en: baseMarca, ...resto } = base.data;
  const schema = datosSchema(resto.entidad, resto.tipo);
  let datosValidos = {};
  if (schema) {
    const parsed = schema.safeParse(datos);
    if (!parsed.success) return invalida();
    datosValidos = sinNulos(parsed.data);
  }
  return {
    operacion: {
      ...resto,
      datos: datosValidos,
      ...(baseMarca ? { base_actualizado_en: baseMarca } : {}),
    },
  };
}
