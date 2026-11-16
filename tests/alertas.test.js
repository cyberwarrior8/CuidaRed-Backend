/* Contrato HTTP de alertas internas · ID06/RF-04/RF-18. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { conSesion, crearApp, cuentaCon, usuarioId } from './cuentas-support.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';

const prefijo = '/api/v1/cuentas/7';
const alertaId = '55555555-5555-4555-8555-555555555555';
const avisoId = '88888888-8888-4888-8888-888888888888';
const adulto = {
  envejeciente_id: '11111111-1111-4111-8111-111111111111',
  nombres: 'Juana',
  apellidos: 'Prueba',
};
const fecha = '2026-11-14T14:15:00Z';
const alerta = {
  ...adulto,
  alerta_envejeciente_id: alertaId,
  tipo: { codigo: 'riesgo_alto', nombre: 'Riesgo alto' },
  prioridad: { nombre: 'Alta', orden: 1 },
  descripcion: 'Caso de prueba.',
  origen: 'sistema',
  estado: 'pendiente',
  fecha_alerta: fecha,
  fecha_atencion: null,
  atendida_por: null,
  cierre_automatico: false,
  accion_tomada: null,
  fuente: { tipo: 'riesgo', referencia_id: '9007199254740995' },
  es_prioritaria: true,
};

describe('fase 6', () => {
  it('pagina por caso y proyecta solo campos públicos de las alertas', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_casos_prioritarios_listar: () => ({
        items: [
          {
            ...adulto,
            fecha_alerta: fecha,
            total_alertas: 2,
            alertas: [
              { ...alerta, datos_clinicos: 'dato privado' },
              { ...alerta, alerta_envejeciente_id: avisoId },
            ],
          },
        ],
        total: 1,
      }),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/casos-prioritarios`)).expect(200);
    expect(res.body.meta.total).toBe(1);
    expect(res.body.data[0].alertas).toHaveLength(2);
    expect(res.body.data[0].alertas[0]).toEqual(alerta);
  });

  it('el Cuidador resuelve con acción registrada, pero no inicia atención', async () => {
    const rpc = cuentaCon('cuidador', 'familia', {
      api_alerta_resolver: () => ({
        ...alerta,
        estado: 'resuelta',
        fecha_atencion: fecha,
        atendida_por: 'Persona de prueba',
        accion_tomada: 'Se hizo seguimiento.',
      }),
    });
    const { app, audit } = crearApp({ rpc });
    await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/en-atencion`)).expect(403);
    await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: ' ' })
      .expect(422);
    const res = await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: 'Se hizo seguimiento.' })
      .expect(200);
    expect(res.body.data.atendida_por).toBe('Persona de prueba');
    expect(rpc).toHaveBeenCalledWith('api_alerta_resolver', {
      p_cuenta_id: '7',
      p_alerta_id: alertaId,
      p_accion: 'Se hizo seguimiento.',
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'alerta.resuelta' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('Se hizo seguimiento.');
  });

  it('un aviso ajeno no revela su existencia ni acepta un destinatario en el cuerpo', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_notificacion_alerta_leer: () => {
        throw mapRpcError({ code: 'P0002', message: 'privado' });
      },
    });
    const { app } = crearApp({ rpc });
    const marca = `${prefijo}/notificaciones-alerta/${avisoId}/leer`;
    await conSesion(request(app).post(marca)).send({ usuario_id: usuarioId }).expect(422);
    const res = await conSesion(request(app).post(marca)).expect(404);
    expect(JSON.stringify(res.body)).not.toContain('privado');
  });
});
