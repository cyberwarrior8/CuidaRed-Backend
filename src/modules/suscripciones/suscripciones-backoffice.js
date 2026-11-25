/* Tarifas y cotizaciones en el Backoffice · ID08/RF-20/BO-03. © 2026 Equipo CuidaRed – INTEC. */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { businessError } from '../../lib/business-errors.js';
import { AppError, unavailable } from '../../lib/errors.js';
import { requireRole } from '../backoffice/require-backoffice.js';
import { id, motivo, parse } from '../backoffice/backoffice-schemas.js';
import { codigoCotizacion, limitesCotizados, versionOferta } from './suscripciones-schemas.js';
import { precioCompatible } from './suscripciones-service.js';
import './suscripciones-repository.js';

const codigoSchema = z.string().regex(/^[a-z_]{1,63}_(mensual|anual)$/);
const editarTarifa = z.strictObject({ importe_centavos: z.int().min(50).max(99999999), motivo });
const editarCotizacion = editarTarifa.extend({
  limites: limitesCotizados,
  version: versionOferta.nullable().optional(),
});
const preparacionTarifa = z.object({ periodicidad: z.enum(['mensual', 'anual']) });
const preparacionCotizacion = preparacionTarifa.extend({
  version_actual: versionOferta.nullable(),
  sin_cambios: z.boolean(),
});

export function montarPreciosStripe(router, { env, adminGateway, stripe, repository }) {
  const administrador = requireRole(repository, 'super_admin');
  const bloqueos = [];
  if (!stripe) bloqueos.push('sandbox_inactivo');
  if (!env.stripeProducts) bloqueos.push('productos_sin_configurar');
  const disponibles = bloqueos.length === 0;
  const rpc = (accion, res, params) => {
    if (!adminGateway) throw unavailable();
    const { actorId, sessionId, aal } = res.locals.backoffice;
    return adminGateway.backofficeRpc(`stripe_${accion}`, {
      p_actor: actorId,
      p_sesion: sessionId,
      p_aal: aal,
      ...params,
    });
  };
  const consultar = (conCuenta) => async (req, res) => {
    const cuentaId = conCuenta ? parse(id, req.params.cuentaId) : null;
    const data = await rpc('leer', res, { p_cuenta_id: cuentaId });
    res.json({ data: { ...data, disponibles, bloqueos } });
  };
  const publicar = (conCuenta) => async (req, res) => {
    if (!disponibles)
      throw new AppError(
        503,
        'SANDBOX_UNAVAILABLE',
        !stripe
          ? 'Activa Stripe Sandbox en el backend para publicar.'
          : 'Configura los productos de Stripe Sandbox en el backend.',
      );
    const cuentaId = conCuenta ? parse(id, req.params.cuentaId) : null;
    const codigo = parse(conCuenta ? codigoCotizacion : codigoSchema, req.params.codigo);
    const {
      importe_centavos: importe,
      motivo: motivoCambio,
      limites,
      version,
    } = parse(conCuenta ? editarCotizacion : editarTarifa, req.body);
    const scope = {
      p_cuenta_id: cuentaId,
      p_codigo: codigo,
      ...(conCuenta ? { p_limites: limites } : {}),
    };
    const respuesta = await rpc('preparar_tarifa', res, {
      ...scope,
      ...(conCuenta ? { p_importe_centavos: importe } : {}),
    });
    const preparacion = (conCuenta ? preparacionCotizacion : preparacionTarifa).safeParse(
      respuesta,
    );
    if (!preparacion.success) throw unavailable();
    const {
      periodicidad,
      version_actual: versionActual,
      sin_cambios: sinCambios,
    } = preparacion.data;
    if (sinCambios) return res.status(204).end();
    if (version !== undefined && version !== versionActual)
      throw businessError('CR_STRIPE_COTIZACION_ACTUALIZADA');
    const producto = env.stripeProducts[codigo.slice(0, codigo.lastIndexOf('_'))];
    if (!producto) throw unavailable();
    const datosClave = [cuentaId, codigo, importe, producto];
    // Una edición de cupos crea un Price distinto, aunque el importe se conserve.
    if (conCuenta) datosClave.push(versionActual, limites);
    const hash = createHash('sha256').update(JSON.stringify(datosClave)).digest('hex');
    const precio = await stripe.createPrice(
      {
        product: producto,
        currency: 'usd',
        unit_amount: importe,
        recurring: { interval: periodicidad === 'mensual' ? 'month' : 'year' },
      },
      `cuidared:tarifa:${hash}`,
    );
    if (
      !precioCompatible(precio, {
        importe_centavos: importe,
        moneda: 'USD',
        periodicidad,
      })
    )
      throw unavailable();
    if (precio.product !== producto && precio.product?.id !== producto) throw unavailable();
    await rpc('publicar_tarifa', res, {
      ...scope,
      p_importe_centavos: importe,
      p_price_id: precio.id,
      p_motivo: motivoCambio,
      ...(conCuenta ? { p_version_esperada: versionActual } : {}),
    });
    res.status(204).end();
  };

  router.get('/planes-stripe', administrador, consultar(false));
  router.patch('/planes-stripe/:codigo', administrador, publicar(false));
  router.get('/cuentas/:cuentaId/cotizaciones-stripe', administrador, consultar(true));
  router.patch('/cuentas/:cuentaId/cotizaciones-stripe/:codigo', administrador, publicar(true));
}
