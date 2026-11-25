/* Verifica y registra el catálogo de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import 'dotenv/config';
import { z } from 'zod';
import { readEnv } from '../src/config/env.js';
import { createSystemClient } from '../src/lib/supabase-admin.js';
import { createStripeGateway } from '../src/modules/suscripciones/stripe-gateway.js';
import { precioCompatible } from '../src/modules/suscripciones/suscripciones-service.js';

const productos = ['basico_familiar', 'cuidado_integral'];
const periodos = ['mensual', 'anual'];
const priceId = z.string().regex(/^price_[A-Za-z0-9]+$/);
const configuracion = z.strictObject(
  Object.fromEntries(
    productos.flatMap((producto) => periodos.map((periodo) => [`${producto}_${periodo}`, priceId])),
  ),
);

async function main() {
  const args = process.argv.slice(2);
  const aplicar = args[0] === '--aplicar';
  if (args.length > 1 || (args.length === 1 && !aplicar)) {
    throw new Error('Uso: node scripts/stripe-catalogo-sandbox.js [--aplicar]');
  }
  const env = readEnv({ ...process.env, STRIPE_SANDBOX_ENABLED: 'true' });
  const stripe = createStripeGateway(env);
  const ids = configuracion.parse(JSON.parse(process.env.STRIPE_SANDBOX_CATALOG_JSON ?? '{}'));
  if (new Set(Object.values(ids)).size !== Object.keys(ids).length)
    throw new Error('Cada oferta debe tener un Price propio.');

  const ofertas = await Promise.all(
    Object.entries(ids).map(async ([codigo, id]) => {
      const price = await stripe.retrievePrice(id);
      const periodicidad = codigo.endsWith('_mensual') ? 'mensual' : 'anual';
      const moneda = price.currency?.toUpperCase();
      const importe = price.unit_amount;
      if (
        moneda !== 'USD' ||
        !Number.isSafeInteger(importe) ||
        importe < 50 ||
        importe > 99999999 ||
        !precioCompatible(price, { importe_centavos: importe, moneda, periodicidad })
      ) {
        throw new Error('Price incompatible con el catálogo.');
      }
      return {
        codigo,
        price_id: id,
        periodicidad,
        importe_centavos: importe,
        moneda,
        divisor_moneda: 100,
      };
    }),
  );

  if (aplicar) {
    const client = createSystemClient(env);
    const { error } = await client
      .rpc('api_stripe_catalogo_importar', { p_ofertas: ofertas })
      .retry(false);
    if (error) throw new Error('La base no aceptó el catálogo.');
  }
  for (const { codigo, importe_centavos, moneda, divisor_moneda } of ofertas) {
    const amount = new Intl.NumberFormat('es-DO', { style: 'currency', currency: moneda });
    console.log(`${codigo} ${amount.format(importe_centavos / divisor_moneda)}`);
  }
  console.log(aplicar ? 'Catálogo de prueba registrado.' : 'Catálogo de prueba verificado.');
}

main().catch(() => {
  console.error(
    'No se pudo verificar el catálogo. Revisa el entorno y los cuatro Prices de Sandbox.',
  );
  process.exitCode = 1;
});
