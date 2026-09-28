-- Seguridad e integridad de las reservas.
--
-- 1. Nadie puede auto-asignarse el rol de administradora.
-- 2. La base de datos impide reservas solapadas, fuera de horario, en días cerrados o en el pasado.
-- 3. Los clientes ya no escriben directamente en "bookings": reservan y cancelan con funciones
--    que validan cada caso, así que no pueden mover ni alterar una reserva existente.
--
-- ANTES DE APLICAR: comprueba quién tiene ya el rol de admin (por si alguien lo reclamó):
--   SELECT u.email FROM public.user_roles r JOIN auth.users u ON u.id = r.user_id WHERE r.role = 'admin';
-- Si hay reservas solapadas, la restricción del punto 2 fallará: resuélvelas antes (cancela una).
--
-- DESPUÉS DE APLICAR: da el rol de admin a la cuenta real de la dueña (una sola vez):
--   INSERT INTO public.user_roles (user_id, role)
--   SELECT id, 'admin' FROM auth.users WHERE email = 'correo-de-la-duena@ejemplo.com'
--   ON CONFLICT DO NOTHING;

-- 1 ------------------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.reclamar_duena();

-- 2 ------------------------------------------------------------------------------------------
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_estado_valido CHECK (estado IN ('confirmada', 'cancelada')),
  ADD CONSTRAINT bookings_fin_despues_de_inicio CHECK (fin > inicio),
  ADD CONSTRAINT bookings_sin_solapes
    EXCLUDE USING gist (tstzrange(inicio, fin, '[)') WITH &&) WHERE (estado = 'confirmada');

-- 3 ------------------------------------------------------------------------------------------
REVOKE INSERT, UPDATE ON public.bookings FROM authenticated;
DROP POLICY IF EXISTS "Crear mis reservas" ON public.bookings;
DROP POLICY IF EXISTS "Actualizar mis reservas" ON public.bookings;
DROP POLICY IF EXISTS "Admin actualiza reservas" ON public.bookings;

-- Horario del salón (mismo que src/lib/salon.ts): 10:00-20:00, huecos de 30 min, domingo cerrado.
CREATE OR REPLACE FUNCTION public.reservar(_service_id uuid, _inicio timestamptz)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _dur integer;
  _fin timestamptz;
  _ini_local timestamp;
  _fin_local timestamp;
  _id uuid;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Necesitas iniciar sesión para reservar' USING ERRCODE = '42501';
  END IF;

  SELECT duracion_min INTO _dur FROM public.services WHERE id = _service_id AND activo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ese servicio no está disponible' USING ERRCODE = 'P0001';
  END IF;

  _fin := _inicio + make_interval(mins => _dur);
  _ini_local := _inicio AT TIME ZONE 'Europe/Madrid';
  _fin_local := _fin AT TIME ZONE 'Europe/Madrid';

  IF _inicio <= now() THEN
    RAISE EXCEPTION 'Esa hora ya ha pasado' USING ERRCODE = 'P0001';
  END IF;
  IF extract(isodow FROM _ini_local) = 7
     OR EXISTS (SELECT 1 FROM public.closed_days WHERE dia = _ini_local::date) THEN
    RAISE EXCEPTION 'La peluquería está cerrada ese día' USING ERRCODE = 'P0001';
  END IF;
  IF extract(minute FROM _ini_local)::int % 30 <> 0 OR extract(second FROM _ini_local) <> 0
     OR _ini_local::time < time '10:00'
     OR _fin_local::date <> _ini_local::date OR _fin_local::time > time '20:00' THEN
    RAISE EXCEPTION 'Esa hora está fuera del horario' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.bookings (user_id, service_id, inicio, fin)
  VALUES (_uid, _service_id, _inicio, _fin)
  RETURNING id INTO _id;
  RETURN _id;
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Esa hora ya está reservada' USING ERRCODE = 'P0001';
END;
$$;

-- El cliente cancela sus reservas futuras; la dueña puede cancelar cualquiera.
CREATE OR REPLACE FUNCTION public.cancelar_reserva(_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  UPDATE public.bookings
  SET estado = 'cancelada'
  WHERE id = _id
    AND estado = 'confirmada'
    AND (
      (user_id = _uid AND inicio > now())
      OR public.has_role(_uid, 'admin')
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se puede cancelar esa reserva' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- Las funciones son ejecutables por PUBLIC por defecto: se restringe a usuarios con sesión.
REVOKE EXECUTE ON FUNCTION public.reservar(uuid, timestamptz) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.cancelar_reserva(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancelar_reserva(uuid) TO authenticated;
