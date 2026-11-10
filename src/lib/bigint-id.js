/* Identificadores positivos bigint de PostgreSQL, sin pérdida de precisión. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';

const maximum = '9223372036854775807';

export const isBigintId = (value) =>
  typeof value === 'string' &&
  /^[1-9][0-9]{0,18}$/.test(value) &&
  (value.length < maximum.length || value <= maximum);

export const bigintId = z.string().refine(isBigintId);

// Compatibilidad con respuestas antiguas que todavía usan números seguros.
export const jsonBigintId = z.union([bigintId, z.int().positive().transform(String)]);
