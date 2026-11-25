/* Contratos de ofertas y cotizaciones de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';

export const codigoCotizacion = z.enum([
  'gestion_comunitaria_avanzada_mensual',
  'gestion_comunitaria_avanzada_anual',
]);

const cupo = z.int().positive().nullable();
export const limitesPlan = z.object({
  envejecientes: cupo,
  usuarios: cupo,
  cuidadores: cupo.default(null),
  familiares: cupo,
});

const cupoCotizado = z.int().min(1).max(100000).nullable();
export const limitesCotizados = z.strictObject({
  envejecientes: cupoCotizado,
  usuarios: cupoCotizado,
  cuidadores: cupoCotizado,
  familiares: cupoCotizado,
});

export const versionOferta = z.uuid().toLowerCase();
