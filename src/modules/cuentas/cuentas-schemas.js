/* Contratos de entrada de cuentas, configuración y suscripción · ID02/RF-11/RF-19. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { AppError } from '../../lib/errors.js';
import { TIPOS_CUENTA } from './permisos.js';

/** Valida la entrada del cliente; el detalle del fallo no se devuelve (CR-162). */
export function parseInput(schema, data) {
  const result = schema.safeParse(data);
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}

const vacioANull = (valor) => (valor === '' ? null : valor);

// Mismos dominios que las restricciones de cuidared.cuenta y que la RPC (que vuelve a validar).
const nombre = z.string().trim().min(2).max(120);
const categoriaCuentaId = z.number().int().min(1).max(32767);
const municipioCod = z.string().regex(/^[0-9]{4,6}$/);
const direccion = z.string().trim().max(150).transform(vacioANull).nullable();
// El teléfono se normaliza aquí (sin espacios ni guiones) antes de comprobar `^\+?[0-9]{10,15}$`.
const telefono = z
  .string()
  .max(40)
  .transform((valor) => valor.replace(/[\s-]/g, ''))
  .refine((valor) => valor === '' || /^\+?[0-9]{10,15}$/.test(valor))
  .transform(vacioANull)
  .nullable();
const correo = z
  .string()
  .trim()
  .toLowerCase()
  .max(254)
  .refine((valor) => valor === '' || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(valor))
  .transform(vacioANull)
  .nullable();

/** POST /cuentas: autorregistro del titular. El titular, el rol y la prueba salen del servidor. */
export const crearCuentaSchema = z.strictObject({
  tipo: z.enum(TIPOS_CUENTA),
  nombre,
  categoria_cuenta_id: categoriaCuentaId,
  municipio_cod: municipioCod,
  direccion: direccion.optional(),
  telefono: telefono.optional(),
  correo: correo.optional(),
});

/** PATCH /cuentas/:cuentaId: no admite tipo, titular ni suscripción. `null` vacía dirección, teléfono o correo. */
export const actualizarCuentaSchema = z
  .strictObject({
    nombre,
    categoria_cuenta_id: categoriaCuentaId,
    municipio_cod: municipioCod,
    direccion,
    telefono,
    correo,
  })
  .partial()
  .refine((valor) => Object.keys(valor).length > 0);

/*
 * PATCH /cuentas/:cuentaId/configuracion: { valores: { nombre: valor | null } }. Los valores se guardan como texto:
 * números y booleanos JSON se normalizan a su texto ('30', 'true'). La RPC valida nombre y dominio por tipo de dato.
 */
const valorParametro = z.union([z.string().max(1000), z.number().finite(), z.boolean(), z.null()]);
export const actualizarConfiguracionSchema = z
  .strictObject({
    valores: z
      .record(z.string().regex(/^[a-z][a-z0-9_]{0,63}$/), valorParametro)
      .refine((valores) => {
        const total = Object.keys(valores).length;
        return total >= 1 && total <= 50;
      }),
  })
  .transform(({ valores }) => ({
    valores: Object.fromEntries(
      Object.entries(valores).map(([clave, valor]) => [
        clave,
        valor === null ? null : String(valor),
      ]),
    ),
  }));
