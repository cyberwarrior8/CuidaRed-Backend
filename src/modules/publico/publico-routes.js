/* Rutas públicas sin sesión (solicitudes de visita de personas externas) · V2 §Visita. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { AppError, unavailable } from '../../lib/errors.js';
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
 * Rutas /publico/* montadas ANTES de requireSession: no hay identidad. Cada ruta usa el cliente anon del gateway, que solo
 * acepta RPC `api_publico_*`, con su propio límite de peticiones, entrada estricta (Zod) y respuestas que no revelan datos
 * de cuentas ni de adultos. Nunca se listan cuentas Familia ni se confirma si un adulto existe.
 *
 *   GET  /publico/organizaciones                       { cuenta_id, nombre } de organizaciones con acceso operativo
 *   POST /publico/solicitudes-visita                   crea la solicitud y devuelve el código UNA vez
 *   POST /publico/solicitudes-visita/consulta          { codigo } → estado público
 *   POST /publico/solicitudes-visita/observacion       { codigo, observacion } → visita realizada
 */
export function createPublicoRouter(deps) {
  const router = Router({ mergeParams: true });
  // El cliente anon se pide en cada petición: así el router se monta aunque el gateway no lo ofrezca (pruebas).
  const rpc = (nombre, parametros) => deps.gateway.publico().rpc(nombre, parametros);
  const huella = (codigo) => hashCodigo(codigo, deps.env?.CODIGO_SEGUIMIENTO_SECRETO);
  const log = (res, action) =>
    deps.audit({ requestId: res.locals.requestId, action, result: 'success' });

  router.use(limitador(LIMITE_PUBLICO));

  router.get('/organizaciones', async (_req, res) => {
    const data = salida(organizacionesSchema, await rpc('api_publico_listar_organizaciones', {}));
    res.json({ data });
  });

  router.post('/solicitudes-visita', limitador(LIMITE_CREACION), async (req, res) => {
    const datos = parseBody(crearSolicitudSchema, req.body);
    // El código se genera aquí y a la base solo llega su hash: ni la base ni los registros guardan el código.
    const codigo = generarCodigoSeguimiento();
    const creada = salida(
      solicitudCreadaSchema,
      await rpc('api_publico_crear_solicitud', {
        p_datos: { ...datos, codigo_hash: huella(codigo) },
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
    res.json({ data: { ...estado, estado_texto: ESTADO_TEXTO[estado.estado] } });
  });

  router.post('/solicitudes-visita/observacion', async (req, res) => {
    const { codigo, observacion } = parseBody(observacionSchema, req.body);
    const hash = huella(leerCodigo(codigo));
    const texto = parseBody(textoObservacion, observacion);
    const estado = salida(
      estadoPublicoSchema,
      await rpc('api_publico_registrar_observacion', { p_codigo_hash: hash, p_observacion: texto }),
    );
    log(res, 'solicitud_visita.observacion');
    res.json({ data: { ...estado, estado_texto: ESTADO_TEXTO[estado.estado] } });
  });

  // Cualquier otra ruta o método bajo /publico es 404: nunca cae en la validación de sesión de las rutas protegidas.
  router.use((_req, _res, next) => next(noEncontrada()));

  return router;
}
