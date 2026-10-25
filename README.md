# CuidaRed-Backend

API de CuidaRed en **JavaScript / Node.js / Express**. Fase 1 en implementación; las fases 2–8 están pendientes. Consultar [plan](PLAN-DESARROLLO-BACKEND.md), [contexto](CONTEXTO-BACKEND.md), [guía](AGENTS.md) y [cambios](CAMBIOS-ACTUALES.md).

## Instalación y ejecución

Requiere Node.js 24.19 o una versión posterior de la rama 24 y npm. Desde este repositorio:

```powershell
npm ci
Copy-Item .env.example .env
# Completar .env con URL y clave publicable de Supabase y origen exacto del frontend.
npm run dev
```

`npm start` inicia sin vigilancia de archivos. JavaScript ESM se ejecuta directamente: no hay paso de compilación TypeScript. `GET /health/live` confirma que Express responde. Un servidor iniciado no demuestra que los servicios de persistencia estén configurados.

Usar solo `SUPABASE_PUBLISHABLE_KEY=sb_publishable_...`; nunca una clave secret/service_role. Producción exige HTTPS y orígenes explícitos. `.env` está ignorado. No activar confianza en proxies sin definir primero la topología de despliegue.

## Comprobaciones

```powershell
npm run lint
npm run format:check
npm test
```

`npm run format` aplica Prettier; `npm run test:watch` observa pruebas. Vitest/Supertest usan datos sintéticos y dependencias interceptadas: no requieren ni modifican una base real. Las pruebas HTTP abren puertos locales temporales.

## Estructura

- `src/app.js`, `src/server.js`: aplicación y arranque.
- `src/config/`, `src/lib/`: entorno, errores y auditoría técnica.
- `src/modules/access/`: sesión, perfil, validación y adaptador Supabase.
- `tests/`: pruebas `*.test.js`.
- `docs/`: contratos y propuestas de cambios; no se ejecutan automáticamente.

## Frontend y aprobación pendiente

En `../CuidaRed-Frontend`, completar `.env.local` según su `.env.example`, ejecutar `npm ci` y `npm run dev`. El acceso conectado usa SDK Supabase y Bearer tokens para Express. El prototipo solo se habilita con `VITE_AUTH_MODE=demo` en desarrollo; no otorga permisos reales.

La [persistencia de fase 1](docs/VERIFICACION-FASE-1-SUPABASE.md) fue aprobada y aplicada el 25/10/2026 como `20261025041944_fase_1_acceso`. `cuidared_api` es el único esquema configurado para PostgREST; las tablas permanecen privadas. Quedan pendientes configuración Auth y pruebas con usuarios reales, que requieren revisión aparte. No existe un fallback de datos simulados si faltan dependencias.

Las pruebas del acceso frontend se ejecutan desde su repositorio con `npx playwright test --config playwright.access.config.ts`; requieren Chromium de Playwright y no contactan Auth real. El resto de las capacidades se incorporará en su fase, después de resolver las decisiones de negocio abiertas.
