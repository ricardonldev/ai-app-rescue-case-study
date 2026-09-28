# Informe de diagnóstico

Repositorio: `entrada/repo` · 2026-09-28

**Resumen:** 1 fallos · 5 avisos · 7 correctos

| Área | Estado | Comprobación |
|---|---|---|
| Proyecto | ✅ OK | package.json |
| Proyecto | ⚠️ AVISO | Gestor bun no instalado |
| Build | ✅ OK | Instalación (npm) |
| Build | ✅ OK | Build de producción |
| Calidad | ✅ OK | Tipos (tsc --noEmit) |
| Calidad | ⚠️ AVISO | Lint |
| Seguridad | ✅ OK | npm audit (producción) |
| Seguridad | ✅ OK | Secretos en el código |
| Seguridad | ⚠️ AVISO | Archivos .env en el repositorio |
| Supabase | ✅ OK | Row Level Security activado en todas las tablas |
| Supabase | ⚠️ AVISO | Políticas abiertas (using(true)) |
| Supabase | ❌ FALLO | service_role usada en el frontend |
| Despliegue | ⚠️ AVISO | Configuración de despliegue |

## Detalles

### ⚠️ Proyecto: Gestor bun no instalado

```
El repo usa bun, que no está en esta máquina; se usa npm en su lugar.
```

### ⚠️ Calidad: Lint

```
   9:30   error  Delete `␍`  prettier/prettier
  10:19   error  Delete `␍`  prettier/prettier
  11:96   error  Delete `␍`  prettier/prettier
  12:35   error  Delete `␍`  prettier/prettier
  13:33   error  Delete `␍`  prettier/prettier
  14:5    error  Delete `␍`  prettier/prettier
  15:4    error  Delete `␍`  prettier/prettier

✖ 6862 problems (6856 errors, 6 warnings)
  6855 errors and 0 warnings potentially fixable with the `--fix` option.
```

### ⚠️ Seguridad: Archivos .env en el repositorio

```
.env. En apps de Vite/Lovable la "anon key" es pública por diseño; lo grave sería una clave secreta (ver arriba).
```

### ⚠️ Supabase: Políticas abiertas (using(true))

```
Revisar si deben ser públicas:
services → "servicios visibles"
closed_days → "dias cerrados visibles"
```

### ❌ Supabase: service_role usada en el frontend

```
src\integrations\supabase\client.server.ts
```

### ⚠️ Despliegue: Configuración de despliegue

```
No hay configuración de despliegue en el repo.
```
