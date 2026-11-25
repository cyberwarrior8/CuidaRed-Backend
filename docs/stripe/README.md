# Probar los pagos de CuidaRed con Stripe Sandbox

Esta guía cubre el recorrido completo desde la publicación del precio hasta la confirmación del pago en CuidaRed. Usa un sandbox de Stripe, cuentas de prueba y un proyecto Supabase autorizado con las migraciones de la fase 8. [Estado de las migraciones](../CAMBIOS-SCHEMA-CUIDARED.md)

## 1. Preparar Stripe y los usuarios de prueba

1. Crea o selecciona un sandbox en Stripe. En su catálogo crea cuatro **productos**, uno por plan, y copia sus identificadores `prod_…`. CuidaRed crea los precios recurrentes al publicarlos desde Backoffice.
2. Obtén una clave privada de ese sandbox. Prefiere una clave restringida de prueba `rk_test_…` con permisos para precios, clientes, Checkout, suscripciones, programación de suscripciones, facturas y vistas previas, pagos y consulta de reembolsos. Se admite también una clave `sk_test_…`. Usa el mismo sandbox para la clave, los productos y el reenvío de eventos.
3. Prepara una identidad de Backoffice con rol **Superadministrador** y MFA, un titular de Familia y otro de Organización. Usa cuentas desechables. Una cuenta vencida permite comprobar que el pago recupera el acceso a los módulos.

