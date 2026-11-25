# Correo de visitas con un buzón existente

El backend puede enviar desde Gmail por SMTP sin comprar un dominio ni configurar Resend. El visitante recibe los mensajes en el correo obligatorio de su solicitud. La organización recibe las solicitudes nuevas en su correo de contacto, configurado en **Cuenta → Correo**; si no tiene uno, se notifican sus gestores activos con correo confirmado.

## Preparar otro entorno

Copia `.env.example` a `.env` y configura las credenciales propias del proyecto Supabase. Activa las solicitudes públicas solo después de aplicar sus migraciones en orden. Estas variables pertenecen exclusivamente al backend:

```dotenv
VISITAS_PUBLICAS_HABILITADAS=1
CODIGO_SEGUIMIENTO_SECRETO=REEMPLAZAR_CON_UN_SECRETO_ALEATORIO_ESTABLE_DE_AL_MENOS_32_CARACTERES
PWA_ORIGIN=http://localhost:5173
VISITAS_CORREO_PROVEEDOR=smtp
VISITAS_CORREO_REMITENTE=correo-del-proyecto@gmail.com
VISITAS_SMTP_HOST=smtp.gmail.com
VISITAS_SMTP_PORT=465
VISITAS_SMTP_USUARIO=correo-del-proyecto@gmail.com
VISITAS_CORREO_HABILITADO=0
```

Remitente y usuario SMTP deben ser el mismo buzón. Para abrir enlaces desde otro dispositivo utiliza el origen HTTPS público de la PWA en `PWA_ORIGIN`, y autorízalo también en `FRONTEND_ORIGINS`. No cambies el secreto de seguimiento después de emitir códigos.

## Credencial y activación

El propietario del buzón completa los [pasos de contraseña de aplicación](ACTIVAR-CORREO-PROYECTO.md). La contraseña se guarda únicamente en `VISITAS_SMTP_PASSWORD` del `.env`, nunca en Git, el frontend o el chat. El ejemplo anterior no contiene una contraseña y no envía mensajes.

Desde la carpeta del backend:

```powershell
npm ci
npm run visitas:correo
npm run visitas:correo -- --enviar-a=BUZON_DE_PRUEBA
```

El primer diagnóstico no envía correos ni consume avisos. La segunda orden requiere autorización para el destinatario elegido y envía una única prueba. Comprueba recepción y spam antes de establecer `VISITAS_CORREO_HABILITADO=1` y reiniciar el backend. La aceptación SMTP no acredita llegada a la bandeja principal.

Con la cola activa y el servidor ejecutándose, los avisos se procesan cada 30 segundos. Se conserva aceptación/rechazo con motivo, cambios de horario, recordatorios, enlace a observaciones al inicio y confirmación de realización. [Flujo por rol y migraciones](VISITAS-ORGANIZACION.md).
