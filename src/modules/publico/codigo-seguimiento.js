/* Código de seguimiento de solicitudes de visita externas · V2 §Visita. © 2026 Equipo CuidaRed – INTEC. */
import { createHash, createHmac, randomInt } from 'node:crypto';

// Sin 0/O/1/I para que se lea y se dicte sin confusión: 24 letras + 8 dígitos = 32 símbolos (5 bits cada uno).
export const ALFABETO_CODIGO = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const PATRON_CODIGO = /^VIS-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/;

/** "VIS-XXXX-XXXX" con 8 símbolos aleatorios criptográficos (40 bits). Se devuelve al visitante una única vez. */
export function generarCodigoSeguimiento() {
  let simbolos = '';
  for (let i = 0; i < 8; i += 1) simbolos += ALFABETO_CODIGO[randomInt(ALFABETO_CODIGO.length)];
  return `VIS-${simbolos.slice(0, 4)}-${simbolos.slice(4)}`;
}

/** El visitante puede escribirlo con espacios o en minúsculas. */
export const normalizarCodigo = (codigo) => codigo.trim().toUpperCase().replace(/\s+/g, '');

/**
 * Huella del código normalizado: lo único que se guarda. Con CODIGO_SEGUIMIENTO_SECRETO (obligatorio en producción)
 * es HMAC-SHA256: aunque se filtrara la tabla, los 40 bits del código no se pueden probar por fuerza bruta sin el
 * secreto del servidor. Sin secreto (desarrollo y pruebas) es SHA-256.
 */
export const hashCodigo = (codigo, secreto) =>
  secreto
    ? createHmac('sha256', secreto).update(normalizarCodigo(codigo)).digest('hex')
    : createHash('sha256').update(normalizarCodigo(codigo)).digest('hex');
