# Desarrollo del backend de CuidaRed en ocho fases

## Enfoque y organización

La planificación seguirá los procesos **ID01–ID08** de [Prototipos](</C:/Users/edgar/Documents/Proyecto Final/Docs/Prototipos/IDS355-2026-CuidaRed-ProyectoFinal.docx>), conservando su orden y sus objetivos de usuario.

Se aplicarán las reglas V2, el SRS compatible y las once decisiones de [CONTEXTO-BACKEND.md](</C:/Users/edgar/Documents/Proyecto Final/repos/CuidaRed-Backend/CONTEXTO-BACKEND.md>). Cada fase entregará **API, pruebas, documentación e integración mínima con el frontend**, sin rediseñar las pantallas.

Los módulos adicionales de V2 se distribuirán así:

- **Organización:** perfiles de cuidadores.
- **Envejecientes:** asignaciones, permisos familiares, riesgos e indicaciones médicas.
- **Visitas y Seguimiento:** agenda, tareas y evidencias.

La infraestructura, seguridad y pruebas se incorporarán progresivamente dentro de estas ocho fases; no habrá una fase adicional.

## Fase 1 — Perfil y Acceso

**Objetivos:** registrar cuenta de usuario, iniciar sesión, recuperar contraseña y actualizar perfil.

**Trabajo previsto:**

- Preparar Node.js/Express, configuración de entorno, estructura modular, manejo de errores y herramientas de desarrollo y pruebas.
- Integrar Supabase Auth para registro/activación, autenticación, recuperación, cierre de sesión y perfil personal.
- Establecer validación de identidad, protección de rutas y base de auditoría.
- Definir los primeros contratos de API y sustituir la autenticación simulada del frontend. La creación de la cuenta Familia/Organización corresponde a la fase 2.

**Entregables:** aplicación backend ejecutable, acceso conectado, documentación de instalación y pruebas de autenticación.

**Criterios de cierre:** funcionan los flujos de acceso; se rechazan sesiones inválidas y usuarios desactivados; el frontend deja de gestionar contraseñas mediante su simulador.

**Preparación necesaria:** resolver lenguaje, estructura, herramientas y políticas de sesión, invitación y recuperación pendientes.

**Trazabilidad:** ID01; RF-09 y RF-21.

## Fase 2 — Organización

**Objetivos:** registrar organización, gestionar miembros y configurar organización.

**Trabajo previsto:**

- Implementar Cuenta para **Familia y Organización**, titularidad, membresías y contexto de cuenta activa.
- Aplicar los roles permitidos por tipo de cuenta y conservar historial de membresías.
- Gestionar perfiles de Cuidador asociados a una identidad existente.
- Implementar parámetros y configuración por cuenta.
- Incorporar la prueba única de siete días y la comprobación de acceso operativo por vigencia. La integración con Stripe llegará en la fase 8.

**Entregables:** administración de cuentas, miembros, cuidadores y configuración conectada al frontend.

**Criterios de cierre:** una persona puede participar en varias cuentas sin mezclar permisos; las bajas de membresía revocan acceso; una cuenta vencida conserva únicamente acceso a cuenta/suscripción según sus permisos.

**Preparación necesaria:** completar la matriz de permisos, catálogos de cuenta/cuidado y procedimiento de alta y titularidad.

**Dependencia:** fase 1.  
**Trazabilidad:** ID02; RF-09, RF-11, RF-12 y RF-19.

## Fase 3 — Envejecientes

**Objetivos:** registrar perfil, clasificar riesgo, actualizar datos y consultar historial.

**Trabajo previsto:**

- Implementar perfiles con cédula obligatoria y única en toda la plataforma.
- Registrar consentimiento y contactos de emergencia, garantizando exactamente un contacto principal.
- Gestionar asignaciones de cuidadores, vínculos familiares y permisos explícitos.
- Implementar evaluaciones históricas, cuestionario de 100 puntos, máximo de factores vigentes y «Sin evaluación vigente» cuando corresponda.
- Gestionar indicaciones médicas con acceso restringido.
- Preparar la consulta del historial, que se completará con visitas, necesidades y alertas en sus respectivas fases.

**Entregables:** expediente del adulto conectado, evaluaciones, contactos, asignaciones e indicaciones.

**Criterios de cierre:** alta consistente; rechazo de cédulas duplicadas incluso entre cuentas; cálculo de riesgo correcto; familiar sin permiso y cuidador no asignado no acceden al caso.

**Preparación necesaria:** resolver validaciones restantes, consentimiento, bajas, conservación y permisos de información sensible.

**Dependencia:** fase 2.  
**Trazabilidad:** ID03; RF-01, RF-13, RF-14, RF-15 y RF-17.

## Fase 4 — Visitas y Seguimiento

**Objetivos:** programar visita, registrar su realización, adjuntar evidencia y consultar historial.

**Trabajo previsto:**

- Implementar programación y autorización previas: Coordinador en Familia; Administrador o Coordinador en Organización.
- Registrar visitantes y observaciones por adulto, preservando el historial.
- Incorporar agenda, asignación y ejecución de tareas de cuidado.
- Implementar evidencias privadas y su validación; exigir evidencia validada antes de completar las tareas que la requieren.
- Implementar la sincronización de visitas con marcas UTC, resolución LWW, reintentos y revalidación de permisos.
- Conectar los servicios de visitas, agenda y evidencias del frontend.

**Entregables:** seguimiento operativo con visitas, tareas, archivos e historial, incluyendo sincronización de visitas.

**Criterios de cierre:** solo las visitas realizadas cuentan como contacto; no se ejecutan visitas sin autorización; no se completan tareas con evidencia pendiente; los reintentos no duplican visitas.

**Preparación necesaria:** cerrar aceptación/cancelación de visitas, recurrencia, política de archivos y contrato de sincronización.

