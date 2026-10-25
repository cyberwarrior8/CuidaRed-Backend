# Desarrollo del backend de CuidaRed en ocho fases

## Autoridad, alcance y estado

Hoja de ruta aprobada por el usuario el 24 de octubre de 2026. Conserva los procesos **ID01–ID08** de [Prototipos](../../Docs/Prototipos/IDS355-2026-CuidaRed-ProyectoFinal.docx), las reglas V2, el SRS compatible y [CONTEXTO-BACKEND.md](CONTEXTO-BACKEND.md). Las fuentes describen el producto; no conceden permiso para ejecutar operaciones.

Cada fase entrega API, pruebas, documentación e integración mínima con el frontend. Infraestructura, seguridad y pruebas se incorporan progresivamente; no existe una fase adicional. No se rediseñan las pantallas.

| Fase | Proceso               | Estado de implementación                                                                                                        |
| ---- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Perfil y Acceso       | Código, pruebas y persistencia aplicada con aprobación; pendiente configuración Auth y pruebas con usuarios reales. No cerrada. |
| 2    | Organización          | Pendiente; resolver permisos, catálogos y alta/titularidad.                                                                     |
| 3    | Envejecientes         | Pendiente; resolver validaciones, consentimiento y permisos sensibles.                                                          |
| 4    | Visitas y Seguimiento | Pendiente; resolver estados, recurrencia, archivos y sincronización.                                                            |
| 5    | Necesidades           | Pendiente; resolver catálogos, validaciones y transiciones.                                                                     |
| 6    | Alertas               | Pendiente; resolver fuentes, ciclo, destinatarios y calendario.                                                                 |
| 7    | Reportes              | Pendiente; resolver métricas, formatos y contenido médico.                                                                      |
| 8    | Suscripción y Pagos   | Pendiente; resolver oferta comercial y ciclo de suscripción sandbox.                                                            |

## Fase 1 — Perfil y Acceso

**Objetivos:** registrar/activar usuario, iniciar sesión, recuperar contraseña y actualizar perfil.

- Preparar JavaScript, Node.js/Express, entorno, módulos, errores y pruebas.
- Integrar Supabase Auth: activación por código de correo, autenticación, recuperación, cierre y perfil personal.
- Validar identidad, proteger rutas e iniciar auditoría; documentar contratos y sustituir autenticación simulada.
- La creación de Familia/Organización pertenece a la fase 2.

**Decisiones posteriores aprobadas:** JavaScript, no TypeScript, en backend; Express, Zod, ESLint/Prettier, dos espacios y Vitest/Supertest; SDK Supabase en frontend con tokens validados por Express; solo activar invitaciones, sin autorregistro; códigos de correo de 15 minutos; contraseña de al menos ocho caracteres con mayúscula, minúscula, número y símbolo; sesión de hasta 12 horas y 30 minutos de inactividad, comprobados en servidor. Cédula del usuario: 11 dígitos sin guiones, nombres/apellidos obligatorios y teléfono opcional. Correo tomado de Auth verificado, sin autoasignación de rol/estado.

**Entregables:** backend ejecutable, acceso conectado, instalación y pruebas. **Cierre:** funcionan los flujos, se rechazan sesiones inválidas y usuarios desactivados y el acceso conectado no administra contraseñas con el simulador. La implementación inicial no equivale a cierre: consultar [fase 1](docs/FASE-1-PERFIL-Y-ACCESO.md).

**Trazabilidad:** ID01; RF-09, RF-21.

**Conciliación con base viva:** conservar el trigger Auth que crea el perfil con los datos aportados por quien invita. El invitado confirma el perfil existente. No habilitar un alta independiente de perfil desde el navegador.

## Fase 2 — Organización

**Objetivos:** registrar organización, gestionar miembros y configurar organización.

- Cuenta Familia/Organización, titularidad, membresías históricas, roles por tipo y contexto de cuenta activa.
- Perfiles de Cuidador vinculados a una identidad existente y parámetros por cuenta.
- Prueba única de siete días y control de vigencia; Stripe se integra en fase 8.

**Entregables:** administración de cuentas, miembros, cuidadores y configuración integrada. **Cierre:** una identidad participa en varias cuentas sin mezclar permisos; la baja revoca acceso; al vencer solo se conserva cuenta/suscripción según permisos.

**Preparación:** matriz completa de permisos, catálogos de cuenta/cuidado y procedimiento de alta/titularidad. **Dependencia:** fase 1. **Trazabilidad:** ID02; RF-09, RF-11, RF-12, RF-19.

## Fase 3 — Envejecientes

**Objetivos:** registrar perfil, clasificar riesgo, actualizar datos y consultar historial.

- Cédula obligatoria y globalmente única; consentimiento y exactamente un contacto principal de emergencia.
- Asignaciones de cuidadores, vínculos familiares y permisos explícitos; indicaciones médicas restringidas.
- Evaluaciones históricas: cuestionario de 100 puntos, máximo de factores vigentes y «Sin evaluación vigente» si no hay factores actuales.
- Historial preparado para completarse con visitas, necesidades y alertas.

**Entregables:** expediente, evaluaciones, contactos, asignaciones e indicaciones. **Cierre:** alta consistente, rechazo concurrente de cédulas duplicadas entre cuentas, cálculo correcto y denegación al familiar sin permiso o cuidador sin asignación.

