/* Validación de suscripciones Web Push · RF-18. © 2026 Equipo CuidaRed – INTEC. */
import { ECDH } from 'node:crypto';

// Los endpoints son capacidades privadas. Solo se admiten servicios de los navegadores previstos.
const endpointPermitido =
  /^https:\/\/(?:fcm\.googleapis\.com\/(?:fcm\/send|wp)\/|updates\.push\.services\.mozilla\.com\/wpush\/v2\/|web\.push\.apple\.com\/)[A-Za-z0-9_-][A-Za-z0-9_~.:-]*$/;

export function esEndpointPush(valor) {
  return valor.length <= 4096 && valor.length > 0 && endpointPermitido.exec(valor)?.[0] === valor;
}

function decodificarBase64Url(valor, longitud) {
  if (valor.length !== Math.ceil((longitud * 8) / 6) || !/^[A-Za-z0-9_-]+$/.test(valor)) {
    return null;
  }
  const bytes = Buffer.from(valor, 'base64url');
  return bytes.length === longitud && bytes.toString('base64url') === valor ? bytes : null;
}

export function esClavePublicaPush(valor) {
  const bytes = decodificarBase64Url(valor, 65);
  if (!bytes || bytes[0] !== 4) return false;
  try {
    ECDH.convertKey(bytes, 'prime256v1');
    return true;
  } catch {
    return false;
  }
}

export function esSecretoAutenticacionPush(valor) {
  return decodificarBase64Url(valor, 16) !== null;
}
