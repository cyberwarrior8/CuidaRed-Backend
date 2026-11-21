-- PROPUESTA SIN APLICAR. Requiere aprobación expresa antes de ejecutarse.
-- ID02; ONE, División Territorial 2021, corte declarado 2021-06-30.
-- Fuente, páginas y SHA-256: docs/catalogos/one-2021.propuesta.json.
-- Regenerar: node scripts/prepare-territory-catalog.js --write-sql
-- CUIDARED-003. No actualiza ni elimina registros, ni modifica tablas permanentes.
begin;
lock table cuidared.provincia, cuidared.municipio in share row exclusive mode;

create temporary table one_2021_provincia (
  provincia_cod varchar(2) primary key,
  nombre text not null unique
) on commit drop;
create temporary table one_2021_municipio (
  municipio_cod varchar(4) primary key,
  nombre text not null,
  provincia_cod varchar(2) not null references one_2021_provincia(provincia_cod)
) on commit drop;

insert into pg_temp.one_2021_provincia(provincia_cod, nombre) values
  ('01', 'Distrito Nacional'),
  ('02', 'Azua'),
  ('03', 'Baoruco'),
  ('04', 'Barahona'),
  ('05', 'Dajabón'),
  ('06', 'Duarte'),
  ('07', 'Elías Piña'),
  ('08', 'El Seibo'),
  ('09', 'Espaillat'),
  ('10', 'Independencia'),
  ('11', 'La Altagracia'),
  ('12', 'La Romana'),
  ('13', 'La Vega'),
  ('14', 'María Trinidad Sánchez'),
  ('15', 'Monte Cristi'),
  ('16', 'Pedernales'),
  ('17', 'Peravia'),
  ('18', 'Puerto Plata'),
  ('19', 'Hermanas Mirabal'),
  ('20', 'Samaná'),
  ('21', 'San Cristóbal'),
  ('22', 'San Juan'),
  ('23', 'San Pedro de Macorís'),
  ('24', 'Sánchez Ramírez'),
  ('25', 'Santiago'),
  ('26', 'Santiago Rodríguez'),
  ('27', 'Valverde'),
  ('28', 'Monseñor Nouel'),
  ('29', 'Monte Plata'),
  ('30', 'Hato Mayor'),
  ('31', 'San José de Ocoa'),
  ('32', 'Santo Domingo');

