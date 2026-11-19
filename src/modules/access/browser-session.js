/* Sesión del navegador en cookie protegida · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { AppError, unavailable } from '../../lib/errors.js';
import { bearerToken, invalidSession, requireSession, resolveSession } from './require-session.js';

export const browserSessionPath = '/session/browser';
const name = '__Secure-cuidared-browser';
const options = {
  httpOnly: true,
  secure: true,
  sameSite: 'strict',
  path: `/api/v1${browserSessionPath}`,
};
const maxSession = 12 * 60 * 60 * 1000;
const startBody = z.strictObject({
  refresh_token: z
    .string()
    .min(1)
    .max(512)
    .regex(/^[\w-]+$/),
});
const stored = startBody.extend({ sid: z.uuid(), until: z.int() });

function tokenClaims(token) {
  try {
    const { session_id: sid, exp } = JSON.parse(Buffer.from(token.split('.')[1], 'base64url'));
    if (z.uuid().safeParse(sid).success && Number.isSafeInteger(exp)) return { sid, exp };
  } catch {
    // Los JWT se autentican en Supabase. Aquí solo se extraen las referencias verificadas.
  }
  throw invalidSession();
}

function encodeCookie(key, value) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(name));
  const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64url');
}

function decodeCookie(key, raw) {
  try {
    if (!/^[\w-]{38,1600}$/.test(raw)) throw invalidSession();
    const value = Buffer.from(raw, 'base64url');
    const decipher = createDecipheriv('aes-256-gcm', key, value.subarray(0, 12));
    decipher.setAAD(Buffer.from(name));
    decipher.setAuthTag(value.subarray(12, 28));
    return stored.parse(
      JSON.parse(Buffer.concat([decipher.update(value.subarray(28)), decipher.final()])),
    );
  } catch {
    throw invalidSession();
  }
}

function rawCookie(req) {
  const prefix = `${name}=`;
  const cookies = (req.headers.cookie ?? '').split(';').map((entry) => entry.trim());
  const matches = cookies.filter((entry) => entry.startsWith(prefix));
  if (matches.length > 1) throw invalidSession();
  return matches[0]?.slice(prefix.length);
}

function reply(res, key, value, token, userId, exp) {
  res.cookie(name, encodeCookie(key, value), { ...options, expires: new Date(value.until) });
  res.json({ data: { access_token: token, expires_at: exp, user: { id: userId } } });
}

export function createBrowserSessionRouter({ env, gateway, now }) {
  const router = Router();
  const key = env.BROWSER_SESSION_KEY && Buffer.from(env.BROWSER_SESSION_KEY, 'base64url');
  router.use((req, _res, next) => {
    // Las operaciones con credenciales del navegador requieren origen exacto, incluso sin preflight.
    if (!req.headers.origin || !env.origins.includes(req.headers.origin)) {
      throw new AppError(403, 'ORIGIN_DENIED', 'Origen no permitido.');
    }
    next();
  });
  router.post('/start', requireSession(gateway), (req, res) => {
    if (!key) throw unavailable();
    const input = startBody.safeParse(req.body);
    if (!input.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos de acceso.');
    const token = bearerToken(req);
    const { sid, exp } = tokenClaims(token);
    const value = { ...input.data, sid, until: now().getTime() + maxSession };
    reply(res, key, value, token, res.locals.access.identity.id, exp);
  });
  router.post('/restore', async (req, res) => {
    try {
      const raw = rawCookie(req);
      if (raw === undefined) return res.status(204).end();
      if (!key) throw unavailable();
      const value = decodeCookie(key, raw);
      if (now().getTime() >= value.until) throw invalidSession();
      const refreshed = await gateway.refreshBrowserSession(value.refresh_token);
      const { sid, exp } = tokenClaims(refreshed.access_token);
      if (sid !== value.sid) throw invalidSession();
      const { identity } = await resolveSession(gateway, refreshed.access_token, (actor) => {
        res.locals.actorId = actor.id;
      });
      reply(
        res,
        key,
        { ...value, refresh_token: refreshed.refresh_token },
        refreshed.access_token,
        identity.id,
        exp,
      );
    } catch (error) {
      if (error instanceof AppError && [401, 403, 409].includes(error.status)) {
        res.clearCookie(name, options);
      }
      throw error;
    }
  });
  router.post('/clear', (_req, res) => {
    res.clearCookie(name, options);
    res.status(204).end();
  });
  return router;
}
