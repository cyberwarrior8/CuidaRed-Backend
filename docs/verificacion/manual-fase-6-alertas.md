# Prueba manual en navegador · Fase 6 Alertas

ID06 de Prototipos, RF-04, RF-05 y RF-18. Guion para comprobar en un navegador, rol por rol, lo que ya cubren las pruebas automáticas (`tests/alertas.test.js` en este repositorio y `tests/access/alertas.spec.ts` y `fases-5-6.spec.ts` en el frontend). Las pruebas automáticas usan servicios simulados: este guion es la comprobación contra el sistema real.

Contrato: [alertas.md](../contratos/alertas.md) y [web-push.md](../contratos/web-push.md). Permisos: `src/modules/cuentas/permisos.js`.

## 1. Reglas que se comprueban

| Regla                                                                                                                                                                                       | Fuente                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Una alerta por causa: un factor de riesgo alto vigente, una necesidad de Medicamentos pendiente, una necesidad pendiente de otra categoría con prioridad Alta, o una ventana sin visita.    | `fase-6b-alertas-motor.sql`, `fase-6c-alertas-necesidades-prioritarias.sql`                                        |
| Estados: `pendiente`, `en_proceso` (en pantalla «En atención») y `resuelta`. No hay «Atendida» ni «Emergencia».                                                                             | `alertas-schemas.js`                                                                                               |
| Coordinador y Administrador (Organización) consultan, inician la atención y resuelven. El Cuidador consulta y resuelve, pero no inicia la atención. Voluntario y Familiar no tienen acceso. | `permisos.js` y `alertas-routes.js`                                                                                |
| Reciben aviso interno solo el Coordinador (Familia u Organización) y el Administrador (solo Organización) con acceso al caso. El Cuidador no.                                               | `trg_alerta_avisar` en `fase-6b-alertas-motor.sql` y en la migración `20261115231642_fases_5_y_6_cuidared_009.sql` |
| Seguimiento familiar: más de 15 días calendario (el día 15 no genera, el 16 sí), umbral `dias_sin_visita_alerta`. Se evalúa cada noche a las 00:05 de República Dominicana.                 | `alertas.md`, `operacion-fase-6-cron.sql`                                                                          |
| Cambio de condición: la alerta se resuelve sola, con `cierre_automatico`. Los cambios de riesgo y de necesidades actúan al registrarse; la visita efectiva, en la evaluación diaria.        | `alertas.md`                                                                                                       |

## 2. Antes de empezar

### 2.1 Entorno

- Un proyecto o una base de **pruebas** con las migraciones CUIDARED-009 (`20261115231642`), CUIDARED-011 (`20261117044316`) y el cierre diario (`20261115231810`) aplicadas. Comprueba su estado en [CAMBIOS-SCHEMA-CUIDARED.md](../CAMBIOS-SCHEMA-CUIDARED.md). **No uses datos reales de personas.** Si esas migraciones no están aplicadas, detén la prueba: la API responderá 503 en las rutas de alertas.
- Backend: `npm run dev` en `http://localhost:3000`. Frontend: `npm run dev` en `http://localhost:5173`, con `VITE_AUTH_MODE=supabase` y `VITE_API_URL=http://localhost:3000` (copia `.env.example` a `.env.local`; nunca subas claves).
- Una ventana de navegador (o un perfil de Chrome) **por persona**, para tener varias sesiones a la vez. Abre las herramientas de desarrollo (pestaña Red) en las ventanas de Voluntario y Familiar.

### 2.2 Personas y cuentas de prueba

Usa correos de prueba que controles. Una misma persona puede tener un rol distinto en cada cuenta.

| Clave            | Rol                           | Cuenta               | Cómo se crea                                                                                                                    |
| ---------------- | ----------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **CF**           | Coordinador de Familia        | **F** (Familia)      | Autorregistro en `/registro` y alta de la cuenta tipo Familia. Es la persona titular.                                           |
| **CuF**          | Cuidador                      | F                    | CF lo invita desde **Miembros** con el rol Cuidador. Necesita su perfil de cuidador (Inicio → Perfiles globales de cuidadores). |
| **AO**           | Administrador de Organización | **O** (Organización) | Autorregistro y alta de la cuenta tipo Organización. Es la persona titular.                                                     |
| **CO**           | Coordinador de Organización   | O                    | AO lo invita desde **Miembros**. Opcional.                                                                                      |
| **CuO**          | Cuidador                      | O                    | AO lo invita con el rol Cuidador.                                                                                               |
| **VO**           | Voluntario                    | O                    | AO lo invita con el rol Voluntario.                                                                                             |
| **FaF**, **FaO** | Familiar                      | F y O                | CF o AO los invita con el rol Familiar y lo autoriza sobre el adulto.                                                           |