insert into pg_temp.one_2021_municipio(municipio_cod, nombre, provincia_cod) values
  ('0101', 'Santo Domingo de Guzmán', '01'),
  ('0201', 'Azua', '02'),
  ('0202', 'Las Charcas', '02'),
  ('0203', 'Las Yayas de Viajama', '02'),
  ('0204', 'Padre Las Casas', '02'),
  ('0205', 'Peralta', '02'),
  ('0206', 'Sabana Yegua', '02'),
  ('0207', 'Pueblo Viejo', '02'),
  ('0208', 'Tábara Arriba', '02'),
  ('0209', 'Guayabal', '02'),
  ('0210', 'Estebanía', '02'),
  ('0301', 'Neiba', '03'),
  ('0302', 'Galván', '03'),
  ('0303', 'Tamayo', '03'),
  ('0304', 'Villa Jaragua', '03'),
  ('0305', 'Los Ríos', '03'),
  ('0401', 'Barahona', '04'),
  ('0402', 'Cabral', '04'),
  ('0403', 'Enriquillo', '04'),
  ('0404', 'Paraíso', '04'),
  ('0405', 'Vicente Noble', '04'),
  ('0406', 'El Peñón', '04'),
  ('0407', 'La Ciénaga', '04'),
  ('0408', 'Fundación', '04'),
  ('0409', 'Las Salinas', '04'),
  ('0410', 'Polo', '04'),
  ('0411', 'Jaquimeyes', '04'),
  ('0501', 'Dajabón', '05'),
  ('0502', 'Loma de Cabrera', '05'),
  ('0503', 'Partido', '05'),
  ('0504', 'Restauración', '05'),
  ('0505', 'El Pino', '05'),
  ('0601', 'San Francisco de Macorís', '06'),
  ('0602', 'Arenoso', '06'),
  ('0603', 'Castillo', '06'),
  ('0604', 'Pimentel', '06'),
  ('0605', 'Villa Riva', '06'),
  ('0606', 'Las Guáranas', '06'),
  ('0607', 'Eugenio María de Hostos', '06'),
  ('0701', 'Comendador', '07'),
  ('0702', 'Bánica', '07'),
  ('0703', 'El Llano', '07'),
  ('0704', 'Hondo Valle', '07'),
  ('0705', 'Pedro Santana', '07'),
  ('0706', 'Juan Santiago', '07'),
  ('0801', 'El Seibo', '08'),
  ('0802', 'Miches', '08'),
  ('0901', 'Moca', '09'),
  ('0902', 'Cayetano Germosén', '09'),
  ('0903', 'Gaspar Hernández', '09'),
  ('0904', 'Jamao Al Norte', '09'),
  ('0905', 'San Víctor', '09'),
  ('1001', 'Jimaní', '10'),
  ('1002', 'Duvergé', '10'),
  ('1003', 'La Descubierta', '10'),
  ('1004', 'Postrer Río', '10'),
  ('1005', 'Cristóbal', '10'),
  ('1006', 'Mella', '10'),
  ('1101', 'Higüey', '11'),
  ('1102', 'San Rafael del Yuma', '11'),
  ('1201', 'La Romana', '12'),
  ('1202', 'Guaymate', '12'),
  ('1203', 'Villa Hermosa', '12'),
  ('1301', 'La Vega', '13'),
  ('1302', 'Constanza', '13'),
  ('1303', 'Jarabacoa', '13'),
  ('1304', 'Jima Abajo', '13'),
  ('1401', 'Nagua', '14'),
  ('1402', 'Cabrera', '14'),
  ('1403', 'El Factor', '14'),
  ('1404', 'Río San Juan', '14'),
  ('1501', 'Monte Cristi', '15'),
  ('1502', 'Castañuelas', '15'),
  ('1503', 'Guayubín', '15'),
  ('1504', 'Las Matas de Santa Cruz', '15'),
  ('1505', 'Pepillo Salcedo', '15'),
  ('1506', 'Villa Vásquez', '15'),
  ('1601', 'Pedernales', '16'),
  ('1602', 'Oviedo', '16'),
  ('1701', 'Baní', '17'),
  ('1702', 'Nizao', '17'),
  ('1703', 'Matanzas', '17'),
  ('1801', 'Puerto Plata', '18'),
  ('1802', 'Altamira', '18'),
  ('1803', 'Guananico', '18'),
  ('1804', 'Imbert', '18'),
  ('1805', 'Los Hidalgos', '18'),
  ('1806', 'Luperón', '18'),
  ('1807', 'Sosúa', '18'),
  ('1808', 'Villa Isabela', '18'),
  ('1809', 'Villa Montellano', '18'),
  ('1901', 'Salcedo', '19'),
  ('1902', 'Tenares', '19'),
  ('1903', 'Villa Tapia', '19'),
  ('2001', 'Samaná', '20'),
  ('2002', 'Sánchez', '20'),
  ('2003', 'Las Terrenas', '20'),
  ('2101', 'San Cristóbal', '21'),
  ('2102', 'Sabana Grande de Palenque', '21'),
  ('2103', 'Bajos de Haina', '21'),
  ('2104', 'Cambita Garabitos', '21'),
  ('2105', 'Villa Altagracia', '21'),
  ('2106', 'Yaguate', '21'),
  ('2107', 'San Gregorio de Nigua', '21'),
  ('2108', 'Los Cacaos', '21'),
  ('2201', 'San Juan', '22'),
  ('2202', 'Bohechío', '22'),
  ('2203', 'El Cercado', '22'),
  ('2204', 'Juan de Herrera', '22'),
  ('2205', 'Las Matas de Farfán', '22'),
  ('2206', 'Vallejuelo', '22'),
  ('2301', 'San Pedro de Macorís', '23'),
  ('2302', 'Los Llanos', '23'),
  ('2303', 'Ramón Santana', '23'),
  ('2304', 'Consuelo', '23'),
  ('2305', 'Quisqueya', '23'),
  ('2306', 'Guayacanes', '23'),
  ('2401', 'Cotuí', '24'),
  ('2402', 'Cevicos', '24'),
  ('2403', 'Fantino', '24'),
  ('2404', 'Villa La Mata', '24'),
  ('2501', 'Santiago', '25'),
  ('2502', 'Bisonó', '25'),
  ('2503', 'Jánico', '25'),
  ('2504', 'Licey al Medio', '25'),
  ('2505', 'San José de las Matas', '25'),
  ('2506', 'Tamboril', '25'),
  ('2507', 'Villa González', '25'),
  ('2508', 'Puñal', '25'),
  ('2509', 'Sabana Iglesia', '25'),
  ('2510', 'Baitoa', '25'),
  ('2601', 'San Ignacio de Sabaneta', '26'),
  ('2602', 'Villa Los Almácigos', '26'),
  ('2603', 'Monción', '26'),
  ('2701', 'Mao', '27'),
  ('2702', 'Esperanza', '27'),
  ('2703', 'Laguna Salada', '27'),
  ('2801', 'Bonao', '28'),
  ('2802', 'Maimón', '28'),
  ('2803', 'Piedra Blanca', '28'),
  ('2901', 'Monte Plata', '29'),
  ('2902', 'Bayaguana', '29'),
  ('2903', 'Sabana Grande de Boyá', '29'),
  ('2904', 'Yamasá', '29'),
  ('2905', 'Peralvillo', '29'),
  ('3001', 'Hato Mayor', '30'),
  ('3002', 'Sabana de La Mar', '30'),
  ('3003', 'El Valle', '30'),
  ('3101', 'San José de Ocoa', '31'),
  ('3102', 'Sabana Larga', '31'),
  ('3103', 'Rancho Arriba', '31'),
  ('3201', 'Santo Domingo Este', '32'),
  ('3202', 'Santo Domingo Oeste', '32'),
  ('3203', 'Santo Domingo Norte', '32'),
  ('3204', 'Boca Chica', '32'),
  ('3205', 'San Antonio de Guerra', '32'),
  ('3206', 'Los Alcarrizos', '32'),
  ('3207', 'Pedro Brand', '32');

