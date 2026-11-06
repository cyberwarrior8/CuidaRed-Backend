/* Pruebas API ID02/RF-11/RF-19/RF-20: cuenta activa, configuración y suscripción, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { ROLES_POR_TIPO } from '../src/modules/cuentas/permisos.js';
import {
  conSesion,
  contexto,
  contextoVencido,
  crearApp,
  cuentaCon,
  rpcPorNombre,
  usuarioId,
} from './cuentas-support.js';

const detalleCrudo = (rol = 'coordinador', tipo = 'familia', extra = {}) => ({
  cuenta: {
    cuenta_id: 7,
    nombre: 'Familia Pérez',
    tipo,
    categoria: { categoria_cuenta_id: 1, nombre: 'Monitoreo a distancia' },
    municipio: {
      municipio_cod: '0101',
      nombre: 'Santo Domingo de Guzmán',
      provincia_cod: '01',
      provincia: 'Distrito Nacional',
    },
    direccion: 'Calle 1',
    telefono: '+18095551234',
    correo: null,
    fecha_creacion: '2026-11-06T16:00:09.151093-04:00',
  },
  contexto: contexto(rol, tipo, extra),
  uso: { envejecientes: 1, usuarios: 2, familiares: 0, voluntarios: 0 },
});

const parametros = (propio = false) => [
  {
    nombre: 'dias_sin_visita_alerta',
    valor: propio ? '30' : '15',
    tipo_dato: 'entero',
    es_propio: propio,
    valor_general: '15',
    descripcion: 'Días sin visita para la alerta.',
  },
  {
    nombre: 'notificar_casos_prioritarios',
    valor: 'true',
    tipo_dato: 'booleano',
    es_propio: false,
    valor_general: 'true',
    descripcion: null,
  },
];

const suscripcionCruda = (extra = {}) => ({
  estado: 'prueba',
  acceso_operativo: true,
  prueba: {
    gratuita: true,
    vigente: true,
    fecha_inicio: '2026-11-06',
    fecha_fin: '2026-11-13',
    dias_restantes: 7,
  },
  plan: null,
  fecha_fin_vigencia: null,
  limites: { envejecientes: 2, usuarios: 4, familiares: 2 },
  uso: { envejecientes: 0, usuarios: 1, familiares: 0, voluntarios: 0 },
  funcionalidades: ['registro_visitas'],
  planes: [
    {
      plan_id: 1,
      nombre: 'Básico Familiar',
      categoria: 'Básico',
      precio: 650,
      periodicidad: 'mensual',
      duracion_dias: 30,
      resumen: 'Hasta 2 adultos mayores.',
      limites: { envejecientes: 2, usuarios: null, familiares: 3 },
      funcionalidades: ['registro_visitas', 'necesidades_diarias'],
      es_actual: false,
    },
  ],
  ...extra,
});

const get = (app, ruta) => conSesion(request(app).get(`/api/v1/cuentas/7${ruta}`));
const patch = (app, ruta, datos) =>
  conSesion(request(app).patch(`/api/v1/cuentas/7${ruta}`)).send(datos);

// Combinaciones (tipo, rol) que existen en V2.
const combinaciones = Object.entries(ROLES_POR_TIPO).flatMap(([tipo, roles]) =>
  roles.map((rol) => [tipo, rol]),
);
// Quién tiene organizacion:configurar y cuenta:suscripcion (matriz de permisos).
const gestionan = [
  ['organizacion', 'administrador'],
  ['familia', 'coordinador'],
];
const noGestionan = combinaciones.filter(
  ([tipo, rol]) => !gestionan.some(([t, r]) => t === tipo && r === rol),
);

describe('aislamiento: una cuenta ajena no existe para el usuario', () => {
  it.each([
    ['GET', '', undefined],
    ['PATCH', '', { nombre: 'Intrusa' }],
    ['GET', '/configuracion', undefined],
    ['PATCH', '/configuracion', { valores: { dias_sin_visita_alerta: '20' } }],
    ['GET', '/suscripcion', undefined],
  ])('%s /cuentas/9%s es 404 y no toca los datos', async (metodo, ruta, cuerpo) => {
    const rpc = rpcPorNombre({ api_contexto_cuenta: () => null });
    const { app } = crearApp({ rpc });
    const peticion = conSesion(request(app)[metodo.toLowerCase()](`/api/v1/cuentas/9${ruta}`));
    await (cuerpo ? peticion.send(cuerpo) : peticion).expect(404);
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith('api_contexto_cuenta', { p_cuenta_id: 9 });
  });

  it('exige sesión en todas las rutas de la cuenta', async () => {
    const { app } = crearApp({ rpc: rpcPorNombre({}) });
    await request(app).get('/api/v1/cuentas/7').expect(401);
    await request(app).patch('/api/v1/cuentas/7').send({ nombre: 'X' }).expect(401);
    await request(app).get('/api/v1/cuentas/7/configuracion').expect(401);
    await request(app).get('/api/v1/cuentas/7/suscripcion').expect(401);
  });
});

describe('RF-11: GET /cuentas/:cuentaId', () => {
  it.each(combinaciones)('cualquier miembro lo lee (%s, %s)', async (tipo, rol) => {
    const rpc = cuentaCon(rol, tipo, { api_obtener_cuenta: () => detalleCrudo(rol, tipo) }, {});
    const res = await get(crearApp({ rpc }).app, '').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_obtener_cuenta', { p_cuenta_id: 7 });
    expect(res.body.data.cuenta).toEqual({
      cuenta_id: '7',
      nombre: 'Familia Pérez',
      tipo,
      categoria: { categoria_cuenta_id: 1, nombre: 'Monitoreo a distancia' },
      municipio: {
        municipio_cod: '0101',
        nombre: 'Santo Domingo de Guzmán',
        provincia_cod: '01',
        provincia: 'Distrito Nacional',
      },
      direccion: 'Calle 1',
      telefono: '+18095551234',
      correo: null,
      fecha_creacion: '2026-11-06T20:00:09.151Z',
    });
    expect(res.body.data.contexto).toMatchObject({
      cuenta_id: '7',
      rol,
      tipo,
      estado_membresia: 'activa',
    });
    expect(res.body.data.uso).toEqual({
      envejecientes: 1,
      usuarios: 2,
      familiares: 0,
      voluntarios: 0,
    });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('con la cuenta vencida sigue accesible (V2: se conserva la cuenta)', async () => {
    const vencido = contextoVencido('cuidador', 'organizacion');
    const rpc = rpcPorNombre({
      api_contexto_cuenta: () => vencido,
      api_obtener_cuenta: () => ({ ...detalleCrudo(), contexto: vencido }),
    });
    const res = await get(crearApp({ rpc }).app, '').expect(200);
    expect(res.body.data.contexto).toMatchObject({
      acceso_operativo: false,
      estado_suscripcion: 'vencida',
    });
  });

  it('no publica el titular ni campos fuera del contrato', async () => {
    const crudo = detalleCrudo();
    crudo.cuenta.usuario_titular_id = usuarioId;
    crudo.cuenta.plan_precio = 650;
    const rpc = cuentaCon('coordinador', 'familia', { api_obtener_cuenta: () => crudo });
    const res = await get(crearApp({ rpc }).app, '').expect(200);
    expect(JSON.stringify(res.body)).not.toMatch(/usuario_titular_id|plan_precio/);
  });

  it('el id inválido no consulta la base y un 403 de la RPC se respeta', async () => {
    const rpc = cuentaCon('familiar', 'familia', {
      api_obtener_cuenta: () => {
        throw mapRpcError({ code: '42501' });
      },
    });
    const { app } = crearApp({ rpc });
    await get(app, '').expect(403);
    await conSesion(request(app).get('/api/v1/cuentas/abc')).expect(404);
  });

  it('un contrato roto de la base es indisponibilidad', async () => {
    const rpc = cuentaCon('coordinador', 'familia', { api_obtener_cuenta: () => ({ cuenta: {} }) });
    await get(crearApp({ rpc }).app, '').expect(503);
  });
});

describe('RF-11: PATCH /cuentas/:cuentaId (organizacion:configurar)', () => {
  it.each(gestionan)('lo permite a %s / %s', async (tipo, rol) => {
    const rpc = cuentaCon(rol, tipo, { api_actualizar_cuenta: () => detalleCrudo(rol, tipo) });
    const { app, audit } = crearApp({ rpc });
    const res = await patch(app, '', { nombre: 'Casa Pérez', telefono: '809-555-1234' }).expect(
      200,
    );
    expect(rpc).toHaveBeenCalledWith('api_actualizar_cuenta', {
      p_cuenta_id: 7,
      p_datos: { nombre: 'Casa Pérez', telefono: '8095551234' },
    });
    expect(res.body.data.cuenta.cuenta_id).toBe('7');
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'cuenta.updated', actorId: usuarioId, result: 'success' }),
    );
  });

  it.each(noGestionan)('lo niega a %s / %s sin tocar la base', async (tipo, rol) => {
    const rpc = cuentaCon(rol, tipo, { api_actualizar_cuenta: () => detalleCrudo(rol, tipo) });
    const res = await patch(crearApp({ rpc }).app, '', { nombre: 'Casa' }).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(rpc).not.toHaveBeenCalledWith('api_actualizar_cuenta', expect.anything());
  });

  it('con la cuenta vencida sigue permitiendo gestionar la cuenta', async () => {
    const vencido = contextoVencido('administrador', 'organizacion');
    const rpc = rpcPorNombre({
      api_contexto_cuenta: () => vencido,
      api_actualizar_cuenta: () => ({ ...detalleCrudo(), contexto: vencido }),
    });
    await patch(crearApp({ rpc }).app, '', { direccion: 'Calle 9' }).expect(200);
  });

  it('una actualización parcial admite vaciar dirección, teléfono y correo con null', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_cuenta: () => detalleCrudo(),
    });
    await patch(crearApp({ rpc }).app, '', { direccion: '', telefono: null, correo: null }).expect(
      200,
    );
    expect(rpc).toHaveBeenCalledWith('api_actualizar_cuenta', {
      p_cuenta_id: 7,
      p_datos: { direccion: null, telefono: null, correo: null },
    });
  });

  it.each([
    ['sin campos', {}],
    ['tipo (no se puede cambiar)', { tipo: 'organizacion' }],
    ['titular', { usuario_titular_id: usuarioId }],
    ['suscripción', { suscripcion_estado: 'activa' }],
    ['plan', { plan_id: 3 }],
    ['nombre nulo', { nombre: null }],
    ['nombre de un carácter', { nombre: 'a' }],
    ['categoría como texto', { categoria_cuenta_id: '2' }],
    ['municipio inválido', { municipio_cod: '12' }],
    ['teléfono inválido', { telefono: '12' }],
    ['correo inválido', { correo: 'mal' }],
  ])('rechaza con 422 sin tocar la base: %s', async (_caso, cuerpo) => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_cuenta: () => detalleCrudo(),
    });
    await patch(crearApp({ rpc }).app, '', cuerpo).expect(422);
    expect(rpc).not.toHaveBeenCalledWith('api_actualizar_cuenta', expect.anything());
  });

  it('una categoría de otro tipo de cuenta es 422 INVALID_CATEGORY', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_cuenta: () => {
        throw mapRpcError({ code: 'P0001', message: 'CR_CATEGORIA_INVALIDA' });
      },
    });
    const res = await patch(crearApp({ rpc }).app, '', { categoria_cuenta_id: 5 }).expect(422);
    expect(res.body.error.code).toBe('INVALID_CATEGORY');
  });

  it('la autorización de la base también cuenta: 42501 es 403', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_cuenta: () => {
        throw mapRpcError({ code: '42501' });
      },
    });
    await patch(crearApp({ rpc }).app, '', { nombre: 'Casa' }).expect(403);
  });
});

describe('RF-19: configuración de la cuenta', () => {
  it.each(combinaciones)('cualquier miembro la lee (%s, %s)', async (tipo, rol) => {
    const rpc = cuentaCon(rol, tipo, { api_obtener_configuracion: () => parametros() });
    const res = await get(crearApp({ rpc }).app, '/configuracion').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_obtener_configuracion', { p_cuenta_id: 7 });
    expect(res.body.data).toEqual(parametros());
    expect(res.body.data[0]).toEqual({
      nombre: 'dias_sin_visita_alerta',
      valor: '15',
      tipo_dato: 'entero',
      es_propio: false,
      valor_general: '15',
      descripcion: 'Días sin visita para la alerta.',
    });
  });

  it('con la cuenta vencida sigue accesible', async () => {
    const rpc = rpcPorNombre({
      api_contexto_cuenta: () => contextoVencido('voluntario', 'organizacion'),
      api_obtener_configuracion: () => parametros(),
    });
    await get(crearApp({ rpc }).app, '/configuracion').expect(200);
  });

  it.each(gestionan)(
    '%s / %s cambia valores y vuelve a recibir la configuración efectiva',
    async (tipo, rol) => {
      const rpc = cuentaCon(rol, tipo, { api_actualizar_configuracion: () => parametros(true) });
      const { app, audit } = crearApp({ rpc });
      const res = await patch(app, '/configuracion', {
        valores: {
          dias_sin_visita_alerta: 30,
          notificar_casos_prioritarios: false,
          contacto_institucional_nombre: null,
        },
      }).expect(200);
      // Números y booleanos JSON se guardan como texto; null restablece el valor general.
      expect(rpc).toHaveBeenCalledWith('api_actualizar_configuracion', {
        p_cuenta_id: 7,
        p_valores: {
          dias_sin_visita_alerta: '30',
          notificar_casos_prioritarios: 'false',
          contacto_institucional_nombre: null,
        },
      });
      expect(res.body.data[0]).toMatchObject({
        nombre: 'dias_sin_visita_alerta',
        valor: '30',
        es_propio: true,
      });
      expect(audit).toHaveBeenCalledWith(
        expect.objectContaining({
          action: 'cuenta.config_updated',
          actorId: usuarioId,
          result: 'success',
        }),
      );
      // La auditoría técnica no incluye los valores configurados.
      expect(JSON.stringify(audit.mock.calls)).not.toContain('dias_sin_visita_alerta');
    },
  );

  it.each(noGestionan)('%s / %s no puede cambiar la configuración', async (tipo, rol) => {
    const rpc = cuentaCon(rol, tipo, { api_actualizar_configuracion: () => parametros(true) });
    await patch(crearApp({ rpc }).app, '/configuracion', {
      valores: { dias_sin_visita_alerta: '20' },
    }).expect(403);
    expect(rpc).not.toHaveBeenCalledWith('api_actualizar_configuracion', expect.anything());
  });

  it('con la cuenta vencida el administrador sigue pudiendo configurar', async () => {
    const rpc = rpcPorNombre({
      api_contexto_cuenta: () => contextoVencido('administrador', 'organizacion'),
      api_actualizar_configuracion: () => parametros(true),
    });
    await patch(crearApp({ rpc }).app, '/configuracion', {
      valores: { dias_sin_visita_alerta: '20' },
    }).expect(200);
  });

  it.each([
    ['sin cuerpo', undefined],
    ['sin valores', {}],
    ['valores vacío', { valores: {} }],
    ['valores como lista', { valores: [] }],
    ['nombre con mayúsculas', { valores: { DIAS: '1' } }],
    ['nombre con símbolos', { valores: { 'a;b': '1' } }],
    ['valor objeto', { valores: { dias_sin_visita_alerta: { a: 1 } } }],
    ['valor lista', { valores: { dias_sin_visita_alerta: ['1'] } }],
    ['campo extra', { valores: { dias_sin_visita_alerta: '1' }, cuenta_id: 9 }],
  ])('rechaza con 422 sin tocar la base: %s', async (_caso, cuerpo) => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_configuracion: () => parametros(),
    });
    await patch(crearApp({ rpc }).app, '/configuracion', cuerpo).expect(422);
    expect(rpc).not.toHaveBeenCalledWith('api_actualizar_configuracion', expect.anything());
  });

  it('un parámetro inexistente o un valor fuera de dominio es 422 INVALID_PARAMETER', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_actualizar_configuracion: () => {
        throw mapRpcError({ code: 'P0001', message: 'CR_PARAMETRO_INVALIDO' });
      },
    });
    const res = await patch(crearApp({ rpc }).app, '/configuracion', {
      valores: { dias_sin_visita_alerta: '91' },
    }).expect(422);
    expect(res.body.error.code).toBe('INVALID_PARAMETER');
  });
});

describe('RF-20: GET /cuentas/:cuentaId/suscripcion', () => {
  it.each(combinaciones)(
    'cualquier miembro ve estado, prueba, límites y uso (%s, %s)',
    async (tipo, rol) => {
      const rpc = cuentaCon(rol, tipo, { api_obtener_suscripcion: () => suscripcionCruda() });
      const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
      expect(rpc).toHaveBeenCalledWith('api_obtener_suscripcion', { p_cuenta_id: 7 });
      expect(res.body.data).toMatchObject({
        estado: 'prueba',
        acceso_operativo: true,
        prueba: {
          gratuita: true,
          vigente: true,
          fecha_inicio: '2026-11-06',
          fecha_fin: '2026-11-13',
          dias_restantes: 7,
        },
        plan: null,
        fecha_fin_vigencia: null,
        limites: { envejecientes: 2, usuarios: 4, familiares: 2 },
        uso: { envejecientes: 0, usuarios: 1, familiares: 0, voluntarios: 0 },
        funcionalidades: ['registro_visitas'],
      });
    },
  );

  it.each(gestionan)(
    '%s / %s ve además los planes compatibles con precio, límites y funcionalidades',
    async (tipo, rol) => {
      const rpc = cuentaCon(rol, tipo, { api_obtener_suscripcion: () => suscripcionCruda() });
      const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
      expect(res.body.data.planes).toEqual([
        {
          plan_id: 1,
          nombre: 'Básico Familiar',
          categoria: 'Básico',
          precio: 650,
          periodicidad: 'mensual',
          duracion_dias: 30,
          resumen: 'Hasta 2 adultos mayores.',
          limites: { envejecientes: 2, usuarios: null, familiares: 3 },
          funcionalidades: ['registro_visitas', 'necesidades_diarias'],
          es_actual: false,
        },
      ]);
    },
  );

  it.each(noGestionan)(
    '%s / %s no recibe los planes aunque la respuesta los trajera',
    async (tipo, rol) => {
      // Defensa en profundidad: la API recorta `planes` si el rol no tiene cuenta:suscripcion.
      const rpc = cuentaCon(rol, tipo, { api_obtener_suscripcion: () => suscripcionCruda() });
      const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
      expect(res.body.data).not.toHaveProperty('planes');
      expect(res.body.data.estado).toBe('prueba');
    },
  );

  it('si la base no entrega planes, no se inventan', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_obtener_suscripcion: () => suscripcionCruda({ planes: null }),
    });
    const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
    expect(res.body.data).not.toHaveProperty('planes');
  });

  it('con plan activo informa plan, vigencia y límites del plan', async () => {
    const rpc = cuentaCon(
      'administrador',
      'organizacion',
      {
        api_obtener_suscripcion: () =>
          suscripcionCruda({
            estado: 'activa',
            prueba: {
              gratuita: true,
              vigente: false,
              fecha_inicio: '2026-10-01',
              fecha_fin: '2026-10-08',
              dias_restantes: 0,
            },
            plan: {
              plan_id: 3,
              nombre: 'Operación Base',
              categoria: 'Básico',
              precio: 3500,
              periodicidad: 'mensual',
              duracion_dias: 30,
              resumen: null,
            },
            fecha_fin_vigencia: '2026-12-06',
            limites: { envejecientes: 15, usuarios: 20, familiares: null },
            planes: [],
          }),
      },
      { suscripcion_estado: 'activa' },
    );
    const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
    expect(res.body.data).toMatchObject({
      estado: 'activa',
      plan: { plan_id: 3, nombre: 'Operación Base', precio: 3500 },
      fecha_fin_vigencia: '2026-12-06',
      prueba: { vigente: false, dias_restantes: 0 },
      limites: { envejecientes: 15, usuarios: 20, familiares: null },
      planes: [],
    });
  });

  it('con la cuenta vencida sigue accesible y conserva la oferta de planes para quien gestiona', async () => {
    const rpc = rpcPorNombre({
      api_contexto_cuenta: () => contextoVencido('coordinador', 'familia'),
      api_obtener_suscripcion: () =>
        suscripcionCruda({
          estado: 'vencida',
          acceso_operativo: false,
          prueba: {
            gratuita: true,
            vigente: false,
            fecha_inicio: '2026-10-01',
            fecha_fin: '2026-10-08',
            dias_restantes: 0,
          },
          funcionalidades: [],
        }),
    });
    const res = await get(crearApp({ rpc }).app, '/suscripcion').expect(200);
    expect(res.body.data).toMatchObject({
      estado: 'vencida',
      acceso_operativo: false,
      funcionalidades: [],
    });
    expect(res.body.data.planes).toHaveLength(1);
  });

  it.each([
    ['estado desconocido', { estado: 'regalada' }],
    ['días restantes negativos', { prueba: { ...suscripcionCruda().prueba, dias_restantes: -1 } }],
    ['fecha inválida', { prueba: { ...suscripcionCruda().prueba, fecha_fin: '13/11/2026' } }],
    ['sin límites', { limites: undefined }],
  ])('un contrato roto de la base es indisponibilidad: %s', async (_caso, cambio) => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_obtener_suscripcion: () => suscripcionCruda(cambio),
    });
    await get(crearApp({ rpc }).app, '/suscripcion').expect(503);
  });

  it('un 42501 de la base se respeta como 403', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_obtener_suscripcion: vi.fn().mockRejectedValue(mapRpcError({ code: '42501' })),
    });
    await get(crearApp({ rpc }).app, '/suscripcion').expect(403);
  });
});