Cada persona invitada acepta la invitación desde **Mi cuenta** antes de seguir.

### 2.3 Adultos de prueba

Registra datos sintéticos desde **Adultos → Nuevo perfil** (con consentimiento).

- En **F**: `Persona F1 Prueba`. Asigna a **CuF**.
- En **O**: `Persona O1 Prueba` (asigna a **CuO**) y `Persona O2 Prueba` (sin cuidador asignado). Autoriza a **FaO** sobre O1.

### 2.4 Paso de operador para el seguimiento familiar

La prueba del apartado 6.3 necesita que el expediente lleve más de 15 días sin visita y una evaluación diaria. Hazlo **solo en una base local o desechable, o con aprobación previa documentada** (AGENTS.md: no se modifican datos remotos sin aprobación). Sustituye el identificador por el del adulto de prueba:

```sql
update cuidared.envejeciente set fecha_creacion = now() - interval '20 days'
  where envejeciente_id = '<UUID del adulto de prueba>';
select cuidared_interno.alertas_evaluar_diario();
```

Repetir la segunda sentencia no duplica alertas.

## 3. Qué debe ver cada rol

| Elemento                                               | CF  | AO  | CO  | CuF / CuO                | VO  | FaF / FaO |
| ------------------------------------------------------ | --- | --- | --- | ------------------------ | --- | --------- |
| Módulo **Alertas** (menú o **Más**)                    | Sí  | Sí  | Sí  | Sí                       | No  | No        |
| Bandejas **Casos prioritarios** y **Alertas**          | Sí  | Sí  | Sí  | Sí                       | No  | No        |
| Bandeja **Notificaciones**                             | Sí  | Sí  | Sí  | **No**                   | No  | No        |
| Campana 🔔 con contador en la barra azul               | Sí  | Sí  | Sí  | **No**                   | No  | No        |
| Filtros del listado: estado, tipo, adulto mayor        | Sí  | Sí  | Sí  | Sí (solo sus adultos)    | —   | —         |
| Botón **Iniciar atención**                             | Sí  | Sí  | Sí  | **No**                   | —   | —         |
| Botón **Resolver alerta**                              | Sí  | Sí  | Sí  | Sí                       | —   | —         |
| Enlace **Ver alertas de este adulto** en el expediente | Sí  | Sí  | Sí  | Sí                       | No  | No        |
| Activar Web Push en la bandeja Notificaciones          | Sí  | Sí  | Sí  | No (no tiene la bandeja) | No  | No        |

## 4. Coordinador de Familia (CF, cuenta F): ciclo completo

Entra como **CF** a la cuenta **F**. Anota cuántos avisos tiene la campana al empezar (**N0**).

### 4.1 Generación de las alertas

| #   | Pasos                                                                                                                                               | Esperado                                                                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Adultos → Persona F1 → Riesgo social → Registrar factor de riesgo.** Elige un factor y el nivel **Alto**. Guarda.                                 | En **Alertas → Casos prioritarios** aparece `Persona F1 Prueba` con **1 alerta abierta** de tipo **Riesgo alto**, estado **Pendiente**, prioridad Alta. |
| 2   | **Necesidades → Registrar necesidad.** Adulto F1, categoría **Medicamentos**, prioridad **Alta** o **Media**, descripción de al menos 5 caracteres. | Se suma una alerta **Medicamento pendiente** (ahora **2 alertas abiertas**). Un medicamento pendiente alerta con cualquier prioridad.                   |
| 3   | Registra otra necesidad de categoría **Alimentación** con prioridad **Alta**.                                                                       | Se suma una alerta **Necesidad prioritaria** (3 abiertas). Con prioridad Media o Baja no se crea.                                                       |
| 4   | Registra una necesidad de **Alimentación** con prioridad **Media**.                                                                                 | **No** se crea ninguna alerta nueva.                                                                                                                    |
| 5   | Abre la campana o espera hasta 30 s (o vuelve a enfocar la ventana).                                                                                | El contador pasa de **N0** a **N0 + 3**.                                                                                                                |

