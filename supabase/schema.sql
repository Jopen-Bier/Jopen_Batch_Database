--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: brew_plan_group; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.brew_plan_group AS ENUM (
    'jk',
    'wp_60hl',
    'wp_120hl',
    'wp_320hl'
);


--
-- Name: admin_get_last_logins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_last_logins() RETURNS TABLE(id uuid, last_login_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;
  return query select au.id, au.last_sign_in_at from auth.users au;
end;
$$;


--
-- Name: can_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_delete(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_delete
  );
$$;


--
-- Name: can_edit(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_edit(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_edit
  );
$$;


--
-- Name: can_view(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_view(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_view
  );
$$;


--
-- Name: current_role_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_role_id() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select role_id from users where id = auth.uid() and is_active;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from users u join roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active and r.name = 'admin'
  );
$$;


--
-- Name: log_brew_planning_wijziging(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_brew_planning_wijziging() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
begin
  if (TG_OP = 'INSERT') then
    insert into brew_planning_geschiedenis (brew_planning_id, actie, na, gewijzigd_door)
    values (new.id, 'created', to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'UPDATE') then
    insert into brew_planning_geschiedenis (brew_planning_id, actie, voor, na, gewijzigd_door)
    values (new.id, 'updated', to_jsonb(old), to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'DELETE') then
    insert into brew_planning_geschiedenis (brew_planning_id, actie, voor, gewijzigd_door)
    values (old.id, 'deleted', to_jsonb(old), auth.uid());
    return old;
  end if;
  return null;
end;
$$;


--
-- Name: product_sheet_calculated_color(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_calculated_color(p_recipe_id bigint) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  select round(
    coalesce(sum(ri.hoeveelheid * ri.kleur_ebc * 0.08), 0) / nullif(r.brouwsel_hl, 0) + 1.75
  , 2)
  from recipes r
  left join recipe_ingredients ri on ri.recipe_id = r.id and ri.rol = 'hoofdmout'
  where r.id = p_recipe_id
  group by r.brouwsel_hl
$$;


--
-- Name: product_sheet_relevant_hash(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid) RETURNS text
    LANGUAGE sql STABLE
    AS $$
  select md5(
    coalesce(s.origineel_extract::text,'') || '|' || coalesce(s.origineel_extract_tol,'') || '|' ||
    coalesce(s.rest_extract::text,'') || '|' || coalesce(s.rest_extract_tol,'') || '|' ||
    coalesce(s.alcohol::text,'') || '|' || coalesce(s.alcohol_tol,'') || '|' ||
    coalesce(s.bitterheid::text,'') || '|' || coalesce(s.bitterheid_tol,'') || '|' ||
    coalesce(product_sheet_calculated_color(r.id)::text,'') || '|' || coalesce(s.kleur_tol,'') || '|' ||
    coalesce(s.ph::text,'') || '|' || coalesce(s.ph_tol,'') || '|' ||
    coalesce(s.troebeling_lab::text,'') || '|' || coalesce(s.troebeling_lab_tol,'') || '|' ||
    coalesce(s.co2_fles::text,'') || '|' || coalesce(s.co2_fles_tol,'') || '|' ||
    coalesce(s.co2_can::text,'') || '|' || coalesce(s.co2_can_tol,'') || '|' ||
    coalesce(s.co2_fust::text,'') || '|' || coalesce(s.co2_fust_tol,'') || '|' ||
    coalesce(s.headspace_o2::text,'') || '|' || coalesce(s.headspace_o2_tol,'') || '|' ||
    coalesce(s.dissolved_o2::text,'') || '|' || coalesce(s.dissolved_o2_tol,'') || '|' ||
    coalesce(r.smaakomschrijving,'') || '|' ||
    coalesce(array_to_string(r.smaak_keywords, ','),'') || '|' ||
    coalesce(r.kleur_vrije_tekst,'') || '|' ||
    coalesce(r.aanbevolen_schenktemperatuur::text,'') || '|' ||
    coalesce((
      select string_agg(ri.ingredient_id::text || ':' || coalesce(ri.hoeveelheid::text,'') || ':' || coalesce(ri.eenheid,'') || ':' || ri.rol, ',' order by ri.ingredient_id, ri.rol)
      from recipe_ingredients ri where ri.recipe_id = r.id
    ), '') || '|' ||
    coalesce((
      select string_agg(coalesce(i.ingredient_declaratie,'') || ':' || coalesce(i.allergenen, '[]'::jsonb)::text, ',' order by i.id)
      from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
      where ri2.recipe_id = r.id
    ), '')
  )
  from recipes r
  left join recipe_specificaties s on s.recipe_id = r.id
  where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
$$;


--
-- Name: product_sheet_relevant_recipe_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
  select id from recipes
  where recipe_group_id = p_recipe_group_id
  order by versie_major desc, versie_minor desc
  limit 1
$$;


--
-- Name: set_gewijzigd_op(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_gewijzigd_op() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.gewijzigd_op = now();
  return new;
end;
$$;


--
-- Name: set_ingredients_gewijzigd_op(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_ingredients_gewijzigd_op() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.gewijzigd_op = now();
  return new;
end;
$$;


--
-- Name: set_last_login(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_last_login() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update users set last_login_at = now() where id = auth.uid();
end;
$$;


--
-- Name: water_instellingen_log(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_instellingen_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into water_instellingen_historie (geldig_vanaf, gewijzigd_door, gegevens)
    values (new.gewijzigd_op, new.gewijzigd_door, to_jsonb(new));
  return new;
end;
$$;


--
-- Name: water_instellingen_stempel(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_instellingen_stempel() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.gewijzigd_op := now();
  new.gewijzigd_door := auth.uid();
  return new;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batches (
    id bigint NOT NULL,
    batchnummer text NOT NULL,
    recipe_id bigint NOT NULL,
    aantal_brouwsels numeric,
    brouwdatum date,
    status text DEFAULT 'gepland'::text NOT NULL,
    operator text,
    gist_temp_start numeric,
    gist_temp_max numeric,
    giststam text,
    gist_gerehydrateerd boolean,
    gist_gewicht numeric,
    gist_bij_1e_brouwsel boolean,
    gist_geent_op date,
    gist_door text,
    gist_programma_aan boolean,
    datum_orderpicken date,
    "extract" numeric,
    alcohol numeric,
    bitterheid numeric,
    kleur numeric,
    ph numeric,
    glt_leeg boolean,
    totaal_eindvolume numeric,
    created_at timestamp with time zone DEFAULT now(),
    naam text,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    aangemaakt_door uuid,
    CONSTRAINT batches_status_check CHECK ((status = ANY (ARRAY['gepland'::text, 'brouwen'::text, 'vergisting'::text, 'verwerking'::text, 'afvullen'::text, 'afgerond'::text])))
);


--
-- Name: batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batches ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: brew_capacity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_capacity (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    capacity_group text NOT NULL,
    iso_year integer NOT NULL,
    week_number integer NOT NULL,
    max_brouwsels numeric DEFAULT 0 NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brew_capacity_capacity_group_check CHECK ((capacity_group = ANY (ARRAY['jk'::text, 'wp'::text]))),
    CONSTRAINT brew_capacity_week_number_check CHECK (((week_number >= 1) AND (week_number <= 53)))
);


--
-- Name: brew_planning; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_group public.brew_plan_group NOT NULL,
    iso_year integer NOT NULL,
    week_number integer NOT NULL,
    recipe_id bigint,
    aantal_brouwsels numeric DEFAULT 1 NOT NULL,
    hl numeric,
    prio boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    notities text,
    aangemaakt_door uuid,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    bijgewerkt_op timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid,
    CONSTRAINT brew_planning_week_number_check CHECK (((week_number >= 1) AND (week_number <= 53)))
);


--
-- Name: brew_planning_geschiedenis; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning_geschiedenis (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_planning_id uuid NOT NULL,
    actie text NOT NULL,
    voor jsonb,
    na jsonb,
    gewijzigd_door uuid,
    gewijzigd_op timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brew_planning_geschiedenis_actie_check CHECK ((actie = ANY (ARRAY['created'::text, 'updated'::text, 'deleted'::text])))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    last_login_at timestamp with time zone,
    role_id integer
);


--
-- Name: brew_planning_geschiedenis_verrijkt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.brew_planning_geschiedenis_verrijkt WITH (security_invoker='true') AS
 SELECT g.id,
    g.brew_planning_id,
    g.actie,
    g.voor,
    g.na,
    g.gewijzigd_door,
    u.name AS gewijzigd_door_naam,
    g.gewijzigd_op
   FROM (public.brew_planning_geschiedenis g
     LEFT JOIN public.users u ON ((u.id = g.gewijzigd_door)))
  ORDER BY g.gewijzigd_op DESC;


--
-- Name: brew_planning_splits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning_splits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_planning_id uuid NOT NULL,
    recipe_id bigint NOT NULL,
    recipe_group_id uuid,
    hl numeric NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brew_planning_wijzigingen; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.brew_planning_wijzigingen AS
 SELECT h.id,
    h.brew_planning_id,
    h.actie,
    ((h.voor ->> 'week_number'::text))::integer AS week_voor,
    ((h.na ->> 'week_number'::text))::integer AS week_na,
    ((h.voor ->> 'iso_year'::text))::integer AS jaar_voor,
    ((h.na ->> 'iso_year'::text))::integer AS jaar_na,
    ((h.na ->> 'aantal_brouwsels'::text))::numeric AS brouwsels_na,
    ((h.na ->> 'prio'::text))::boolean AS prio_na,
    (h.na ->> 'plan_group'::text) AS plan_group_na,
    h.gewijzigd_door,
    g.name AS gewijzigd_door_naam,
    h.gewijzigd_op
   FROM (public.brew_planning_geschiedenis h
     LEFT JOIN public.users g ON ((g.id = h.gewijzigd_door)));


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    label text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: grondstof_lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grondstof_lots (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    leverancier text,
    lotcode text,
    ontvangstdatum date DEFAULT CURRENT_DATE NOT NULL,
    hoeveelheid_ontvangen numeric NOT NULL,
    eenheid text,
    aantal_colli text,
    locatie text,
    ontvangstcontrole boolean DEFAULT false NOT NULL,
    ingangscontrole boolean DEFAULT false NOT NULL,
    tht_datum date,
    alpha_pct numeric,
    status text DEFAULT 'actief'::text NOT NULL,
    document_pad text,
    notitie text,
    aangemaakt_door uuid,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    ontvangen_door uuid,
    CONSTRAINT grondstof_lots_status_check CHECK ((status = ANY (ARRAY['actief'::text, 'leeg'::text, 'afgesloten'::text])))
);


--
-- Name: grondstof_lots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.grondstof_lots ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.grondstof_lots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: hop_utilisatie_curve; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hop_utilisatie_curve (
    kooktijd_min integer NOT NULL,
    rendement_pct numeric NOT NULL
);


--
-- Name: ingredient_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    uses_alpha_pct boolean DEFAULT false NOT NULL,
    uses_extract_pct boolean DEFAULT false NOT NULL,
    uses_gistfactor boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_categories ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredient_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredient_declaraties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_declaraties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    naam text NOT NULL,
    is_geen_declaratie boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_documenten; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_documenten (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    bestandsnaam text NOT NULL,
    storage_path text NOT NULL,
    grootte_bytes bigint,
    revisiedatum date NOT NULL,
    geupload_door uuid,
    geupload_op timestamp with time zone DEFAULT now() NOT NULL,
    document_type_id uuid NOT NULL,
    status text DEFAULT 'actief'::text NOT NULL,
    CONSTRAINT ingredient_documenten_status_check CHECK ((status = ANY (ARRAY['actief'::text, 'gearchiveerd'::text])))
);


--
-- Name: ingredient_documenten_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documenten ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredient_documenten_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_ingredients (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    ingredient_id bigint,
    rol text NOT NULL,
    hoeveelheid numeric,
    eenheid text,
    tijdstip text,
    volgorde integer,
    notitie text,
    hdt integer,
    alpha_pct numeric,
    kleur_ebc numeric,
    alles_in_brouwsel_1 boolean DEFAULT false NOT NULL,
    CONSTRAINT recipe_ingredients_rol_check CHECK ((rol = ANY (ARRAY['hoofdmout'::text, 'hopgift_kook'::text, 'dry_hop'::text, 'toegift_brouwerij'::text, 'toegift_kelder'::text, 'gist'::text])))
);


--
-- Name: ingredient_gebruik_counts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ingredient_gebruik_counts WITH (security_invoker='true') AS
 SELECT ingredient_id,
    count(DISTINCT recipe_id) AS aantal_recepten
   FROM public.recipe_ingredients
  WHERE (ingredient_id IS NOT NULL)
  GROUP BY ingredient_id;


--
-- Name: ingredient_revisies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_revisies (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    versie_major integer NOT NULL,
    versie_minor integer NOT NULL,
    datum date DEFAULT CURRENT_DATE NOT NULL,
    door text,
    wijziging text,
    gebruiker_id uuid,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_revisies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisies ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ingredient_revisies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredients (
    id bigint NOT NULL,
    naam text NOT NULL,
    categorie text,
    eenheid text,
    prijs numeric,
    extract_pct numeric,
    alpha_pct numeric,
    gistfactor numeric,
    leverancier text,
    status text DEFAULT 'actief'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    aangemaakt_door uuid,
    gewijzigd_door uuid,
    gewijzigd_op timestamp with time zone DEFAULT now() NOT NULL,
    category_id bigint,
    versie_major integer DEFAULT 1 NOT NULL,
    versie_minor integer DEFAULT 0 NOT NULL,
    ingredient_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    versie_status text DEFAULT 'huidig'::text NOT NULL,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    leverancier_2 text,
    prijs_2 numeric,
    eenheid_prijs_1 text,
    eenheid_prijs_2 text,
    kleur_ebc numeric,
    allergenen jsonb,
    ingredient_declaratie text,
    bewaartemperatuur text,
    houdbaarheid numeric,
    houdbaarheid_na_openen numeric,
    dichtheid numeric,
    alcohol_pct numeric,
    houdbaarheid_eenheid text,
    houdbaarheid_na_openen_eenheid text,
    leverancier_3 text,
    prijs_3 numeric,
    eenheid_prijs_3 text,
    prijs_per_kg numeric,
    prijs_per_kg_2 numeric,
    prijs_per_kg_3 numeric,
    minimum_voorraad numeric,
    CONSTRAINT ingredients_categorie_check CHECK ((categorie = ANY (ARRAY['graan'::text, 'hop'::text, 'gist'::text, 'additief'::text]))),
    CONSTRAINT ingredients_houdbaarheid_eenheid_check CHECK (((houdbaarheid_eenheid IS NULL) OR (houdbaarheid_eenheid = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_houdbaarheid_na_openen_eenheid_check CHECK (((houdbaarheid_na_openen_eenheid IS NULL) OR (houdbaarheid_na_openen_eenheid = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_status_check CHECK ((status = ANY (ARRAY['concept'::text, 'actief'::text, 'uitfaserend'::text]))),
    CONSTRAINT ingredients_versie_status_check CHECK ((versie_status = ANY (ARRAY['huidig'::text, 'gearchiveerd'::text])))
);


--
-- Name: COLUMN ingredients.prijs_per_kg; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.prijs_per_kg IS 'Prijs per kg voor Supplier #1, los van prijs/eenheid_prijs_1 (die de doseereenheid volgt).';


--
-- Name: COLUMN ingredients.prijs_per_kg_2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.prijs_per_kg_2 IS 'Prijs per kg voor Supplier #2.';


--
-- Name: COLUMN ingredients.prijs_per_kg_3; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.prijs_per_kg_3 IS 'Prijs per kg voor Supplier #3.';


--
-- Name: COLUMN ingredients.minimum_voorraad; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.minimum_voorraad IS 'Ondergrens voor de Stock overview-pagina ("bijna leeg"-signaal). Eenheid wordt afgeleid uit ingredients.eenheid (het deel vóór een eventuele ''/'', dus g/hl -> g) -- geen apart eenheid-veld nodig.';


--
-- Name: ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: permission_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permission_modules (
    module_key text NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: product_sheet_revisies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_sheet_revisies (
    id bigint NOT NULL,
    product_sheet_id bigint NOT NULL,
    versie integer NOT NULL,
    recipe_versie_major integer,
    recipe_versie_minor integer,
    datum date DEFAULT CURRENT_DATE NOT NULL,
    door text,
    wijzigingen text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: product_sheet_revisies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisies ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.product_sheet_revisies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: product_sheets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_sheets (
    id bigint NOT NULL,
    recipe_group_id uuid NOT NULL,
    status text DEFAULT 'actief'::text NOT NULL,
    huidige_versie integer DEFAULT 1 NOT NULL,
    excise_tax_category text,
    vat_gerijpt_hl numeric,
    vat_type text,
    vat_dagen numeric,
    energie_kj numeric,
    energie_kcal numeric,
    vet_g numeric,
    koolhydraten_g numeric,
    eiwit_g numeric,
    zout_g numeric,
    opmerkingen text,
    sync_snapshot jsonb,
    bijgewerkt_obv_versie_major integer,
    bijgewerkt_obv_versie_minor integer,
    bijgewerkt_op timestamp with time zone,
    bijgewerkt_door uuid,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    aangemaakt_door uuid
);


--
-- Name: COLUMN product_sheets.sync_snapshot; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_sheets.sync_snapshot IS 'Snapshot van alleen de label-relevante receptvelden bij de laatste Update, voor de rood/groen sync-status. Vergelijk live tegen dezelfde velden, niet tegen recipes.versie_major/minor als geheel.';


--
-- Name: product_sheet_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.product_sheet_status WITH (security_invoker='true') AS
 SELECT id AS product_sheet_id,
    recipe_group_id,
    status,
    huidige_versie,
    bijgewerkt_op,
    bijgewerkt_obv_versie_major,
    bijgewerkt_obv_versie_minor,
    (sync_snapshot ->> 'hash'::text) AS opgeslagen_hash,
    public.product_sheet_relevant_hash(recipe_group_id) AS huidige_hash,
    COALESCE(((sync_snapshot ->> 'hash'::text) = public.product_sheet_relevant_hash(recipe_group_id)), false) AS in_sync
   FROM public.product_sheets ps
  WHERE (status <> 'gearchiveerd'::text);


--
-- Name: product_sheets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.product_sheets ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.product_sheets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_brouwspecificaties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_brouwspecificaties (
    recipe_id bigint NOT NULL,
    kamers_mashfilter numeric,
    walsenmolen text,
    beslag_dikte numeric,
    volume_kook numeric,
    wortvoorkoeler_temp numeric,
    eindvolume_brouwsel numeric,
    gewenste_verdamping numeric,
    intensiteit_koken numeric,
    whirlpool_rust numeric,
    lauterfactor numeric,
    recept_naam_software text,
    stort_special_bin_kg numeric,
    naam_special_bin text,
    mash_inmaischen_temp numeric,
    mash_inmaischen_tijd numeric,
    mash_verhogen1_temp numeric,
    mash_verhogen1_tijd numeric,
    mash_verhogen2_temp numeric,
    mash_verhogen2_tijd numeric,
    mash_verhogen3_temp numeric,
    mash_verhogen3_tijd numeric,
    mash_verhogen4_temp numeric,
    mash_verhogen4_tijd numeric,
    mash_uitmaischen_temp numeric,
    mash_uitmaischen_tijd numeric,
    cumm_sparging_vol numeric,
    verwacht_extract_begin_kook numeric,
    volume_water_additie_terugkoeling numeric,
    sparging_1e numeric,
    sparging_2e numeric,
    sparging_3e numeric,
    sparging_4e numeric,
    eerste_afloop numeric,
    spoelwater numeric,
    spoel_afloop numeric,
    totaal_gefiltreerd_volume numeric,
    inmaischen_zuur_l numeric,
    inmaischen_tannines_l numeric,
    koken_zuur_l numeric,
    inline_sparge_zuur_l numeric,
    maischwater numeric,
    ph_maische text,
    ph_start_koken text,
    ph_eind_koken text,
    beluchting numeric,
    stamwort_correctie_brouwhuis numeric
);


--
-- Name: recipe_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_comments (
    recipe_id bigint NOT NULL,
    comments text[]
);


--
-- Name: recipe_fermentatie; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_fermentatie (
    recipe_id bigint NOT NULL,
    pitching_temp numeric,
    main_ferm_temp numeric,
    t_release numeric,
    temp_dry_warm numeric,
    extract_dry_warm_1 numeric,
    extract_dry_warm_2 numeric,
    extract_dry_warm_3 numeric,
    vergistingstijd numeric,
    lagertijd numeric,
    lager_temp numeric,
    pasteurisatie numeric,
    troebeling_na_sep numeric,
    bier_risico text,
    bier_status text,
    pitching_temp_tol text,
    main_ferm_temp_tol text,
    t_release_tol text,
    temp_dry_warm_tol text,
    extract_dry_warm_1_tol text,
    extract_dry_warm_2_tol text,
    extract_dry_warm_3_tol text,
    vergistingstijd_tol text,
    lagertijd_tol text,
    lager_temp_tol text,
    pasteurisatie_tol text,
    troebeling_na_sep_tol text,
    bitterheid_bh numeric,
    bitterheid_bh_tol text,
    CONSTRAINT recipe_fermentatie_bier_risico_check CHECK (((bier_risico IS NULL) OR (bier_risico = ANY (ARRAY['Standaard'::text, 'Gevaarlijk'::text, 'Suikerhoudend'::text, 'Gevoelig'::text])))),
    CONSTRAINT recipe_fermentatie_bier_status_check CHECK (((bier_status IS NULL) OR (bier_status = ANY (ARRAY['Standaard'::text, 'NPI'::text, 'Te verbeteren'::text]))))
);


--
-- Name: recipe_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_ingredients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_kosten; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_kosten (
    recipe_id bigint NOT NULL,
    cost_clr_per_kge numeric,
    cost_bh_per_kge numeric,
    cost_grondstoffen_hl numeric,
    bierverlies_pct numeric
);


--
-- Name: recipe_processtappen; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_processtappen (
    recipe_id bigint NOT NULL,
    dry_hop_warm boolean DEFAULT false,
    dry_hop_cold boolean DEFAULT false,
    hopsteiner boolean DEFAULT false,
    bevasil boolean DEFAULT false,
    nagardo boolean DEFAULT false,
    gluten_test boolean DEFAULT false,
    sample_to_lab boolean DEFAULT false,
    fuge_after_cooling boolean DEFAULT false,
    cool_to_7c boolean DEFAULT false,
    cool_to_0c boolean DEFAULT false,
    check_hbt_addition boolean DEFAULT false,
    keldersplitsing boolean DEFAULT false,
    cellar_add_1 boolean DEFAULT false,
    cellar_add_2 boolean DEFAULT false,
    cellar_add_3 boolean DEFAULT false,
    cellar_add_4 boolean DEFAULT false,
    dry_hop_0c boolean,
    dry_hop_comment_warm text,
    dry_hop_methode_warm text,
    dry_hop_comment_16c text,
    dry_hop_methode_16c text,
    dry_hop_1_dag integer,
    dry_hop_2_dag integer,
    kelder_toevoeging_dag integer,
    comment_verwerken text,
    total_wp_hop numeric,
    total_dry_hop numeric
);


--
-- Name: recipe_revisies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_revisies (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    versienummer integer,
    datum date,
    door text,
    wijziging text,
    versie_major integer,
    versie_minor integer,
    gebruiker_id uuid
);


--
-- Name: recipe_revisies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisies ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_revisies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_specificaties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_specificaties (
    recipe_id bigint NOT NULL,
    origineel_extract numeric,
    rest_extract numeric,
    alcohol numeric,
    bitterheid numeric,
    kleur numeric,
    ph numeric,
    adf_pct numeric,
    troebeling_lab numeric,
    co2_fles numeric,
    co2_can numeric,
    co2_fust numeric,
    headspace_o2 numeric,
    dissolved_o2 numeric,
    origineel_extract_tol text,
    rest_extract_tol text,
    alcohol_tol text,
    bitterheid_tol text,
    kleur_tol text,
    ph_tol text,
    adf_pct_tol text,
    troebeling_lab_tol text,
    co2_fles_tol text,
    co2_can_tol text,
    co2_fust_tol text,
    headspace_o2_tol text,
    dissolved_o2_tol text
);


--
-- Name: recipe_verpakking; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_verpakking (
    recipe_id bigint NOT NULL,
    ean_fles text,
    tht_fles_maanden numeric,
    tht_vat_maanden numeric,
    tht_blik_maanden numeric,
    alc_pct numeric,
    formaten jsonb,
    tpo_spec numeric,
    hso_spec numeric,
    do_spec numeric,
    co2_fles_can_spec numeric,
    co2_fles_can_tolerantie numeric,
    co2_fust_spec numeric,
    co2_fust_tolerantie numeric,
    zuurstof_fust_spec numeric
);


--
-- Name: recipe_water; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_water (
    recipe_id bigint NOT NULL,
    ca numeric,
    mg numeric,
    na numeric,
    cl numeric,
    so4 numeric,
    ratio_cl_so4 numeric,
    alkalinity numeric,
    maischwater numeric,
    ph_maische numeric,
    ph_start_koken numeric,
    ph_eind_koken numeric,
    beluchting numeric
);


--
-- Name: recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipes (
    id bigint NOT NULL,
    naam text NOT NULL,
    bierstijl text,
    locatie text,
    huidige_versie integer DEFAULT 1 NOT NULL,
    status text DEFAULT 'actief'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    versie_major integer DEFAULT 1 NOT NULL,
    versie_minor integer DEFAULT 0 NOT NULL,
    aangemaakt_door uuid,
    gewijzigd_door uuid,
    gewijzigd_op timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    brouwsel_hl numeric,
    kleur text,
    smaakomschrijving text,
    smaak_keywords text[],
    aanbevolen_schenktemperatuur numeric,
    kleur_srm numeric,
    kleur_vrije_tekst text,
    CONSTRAINT recipes_locatie_check CHECK ((locatie = ANY (ARRAY['Waarderpolder'::text, 'Jopen Kerk'::text]))),
    CONSTRAINT recipes_status_check CHECK ((status = ANY (ARRAY['concept'::text, 'actief'::text, 'gearchiveerd'::text])))
);


--
-- Name: recipes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    role_id bigint NOT NULL,
    module_key text NOT NULL,
    can_view boolean DEFAULT false NOT NULL,
    can_edit boolean DEFAULT false NOT NULL,
    can_delete boolean DEFAULT false NOT NULL
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id bigint NOT NULL,
    name text NOT NULL,
    is_system_role boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    label text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: voorraad_mutaties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voorraad_mutaties (
    id bigint NOT NULL,
    lot_id bigint,
    type text NOT NULL,
    hoeveelheid numeric NOT NULL,
    batch_id bigint,
    recipe_ingredient_id bigint,
    notitie text,
    geboekt_in_boekhouding boolean DEFAULT false NOT NULL,
    geboekt_door uuid,
    geboekt_op timestamp with time zone,
    aangemaakt_door uuid,
    aangemaakt_op timestamp with time zone DEFAULT now() NOT NULL,
    off_recipe boolean DEFAULT false NOT NULL,
    ingevoerde_hoeveelheid numeric,
    ingevoerde_eenheid text,
    is_spoilage boolean DEFAULT false NOT NULL,
    is_correction boolean DEFAULT false NOT NULL,
    CONSTRAINT voorraad_mutaties_type_check CHECK ((type = ANY (ARRAY['ontvangst'::text, 'reservering'::text, 'uitboeking'::text, 'correctie'::text])))
);


--
-- Name: voorraad_mutaties_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.voorraad_mutaties ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.voorraad_mutaties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: water_instellingen; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_instellingen (
    id smallint DEFAULT 1 NOT NULL,
    omschrijving text DEFAULT 'Jopen ambient water'::text NOT NULL,
    gemeten_op date,
    ca numeric NOT NULL,
    mg numeric NOT NULL,
    na numeric NOT NULL,
    cl numeric NOT NULL,
    so4 numeric NOT NULL,
    alkalinity numeric,
    max_ca numeric DEFAULT 300 NOT NULL,
    max_mg numeric DEFAULT 30 NOT NULL,
    max_cl numeric DEFAULT 400 NOT NULL,
    max_so4 numeric DEFAULT 600 NOT NULL,
    gewijzigd_op timestamp with time zone DEFAULT now() NOT NULL,
    gewijzigd_door uuid,
    CONSTRAINT water_instellingen_id_check CHECK ((id = 1))
);


--
-- Name: water_instellingen_historie; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_instellingen_historie (
    id bigint NOT NULL,
    geldig_vanaf timestamp with time zone NOT NULL,
    gewijzigd_door uuid,
    gegevens jsonb NOT NULL
);


--
-- Name: water_instellingen_historie_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.water_instellingen_historie ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.water_instellingen_historie_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batches batches_batchnummer_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_batchnummer_key UNIQUE (batchnummer);


--
-- Name: batches batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_pkey PRIMARY KEY (id);


--
-- Name: brew_capacity brew_capacity_group_year_week_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_group_year_week_key UNIQUE (capacity_group, iso_year, week_number);


--
-- Name: brew_capacity brew_capacity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_geschiedenis brew_planning_geschiedenis_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_geschiedenis
    ADD CONSTRAINT brew_planning_geschiedenis_pkey PRIMARY KEY (id);


--
-- Name: brew_planning brew_planning_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_splits brew_planning_splits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_pkey PRIMARY KEY (id);


--
-- Name: document_types document_types_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_code_key UNIQUE (code);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: grondstof_lots grondstof_lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grondstof_lots
    ADD CONSTRAINT grondstof_lots_pkey PRIMARY KEY (id);


--
-- Name: hop_utilisatie_curve hop_utilisatie_curve_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hop_utilisatie_curve
    ADD CONSTRAINT hop_utilisatie_curve_pkey PRIMARY KEY (kooktijd_min);


--
-- Name: ingredient_categories ingredient_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_categories
    ADD CONSTRAINT ingredient_categories_name_key UNIQUE (name);


--
-- Name: ingredient_categories ingredient_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_categories
    ADD CONSTRAINT ingredient_categories_pkey PRIMARY KEY (id);


--
-- Name: ingredient_declaraties ingredient_declaraties_naam_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declaraties
    ADD CONSTRAINT ingredient_declaraties_naam_key UNIQUE (naam);


--
-- Name: ingredient_declaraties ingredient_declaraties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declaraties
    ADD CONSTRAINT ingredient_declaraties_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documenten ingredient_documenten_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documenten
    ADD CONSTRAINT ingredient_documenten_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documenten ingredient_documenten_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documenten
    ADD CONSTRAINT ingredient_documenten_storage_path_key UNIQUE (storage_path);


--
-- Name: ingredient_revisies ingredient_revisies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisies
    ADD CONSTRAINT ingredient_revisies_pkey PRIMARY KEY (id);


--
-- Name: ingredients ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_pkey PRIMARY KEY (id);


--
-- Name: permission_modules permission_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_modules
    ADD CONSTRAINT permission_modules_pkey PRIMARY KEY (module_key);


--
-- Name: product_sheet_revisies product_sheet_revisies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisies
    ADD CONSTRAINT product_sheet_revisies_pkey PRIMARY KEY (id);


--
-- Name: product_sheets product_sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_pkey PRIMARY KEY (id);


--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brouwspecificaties
    ADD CONSTRAINT recipe_brouwspecificaties_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_comments recipe_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_fermentatie recipe_fermentatie_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentatie
    ADD CONSTRAINT recipe_fermentatie_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_ingredients recipe_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_pkey PRIMARY KEY (id);


--
-- Name: recipe_kosten recipe_kosten_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_kosten
    ADD CONSTRAINT recipe_kosten_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_processtappen recipe_processtappen_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_processtappen
    ADD CONSTRAINT recipe_processtappen_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_revisies recipe_revisies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisies
    ADD CONSTRAINT recipe_revisies_pkey PRIMARY KEY (id);


--
-- Name: recipe_specificaties recipe_specificaties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specificaties
    ADD CONSTRAINT recipe_specificaties_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_verpakking recipe_verpakking_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_verpakking
    ADD CONSTRAINT recipe_verpakking_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_water recipe_water_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_water
    ADD CONSTRAINT recipe_water_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipes recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, module_key);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: units units_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_code_key UNIQUE (code);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: voorraad_mutaties voorraad_mutaties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_pkey PRIMARY KEY (id);


--
-- Name: water_instellingen_historie water_instellingen_historie_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_instellingen_historie
    ADD CONSTRAINT water_instellingen_historie_pkey PRIMARY KEY (id);


--
-- Name: water_instellingen water_instellingen_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_instellingen
    ADD CONSTRAINT water_instellingen_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_splits_brew_planning_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brew_planning_splits_brew_planning_id_idx ON public.brew_planning_splits USING btree (brew_planning_id);


--
-- Name: idx_batches_batchnummer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_batchnummer ON public.batches USING btree (batchnummer DESC);


--
-- Name: idx_batches_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_recipe_id ON public.batches USING btree (recipe_id);


--
-- Name: idx_brew_capacity_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_capacity_year_week ON public.brew_capacity USING btree (iso_year, week_number);


--
-- Name: idx_brew_planning_geschiedenis_gewijzigd_op; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_geschiedenis_gewijzigd_op ON public.brew_planning_geschiedenis USING btree (gewijzigd_op DESC);


--
-- Name: idx_brew_planning_geschiedenis_planning_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_geschiedenis_planning_id ON public.brew_planning_geschiedenis USING btree (brew_planning_id);


--
-- Name: idx_brew_planning_recipe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe ON public.brew_planning USING btree (recipe_id);


--
-- Name: idx_brew_planning_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe_group_id ON public.brew_planning USING btree (recipe_group_id);


--
-- Name: idx_brew_planning_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_year_week ON public.brew_planning USING btree (iso_year, week_number);


--
-- Name: idx_grondstof_lots_ingredient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_grondstof_lots_ingredient ON public.grondstof_lots USING btree (ingredient_id);


--
-- Name: idx_grondstof_lots_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_grondstof_lots_status ON public.grondstof_lots USING btree (status);


--
-- Name: idx_ingredient_documenten_ing_status_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documenten_ing_status_type ON public.ingredient_documenten USING btree (ingredient_id, status, document_type_id);


--
-- Name: idx_ingredient_documenten_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documenten_ingredient_id ON public.ingredient_documenten USING btree (ingredient_id);


--
-- Name: idx_ingredient_revisies_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_revisies_ingredient_id ON public.ingredient_revisies USING btree (ingredient_id);


--
-- Name: idx_ingredients_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredients_group_id ON public.ingredients USING btree (ingredient_group_id);


--
-- Name: idx_recipes_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipes_recipe_group_id ON public.recipes USING btree (recipe_group_id);


--
-- Name: idx_voorraad_mutaties_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voorraad_mutaties_batch ON public.voorraad_mutaties USING btree (batch_id);


--
-- Name: idx_voorraad_mutaties_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voorraad_mutaties_lot ON public.voorraad_mutaties USING btree (lot_id);


--
-- Name: idx_voorraad_mutaties_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voorraad_mutaties_type ON public.voorraad_mutaties USING btree (type);


--
-- Name: product_sheet_revisies_product_sheet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_sheet_revisies_product_sheet_id_idx ON public.product_sheet_revisies USING btree (product_sheet_id);


--
-- Name: product_sheets_recipe_group_id_actief_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX product_sheets_recipe_group_id_actief_idx ON public.product_sheets USING btree (recipe_group_id) WHERE (status <> 'gearchiveerd'::text);


--
-- Name: brew_planning trg_brew_planning_geschiedenis; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brew_planning_geschiedenis AFTER INSERT OR DELETE OR UPDATE ON public.brew_planning FOR EACH ROW EXECUTE FUNCTION public.log_brew_planning_wijziging();


--
-- Name: ingredients trg_ingredients_gewijzigd_op; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ingredients_gewijzigd_op BEFORE UPDATE ON public.ingredients FOR EACH ROW EXECUTE FUNCTION public.set_ingredients_gewijzigd_op();


--
-- Name: recipes trg_recipes_gewijzigd_op; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recipes_gewijzigd_op BEFORE UPDATE ON public.recipes FOR EACH ROW EXECUTE FUNCTION public.set_gewijzigd_op();


--
-- Name: water_instellingen trg_water_instellingen_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_instellingen_log AFTER INSERT OR UPDATE ON public.water_instellingen FOR EACH ROW EXECUTE FUNCTION public.water_instellingen_log();


--
-- Name: water_instellingen trg_water_instellingen_stempel; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_instellingen_stempel BEFORE UPDATE ON public.water_instellingen FOR EACH ROW EXECUTE FUNCTION public.water_instellingen_stempel();


--
-- Name: batches batches_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES public.users(id);


--
-- Name: batches batches_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: brew_capacity brew_capacity_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: brew_planning brew_planning_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES public.users(id);


--
-- Name: brew_planning_geschiedenis brew_planning_geschiedenis_gewijzigd_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_geschiedenis
    ADD CONSTRAINT brew_planning_geschiedenis_gewijzigd_door_fkey FOREIGN KEY (gewijzigd_door) REFERENCES public.users(id);


--
-- Name: brew_planning brew_planning_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: brew_planning_splits brew_planning_splits_brew_planning_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_brew_planning_id_fkey FOREIGN KEY (brew_planning_id) REFERENCES public.brew_planning(id) ON DELETE CASCADE;


--
-- Name: brew_planning_splits brew_planning_splits_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: grondstof_lots grondstof_lots_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grondstof_lots
    ADD CONSTRAINT grondstof_lots_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES public.users(id);


--
-- Name: grondstof_lots grondstof_lots_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grondstof_lots
    ADD CONSTRAINT grondstof_lots_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: grondstof_lots grondstof_lots_ontvangen_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grondstof_lots
    ADD CONSTRAINT grondstof_lots_ontvangen_door_fkey FOREIGN KEY (ontvangen_door) REFERENCES public.users(id);


--
-- Name: ingredient_documenten ingredient_documenten_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documenten
    ADD CONSTRAINT ingredient_documenten_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id);


--
-- Name: ingredient_documenten ingredient_documenten_geupload_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documenten
    ADD CONSTRAINT ingredient_documenten_geupload_door_fkey FOREIGN KEY (geupload_door) REFERENCES auth.users(id);


--
-- Name: ingredient_documenten ingredient_documenten_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documenten
    ADD CONSTRAINT ingredient_documenten_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredient_revisies ingredient_revisies_gebruiker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisies
    ADD CONSTRAINT ingredient_revisies_gebruiker_id_fkey FOREIGN KEY (gebruiker_id) REFERENCES public.users(id);


--
-- Name: ingredient_revisies ingredient_revisies_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisies
    ADD CONSTRAINT ingredient_revisies_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredients ingredients_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES auth.users(id);


--
-- Name: ingredients ingredients_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ingredient_categories(id);


--
-- Name: ingredients ingredients_gewijzigd_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_gewijzigd_door_fkey FOREIGN KEY (gewijzigd_door) REFERENCES auth.users(id);


--
-- Name: product_sheet_revisies product_sheet_revisies_product_sheet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisies
    ADD CONSTRAINT product_sheet_revisies_product_sheet_id_fkey FOREIGN KEY (product_sheet_id) REFERENCES public.product_sheets(id) ON DELETE CASCADE;


--
-- Name: product_sheets product_sheets_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES auth.users(id);


--
-- Name: product_sheets product_sheets_bijgewerkt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_bijgewerkt_door_fkey FOREIGN KEY (bijgewerkt_door) REFERENCES auth.users(id);


--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brouwspecificaties
    ADD CONSTRAINT recipe_brouwspecificaties_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_comments recipe_comments_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_fermentatie recipe_fermentatie_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentatie
    ADD CONSTRAINT recipe_fermentatie_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_ingredients recipe_ingredients_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: recipe_ingredients recipe_ingredients_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_kosten recipe_kosten_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_kosten
    ADD CONSTRAINT recipe_kosten_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_processtappen recipe_processtappen_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_processtappen
    ADD CONSTRAINT recipe_processtappen_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_revisies recipe_revisies_gebruiker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisies
    ADD CONSTRAINT recipe_revisies_gebruiker_id_fkey FOREIGN KEY (gebruiker_id) REFERENCES auth.users(id);


--
-- Name: recipe_revisies recipe_revisies_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisies
    ADD CONSTRAINT recipe_revisies_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_specificaties recipe_specificaties_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specificaties
    ADD CONSTRAINT recipe_specificaties_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_verpakking recipe_verpakking_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_verpakking
    ADD CONSTRAINT recipe_verpakking_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_water recipe_water_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_water
    ADD CONSTRAINT recipe_water_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipes recipes_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES auth.users(id);


--
-- Name: recipes recipes_gewijzigd_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_gewijzigd_door_fkey FOREIGN KEY (gewijzigd_door) REFERENCES auth.users(id);


--
-- Name: role_permissions role_permissions_module_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_module_key_fkey FOREIGN KEY (module_key) REFERENCES public.permission_modules(module_key) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: users users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: voorraad_mutaties voorraad_mutaties_aangemaakt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_aangemaakt_door_fkey FOREIGN KEY (aangemaakt_door) REFERENCES public.users(id);


--
-- Name: voorraad_mutaties voorraad_mutaties_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id);


--
-- Name: voorraad_mutaties voorraad_mutaties_geboekt_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_geboekt_door_fkey FOREIGN KEY (geboekt_door) REFERENCES public.users(id);


--
-- Name: voorraad_mutaties voorraad_mutaties_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.grondstof_lots(id);


--
-- Name: voorraad_mutaties voorraad_mutaties_recipe_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voorraad_mutaties
    ADD CONSTRAINT voorraad_mutaties_recipe_ingredient_id_fkey FOREIGN KEY (recipe_ingredient_id) REFERENCES public.recipe_ingredients(id);


--
-- Name: water_instellingen water_instellingen_gewijzigd_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_instellingen
    ADD CONSTRAINT water_instellingen_gewijzigd_door_fkey FOREIGN KEY (gewijzigd_door) REFERENCES public.users(id);


--
-- Name: water_instellingen_historie water_instellingen_historie_gewijzigd_door_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_instellingen_historie
    ADD CONSTRAINT water_instellingen_historie_gewijzigd_door_fkey FOREIGN KEY (gewijzigd_door) REFERENCES public.users(id);


--
-- Name: batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batches ENABLE ROW LEVEL SECURITY;

--
-- Name: batches batches_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_delete ON public.batches FOR DELETE USING (public.can_delete('batches'::text));


--
-- Name: batches batches_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_insert ON public.batches FOR INSERT WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batches batches_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_select ON public.batches FOR SELECT USING (public.can_view('batches'::text));


--
-- Name: batches batches_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_update ON public.batches FOR UPDATE USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: brew_capacity; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_capacity ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_capacity brew_capacity_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_delete ON public.brew_capacity FOR DELETE USING (public.can_delete('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_insert ON public.brew_capacity FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_select ON public.brew_capacity FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_update ON public.brew_capacity FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning brew_planning_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_delete ON public.brew_planning FOR DELETE USING (public.can_delete('brewing_planning'::text));


--
-- Name: brew_planning_geschiedenis; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning_geschiedenis ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning_geschiedenis brew_planning_geschiedenis_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_geschiedenis_select ON public.brew_planning_geschiedenis FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_insert ON public.brew_planning FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_select ON public.brew_planning FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning_splits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning_splits ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning_splits brew_planning_splits_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_delete ON public.brew_planning_splits FOR DELETE USING (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_insert ON public.brew_planning_splits FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_select ON public.brew_planning_splits FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_update ON public.brew_planning_splits FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_update ON public.brew_planning FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: document_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

--
-- Name: document_types document_types_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_delete ON public.document_types FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: document_types document_types_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_insert ON public.document_types FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: document_types document_types_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_select ON public.document_types FOR SELECT USING (true);


--
-- Name: document_types document_types_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_update ON public.document_types FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: grondstof_lots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.grondstof_lots ENABLE ROW LEVEL SECURITY;

--
-- Name: grondstof_lots grondstof_lots_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY grondstof_lots_delete ON public.grondstof_lots FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: grondstof_lots grondstof_lots_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY grondstof_lots_insert ON public.grondstof_lots FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: grondstof_lots grondstof_lots_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY grondstof_lots_select ON public.grondstof_lots FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: grondstof_lots grondstof_lots_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY grondstof_lots_update ON public.grondstof_lots FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: hop_utilisatie_curve; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hop_utilisatie_curve ENABLE ROW LEVEL SECURITY;

--
-- Name: hop_utilisatie_curve hop_utilisatie_curve_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hop_utilisatie_curve_delete ON public.hop_utilisatie_curve FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: hop_utilisatie_curve hop_utilisatie_curve_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hop_utilisatie_curve_insert ON public.hop_utilisatie_curve FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: hop_utilisatie_curve hop_utilisatie_curve_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hop_utilisatie_curve_select ON public.hop_utilisatie_curve FOR SELECT USING (true);


--
-- Name: hop_utilisatie_curve hop_utilisatie_curve_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hop_utilisatie_curve_update ON public.hop_utilisatie_curve FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_categories ingredient_categories_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_delete ON public.ingredient_categories FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: ingredient_categories ingredient_categories_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_insert ON public.ingredient_categories FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_categories ingredient_categories_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_select ON public.ingredient_categories FOR SELECT USING (true);


--
-- Name: ingredient_categories ingredient_categories_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_update ON public.ingredient_categories FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_declaraties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_declaraties ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_declaraties ingredient_declaraties_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declaraties_delete ON public.ingredient_declaraties FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: ingredient_declaraties ingredient_declaraties_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declaraties_insert ON public.ingredient_declaraties FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_declaraties ingredient_declaraties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declaraties_select ON public.ingredient_declaraties FOR SELECT USING (true);


--
-- Name: ingredient_declaraties ingredient_declaraties_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declaraties_update ON public.ingredient_declaraties FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_documenten; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documenten ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_documenten ingredient_documenten_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documenten_delete ON public.ingredient_documenten FOR DELETE USING (public.can_delete('ingredients'::text));


--
-- Name: ingredient_documenten ingredient_documenten_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documenten_insert ON public.ingredient_documenten FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_documenten ingredient_documenten_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documenten_select ON public.ingredient_documenten FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredient_documenten ingredient_documenten_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documenten_update ON public.ingredient_documenten FOR UPDATE USING (public.can_edit('ingredients'::text)) WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisies ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_revisies ingredient_revisies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisies_insert ON public.ingredient_revisies FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisies ingredient_revisies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisies_select ON public.ingredient_revisies FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredients ingredients_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_delete ON public.ingredients FOR DELETE USING (public.can_delete('ingredients'::text));


--
-- Name: ingredients ingredients_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_insert ON public.ingredients FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredients ingredients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_select ON public.ingredients FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredients ingredients_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_update ON public.ingredients FOR UPDATE USING (public.can_edit('ingredients'::text)) WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: permission_modules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_modules ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_modules permission_modules_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY permission_modules_select ON public.permission_modules FOR SELECT USING (true);


--
-- Name: product_sheet_revisies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisies ENABLE ROW LEVEL SECURITY;

--
-- Name: product_sheet_revisies product_sheet_revisies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisies_insert ON public.product_sheet_revisies FOR INSERT WITH CHECK (public.can_edit('product_sheets'::text));


--
-- Name: product_sheet_revisies product_sheet_revisies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisies_select ON public.product_sheet_revisies FOR SELECT USING (public.can_view('product_sheets'::text));


--
-- Name: product_sheets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_sheets ENABLE ROW LEVEL SECURITY;

--
-- Name: product_sheets product_sheets_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_delete ON public.product_sheets FOR DELETE USING (public.can_delete('product_sheets'::text));


--
-- Name: product_sheets product_sheets_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_insert ON public.product_sheets FOR INSERT WITH CHECK (public.can_edit('product_sheets'::text));


--
-- Name: product_sheets product_sheets_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_select ON public.product_sheets FOR SELECT USING (public.can_view('product_sheets'::text));


--
-- Name: product_sheets product_sheets_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_update ON public.product_sheets FOR UPDATE USING (public.can_edit('product_sheets'::text));


--
-- Name: recipe_brouwspecificaties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_brouwspecificaties ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brouwspecificaties_delete ON public.recipe_brouwspecificaties FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brouwspecificaties_insert ON public.recipe_brouwspecificaties FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brouwspecificaties_select ON public.recipe_brouwspecificaties FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_brouwspecificaties recipe_brouwspecificaties_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brouwspecificaties_update ON public.recipe_brouwspecificaties FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_comments recipe_comments_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_delete ON public.recipe_comments FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_comments recipe_comments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_insert ON public.recipe_comments FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_comments recipe_comments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_select ON public.recipe_comments FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_comments recipe_comments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_update ON public.recipe_comments FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentatie; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_fermentatie ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_fermentatie recipe_fermentatie_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentatie_delete ON public.recipe_fermentatie FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_fermentatie recipe_fermentatie_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentatie_insert ON public.recipe_fermentatie FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentatie recipe_fermentatie_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentatie_select ON public.recipe_fermentatie FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_fermentatie recipe_fermentatie_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentatie_update ON public.recipe_fermentatie FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_ingredients recipe_ingredients_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_delete ON public.recipe_ingredients FOR DELETE USING (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_insert ON public.recipe_ingredients FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_select ON public.recipe_ingredients FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_update ON public.recipe_ingredients FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_kosten; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_kosten ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_kosten recipe_kosten_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_kosten_delete ON public.recipe_kosten FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_kosten recipe_kosten_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_kosten_insert ON public.recipe_kosten FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_kosten recipe_kosten_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_kosten_select ON public.recipe_kosten FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_kosten recipe_kosten_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_kosten_update ON public.recipe_kosten FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_processtappen; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_processtappen ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_processtappen recipe_processtappen_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_processtappen_delete ON public.recipe_processtappen FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_processtappen recipe_processtappen_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_processtappen_insert ON public.recipe_processtappen FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_processtappen recipe_processtappen_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_processtappen_select ON public.recipe_processtappen FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_processtappen recipe_processtappen_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_processtappen_update ON public.recipe_processtappen FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisies ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_revisies recipe_revisies_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisies_delete ON public.recipe_revisies FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_revisies recipe_revisies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisies_insert ON public.recipe_revisies FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisies recipe_revisies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisies_select ON public.recipe_revisies FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_revisies recipe_revisies_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisies_update ON public.recipe_revisies FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specificaties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_specificaties ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_specificaties recipe_specificaties_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specificaties_delete ON public.recipe_specificaties FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_specificaties recipe_specificaties_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specificaties_insert ON public.recipe_specificaties FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specificaties recipe_specificaties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specificaties_select ON public.recipe_specificaties FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_specificaties recipe_specificaties_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specificaties_update ON public.recipe_specificaties FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_verpakking; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_verpakking ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_verpakking recipe_verpakking_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_verpakking_delete ON public.recipe_verpakking FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_verpakking recipe_verpakking_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_verpakking_insert ON public.recipe_verpakking FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_verpakking recipe_verpakking_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_verpakking_select ON public.recipe_verpakking FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_verpakking recipe_verpakking_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_verpakking_update ON public.recipe_verpakking FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_water; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_water ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_water recipe_water_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_delete ON public.recipe_water FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_water recipe_water_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_insert ON public.recipe_water FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_water recipe_water_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_select ON public.recipe_water FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_water recipe_water_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_update ON public.recipe_water FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;

--
-- Name: recipes recipes_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_delete ON public.recipes FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipes recipes_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_insert ON public.recipes FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipes recipes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_select ON public.recipes FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipes recipes_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_update ON public.recipes FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: role_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permissions role_permissions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_select ON public.role_permissions FOR SELECT USING (true);


--
-- Name: role_permissions role_permissions_write_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_write_admin ON public.role_permissions USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: roles roles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_select ON public.roles FOR SELECT USING (true);


--
-- Name: roles roles_write_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_write_admin ON public.roles USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

--
-- Name: units units_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_delete ON public.units FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: units units_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_insert ON public.units FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: units units_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_select ON public.units FOR SELECT USING (true);


--
-- Name: units units_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_update ON public.units FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_select ON public.users FOR SELECT TO authenticated USING (true);


--
-- Name: users users_write_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_write_admin ON public.users TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: voorraad_mutaties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.voorraad_mutaties ENABLE ROW LEVEL SECURITY;

--
-- Name: voorraad_mutaties voorraad_mutaties_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voorraad_mutaties_delete ON public.voorraad_mutaties FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: voorraad_mutaties voorraad_mutaties_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voorraad_mutaties_insert ON public.voorraad_mutaties FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: voorraad_mutaties voorraad_mutaties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voorraad_mutaties_select ON public.voorraad_mutaties FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: voorraad_mutaties voorraad_mutaties_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY voorraad_mutaties_update ON public.voorraad_mutaties FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: water_instellingen; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_instellingen ENABLE ROW LEVEL SECURITY;

--
-- Name: water_instellingen_historie; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_instellingen_historie ENABLE ROW LEVEL SECURITY;

--
-- Name: water_instellingen_historie water_instellingen_historie_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_instellingen_historie_select ON public.water_instellingen_historie FOR SELECT USING (true);


--
-- Name: water_instellingen water_instellingen_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_instellingen_select ON public.water_instellingen FOR SELECT USING (true);


--
-- Name: water_instellingen water_instellingen_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_instellingen_update ON public.water_instellingen FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION admin_get_last_logins(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_get_last_logins() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_get_last_logins() TO service_role;
GRANT ALL ON FUNCTION public.admin_get_last_logins() TO authenticated;


--
-- Name: FUNCTION can_delete(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_delete(p_module_key text) TO service_role;


--
-- Name: FUNCTION can_edit(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_edit(p_module_key text) TO service_role;


--
-- Name: FUNCTION can_view(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_view(p_module_key text) TO service_role;


--
-- Name: FUNCTION current_role_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_role_id() TO service_role;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin() TO service_role;


--
-- Name: FUNCTION log_brew_planning_wijziging(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_brew_planning_wijziging() TO service_role;


--
-- Name: FUNCTION product_sheet_calculated_color(p_recipe_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_calculated_color(p_recipe_id bigint) TO service_role;


--
-- Name: FUNCTION product_sheet_relevant_hash(p_recipe_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid) TO service_role;


--
-- Name: FUNCTION product_sheet_relevant_recipe_id(p_recipe_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid) TO service_role;


--
-- Name: FUNCTION set_gewijzigd_op(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_gewijzigd_op() TO service_role;


--
-- Name: FUNCTION set_ingredients_gewijzigd_op(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_ingredients_gewijzigd_op() TO service_role;


--
-- Name: FUNCTION set_last_login(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_last_login() TO service_role;
GRANT ALL ON FUNCTION public.set_last_login() TO authenticated;


--
-- Name: FUNCTION water_instellingen_log(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.water_instellingen_log() TO service_role;


--
-- Name: FUNCTION water_instellingen_stempel(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.water_instellingen_stempel() TO service_role;


--
-- Name: TABLE batches; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batches TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batches TO authenticated;
GRANT ALL ON TABLE public.batches TO service_role;


--
-- Name: SEQUENCE batches_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batches_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batches_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batches_id_seq TO service_role;


--
-- Name: TABLE brew_capacity; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_capacity TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_capacity TO authenticated;
GRANT ALL ON TABLE public.brew_capacity TO service_role;


--
-- Name: TABLE brew_planning; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning TO authenticated;
GRANT ALL ON TABLE public.brew_planning TO service_role;


--
-- Name: TABLE brew_planning_geschiedenis; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_geschiedenis TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_geschiedenis TO authenticated;
GRANT ALL ON TABLE public.brew_planning_geschiedenis TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;


--
-- Name: TABLE brew_planning_geschiedenis_verrijkt; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_geschiedenis_verrijkt TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_geschiedenis_verrijkt TO authenticated;
GRANT ALL ON TABLE public.brew_planning_geschiedenis_verrijkt TO service_role;


--
-- Name: TABLE brew_planning_splits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO authenticated;
GRANT ALL ON TABLE public.brew_planning_splits TO service_role;


--
-- Name: TABLE brew_planning_wijzigingen; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_wijzigingen TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_wijzigingen TO authenticated;
GRANT ALL ON TABLE public.brew_planning_wijzigingen TO service_role;


--
-- Name: TABLE document_types; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO authenticated;
GRANT ALL ON TABLE public.document_types TO service_role;


--
-- Name: TABLE grondstof_lots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.grondstof_lots TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.grondstof_lots TO authenticated;
GRANT ALL ON TABLE public.grondstof_lots TO service_role;


--
-- Name: SEQUENCE grondstof_lots_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.grondstof_lots_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.grondstof_lots_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.grondstof_lots_id_seq TO service_role;


--
-- Name: TABLE hop_utilisatie_curve; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.hop_utilisatie_curve TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.hop_utilisatie_curve TO authenticated;
GRANT ALL ON TABLE public.hop_utilisatie_curve TO service_role;


--
-- Name: TABLE ingredient_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_categories TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_categories TO authenticated;
GRANT ALL ON TABLE public.ingredient_categories TO service_role;


--
-- Name: SEQUENCE ingredient_categories_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_categories_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_categories_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_categories_id_seq TO service_role;


--
-- Name: TABLE ingredient_declaraties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declaraties TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declaraties TO authenticated;
GRANT ALL ON TABLE public.ingredient_declaraties TO service_role;


--
-- Name: TABLE ingredient_documenten; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documenten TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documenten TO authenticated;
GRANT ALL ON TABLE public.ingredient_documenten TO service_role;


--
-- Name: SEQUENCE ingredient_documenten_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documenten_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documenten_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_documenten_id_seq TO service_role;


--
-- Name: TABLE recipe_ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO authenticated;
GRANT ALL ON TABLE public.recipe_ingredients TO service_role;


--
-- Name: TABLE ingredient_gebruik_counts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_gebruik_counts TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_gebruik_counts TO authenticated;
GRANT ALL ON TABLE public.ingredient_gebruik_counts TO service_role;


--
-- Name: TABLE ingredient_revisies; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisies TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisies TO authenticated;
GRANT ALL ON TABLE public.ingredient_revisies TO service_role;


--
-- Name: SEQUENCE ingredient_revisies_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisies_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisies_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_revisies_id_seq TO service_role;


--
-- Name: TABLE ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredients TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredients TO authenticated;
GRANT ALL ON TABLE public.ingredients TO service_role;


--
-- Name: SEQUENCE ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredients_id_seq TO service_role;


--
-- Name: TABLE permission_modules; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO authenticated;
GRANT ALL ON TABLE public.permission_modules TO service_role;


--
-- Name: TABLE product_sheet_revisies; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisies TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisies TO authenticated;
GRANT ALL ON TABLE public.product_sheet_revisies TO service_role;


--
-- Name: SEQUENCE product_sheet_revisies_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisies_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisies_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.product_sheet_revisies_id_seq TO service_role;


--
-- Name: TABLE product_sheets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheets TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheets TO authenticated;
GRANT ALL ON TABLE public.product_sheets TO service_role;


--
-- Name: TABLE product_sheet_status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_status TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_status TO authenticated;
GRANT ALL ON TABLE public.product_sheet_status TO service_role;


--
-- Name: SEQUENCE product_sheets_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.product_sheets_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.product_sheets_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.product_sheets_id_seq TO service_role;


--
-- Name: TABLE recipe_brouwspecificaties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brouwspecificaties TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brouwspecificaties TO authenticated;
GRANT ALL ON TABLE public.recipe_brouwspecificaties TO service_role;


--
-- Name: TABLE recipe_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO authenticated;
GRANT ALL ON TABLE public.recipe_comments TO service_role;


--
-- Name: TABLE recipe_fermentatie; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentatie TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentatie TO authenticated;
GRANT ALL ON TABLE public.recipe_fermentatie TO service_role;


--
-- Name: SEQUENCE recipe_ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_ingredients_id_seq TO service_role;


--
-- Name: TABLE recipe_kosten; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_kosten TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_kosten TO authenticated;
GRANT ALL ON TABLE public.recipe_kosten TO service_role;


--
-- Name: TABLE recipe_processtappen; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_processtappen TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_processtappen TO authenticated;
GRANT ALL ON TABLE public.recipe_processtappen TO service_role;


--
-- Name: TABLE recipe_revisies; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisies TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisies TO authenticated;
GRANT ALL ON TABLE public.recipe_revisies TO service_role;


--
-- Name: SEQUENCE recipe_revisies_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisies_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisies_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_revisies_id_seq TO service_role;


--
-- Name: TABLE recipe_specificaties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specificaties TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specificaties TO authenticated;
GRANT ALL ON TABLE public.recipe_specificaties TO service_role;


--
-- Name: TABLE recipe_verpakking; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_verpakking TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_verpakking TO authenticated;
GRANT ALL ON TABLE public.recipe_verpakking TO service_role;


--
-- Name: TABLE recipe_water; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_water TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_water TO authenticated;
GRANT ALL ON TABLE public.recipe_water TO service_role;


--
-- Name: TABLE recipes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipes TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipes TO authenticated;
GRANT ALL ON TABLE public.recipes TO service_role;


--
-- Name: SEQUENCE recipes_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipes_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipes_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipes_id_seq TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_permissions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_permissions TO authenticated;
GRANT ALL ON TABLE public.role_permissions TO service_role;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.roles TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.roles TO authenticated;
GRANT ALL ON TABLE public.roles TO service_role;


--
-- Name: SEQUENCE roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.roles_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.roles_id_seq TO service_role;


--
-- Name: TABLE units; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO authenticated;
GRANT ALL ON TABLE public.units TO service_role;


--
-- Name: TABLE voorraad_mutaties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.voorraad_mutaties TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.voorraad_mutaties TO authenticated;
GRANT ALL ON TABLE public.voorraad_mutaties TO service_role;


--
-- Name: SEQUENCE voorraad_mutaties_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.voorraad_mutaties_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.voorraad_mutaties_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.voorraad_mutaties_id_seq TO service_role;


--
-- Name: TABLE water_instellingen; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_instellingen TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_instellingen TO authenticated;
GRANT ALL ON TABLE public.water_instellingen TO service_role;


--
-- Name: TABLE water_instellingen_historie; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_instellingen_historie TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_instellingen_historie TO authenticated;
GRANT ALL ON TABLE public.water_instellingen_historie TO service_role;


--
-- Name: SEQUENCE water_instellingen_historie_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.water_instellingen_historie_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.water_instellingen_historie_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.water_instellingen_historie_id_seq TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--


