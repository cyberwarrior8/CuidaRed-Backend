/* Rutas públicas sin sesión (solicitudes de visita de personas externas) · V2 §Visita. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { AppError, unavailable } from '../../lib/errors.js';
import { randomUUID } from 'node:crypto';
import { fotoVisitanteSchema, subirFotoVisitante } from './evidencias-visitante.js';
import { uuidParam } from '../visitas/visitas-schemas.js';
import '../visitas/visitas-errors.js';
import { parseBody } from '../visitas/visitas-schemas.js';
import {
  generarCodigoSeguimiento,
  hashCodigo,
  normalizarCodigo,
  PATRON_CODIGO,
} from './codigo-seguimiento.js';
import {
  consultaSchema,
  crearSolicitudSchema,
  ESTADO_TEXTO,
  estadoPublicoSchema,
  observacionSchema,
  organizacionesSchema,
  solicitudCreadaSchema,
  textoObservacion,
} from './publico-schemas.js';

// Límites por IP: el conjunto de rutas públicas y, además, la creación de solicitudes (que avisa al personal).
export const LIMITE_PUBLICO = { ventanaMs: 60_000, maximo: 10 };
export const LIMITE_CREACION = { ventanaMs: 60 * 60_000, maximo: 10 };

const limitador = ({ ventanaMs, maximo }) =>
  rateLimit({
    windowMs: ventanaMs,
    limit: maximo,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: (_req, _res, next) =>
      next(new AppError(429, 'RATE_LIMITED', 'Espera un momento antes de intentar de nuevo.')),
  });

// Mismo código y mensaje que el P0002 de la base: un código mal escrito y uno inexistente son indistinguibles.
const noEncontrada = () => new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');

// Contrato roto de la base: indisponibilidad, y solo salen los campos de la lista cerrada.
function salida(schema, data) {
  const result = schema.safeParse(data);
  if (!result.success) throw unavailable();
  return result.data;
}

/** Código inexistente o con formato inválido: el mismo 404 genérico, sin consultar la base si el formato no cuadra. */
function leerCodigo(codigo) {
  const normalizado = normalizarCodigo(codigo);
  if (!PATRON_CODIGO.test(normalizado)) throw noEncontrada();
  return normalizado;
}

/*
 * Rutas /publico/* montadas ANTES de requireSession. Express llama las RPC con su cliente dedicado,
 * aplica límites de peticiones y valida entradas y respuestas que no revelan datos
 * de cuentas ni de adultos. Nunca se listan cuentas Familia ni se confirma si un adulto existe.
 *
 *   GET  /publico/organizaciones                       { cuenta_id, nombre } de organizaciones con acceso operativo
 *   POST /publico/solicitudes-visita                   crea la solicitud y devuelve el código UNA vez
 *   POST /publico/solicitudes-visita/consulta          { codigo } → estado público
 *   POST /publico/solicitudes-visita/observacion       { codigo, observacion } desde el inicio de la cita
 *   POST /publico/solicitudes-visita/evidencias        { codigo, id, nombre, archivo } foto privada
 */
export function createPublicoRouter(deps, rpc) {
  const router = Router({ mergeParams: true });
  const huella = (codigo) => hashCodigo(codigo, deps.env?.CODIGO_SEGUIMIENTO_SECRETO);
  const log = (res, action) =>
    deps.audit({ requestId: res.locals.requestId, action, result: 'success' });

  router.use((_req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });
  router.use(limitador(LIMITE_PUBLICO));

  router.get('/organizaciones', async (_req, res) => {
    const data = salida(organizacionesSchema, await rpc('api_publico_listar_organizaciones', {}));
    res.json({ data });
  });

  router.post('/solicitudes-visita', limitador(LIMITE_CREACION), async (req, res) => {
    const { idempotencia, ...datos } = parseBody(crearSolicitudSchema, req.body);
    // El código se genera aquí y a la base solo llega su hash: ni la base ni los registros guardan el código.
    const referencia = idempotencia ?? randomUUID();
    const codigo = generarCodigoSeguimiento(referencia, deps.env?.CODIGO_SEGUIMIENTO_SECRETO);
    const creada = salida(
      solicitudCreadaSchema,
      await rpc('api_publico_crear_solicitud', {
        p_datos: { ...datos, codigo_hash: huella(codigo), referencia_codigo: referencia },
      }),
    );
    log(res, 'solicitud_visita.creada');
    res.status(201).json({ data: { codigo, ...creada } });
  });

  router.post('/solicitudes-visita/consulta', async (req, res) => {
    const { codigo } = parseBody(consultaSchema, req.body);
    const hash = huella(leerCodigo(codigo));
    const estado = salida(
      estadoPublicoSchema,
      await rpc('api_publico_consultar_solicitud', { p_codigo_hash: hash }),
    );
    res.json({
      data: {
        ...estado,
        estado_texto:
          estado.estado === 'autorizada' && estado.reprogramada
            ? 'Reprogramada'
            : ESTADO_TEXTO[estado.estado],
      },
    });
  });

  router.post('/solicitudes-visita/observacion', async (req, res) => {
    const { codigo, observacion } = parseBody(observacionSchema, req.body);
    const hash = huella(leerCodigo(codigo));
    const texto = parseBody(textoObservacion, observacion);
    const estado = salida(
      estadoPublicoSchema,
      await rpc('api_publico_registrar_observacion_posterior', {
        p_codigo_hash: hash,
        p_observacion: texto,
      }),
    );
    log(res, 'solicitud_visita.observacion');
    res.json({ data: { ...estado, estado_texto: ESTADO_TEXTO[estado.estado] } });
  });

  router.post('/solicitudes-visita/evidencias', limitador(LIMITE_CREACION), async (req, res) => {
    const datos = parseBody(fotoVisitanteSchema, req.body);
    const hash = huella(leerCodigo(datos.codigo));
    const estado = salida(
      estadoPublicoSchema,
      await subirFotoVisitante({
        hash,
        datos,
        rpc,
        storage: deps.adminGateway?.evidenciaVisitante,
      }),
    );
    log(res, 'solicitud_visita.evidencia');
    res.status(201).json({ data: { ...estado, estado_texto: ESTADO_TEXTO[estado.estado] } });
  });
  router.post('/solicitudes-visita/evidencias/:id/descarga', async (req, res) => {
    const { codigo } = parseBody(consultaSchema, req.body);
    const data = await rpc('api_publico_evidencia_descarga', {
      p_codigo_hash: huella(leerCodigo(codigo)),
      p_id: uuidParam(req.params.id),
    });
    if (!data?.ruta || !data?.nombre || !deps.adminGateway?.evidenciaVisitante) throw unavailable();
    res.json({
      data: { url: await deps.adminGateway.evidenciaVisitante.descarga(data.ruta, data.nombre) },
    });
  });

  // Cualquier otra ruta o método bajo /publico es 404: nunca cae en la validación de sesión de las rutas protegidas.
  router.use((_req, _res, next) => next(noEncontrada()));

  return router;
}