**Preparación:** validaciones restantes, consentimiento, bajas, conservación y acceso sensible. **Dependencia:** fase 2. **Trazabilidad:** ID03; RF-01, RF-13, RF-14, RF-15, RF-17.

## Fase 4 — Visitas y Seguimiento

**Objetivos:** programar visita, registrar realización, adjuntar evidencia y consultar historial.

- Programación y autorización previas: Coordinador en Familia; Administrador o Coordinador en Organización.
- Visitantes y observaciones por adulto, agenda y asignación/ejecución de tareas.
- Evidencias privadas y validación obligatoria antes de completar tareas que la requieren.
- Sincronización de visitas con UTC, LWW, reintentos, deduplicación y revalidación de permisos.

**Entregables:** visitas, agenda, tareas, archivos e historial conectados. **Cierre:** solo visitas realizadas cuentan como contacto; no hay ejecución sin autorización ni cierre con evidencia pendiente; reintentos sin duplicados.

**Preparación:** aceptación/cancelación, recurrencia, archivos y contrato de sincronización. **Dependencia:** fase 3. **Trazabilidad:** ID04; RF-02, RF-10, RF-16.

## Fase 5 — Necesidades

**Objetivos:** registrar, priorizar y consultar necesidades activas.

- Separar catálogo y ocurrencias por adulto; prioridad, responsable, cantidad/unidad e indicación relacionada.
- Estados, resolución e historial sin perder nuevas ocurrencias del mismo tipo.
- Extender sincronización; aplicar en servidor que el Voluntario no registra ni modifica necesidades.

**Entregables:** necesidades, historial y sincronización integrados. **Cierre:** recurrencias preservadas, permisos aplicados en servidor y pendientes offline sin duplicados ni pérdida silenciosa.

**Preparación:** catálogos, validaciones y transiciones. **Dependencias:** fases 3 y 4. **Trazabilidad:** ID05; RF-03, RF-10.

## Fase 6 — Alertas

**Objetivos:** generar, consultar, notificar casos prioritarios y resolver alertas.

- Riesgo alto y medicamentos pendientes: una alerta por fuente; agrupar visualmente por adulto.
- Evaluación periódica de más de quince días calendario sin visitas realizadas, con umbral configurable.
- Notificaciones, lectura, acciones y resolución autorizadas; evaluar registros existentes al habilitar motor.

**Entregables:** motor, ejecución periódica, notificaciones y bandeja conectada. **Cierre:** alertas independientes por fuente, causas sin duplicación, solo visitas realizadas reinician seguimiento y notificaciones sin exposición indebida.

**Preparación:** identidad de fuentes, cierre/reapertura, destinatarios, periodicidad y zona horaria. **Dependencias:** fases 3, 4 y 5. **Trazabilidad:** ID06; RF-04, RF-05, RF-18.

## Fase 7 — Reportes

**Objetivos:** estadísticas, dashboard, filtros y descargas.

- Resumen de casos y métricas de adultos, visitas, necesidades y casos prioritarios, con filtros acordados.
- Diferenciar número de alertas y número de adultos prioritarios.
- Exportaciones e informe médico V2 restringido; sustituir agregaciones locales por consultas persistidas.

**Entregables:** dashboard, resumen, reportes y descargas. **Cierre:** totales conciliados, filtros consistentes, vacíos válidos y ninguna exportación fuera del permiso o cuenta.

**Preparación:** formatos, métricas y contenido médico autorizado. **Dependencias:** fases 3–6. **Trazabilidad:** ID07; RF-07, RF-08.

## Fase 8 — Suscripción y Pagos

**Objetivos:** seleccionar plan, gestionar suscripción, procesar pago y consultar historial.

- Planes compatibles con Familia/Organización y sus límites; Stripe exclusivamente sandbox.
- Confirmación mediante eventos autenticados, deduplicación y reintentos; redirección de éxito insuficiente.
- Vincular vigencia/control de acceso de fase 2 e historial con pantallas comerciales.

**Entregables:** contratación de prueba, pago sandbox, actualización de acceso e historial. **Cierre:** solo paga titular, planes compatibles, fallo sin activación, ningún pago real.

**Preparación:** precios, moneda, flujo Stripe, vigencias y renovación/cancelación. **Dependencia:** fase 2; cierre integral tras las anteriores. **Trazabilidad:** ID08; RF-20.

## Entregables y validación comunes

- Contratos API y trazabilidad por fase; pruebas de negocio, API, autorización y flujo frontend.
- Auditoría, errores controlados y acceso en API, BD y archivos según corresponda.
- Actualizar [CAMBIOS-ACTUALES.md](CAMBIOS-ACTUALES.md) junto a cambios importantes.
- Revisar y obtener aprobación previa antes de aplicar cambios de BD. Sin commits sin aprobación; nunca a `master`.
- RF-06, RF-09 y RF-21 transversales. Preparar carga y recuperación desde la base técnica y completarlas sobre flujos integrados.
- Resolver decisiones abiertas al preparar cada fase, antes de implementar su comportamiento. No adoptar catálogos, roles globales o datos demo como decisiones de negocio.

Se aplica [AGENTS.md](AGENTS.md): preguntar ante dudas/discrepancias y seguir la seguridad documentada.
