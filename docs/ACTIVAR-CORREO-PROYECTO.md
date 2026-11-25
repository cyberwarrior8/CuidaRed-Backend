# Lo único que necesita hacer el dueño del Gmail

El remitente y el buzón administrativo ya están configurados. El visitante recibirá los avisos en el correo que escriba en el formulario. No hay que configurar Resend, dominio, DNS ni Supabase.

1. Inicia sesión en **el Gmail del proyecto** y activa la [verificación en dos pasos](https://myaccount.google.com/security) si todavía no está activa.
2. Abre [Contraseñas de aplicaciones](https://myaccount.google.com/apppasswords). Crea una llamada **CuidaRed**.
3. En `CuidaRed-Backend/.env`, pega la contraseña generada en esta única variable, sin los espacios de presentación:

   ```dotenv
   VISITAS_SMTP_PASSWORD=CONTRASENA_GENERADA
   ```

No uses la contraseña habitual de Gmail. No pegues la contraseña en el chat, en documentos, en el frontend ni en Git. El `.env` local está excluido de Git. No hace falta cambiar las otras variables.

Cuando esté guardada, basta con indicar **«El dueño ya configuró la contraseña»**. El responsable del proyecto podrá comprobar el envío y activar la cola; no necesita que le envíen la contraseña por el chat.

## Para el responsable del proyecto

Desde el backend:

```powershell
npm run visitas:correo
npm run visitas:correo -- --enviar-a=BUZON_DE_PRUEBA
```

Después de comprobar la recepción, establece `VISITAS_CORREO_HABILITADO=1` en el `.env` y reinicia `npm run dev`. Hasta ese momento, Visitas funciona y conserva los avisos pendientes, pero no envía correos.

El mensaje de Node **Failed running 'src/server.js'** es un resumen: el error concreto aparece antes. La configuración incompleta del correo no bloquea el arranque mientras `VISITAS_CORREO_HABILITADO=0`. Para comprobar la API, abre `http://localhost:3000/health/live`; debe responder `{"status":"ok"}`.

Documentación de Google: [contraseñas de aplicaciones](https://support.google.com/accounts/answer/185833).
