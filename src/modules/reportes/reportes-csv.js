/* CSV auditado de los reportes estadísticos (UTF-8 con BOM, CRLF) · RF-08. © 2026 Equipo CuidaRed – INTEC. */

/*
 * Estructura y columnas de docs/contratos/reportes.md («CSV»). Se construye solo con los datos ya proyectados del
 * reporte; ninguna celda se interpreta como fórmula (OWASP «CSV injection»): el texto cuyo primer carácter visible
 * es =, +, -, @ (o su forma de ancho completo), o que empieza por tabulador o retorno de carro, se antepone con un
 * apóstrofo.
 */

const BOM = String.fromCharCode(0xfeff); // marca de orden de bytes UTF-8 (EF BB BF)
const SIN_DATOS = 'Sin datos para los filtros seleccionados.';
const SEPARADOR_LISTA = ' | ';

export const TITULOS = {
  adultos: 'Adultos mayores registrados',
  visitas: 'Visitas realizadas',
  necesidades: 'Necesidades frecuentes y atendidas',
  casos_prioritarios: 'Casos prioritarios',
};

const RIESGO = { alto: 'Alto', medio: 'Medio', bajo: 'Bajo' };
const riesgo = (nivel) => (nivel ? RIESGO[nivel] : 'Sin evaluación vigente');
const nombre = (p) => `${p.nombres} ${p.apellidos}`;
const lista = (items) => items.join(SEPARADOR_LISTA);
const municipio = (m) => m.nombre ?? m.codigo;

const COLUMNAS = {
  adultos: [
    ['Apellidos', (f) => f.apellidos],
    ['Nombres', (f) => f.nombres],
    ['Municipio', (f) => municipio(f.municipio)],
    ['Sector', (f) => f.zona],
    ['Edad', (f) => f.edad],
    ['Sexo', (f) => f.sexo],
    ['Riesgo vigente', (f) => riesgo(f.riesgo_vigente)],
    ['Estado', (f) => f.estado],
    ['Fecha de alta', (f) => f.fecha_alta],
    ['Personal asignado', (f) => f.personal_asignado],
  ],
  visitas: [
    ['Fecha', (f) => f.fecha],
    ['Hora inicio', (f) => f.hora_inicio],
    ['Hora fin', (f) => f.hora_fin],
    ['Razón', (f) => f.razon],
    ['Origen', (f) => f.origen],
    [
      'Tipo de visita',
      (f) =>
        f.tipo_visita === 'institucional' ? 'Institucional sin expediente' : 'Con expediente',
    ],
    ['Responsables', (f) => lista(f.responsables.map(nombre))],
    ['Adultos atendidos', (f) => lista(f.adultos.map(nombre))],
    ['Estados observados', (f) => lista(f.adultos.map((a) => a.estado_general ?? 'sin_registro'))],
  ],
  necesidades: [
    ['Categoría', (f) => f.nombre],
    ['Total', (f) => f.total],
    ['% del total', (f) => f.porcentaje],
    ['Pendientes', (f) => f.pendientes],
    ['En proceso', (f) => f.en_proceso],
    ['Resueltas', (f) => f.resueltas],
    ['Canceladas', (f) => f.canceladas],
    ['Prioridad alta', (f) => f.prioridad_alta],
    ['Recurrentes', (f) => f.recurrentes],
  ],
  casos_prioritarios: [
    ['Apellidos', (f) => f.apellidos],
    ['Nombres', (f) => f.nombres],
    ['Municipio', (f) => municipio(f.municipio)],
    ['Sector', (f) => f.zona],
    ['Riesgo vigente', (f) => riesgo(f.riesgo_vigente)],
    ['Alertas prioritarias', (f) => f.alertas],
    ['Alertas abiertas', (f) => f.alertas_abiertas],
    ['Tipos de alerta', (f) => lista(f.tipos)],
    ['Estado actual', (f) => f.estado_actual],
    ['Última alerta', (f) => f.ultima_alerta],
  ],
};

// Fórmula: empieza por tabulador o retorno de carro, o su primer carácter visible es = + - @ o su forma de ancho
// completo (U+FF1D, U+FF0B, U+FF0D, U+FF20), aunque vaya precedido de espacios (OWASP «CSV injection»).
const FORMULA = /^[\t\r]|^\s*[=+\-@＝＋－＠]/u;

/** Celda segura: neutraliza fórmulas en el texto y entrecomilla separadores, comillas y saltos de línea. */
export function celda(valor) {
  if (valor === null || valor === undefined) return '';
  if (typeof valor === 'number') return Number.isFinite(valor) ? String(valor) : '';
  if (typeof valor === 'boolean') return valor ? 'Sí' : 'No';
  let texto = String(valor);
  if (FORMULA.test(texto)) texto = `'${texto}`;
  return /[",;\r\n]/.test(texto) ? `"${texto.replace(/"/g, '""')}"` : texto;
}

/** CSV completo del reporte, con la cabecera de la exportación registrada. */
export function reporteCsv({ exportacion, reporte }) {
  const { tipo, filtros } = reporte;
  const filas = [
    ['Reporte CuidaRed', TITULOS[tipo]],
    ['Cuenta', exportacion.cuenta.nombre],
    ['Generado', reporte.generado_en],
    ['Generado por', nombre(exportacion.generado_por)],
    ['Fecha filtrada', reporte.campo_fecha],
    ['Desde', filtros.desde],
    ['Hasta', filtros.hasta],
    ['Municipio', filtros.municipio_cod ?? 'Todos'],
    ['Sector', filtros.zona ?? 'Todos'],
    ['Riesgo', filtros.riesgo ?? 'Todos'],
  ];
  if (tipo === 'necesidades') filas.push(['Categoría', filtros.tipo_necesidad_id ?? 'Todas']);

  filas.push([], ['Indicadores'], ['Indicador', 'Valor']);
  for (const [clave, valor] of Object.entries(reporte.indicadores)) {
    filas.push([clave, clave === 'mas_frecuente' ? (valor?.nombre ?? null) : valor]);
  }
  for (const [clave, items] of Object.entries(reporte.series)) {
    filas.push([], [clave], ['Clave', 'Etiqueta', 'Valor', 'Porcentaje']);
    for (const item of items) filas.push([item.clave, item.etiqueta, item.valor, item.porcentaje]);
  }

  filas.push([]);
  if (reporte.detalle.length === 0) {
    filas.push([SIN_DATOS]);
  } else {
    const columnas = COLUMNAS[tipo];
    filas.push(
      ['Detalle'],
      columnas.map(([titulo]) => titulo),
    );
    for (const fila of reporte.detalle) filas.push(columnas.map(([, valor]) => valor(fila)));
    if (reporte.detalle_truncado) {
      filas.push(['Detalle recortado', `${reporte.detalle.length} de ${reporte.detalle_total}`]);
    }
  }
  return BOM + filas.map((fila) => fila.map(celda).join(',')).join('\r\n') + '\r\n';
}
