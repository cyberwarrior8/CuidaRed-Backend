/* Aportes externos: archivos privados, límites e idempotencia. © 2026 Equipo CuidaRed – INTEC. */
import { describe, it, expect, vi } from 'vitest';
import { randomBytes } from 'node:crypto';
import sharp from 'sharp';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { subirFotoVisitante } from '../src/modules/publico/evidencias-visitante.js';

const id = '11111111-1111-4111-8111-111111111111';
const hash = 'a'.repeat(64);
const ruta = `solicitud/22222222-2222-4222-8222-222222222222/${id}.jpg`;
function setup(options = {}) {
  const estado = {
    estado: 'autorizada',
    puede_adjuntar_evidencias: true,
    evidencias: [],
    ...options.estado,
  };
  const rpc = vi.fn(async (name) => {
    if (name === 'api_publico_consultar_solicitud') return estado;
    if (name === 'api_publico_preparar_evidencia') return { id, ruta, adjunta: false };
    if (name === 'api_publico_adjuntar_evidencia') {
      if (options.errorFinal) throw options.errorFinal;
      return { ...estado, evidencias: [{ evidencia_id: id }] };
    }
    if (name === 'api_publico_descartar_evidencia') return options.confirmada ? null : ruta;
    throw new Error(name);
  });
  const storage = { subir: vi.fn(async () => {}), borrar: vi.fn(async () => {}) };
  return { rpc, storage, estado };
}
const foto = async () =>
  (
    await sharp({ create: { width: 8, height: 6, channels: 3, background: '#14628a' } })
      .withMetadata({ orientation: 6 })
      .jpeg()
      .toBuffer()
  ).toString('base64');

