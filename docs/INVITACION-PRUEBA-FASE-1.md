# Invitación administrativa de prueba — fase 1

El panel de invitación de Supabase inspeccionado solo admite correo. El trigger de CuidaRed exige cédula, nombres y apellidos en la creación de la identidad. Usar `scripts/invite-test-user.js`, una herramienta manual sin ruta HTTP pública, para enviar esos datos con `auth.admin.inviteUserByEmail`. No sustituirlo por inserciones SQL en `auth.users` ni asignar roles o cuentas.

La operación requiere aprobación previa para crear identidad/perfil y enviar correo. El usuario autorizó una primera invitación el 25/10/2026; el correo y los datos personales se mantienen fuera de esta guía y del código. Hasta tener respuesta exitosa de Auth y verificar el perfil no se declara enviada.

La URL se lee de `SUPABASE_URL` en el `.env` local del backend, cargado automáticamente con dotenv. El script no contiene una URL de proyecto ni tiene una URL de respaldo. Usar HTTPS sin credenciales, rutas, consultas ni fragmentos. `.env` debe permanecer ignorado por Git; `.env.example` solo contiene ejemplos. La clave administrativa se mantiene temporalmente en el proceso, como se indica abajo.

Desde PowerShell en el backend, con `.env` configurado, sustituir los ejemplos por los datos autorizados:

```powershell
$env:INVITATION_PROFILE_JSON = '{"email":"DESTINATARIO","cedula":"ONCE_DIGITOS","nombres":"NOMBRES","apellidos":"APELLIDOS"}'
node .\scripts\invite-test-user.js
```

Ese comando solo valida los datos y la URL localmente. Para ejecutar el envío se necesita una **clave secret existente del mismo proyecto configurado en `SUPABASE_URL`**. Se introduce de forma oculta; no se guarda en `.env`, frontend, documentos o historial del comando:

```powershell
$invitationSecret = Read-Host 'Clave secret de Supabase (sb_secret_)' -AsSecureString
$invitationCredential = [System.Management.Automation.PSCredential]::new('supabase', $invitationSecret)
try {
  $env:SUPABASE_ADMIN_KEY = $invitationCredential.GetNetworkCredential().Password
  node .\scripts\invite-test-user.js --send
} finally {
  Remove-Item Env:\SUPABASE_ADMIN_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:\INVITATION_PROFILE_JSON -ErrorAction SilentlyContinue
  Remove-Variable invitationSecret, invitationCredential -ErrorAction SilentlyContinue
}
```

No repetir automáticamente ante error o interrupción: comprobar primero Auth Users, el perfil asociado y los logs. Una aceptación del proveedor no demuestra entrega al buzón. No publicar la clave ni incluir contraseñas/códigos en los resultados. Tras la entrega, activar desde `http://localhost:5173/registro` con el código del correo y la contraseña elegida por el destinatario.

Referencias: [SDK administrativo](https://supabase.com/docs/reference/javascript/auth-admin-inviteuserbyemail), [gestión de claves](https://supabase.com/docs/guides/api/api-keys).

## Reenviar un código tras cambiar su longitud

La configuración nueva se usa al emitir una invitación nueva; el correo anterior no cambia. Si la identidad ya existe y sigue sin confirmar, se puede volver a invitar al mismo correo con `inviteUserByEmail` o desde **Authentication > Users > Add user > Send invitation**. En este caso el perfil ya existe: no se vuelve a ejecutar el trigger de inserción ni se necesita recrear la identidad. Usar el correo más reciente para activar la cuenta. Un usuario confirmado no admite este reenvío de invitación.

El 25/10/2026 se verificó que la primera identidad autorizada y su perfil existen y que la identidad aún no está confirmada ni ha iniciado sesión. Los logs del intento de eliminación mostraron SQLSTATE `23503`: `cuidared.usuario` referencia a `auth.users` mediante `fk_usuario_auth`, con `ON DELETE RESTRICT`. Ese es el motivo del error de eliminación, independiente de la longitud del código. No se cambió la restricción ni se borraron registros. No cambiar a `CASCADE` para resolver un reenvío: la eliminación/anonimización debe diseñarse y aprobarse por separado considerando historial, auditoría y otras referencias.

Referencia: [invitaciones y caducidad](https://supabase.com/docs/guides/auth/users#inviting-users).
