# Web Push para avisos de CuidaRed

RF-18. Los avisos internos de Alertas son la fuente del contador, de la fecha de lectura y de las entregas Web Push a navegadores registrados.

## Contrato

Rutas personales bajo `/api/v1`. Se requieren sesión vigente y usuario activo. La identidad se toma de Supabase Auth.

| Método y ruta | Entrada | Resultado |
| --- | --- | --- |
| GET `/notificaciones-push/configuracion` | — | `{data:{habilitado,clave_publica}}`. La clave pública es nula mientras la función está apagada. |
| POST `/notificaciones-push/suscripciones` | `{endpoint,keys:{p256dh,auth}}` | 204. La misma suscripción y el mismo titular pueden reintentar el registro. |
| POST `/notificaciones-push/suscripciones/estado` | `{endpoint}` | `{data:{activa}}` para ese navegador y la identidad autenticada. |
| POST `/notificaciones-push/suscripciones/revocar` | `{endpoint}` | 204. Elimina el registro propio si existe. |

La URL de suscripción y sus claves se tratan como datos privados. El backend comprueba que la URL sea HTTPS y corresponda a los servicios admitidos en esta entrega (FCM, Mozilla y Apple). Expone solo la clave pública VAPID. Una suscripción de otra identidad queda fuera de la consulta y la revocación. Un intento de cambiar su propietario responde 409.

Con la función apagada, la API rechaza registros nuevos. La consulta de estado y la revocación siguen disponibles para retirar un dispositivo propio.

## Activación y envío

El control de la bandeja solicita permiso por acción de la persona. El *service worker* recibe la referencia de la cuenta y el UUID opaco de aviso. Genera un texto genérico y abre la bandeja autenticada al tocarlo. El UUID permite al navegador reemplazar una copia repetida del mismo aviso. La fecha de lectura se registra al marcarlo en la aplicación.

Supabase crea una entrega por dispositivo al insertar un aviso interno nuevo. El emisor comprueba la membresía y el alcance vigentes antes de reservarla. Los fallos transitorios admiten hasta seis intentos con espera creciente, y la reserva vencida permite recuperar un envío interrumpido. Los servicios pueden conservar avisos en tránsito por el tiempo restante de una ventana de 24 horas. Si el navegador declara caducado un dispositivo, se retira su registro. El UUID también identifica el tema de la entrega ante el servicio Push.

El vencimiento por inactividad conserva la suscripción. El cierre manual la revoca para el navegador actual. Al entrar con otra identidad en un navegador compartido, CuidaRed verifica la suscripción y la desactiva en el navegador si pertenece a la sesión anterior.

Al tocar un aviso con todas las pestañas cerradas, el navegador recupera la sesión mediante la [cookie de acceso](../FASE-1-PERFIL-Y-ACCESO.md#recuperación-en-el-mismo-navegador). Si el servidor indica que la sesión venció, CuidaRed solicita iniciar sesión y conserva el destino de la notificación.

## Puesta en marcha

1. Mantén `WEB_PUSH_ENABLED=false` mientras preparas la configuración. Genera una pareja VAPID por entorno y conserva la clave privada en el entorno protegido del emisor. Usa `WEB_PUSH_PUBLIC_KEY` para la clave pública.
2. Configura `WEB_PUSH_PRIVATE_KEY`, `WEB_PUSH_VAPID_SUBJECT` con un contacto técnico y `SUPABASE_SECRET_KEY` en el entorno del emisor. Prepara la PWA con HTTPS y habilita `WEB_PUSH_ENABLED=true` en la API y en el emisor.
3. Inicia un proceso persistente con `npm run web-push:worker`. Activa avisos desde un dispositivo de prueba y genera una alerta nueva. Comprueba recepción con la PWA cerrada y apertura de la bandeja autenticada.

Las pruebas del registro y de la cola se ejecutan en una base desechable con `npm run validar:sql -- --solo=web-push`. El contrato, las migraciones y la validación remota se registran en [CUIDARED-010](../CAMBIOS-SCHEMA-CUIDARED.md#cuidared-010--suscripciones-web-push).

## Prueba en la misma computadora

El contacto de CuidaRed para la prueba local es `mailto:cuidared.piloto@gmail.com`. Configura las claves y el contacto en el `.env` privado del backend. Arranca la API con `npm run start` y el emisor en otra terminal con `npm run web-push:worker`.

En el frontend ejecuta `npm run dev:web-push` y abre `http://localhost:5173` en Chrome. La API puede seguir en `http://localhost:3000` durante esta prueba. Abre la campana, selecciona **Activar notificaciones** y concede el permiso del navegador. Usa una cuenta con acceso a expedientes y avisos de alerta. Genera una alerta nueva desde otra sesión para comprobar la entrega con la pestaña suscrita cerrada.
