/* Contratos de salida (DTO en snake_case) de cuentas, configuración y suscripción · CR-162/CR-164. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { unavailable } from '../../lib/errors.js';
import { ROLES, TIPOS_CUENTA } from './permisos.js';

/*
 * Lo que devuelven las RPC se valida y se reduce a una lista cerrada de campos antes de salir: un contrato roto de la
 * base es indisponibilidad (503), y una columna nueva en la RPC no se publica sin pasar por aquí.
 */
function leer(schema, valor) {
  const result = schema.safeParse(valor);
  if (!result.success) throw unavailable();
  return result.data;
}

const entero = z.number().int();
const textoOpcional = z.string().nullable();
const idCuenta = z
  .union([z.number().int().positive(), z.string().regex(/^[1-9]\d{0,17}$/)])
  .transform(String);
const estadoSuscripcion = z.enum(['prueba', 'activa', 'vencida', 'cancelada', 'suspendida']);
const fecha = z.iso.date();
const instante = z.iso
  .datetime({ offset: true })
  .transform((valor) => new Date(valor).toISOString());
const limite = entero.nullable();
const limites = z.object({ envejecientes: limite, usuarios: limite, familiares: limite });
const uso = z.object({
  envejecientes: entero.min(0),
  usuarios: entero.min(0),
  familiares: entero.min(0),
  voluntarios: entero.min(0),
});

/* ───────────── Contexto de cuenta (CONTRATO-ME, CR-164) ───────────── */

const contexto = z
  .object({
    cuenta_id: idCuenta,
    nombre: z.string(),
    tipo: z.enum(TIPOS_CUENTA),
    rol: z.enum(ROLES),
    permisos: z.array(z.string()),
    es_titular: z.boolean(),
    suscripcion_estado: estadoSuscripcion,
    acceso_operativo: z.boolean(),
    funcionalidades: z.array(z.string()),
    limites,
  })
  .transform((c) => ({
    cuenta_id: c.cuenta_id,
    nombre: c.nombre,
    tipo: c.tipo,
    rol: c.rol,
    estado_membresia: 'activa',
    permisos: c.permisos,
    estado_suscripcion: c.suscripcion_estado,
    funcionalidades: c.funcionalidades,
    es_titular: c.es_titular,
    acceso_operativo: c.acceso_operativo,
    limites: c.limites,
  }));

// Membresía pendiente de aceptar: aún no concede permisos ni acceso a la cuenta.
const pendiente = z
  .object({
    membresia_id: idCuenta,
    cuenta_id: idCuenta,
    nombre: z.string(),
    tipo: z.enum(TIPOS_CUENTA),
    rol: z.enum(ROLES),
  })
  .transform((p) => ({
    cuenta_id: p.cuenta_id,
    nombre: p.nombre,
    tipo: p.tipo,
    rol: p.rol,
    estado_membresia: 'pendiente',
    permisos: [],
    estado_suscripcion: null,
    funcionalidades: [],
    es_titular: false,
    acceso_operativo: false,
    limites: null,
    membresia_id: p.membresia_id,
  }));

const misCuentas = z.object({ activas: z.array(contexto), pendientes: z.array(pendiente) });

/** Contexto de una cuenta activa (respuesta de POST /cuentas y parte de GET /cuentas/:cuentaId). */
export const contextoDto = (crudo) => leer(contexto, crudo);

/** `cuentas` de GET /me: primero las activas, luego las pendientes de aceptar. */
export function cuentasMeDto(crudo) {
  const { activas, pendientes } = leer(misCuentas, crudo);
  return [...activas, ...pendientes];
}

/* ───────────── Cuenta activa ───────────── */

const detalleCuenta = z
  .object({
    cuenta: z.object({
      cuenta_id: idCuenta,
      nombre: z.string(),
      tipo: z.enum(TIPOS_CUENTA),
      categoria: z.object({ categoria_cuenta_id: entero, nombre: z.string() }),
      municipio: z.object({
        municipio_cod: z.string(),
        nombre: z.string(),
        provincia_cod: z.string(),
        provincia: z.string(),
      }),
      direccion: textoOpcional,
      telefono: textoOpcional,
      correo: textoOpcional,
      fecha_creacion: instante,
    }),
    contexto,
    uso,
  })
  .transform(({ cuenta, contexto: ctx, uso: usoCuenta }) => ({
    cuenta: {
      cuenta_id: cuenta.cuenta_id,
      nombre: cuenta.nombre,
      tipo: cuenta.tipo,
      categoria: cuenta.categoria,
      municipio: cuenta.municipio,
      direccion: cuenta.direccion,
      telefono: cuenta.telefono,
      correo: cuenta.correo,
      fecha_creacion: cuenta.fecha_creacion,
    },
    contexto: ctx,
    uso: usoCuenta,
  }));

/** GET y PATCH /cuentas/:cuentaId: datos de la cuenta, contexto del usuario y uso frente a los límites. */
export const detalleCuentaDto = (crudo) => leer(detalleCuenta, crudo);

/* ───────────── Configuración (RF-19) ───────────── */

const parametro = z.object({
  nombre: z.string(),
  valor: z.string(),
  tipo_dato: z.enum(['entero', 'decimal', 'booleano', 'texto']),
  es_propio: z.boolean(),
  valor_general: z.string(),
  descripcion: textoOpcional,
});

/** Parámetros efectivos: valor propio de la cuenta o, si no hay, el valor general (`es_propio` lo indica). */
export const configuracionDto = (crudo) => leer(z.array(parametro), crudo);

/* ───────────── Suscripción y vigencia (RF-20) ───────────── */

const planBase = z.object({
  plan_id: entero,
  nombre: z.string(),
  categoria: z.string(),
  precio: z.number().min(0),
  periodicidad: z.string(),
  duracion_dias: entero.nullable(),
  resumen: textoOpcional,
});
const planOfertado = planBase.extend({
  limites,
  funcionalidades: z.array(z.string()),
  es_actual: z.boolean(),
});
const suscripcion = z.object({
  estado: estadoSuscripcion,
  acceso_operativo: z.boolean(),
  prueba: z.object({
    gratuita: z.boolean(),
    vigente: z.boolean(),
    fecha_inicio: fecha.nullable(),
    fecha_fin: fecha.nullable(),
    dias_restantes: entero.min(0),
  }),
  plan: planBase.nullable(),
  fecha_fin_vigencia: fecha.nullable(),
  limites,
  uso,
  funcionalidades: z.array(z.string()),
  planes: z.array(planOfertado).nullish(),
});

/**
 * Suscripción de la cuenta. `planes` (con precio, límites y funcionalidades) solo se publica si el rol tiene
 * cuenta:suscripcion (`conPlanes`) y la base también lo entregó: la API y la RPC deben coincidir.
 */
export function suscripcionDto(crudo, { conPlanes }) {
  const { planes, ...resto } = leer(suscripcion, crudo);
  return conPlanes && planes ? { ...resto, planes } : resto;
}
