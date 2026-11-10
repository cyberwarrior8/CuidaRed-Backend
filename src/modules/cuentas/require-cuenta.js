/* Contexto de cuenta activa, permisos y acceso operativo por petición · RF-09/RF-11/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { AppError, unavailable } from '../../lib/errors.js';
import { isBigintId, jsonBigintId } from '../../lib/bigint-id.js';
import { ACCIONES_SIN_ACCESO_OPERATIVO } from './permisos.js';

/*
 * Todas las rutas de una cuenta cuelgan de /api/v1/cuentas/:cuentaId. La cuenta viaja en la ruta (no en cabeceras
 * ni en el cuerpo) y NUNCA concede acceso por sí misma: `api_contexto_cuenta` comprueba en la base, con el JWT, que
 * el usuario tiene una membresía activa en esa cuenta y devuelve su rol, permisos y estado de suscripción.
 * Las RPC de cada módulo vuelven a autorizar (defensa en profundidad): este middleware solo responde antes y con
 * errores claros.
 */

const sinPermiso = () =>
  new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.');
const sinAcceso = () =>
  new AppError(
    403,
    'SUBSCRIPTION_INACTIVE',
    'La cuenta no tiene una prueba o un plan vigente. Solo puedes gestionar la cuenta y su suscripción.',
  );

/** Valida y normaliza el contexto devuelto por la RPC; un contrato roto es indisponibilidad, no permiso. */
export function readContext(ctx) {
  if (
    !ctx ||
    typeof ctx !== 'object' ||
    !['familia', 'organizacion'].includes(ctx.tipo) ||
    typeof ctx.rol !== 'string' ||
    !Array.isArray(ctx.permisos) ||
    typeof ctx.acceso_operativo !== 'boolean'
  ) {
    throw unavailable();
  }
  const cuentaId = jsonBigintId.safeParse(ctx.cuenta_id);
  const membresiaId = jsonBigintId.nullish().safeParse(ctx.membresia_id);
  if (!cuentaId.success || !membresiaId.success) throw unavailable();
  return {
    cuentaId: cuentaId.data,
    tipo: ctx.tipo,
    rol: ctx.rol,
    membresiaId: membresiaId.data ?? null,
    permisos: new Set(ctx.permisos),
    esTitular: ctx.es_titular === true,
    accesoOperativo: ctx.acceso_operativo,
    suscripcionEstado: ctx.suscripcion_estado ?? null,
    funcionalidades: new Set(Array.isArray(ctx.funcionalidades) ? ctx.funcionalidades : []),
  };
}

/** Resuelve la cuenta de la ruta para el usuario autenticado (requiere requireSession antes). */
export function requireCuenta() {
  return async (req, res, next) => {
    const { cuentaId } = req.params;
    if (!isBigintId(cuentaId)) {
      throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
    }
    const ctx = await res.locals.access.repository.rpc('api_contexto_cuenta', {
      p_cuenta_id: cuentaId,
    });
    // Sin membresía activa la cuenta "no existe" para el usuario: no se revela si existe.
    if (!ctx) throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
    res.locals.cuenta = readContext(ctx);
    if (res.locals.cuenta.cuentaId !== cuentaId) throw unavailable();
    res.locals.contextoCuenta = ctx;
    next();
  };
}

/**
 * Exige al menos una de las acciones. Salvo las de gestión de cuenta/suscripción, exige además acceso operativo
 * (prueba o plan vigente): al vencer, se bloquean lectura y escritura de módulos operativos (D07).
 */
export function requirePermiso(...acciones) {
  if (!acciones.length) throw new Error('requirePermiso necesita al menos una acción.');
  return (_req, res, next) => {
    const cuenta = res.locals.cuenta;
    if (!cuenta) throw new Error('requirePermiso requiere requireCuenta antes.');
    const permitida = acciones.find((a) => cuenta.permisos.has(a));
    if (!permitida) throw sinPermiso();
    if (!cuenta.accesoOperativo && !ACCIONES_SIN_ACCESO_OPERATIVO.includes(permitida))
      throw sinAcceso();
    next();
  };
}

/** Para rutas operativas que no dependen de una acción concreta (p. ej. lectura de catálogos de la cuenta). */
export function requireAccesoOperativo() {
  return (_req, res, next) => {
    if (!res.locals.cuenta?.accesoOperativo) throw sinAcceso();
    next();
  };
}