it('Express acepta una fotografía mayor de 16 KB sin ampliar los cuerpos de consulta o descarga', async () => {
  const estado = {
    organizacion: 'Organización sintética',
    estado: 'autorizada',
    fecha: '2026-11-23',
    hora: '10:00',
    motivo_rechazo: null,
    puede_registrar_observacion: true,
    observacion: null,
    puede_adjuntar_evidencias: true,
    evidencias: [],
  };
  const storage = { subir: vi.fn(async () => {}), borrar: vi.fn(async () => {}) };
  const rpc = vi.fn(async (name) => {
    if (name === 'api_publico_consultar_solicitud') return estado;
    if (name === 'api_publico_preparar_evidencia') return { id, ruta, adjunta: false };
    if (name === 'api_publico_adjuntar_evidencia')
      return {
        ...estado,
        evidencias: [
          { evidencia_id: id, nombre_archivo: 'actividad.jpg', fecha: new Date().toISOString() },
        ],
      };
    throw new Error(name);
  });
  const app = createApp({
    env: {
      origins: [],
      VISITAS_PUBLICAS_HABILITADAS: true,
      CODIGO_SEGUIMIENTO_SECRETO: 'secreto-sintetico-solo-para-probar-fotografias',
    },
    gateway: {},
    audit: vi.fn(),
    adminGateway: { visitaPublicaRpc: rpc, evidenciaVisitante: storage },
  });
  const archivo = (
    await sharp(randomBytes(96 * 96 * 3), { raw: { width: 96, height: 96, channels: 3 } })
      .png()
      .toBuffer()
  ).toString('base64');
  const cuerpo = { codigo: 'VIS-ABCD-2345', id, nombre: 'actividad.png', archivo };
  expect(Buffer.byteLength(JSON.stringify(cuerpo))).toBeGreaterThan(16384);
  const respuesta = await request(app)
    .post('/api/v1/publico/solicitudes-visita/evidencias')
    .send(cuerpo)
    .expect(201);
  expect(respuesta.body.data.evidencias[0].nombre_archivo).toBe('actividad.jpg');
  expect(storage.subir).toHaveBeenCalledOnce();
  expect((await sharp(storage.subir.mock.calls[0][1]).metadata()).format).toBe('jpeg');
  await request(app).post('/api/v1/publico/solicitudes-visita/consulta').send(cuerpo).expect(413);
  await request(app)
    .post(`/api/v1/publico/solicitudes-visita/evidencias/${id}/descarga`)
    .send(cuerpo)
    .expect(413);
  expect(rpc).toHaveBeenCalledTimes(3);
});
describe('fotografías del visitante sin cuenta', () => {
  it('rechaza antes del horario sin subir ni reservar archivos', async () => {
    const ctx = setup({ estado: { puede_adjuntar_evidencias: false } });
    await expect(
      subirFotoVisitante({ ...ctx, hash, datos: { id, nombre: 'foto.jpg', archivo: 'AAAA' } }),
    ).rejects.toMatchObject({ status: 409 });
    expect(ctx.rpc).toHaveBeenCalledTimes(1);
    expect(ctx.storage.subir).not.toHaveBeenCalled();
  });
  it('un código inexistente no llega a Storage', async () => {
    const ctx = setup();
    ctx.rpc.mockRejectedValueOnce({ status: 404 });
    await expect(
      subirFotoVisitante({ ...ctx, hash, datos: { id, nombre: 'foto.jpg', archivo: 'AAAA' } }),
    ).rejects.toMatchObject({ status: 404 });
    expect(ctx.storage.subir).not.toHaveBeenCalled();
  });
  it('rechaza HTML/SVG que intenta presentarse como una fotografía', async () => {
    const ctx = setup();
    await expect(
      subirFotoVisitante({
        ...ctx,
        hash,
        datos: {
          id,
          nombre: 'foto.jpg',
          archivo: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>').toString('base64'),
        },
      }),
    ).rejects.toMatchObject({ status: 422 });
    expect(ctx.storage.subir).not.toHaveBeenCalled();
    expect(ctx.rpc).toHaveBeenCalledTimes(1);
  });
  it('normaliza la fotografía, elimina EXIF y conserva el ámbito de la solicitud', async () => {
    const ctx = setup();
    await subirFotoVisitante({
      ...ctx,
      hash,
      datos: { id, nombre: 'actividad.png', archivo: await foto() },
    });
    expect(ctx.rpc.mock.calls[1]).toEqual([
      'api_publico_preparar_evidencia',
      expect.objectContaining({
        p_codigo_hash: hash,
        p_id: id,
        p_nombre: 'actividad.jpg',
        p_sha: expect.stringMatching(/^[a-f0-9]{64}$/),
      }),
    ]);
    expect(ctx.storage.subir).toHaveBeenCalledWith(ruta, expect.any(Buffer));
    const metadata = await sharp(ctx.storage.subir.mock.calls[0][1]).metadata();
    expect(metadata.format).toBe('jpeg');
    expect(metadata.exif).toBeUndefined();
    expect(metadata.orientation).toBeUndefined();
    expect(ctx.rpc.mock.calls[2]).toEqual([
      'api_publico_adjuntar_evidencia',
      { p_codigo_hash: hash, p_id: id },
    ]);
  });
  it('no reescribe ni vuelve a procesar una fotografía ya confirmada', async () => {
    const ctx = setup({ estado: { evidencias: [{ evidencia_id: id }] } });
    await expect(
      subirFotoVisitante({
        ...ctx,
        hash,
        datos: { id, nombre: 'foto.jpg', archivo: 'no se procesa' },
      }),
    ).resolves.toBe(ctx.estado);
    expect(ctx.storage.subir).not.toHaveBeenCalled();
    expect(ctx.rpc).toHaveBeenCalledTimes(1);
  });
  it('limpia únicamente la reserva propia si falla la entrega', async () => {
    const ctx = setup();
    ctx.storage.subir.mockRejectedValueOnce(new Error('Corte simulado'));
    await expect(
      subirFotoVisitante({
        ...ctx,
        hash,
        datos: { id, nombre: 'foto.jpg', archivo: await foto() },
      }),
    ).rejects.toThrow('Corte simulado');
    expect(ctx.rpc).toHaveBeenLastCalledWith('api_publico_descartar_evidencia', {
      p_codigo_hash: hash,
      p_id: id,
    });
    expect(ctx.storage.borrar).toHaveBeenCalledWith(ruta);
  });
  it('conserva el objeto si el registro se confirmó pese a perderse la respuesta', async () => {
    const ctx = setup({ confirmada: true, errorFinal: new Error('Respuesta perdida') });
    await expect(
      subirFotoVisitante({
        ...ctx,
        hash,
        datos: { id, nombre: 'foto.jpg', archivo: await foto() },
      }),
    ).rejects.toThrow('Respuesta perdida');
    expect(ctx.storage.borrar).not.toHaveBeenCalled();
  });
});
