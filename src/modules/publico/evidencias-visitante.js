/* Evidencias públicas con código: fotografías privadas y normalizadas. © 2026 Equipo CuidaRed – INTEC. */
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { z } from 'zod';
import { AppError, unavailable } from '../../lib/errors.js';

export const fotoVisitanteSchema = z.strictObject({
  codigo: z.string().max(64),
  id: z.uuid(),
  nombre: z
    .string()
    .trim()
    .min(1)
    .max(100)
    .refine((v) => !/[\p{Cc}/\\]/u.test(v)),
  archivo: z.string().min(1).max(2796204),
});
const invalida = () =>
  new AppError(
    422,
    'VISITOR_PHOTO_INVALID',
    'Adjunta una fotografía JPG, PNG o WebP de hasta 2 MB.',
  );

export async function subirFotoVisitante({ hash, datos, rpc, storage }) {
  const actual = await rpc('api_publico_consultar_solicitud', { p_codigo_hash: hash });
  if (actual.evidencias?.some((e) => e.evidencia_id === datos.id)) return actual;
  if (!actual.puede_adjuntar_evidencias)
    throw new AppError(
      409,
      'REQUEST_UNAVAILABLE',
      'Las fotografías se habilitan al comenzar la visita. El máximo es de tres.',
    );
  if (!storage) throw unavailable();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(datos.archivo)) throw invalida();
  const original = Buffer.from(datos.archivo, 'base64');
  if (original.length > 2097152 || original.toString('base64') !== datos.archivo) throw invalida();
  let limpio;
  try {
    const imagen = sharp(original, {
      limitInputPixels: 24000000,
      failOn: 'error',
      animated: false,
    });
    const meta = await imagen.metadata();
    if (!['jpeg', 'png', 'webp'].includes(meta.format) || (meta.pages ?? 1) > 1) throw invalida();
    // Rotación correcta, dimensiones acotadas y eliminación de EXIF, ubicación y otros metadatos.
    limpio = await imagen
      .rotate()
      .resize(1600, 1600, { fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 82 })
      .toBuffer();
    if (limpio.length > 2097152) throw invalida();
  } catch {
    throw invalida();
  }
  const preparada = await rpc('api_publico_preparar_evidencia', {
    p_codigo_hash: hash,
    p_id: datos.id,
    p_nombre: datos.nombre.replace(/\.[^.]*$/, '').slice(0, 90) + '.jpg',
    p_bytes: limpio.length,
    p_sha: createHash('sha256').update(limpio).digest('hex'),
  });
  if (!preparada?.id || !preparada?.ruta) throw unavailable();
  if (preparada.adjunta) return rpc('api_publico_consultar_solicitud', { p_codigo_hash: hash });
  try {
    await storage.subir(preparada.ruta, limpio);
    return await rpc('api_publico_adjuntar_evidencia', { p_codigo_hash: hash, p_id: preparada.id });
  } catch (error) {
    // Si el registro sí se confirmó pese a un corte, nunca se borra la fotografía ya adjunta.
    const ruta = await rpc('api_publico_descartar_evidencia', {
      p_codigo_hash: hash,
      p_id: preparada.id,
    }).catch(() => null);
    if (ruta) await storage.borrar(ruta).catch(() => {});
    throw error;
  }
}
