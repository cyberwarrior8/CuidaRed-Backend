/* Pruebas API ID02/RF-11/RF-20: alta de cuenta por autorregistro del titular, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { contexto, conSesion, crearApp, rpcPorNombre, usuarioId } from './cuentas-support.js';

const cuerpo = {
  tipo: 'familia',
  nombre: 'Familia Pérez',
  categoria_cuenta_id: 1,
  municipio_cod: '0101',
};
const registrar = (app, datos = cuerpo) =>
  conSesion(request(app).post('/api/v1/cuentas')).send(datos);

describe('ID02: POST /cuentas (autorregistro del titular)', () => {
  it('crea la cuenta y responde 201 con el contexto del titular', async () => {
    const rpc = rpcPorNombre({
      api_registrar_cuenta: () => contexto('coordinador', 'familia'),
    });
    const { app, audit } = crearApp({ rpc });
    const res = await registrar(app).expect(201);
    expect(rpc).toHaveBeenCalledWith('api_registrar_cuenta', { p_datos: cuerpo });
    expect(res.headers.location).toBe('/api/v1/cuentas/7');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.data).toMatchObject({
      cuenta_id: '7',
      nombre: 'Familia Pérez',
      tipo: 'familia',
      rol: 'coordinador',
      estado_membresia: 'activa',
      estado_suscripcion: 'prueba',
      es_titular: true,
      acceso_operativo: true,
      limites: { envejecientes: 2, usuarios: 4, familiares: 2 },
    });
    expect(res.body.data.permisos).toContain('usuarios:gestionar');
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'cuenta.created', actorId: usuarioId, result: 'success' }),
    );
  });

  it('en Organización el titular es administrador', async () => {
    const rpc = rpcPorNombre({
      api_registrar_cuenta: () =>
        contexto('administrador', 'organizacion', {
          limites: { envejecientes: 5, usuarios: 5, familiares: null },
        }),
    });
    const res = await registrar(crearApp({ rpc }).app, { ...cuerpo, tipo: 'organizacion' }).expect(
      201,
    );
    expect(res.body.data.rol).toBe('administrador');
    expect(res.body.data.limites.familiares).toBeNull();
  });

  it('exige sesión pero no membresía: no resuelve ninguna cuenta', async () => {
    const rpc = rpcPorNombre({ api_registrar_cuenta: () => contexto() });
    const { app, gateway } = crearApp({ rpc });
    await request(app).post('/api/v1/cuentas').send(cuerpo).expect(401);
    expect(gateway.authenticate).not.toHaveBeenCalled();
    await registrar(app).expect(201);
    expect(rpc).not.toHaveBeenCalledWith('api_contexto_cuenta', expect.anything());
  });

  it('normaliza teléfono, correo y vacíos antes de llamar a la base', async () => {
    const rpc = rpcPorNombre({ api_registrar_cuenta: () => contexto() });
    await registrar(crearApp({ rpc }).app, {
      ...cuerpo,
      nombre: '  Familia Pérez  ',
      telefono: '+1 809-555-1234',
      correo: '  Familia@Correo.DO ',
      direccion: '',
    }).expect(201);
    expect(rpc).toHaveBeenCalledWith('api_registrar_cuenta', {
      p_datos: {
        ...cuerpo,
        telefono: '+18095551234',
        correo: 'familia@correo.do',
        direccion: null,
      },
    });
  });

  it.each([
    ['tipo desconocido', { tipo: 'club' }],
    ['sin nombre', { nombre: undefined }],
    ['nombre de un carácter', { nombre: 'a' }],
    ['nombre de 121 caracteres', { nombre: 'x'.repeat(121) }],
    ['categoría como texto', { categoria_cuenta_id: '1' }],
    ['categoría 0', { categoria_cuenta_id: 0 }],
    ['categoría decimal', { categoria_cuenta_id: 1.5 }],
    ['municipio sin formato', { municipio_cod: 'ab' }],
    ['sin municipio', { municipio_cod: undefined }],
    ['teléfono corto', { telefono: '12345' }],
    ['teléfono con letras', { telefono: '809-555-ABCD' }],
    ['correo sin arroba', { correo: 'sin-arroba' }],
    ['dirección de 151 caracteres', { direccion: 'x'.repeat(151) }],
  ])('rechaza con 422 sin tocar la base: %s', async (_caso, cambio) => {
    const rpc = rpcPorNombre({ api_registrar_cuenta: () => contexto() });
    const res = await registrar(crearApp({ rpc }).app, { ...cuerpo, ...cambio }).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(rpc).not.toHaveBeenCalled();
  });

  it.each([
    'usuario_titular_id',
    'rol',
    'estado',
    'plan_id',
    'suscripcion_estado',
    'prueba_gratuita',
    'fecha_fin_prueba',
    'cuenta_id',
    'es_titular',
  ])('impide asignación masiva de %s', async (campo) => {
    const rpc = rpcPorNombre({ api_registrar_cuenta: () => contexto() });
    await registrar(crearApp({ rpc }).app, { ...cuerpo, [campo]: 'intruso' }).expect(422);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('rechaza un cuerpo que no es un objeto', async () => {
    const { app } = crearApp({ rpc: rpcPorNombre({}) });
    await conSesion(request(app).post('/api/v1/cuentas')).send([]).expect(422);
    await conSesion(request(app).post('/api/v1/cuentas')).expect(422);
  });

  it('una segunda prueba vigente del titular es 409 TRIAL_IN_PROGRESS', async () => {
    const rpc = vi
      .fn()
      .mockRejectedValue(mapRpcError({ code: 'P0001', message: 'CR_PRUEBA_EN_CURSO' }));
    const { app, audit } = crearApp({ rpc });
    const res = await registrar(app).expect(409);
    expect(res.body.error.code).toBe('TRIAL_IN_PROGRESS');
    expect(JSON.stringify(res.body)).not.toContain('CR_PRUEBA_EN_CURSO');
    expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ action: 'cuenta.created' }));
  });

  it('una categoría de otro tipo de cuenta es 422 INVALID_CATEGORY', async () => {
    const rpc = vi
      .fn()
      .mockRejectedValue(mapRpcError({ code: 'P0001', message: 'CR_CATEGORIA_INVALIDA' }));
    const res = await registrar(crearApp({ rpc }).app).expect(422);
    expect(res.body.error.code).toBe('INVALID_CATEGORY');
  });

  it('un municipio inexistente (22023 de la base) es 422 genérico', async () => {
    const rpc = vi.fn().mockRejectedValue(mapRpcError({ code: '22023' }));
    const res = await registrar(crearApp({ rpc }).app).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
  });

  it('un usuario inactivo (42501 de la base) es 403', async () => {
    const rpc = vi.fn().mockRejectedValue(mapRpcError({ code: '42501' }));
    await registrar(crearApp({ rpc }).app).expect(403);
  });

  it('un contrato roto de la base es indisponibilidad, no una cuenta a medias', async () => {
    for (const roto of [null, { cuenta_id: 7 }, contexto('coordinador', 'club')]) {
      const rpc = rpcPorNombre({ api_registrar_cuenta: () => roto });
      await registrar(crearApp({ rpc }).app).expect(503);
    }
  });

  it('no publica campos que la RPC añada fuera del contrato', async () => {
    const rpc = rpcPorNombre({
      api_registrar_cuenta: () => ({
        ...contexto(),
        usuario_titular_id: usuarioId,
        plan_precio: 0,
      }),
    });
    const res = await registrar(crearApp({ rpc }).app).expect(201);
    expect(res.body.data).not.toHaveProperty('usuario_titular_id');
    expect(res.body.data).not.toHaveProperty('plan_precio');
    expect(res.body.data).not.toHaveProperty('membresia_id');
  });
});
