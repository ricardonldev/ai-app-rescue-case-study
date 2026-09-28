// Reproduce the security problems of the Lovable-generated schema on a real Postgres (PGlite),
// then apply the fix migration and check they are blocked while normal use still works.
// Usage: node verify.mjs ../migrations          -> only the original schema (expects vulnerabilities)
//        node verify.mjs ../migrations --fix    -> original + 0001 fix
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const repo = process.argv[2];
const withFix = process.argv.includes('--fix');
const migDir = repo; // folder with the .sql migrations
const migs = readdirSync(migDir).filter((f) => f.endsWith('.sql')).sort()
  .filter((f) => withFix || f.startsWith('0000'));

const db = new PGlite();
// Minimal stand-in for what Supabase provides: roles, auth.users, auth.uid().
await db.exec(`
  CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users (id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}');
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
    $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
  GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
`);
for (const f of migs) await db.exec(readFileSync(join(migDir, f), 'utf8'));

const U = {
  duena: '00000000-0000-0000-0000-00000000000d',
  ana: '00000000-0000-0000-0000-0000000000a1',
  intruso: '00000000-0000-0000-0000-0000000000ff',
};
for (const [name, id] of Object.entries(U)) {
  await db.query(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, $2, $3)`,
    [id, `${name}@ejemplo.com`, JSON.stringify({ nombre: name })]);
}
await db.query(`UPDATE public.profiles SET telefono = '600000000' WHERE id = $1`, [U.ana]);

async function as(uid, sql, params = []) {
  await db.exec('BEGIN');
  try {
    await db.exec(`SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '${uid}', true);`);
    const r = await db.query(sql, params);
    await db.exec('COMMIT');
    return { ok: true, rows: r.rows };
  } catch (e) {
    await db.exec('ROLLBACK');
    return { ok: false, error: e.message };
  }
}

const svc = (await db.query(`SELECT id, duracion_min FROM public.services WHERE nombre = 'Corte & peinado'`)).rows[0];
// Next Tuesday 11:00 Madrid time, as the browser would send it.
const nextTue = (() => { const d = new Date(); d.setDate(d.getDate() + ((9 - d.getDay()) % 7 || 7)); return d.toISOString().slice(0, 10); })();
const at = (hhmm, day = nextTue) => (db.query(`SELECT (($1 || ' ' || $2)::timestamp AT TIME ZONE 'Europe/Madrid') AS t`, [day, hhmm]));
const t1100 = (await at('11:00')).rows[0].t;
const t1100fin = new Date(new Date(t1100).getTime() + svc.duracion_min * 60000);
const t0300 = (await at('03:00')).rows[0].t;

const results = [];
const check = (name, vulnerable, detail) => results.push({ name, vulnerable, detail });
const book = (uid, inicio, fin) => withFix
  ? as(uid, `SELECT public.reservar($1, $2) AS id`, [svc.id, inicio])
  : as(uid, `INSERT INTO public.bookings (user_id, service_id, inicio, fin) VALUES ($1,$2,$3,$4) RETURNING id`,
      [uid, svc.id, inicio, fin]);

// --- Normal use must work in both versions
const anaBooking = await book(U.ana, t1100, t1100fin);
results.push({ name: 'Uso normal: Ana reserva un martes a las 11:00', vulnerable: !anaBooking.ok, detail: anaBooking.error || 'OK' });
const anaId = anaBooking.rows?.[0]?.id;

// --- 1. Anyone can become admin
const claim = withFix
  ? await as(U.intruso, `SELECT public.reclamar_duena() AS ok`)
  : await as(U.intruso, `SELECT public.reclamar_duena() AS ok`);
const intrusoIsAdmin = claim.ok && claim.rows[0].ok === true;
const leak = await as(U.intruso, `SELECT p.nombre, p.telefono FROM public.bookings b JOIN public.profiles p ON p.id = b.user_id`);
check('1. Un usuario cualquiera se hace admin y ve datos de clientes',
  intrusoIsAdmin && leak.ok && leak.rows.length > 0,
  intrusoIsAdmin ? `se hizo admin y leyó: ${JSON.stringify(leak.rows)}` : (claim.error || 'no pudo hacerse admin'));

// --- 2. Double booking and impossible bookings
const dup = await book(U.intruso, t1100, t1100fin);
check('2a. Reserva doble a la misma hora', dup.ok, dup.error || 'se aceptó la reserva duplicada');
const night = await book(U.intruso, t0300, new Date(new Date(t0300).getTime() + 45 * 60000));
check('2b. Reserva a las 03:00', night.ok, night.error || 'se aceptó');

// --- 3. Editing an existing booking to anything
if (anaId) {
  const edit = await as(U.ana, `UPDATE public.bookings SET inicio = inicio - interval '8 hours', estado = 'lo-que-sea' WHERE id = $1 RETURNING estado`, [anaId]);
  check('3. El cliente cambia hora/estado de su reserva a lo que quiera', edit.ok && edit.rows.length > 0, edit.error || 'se aceptó el cambio');
  const cancel = withFix
    ? await as(U.ana, `SELECT public.cancelar_reserva($1)`, [anaId])
    : await as(U.ana, `UPDATE public.bookings SET estado = 'cancelada' WHERE id = $1 RETURNING id`, [anaId]);
  results.push({ name: 'Uso normal: Ana cancela su reserva', vulnerable: !cancel.ok, detail: cancel.error || 'OK' });
}

if (withFix) {
  // Extra cases only meaningful with the fix in place.
  const nextSun = new Date(new Date(nextTue).getTime() + 5 * 86400000).toISOString().slice(0, 10);
  const sun = (await at('11:00', nextSun)).rows[0].t;
  const r1 = await as(U.ana, `SELECT public.reservar($1, $2)`, [svc.id, sun]);
  check('Extra: reserva en domingo', r1.ok, r1.error || 'se aceptó');

  await db.query(`INSERT INTO public.closed_days (dia, motivo) VALUES ($1, 'vacaciones')`, [nextTue]);
  const r2 = await as(U.ana, `SELECT public.reservar($1, $2)`, [svc.id, (await at('16:00')).rows[0].t]);
  check('Extra: reserva en día marcado como cerrado', r2.ok, r2.error || 'se aceptó');
  await db.query(`DELETE FROM public.closed_days WHERE dia = $1`, [nextTue]);

  const r3 = await as(U.ana, `SELECT public.reservar($1, $2)`, [svc.id, (await at('19:30')).rows[0].t]);
  check('Extra: servicio de 45 min a las 19:30 (acabaría tras el cierre)', r3.ok, r3.error || 'se aceptó');

  const r4 = await as(U.ana, `SELECT public.reservar($1, $2)`, [svc.id, (await at('12:15')).rows[0].t]);
  check('Extra: hora que no es un hueco de 30 min (12:15)', r4.ok, r4.error || 'se aceptó');

  const b = await as(U.ana, `SELECT public.reservar($1, $2) AS id`, [svc.id, (await at('17:00')).rows[0].t]);
  const r5 = await as(U.intruso, `SELECT public.cancelar_reserva($1)`, [b.rows?.[0]?.id]);
  check('Extra: otro usuario cancela la reserva de Ana', r5.ok, r5.error || 'se aceptó');

  await db.query(`INSERT INTO public.user_roles (user_id, role) VALUES ($1, 'admin')`, [U.duena]);
  const r6 = await as(U.duena, `SELECT count(*)::int AS n FROM public.bookings`);
  results.push({ name: 'Uso normal: la dueña (asignada por SQL) ve las reservas', vulnerable: !(r6.ok && r6.rows[0].n > 0), detail: r6.error || `ve ${r6.rows[0].n} reservas` });
  const r7 = await as(U.duena, `SELECT public.cancelar_reserva($1)`, [b.rows?.[0]?.id]);
  results.push({ name: 'Uso normal: la dueña cancela una reserva', vulnerable: !r7.ok, detail: r7.error || 'OK' });
}

console.log(`\n=== ${withFix ? 'CON EL ARREGLO' : 'ESQUEMA ORIGINAL DE LOVABLE'} (${migs.join(', ')})`);
for (const r of results) {
  const normal = r.name.startsWith('Uso normal');
  const icon = normal ? (r.vulnerable ? '❌ ROTO' : '✅ funciona') : (r.vulnerable ? '🔓 VULNERABLE' : '🔒 bloqueado');
  console.log(`${icon}  ${r.name}\n      ${r.detail}`);
}
