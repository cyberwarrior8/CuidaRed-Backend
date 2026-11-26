/* Autorización, privacidad y errores de Backoffice · BO-01 a BO-26. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/lib/errors.js';
import { createAdminGateway } from '../src/lib/supabase-admin.js';
import { createSystemLogger } from '../src/lib/system-logger.js';
import { prepareLogo } from '../src/modules/backoffice/backoffice-brand.js';

const actor = 'a5027ba5-9a17-47fa-8872-1221f994a6be';
const session = '73b4218e-be00-4325-a873-cd7e43df0edd';
const token = (aal = 'aal1') =>
  'header.' +
  Buffer.from(JSON.stringify({ sub: actor, session_id: session, aal })).toString('base64url') +
  '.firma';
const bearer = (aal) => 'Bearer ' + token(aal);
function fixture(handlers = {}, { stripe, stripeProducts, ...environment } = {}) {
  const rpc = vi.fn(async (name, args) => {
    if (name in handlers) return handlers[name](args);
    if (name === 'sesion') return { estado: 'ok', rol: 'auditor', usuario_id: actor };
    if (name === 'leer') return { data: [], meta: { page: 1, limit: 25, total: 0, totalPages: 1 } };
    return undefined;
  });
  const gateway = {
    authenticate: vi.fn(async () => ({ id: actor })),
    passwordSession: vi.fn(async () => ({
      access_token: token(),
      refresh_token: 'refresh',
      actorId: actor,
    })),
  };
  const app = createApp({
    env: {
      origins: ['http://localhost:5174'],
      SUPABASE_URL: 'https://test.supabase.co',
      stripeProducts,
      ...environment,
    },
    gateway,
    adminGateway: { backofficeRpc: rpc },
    stripe,
    audit: vi.fn(),
  });
  return { app, rpc, gateway };
}

describe('Disponibilidad de tarifas de Stripe Sandbox', () => {
  const sesion = () => ({ estado: 'ok', rol: 'super_admin' });
  const tarifas = '/api/admin/planes-stripe';
  const codigo = 'basico_familiar_mensual';
  const cambio = { importe_centavos: 950, motivo: 'Ajuste de tarifa de prueba' };

  it('informa los bloqueos de configuración y rechaza la publicación antes de crear un precio', async () => {
    const { app, rpc } = fixture({ sesion, stripe_leer: () => ({ tarifas: [] }) });
    const consulta = await request(app)
      .get(tarifas)
      .set('Authorization', bearer('aal2'))
      .expect(200);
    expect(consulta.body.data).toEqual({
      tarifas: [],
      disponibles: false,
      bloqueos: ['sandbox_inactivo', 'productos_sin_configurar'],
    });
    const publicacion = await request(app)
      .patch(`${tarifas}/${codigo}`)
      .set('Authorization', bearer('aal2'))
      .send(cambio)
      .expect(503);
    expect(publicacion.body.error.code).toBe('SANDBOX_UNAVAILABLE');
    expect(rpc.mock.calls.some(([name]) => name === 'stripe_preparar_tarifa')).toBe(false);
  });

  it('con el sandbox y el producto configurados permite crear y publicar la tarifa de prueba', async () => {
    const stripe = {
      createPrice: vi.fn().mockResolvedValue({
        id: 'price_Basico',
        product: 'prod_Basico',
        livemode: false,
        active: true,
        type: 'recurring',
        billing_scheme: 'per_unit',
        unit_amount: 950,
        currency: 'usd',
        recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' },
      }),
    };
    const { app, rpc } = fixture(
      {
        sesion,
        stripe_leer: () => ({ tarifas: [] }),
        stripe_preparar_tarifa: () => ({ periodicidad: 'mensual' }),
      },
      { stripe, stripeProducts: { basico_familiar: 'prod_Basico' } },
    );
    const consulta = await request(app)
      .get(tarifas)
      .set('Authorization', bearer('aal2'))
      .expect(200);
    expect(consulta.body.data).toMatchObject({ disponibles: true, bloqueos: [] });
    await request(app)
      .patch(`${tarifas}/${codigo}`)
      .set('Authorization', bearer('aal2'))
      .send(cambio)
      .expect(204);
    expect(stripe.createPrice).toHaveBeenCalledOnce();
    expect(rpc).toHaveBeenCalledWith(
      'stripe_publicar_tarifa',
      expect.objectContaining({
        p_cuenta_id: null,
        p_codigo: codigo,
        p_importe_centavos: 950,
        p_price_id: 'price_Basico',
      }),
    );
  });

  it('publica Operación Base como tarifa general sin una cotización', async () => {
    const codigoBase = 'operacion_base_anual';
    const tarifaBase = {
      codigo: codigoBase,
      nombre: 'Operación Base',
      periodicidad: 'anual',
      moneda: 'USD',
      importe_sugerido_centavos: null,
      importe_centavos: null,
    };
    const stripe = {
      createPrice: vi.fn().mockResolvedValue({
        id: 'price_Base',
        product: 'prod_Base',
        livemode: false,
        active: true,
        type: 'recurring',
        billing_scheme: 'per_unit',
        unit_amount: 950,
        currency: 'usd',
        recurring: { interval: 'year', interval_count: 1, usage_type: 'licensed' },
      }),
    };
    const { app, rpc } = fixture(
      {
        sesion,
        stripe_leer: () => ({ tarifas: [tarifaBase] }),
        stripe_preparar_tarifa: () => ({ periodicidad: 'anual' }),
      },
      { stripe, stripeProducts: { operacion_base: 'prod_Base' } },
    );
    const consulta = await request(app)
      .get(tarifas)
      .set('Authorization', bearer('aal2'))
      .expect(200);
    expect(consulta.body.data.tarifas).toEqual([tarifaBase]);
    await request(app)
      .patch(`${tarifas}/${codigoBase}`)
      .set('Authorization', bearer('aal2'))
      .send(cambio)
      .expect(204);
    expect(stripe.createPrice).toHaveBeenCalledWith(
      expect.objectContaining({ product: 'prod_Base', recurring: { interval: 'year' } }),
      expect.any(String),
    );
    expect(rpc).toHaveBeenCalledWith(
      'stripe_publicar_tarifa',
      expect.objectContaining({
        p_cuenta_id: null,
        p_codigo: codigoBase,
        p_price_id: 'price_Base',
      }),
    );
  });

  it('requiere cuatro cupos explícitos y versiona cada edición de una cotización de Avanzada', async () => {
    const cotizacion = '/api/admin/cuentas/5/cotizaciones-stripe';
    const avanzada = 'gestion_comunitaria_avanzada_mensual';
    const propuesta = { envejecientes: 30, usuarios: 40, cuidadores: 25, familiares: null };
    const versionAnterior = '783ae9ab-9ce2-4da5-90c1-98dad6a1e73b';
    const stripe = {
      createPrice: vi.fn().mockResolvedValue({
        id: 'price_Avanzada',
        product: 'prod_Avanzada',
        livemode: false,
        active: true,
        type: 'recurring',
        billing_scheme: 'per_unit',
        unit_amount: 950,
        currency: 'usd',
        recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' },
      }),
    };
    const preparar = vi.fn().mockReturnValue({
      periodicidad: 'mensual',
      version_actual: versionAnterior,
      sin_cambios: false,
    });
    const { app, rpc } = fixture(
      { sesion, stripe_preparar_tarifa: preparar },
      { stripe, stripeProducts: { gestion_comunitaria_avanzada: 'prod_Avanzada' } },
    );
    const publicar = (codigo, body) =>
      request(app).patch(`${cotizacion}/${codigo}`).set('Authorization', bearer('aal2')).send(body);
    await publicar('operacion_base_mensual', { ...cambio, limites: propuesta }).expect(422);
    await publicar(avanzada, cambio).expect(422);
    await publicar(avanzada, { ...cambio, limites: { ...propuesta, cuidadores: 0 } }).expect(422);
    await publicar(avanzada, { ...cambio, limites: { ...propuesta, usuarios: 100001 } }).expect(
      422,
    );
    expect(preparar).not.toHaveBeenCalled();
    expect(stripe.createPrice).not.toHaveBeenCalled();

    const desactualizada = await publicar(avanzada, {
      ...cambio,
      limites: propuesta,
      version: null,
    }).expect(409);
    expect(desactualizada.body.error.code).toBe('QUOTE_UPDATED');
    expect(stripe.createPrice).not.toHaveBeenCalled();

    await publicar(avanzada, { ...cambio, limites: propuesta, version: versionAnterior }).expect(
      204,
    );
    await publicar(avanzada, { ...cambio, limites: propuesta }).expect(204);
    await publicar(avanzada, { ...cambio, limites: { ...propuesta, cuidadores: 26 } }).expect(204);
    expect(stripe.createPrice.mock.calls[0][1]).toBe(stripe.createPrice.mock.calls[1][1]);
    expect(stripe.createPrice.mock.calls[0][1]).not.toBe(stripe.createPrice.mock.calls[2][1]);
    expect(rpc).toHaveBeenCalledWith(
      'stripe_preparar_tarifa',
      expect.objectContaining({
        p_cuenta_id: '5',
        p_codigo: avanzada,
        p_limites: propuesta,
        p_importe_centavos: 950,
      }),
    );
    expect(rpc).toHaveBeenCalledWith(
      'stripe_publicar_tarifa',
      expect.objectContaining({
        p_cuenta_id: '5',
        p_codigo: avanzada,
        p_limites: propuesta,
        p_version_esperada: versionAnterior,
        p_price_id: 'price_Avanzada',
      }),
    );

    preparar.mockReturnValueOnce({
      periodicidad: 'mensual',
      version_actual: versionAnterior,
      sin_cambios: true,
    });
    await publicar(avanzada, { ...cambio, limites: propuesta, version: null }).expect(204);
    expect(stripe.createPrice).toHaveBeenCalledTimes(3);
  });
});

describe('Backoffice y PWA aislados', () => {
  it('retira la asignación de plan gratuito aun para un administrador con MFA', async () => {
    const { app, rpc } = fixture({ sesion: () => ({ estado: 'ok', rol: 'super_admin' }) });
    await request(app)
      .post('/api/admin/cuentas/5/plan-gratuito')
      .set('Authorization', bearer('aal2'))
      .send({ motivo: 'Asignación retirada' })
      .expect(404);
    expect(rpc.mock.calls.some(([name]) => name === 'stripe_plan_gratuito')).toBe(false);
  });

  it.each(['super_admin', 'soporte', 'auditor'])(
    'supervisa los módulos como %s sin publicar configuración privada',
    async (rol) => {
      const { app, rpc } = fixture(
        {
          sesion: () => ({ estado: 'ok', rol }),
          supervision: () => ({ solicitudes: { pendientes: 3 }, correos: [] }),
        },
        {
          VISITAS_CORREO_HABILITADO: false,
          VISITAS_CORREO_PROVEEDOR: 'smtp',
          VISITAS_CORREO_REMITENTE: 'piloto@example.test',
          VISITAS_SMTP_HOST: 'smtp.example.test',
          VISITAS_SMTP_USUARIO: 'piloto@example.test',
          VISITAS_SMTP_PASSWORD: 'no-exponer-en-la-respuesta',
          PWA_ORIGIN: 'https://pwa.example.test',
        },
      );
      const res = await request(app)
        .get('/api/admin/supervision?meses=12')
        .set('Authorization', bearer('aal2'))
        .expect(200);
      expect(res.body.data.servicios.correo).toEqual({
        habilitado: false,
        configurado: true,
        proveedor: 'smtp',
      });
      expect(JSON.stringify(res.body)).not.toMatch(/no-exponer|piloto@example|smtp.example/);
      expect(rpc).toHaveBeenCalledWith(
        'supervision',
        expect.objectContaining({ p_actor: actor, p_sesion: session, p_aal: 'aal2', p_meses: 12 }),
      );
    },
  );
  it('deniega el seguimiento anónimo y rechaza filtros que intenten cambiar su alcance', async () => {
    const { app, rpc } = fixture();
    await request(app).get('/api/admin/supervision').expect(401);
    await request(app)
      .get('/api/admin/supervision?meses=60')
      .set('Authorization', bearer())
      .expect(422);
    await request(app)
      .get('/api/admin/supervision?usuario=otro')
      .set('Authorization', bearer())
      .expect(422);
    expect(rpc.mock.calls.some(([name]) => name === 'supervision')).toBe(false);
  });
  it('valida la vista previa del logo sin guardarlo ni publicarlo', async () => {
    const { app, rpc } = fixture({ sesion: () => ({ estado: 'ok', rol: 'super_admin' }) });
    const image =
      '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><circle cx="24" cy="20" r="12" fill="blue"/></svg>';
    const res = await request(app)
      .post('/api/admin/logos/completo_claro/validar')
      .set('Authorization', bearer('aal2'))
      .set('Content-Type', 'image/svg+xml')
      .send(image)
      .expect(200);
    expect(res.headers['content-type']).toContain('image/png');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(rpc.mock.calls.some(([name]) => name === 'mutar')).toBe(false);
    await request(app)
      .post('/api/admin/logos/completo_claro/validar')
      .set('Authorization', bearer('aal2'))
      .set('Content-Type', 'image/svg+xml')
      .send('<svg><script>alert(1)</script></svg>')
      .expect(422);
  });
  it.each(['soporte', 'auditor'])('impide validar logos desde el rol %s', async (rol) => {
    const { app } = fixture({ sesion: () => ({ estado: 'ok', rol }) });
    await request(app)
      .post('/api/admin/logos/completo_claro/validar')
      .set('Authorization', bearer())
      .set('Content-Type', 'image/png')
      .send(Buffer.from('no-es-un-logo'))
      .expect(403);
  });
  it('exige un JWT y audita las acciones denegadas al auditor', async () => {
    const { app, rpc } = fixture();
    await request(app).get('/api/admin/cuentas').expect(401);
    await request(app)
      .post('/api/admin/cuentas/5/estado')
      .set('Authorization', bearer())
      .send({ estado: 'deshabilitada', motivo: 'Bloqueo de prueba' })
      .expect(403);
    expect(rpc).toHaveBeenCalledWith(
      'auditar',
      expect.objectContaining({ p_accion: 'acceso.denegado', p_actor: actor }),
    );
    expect(rpc.mock.calls.some(([name]) => name === 'mutar')).toBe(false);
  });
  it('restringe la exportación de logs al super administrador y auditor', async () => {
    const { app } = fixture({ sesion: () => ({ estado: 'ok', rol: 'soporte' }) });
    await request(app).get('/api/admin/logs').set('Authorization', bearer()).expect(200);
    await request(app)
      .get('/api/admin/logs/exportacion')
      .set('Authorization', bearer())
      .expect(403);
  });
  it('la API exige MFA antes de entregar información al administrador', async () => {
    const { app, rpc } = fixture({ sesion: () => ({ estado: 'mfa' }) });
    const res = await request(app)
      .get('/api/admin/resumen')
      .set('Authorization', bearer())
      .expect(403);
    expect(res.body.error.code).toBe('MFA_REQUIRED');
    expect(rpc.mock.calls.some(([name]) => name === 'leer')).toBe(false);
  });
  it('rechaza las credenciales válidas de PWA sin devolver sus tokens', async () => {
    const { app } = fixture({ intento: () => false, admitir: () => false });
    const res = await request(app)
      .post('/api/admin/login')
      .send({ email: 'persona@example.test', password: 'pass' })
      .expect(403);
    expect(res.body.data).toBeUndefined();
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
  it('respeta el bloqueo temporal antes de consultar Auth', async () => {
    const { app, gateway } = fixture({ intento: () => true });
    await request(app)
      .post('/api/admin/login')
      .send({ email: 'persona@example.test', password: 'pass' })
      .expect(429);
    expect(gateway.passwordSession).not.toHaveBeenCalled();
  });
  it('respeta un resultado vacío y propaga errores de escrituras', async () => {
    const { app, rpc } = fixture({
      sesion: () => ({ estado: 'ok', rol: 'soporte' }),
      mutar: () => {
        throw new AppError(503, 'DEPENDENCY_UNAVAILABLE', 'Servicio no disponible.');
      },
    });
    const list = await request(app)
      .get('/api/admin/cuentas?search=cuenta&limit=25')
      .set('Authorization', bearer())
      .expect(200);
    expect(list.body.data).toEqual([]);
    await request(app)
      .post('/api/admin/cuentas/5/estado')
      .set('Authorization', bearer())
      .send({ estado: 'deshabilitada', motivo: 'Bloqueo de prueba' })
      .expect(503);
    expect(rpc).toHaveBeenCalledWith(
      'mutar',
      expect.objectContaining({ p_datos: { cuenta: '5', estado: 'deshabilitada' } }),
    );
  });
  it('acepta categorías de telemetría y rechaza cargas arbitrarias', async () => {
    const { app, rpc } = fixture();
    await request(app)
      .post('/api/admin/telemetria')
      .send({ evento: 'javascript.error', detalle: 'información no permitida' })
      .expect(422);
    await request(app)
      .post('/api/admin/telemetria')
      .send({ evento: 'javascript.error' })
      .expect(204);
    expect(rpc).toHaveBeenCalledWith(
      'log',
      expect.objectContaining({
        p_evento: expect.objectContaining({ origen: 'frontend', ruta: '/pwa' }),
      }),
    );
  });
  it('acepta SVG vectorial transparente y lo guarda como PNG', async () => {
    const valid = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 40" width="80" height="40"><circle cx="20" cy="20" r="10" fill="blue"/></svg>',
    );
    const result = await prepareLogo(valid, 'image/svg+xml', 'completo_claro');
    expect(result.path).toMatch(/^completo_claro\/.+\.png$/);
    expect(result.data.subarray(1, 4).toString()).toBe('PNG');
    const invalid = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.test/image.png"/></svg>',
    );
    await expect(prepareLogo(invalid, 'image/svg+xml', 'completo_claro')).rejects.toMatchObject({
      code: 'INVALID_LOGO',
    });
  });
});

describe('Fallos transitorios de Supabase en el Backoffice', () => {
  const env = {
    SUPABASE_URL: 'https://test.supabase.co',
    SUPABASE_SECRET_KEY: 'sb_secret_test',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
  };
  const transient = () => Response.json({ code: 'PGRST003' }, { status: 504 });

  it('reintenta validar y devuelve el estado MFA que entrega Supabase', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new DOMException('Expiró el intento', 'TimeoutError'))
      .mockResolvedValueOnce(Response.json({ estado: 'mfa' }));
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'validar' })).resolves.toEqual({
      estado: 'mfa',
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('conserva el fallo final con diagnóstico limitado y evita reintentar el registro de ingreso', async () => {
    const fetch = vi.fn(async () => transient());
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'validar' })).rejects.toMatchObject({
      code: 'DEPENDENCY_UNAVAILABLE',
      dependency: 'supabase.api_bo_sesion',
      upstreamStatus: 504,
      upstreamCode: 'PGRST003',
    });
    expect(fetch).toHaveBeenCalledTimes(2);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'ingreso' })).rejects.toMatchObject({
      code: 'DEPENDENCY_UNAVAILABLE',
    });
    expect(fetch).toHaveBeenCalledTimes(3);
  });

  it('recupera una lectura tras una interrupción de transporte', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Conexión interrumpida'))
      .mockResolvedValueOnce(Response.json({ data: [] }));
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('leer', { p_recurso: 'logs' })).resolves.toEqual({
      data: [],
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('reintenta un log rechazado por el pool, pero registra el diagnóstico de un fallo ambiguo', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(transient())
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(Response.json({ code: 'XX000' }, { status: 502 }));
    const audit = vi.fn();
    const recordLog = createSystemLogger(createAdminGateway(env, fetch), audit);
    const event = { p_evento: { request_id: session, mensaje: 'Evento de prueba' } };
    await expect(recordLog(event)).resolves.toBe(true);
    await expect(recordLog(event)).resolves.toBe(false);
    expect(fetch).toHaveBeenCalledTimes(3);
    expect(audit).toHaveBeenCalledExactlyOnceWith({
      requestId: session,
      action: 'log.persistence',
      result: 'error',
      code: 'LOG_STORAGE_UNAVAILABLE',
      dependency: 'supabase.api_bo_log',
      upstreamStatus: 502,
      upstreamCode: 'XX000',
    });
  });
});
