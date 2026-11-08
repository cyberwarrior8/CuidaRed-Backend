/* Contratos de entrada y salida de perfiles de adultos mayores y contactos · RF-01/RF-17. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { jsonBigintId } from '../../lib/bigint-id.js';
import { businessError } from '../../lib/business-errors.js';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { unavailable } from '../../lib/errors.js';

/* ───────────── Catálogos cerrados (sincronizados con src/domain/catalogos.ts del frontend y con el CHECK de BD) ───── */

export const SEXOS = ['F', 'M'];
export const AUTONOMIAS = ['independiente', 'parcial', 'dependiente'];
export const CONDICIONES = [
  'cronica',
  'movilidad',
  'cognitivo',
  'sensorial',
  'vive_solo',
  'sin_ingresos',
  'vivienda',
  'aislamiento',
];
export const ESTADOS = ['activo', 'inactivo', 'fallecido'];
export const MIN_CONTACTOS = 1;
export const MAX_CONTACTOS = 5;

/* ───────────── Validación de entrada (Zod, listas cerradas) ───────────── */

const compactar = (valor) => valor.replace(/\s+/g, ' ').trim();
const sinSeparadores = (valor) => valor.replace(/[\s-]/g, '');
const sinControl = (valor) => !/\p{Cc}/u.test(valor);

// Texto de una sola línea: espacios colapsados y longitud acotada.
const texto = (min, max) =>
  z.string().transform(compactar).pipe(z.string().min(min).max(max).refine(sinControl));
