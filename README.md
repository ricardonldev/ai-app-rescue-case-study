# Case study: rescuing an AI-generated booking app

**An app built by Lovable from a single prompt compiled, passed type checks and "worked". Its database let any user become admin and read customers' phone numbers.** This repo shows how it was found, proved, fixed and verified, including in production.

> **Demo case, not a client project.** On 28 Sep 2026 I asked [Lovable](https://lovable.dev) for a hair-salon booking app (the exact prompt is below) and took the result as is, exactly like a non-technical founder would.
> Built with Claude Code; directed, reviewed and tested by me.
> 🇪🇸 [Resumen en español al final](#en-español)

---

## The app
> *"Crea una app de reservas para una peluquería pequeña… Los clientes pueden registrarse, ver los servicios, elegir día y hora libres y reservar… La dueña tiene un panel de administración… Usa Supabase…"*

Lovable produced a TanStack Start + Supabase app: sign-up and login, services, a booking calendar, "my bookings" and an owner dashboard. It builds cleanly and has no TypeScript errors.

## 1 · Automatic scan: looks fine
My [diagnostic script](diagnostic/automatic-scan-before.md) (build, types, dependency audit, leaked secrets, RLS enabled on every table, deployment config) found **no real problems**. RLS was on everywhere and no secret keys were committed.

**Lesson: the scan checks the plumbing, not the business rules. Every real issue was found by reading the SQL by hand.**

## 2 · Manual review: 4 real problems

| # | Problem | Impact |
|---|---|---|
| 1 | `reclamar_duena()` ("claim owner") is a `SECURITY DEFINER` function that makes **the first user who calls it an admin**. Until the real owner clicks the button, any stranger who signs up can do it | Admin can read **every booking with customer names and phone numbers** (a GDPR problem) |
| 2 | Nothing in the database prevents **two bookings at the same time** | Double bookings |
| 3 | Opening hours, Sundays and closed days are only checked **in the browser** | Bookings at 03:00, on Sundays or on closed days |
| 4 | The `UPDATE` policy lets customers change **any column** of their booking | Move a booking onto someone else's slot, or set its status to anything |

## 3 · Proving it before claiming it
[`verification/verify.mjs`](verification/verify.mjs) loads the **untouched generated schema** into a real Postgres 18 ([PGlite](https://pglite.dev), no Docker needed), with Supabase-like roles and `auth.uid()`, and attacks it:

```
=== ESQUEMA ORIGINAL DE LOVABLE
✅ funciona      Uso normal: Ana reserva un martes a las 11:00
🔓 VULNERABLE    1. Un usuario cualquiera se hace admin y ve datos de clientes
                 se hizo admin y leyó: [{"nombre":"ana","telefono":"600000000"}]
🔓 VULNERABLE    2a. Reserva doble a la misma hora
🔓 VULNERABLE    2b. Reserva a las 03:00
🔓 VULNERABLE    3. El cliente cambia hora/estado de su reserva a lo que quiera
```

## 4 · The fix
One migration ([`migrations/0001_security_fix.sql`](migrations/0001_security_fix.sql)) plus a small frontend change (+17 / −36 lines):
- **Removed the self-promotion function.** The owner's admin role is granted once with SQL.
- **The database enforces the rules:** a `CHECK` on status, `fin > inicio`, and an **`EXCLUDE USING gist`** constraint that makes overlapping confirmed bookings impossible.
- **Customers no longer write to `bookings` directly.** They call `reservar()`, which checks the service, future date, Sundays, closed days, 30-minute slots and 10:00-20:00 hours (Europe/Madrid) and computes the end time, or `cancelar_reserva()` (only their own future bookings; the owner can cancel any).
- `REVOKE EXECUTE … FROM PUBLIC` on the new functions, which Postgres makes executable by everyone by default.

## 5 · Verified
```
=== CON EL ARREGLO
✅ funciona      Uso normal: Ana reserva un martes a las 11:00
🔒 bloqueado     1. Un usuario cualquiera se hace admin …   (function does not exist)
🔒 bloqueado     2a. Reserva doble a la misma hora           (Esa hora ya está reservada)
🔒 bloqueado     2b. Reserva a las 03:00                     (Esa hora está fuera del horario)
🔒 bloqueado     3. El cliente cambia hora/estado …          (permission denied)
✅ funciona      Uso normal: Ana cancela su reserva
🔒 bloqueado     Extra: domingo · día cerrado · acaba tras el cierre · 12:15 · cancelar reserva ajena
✅ funciona      Uso normal: la dueña ve y cancela reservas
```
Full outputs: [before](verification/output-before.txt) · [after](verification/output-after.txt).

- The frontend passes `tsc --noEmit` and the production build.
- **In production:** the migration was applied to the real Lovable Cloud database after checking it had no admins and no bookings (so no conflicting data). A catalog query confirmed the old function is gone, the new functions and constraints exist, and customers have no `INSERT`/`UPDATE` on `bookings`.

## Run it yourself
```bash
cd verification
npm install
node verify.mjs ../migrations          # original schema: vulnerable
node verify.mjs ../migrations --fix    # with the fix: blocked
```

## Out of scope (noted, not changed)
- 162 formatting warnings already present in the generated code.
- Opening hours live in two places (frontend and SQL function).
- Everything assumes the Europe/Madrid time zone.
- Supabase's default grants (`TRUNCATE`, `TRIGGER`…) on the table. They can't be reached through the API; revoking them would be extra hardening.

---

## En español
**Caso de demostración (no es un cliente):** Lovable generó una app de reservas para una peluquería a partir de una sola petición. Compilaba y funcionaba, pero **cualquier usuario registrado podía hacerse administrador y ver los teléfonos de los clientes**, se podían hacer reservas dobles o a las 3 de la mañana, y los clientes podían modificar sus reservas a su antojo.

- El análisis automático no detectó nada; todo salió de **revisar el SQL a mano**.
- Cada fallo se **demostró** en un Postgres real antes de arreglarlo.
- El arreglo son **una migración y 17 líneas** de frontend. Se verificó en local (13 comprobaciones) y **se aplicó en producción**.
- Hecho con Claude Code; dirigido, revisado y probado por mí.
