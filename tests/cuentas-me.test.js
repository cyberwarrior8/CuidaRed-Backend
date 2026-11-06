/* Pruebas API CR-164: GET /me con cuentas, roles y vigencia, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';
import {
  contexto,
  contextoVencido,
  conSesion,
  crearApp,
  rpcPorNombre,
  perfil,
  usuarioId,
} from './cuentas-support.js';

const pedirMe = (app) => conSesion(request(app).get('/api/v1/me'));

describe('CR-164: GET /me con cuentas', () => {
  it('conserva identity y profile de la fase 1 y agrega cuentas sin cuenta activa en el servidor', async () => {
    const rpc = rpcPorNombre({ api_mis_cuentas: () => ({ activas: [], pendientes: [] }) });
    const res = await pedirMe(crearApp({ rpc }).app).expect(200);
    expect(res.body.data.identity).toEqual({ id: usuarioId, email: perfil.correo });
    expect(res.body.data.profile).toMatchObject({
      id: usuarioId,
      cedula: '00112345678',
      estado: 'activo',
    });
    expect(res.body.data.cuentas).toEqual([]);
    expect(res.body.data.cuenta_activa_id).toBeNull();
    expect(res.headers['cache-control']).toBe('no-store');
    expect(rpc).toHaveBeenCalledWith('api_mis_cuentas');
  });

  it('cada cuenta activa lleva su propio rol, permisos, vigencia, funcionalidades y límites', async () => {
    const familia = contexto('coordinador', 'familia');
    const organizacion = contexto('cuidador', 'organizacion', {
      cuenta_id: 9,
      nombre: 'Fundación Esperanza',
      es_titular: false,
      suscripcion_estado: 'activa',
      plan_id: 3,
      funcionalidades: ['registro_visitas', 'tablon_notificaciones'],
      limites: { envejecientes: 15, usuarios: 20, familiares: null },
    });
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({ activas: [familia, organizacion], pendientes: [] }),
    });
    const { body } = await pedirMe(crearApp({ rpc }).app).expect(200);
    expect(body.data.cuentas).toHaveLength(2);
    const [primera, segunda] = body.data.cuentas;
    expect(primera).toEqual({
      cuenta_id: '7',
      nombre: 'Familia Pérez',
      tipo: 'familia',
      rol: 'coordinador',
      estado_membresia: 'activa',
      permisos: permisosDe('coordinador', 'familia'),
      estado_suscripcion: 'prueba',
      funcionalidades: ['registro_visitas', 'necesidades_diarias'],
      es_titular: true,
      acceso_operativo: true,
      limites: { envejecientes: 2, usuarios: 4, familiares: 2 },
    });
    expect(segunda).toMatchObject({
      cuenta_id: '9',
      tipo: 'organizacion',
      rol: 'cuidador',
      estado_suscripcion: 'activa',
      es_titular: false,
      limites: { envejecientes: 15, usuarios: 20, familiares: null },
    });
    // Sin mezclar permisos entre cuentas: lo que gestiona en una no se concede en la otra.
    expect(primera.permisos).toContain('usuarios:gestionar');
    expect(segunda.permisos).not.toContain('usuarios:gestionar');
    expect(segunda.permisos).toEqual(permisosDe('cuidador', 'organizacion'));
  });

  it('una cuenta vencida sigue listada, marcada sin acceso operativo', async () => {
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({
        activas: [contextoVencido('administrador', 'organizacion')],
        pendientes: [],
      }),
    });
    const { body } = await pedirMe(crearApp({ rpc }).app).expect(200);
    expect(body.data.cuentas[0]).toMatchObject({
      estado_suscripcion: 'vencida',
      acceso_operativo: false,
      funcionalidades: [],
    });
  });

  it('las membresías pendientes salen sin permisos ni acceso', async () => {
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({
        activas: [contexto()],
        pendientes: [
          {
            membresia_id: 31,
            cuenta_id: 12,
            nombre: 'Hogar Luz',
            tipo: 'organizacion',
            rol: 'voluntario',
          },
        ],
      }),
    });
    const { body } = await pedirMe(crearApp({ rpc }).app).expect(200);
    expect(body.data.cuentas.map((c) => c.estado_membresia)).toEqual(['activa', 'pendiente']);
    expect(body.data.cuentas[1]).toEqual({
      cuenta_id: '12',
      nombre: 'Hogar Luz',
      tipo: 'organizacion',
      rol: 'voluntario',
      estado_membresia: 'pendiente',
      permisos: [],
      estado_suscripcion: null,
      funcionalidades: [],
      es_titular: false,
      acceso_operativo: false,
      limites: null,
      membresia_id: '31',
    });
  });

  it('no publica campos internos de la RPC ni identificadores de otras personas', async () => {
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({
        activas: [{ ...contexto(), usuario_titular_id: 'otra-persona', plan_precio: 650 }],
        pendientes: [],
      }),
    });
    const { body } = await pedirMe(crearApp({ rpc }).app).expect(200);
    expect(JSON.stringify(body)).not.toMatch(/otra-persona|plan_precio|membresia_id/);
  });

  it('un fallo de la base no se disfraza de «sin cuentas»', async () => {
    const rpc = vi.fn().mockRejectedValue(mapRpcError({ code: 'PGRST202' }));
    await pedirMe(crearApp({ rpc }).app).expect(503);
  });

  it.each([
    ['respuesta vacía', null],
    ['sin pendientes', { activas: [] }],
    ['rol desconocido', { activas: [contexto('admin', 'organizacion')], pendientes: [] }],
    ['tipo desconocido', { activas: [contexto('coordinador', 'club')], pendientes: [] }],
    [
      'permisos que no son lista',
      { activas: [contexto('coordinador', 'familia', { permisos: 'todo' })], pendientes: [] },
    ],
  ])('un contrato roto de la base es indisponibilidad: %s', async (_caso, roto) => {
    const rpc = rpcPorNombre({ api_mis_cuentas: () => roto });
    await pedirMe(crearApp({ rpc }).app).expect(503);
  });

  it('sin sesión vigente no consulta las cuentas', async () => {
    const rpc = rpcPorNombre({ api_mis_cuentas: () => ({ activas: [], pendientes: [] }) });
    const { app, repository } = crearApp({ rpc });
    repository.session.mockResolvedValue({ vigente: false });
    await pedirMe(app).expect(401);
    expect(rpc).not.toHaveBeenCalled();
  });
});
