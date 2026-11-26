# Suscripciones y pagos de prueba

Trazabilidad ID08, RF-20, CU-20 y CR-162. La prueba de siete días sigue siendo un atributo de la cuenta y comienza automáticamente sin solicitar un medio de pago. Stripe Checkout procesa la contratación en un sandbox. La renovación usa el período contratado y una renovación fallida conserva únicamente la vigencia ya pagada.

## API de cuenta

Prefijo `/api/v1/cuentas/:cuentaId`. La sesión y la membresía activa son obligatorias. `GET /suscripcion` conserva su contrato de consulta general. Las rutas de fase 8 requieren `cuenta:suscripcion` y permanecen accesibles al vencer la vigencia. Solo puede efectuar acciones el titular.

| Ruta | Resultado |
| --- | --- |
| `GET /suscripcion/gestion` | Estado, acceso, vigencia exacta, titularidad, disponibilidad de Sandbox, cancelación programada y ofertas compatibles. |
| `GET /suscripcion/catalogo` | Planes activos del tipo de cuenta con límites, funcionalidades y referencias familiares en USD, incluso antes de publicar tarifas. |
| `GET /suscripcion/pagos` | Historial paginado de Stripe. Admite `page`, `limit` y `sort=fecha` o `sort=-fecha` con desempate por ID. |
| `GET /suscripcion/cotizaciones` | Estado de la cotización de Gestión Comunitaria Avanzada por ciclo, volumen registrado, importe y cupos publicados. |
| `POST /suscripcion/cotizaciones` | El titular de Organización solicita una cotización con `{"codigo":"gestion_comunitaria_avanzada_mensual"}`. Devuelve 201. |
| `POST /suscripcion/checkout` | Cuerpo con `oferta` y la `version` mostrada. La versión es obligatoria para cotizaciones y se verifica en las tarifas directas cuando el cliente la envía. Devuelve 201 y una URL HTTPS para iniciar o retomar Checkout. |
| `POST /suscripcion/cambio-plan` | Cuerpo con los mismos campos que Checkout. Devuelve 202 con `modo: inmediato\|proximo_corte` y `url: null` o una factura alojada por Stripe para completar la confirmación. |
| `POST /suscripcion/cancelacion` | Sin cuerpo. Devuelve 204 tras programar el fin de la renovación. Conserva el período ya pagado. |

Una oferta contiene `codigo`, `nombre`, `periodicidad`, `importe_centavos`, `moneda`, `limites`, `funcionalidades`, `actual`, `publicada`, `en_curso` y `version`. Los importes se expresan en centavos de USD. Cada modalidad mensual y anual usa su propio Price de Sandbox. Solo la organización solicitante puede contratar su cotización. Si se publica otra versión antes de que confirme la compra o el cambio, el servidor responde 409 `QUOTE_UPDATED`. La reanudación comprueba la versión del intento original. La prueba gratuita es la única modalidad sin pago. Al vencer, la cuenta conserva el acceso a la gestión de la cuenta y la suscripción según sus permisos. [Retiro del plan gratuito](../CAMBIOS-SCHEMA-SUSCRIPCIONES.md#cuidared-014--retiro-del-plan-gratuito-de-backoffice)

El historial incluye `pago_id`, `plan`, `periodicidad`, `importe_centavos`, `moneda`, `estado`, `fecha` e `importe_reembolsado_centavos`. Los reembolsos se gestionan en Stripe Sandbox. CuidaRed muestra su resultado conciliado en el historial.

El catálogo devuelve `codigo`, `nombre`, `limites`, `funcionalidades`, `precios_referencia` y `cotizado`. Familia y Operación Base pueden contratar en cuanto haya tarifa publicada para el ciclo. Operación Base mantiene su catálogo común de cupos y las funciones de visitas, necesidades, avisos y métricas. Gestión Comunitaria Avanzada obtiene los cupos desde la oferta por cuenta. Los cuatro cupos son `envejecientes`, `usuarios` (integrantes del equipo), `cuidadores` y `familiares`. El equipo cuenta a Administrador, Coordinador y Cuidador. El cupo de cuidadores se aplica además del de equipo. Familiares consumen su propio cupo y Voluntario no consume plazas de equipo. Un precio de referencia es informativo. Básico Familiar y la prueba de Familia comparten el cupo de cuidadores, inicialmente cinco.

`GET /gestion` expone `es_titular`, `estado`, `acceso_operativo`, `vigencia_hasta`, `sandbox`, `pagos_disponibles`, `suscripcion_stripe`, `puede_modificar`, `cancelacion_programada`, `checkout_en_curso`, `cambio_en_curso`, `cambio_programado` y `ofertas`. Los campos de Stripe, credenciales y datos de pago quedan en el servidor. Un plan incompatible o inválido se rechaza. Un intento pendiente de otra oferta o una modificación en curso devuelve 409.

## Backoffice

El rol `super_admin` con MFA puede publicar las tarifas de Familia y Operación Base en `GET/PATCH /api/admin/planes-stripe` (usar `/:codigo` para el PATCH). Las cotizaciones usan `GET/PATCH /api/admin/cuentas/:cuentaId/cotizaciones-stripe` con el mismo sufijo para el PATCH. Cada cambio recibe `importe_centavos` y `motivo`. La publicación de una cotización requiere además `limites` con los cuatro campos, cada uno entero de 1 a 100 000 o `null` para dejarlo sin límite. Backoffice envía la `version` que abrió para rechazar ediciones desactualizadas. El precio y los cupos se publican como una versión ligada al Price de Sandbox, con auditoría. Los números de uso observados se conservan por separado.

Las consultas devuelven `disponibles` y `bloqueos` para indicar si falta activar Stripe Sandbox o configurar sus productos. Backoffice muestra las acciones deshabilitadas mientras falta configuración. Los intentos de publicar en ese estado responden con `503 SANDBOX_UNAVAILABLE`.

`PATCH /api/admin/planes/:id` permite editar los límites de adultos y usuarios del equipo. Acepta también `cuidadores` como entero positivo para Básico Familiar. El límite se aplica al guardar y se muestra en la siguiente consulta de catálogo.

## Confirmación y conciliación

`POST /api/v1/webhooks/stripe` verifica la firma sobre el cuerpo original. Rechaza eventos de modo real antes de consultar al proveedor. Para facturas agrega únicamente los campos necesarios y verifica el vínculo entre Customer, suscripción de Sandbox y la cuenta. El procesamiento de un evento y la actualización de pagos y vigencia se guardan en una transacción. Las facturas y eventos duplicados conservan un único registro.

El retorno `?checkout=retorno` invita a consultar el estado. Confirmar una compra o una renovación requiere una factura respaldada por un pago válido. Las facturas fallidas se registran sin ampliar el acceso. Los aumentos dentro del mismo ciclo se aplican tras cobrar la diferencia prorrateada. Las reducciones y los cambios de periodicidad se programan al próximo corte sin crédito. Si la cuenta rebasa los límites del nuevo plan antes del corte, se conservan los registros y se bloquean nuevas altas hasta volver al límite. CuidaRed conserva el historial si la suscripción se cancela o cambia el titular. Una transferencia valida primero el destinatario y programa en Stripe el fin de la renovación anterior antes de actualizar la titularidad.

Consulta el procedimiento de pruebas y las dependencias de configuración. [Pruebas en Stripe Sandbox](../FASE-8-SANDBOX.md)
