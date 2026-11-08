/* Contexto de cuenta, permisos y vigencia en la API · RF-09/RF-11/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import express from 'express';
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { businessError, registerBusinessErrors } from '../src/lib/business-errors.js';
import { AppError } from '../src/lib/errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { MATRIZ, permisosDe, ROLES_POR_TIPO } from '../src/modules/cuentas/permisos.js';
import {
  requireAccesoOperativo,
  requireCuenta,
  requirePermiso,
} from '../src/modules/cuentas/require-cuenta.js';

const contexto = (extra = {}) => ({
  cuenta_id: 7,
  tipo: 'familia',
  rol: 'coordinador',
  membresia_id: 11,
  permisos: permisosDe('coordinador', 'familia'),
  es_titular: true,
  acceso_operativo: true,
  suscripcion_estado: 'prueba',
  funcionalidades: ['registro_visitas'],
  ...extra,
});

function appCon(rpc, ...finales) {
  const app = express();
  app.use((_req, res, next) => {
    res.locals.access = { repository: { rpc } };
    next();
  });
  const enCuenta = express.Router({ mergeParams: true });
  enCuenta.use(requireCuenta());
  enCuenta.get('/x', ...finales, (_req, res) => res.json({ data: { rol: res.locals.cuenta.rol } }));
  app.use('/cuentas/:cuentaId', enCuenta);
  app.use((err, _req, res, _next) =>
    res.status(err.status ?? 500).json({ error: { code: err.code } }),
  );
  return app;
}

describe('RF-09: matriz de permisos V2', () => {
  it('en Familia no existen Administrador ni Voluntario y el Coordinador gestiona accesos', () => {
    expect(ROLES_POR_TIPO.familia).toEqual(['coordinador', 'cuidador', 'familiar']);
    expect(permisosDe('administrador', 'familia')).toEqual([]);
    expect(permisosDe('voluntario', 'familia')).toEqual([]);
    expect(permisosDe('coordinador', 'familia')).toContain('usuarios:gestionar');
    expect(permisosDe('coordinador', 'organizacion')).not.toContain('usuarios:gestionar');
  });
  it('el Voluntario solo registra visitas; el Familiar consulta indicaciones sin gestionarlas', () => {
    expect(MATRIZ.voluntario).not.toContain('necesidades:registrar');
    expect(MATRIZ.voluntario).not.toContain('indicaciones:ver');
    expect(MATRIZ.familiar).toContain('indicaciones:ver');
    expect(MATRIZ.familiar).not.toContain('indicaciones:gestionar');
    expect(MATRIZ.cuidador).toContain('alertas:cerrar');
    expect(MATRIZ.cuidador).not.toContain('alertas:gestionar');
  });
});

describe('RF-11: cuenta activa por ruta', () => {
  it('resuelve el contexto con el id de la ruta y lo expone a la ruta', async () => {
    const rpc = vi.fn().mockResolvedValue(contexto());
    const res = await request(appCon(rpc)).get('/cuentas/7/x').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_contexto_cuenta', { p_cuenta_id: '7' });
    expect(res.body.data.rol).toBe('coordinador');
  });
  it.each(['0', 'abc', '-1', '1.5', '99999999999999999999'])(
    'rechaza el id %s sin consultar la base',
    async (id) => {
      const rpc = vi.fn();
      await request(appCon(rpc)).get(`/cuentas/${id}/x`).expect(404);
      expect(rpc).not.toHaveBeenCalled();
    },
  );
  it('sin membresía activa responde 404 sin revelar si la cuenta existe', async () => {
    await request(appCon(vi.fn().mockResolvedValue(null)))
      .get('/cuentas/9/x')
      .expect(404);
  });
  it('un contrato roto de la base es indisponibilidad, no un permiso', async () => {
    await request(appCon(vi.fn().mockResolvedValue({ cuenta_id: 7 })))
      .get('/cuentas/7/x')
      .expect(503);
  });
});

describe('RF-09/RF-20: permiso y acceso operativo', () => {
  it('exige la acción', async () => {
    const rpc = vi
      .fn()
      .mockResolvedValue(
        contexto({ rol: 'familiar', permisos: permisosDe('familiar', 'familia') }),
      );
    const res = await request(appCon(rpc, requirePermiso('usuarios:gestionar')))
      .get('/cuentas/7/x')
      .expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
  it('cuenta vencida: bloquea lo operativo y conserva la gestión de suscripción (D07)', async () => {
    const vencida = vi
      .fn()
      .mockResolvedValue(contexto({ acceso_operativo: false, suscripcion_estado: 'vencida' }));
    const bloqueada = await request(appCon(vencida, requirePermiso('adultos:ver')))
      .get('/cuentas/7/x')
      .expect(403);
    expect(bloqueada.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    await request(appCon(vencida, requirePermiso('cuenta:suscripcion')))
      .get('/cuentas/7/x')
      .expect(200);
    await request(appCon(vencida, requireAccesoOperativo())).get('/cuentas/7/x').expect(403);
  });
});

describe('CR-162: errores de negocio de las RPC', () => {
  it('traduce solo códigos CR_* registrados y nunca el texto del proveedor', () => {
    registerBusinessErrors({
      CR_PRUEBA_X: { status: 409, publicCode: 'TEST_X', message: 'Mensaje público.' },
    });
    const e = mapRpcError({ code: 'P0001', message: 'CR_PRUEBA_X' });
    expect(e).toBeInstanceOf(AppError);
    expect([e.status, e.code, e.message]).toEqual([409, 'TEST_X', 'Mensaje público.']);
    expect(mapRpcError({ code: 'P0001', message: 'detalle interno de la base' }).status).toBe(503);
    expect(businessError('CR_NO_REGISTRADO')).toBeUndefined();
    expect(mapRpcError({ code: 'P0001', message: 'CR_CUENTA_SIN_ACCESO' }).code).toBe(
      'SUBSCRIPTION_INACTIVE',
    );
  });
  it('conserva el mapeo de fase 1 y permite un 409 propio por operación', () => {
    expect(mapRpcError({ code: '23505' }).code).toBe('CONFLICT');
    expect(
      mapRpcError({ code: '23505' }, { conflict: { code: 'PROFILE_CONFLICT', message: 'x' } }).code,
    ).toBe('PROFILE_CONFLICT');
    expect(mapRpcError({ code: '28000' }).status).toBe(401);
    expect(mapRpcError({ code: '42501' }).status).toBe(403);
    expect(mapRpcError({ code: 'P0002' }).status).toBe(404);
    expect(mapRpcError({ code: '22023' }).status).toBe(422);
  });
  it('rechaza registrar códigos o estados inválidos', () => {
    expect(() =>
      registerBusinessErrors({ MAL: { status: 409, publicCode: 'X', message: '' } }),
    ).toThrow();
    expect(() =>
      registerBusinessErrors({ CR_OK: { status: 500, publicCode: 'X', message: '' } }),
    ).toThrow();
  });
});
