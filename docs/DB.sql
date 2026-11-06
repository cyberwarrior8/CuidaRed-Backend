-- WARNING: This schema is for context only and is not meant to be run.
-- Table order and constraints may not be valid for execution.

CREATE TABLE cuidared.provincia (
  provincia_cod character varying NOT NULL CHECK (provincia_cod::text ~ '^[0-9]{2}$'::text),
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT provincia_pkey PRIMARY KEY (provincia_cod)
);
CREATE TABLE cuidared.municipio (
  municipio_cod character varying NOT NULL CHECK (municipio_cod::text ~ '^[0-9]{4,6}$'::text),
  nombre character varying NOT NULL,
  provincia_cod character varying NOT NULL,
  CONSTRAINT municipio_pkey PRIMARY KEY (municipio_cod),
  CONSTRAINT fk_municipio_provincia FOREIGN KEY (provincia_cod) REFERENCES cuidared.provincia(provincia_cod)
);
CREATE TABLE cuidared.tipo_cuenta (
  tipo_cuenta_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT tipo_cuenta_pkey PRIMARY KEY (tipo_cuenta_id)
);
CREATE TABLE cuidared.categoria_cuenta (
  categoria_cuenta_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT categoria_cuenta_pkey PRIMARY KEY (categoria_cuenta_id)
);
CREATE TABLE cuidared.plan_categoria (
  plan_categoria_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT plan_categoria_pkey PRIMARY KEY (plan_categoria_id)
);
CREATE TABLE cuidared.plan (
  plan_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  plan_categoria_id smallint NOT NULL,
  tipo_cuenta_id smallint NOT NULL,
  precio numeric NOT NULL DEFAULT 0 CHECK (precio >= 0::numeric),
  periodicidad character varying NOT NULL DEFAULT 'sin_vencimiento'::character varying CHECK (periodicidad::text = ANY (ARRAY['sin_vencimiento'::character varying, 'mensual'::character varying, 'trimestral'::character varying, 'anual'::character varying]::text[])),
  duracion_dias integer,
  estado character varying NOT NULL DEFAULT 'activo'::character varying CHECK (estado::text = ANY (ARRAY['activo'::character varying, 'inactivo'::character varying]::text[])),
  limite_envejecientes integer CHECK (limite_envejecientes IS NULL OR limite_envejecientes > 0),
  limite_usuarios integer CHECK (limite_usuarios IS NULL OR limite_usuarios > 0),
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT plan_pkey PRIMARY KEY (plan_id),
  CONSTRAINT fk_plan_plan_categoria FOREIGN KEY (plan_categoria_id) REFERENCES cuidared.plan_categoria(plan_categoria_id),
  CONSTRAINT fk_plan_tipo_cuenta FOREIGN KEY (tipo_cuenta_id) REFERENCES cuidared.tipo_cuenta(tipo_cuenta_id)
);
CREATE TABLE cuidared.rol (
  rol_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  codigo character varying NOT NULL UNIQUE CHECK (codigo::text ~ '^[a-z_]+$'::text),
  nombre character varying NOT NULL UNIQUE,
  descripcion character varying,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT rol_pkey PRIMARY KEY (rol_id)
);
CREATE TABLE cuidared.prioridad (
  prioridad_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  orden smallint NOT NULL UNIQUE,
  CONSTRAINT prioridad_pkey PRIMARY KEY (prioridad_id)
);
CREATE TABLE cuidared.nivel_riesgo (
  nivel_riesgo_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  orden smallint NOT NULL UNIQUE,
  CONSTRAINT nivel_riesgo_pkey PRIMARY KEY (nivel_riesgo_id)
);
CREATE TABLE cuidared.riesgo (
  riesgo_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  descripcion character varying,
  CONSTRAINT riesgo_pkey PRIMARY KEY (riesgo_id)
);
CREATE TABLE cuidared.tipo_necesidad (
  tipo_necesidad_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT tipo_necesidad_pkey PRIMARY KEY (tipo_necesidad_id)
);
CREATE TABLE cuidared.necesidad (
  necesidad_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  tipo_necesidad_id smallint NOT NULL,
  descripcion character varying,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT necesidad_pkey PRIMARY KEY (necesidad_id),
  CONSTRAINT fk_necesidad_tipo_necesidad FOREIGN KEY (tipo_necesidad_id) REFERENCES cuidared.tipo_necesidad(tipo_necesidad_id)
);
CREATE TABLE cuidared.tipo_alerta (
  tipo_alerta_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  codigo character varying NOT NULL UNIQUE CHECK (codigo::text ~ '^[a-z_]+$'::text),
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT tipo_alerta_pkey PRIMARY KEY (tipo_alerta_id)
);
CREATE TABLE cuidared.tipo_indicacion (
  tipo_indicacion_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT tipo_indicacion_pkey PRIMARY KEY (tipo_indicacion_id)
);
CREATE TABLE cuidared.tipo_cuidado (
  tipo_cuidado_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT tipo_cuidado_pkey PRIMARY KEY (tipo_cuidado_id)
);
CREATE TABLE cuidared.tipo_vinculo (
  tipo_vinculo_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  codigo character varying NOT NULL UNIQUE CHECK (codigo::text ~ '^[a-z_]+$'::text),
  nombre character varying NOT NULL UNIQUE,
  CONSTRAINT tipo_vinculo_pkey PRIMARY KEY (tipo_vinculo_id)
);
CREATE TABLE cuidared.metodo_pago (
  metodo_pago_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE,
  activo boolean NOT NULL DEFAULT true,
  CONSTRAINT metodo_pago_pkey PRIMARY KEY (metodo_pago_id)
);
CREATE TABLE cuidared.parametro (
  parametro_id smallint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL UNIQUE CHECK (nombre::text ~ '^[a-z0-9_]+$'::text),
  valor character varying NOT NULL,
  valor_defecto character varying NOT NULL,
  descripcion character varying,
  tipo_dato character varying NOT NULL DEFAULT 'texto'::character varying CHECK (tipo_dato::text = ANY (ARRAY['entero'::character varying, 'decimal'::character varying, 'booleano'::character varying, 'texto'::character varying]::text[])),
  CONSTRAINT parametro_pkey PRIMARY KEY (parametro_id)
);
CREATE TABLE cuidared.usuario (
  usuario_id uuid NOT NULL,
  cedula character NOT NULL UNIQUE CHECK (cedula ~ '^[0-9]{11}$'::text),
  nombres character varying NOT NULL,
  apellidos character varying NOT NULL,
  correo character varying NOT NULL CHECK (correo::text ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text),
  telefono character varying CHECK (telefono IS NULL OR telefono::text ~ '^\+?[0-9]{10,15}$'::text),
  estado character varying NOT NULL DEFAULT 'activo'::character varying CHECK (estado::text = ANY (ARRAY['activo'::character varying, 'inactivo'::character varying, 'suspendido'::character varying]::text[])),
  fecha_registro timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT usuario_pkey PRIMARY KEY (usuario_id),
  CONSTRAINT fk_usuario_auth FOREIGN KEY (usuario_id) REFERENCES auth.users(id)
);
CREATE TABLE cuidared.cuenta (
  cuenta_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  nombre character varying NOT NULL,
  tipo_cuenta_id smallint NOT NULL,
  categoria_cuenta_id smallint NOT NULL,
  municipio_cod character varying NOT NULL,
  direccion character varying,
  telefono character varying CHECK (telefono IS NULL OR telefono::text ~ '^\+?[0-9]{10,15}$'::text),
  correo character varying CHECK (correo IS NULL OR correo::text ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text),
  suscripcion_estado character varying NOT NULL DEFAULT 'activa'::character varying CHECK (suscripcion_estado::text = ANY (ARRAY['prueba'::character varying, 'activa'::character varying, 'vencida'::character varying, 'cancelada'::character varying, 'suspendida'::character varying]::text[])),
  prueba_gratuita boolean NOT NULL DEFAULT false,
  fecha_inicio_prueba date,
  fecha_fin_prueba date,
  plan_id smallint NOT NULL,
  plan_precio numeric NOT NULL DEFAULT 0 CHECK (plan_precio >= 0::numeric),
  usuario_titular_id uuid NOT NULL,
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT cuenta_pkey PRIMARY KEY (cuenta_id),
  CONSTRAINT fk_cuenta_tipo_cuenta FOREIGN KEY (tipo_cuenta_id) REFERENCES cuidared.tipo_cuenta(tipo_cuenta_id),
  CONSTRAINT fk_cuenta_categoria_cuenta FOREIGN KEY (categoria_cuenta_id) REFERENCES cuidared.categoria_cuenta(categoria_cuenta_id),
  CONSTRAINT fk_cuenta_municipio FOREIGN KEY (municipio_cod) REFERENCES cuidared.municipio(municipio_cod),
  CONSTRAINT fk_cuenta_plan FOREIGN KEY (plan_id) REFERENCES cuidared.plan(plan_id),
  CONSTRAINT fk_cuenta_usuario_titular FOREIGN KEY (usuario_titular_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.membresia (
  membresia_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  usuario_id uuid NOT NULL,
  cuenta_id bigint NOT NULL,
  rol_id smallint NOT NULL,
  estado character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado::text = ANY (ARRAY['pendiente'::character varying, 'activa'::character varying, 'inactiva'::character varying]::text[])),
  fecha_inicio date NOT NULL DEFAULT CURRENT_DATE,
  fecha_fin date,
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT membresia_pkey PRIMARY KEY (membresia_id),
  CONSTRAINT fk_membresia_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_membresia_cuenta FOREIGN KEY (cuenta_id) REFERENCES cuidared.cuenta(cuenta_id),
  CONSTRAINT fk_membresia_rol FOREIGN KEY (rol_id) REFERENCES cuidared.rol(rol_id)
);
CREATE TABLE cuidared.configuracion_cuenta (
  cuenta_id bigint NOT NULL,
  parametro_id smallint NOT NULL,
  valor character varying NOT NULL,
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT configuracion_cuenta_pkey PRIMARY KEY (cuenta_id, parametro_id),
  CONSTRAINT fk_configuracion_cuenta_cuenta FOREIGN KEY (cuenta_id) REFERENCES cuidared.cuenta(cuenta_id),
  CONSTRAINT fk_configuracion_cuenta_parametro FOREIGN KEY (parametro_id) REFERENCES cuidared.parametro(parametro_id)
);
CREATE TABLE cuidared.pago (
  pago_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  cuenta_id bigint NOT NULL,
  plan_id smallint NOT NULL,
  usuario_id uuid NOT NULL,
  metodo_pago_id smallint NOT NULL,
  monto numeric NOT NULL CHECK (monto >= 0::numeric),
  moneda character NOT NULL DEFAULT 'DOP'::bpchar CHECK (moneda ~ '^[A-Z]{3}$'::text),
  estado character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado::text = ANY (ARRAY['pendiente'::character varying, 'completado'::character varying, 'fallido'::character varying, 'reembolsado'::character varying]::text[])),
  referencia_pasarela character varying,
  fecha_pago timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT pago_pkey PRIMARY KEY (pago_id),
  CONSTRAINT fk_pago_cuenta FOREIGN KEY (cuenta_id) REFERENCES cuidared.cuenta(cuenta_id),
  CONSTRAINT fk_pago_plan FOREIGN KEY (plan_id) REFERENCES cuidared.plan(plan_id),
  CONSTRAINT fk_pago_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_pago_metodo_pago FOREIGN KEY (metodo_pago_id) REFERENCES cuidared.metodo_pago(metodo_pago_id)
);
CREATE TABLE cuidared.envejeciente (
  envejeciente_id uuid NOT NULL DEFAULT gen_random_uuid(),
  cuenta_id bigint NOT NULL,
  usuario_registrador_id uuid NOT NULL,
  nombres character varying NOT NULL,
  apellidos character varying NOT NULL,
  cedula character CHECK (cedula IS NULL OR cedula ~ '^[0-9]{11}$'::text),
  fecha_nacimiento date NOT NULL CHECK (fecha_nacimiento >= '1900-01-01'::date AND fecha_nacimiento <= CURRENT_DATE),
  sexo character NOT NULL CHECK (sexo = ANY (ARRAY['F'::bpchar, 'M'::bpchar])),
  municipio_cod character varying NOT NULL,
  direccion character varying NOT NULL,
  telefono character varying CHECK (telefono IS NULL OR telefono::text ~ '^\+?[0-9]{10,15}$'::text),
  estado character varying NOT NULL DEFAULT 'activo'::character varying CHECK (estado::text = ANY (ARRAY['activo'::character varying, 'inactivo'::character varying, 'fallecido'::character varying]::text[])),
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT envejeciente_pkey PRIMARY KEY (envejeciente_id),
  CONSTRAINT fk_envejeciente_cuenta FOREIGN KEY (cuenta_id) REFERENCES cuidared.cuenta(cuenta_id),
  CONSTRAINT fk_envejeciente_registrador FOREIGN KEY (usuario_registrador_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_envejeciente_municipio FOREIGN KEY (municipio_cod) REFERENCES cuidared.municipio(municipio_cod)
);
CREATE TABLE cuidared.contacto_emergencia (
  contacto_emergencia_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  envejeciente_id uuid NOT NULL,
  nombres character varying NOT NULL,
  apellidos character varying NOT NULL,
  parentesco character varying NOT NULL,
  telefono character varying NOT NULL CHECK (telefono::text ~ '^\+?[0-9]{10,15}$'::text),
  es_principal boolean NOT NULL DEFAULT false,
  CONSTRAINT contacto_emergencia_pkey PRIMARY KEY (contacto_emergencia_id),
  CONSTRAINT fk_contacto_emergencia_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id)
);
CREATE TABLE cuidared.vinculo (
  envejeciente_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  tipo_vinculo_id smallint NOT NULL,
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT vinculo_pkey PRIMARY KEY (envejeciente_id, usuario_id),
  CONSTRAINT fk_vinculo_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_vinculo_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_vinculo_tipo_vinculo FOREIGN KEY (tipo_vinculo_id) REFERENCES cuidared.tipo_vinculo(tipo_vinculo_id)
);
CREATE TABLE cuidared.cuidador (
  cuidador_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  usuario_id uuid NOT NULL,
  tipo_cuidado_id smallint NOT NULL,
  fecha_inicio date NOT NULL DEFAULT CURRENT_DATE,
  fecha_fin date,
  cuidador_independiente boolean NOT NULL DEFAULT false,
  usuario_empleador_id uuid,
  CONSTRAINT cuidador_pkey PRIMARY KEY (cuidador_id),
  CONSTRAINT fk_cuidador_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_cuidador_tipo_cuidado FOREIGN KEY (tipo_cuidado_id) REFERENCES cuidared.tipo_cuidado(tipo_cuidado_id),
  CONSTRAINT fk_cuidador_empleador FOREIGN KEY (usuario_empleador_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.indicacion_medica (
  indicacion_medica_id uuid NOT NULL DEFAULT gen_random_uuid(),
  envejeciente_id uuid NOT NULL,
  tipo_indicacion_id smallint NOT NULL,
  titulo character varying NOT NULL,
  descripcion text,
  frecuencia_horario character varying,
  fecha_inicio date NOT NULL DEFAULT CURRENT_DATE,
  fecha_fin date,
  estado character varying NOT NULL DEFAULT 'activa'::character varying CHECK (estado::text = ANY (ARRAY['activa'::character varying, 'suspendida'::character varying, 'finalizada'::character varying]::text[])),
  evidencia_url text,
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT indicacion_medica_pkey PRIMARY KEY (indicacion_medica_id),
  CONSTRAINT fk_indicacion_medica_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_indicacion_medica_tipo FOREIGN KEY (tipo_indicacion_id) REFERENCES cuidared.tipo_indicacion(tipo_indicacion_id)
);
CREATE TABLE cuidared.envejeciente_necesidad (
  envejeciente_necesidad_id uuid NOT NULL DEFAULT gen_random_uuid(),
  envejeciente_id uuid NOT NULL,
  necesidad_id smallint NOT NULL,
  prioridad_id smallint NOT NULL,
  fecha_necesidad timestamp with time zone NOT NULL DEFAULT now(),
  cantidad numeric CHECK (cantidad IS NULL OR cantidad >= 0::numeric),
  unidad_medida character varying,
  descripcion text,
  estado character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado::text = ANY (ARRAY['pendiente'::character varying, 'en_proceso'::character varying, 'resuelta'::character varying, 'cancelada'::character varying]::text[])),
  es_recurrente boolean NOT NULL DEFAULT false,
  umbral_alerta numeric CHECK (umbral_alerta IS NULL OR umbral_alerta >= 0::numeric),
  indicacion_medica_id uuid,
  usuario_responsable_id uuid,
  fecha_resolucion timestamp with time zone,
  motivo_resolucion text,
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT envejeciente_necesidad_pkey PRIMARY KEY (envejeciente_necesidad_id),
  CONSTRAINT fk_env_necesidad_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_env_necesidad_necesidad FOREIGN KEY (necesidad_id) REFERENCES cuidared.necesidad(necesidad_id),
  CONSTRAINT fk_env_necesidad_prioridad FOREIGN KEY (prioridad_id) REFERENCES cuidared.prioridad(prioridad_id),
  CONSTRAINT fk_env_necesidad_indicacion FOREIGN KEY (indicacion_medica_id) REFERENCES cuidared.indicacion_medica(indicacion_medica_id),
  CONSTRAINT fk_env_necesidad_responsable FOREIGN KEY (usuario_responsable_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.envejeciente_riesgo (
  envejeciente_riesgo_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  envejeciente_id uuid NOT NULL,
  riesgo_id smallint NOT NULL,
  nivel_riesgo_id smallint NOT NULL,
  fecha_riesgo timestamp with time zone NOT NULL DEFAULT now(),
  estado character varying NOT NULL DEFAULT 'activo'::character varying CHECK (estado::text = ANY (ARRAY['activo'::character varying, 'resuelto'::character varying, 'reemplazado'::character varying]::text[])),
  motivo character varying,
  observacion text,
  CONSTRAINT envejeciente_riesgo_pkey PRIMARY KEY (envejeciente_riesgo_id),
  CONSTRAINT fk_env_riesgo_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_env_riesgo_riesgo FOREIGN KEY (riesgo_id) REFERENCES cuidared.riesgo(riesgo_id),
  CONSTRAINT fk_env_riesgo_nivel FOREIGN KEY (nivel_riesgo_id) REFERENCES cuidared.nivel_riesgo(nivel_riesgo_id)
);
CREATE TABLE cuidared.alerta_envejeciente (
  alerta_envejeciente_id uuid NOT NULL DEFAULT gen_random_uuid(),
  envejeciente_id uuid NOT NULL,
  tipo_alerta_id smallint NOT NULL,
  prioridad_id smallint NOT NULL,
  descripcion text NOT NULL,
  origen character varying NOT NULL DEFAULT 'sistema'::character varying CHECK (origen::text = ANY (ARRAY['sistema'::character varying, 'manual'::character varying]::text[])),
  estado character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado::text = ANY (ARRAY['pendiente'::character varying, 'en_proceso'::character varying, 'resuelta'::character varying]::text[])),
  fecha_alerta timestamp with time zone NOT NULL DEFAULT now(),
  fecha_atencion timestamp with time zone,
  accion_tomada text,
  usuario_atendio_id uuid,
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT alerta_envejeciente_pkey PRIMARY KEY (alerta_envejeciente_id),
  CONSTRAINT fk_alerta_env_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_alerta_env_tipo_alerta FOREIGN KEY (tipo_alerta_id) REFERENCES cuidared.tipo_alerta(tipo_alerta_id),
  CONSTRAINT fk_alerta_env_prioridad FOREIGN KEY (prioridad_id) REFERENCES cuidared.prioridad(prioridad_id),
  CONSTRAINT fk_alerta_env_usuario_atendio FOREIGN KEY (usuario_atendio_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.visita (
  visita_id uuid NOT NULL DEFAULT gen_random_uuid(),
  fecha date NOT NULL,
  hora_inicio time without time zone,
  hora_fin time without time zone,
  razon character varying,
  estado character varying NOT NULL DEFAULT 'programada'::character varying CHECK (estado::text = ANY (ARRAY['programada'::character varying, 'en_curso'::character varying, 'completada'::character varying, 'cancelada'::character varying]::text[])),
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT visita_pkey PRIMARY KEY (visita_id)
);
CREATE TABLE cuidared.registro_visita (
  visita_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  autorizada_por_usuario_id uuid,
  CONSTRAINT registro_visita_pkey PRIMARY KEY (visita_id, usuario_id),
  CONSTRAINT fk_registro_visita_visita FOREIGN KEY (visita_id) REFERENCES cuidared.visita(visita_id),
  CONSTRAINT fk_registro_visita_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_registro_visita_autoriza FOREIGN KEY (autorizada_por_usuario_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.detalle_visita (
  visita_id uuid NOT NULL,
  envejeciente_id uuid NOT NULL,
  estado_general character varying CHECK (estado_general IS NULL OR (estado_general::text = ANY (ARRAY['estable'::character varying, 'requiere_atencion'::character varying, 'situacion_critica'::character varying]::text[]))),
  observacion text,
  CONSTRAINT detalle_visita_pkey PRIMARY KEY (visita_id, envejeciente_id),
  CONSTRAINT fk_detalle_visita_visita FOREIGN KEY (visita_id) REFERENCES cuidared.visita(visita_id),
  CONSTRAINT fk_detalle_visita_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id)
);
CREATE TABLE cuidared.tarea_agenda (
  tarea_agenda_id uuid NOT NULL DEFAULT gen_random_uuid(),
  cuidador_id bigint NOT NULL,
  envejeciente_id uuid NOT NULL,
  indicacion_medica_id uuid,
  prioridad_id smallint NOT NULL,
  usuario_creador_id uuid NOT NULL,
  titulo character varying NOT NULL,
  fecha_programada date NOT NULL,
  hora_programada time without time zone,
  estado character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado::text = ANY (ARRAY['pendiente'::character varying, 'en_progreso'::character varying, 'completada'::character varying, 'cancelada'::character varying]::text[])),
  requiere_evidencia boolean NOT NULL DEFAULT false,
  es_repetitiva boolean NOT NULL DEFAULT false,
  fecha_creacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_actualizacion timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT tarea_agenda_pkey PRIMARY KEY (tarea_agenda_id),
  CONSTRAINT fk_tarea_agenda_cuidador FOREIGN KEY (cuidador_id) REFERENCES cuidared.cuidador(cuidador_id),
  CONSTRAINT fk_tarea_agenda_envejeciente FOREIGN KEY (envejeciente_id) REFERENCES cuidared.envejeciente(envejeciente_id),
  CONSTRAINT fk_tarea_agenda_indicacion FOREIGN KEY (indicacion_medica_id) REFERENCES cuidared.indicacion_medica(indicacion_medica_id),
  CONSTRAINT fk_tarea_agenda_prioridad FOREIGN KEY (prioridad_id) REFERENCES cuidared.prioridad(prioridad_id),
  CONSTRAINT fk_tarea_agenda_creador FOREIGN KEY (usuario_creador_id) REFERENCES cuidared.usuario(usuario_id)
);
CREATE TABLE cuidared.evidencia (
  evidencia_id uuid NOT NULL DEFAULT gen_random_uuid(),
  tarea_agenda_id uuid NOT NULL,
  archivo_url text NOT NULL,
  observacion text,
  estado_validacion character varying NOT NULL DEFAULT 'pendiente'::character varying CHECK (estado_validacion::text = ANY (ARRAY['pendiente'::character varying, 'validada'::character varying, 'rechazada'::character varying]::text[])),
  fecha_registro timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT evidencia_pkey PRIMARY KEY (evidencia_id),
  CONSTRAINT fk_evidencia_tarea FOREIGN KEY (tarea_agenda_id) REFERENCES cuidared.tarea_agenda(tarea_agenda_id)
);
CREATE TABLE cuidared.notificacion (
  notificacion_id uuid NOT NULL DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL,
  cuenta_id bigint,
  plan_id smallint,
  alerta_envejeciente_id uuid,
  mensaje text NOT NULL,
  estado character varying NOT NULL DEFAULT 'no_leida'::character varying CHECK (estado::text = ANY (ARRAY['no_leida'::character varying, 'leida'::character varying, 'archivada'::character varying]::text[])),
  fecha_notificacion timestamp with time zone NOT NULL DEFAULT now(),
  fecha_lectura timestamp with time zone,
  CONSTRAINT notificacion_pkey PRIMARY KEY (notificacion_id),
  CONSTRAINT fk_notificacion_usuario FOREIGN KEY (usuario_id) REFERENCES cuidared.usuario(usuario_id),
  CONSTRAINT fk_notificacion_cuenta FOREIGN KEY (cuenta_id) REFERENCES cuidared.cuenta(cuenta_id),
  CONSTRAINT fk_notificacion_plan FOREIGN KEY (plan_id) REFERENCES cuidared.plan(plan_id),
  CONSTRAINT fk_notificacion_alerta FOREIGN KEY (alerta_envejeciente_id) REFERENCES cuidared.alerta_envejeciente(alerta_envejeciente_id)
);
CREATE TABLE cuidared.auditoria (
  auditoria_id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  tabla character varying NOT NULL,
  operacion character NOT NULL CHECK (operacion = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])),
  registro_id text NOT NULL,
  usuario_id uuid,
  fecha timestamp with time zone NOT NULL DEFAULT now(),
  datos_anteriores jsonb,
  datos_nuevos jsonb,
  CONSTRAINT auditoria_pkey PRIMARY KEY (auditoria_id)
);