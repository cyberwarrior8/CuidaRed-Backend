/* Genera la siembra SQL de cuidared.rol_permiso desde la matriz de la API · herramientas. © 2026 Equipo CuidaRed – INTEC. */
// Uso: node scripts/generar-permisos-sql.js  → imprime el bloque `insert` que va en docs/propuestas/fase-2a-base.sql.
// La matriz vive en src/modules/cuentas/permisos.js; regenerar el bloque cada vez que cambie.
import { filasPermisos } from '../src/modules/cuentas/permisos.js';

const filas = filasPermisos()
  .map(({ rol, tipo, accion }) => `  ('${rol}', '${tipo}', '${accion}')`)
  .join(',\n');
process.stdout.write(`insert into cuidared.rol_permiso (rol_id, tipo_cuenta_id, accion)
select r.rol_id, t.tipo_cuenta_id, v.accion
from (values
${filas}
) as v(rol, tipo, accion)
join cuidared.rol r on r.codigo = v.rol
join cuidared.tipo_cuenta t on t.codigo = v.tipo
on conflict do nothing;
`);