[Sandboxes de Stripe](https://docs.stripe.com/sandboxes) · [Claves de API](https://docs.stripe.com/keys) · [Acceso al Backoffice](https://github.com/selinefeliz/Cuidared-Backoffice#aprovisionar-el-acceso)

## 2. Reenviar eventos al backend local

Instala la CLI de Stripe. Deja este proceso en una terminal separada mientras pruebas. En la primera conexión ejecuta `stripe login`. Si tienes varios perfiles, selecciona el del sandbox con `stripe switch` y comprueba el contexto antes de escuchar. [Instalar Stripe CLI](https://docs.stripe.com/stripe-cli/install)

```powershell
stripe whoami --format json
stripe listen --all-snapshot --forward-to http://localhost:3000/api/v1/webhooks/stripe
```

Copia el secreto `whsec_…` que muestra `stripe listen` al archivo privado `.env` del backend. Para localhost usa el secreto de la CLI. Si configuraste un destino HTTPS en el Dashboard, su secreto corresponde a ese otro destino. Si cambia el secreto al iniciar el listener, actualiza `.env` y reinicia Express. El puerto del comando debe coincidir con el que usa Express. [Reenvío de eventos con Stripe CLI](https://docs.stripe.com/stripe-cli/use-cli)

## 3. Configurar y arrancar las tres aplicaciones

Crea los archivos de entorno a partir del `.env.example` de cada repositorio cuando te falten. Conserva la configuración Supabase y de sesión existente. Completa estos valores en **CuidaRed-Backend/.env** con credenciales de prueba y los cuatro productos del paso 1.

```dotenv
NODE_ENV=development
PORT=3000
PWA_ORIGIN=http://localhost:5173
FRONTEND_ORIGINS=http://localhost:5173,http://localhost:5174
SUPABASE_URL=https://PROJECT_REF.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_REEMPLAZAR
SUPABASE_SECRET_KEY=sb_secret_REEMPLAZAR
STRIPE_SANDBOX_ENABLED=true
STRIPE_SECRET_KEY=rk_test_REEMPLAZAR
STRIPE_WEBHOOK_SECRET=whsec_REEMPLAZAR
STRIPE_SANDBOX_PRODUCTS_JSON={"basico_familiar":"prod_REEMPLAZAR1","cuidado_integral":"prod_REEMPLAZAR2","operacion_base":"prod_REEMPLAZAR3","gestion_comunitaria_avanzada":"prod_REEMPLAZAR4"}
```

En **CuidaRed-Frontend/.env.local** configura `VITE_AUTH_MODE=supabase`. Allí y en **CuidaRed-Backoffice/.env.local** configura `VITE_API_URL=http://localhost:3000`, `VITE_SUPABASE_URL` y `VITE_SUPABASE_PUBLISHABLE_KEY` para el mismo proyecto. Guarda las claves privadas y el secreto del webhook solo en el backend.

En la primera instalación ejecuta `npm ci` en cada repositorio. Abre una terminal por aplicación y ejecuta los comandos desde su carpeta.

| Aplicación | Comando | Dirección |
| --- | --- | --- |
| Backend | `npm run dev` | [Comprobar Express](http://localhost:3000/health/live) |
| CuidaRed | `npm run dev -- --host localhost --port 5173 --strictPort` | [CuidaRed local](http://localhost:5173/) |
| Backoffice | `npm run dev -- --host localhost --strictPort` | [Backoffice local](http://localhost:5174/admin/) |

Si cambias un puerto, actualiza los orígenes, la URL de la API o el reenvío según corresponda. Usa `localhost` en las tres direcciones para conservar la sesión y coincidir con los orígenes autorizados.

## 4. Publicar tarifas o cotizaciones

| Plan | Cómo queda disponible para el titular |
| --- | --- |
| Básico Familiar y Cuidado Integral | En **Backoffice → Configuración → Tarifas en Stripe Sandbox**, publica el importe de cada ciclo. Las referencias iniciales son USD 9/90 y USD 19/190, mensual/anual. |
| Operación Base | En la misma pantalla, publica la tarifa mensual y la anual de Operación Base. USD 39/390 son valores sugeridos para el piloto. Usa los importes que el equipo haya decidido para la prueba. |
| Gestión Comunitaria Avanzada | En CuidaRed, el titular solicita la cotización para el ciclo que quiere. En **Backoffice → Cuentas → [organización] → Pagos**, publica el precio en USD y los cupos de adultos mayores, equipo, cuidadores y familiares. En CuidaRed, el titular verá las condiciones de ese ciclo antes de pagar. |

El botón de compra aparece para el titular cuando el ciclo tiene una oferta disponible. La cotización de una organización solo puede contratarse desde esa cuenta.

## 5. Pagar y verificar el resultado

1. En CuidaRed, abre la cuenta como titular y entra a **Suscripción y pagos**. Elige el plan y la periodicidad, verifica el importe y abre Stripe Checkout con **Elegir plan**.
2. Para simular un pago aprobado, usa `4242 4242 4242 4242`, una fecha futura y cualquier CVC de tres dígitos. Para simular un rechazo general, usa `4000 0000 0000 0002`. Completa los demás campos con datos inventados. [Tarjetas oficiales de prueba](https://docs.stripe.com/testing#cards)
3. Tras un pago aprobado, comprueba en la terminal de Stripe que `invoice.paid` se reenvió y recibió respuesta 2xx. En CuidaRed verifica **Plan activo**, la fecha de vigencia, el acceso a los módulos y una fila de pago completado por el importe elegido. Si la conciliación sigue pendiente, usa **Consultar estado del pago**.
4. En una cuenta vencida prueba el rechazo. Verifica que los módulos permanezcan bloqueados y que el titular pueda volver al pago. Si Stripe genera una factura fallida, revisa su fila en el historial. Un rechazo de tarjeta dentro de Checkout puede producirse antes de que exista una factura que CuidaRed pueda registrar.
5. Para Avanzada, confirma los cuatro cupos en CuidaRed y en la ficha de Backoffice. Verifica que una segunda organización no pueda usar esa oferta y que una cotización nueva conserve los términos ya contratados. Si pruebas cada plan o ciclo por separado, usa cuentas distintas o sigue el flujo de cambios del plan.
6. En una suscripción activa, prueba un aumento dentro del mismo ciclo, una reducción o cambio de periodicidad al siguiente corte y la cancelación de la renovación. La interfaz debe mostrar cuándo se aplica cada cambio. Para probar la conciliación de un reembolso, emítelo desde Stripe **Sandbox** sobre un pago de esa cuenta y revisa el importe reembolsado en CuidaRed.

## Si el flujo se atasca

| Síntoma | Qué revisar |
| --- | --- |
| Backoffice no habilita **Publicar** | Comprueba que Express tiene habilitado Stripe Sandbox, la clave privada de prueba y los cuatro productos de ese sandbox. |
| La pantalla muestra una tarifa pendiente o el pago no aparece | Comprueba que el ciclo fue publicado o cotizado, que abriste la cuenta como titular y que Supabase tiene las migraciones de suscripciones. |
| Stripe procesa el pago y CuidaRed sigue en espera | Revisa que el listener siga activo y reciba `invoice.paid`. Un 400 de firma suele indicar que el `whsec_` del backend pertenece a otro destino. Comprueba el puerto y los registros de Express. |
| La oferta cambió mientras escogías el plan | Actualiza la pantalla, verifica el precio y los cupos y confirma otra vez. Si hay un pago en curso, CuidaRed presenta las condiciones de ese intento y permite retomarlo. |

Para un destino de eventos configurado manualmente, consulta la [lista de eventos de CuidaRed](../FASE-8-SANDBOX.md#destino-de-eventos). Una prueba con `stripe trigger` solo comprueba el reenvío. Para verificar vigencia, historial y cupos, inicia Checkout desde CuidaRed para que Stripe reciba la referencia al intento. Stripe Tax queda fuera de los cobros simulados del MVP.

## Pruebas automatizadas

- En el backend, `npm test -- tests/suscripciones.test.js tests/stripe-gateway.test.js tests/backoffice.test.js` ejecuta las pruebas de API y conciliación con Stripe simulado.
- En el backend, `npm run validar:sql -- --solo=suscripciones` usa una base PostgreSQL local desechable para verificar permisos, vigencia y cupos.
- En el frontend, `npm run test:access -- suscripcion.spec.ts` prueba el recorrido en móvil y escritorio con servicios simulados. El Backoffice debe liberar el puerto 5174 que utiliza esa configuración de pruebas.
