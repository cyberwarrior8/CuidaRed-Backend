/* Contratos de perfil propio · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';

const name = z.string().trim().min(1).max(100);
const phone = z.string().trim().max(20).nullable().optional();
const editable = { nombres: name, apellidos: name, telefono: phone };

export const updateProfileSchema = z
  .strictObject(editable)
  .partial()
  .refine((value) => Object.keys(value).length > 0);

export function publicProfile(profile) {
  if (!profile) return null;
  return {
    id: profile.usuario_id,
    cedula: profile.cedula,
    nombres: profile.nombres,
    apellidos: profile.apellidos,
    correo: profile.correo,
    telefono: profile.telefono,
    estado: profile.estado,
  };
}