const nombre = (max = 60) => texto(2, max).pipe(z.string().regex(/^[\p{L}][\p{L}\s'.-]*$/u));

// Cédula: 11 dígitos; se aceptan guiones y espacios (000-0000000-0) y se guarda sin ellos.
const cedula = z
  .string()
  .transform(sinSeparadores)
  .pipe(z.string().regex(/^\d{11}$/));
// Teléfono del modelo: ^\+?[0-9]{10,15}$, tras quitar espacios y guiones.
const telefono = z
  .string()
  .transform(sinSeparadores)
  .pipe(z.string().regex(/^\+?\d{10,15}$/));
const telefonoOpcional = z
  .string()
  .transform(sinSeparadores)
  .transform((valor) => (valor === '' ? null : valor))
  .pipe(
    z
      .string()
      .regex(/^\+?\d{10,15}$/)
      .nullable(),
  )
  .nullable();

// La edad (60 a 120 años) la valida la RPC con la fecha de negocio (D09); aquí, formato y rango del modelo.
const fechaNacimiento = z.iso.date().refine((valor) => valor >= '1900-01-01');
const municipioCod = z.string().regex(/^[0-9]{4,6}$/);
const condiciones = z
  .array(z.enum(CONDICIONES))
  .max(CONDICIONES.length)
  .transform((lista) => [...new Set(lista)]);
const notaCondicion = z
  .string()
  .transform((valor) => valor.trim())
  .pipe(z.string().max(500))
  .transform((valor) => valor || null)
  .nullable();

// Consentimiento informado (Ley 172-13). Que esté otorgado y, si lo da un representante, su nombre, lo exige
// `exigirConsentimiento` con CR_CONSENTIMIENTO_REQUERIDO; aquí solo la forma.
const consentimiento = z
  .strictObject({
    otorgado: z.boolean(),
    otorgado_por: z.enum(['adulto', 'representante']),
    representante: nombre(120).nullish(),
  })
  .refine((valor) => valor.otorgado_por === 'representante' || valor.representante == null);

const camposContacto = {
  nombres: nombre(),
  apellidos: nombre(),
  parentesco: texto(2, 40),
  telefono,
};
export const contactoCrearSchema = z.strictObject({
  ...camposContacto,
  es_principal: z.boolean().default(false),
});
// El principal se cambia con POST /contactos/:id/principal, no con PATCH.
export const contactoEditarSchema = z
  .strictObject(camposContacto)
  .partial()
  .refine((valor) => Object.keys(valor).length > 0);

const camposPerfil = {
  nombres: nombre(),
  apellidos: nombre(),
  cedula,
  fecha_nacimiento: fechaNacimiento,
  sexo: z.enum(SEXOS),
  telefono: telefonoOpcional,
  municipio_cod: municipioCod,
  zona: texto(1, 60),
  direccion: texto(0, 150),
  autonomia: z.enum(AUTONOMIAS),
  condiciones,
  nota_condicion: notaCondicion,
};

// Los topes de contactos y el consentimiento se evalúan después con CR_* (ver exigir* más abajo): son reglas de negocio.
export const crearEnvejecienteSchema = z.strictObject({
  ...camposPerfil,
  telefono: camposPerfil.telefono.optional(),
  direccion: camposPerfil.direccion.optional(),
  condiciones: camposPerfil.condiciones.optional(),
  nota_condicion: camposPerfil.nota_condicion.optional(),
  consentimiento: consentimiento.optional(),
  contactos: z.array(contactoCrearSchema).max(20).optional(),
});

// Nunca estado, cuenta ni registrador: el estado cambia solo con POST …/estado.
export const editarEnvejecienteSchema = z
  .strictObject({ ...camposPerfil, consentimiento })
  .partial()
  .refine((valor) => Object.keys(valor).length > 0);

export const cambiarEstadoSchema = z
  .strictObject({
    estado: z.enum(ESTADOS),
    motivo: z
      .string()
      .transform(compactar)
      .pipe(z.string().max(200).refine(sinControl))
      .transform((valor) => valor || null)
      .nullish(),
  })
  // El motivo es obligatorio al inactivar (CR-172).
  .refine((valor) => valor.estado !== 'inactivo' || (valor.motivo?.length ?? 0) >= 3);

/** ¿Hay consentimiento otorgado y, si lo da un representante, con su nombre? (CR_CONSENTIMIENTO_REQUERIDO) */
export function exigirConsentimiento(valor) {
  const completo =
    valor?.otorgado === true &&
    (valor.otorgado_por === 'adulto' || Boolean(valor.representante?.length));
  if (!completo) throw businessError('CR_CONSENTIMIENTO_REQUERIDO');
}

/** De 1 a 5 contactos y exactamente uno principal (CR_CONTACTO_PRINCIPAL). */
export function exigirContactos(contactos) {
  if (
    !Array.isArray(contactos) ||
    contactos.length < MIN_CONTACTOS ||
    contactos.length > MAX_CONTACTOS ||
    contactos.filter((contacto) => contacto.es_principal).length !== 1
  ) {
    throw businessError('CR_CONTACTO_PRINCIPAL');
  }
}

/* ───────────── Colección (CR-162): orden por apellidos, nombres y fecha de creación ───────────── */

export const leerListado = createCollectionQuery({
  sortableFields: ['apellidos', 'nombres', 'fecha_creacion', 'envejeciente_id'],
  defaultSort: 'apellidos,nombres,fecha_creacion',
  tieBreaker: 'envejeciente_id',
  filterSchemas: { estado: z.enum(ESTADOS), municipio_cod: municipioCod },
});

/* ───────────── Salida (DTO snake_case por nivel de visibilidad) ───────────── */

/**
 * Nivel de visibilidad del usuario (D04, propuesta): `minimo` para el Voluntario, `completo` con adultos:ver-sensible
 * y `basico` para quien consulta sin ese permiso (Familiar). La RPC decide el mismo nivel; esta proyección es una
 * segunda barrera: aunque la base devolviera más, la respuesta nunca excede el nivel del rol.
 */
export function nivelDe(cuenta) {
  if (cuenta.rol === 'voluntario') return 'minimo';
  return cuenta.permisos.has('adultos:ver-sensible') ? 'completo' : 'basico';
}

const pick = (origen, claves) =>
  Object.fromEntries(
    claves.filter((clave) => origen?.[clave] !== undefined).map((clave) => [clave, origen[clave]]),
  );

const CAMPOS_CONTACTO = [
  'contacto_id',
  'envejeciente_id',
  'nombres',
  'apellidos',
  'parentesco',
  'telefono',
  'es_principal',
];
const CAMPOS_MINIMO = [
  'envejeciente_id',
  'estado',
  'nombres',
  'apellidos',
  'direccion',
  'zona',
  'municipio_cod',
  'municipio_nombre',
  'provincia_cod',
];
const CAMPOS_BASICO = [
  'cedula',
  'fecha_nacimiento',
  'sexo',
  'telefono',
  'fecha_creacion',
  'fecha_actualizacion',
];
const CAMPOS_COMPLETO = ['motivo_estado', 'fecha_estado'];
const CAMPOS_LISTA_MINIMO = [
  'envejeciente_id',
  'estado',
  'nombres',
  'apellidos',
  'municipio_cod',
  'zona',
  'fecha_creacion',
];

function esFila(fila) {
  return Boolean(fila) && typeof fila === 'object' && typeof fila.envejeciente_id === 'string';
}

export function serializeContacto(contacto) {
  const id = jsonBigintId.safeParse(contacto?.contacto_id);
  if (!id.success) throw unavailable();
  return { ...pick(contacto, CAMPOS_CONTACTO), contacto_id: id.data };
}

/** Perfil completo (detalle). Un contrato roto de la base es indisponibilidad, no un dato vacío. */
export function serializeAdulto(fila, nivel) {
  if (!esFila(fila)) throw unavailable();
  const salida = pick(fila, CAMPOS_MINIMO);
  salida.contacto_principal = fila.contacto_principal
    ? serializeContacto(fila.contacto_principal)
    : null;
  if (nivel !== 'minimo') {
    Object.assign(salida, pick(fila, CAMPOS_BASICO));
    salida.contactos = Array.isArray(fila.contactos) ? fila.contactos.map(serializeContacto) : [];
  }
  if (nivel === 'completo') {
    Object.assign(salida, pick(fila, CAMPOS_COMPLETO));
    salida.condicion_general = pick(fila.condicion_general, ['autonomia', 'condiciones', 'nota']);
    salida.consentimiento = pick(fila.consentimiento, [
      'otorgado',
      'otorgado_por',
      'representante',
      'fecha',
      'registrado_por',
    ]);
  }
  return salida;
}

/** Fila del listado: más corta que el detalle y con los mismos niveles de visibilidad. */
export function serializeItem(fila, nivel) {
  if (!esFila(fila)) throw unavailable();
  return {
    ...pick(fila, CAMPOS_LISTA_MINIMO),
    ...(nivel === 'minimo' ? {} : pick(fila, ['fecha_nacimiento', 'sexo'])),
    ...(nivel === 'completo' ? pick(fila, ['autonomia']) : {}),
  };
}

export function serializeEstado(fila) {
  if (
    !esFila(fila) ||
    !ESTADOS.includes(fila.estado) ||
    !['tareas_canceladas', 'alertas_resueltas', 'visitas_canceladas'].every((clave) =>
      Number.isSafeInteger(fila[clave]),
    )
  ) {
    throw unavailable();
  }
  return pick(fila, [
    'envejeciente_id',
    'estado',
    'motivo_estado',
    'fecha_estado',
    'tareas_canceladas',
    'alertas_resueltas',
    'visitas_canceladas',
  ]);
}
