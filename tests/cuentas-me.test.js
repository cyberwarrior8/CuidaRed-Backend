/* Perfil, cuentas paginadas e invitaciones independientes · CR-164. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { unavailable } from '../src/lib/errors.js';
import {
  contexto,
  contextoVencido,
  conSesion,
  crearApp,
  rpcPorNombre,
  perfil,
  usuarioId,
} from './cuentas-support.js';

const pedir = (app, ruta) => conSesion(request(app).get('/api/v1' + ruta));

describe('CR-164: el perfil de fase 1 funciona con las RPC de cuentas ausentes', () => {
  it('conserva identidad y perfil aunque el catálogo de cuentas no responda', async () => {
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => {
        throw unavailable();
      },
    });
    const { app } = crearApp({ rpc });
    const res = await pedir(app, '/me').expect(200);
    expect(res.body.data).toEqual({
      identity: { id: usuarioId, email: perfil.correo },
      profile: {
        id: usuarioId,
        cedula: perfil.cedula,
        nombres: perfil.nombres,
        apellidos: perfil.apellidos,
        correo: perfil.correo,
        telefono: null,
        estado: 'activo',
      },
    });
    expect(rpc).not.toHaveBeenCalled();
    await pedir(app, '/cuentas').expect(503);
    await pedir(app, '/me').expect(200);
  });
});

describe('GET /cuentas y /me/membresias', () => {
  it('mantiene cuentas activas con sus permisos y conserva ids bigint y metadatos', async () => {
    const cuentaId = '9223372036854775807';
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({
        items: [
          contexto('coordinador', 'familia', { cuenta_id: cuentaId }),
          contextoVencido('cuidador', 'organizacion'),
        ],
        total: 22,
      }),
    });
    const res = await pedir(
      crearApp({ rpc }).app,
      '/cuentas?page=2&sort=-nombre&filter[tipo_cuenta]=familia',
    ).expect(200);
    expect(res.body.meta).toEqual({ page: 2, limit: 20, total: 22, totalPages: 2 });
    expect(res.body.data[0]).toMatchObject({
      cuenta_id: cuentaId,
      rol: 'coordinador',
      estado_membresia: 'activa',
    });
    expect(res.body.data[1]).toMatchObject({ rol: 'cuidador', acceso_operativo: false });
    expect(rpc).toHaveBeenCalledWith('api_mis_cuentas', {
      p_filtros: { tipo_cuenta: 'familia' },
      p_orden: [
        { field: 'nombre', direction: 'desc' },
        { field: 'cuenta_id', direction: 'asc' },
      ],
      p_offset: 20,
      p_limit: 20,
    });
  });

  it('una página vacía conserva el total y la paginación', async () => {
    const rpc = rpcPorNombre({ api_mis_cuentas: () => ({ items: [], total: 2 }) });
    const res = await pedir(crearApp({ rpc }).app, '/cuentas?page=2').expect(200);
    expect(res.body).toEqual({ data: [], meta: { page: 2, limit: 20, total: 2, totalPages: 1 } });
  });

  it.each(['?limit=101', '?filter[estado]=activa', '?sort=-usuario_id', '?page=1&page=2'])(
    'rechaza %s antes de la RPC',
    async (query) => {
      const rpc = rpcPorNombre({});
      await pedir(crearApp({ rpc }).app, '/cuentas' + query).expect(422);
      expect(rpc).not.toHaveBeenCalled();
    },
  );

  it('las invitaciones se listan por separado y sin conceder permisos', async () => {
    const rpc = rpcPorNombre({
      api_mis_invitaciones: () => [
        { cuenta_id: '7', membresia_id: '31', nombre: 'Familia', tipo: 'familia', rol: 'familiar' },
      ],
    });
    const res = await pedir(crearApp({ rpc }).app, '/me/membresias').expect(200);
    expect(res.body.data[0]).toMatchObject({
      membresia_id: '31',
      estado_membresia: 'pendiente',
      permisos: [],
      acceso_operativo: false,
    });
    expect(rpc).toHaveBeenCalledWith('api_mis_invitaciones');
  });

  it('rechaza una respuesta rota o un id redondeado como número', async () => {
    const rpc = rpcPorNombre({
      api_mis_cuentas: () => ({
        items: [contexto('coordinador', 'familia', { cuenta_id: 9007199254740992 })],
        total: 1,
      }),
    });
    await pedir(crearApp({ rpc }).app, '/cuentas').expect(503);
  });

  it('la selección por ruta conserva el bigint y rechaza un contexto de otra cuenta', async () => {
    const id = '9007199254740993';
    const rpc = rpcPorNombre({
      api_contexto_cuenta: ({ p_cuenta_id }) =>
        contexto('coordinador', 'familia', { cuenta_id: p_cuenta_id }),
    });
    await pedir(crearApp({ rpc }).app, '/cuentas/' + id + '/contexto').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_contexto_cuenta', { p_cuenta_id: id });
    const equivocada = rpcPorNombre({ api_contexto_cuenta: () => contexto() });
    await pedir(crearApp({ rpc: equivocada }).app, '/cuentas/' + id + '/contexto').expect(503);
  });
});
