-- Roles
CREATE TYPE public.app_role AS ENUM ('admin', 'cliente');

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role
  )
$$;

CREATE POLICY "Ver mis roles" ON public.user_roles
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admin ve todos los roles" ON public.user_roles
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Perfiles
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  nombre text NOT NULL DEFAULT '',
  telefono text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Ver mi perfil" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "Admin ve perfiles" ON public.profiles
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Crear mi perfil" ON public.profiles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);
CREATE POLICY "Actualizar mi perfil" ON public.profiles
  FOR UPDATE TO authenticated USING (auth.uid() = id);

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, nombre)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'nombre', NEW.raw_user_meta_data->>'full_name', ''))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'cliente')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Servicios
CREATE TABLE public.services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre text NOT NULL,
  descripcion text,
  duracion_min integer NOT NULL DEFAULT 30,
  precio_cents integer NOT NULL DEFAULT 0,
  activo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.services TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.services TO authenticated;
GRANT ALL ON public.services TO service_role;
ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Servicios visibles" ON public.services
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Admin gestiona servicios" ON public.services
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Dias cerrados
CREATE TABLE public.closed_days (
  dia date PRIMARY KEY,
  motivo text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.closed_days TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.closed_days TO authenticated;
GRANT ALL ON public.closed_days TO service_role;
ALTER TABLE public.closed_days ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Dias cerrados visibles" ON public.closed_days
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Admin gestiona dias cerrados" ON public.closed_days
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Reservas
CREATE TABLE public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  service_id uuid NOT NULL REFERENCES public.services(id),
  inicio timestamptz NOT NULL,
  fin timestamptz NOT NULL,
  estado text NOT NULL DEFAULT 'confirmada',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bookings_inicio_idx ON public.bookings (inicio);
CREATE INDEX bookings_user_idx ON public.bookings (user_id);
GRANT SELECT, INSERT, UPDATE ON public.bookings TO authenticated;
GRANT ALL ON public.bookings TO service_role;
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Ver mis reservas" ON public.bookings
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admin ve todas las reservas" ON public.bookings
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Crear mis reservas" ON public.bookings
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Actualizar mis reservas" ON public.bookings
  FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admin actualiza reservas" ON public.bookings
  FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Huecos ocupados (sin exponer datos de clientes)
CREATE OR REPLACE FUNCTION public.slots_ocupados(_dia date)
RETURNS TABLE (inicio timestamptz, fin timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT b.inicio, b.fin
  FROM public.bookings b
  WHERE b.estado = 'confirmada'
    AND b.inicio >= _dia::timestamptz - interval '1 day'
    AND b.inicio < _dia::timestamptz + interval '2 days'
$$;
GRANT EXECUTE ON FUNCTION public.slots_ocupados(date) TO anon, authenticated;

-- La primera persona puede reclamar el rol de duena
CREATE OR REPLACE FUNCTION public.reclamar_duena()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
BEGIN
  IF _uid IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.user_roles WHERE role = 'admin') THEN
    RETURN public.has_role(_uid, 'admin');
  END IF;
  INSERT INTO public.user_roles (user_id, role) VALUES (_uid, 'admin')
  ON CONFLICT DO NOTHING;
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.reclamar_duena() TO authenticated;

INSERT INTO public.services (nombre, descripcion, duracion_min, precio_cents) VALUES
  ('Corte & peinado', 'Corte personalizado con lavado y peinado final.', 45, 2800),
  ('Color & balayage', 'Color completo o balayage con tratamiento de brillo.', 120, 6500),
  ('Tratamiento keratina', 'Alisado y nutrición profunda de larga duración.', 90, 9000),
  ('Recogido de fiesta', 'Peinado y recogido para eventos.', 60, 4000);