### 4.2 Ciclo pendiente → en atención → resuelta

| #   | Pasos                                                                                                  | Esperado                                                                                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Alertas → Alertas.** Abre **Riesgo alto**.                                                           | Detalle con adulto, prioridad, fecha, **Fuente: Factor de riesgo** y la descripción. Botones **Iniciar atención** y **Resolver alerta**.                              |
| 2   | **Iniciar atención → Confirmar inicio.**                                                               | Mensaje «Alerta en atención.». Estado **En atención**. Desaparece **Iniciar atención**; sigue **Resolver alerta**. En el listado, el filtro _En atención_ la muestra. |
| 3   | **Resolver alerta**, deja la acción en blanco (solo espacios) y confirma.                              | Mensaje «Describe la acción tomada.». No se resuelve.                                                                                                                 |
| 4   | Escribe una acción (máximo 500 caracteres) y **Confirmar resolución**.                                 | Mensaje «Alerta resuelta.». Estado **Resuelta**, con **Fecha de atención**, **Atendida por** (tu nombre) y **Acción tomada**. Ya no hay botones de gestión.           |
| 5   | Vuelve a **Casos prioritarios**.                                                                       | F1 muestra **2 alertas abiertas**. La resuelta sigue en el listado con el filtro _Resuelta_.                                                                          |
| 6   | Recarga la página y registra otra necesidad que no sea de Medicamentos con prioridad Media.            | La alerta resuelta **no vuelve a abrirse**: resolver a mano conserva su fuente y solo otra ocurrencia crea una alerta nueva.                                          |
| 7   | Repite el ciclo con **Medicamento pendiente**, resolviéndola **directamente** sin iniciar la atención. | Se resuelve: pasar por «En atención» es opcional.                                                                                                                     |

### 4.3 Filtros y paginación

| #   | Pasos                                                                                         | Esperado                                                                                                                                                             |
| --- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | En **Alertas → Alertas**, usa **Estado de la alerta**, **Tipo de alerta** y **Adulto mayor**. | El listado se acota a cada filtro y se pueden combinar. No existe estado «Cancelada». Si filtras por un adulto sin alertas, aparece «Sin alertas en este listado.».  |
| 2   | Desde **Adultos → Persona F1**, toca **Ver alertas de este adulto**.                          | Abre **Alertas** en el listado con el adulto ya elegido (`?bandeja=alertas&adulto=…`). Muestra sus alertas en cualquier estado, de la más reciente a la más antigua. |
| 3   | Si tienes más de 20 alertas, usa **Siguiente** y **Anterior**.                                | Cambia la página y, al cambiar un filtro, vuelve a la página 1.                                                                                                      |

## 5. Administrador de Organización (AO, cuenta O)

Repite en la cuenta **O** con **AO** los pasos 4.1 a 4.3 sobre `Persona O1 Prueba` y `Persona O2 Prueba`.

- [ ] AO ve las alertas de **ambos** adultos y los filtra por adulto.
- [ ] AO tiene campana y la bandeja **Notificaciones**.
- [ ] AO puede **Iniciar atención** y **Resolver alerta**.
- [ ] Opcional: entra como **CO** y comprueba lo mismo que AO. CO también recibe avisos de las alertas que AO ve.
- [ ] Una alerta que AO deja en «En atención» aparece igual para CO.

## 6. Cierre automático, avisos y contador

### 6.1 Cierre automático inmediato (cuenta F, como CF)

Con alertas abiertas de los pasos 4.1.1 a 4.1.3:

| #   | Pasos                                                                                                                  | Esperado                                                                                                                                                                         |
| --- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Necesidades → Medicamentos de F1 → Cambiar estado → Resuelta**, con un motivo de al menos 3 caracteres.              | La alerta **Medicamento pendiente** pasa a **Resuelta** sola. Su detalle dice «La alerta se cerró automáticamente al dejar de cumplirse su causa.». No muestra **Atendida por**. |
| 2   | **Necesidades →** necesidad de Alimentación con prioridad Alta **→ Editar prioridad y responsable →** prioridad Media. | La alerta **Necesidad prioritaria** se cierra sola.                                                                                                                              |
| 3   | **Riesgo social →** el factor Alto **→ Resolver factor**.                                                              | La alerta **Riesgo alto** se cierra sola.                                                                                                                                        |
| 4   | Vuelve a poner un factor Alto o registra otra necesidad Alta.                                                          | Se crea una alerta **nueva**: solo otra ocurrencia genera otra alerta.                                                                                                           |

