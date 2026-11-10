/* Lista cerrada de catálogos, filtros y paginación · CR-165/CR-162. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { TIPOS_CUENTA } from '../cuentas/permisos.js';

/*
 * Solo estos catálogos se publican (el resto de la ruta es 404). Cada uno declara sus filtros de consulta
 * (parámetros simples, no `filter[...]`: un catálogo es referencia, no una colección de negocio) y, si es muy largo,
 * su paginación CR-162. Los nombres coinciden con `p_nombre` de la RPC api_catalogo.
 */
const tipoCuenta = z.enum(TIPOS_CUENTA);
const provinciaCod = z.string().regex(/^[0-9]{2}$/);
const identificador = z
  .string()
  .regex(/^[1-9][0-9]{0,4}$/)
  .transform(Number);

export const CATALOGOS = {
  provincias: {},
  // El territorio no se siembra (D14): la base debe tenerlo cargado. Es el único catálogo paginado.
  municipios: {
    filtros: { provincia_cod: provinciaCod },
    paginacion: {
      sortableFields: ['nombre', 'municipio_cod'],
      defaultSort: 'nombre',
      tieBreaker: 'municipio_cod',
    },
  },
  'tipos-cuenta': {},
  'categorias-cuenta': { filtros: { tipo: tipoCuenta } },
  roles: {},
  planes: { filtros: { tipo: tipoCuenta } },
  'tipos-cuidado': {},
  'tipos-vinculo': {},
  prioridades: {},
  'niveles-riesgo': {},
  riesgos: {},
  'tipos-necesidad': {},
  necesidades: { filtros: { tipo_necesidad_id: identificador } },
  'tipos-alerta': {},
  'tipos-indicacion': {},
  'metodos-pago': {},
};
