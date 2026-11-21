/* Contrato HTTP y autorización de necesidades sin base real · ID05/RF-03. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { conSesion, crearApp, cuentaCon } from './cuentas-support.js';

const ruta = '/api/v1/cuentas/7/necesidades';
const adulto = 'a071ce25-7f40-4c45-b5ba-dbc6a0011234';
const alta = `/api/v1/cuentas/7/envejecientes/${adulto}/necesidades`;
const ocurrencia = 'b071ce25-7f40-4c45-b5ba-dbc6a0011234';
const evento = 'c071ce25-7f40-4c45-b5ba-dbc6a0011234';
const fecha = '2026-11-14T12:30:00+00:00';
const necesidad = {
  envejeciente_necesidad_id: ocurrencia,
  envejeciente_id: adulto,
  envejeciente_nombre: 'Persona de prueba',
  envejeciente_estado: 'activo',
  necesidad_id: 3,
  necesidad_nombre: 'Ítem sintético',
  tipo_necesidad_id: 1,
  tipo_necesidad_nombre: 'Categoría sintética',
  prioridad_id: 1,
  prioridad: 'Alta',
  estado: 'pendiente',
  descripcion: 'Necesidad de prueba',
  cantidad: null,
  unidad_medida: null,
  fecha_necesidad: fecha,
  fecha_actualizacion: fecha,
  usuario_responsable_id: null,
  responsable: null,
  indicacion_medica_id: null,
  fecha_resolucion: null,
  motivo_resolucion: null,
  registrado_por: null,
  resuelto_por: null,
  es_recurrente: false,
};

describe('consultas de necesidades', () => {
  it('envía filtros permitidos, devuelve paginación y descarta columnas privadas', async () => {
    const rpc = cuentaCon('cuidador', 'familia', {
      api_necesidades_listar: () => ({
        items: [{ ...necesidad, dato_privado: 'interno' }],
        total: 1,
      }),
    });
    const { app } = crearApp({ rpc });
    const response = await conSesion(
      request(app).get(ruta).query({
        'filter[activas]': 'true',
        'filter[envejeciente_id]': adulto,
        'filter[tipo_necesidad_id]': 1,
        sort: 'prioridad',
      }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_necesidades_listar', {
      p_cuenta_id: '7',
      p_filtros: { activas: true, envejeciente_id: adulto, tipo_necesidad_id: 1 },
      p_orden: ['prioridad', 'envejeciente_necesidad_id'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
    expect(response.body).toEqual({
      data: [necesidad],
      meta: { page: 1, limit: 20, total: 1, totalPages: 1 },
    });
  });

  it('devuelve un historial paginado al familiar', async () => {
    const historial = {
      necesidad_evento_id: evento,
      fecha,
      actor: 'Persona de prueba',
      estado_anterior: null,
      estado: 'pendiente',
      prioridad_id: 1,
      prioridad: 'Alta',
      prioridad_anterior: null,
      responsable_anterior: null,
      responsable: null,
      motivo: null,
    };
    const rpc = cuentaCon('familiar', 'familia', {
      api_necesidad_historial: () => ({ items: [historial], total: 1 }),
    });
    const { app } = crearApp({ rpc });
    const response = await conSesion(request(app).get(`${ruta}/${ocurrencia}/historial`)).expect(
      200,
    );
    expect(rpc).toHaveBeenCalledWith('api_necesidad_historial', {
      p_cuenta_id: '7',
      p_necesidad_id: ocurrencia,
      p_orden: ['-fecha', 'necesidad_evento_id'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
    expect(response.body.data).toEqual([historial]);
  });

  it('conserva el estado del expediente aunque la ocurrencia siga pendiente', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_necesidad_obtener: () => ({ ...necesidad, envejeciente_estado: 'inactivo' }),
    });
    const { app } = crearApp({ rpc });
    const response = await conSesion(request(app).get(`${ruta}/${ocurrencia}`)).expect(200);
    expect(response.body.data).toMatchObject({
      envejeciente_estado: 'inactivo',
      estado: 'pendiente',
    });
  });

  it('el voluntario y una cuenta vencida quedan fuera de la colección', async () => {
    for (const [rol, extra] of [
      ['voluntario', {}],
      ['administrador', { acceso_operativo: false }],
    ]) {
      const rpc = cuentaCon(rol, 'organizacion', {}, extra);
      const { app } = crearApp({ rpc });
      await conSesion(request(app).get(ruta)).expect(403);
      expect(rpc.mock.calls.map(([nombre]) => nombre)).toEqual(['api_contexto_cuenta']);
    }
  });

  it('valida filtros y UUID y trata un expediente sin alcance como inexistente', async () => {
    const rpc = cuentaCon('familiar', 'familia', {
      api_necesidad_obtener: () => {
        throw mapRpcError({ code: 'P0002' });
      },
    });
    const { app } = crearApp({ rpc });
    await conSesion(request(app).get(ruta).query({ 'filter[estado]': 'satisfecha' })).expect(422);
    await conSesion(request(app).get(`${ruta}/3`)).expect(404);
    await conSesion(request(app).get(`${ruta}/${ocurrencia}`)).expect(404);
    expect(rpc.mock.calls.filter(([nombre]) => nombre.startsWith('api_necesidad'))).toEqual([
      ['api_necesidad_obtener', { p_cuenta_id: '7', p_necesidad_id: ocurrencia }],
    ]);
  });
});

describe('registro y priorización de necesidades', () => {
  const cuerpo = { necesidad_id: 3, prioridad_id: 1, descripcion: 'Necesidad de prueba' };

  it('registra una ocurrencia con sus datos y audita sin copiar sus datos', async () => {
    const rpc = cuentaCon('coordinador', 'familia', { api_necesidad_crear: () => necesidad });
    const { app, audit } = crearApp({ rpc });
    const datos = { ...cuerpo, cantidad: 2.5, unidad_medida: 'cajas' };
    const response = await conSesion(request(app).post(alta).send(datos)).expect(201);
    expect(response.body.data).toEqual(necesidad);
    expect(rpc).toHaveBeenCalledWith('api_necesidad_crear', {
      p_cuenta_id: '7',
      p_envejeciente_id: adulto,
      p_datos: datos,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'necesidad.creada', result: 'success' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain(cuerpo.descripcion);
  });

  it.each([
    { cantidad: 1 },
    { cantidad: 0, unidad_medida: 'cajas' },
    { cantidad: 10001, unidad_medida: 'cajas' },
    { descripcion: 'corta'.slice(0, 4) },
    { prioridad_id: null },
    { estado: 'resuelta' },
  ])('rechaza el registro inválido %j antes de escribir', async (campo) => {
    const rpc = cuentaCon('cuidador', 'organizacion');
    const { app } = crearApp({ rpc });
    await conSesion(
      request(app)
        .post(alta)
        .send({ ...cuerpo, ...campo }),
    ).expect(422);
    expect(rpc.mock.calls.map(([nombre]) => nombre)).toEqual(['api_contexto_cuenta']);
  });

  it('separa cambios de prioridad y de estado y exige motivo al cerrar', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_necesidad_actualizar: () => ({ ...necesidad, prioridad_id: 2, prioridad: 'Media' }),
      api_necesidad_estado: () => ({
        ...necesidad,
        estado: 'resuelta',
        motivo_resolucion: 'Entrega registrada',
      }),
    });
    const { app } = crearApp({ rpc });
    await conSesion(request(app).patch(`${ruta}/${ocurrencia}`).send({ prioridad_id: 2 })).expect(
      200,
    );
    await conSesion(
      request(app).post(`${ruta}/${ocurrencia}/estado`).send({ estado: 'resuelta' }),
    ).expect(422);
    await conSesion(
      request(app)
        .post(`${ruta}/${ocurrencia}/estado`)
        .send({ estado: 'resuelta', motivo: 'Entrega registrada' }),
    ).expect(200);
    expect(rpc.mock.calls.filter(([nombre]) => nombre.startsWith('api_necesidad'))).toEqual([
      [
        'api_necesidad_actualizar',
        { p_cuenta_id: '7', p_necesidad_id: ocurrencia, p_datos: { prioridad_id: 2 } },
      ],
      [
        'api_necesidad_estado',
        {
          p_cuenta_id: '7',
          p_necesidad_id: ocurrencia,
          p_datos: { estado: 'resuelta', motivo: 'Entrega registrada' },
        },
      ],
    ]);
  });

  it.each(['familiar', 'voluntario'])(
    'el rol %s no escribe ni consulta candidatos',
    async (rol) => {
      const rpc = cuentaCon(rol, 'organizacion');
      const { app } = crearApp({ rpc });
      await conSesion(request(app).post(alta).send(cuerpo)).expect(403);
      await conSesion(request(app).get(`${alta}/candidatos`)).expect(403);
      expect(rpc.mock.calls.map(([nombre]) => nombre)).toEqual([
        'api_contexto_cuenta',
        'api_contexto_cuenta',
      ]);
    },
  );
});
