/* Matriz de permisos por rol y tipo de cuenta · RF-09, Reglas de Negocio V2. © 2026 Equipo CuidaRed – INTEC. */

/*
 * Fuente única de la matriz que usan la API (comprobación temprana) y las RPC (tabla cuidared.rol_permiso,
 * generada con `npm run generar:permisos`). Coincide con `src/domain/permisos.ts` del frontend.
 * Estado: PROPUESTA basada en V2 y en la matriz ya aprobada del frontend (D04 en CONTEXTO-BACKEND.md §15.2).
 *
 * Roles (rol.codigo): administrador, coordinador, cuidador, familiar, voluntario.
 * Tipos de cuenta: familia, organizacion. En Familia no existen Administrador ni Voluntario y el Coordinador
 * gestiona accesos, autoriza familiares y administra la cuenta.
 */

export const ROLES = ['administrador', 'coordinador', 'cuidador', 'familiar', 'voluntario'];
export const TIPOS_CUENTA = ['familia', 'organizacion'];

export const ROLES_POR_TIPO = {
  familia: ['coordinador', 'cuidador', 'familiar'],
  organizacion: ['administrador', 'coordinador', 'cuidador', 'familiar', 'voluntario'],
};

/** Rol con el que el titular abre una cuenta nueva (autorregistro). */
export const ROL_TITULAR = { familia: 'coordinador', organizacion: 'administrador' };

export const ACCIONES = [
  'adultos:ver',
  'adultos:crear',
  'adultos:editar',
  'adultos:desactivar',
  'adultos:asignar',
  'adultos:evaluar',
  'adultos:anonimizar',
  'adultos:ver-sensible',
  'visitas:ver',
  'visitas:registrar',
  'visitas:programar',
  'visitas:autorizar',
  'necesidades:ver',
  'necesidades:registrar',
  'necesidades:actualizar',
  'alertas:ver',
  'alertas:gestionar',
  'alertas:cerrar',
  'resumen:ver',
  'reportes:ver',
  'informe:exportar',
  'usuarios:gestionar',
  'familiares:autorizar',
  'organizacion:configurar',
  'auditoria:ver',
  'sync:usar',
  'indicaciones:ver',
  'indicaciones:gestionar',
  'agenda:ver',
  'agenda:gestionar',
  'agenda:ejecutar',
  'evidencias:validar',
  'cuenta:suscripcion',
  'cuidadores:gestionar',
  'catalogos:ver',
];

export const MATRIZ = {
  administrador: [
    'adultos:ver',
    'adultos:crear',
    'adultos:editar',
    'adultos:desactivar',
    'adultos:asignar',
    'adultos:evaluar',
    'adultos:anonimizar',
    'adultos:ver-sensible',
    'visitas:ver',
    'visitas:programar',
    'visitas:autorizar',
    'necesidades:ver',
    'necesidades:registrar',
    'necesidades:actualizar',
    'alertas:ver',
    'alertas:gestionar',
    'resumen:ver',
    'reportes:ver',
    'usuarios:gestionar',
    'familiares:autorizar',
    'organizacion:configurar',
    'auditoria:ver',
    'indicaciones:ver',
    'agenda:ver',
    'agenda:gestionar',
    'evidencias:validar',
    'cuenta:suscripcion',
    'cuidadores:gestionar',
    'catalogos:ver',
  ],
  coordinador: [
    'adultos:ver',
    'adultos:crear',
    'adultos:editar',
    'adultos:desactivar',
    'adultos:asignar',
    'adultos:evaluar',
    'adultos:ver-sensible',
    'visitas:ver',
    'visitas:registrar',
    'visitas:programar',
    'visitas:autorizar',
    'necesidades:ver',
    'necesidades:registrar',
    'necesidades:actualizar',
    'alertas:ver',
    'alertas:gestionar',
    'resumen:ver',
    'reportes:ver',
    'informe:exportar',
    'sync:usar',
    'indicaciones:ver',
    'indicaciones:gestionar',
    'agenda:ver',
    'agenda:gestionar',
    'evidencias:validar',
  ],
  cuidador: [
    'adultos:ver',
    'adultos:ver-sensible',
    'visitas:ver',
    'visitas:registrar',
    'necesidades:ver',
    'necesidades:registrar',
    'necesidades:actualizar',
    'alertas:ver',
    'alertas:cerrar',
    'informe:exportar',
    'sync:usar',
    'indicaciones:ver',
    'indicaciones:gestionar',
    'agenda:ver',
    'agenda:ejecutar',
  ],
  voluntario: ['adultos:ver', 'visitas:ver', 'visitas:registrar', 'sync:usar'],
  familiar: ['adultos:ver', 'visitas:ver', 'necesidades:ver', 'indicaciones:ver'],
};

export const AJUSTES_POR_TIPO = {
  familia: {
    coordinador: [
      'usuarios:gestionar',
      'familiares:autorizar',
      'organizacion:configurar',
      'cuenta:suscripcion',
      'cuidadores:gestionar',
      'auditoria:ver',
      'catalogos:ver',
    ],
  },
  organizacion: {},
};

/** Acciones que se permiten aunque la cuenta no tenga acceso operativo (V2: solo cuenta y suscripción). */
export const ACCIONES_SIN_ACCESO_OPERATIVO = [
  'cuenta:suscripcion',
  'organizacion:configurar',
  'usuarios:gestionar',
];

export function permisosDe(rol, tipo) {
  if (!ROLES_POR_TIPO[tipo]?.includes(rol)) return [];
  return [...new Set([...(MATRIZ[rol] ?? []), ...(AJUSTES_POR_TIPO[tipo]?.[rol] ?? [])])];
}

/** Filas (rol, tipo, acción) para sembrar cuidared.rol_permiso. */
export function filasPermisos() {
  const filas = [];
  for (const tipo of TIPOS_CUENTA) {
    for (const rol of ROLES)
      for (const accion of permisosDe(rol, tipo)) filas.push({ rol, tipo, accion });
  }
  return filas;
}