-- Abortamos ante datos diferentes: no mezclar ediciones ni corregir nombres en silencio.
do $$
begin
  if exists (
    select 1 from cuidared.provincia p
    left join pg_temp.one_2021_provincia s using (provincia_cod)
    where s.provincia_cod is null or p.nombre is distinct from s.nombre
  ) or exists (
    select 1 from cuidared.municipio m
    left join pg_temp.one_2021_municipio s using (municipio_cod)
    where s.municipio_cod is null or m.nombre is distinct from s.nombre
       or m.provincia_cod is distinct from s.provincia_cod
  ) then
    raise exception using errcode = '22023',
      message = 'El catálogo existente difiere de la propuesta ONE 2021. Revisar antes de cargar.';
  end if;
end;
$$;

insert into cuidared.provincia(provincia_cod, nombre)
select provincia_cod, nombre from pg_temp.one_2021_provincia
on conflict (provincia_cod) do nothing;

insert into cuidared.municipio(municipio_cod, nombre, provincia_cod)
select municipio_cod, nombre, provincia_cod from pg_temp.one_2021_municipio
on conflict (municipio_cod) do nothing;

do $$
begin
  if (select count(*) from cuidared.provincia) <> 32
     or (select count(*) from cuidared.municipio) <> 158 then
    raise exception using errcode = '22023', message = 'Conteos territoriales inesperados.';
  end if;
end;
$$;
commit;