### 6.2 Aviso y contador

| #   | Pasos                                                                                              | Esperado                                                                                                                                                                                   |
| --- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Con una alerta recién creada (4.1), toca la **campana 🔔**.                                        | Abre **Alertas → Notificaciones** (`?bandeja=avisos`). Hay un aviso **Sin leer** con el texto genérico «Hay una alerta de caso prioritario por revisar.». No muestra el nombre del adulto. |
| 2   | Toca **Ver alerta** en ese aviso.                                                                  | Abre el detalle de la alerta.                                                                                                                                                              |
| 3   | **Marcar como leída.**                                                                             | «Notificación marcada como leída.». El aviso pasa a **Leída** con la fecha de lectura. El contador baja en uno.                                                                            |
| 4   | Cambia **Lectura de notificaciones** entre _Todas_, _Sin leer_ y _Leídas_.                         | Filtra correctamente. **No** existe la opción «Archivadas».                                                                                                                                |
| 5   | En **Configuración**, desactiva **Notificar casos prioritarios** y crea una alerta de riesgo alto. | La alerta se crea, pero **no** genera aviso nuevo. La campana no cambia.                                                                                                                   |
| 6   | Vuelve a activar el ajuste.                                                                        | Las alertas prioritarias nuevas vuelven a generar aviso.                                                                                                                                   |

### 6.3 Seguimiento familiar (cuenta O)

Hazlo en la cuenta **O** (la cuenta Familia no tiene visitas) con el paso de operador del apartado 2.4. Cada vez que se pide «ejecutar el paso de operador» se retrasa el alta del adulto indicado 20 días y se lanza `alertas_evaluar_diario()`.

| #   | Pasos                                                                                                                                                                 | Esperado                                                                                                                                                                           |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Con **AO**, en **Configuración**, fija **Días sin visita para generar alerta** en **30**. Ejecuta el paso de operador sobre `Persona O1 Prueba`.                      | **No** hay alerta de seguimiento: 20 días no superan 30.                                                                                                                           |
| 2   | Con **AO** vuelve el valor a **15** y ejecuta solo `select cuidared_interno.alertas_evaluar_diario();`.                                                               | Hay una alerta **Seguimiento familiar sin visita**, prioridad Media, fuente **Alta del expediente**, estado Pendiente. El aviso dice «Hay una alerta de seguimiento por revisar.». |
| 3   | Repite la evaluación diaria.                                                                                                                                          | No se duplica la alerta ni el aviso.                                                                                                                                               |
| 4   | Con **AO**, programa una visita para O1 y complétala (**Visitas**, ver [VISITAS-ORGANIZACION.md](../VISITAS-ORGANIZACION.md)). Ejecuta de nuevo la evaluación diaria. | La alerta pasa a **Resuelta** sola, con la nota de cierre automático. La visita completada es la nueva referencia.                                                                 |
| 5   | Con **AO**, desactiva **Notificar casos prioritarios**. Ejecuta el paso de operador sobre `Persona O2 Prueba`.                                                        | La alerta de seguimiento de O2 **sí** genera aviso: el ajuste solo afecta a los casos prioritarios. Vuelve a activarlo.                                                            |

## 7. Cuidador (CuF en F, CuO en O)

Genera antes alertas para `Persona F1` (cuenta F) y para `Persona O1` y `Persona O2` (cuenta O), como en el apartado 4.1.