**Dependencia:** fase 3.  
**Trazabilidad:** ID04; RF-02, RF-10 y RF-16.

## Fase 5 — Necesidades

**Objetivos:** registrar necesidad, priorizarla y consultar necesidades activas.

**Trabajo previsto:**

- Separar catálogo de necesidades y ocurrencias concretas por adulto.
- Implementar prioridad, responsable, cantidad/unidad e indicación relacionada.
- Gestionar estados, resolución e historial, conservando nuevas ocurrencias del mismo tipo.
- Extender el mecanismo de sincronización a necesidades.
- Adaptar el frontend a los permisos confirmados: el Voluntario no registra ni modifica necesidades.

**Entregables:** necesidades conectadas, historial de atención y sincronización.

**Criterios de cierre:** se conservan recurrencias e historial; los permisos se aplican en servidor; los pendientes offline se sincronizan sin duplicaciones ni pérdida silenciosa.

**Preparación necesaria:** acordar catálogos, validaciones y transiciones de estado.

**Dependencias:** fases 3 y 4.  
**Trazabilidad:** ID05; RF-03 y RF-10.

## Fase 6 — Alertas

**Objetivos:** generar alertas, consultarlas, notificar casos prioritarios y resolverlas.

**Trabajo previsto:**

- Implementar alertas por riesgo alto y medicamentos pendientes, manteniendo **una alerta por fuente**.
- Agrupar visualmente las alertas del mismo adulto como un caso prioritario.
- Evaluar periódicamente ausencia de visitas: más de quince días calendario, con umbral configurable.
- Incorporar notificaciones, lectura y gestión autorizada de alertas.
- Registrar acciones y resolución; comprobar también los datos existentes al habilitar el motor.

**Entregables:** motor de alertas, evaluación periódica, notificaciones y bandeja conectada.

**Criterios de cierre:** fuentes distintas conservan alertas independientes; un reintento no duplica una causa; solo visitas realizadas reinician el seguimiento; las notificaciones no revelan casos sin autorización.

**Preparación necesaria:** precisar identificación de fuentes, cierre/reapertura, destinatarios, periodicidad y zona horaria.

**Dependencias:** fases 3, 4 y 5.  
**Trazabilidad:** ID06; RF-04, RF-05 y RF-18.

## Fase 7 — Reportes

**Objetivos:** consultar estadísticas, visualizar dashboard, filtrar datos y descargar reportes.

**Trabajo previsto:**

- Implementar resumen de casos y estadísticas de adultos, visitas, necesidades y casos prioritarios.
- Acordar y aplicar filtros y definiciones de métricas.
- Diferenciar cantidad de alertas y cantidad de adultos prioritarios.
- Incorporar exportaciones y el informe de seguimiento médico previsto por V2 para roles autorizados.
- Sustituir las agregaciones locales del frontend por consultas al backend.

**Entregables:** dashboard, resumen, reportes y descargas con datos persistidos.

**Criterios de cierre:** totales conciliados con los registros fuente; filtros consistentes; resultados vacíos válidos; ninguna exportación expone otra cuenta o información fuera del permiso.

**Preparación necesaria:** definir formatos de descarga, métricas y contenido autorizado del informe médico.

**Dependencia:** fases 3–6.  
**Trazabilidad:** ID07; RF-07 y RF-08.

## Fase 8 — Suscripción y Pagos

**Objetivos:** seleccionar plan, gestionar suscripción, procesar pago y consultar historial.

**Trabajo previsto:**

- Implementar catálogo comercial compatible con Familia/Organización y límites del plan.
- Integrar **Stripe exclusivamente en sandbox**.
- Confirmar pagos y cambios de suscripción mediante eventos autenticados del proveedor, con control de duplicados y reintentos.
- Conectar el resultado con la vigencia y el control de acceso incorporados en la fase 2.
- Implementar historial de pagos y adaptar las pantallas comerciales del frontend.

**Entregables:** recorrido completo de contratación de prueba, pago sandbox, actualización de acceso e historial.

**Criterios de cierre:** solo paga el titular; se rechazan planes incompatibles; un pago fallido no activa acceso; la redirección de éxito no confirma por sí sola un pago; no se realizan pagos reales.

**Preparación necesaria:** acordar precios, moneda, flujo de Stripe, vigencias y reglas de renovación/cancelación.

**Dependencia:** fase 2; cierre integral después de las fases anteriores.  
**Trazabilidad:** ID08; RF-20.

## Entregables y validación comunes

Cada fase deberá cerrar con:

- Contratos de API documentados y trazabilidad a los requisitos y objetivos indicados.
- Pruebas de negocio, API, autorización e integración del flujo correspondiente en el frontend.
- Auditoría, errores controlados y controles de acceso en API, base de datos y archivos según corresponda.
- Registro de cambios importantes en `CAMBIOS-ACTUALES.md`.
- Revisión de los cambios de base de datos propuestos y **aprobación previa antes de aplicarlos**.

RF-06, RF-09 y RF-21 serán transversales: formularios compatibles con captura móvil, autorización y auditoría no se posponen al final. Las mediciones de carga y recuperación se prepararán desde la base técnica y se completarán sobre los flujos integrados.

Las decisiones todavía abiertas se resolverán al preparar la fase afectada, antes de implementar ese comportamiento. Esta hoja de ruta organiza capacidades y entregables; los contratos detallados, cambios de esquema y casos límite se concretarán en esos diseños de fase.

Se respetará [AGENTS.md](</C:/Users/edgar/Documents/Proyecto Final/repos/CuidaRed-Backend/AGENTS.md>): preguntar ante dudas, seguir la seguridad documentada, no modificar la base de datos ni realizar commits sin aprobación y nunca hacer commit a `master`.
