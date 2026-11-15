/* Validación y publicación de marca · BO-15 a BO-18. © 2026 Equipo CuidaRed – INTEC. */
import { randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { SaxesParser } from 'saxes';
import { AppError } from '../../lib/errors.js';

const elementos = new Set([
  'svg',
  'g',
  'path',
  'rect',
  'circle',
  'ellipse',
  'line',
  'polygon',
  'polyline',
  'defs',
  'linearGradient',
  'radialGradient',
  'stop',
  'clipPath',
  'mask',
  'title',
  'desc',
]);
const atributos = new Set(
  'xmlns viewBox width height x y x1 x2 y1 y2 cx cy r rx ry d points transform opacity fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-linejoin stroke-linecap stroke-dasharray stroke-dashoffset stroke-miterlimit clip-rule clip-path gradientTransform gradientUnits offset stop-color stop-opacity id fx fy mask maskUnits maskContentUnits preserveAspectRatio'.split(
    ' ',
  ),
);
const invalidLogo = () =>
  new AppError(
    422,
    'INVALID_LOGO',
    'Usa un PNG transparente o un SVG vectorial, de hasta 2 MB y con la proporción de la variante.',
  );

function validateSvg(bytes) {
  const parser = new SaxesParser();
  let depth = 0;
  parser.on('doctype', () => {
    throw invalidLogo();
  });
  parser.on('processinginstruction', () => {
    throw invalidLogo();
  });
  parser.on('error', () => {
    throw invalidLogo();
  });
  parser.on('opentag', ({ name, attributes }) => {
    if ((!depth && name !== 'svg') || ++depth > 48 || !elementos.has(name)) throw invalidLogo();
    for (const [key, value] of Object.entries(attributes)) {
      if (!atributos.has(key) || (key === 'xmlns' && value !== 'http://www.w3.org/2000/svg'))
        throw invalidLogo();
      if (/url\s*\(/i.test(value) && !/^url\(#[a-zA-Z0-9_-]+\)$/.test(value)) throw invalidLogo();
    }
  });
  parser.on('closetag', () => {
    depth--;
  });
  parser.write(new TextDecoder('utf-8', { fatal: true }).decode(bytes)).close();
}

export async function prepareLogo(buffer, type, variant) {
  if (
    !Buffer.isBuffer(buffer) ||
    !buffer.length ||
    buffer.length > 2097152 ||
    !['image/png', 'image/svg+xml'].includes(type)
  )
    throw invalidLogo();
  try {
    if (type === 'image/svg+xml') validateSvg(buffer);
    const image = sharp(buffer, { limitInputPixels: 2500000, failOn: 'error' });
    const { width, height, format, hasAlpha, pages } = await image.metadata();
    const ratio = width / height;
    if (
      format !== (type === 'image/png' ? 'png' : 'svg') ||
      !hasAlpha ||
      pages > 1 ||
      width < 32 ||
      height < 32 ||
      ratio < (variant === 'isotipo' ? 0.5 : 1.5) ||
      ratio > (variant === 'isotipo' ? 2 : 8)
    )
      throw invalidLogo();
    const { channels } = await image.clone().stats();
    if (channels.at(-1).min >= 255 || channels.at(-1).max === 0) throw invalidLogo();
    const data = await image
      .resize({ width: 1400, height: 1400, fit: 'inside', withoutEnlargement: true })
      .png()
      .toBuffer();
    if (data.length > 2097152) throw invalidLogo();
    return { path: variant + '/' + randomUUID() + '.png', data };
  } catch {
    throw invalidLogo();
  }
}

export function brandUrl(env, route, version) {
  return route
    ? new URL(
        '/storage/v1/object/public/cuidared-marca/' + route + '?v=' + version,
        env.SUPABASE_URL,
      ).href
    : null;
}