| #   | Pasos                                                                           | Esperado                                                                                                                                                                             |
| --- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Entra como **CuO** en la cuenta O.                                              | El menú tiene **Alertas**. En la barra azul **no** hay campana.                                                                                                                      |
| 2   | **Alertas**.                                                                    | Solo hay dos bandejas: **Casos prioritarios** y **Alertas**. **No** hay **Notificaciones**. Al abrir `/operacion/<cuenta>/alertas?bandeja=avisos` se muestra **Casos prioritarios**. |
| 3   | Revisa las alertas.                                                             | Solo aparecen las de **O1** (su adulto asignado). Las de **O2** no se ven. El filtro **Adulto mayor** solo lista a O1.                                                               |
| 4   | Abre una alerta.                                                                | Hay **Resolver alerta** y **no** hay **Iniciar atención**.                                                                                                                           |
| 5   | Resuelve la alerta escribiendo la acción.                                       | «Alerta resuelta.», con la acción registrada y tu nombre en **Atendida por**.                                                                                                        |
| 6   | Con **AO**, abre esa alerta.                                                    | AO ve la misma acción, la fecha y el nombre de CuO.                                                                                                                                  |
| 7   | Con **AO**, genera otra alerta para O1 y comprueba que CuO **no** recibe aviso. | CuO no tiene campana ni bandeja de avisos. El aviso lo reciben AO y CO.                                                                                                              |
| 8   | Repite el paso 1 con **CuF** en la cuenta F.                                    | Mismo resultado: sin campana ni bandeja Notificaciones. Resuelve y no inicia la atención.                                                                                            |

## 8. Voluntario y Familiar: acceso denegado

Entra como **VO** (cuenta O) y repite con **FaO** y **FaF**, con las herramientas de desarrollo abiertas en la pestaña **Red**.

| #   | Pasos                                                                              | Esperado                                                                              |
| --- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 1   | Revisa el menú y **Más**.                                                          | **No** hay módulo **Alertas** ni campana.                                             |
| 2   | Abre `/operacion/<cuenta>/alertas` y `/operacion/<cuenta>/alertas?bandeja=avisos`. | Mensaje «No tienes acceso a este módulo de la cuenta.».                               |
| 3   | Revisa la pestaña **Red** durante los pasos anteriores.                            | **Ninguna** petición a `/alertas`, `/casos-prioritarios` ni `/notificaciones-alerta`. |
| 4   | Entra como **FaO** a **Adultos → Persona O1**.                                     | El expediente no muestra **Ver alertas de este adulto**.                              |
| 5   | Opcional: llama a la API con la sesión de VO o de FaO y una ruta de alertas.       | La API responde **403** (`FORBIDDEN`). Lo cubre `tests/alertas.test.js`.              |

## 9. Errores y bordes

| #   | Pasos                                                                                                                                         | Esperado                                                                                                                                                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Abre la **misma alerta** en dos ventanas (por ejemplo AO y CO). Resuélvela en la primera. En la segunda, **Resolver alerta** con otra acción. | La segunda muestra «La alerta ya no admite ese cambio porque cambió de estado. Se actualizó el detalle.» y el detalle aparece ya **Resuelta**. No dice «estado actual de la persona».                                                   |
| 2   | Abre una alerta abierta y, en otra ventana, cierra automáticamente su causa (6.1). Pulsa **Resolver alerta** en la primera.                   | Mismo mensaje y detalle actualizado con el cierre automático.                                                                                                                                                                           |
| 3   | Con una alerta abierta, desactiva la red (herramientas de desarrollo → **Sin conexión**).                                                     | Se muestra «Sin conexión»; **Iniciar atención**, **Resolver alerta** y **Marcar como leída** quedan deshabilitados. Al volver la red, se habilitan.                                                                                     |
| 4   | Con un servicio caído (detén el backend) intenta **Confirmar resolución**.                                                                    | Aparece «No se pudo conectar con CuidaRed. Intenta de nuevo.», el texto escrito se conserva y no aparece «Alerta resuelta.».                                                                                                            |
| 5   | Inactiva un expediente con alertas abiertas (**Cambiar estado**, con motivo).                                                                 | Las alertas abiertas se cierran con el cambio y dejan de aparecer en las bandejas operativas, que solo muestran expedientes activos. **Ver alertas de este adulto** desaparece. Se conservan en **Historial del expediente → Alertas**. |
| 6   | Cuenta sin prueba o plan vigente (si tienes una de prueba vencida).                                                                           | Alertas responde 403 `SUBSCRIPTION_INACTIVE`; el módulo no aparece. Solo se gestionan la cuenta y la suscripción.                                                                                                                       |

## 10. Web Push en la misma computadora

