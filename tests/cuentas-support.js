/* Ayudas compartidas de las pruebas de cuentas y catálogos (no es una prueba). © 2026 Equipo CuidaRed – INTEC. */
import { vi } from 'vitest';
import { createApp } from '../src/app.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';

export const usuarioId = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
export const perfil = {
  usuario_id: usuarioId,
  cedula: '00112345678',
  nombres: 'Ana',
  apellidos: 'Pérez',
  correo: 'ana@example.test',
  telefono: null,
  estado: 'activo',
};

/** Contexto crudo que devuelve api_contexto_cuenta (y cada elemento de `activas` de api_mis_cuentas). */
export function contexto(rol = 'coordinador', tipo = 'familia', extra = {}) {
  return {
    cuenta_id: 7,
    nombre: 'Familia Pérez',
    tipo,
    rol,
    membresia_id: 11,
    permisos: permisosDe(rol, tipo),
    es_titular: rol === 'coordinador' || rol === 'administrador',
    suscripcion_estado: 'prueba',
    fecha_fin_prueba: '2026-11-13',
    fecha_fin_vigencia: null,
    plan_id: null,
    acceso_operativo: true,
    funcionalidades: ['registro_visitas', 'necesidades_diarias'],
    limites: { envejecientes: 2, usuarios: 4, familiares: 2 },
    ...extra,
  };
}

/** Contexto de una cuenta cuya prueba venció: sin acceso operativo, pero sigue siendo miembro. */
export const contextoVencido = (rol, tipo) =>
  contexto(rol, tipo, {
    suscripcion_estado: 'vencida',
    acceso_operativo: false,
    funcionalidades: [],
  });

/** RPC simulada por nombre: una RPC sin manejador falla la prueba en lugar de devolver datos inventados. */
export function rpcPorNombre(manejadores) {
  return vi.fn(async (nombre, parametros) => {
    if (!manejadores[nombre]) throw new Error(`RPC inesperada: ${nombre}`);
    return manejadores[nombre](parametros);
  });
}

/** Aplicación completa con sesión válida y la RPC indicada; `now` permite simular el paso del tiempo. */
export function crearApp({ rpc, now } = {}) {
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(perfil),
    rpc,
  };
  const audit = vi.fn();
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: usuarioId, email: perfil.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const app = createApp({
    env: { origins: ['http://localhost:5173'] },
    gateway,
    audit,
    ...(now ? { now } : {}),
  });
  return { app, audit, gateway, repository, rpc };
}

export const conSesion = (peticion) => peticion.auth('token', { type: 'bearer' });

/** Manejadores de una cuenta 7 donde el usuario tiene el rol indicado, más los que se añadan. */
export function cuentaCon(rol, tipo, manejadores = {}, extra = {}) {
  return rpcPorNombre({
    api_contexto_cuenta: () => contexto(rol, tipo, extra),
    ...manejadores,
  });
}
