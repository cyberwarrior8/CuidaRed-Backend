# Fase 8 en Stripe Sandbox

CuidaRed usa Stripe Checkout alojado para cobrar la suscripción de prueba de una cuenta. El backend controla la oferta, el titular y la vigencia. El entorno utiliza solo claves de prueba. Todos los Price, Checkout, suscripciones, facturas y eventos que procesa deben pertenecer al sandbox.

## Configuración

Sigue el [README de pruebas de Stripe](stripe/README.md) para crear los productos, configurar el entorno, reenviar eventos y probar los pagos. Antes de usar otro entorno compartido, revisa cuáles migraciones de la fase 8 están aplicadas y obtén aprobación para las pendientes. [Registro de cambios](CAMBIOS-SCHEMA-SUSCRIPCIONES.md)

## Catálogo

El usuario delegó los importes iniciales de Familia. Se eligieron precios familiares en USD con una anualidad equivalente a diez meses. Backoffice publica las tarifas generales sin cambiar el importe de los contratos vigentes. Para Operación Base, el superadministrador publica ambos importes sin valores iniciales predeterminados. Gestión Comunitaria Avanzada lleva un importe y cuatro cupos pactados por cuenta y ciclo.

| Código de producto | Plan | Mensual | Anual |
| --- | --- | --- | --- |
| `basico_familiar` | Básico Familiar | USD 9 | USD 90 |
| `cuidado_integral` | Cuidado Integral | USD 19 | USD 190 |
| `operacion_base` | Operación Base | Publicación en Backoffice | Publicación en Backoffice |
| `gestion_comunitaria_avanzada` | Gestión Comunitaria Avanzada | Cotización | Cotización |

Para importar tarifas familiares previamente creadas, las claves son `basico_familiar_mensual`, `basico_familiar_anual`, `cuidado_integral_mensual` y `cuidado_integral_anual`. `node scripts/stripe-catalogo-sandbox.js` coteja los Price de `STRIPE_SANDBOX_CATALOG_JSON` con Stripe. El argumento `--aplicar` escribe en Supabase y requiere aprobación. Las credenciales y los JSON de configuración se conservan en el entorno del backend.

## Prueba local

Usa el [recorrido de pago y comprobaciones](stripe/README.md#5-pagar-y-verificar-el-resultado). Para una prueba más amplia, incluye una renovación fallida, una transferencia de titularidad y la consulta desde un usuario gestor que no sea titular. La transferencia debe programar el fin de la renovación anterior y conservar el período ya pagado.

## Destino de eventos

Configura el destino de eventos para `invoice.paid`, `invoice.payment_failed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.pending_update_applied`, `customer.subscription.pending_update_expired`, `subscription_schedule.released`, `checkout.session.expired`, `charge.refunded`, `refund.created` y `refund.updated`. Los eventos generados por la CLI sin una contratación de CuidaRed carecen de la referencia al intento y no cambian la cuenta. [Eventos de Stripe Billing](https://docs.stripe.com/billing/subscriptions/webhooks)

Stripe Tax queda fuera de los cobros simulados del MVP. Su configuración corresponde a una eventual habilitación comercial.