Procedimiento del contrato [web-push.md](../contratos/web-push.md). **Las claves nunca se escriben en este documento, en el frontend ni en Git.**

1. Genera una pareja VAPID para este entorno. Guárdala en el `.env` privado del backend, que Git ignora:
   `node --input-type=module -e "import w from 'web-push'; console.log(w.generateVAPIDKeys())"`
2. En ese `.env` define `WEB_PUSH_ENABLED=true`, `WEB_PUSH_PUBLIC_KEY`, `WEB_PUSH_PRIVATE_KEY` y `WEB_PUSH_VAPID_SUBJECT` con el contacto de la sección _Prueba en la misma computadora_ del contrato. El emisor también necesita `SUPABASE_SECRET_KEY` en ese mismo archivo.
3. Aplica la migración Web Push `20261116043610` en la base de pruebas (con aprobación si no es local).
4. En una terminal: `npm run start`. En otra: `npm run web-push:worker`.
5. En el frontend: `npm run dev:web-push` y abre `http://localhost:5173` en **Chrome**.

| #   | Pasos                                                                                                                                                                                | Esperado                                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| 1   | Entra como **CF** (o **AO**). Toca la campana y, en **Notificaciones**, pulsa **Activar notificaciones**. Concede el permiso del navegador.                                          | «Notificaciones activadas para este dispositivo.». El botón cambia a **Desactivar notificaciones**.                   |
| 2   | Recarga la página.                                                                                                                                                                   | El estado se conserva: sigue activo.                                                                                  |
| 3   | Cierra la pestaña de CF (o déjala en segundo plano). Desde otra sesión crea una alerta nueva para un adulto de CF (por ejemplo, con **CuF** registra una necesidad de Medicamentos). | Llega una notificación del sistema con un texto **genérico** (sin nombre del adulto), aunque la pestaña esté cerrada. |
| 3b  | Con la misma alerta, comprueba la campana en otra ventana.                                                                                                                           | El aviso interno existe y cuenta como sin leer.                                                                       |
| 4   | Toca la notificación.                                                                                                                                                                | Abre la bandeja **Notificaciones** autenticada. Si la sesión venció, pide iniciar sesión y conserva el destino.       |
| 5   | Verifica el aviso en la aplicación.                                                                                                                                                  | Sigue **Sin leer**: la lectura se registra solo al pulsar **Marcar como leída**.                                      |
| 6   | Repite el paso 3 varias veces seguidas con el mismo aviso.                                                                                                                           | No se acumulan copias: el navegador reemplaza la notificación repetida.                                               |
| 7   | **Desactivar notificaciones.** Crea otra alerta.                                                                                                                                     | El control cambia a **Activar notificaciones** y no llega notificación nueva a este navegador.                        |
| 8   | Entra como **CuF** o **CuO** y genera una alerta.                                                                                                                                    | CuF y CuO **no** reciben notificación y no tienen el control de activar: no tienen la bandeja de avisos.              |
| 9   | Con **FaF**, **FaO** y **VO** comprueba lo mismo.                                                                                                                                    | No tienen acceso a alertas ni a la bandeja de avisos.                                                                 |

Si no llega la notificación, revisa en este orden: el emisor (`web-push:worker`) está corriendo; `WEB_PUSH_ENABLED=true` en la API y en el emisor; Chrome concedió el permiso; la cuenta de prueba tiene prueba o plan vigente; el rol recibe avisos (CF, AO o CO); el aviso existe en la bandeja.

## 11. Registro de resultados

Anota la fecha, el entorno, el navegador y quién ejecutó la prueba. Guarda capturas solo con datos sintéticos.

| Bloque    | Rol              | Resultado | Observaciones |
| --------- | ---------------- | --------- | ------------- |
| 4         | CF               |           |               |
| 5         | AO (y CO)        |           |               |
| 6.1 a 6.3 | CF y AO          |           |               |
| 7         | CuF y CuO        |           |               |
| 8         | VO, FaO y FaF    |           |               |
| 9         | Errores y bordes |           |               |
| 10        | Web Push         |           |               |

La fase se da por verificada cuando todos los bloques pasan, sin alertas duplicadas, sin avisos para el Cuidador y sin datos del adulto en el texto de los avisos ni de las notificaciones del sistema.
