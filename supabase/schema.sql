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
-- Name: log_brew_planning_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_brew_planning_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    insert into brew_planning_history (brew_planning_id, action, after, updated_by)
    values (new.id, 'created', to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'UPDATE') then
    insert into brew_planning_history (brew_planning_id, action, before, after, updated_by)
    values (new.id, 'updated', to_jsonb(old), to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'DELETE') then
    insert into brew_planning_history (brew_planning_id, action, before, updated_by)
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
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                             select round(
                                                                                                                                                                                                 coalesce(sum(ri.quantity * ri.color_ebc * 0.08), 0) / nullif(r.brew_volume_hl, 0) + 1.75
                                                                                                                                                                                                   , 2)
                                                                                                                                                                                                     from recipes r
                                                                                                                                                                                                       left join recipe_ingredients ri on ri.recipe_id = r.id and ri.addition_type = 'malt'
                                                                                                                                                                                                         where r.id = p_recipe_id
                                                                                                                                                                                                           group by r.brew_volume_hl
                                                                                                                                                                                                           $$;


--
-- Name: product_sheet_relevant_hash(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                                             select md5(
                                                                                                                                                                                                                 coalesce(s.original_extract::text,'') || '|' || coalesce(s.original_extract_tol,'') || '|' ||
                                                                                                                                                                                                                     coalesce(s.final_extract::text,'') || '|' || coalesce(s.final_extract_tol,'') || '|' ||
                                                                                                                                                                                                                         coalesce(s.alcohol::text,'') || '|' || coalesce(s.alcohol_tol,'') || '|' ||
                                                                                                                                                                                                                             coalesce(s.bitterness::text,'') || '|' || coalesce(s.bitterness_tol,'') || '|' ||
                                                                                                                                                                                                                                 coalesce(product_sheet_calculated_color(r.id)::text,'') || '|' || coalesce(s.color_tol,'') || '|' ||
                                                                                                                                                                                                                                     coalesce(s.ph::text,'') || '|' || coalesce(s.ph_tol,'') || '|' ||
                                                                                                                                                                                                                                         coalesce(s.turbidity_lab::text,'') || '|' || coalesce(s.turbidity_lab_tol,'') || '|' ||
                                                                                                                                                                                                                                             coalesce(s.co2_bottle::text,'') || '|' || coalesce(s.co2_bottle_tol,'') || '|' ||
                                                                                                                                                                                                                                                 coalesce(s.co2_can::text,'') || '|' || coalesce(s.co2_can_tol,'') || '|' ||
                                                                                                                                                                                                                                                     coalesce(s.co2_keg::text,'') || '|' || coalesce(s.co2_keg_tol,'') || '|' ||
                                                                                                                                                                                                                                                         coalesce(s.headspace_o2::text,'') || '|' || coalesce(s.headspace_o2_tol,'') || '|' ||
                                                                                                                                                                                                                                                             coalesce(s.dissolved_o2::text,'') || '|' || coalesce(s.dissolved_o2_tol,'') || '|' ||
                                                                                                                                                                                                                                                                 coalesce(r.flavor_description,'') || '|' ||
                                                                                                                                                                                                                                                                     coalesce(array_to_string(r.flavor_keywords, ','),'') || '|' ||
                                                                                                                                                                                                                                                                         coalesce(r.color_free_text,'') || '|' ||
                                                                                                                                                                                                                                                                             coalesce(r.serving_temperature::text,'') || '|' ||
                                                                                                                                                                                                                                                                                 coalesce((
                                                                                                                                                                                                                                                                                       select string_agg(ri.ingredient_id::text || ':' || coalesce(ri.quantity::text,'') || ':' || coalesce(ri.unit,'') || ':' || ri.addition_type, ',' order by ri.ingredient_id, ri.addition_type)
                                                                                                                                                                                                                                                                                             from recipe_ingredients ri where ri.recipe_id = r.id
                                                                                                                                                                                                                                                                                                 ), '') || '|' ||
                                                                                                                                                                                                                                                                                                     coalesce((
                                                                                                                                                                                                                                                                                                           select string_agg(coalesce(i.ingredient_declaration,'') || ':' || coalesce(i.allergens, '[]'::jsonb)::text, ',' order by i.id)
                                                                                                                                                                                                                                                                                                                 from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
                                                                                                                                                                                                                                                                                                                       where ri2.recipe_id = r.id
                                                                                                                                                                                                                                                                                                                           ), '')
                                                                                                                                                                                                                                                                                                                             )
                                                                                                                                                                                                                                                                                                                               from recipes r
                                                                                                                                                                                                                                                                                                                                 left join recipe_specs s on s.recipe_id = r.id
                                                                                                                                                                                                                                                                                                                                   where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
                                                                                                                                                                                                                                                                                                                                   $$;


--
-- Name: product_sheet_relevant_recipe_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid) RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                     select id from recipes
                                                                                                                                                                                       where recipe_group_id = p_recipe_group_id
                                                                                                                                                                                         order by version_major desc, version_minor desc
                                                                                                                                                                                           limit 1
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
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: water_settings_log(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_settings_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
                                                                           begin
                                                                             insert into water_settings_history (valid_from, updated_by, data)
                                                                                 values (new.updated_at, new.updated_by, to_jsonb(new));
                                                                                   return new;
                                                                                   end;
                                                                                   $$;


--
-- Name: water_settings_stamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_settings_stamp() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
                                                                     begin
                                                                       new.updated_at := now();
                                                                         new.updated_by := auth.uid();
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
    batch_number text NOT NULL,
    recipe_id bigint NOT NULL,
    brew_count numeric,
    brew_date date,
    status text DEFAULT 'planned'::text NOT NULL,
    operator text,
    yeast_temp_start numeric,
    yeast_temp_max numeric,
    yeast_strain text,
    yeast_rehydrated boolean,
    yeast_weight numeric,
    yeast_with_first_brew boolean,
    yeast_pitched_on date,
    yeast_pitched_by text,
    yeast_program_on boolean,
    order_picking_date date,
    "extract" numeric,
    alcohol numeric,
    bitterness numeric,
    color numeric,
    ph numeric,
    glt_empty boolean,
    total_final_volume numeric,
    name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT batches_status_check CHECK ((status = ANY (ARRAY['planned'::text, 'brewing'::text, 'fermenting'::text, 'processing'::text, 'filling'::text, 'completed'::text])))
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
    max_brews numeric DEFAULT 0 NOT NULL,
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
    brew_count numeric DEFAULT 1 NOT NULL,
    hl numeric,
    is_priority boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid,
    CONSTRAINT brew_planning_week_number_check CHECK (((week_number >= 1) AND (week_number <= 53)))
);


--
-- Name: brew_planning_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_planning_id uuid NOT NULL,
    action text NOT NULL,
    before jsonb,
    after jsonb,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brew_planning_history_action_check CHECK ((action = ANY (ARRAY['created'::text, 'updated'::text, 'deleted'::text])))
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
-- Name: brew_planning_history_detailed; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.brew_planning_history_detailed WITH (security_invoker='true') AS
 SELECT h.id,
    h.brew_planning_id,
    h.action,
    h.before,
    h.after,
    h.updated_by,
    u.name AS updated_by_name,
    h.updated_at
   FROM (public.brew_planning_history h
     LEFT JOIN public.users u ON ((u.id = h.updated_by)))
  ORDER BY h.updated_at DESC;


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
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


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
-- Name: ingredient_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    uses_alpha_pct boolean DEFAULT false NOT NULL,
    uses_extract_pct boolean DEFAULT false NOT NULL,
    uses_yeast_factor boolean DEFAULT false NOT NULL,
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
-- Name: ingredient_declarations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_declarations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    not_declarable boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_documents (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    file_name text NOT NULL,
    storage_path text NOT NULL,
    size_bytes bigint,
    revision_date date NOT NULL,
    uploaded_by uuid,
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL,
    document_type_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT ingredient_documents_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])))
);


--
-- Name: ingredient_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documents ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredient_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredient_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_revisions (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    version_major integer NOT NULL,
    version_minor integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    changed_by_name text,
    change_description text,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ingredient_revisions_id_seq
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
    addition_type text NOT NULL,
    quantity numeric,
    unit text,
    timing text,
    sort_order integer,
    note text,
    hop_dosing_tank integer,
    alpha_pct numeric,
    color_ebc numeric,
    all_in_first_brew boolean DEFAULT false NOT NULL,
    CONSTRAINT recipe_ingredients_addition_type_check CHECK ((addition_type = ANY (ARRAY['malt'::text, 'boil_hop'::text, 'dry_hop'::text, 'brewhouse_addition'::text, 'cellar_addition'::text, 'yeast'::text])))
);


--
-- Name: ingredient_usage_counts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ingredient_usage_counts WITH (security_invoker='true') AS
 SELECT ingredient_id,
    count(DISTINCT recipe_id) AS recipe_count
   FROM public.recipe_ingredients
  WHERE (ingredient_id IS NOT NULL)
  GROUP BY ingredient_id;


--
-- Name: ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredients (
    id bigint NOT NULL,
    name text NOT NULL,
    unit text,
    price numeric,
    extract_pct numeric,
    alpha_pct numeric,
    yeast_factor numeric,
    supplier text,
    status text DEFAULT 'active'::text NOT NULL,
    created_by uuid,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    category_id bigint,
    version_major integer DEFAULT 1 NOT NULL,
    version_minor integer DEFAULT 0 NOT NULL,
    ingredient_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    version_status text DEFAULT 'current'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    supplier_2 text,
    price_2 numeric,
    price_unit_1 text,
    price_unit_2 text,
    color_ebc numeric,
    allergens jsonb,
    ingredient_declaration text,
    storage_temperature text,
    shelf_life numeric,
    shelf_life_after_opening numeric,
    density numeric,
    alcohol_pct numeric,
    shelf_life_unit text,
    shelf_life_after_opening_unit text,
    supplier_3 text,
    price_3 numeric,
    price_unit_3 text,
    price_per_kg numeric,
    price_per_kg_2 numeric,
    price_per_kg_3 numeric,
    minimum_stock numeric,
    CONSTRAINT ingredients_shelf_life_after_opening_unit_check CHECK (((shelf_life_after_opening_unit IS NULL) OR (shelf_life_after_opening_unit = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_shelf_life_unit_check CHECK (((shelf_life_unit IS NULL) OR (shelf_life_unit = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'phasing_out'::text]))),
    CONSTRAINT ingredients_version_status_check CHECK ((version_status = ANY (ARRAY['current'::text, 'archived'::text])))
);


--
-- Name: COLUMN ingredients.price_per_kg; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg IS 'Prijs per kg voor Supplier #1, los van prijs/eenheid_prijs_1 (die de doseereenheid volgt).';


--
-- Name: COLUMN ingredients.price_per_kg_2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg_2 IS 'Prijs per kg voor Supplier #2.';


--
-- Name: COLUMN ingredients.price_per_kg_3; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg_3 IS 'Prijs per kg voor Supplier #3.';


--
-- Name: COLUMN ingredients.minimum_stock; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.minimum_stock IS 'Ondergrens voor de Stock overview-pagina ("bijna leeg"-signaal). Eenheid wordt afgeleid uit ingredients.eenheid (het deel vóór een eventuele ''/'', dus g/hl -> g) -- geen apart eenheid-veld nodig.';


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
-- Name: lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lots (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    supplier text,
    lot_code text,
    received_date date DEFAULT CURRENT_DATE NOT NULL,
    quantity_received numeric NOT NULL,
    unit text,
    package_count text,
    location text,
    receiving_check boolean DEFAULT false NOT NULL,
    incoming_inspection boolean DEFAULT false NOT NULL,
    best_before_date date,
    alpha_pct numeric,
    status text DEFAULT 'active'::text NOT NULL,
    document_path text,
    note text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by uuid,
    CONSTRAINT lots_status_check CHECK ((status = ANY (ARRAY['active'::text, 'empty'::text, 'closed'::text])))
);


--
-- Name: lots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lots ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lots_id_seq
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
-- Name: product_sheet_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_sheet_revisions (
    id bigint NOT NULL,
    product_sheet_id bigint NOT NULL,
    version integer NOT NULL,
    recipe_version_major integer,
    recipe_version_minor integer,
    date date DEFAULT CURRENT_DATE NOT NULL,
    changed_by_name text,
    change_description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: product_sheet_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.product_sheet_revisions_id_seq
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
    status text DEFAULT 'active'::text NOT NULL,
    current_version integer DEFAULT 1 NOT NULL,
    excise_tax_category text,
    barrel_aged_hl numeric,
    barrel_type text,
    barrel_days numeric,
    energy_kj numeric,
    energy_kcal numeric,
    fat_g numeric,
    carbohydrates_g numeric,
    protein_g numeric,
    salt_g numeric,
    remarks text,
    sync_snapshot jsonb,
    based_on_version_major integer,
    based_on_version_minor integer,
    updated_at timestamp with time zone,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT product_sheets_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])))
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
    current_version,
    updated_at,
    based_on_version_major,
    based_on_version_minor,
    (sync_snapshot ->> 'hash'::text) AS stored_hash,
    public.product_sheet_relevant_hash(recipe_group_id) AS current_hash,
    COALESCE(((sync_snapshot ->> 'hash'::text) = public.product_sheet_relevant_hash(recipe_group_id)), false) AS in_sync
   FROM public.product_sheets ps
  WHERE (status <> 'archived'::text);


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
-- Name: recipe_brewing_specs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_brewing_specs (
    recipe_id bigint NOT NULL,
    mash_filter_chambers numeric,
    roller_mill text,
    mash_thickness numeric,
    boil_volume numeric,
    wort_precooler_temp numeric,
    brew_final_volume numeric,
    target_evaporation numeric,
    boil_intensity numeric,
    whirlpool_rest numeric,
    lauter_factor numeric,
    special_bin_load_kg numeric,
    special_bin_name text,
    mash_in_temp numeric,
    mash_in_time numeric,
    mash_step1_temp numeric,
    mash_step1_time numeric,
    mash_step2_temp numeric,
    mash_step2_time numeric,
    mash_step3_temp numeric,
    mash_step3_time numeric,
    mash_step4_temp numeric,
    mash_step4_time numeric,
    mash_out_temp numeric,
    mash_out_time numeric,
    cumulative_sparge_volume numeric,
    expected_extract_boil_start numeric,
    water_addition_volume_cooling numeric,
    sparge_1 numeric,
    sparge_2 numeric,
    sparge_3 numeric,
    sparge_4 numeric,
    first_wort numeric,
    sparge_water numeric,
    sparge_runoff numeric,
    total_lautered_volume numeric,
    mash_in_acid_l numeric,
    mash_in_tannins_l numeric,
    boil_acid_l numeric,
    inline_sparge_acid_l numeric,
    mash_water numeric,
    ph_mash text,
    ph_boil_start text,
    ph_boil_end text,
    aeration numeric,
    original_gravity_correction_brewhouse numeric,
    brewhouse_recipe_name_wp text,
    brewhouse_recipe_name_jk text
);


--
-- Name: recipe_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_comments (
    recipe_id bigint NOT NULL,
    comments text[]
);


--
-- Name: recipe_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_costs (
    recipe_id bigint NOT NULL,
    cost_cellar_per_kge numeric,
    cost_brewhouse_per_kge numeric,
    cost_ingredients_per_hl numeric,
    beer_loss_pct numeric
);


--
-- Name: recipe_fermentation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_fermentation (
    recipe_id bigint NOT NULL,
    pitching_temp numeric,
    main_ferm_temp numeric,
    release_temp numeric,
    dry_hop_warm_temp numeric,
    dry_hop_warm_extract_1 numeric,
    dry_hop_warm_extract_2 numeric,
    dry_hop_warm_extract_3 numeric,
    fermentation_time numeric,
    lagering_time numeric,
    lagering_temp numeric,
    pasteurization numeric,
    turbidity_after_separation numeric,
    beer_risk text,
    beer_status text,
    pitching_temp_tol text,
    main_ferm_temp_tol text,
    release_temp_tol text,
    dry_hop_warm_temp_tol text,
    dry_hop_warm_extract_1_tol text,
    dry_hop_warm_extract_2_tol text,
    dry_hop_warm_extract_3_tol text,
    fermentation_time_tol text,
    lagering_time_tol text,
    lagering_temp_tol text,
    pasteurization_tol text,
    turbidity_after_separation_tol text,
    bitterness_brewhouse numeric,
    bitterness_brewhouse_tol text,
    CONSTRAINT recipe_fermentation_beer_risk_check CHECK (((beer_risk IS NULL) OR (beer_risk = ANY (ARRAY['standard'::text, 'dangerous'::text, 'contains_sugar'::text, 'sensitive'::text])))),
    CONSTRAINT recipe_fermentation_beer_status_check CHECK (((beer_status IS NULL) OR (beer_status = ANY (ARRAY['standard'::text, 'npi'::text, 'to_improve'::text]))))
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
-- Name: recipe_packaging; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_packaging (
    recipe_id bigint NOT NULL,
    ean_bottle text,
    best_before_bottle_months numeric,
    best_before_keg_months numeric,
    best_before_can_months numeric,
    abv_pct numeric,
    formats jsonb,
    tpo_spec numeric,
    hso_spec numeric,
    do_spec numeric,
    co2_bottle_can_spec numeric,
    co2_bottle_can_tolerance numeric,
    co2_keg_spec numeric,
    co2_keg_tolerance numeric,
    o2_keg_spec numeric
);


--
-- Name: recipe_process_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_process_steps (
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
    cellar_split boolean DEFAULT false,
    cellar_add_1 boolean DEFAULT false,
    cellar_add_2 boolean DEFAULT false,
    cellar_add_3 boolean DEFAULT false,
    cellar_add_4 boolean DEFAULT false,
    dry_hop_0c boolean,
    dry_hop_comment_warm text,
    dry_hop_method_warm text,
    dry_hop_comment_16c text,
    dry_hop_method_16c text,
    dry_hop_1_day integer,
    dry_hop_2_day integer,
    cellar_addition_day integer,
    processing_comment text,
    total_wp_hop numeric,
    total_dry_hop numeric
);


--
-- Name: recipe_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_revisions (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    date date,
    changed_by_name text,
    change_description text,
    version_major integer,
    version_minor integer,
    user_id uuid
);


--
-- Name: recipe_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_specs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_specs (
    recipe_id bigint NOT NULL,
    original_extract numeric,
    final_extract numeric,
    alcohol numeric,
    bitterness numeric,
    color numeric,
    ph numeric,
    adf_pct numeric,
    turbidity_lab numeric,
    co2_bottle numeric,
    co2_can numeric,
    co2_keg numeric,
    headspace_o2 numeric,
    dissolved_o2 numeric,
    original_extract_tol text,
    final_extract_tol text,
    alcohol_tol text,
    bitterness_tol text,
    color_tol text,
    ph_tol text,
    adf_pct_tol text,
    turbidity_lab_tol text,
    co2_bottle_tol text,
    co2_can_tol text,
    co2_keg_tol text,
    headspace_o2_tol text,
    dissolved_o2_tol text
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
    alkalinity numeric
);


--
-- Name: recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipes (
    id bigint NOT NULL,
    name text NOT NULL,
    beer_style text,
    location text,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    version_major integer DEFAULT 1 NOT NULL,
    version_minor integer DEFAULT 0 NOT NULL,
    created_by uuid,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_volume_hl numeric,
    recipe_color text,
    flavor_description text,
    flavor_keywords text[],
    serving_temperature numeric,
    color_srm numeric,
    color_free_text text,
    CONSTRAINT recipes_location_check CHECK ((location = ANY (ARRAY['wp'::text, 'jk'::text]))),
    CONSTRAINT recipes_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'archived'::text])))
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
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movements (
    id bigint NOT NULL,
    lot_id bigint,
    movement_type text NOT NULL,
    quantity numeric NOT NULL,
    batch_id bigint,
    recipe_ingredient_id bigint,
    note text,
    booked_in_accounting boolean DEFAULT false NOT NULL,
    booked_by uuid,
    booked_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    off_recipe boolean DEFAULT false NOT NULL,
    entered_quantity numeric,
    entered_unit text,
    is_spoilage boolean DEFAULT false NOT NULL,
    is_correction boolean DEFAULT false NOT NULL,
    CONSTRAINT stock_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['receipt'::text, 'reservation'::text, 'consumption'::text, 'correction'::text])))
);


--
-- Name: stock_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stock_movements ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.stock_movements_id_seq
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
-- Name: water_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_settings (
    id smallint DEFAULT 1 NOT NULL,
    description text DEFAULT 'Jopen ambient water'::text NOT NULL,
    measured_on date,
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT water_settings_id_check CHECK ((id = 1))
);


--
-- Name: water_settings_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_settings_history (
    id bigint NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    updated_by uuid,
    data jsonb NOT NULL
);


--
-- Name: water_settings_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.water_settings_history ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.water_settings_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batches batches_batch_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_batch_number_key UNIQUE (batch_number);


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
-- Name: brew_planning_history brew_planning_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_history
    ADD CONSTRAINT brew_planning_history_pkey PRIMARY KEY (id);


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
-- Name: ingredient_declarations ingredient_declarations_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declarations
    ADD CONSTRAINT ingredient_declarations_name_key UNIQUE (name);


--
-- Name: ingredient_declarations ingredient_declarations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declarations
    ADD CONSTRAINT ingredient_declarations_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documents ingredient_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documents ingredient_documents_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_storage_path_key UNIQUE (storage_path);


--
-- Name: ingredient_revisions ingredient_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_pkey PRIMARY KEY (id);


--
-- Name: ingredients ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_pkey PRIMARY KEY (id);


--
-- Name: lots lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_pkey PRIMARY KEY (id);


--
-- Name: permission_modules permission_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_modules
    ADD CONSTRAINT permission_modules_pkey PRIMARY KEY (module_key);


--
-- Name: product_sheet_revisions product_sheet_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisions
    ADD CONSTRAINT product_sheet_revisions_pkey PRIMARY KEY (id);


--
-- Name: product_sheets product_sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_pkey PRIMARY KEY (id);


--
-- Name: recipe_brewing_specs recipe_brewing_specs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brewing_specs
    ADD CONSTRAINT recipe_brewing_specs_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_comments recipe_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_costs recipe_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_costs
    ADD CONSTRAINT recipe_costs_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_fermentation recipe_fermentation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentation
    ADD CONSTRAINT recipe_fermentation_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_ingredients recipe_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_pkey PRIMARY KEY (id);


--
-- Name: recipe_packaging recipe_packaging_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_packaging
    ADD CONSTRAINT recipe_packaging_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_process_steps recipe_process_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_process_steps
    ADD CONSTRAINT recipe_process_steps_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_revisions recipe_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_pkey PRIMARY KEY (id);


--
-- Name: recipe_specs recipe_specs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specs
    ADD CONSTRAINT recipe_specs_pkey PRIMARY KEY (recipe_id);


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
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


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
-- Name: water_settings_history water_settings_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings_history
    ADD CONSTRAINT water_settings_history_pkey PRIMARY KEY (id);


--
-- Name: water_settings water_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings
    ADD CONSTRAINT water_settings_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_splits_brew_planning_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brew_planning_splits_brew_planning_id_idx ON public.brew_planning_splits USING btree (brew_planning_id);


--
-- Name: idx_batches_batch_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_batch_number ON public.batches USING btree (batch_number DESC);


--
-- Name: idx_batches_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_recipe_id ON public.batches USING btree (recipe_id);


--
-- Name: idx_brew_capacity_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_capacity_year_week ON public.brew_capacity USING btree (iso_year, week_number);


--
-- Name: idx_brew_planning_history_planning_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_history_planning_id ON public.brew_planning_history USING btree (brew_planning_id);


--
-- Name: idx_brew_planning_history_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_history_updated_at ON public.brew_planning_history USING btree (updated_at DESC);


--
-- Name: idx_brew_planning_recipe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe ON public.brew_planning USING btree (recipe_id);


--
-- Name: idx_brew_planning_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe_group_id ON public.brew_planning USING btree (recipe_group_id);


--
-- Name: idx_brew_planning_splits_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_splits_recipe_id ON public.brew_planning_splits USING btree (recipe_id);


--
-- Name: idx_brew_planning_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_year_week ON public.brew_planning USING btree (iso_year, week_number);


--
-- Name: idx_ingredient_documents_ing_status_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documents_ing_status_type ON public.ingredient_documents USING btree (ingredient_id, status, document_type_id);


--
-- Name: idx_ingredient_documents_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documents_ingredient_id ON public.ingredient_documents USING btree (ingredient_id);


--
-- Name: idx_ingredient_revisions_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_revisions_ingredient_id ON public.ingredient_revisions USING btree (ingredient_id);


--
-- Name: idx_ingredients_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredients_group_id ON public.ingredients USING btree (ingredient_group_id);


--
-- Name: idx_lots_ingredient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lots_ingredient ON public.lots USING btree (ingredient_id);


--
-- Name: idx_lots_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lots_status ON public.lots USING btree (status);


--
-- Name: idx_recipe_ingredients_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_ingredient_id ON public.recipe_ingredients USING btree (ingredient_id);


--
-- Name: idx_recipe_ingredients_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_recipe_id ON public.recipe_ingredients USING btree (recipe_id);


--
-- Name: idx_recipe_revisions_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_revisions_recipe_id ON public.recipe_revisions USING btree (recipe_id);


--
-- Name: idx_recipes_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipes_recipe_group_id ON public.recipes USING btree (recipe_group_id);


--
-- Name: idx_stock_movements_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_batch ON public.stock_movements USING btree (batch_id);


--
-- Name: idx_stock_movements_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_lot ON public.stock_movements USING btree (lot_id);


--
-- Name: idx_stock_movements_movement_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_movement_type ON public.stock_movements USING btree (movement_type);


--
-- Name: idx_stock_movements_recipe_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_recipe_ingredient_id ON public.stock_movements USING btree (recipe_ingredient_id);


--
-- Name: product_sheet_revisions_product_sheet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_sheet_revisions_product_sheet_id_idx ON public.product_sheet_revisions USING btree (product_sheet_id);


--
-- Name: product_sheets_recipe_group_id_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX product_sheets_recipe_group_id_active_idx ON public.product_sheets USING btree (recipe_group_id) WHERE (status <> 'archived'::text);


--
-- Name: brew_planning trg_brew_planning_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brew_planning_history AFTER INSERT OR DELETE OR UPDATE ON public.brew_planning FOR EACH ROW EXECUTE FUNCTION public.log_brew_planning_change();


--
-- Name: ingredients trg_ingredients_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ingredients_updated_at BEFORE UPDATE ON public.ingredients FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: recipes trg_recipes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recipes_updated_at BEFORE UPDATE ON public.recipes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: water_settings trg_water_settings_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_settings_log AFTER INSERT OR UPDATE ON public.water_settings FOR EACH ROW EXECUTE FUNCTION public.water_settings_log();


--
-- Name: water_settings trg_water_settings_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_settings_stamp BEFORE UPDATE ON public.water_settings FOR EACH ROW EXECUTE FUNCTION public.water_settings_stamp();


--
-- Name: batches batches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


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
-- Name: brew_planning brew_planning_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: brew_planning_history brew_planning_history_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_history
    ADD CONSTRAINT brew_planning_history_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


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
-- Name: ingredient_documents ingredient_documents_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id);


--
-- Name: ingredient_documents ingredient_documents_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredient_documents ingredient_documents_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.users(id);


--
-- Name: ingredient_revisions ingredient_revisions_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredient_revisions ingredient_revisions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: ingredients ingredients_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ingredient_categories(id);


--
-- Name: ingredients ingredients_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: ingredients ingredients_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: lots lots_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: lots lots_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: lots lots_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.users(id);


--
-- Name: product_sheet_revisions product_sheet_revisions_product_sheet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisions
    ADD CONSTRAINT product_sheet_revisions_product_sheet_id_fkey FOREIGN KEY (product_sheet_id) REFERENCES public.product_sheets(id) ON DELETE CASCADE;


--
-- Name: product_sheets product_sheets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: product_sheets product_sheets_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: recipe_brewing_specs recipe_brewing_specs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brewing_specs
    ADD CONSTRAINT recipe_brewing_specs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_comments recipe_comments_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_costs recipe_costs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_costs
    ADD CONSTRAINT recipe_costs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_fermentation recipe_fermentation_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentation
    ADD CONSTRAINT recipe_fermentation_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


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
-- Name: recipe_packaging recipe_packaging_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_packaging
    ADD CONSTRAINT recipe_packaging_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_process_steps recipe_process_steps_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_process_steps
    ADD CONSTRAINT recipe_process_steps_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_revisions recipe_revisions_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_revisions recipe_revisions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: recipe_specs recipe_specs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specs
    ADD CONSTRAINT recipe_specs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_water recipe_water_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_water
    ADD CONSTRAINT recipe_water_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipes recipes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: recipes recipes_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


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
-- Name: stock_movements stock_movements_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id);


--
-- Name: stock_movements stock_movements_booked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_booked_by_fkey FOREIGN KEY (booked_by) REFERENCES public.users(id);


--
-- Name: stock_movements stock_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: stock_movements stock_movements_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: stock_movements stock_movements_recipe_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_recipe_ingredient_id_fkey FOREIGN KEY (recipe_ingredient_id) REFERENCES public.recipe_ingredients(id);


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
-- Name: water_settings_history water_settings_history_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings_history
    ADD CONSTRAINT water_settings_history_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: water_settings water_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings
    ADD CONSTRAINT water_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


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
-- Name: brew_planning_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning_history ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning_history brew_planning_history_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_history_select ON public.brew_planning_history FOR SELECT USING (public.can_view('brewing_planning'::text));


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
-- Name: ingredient_declarations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_declarations ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_declarations ingredient_declarations_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_delete ON public.ingredient_declarations FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: ingredient_declarations ingredient_declarations_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_insert ON public.ingredient_declarations FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_declarations ingredient_declarations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_select ON public.ingredient_declarations FOR SELECT USING (true);


--
-- Name: ingredient_declarations ingredient_declarations_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_update ON public.ingredient_declarations FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_documents ingredient_documents_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_delete ON public.ingredient_documents FOR DELETE USING (public.can_delete('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_insert ON public.ingredient_documents FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_select ON public.ingredient_documents FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_update ON public.ingredient_documents FOR UPDATE USING (public.can_edit('ingredients'::text)) WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_revisions ingredient_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisions_insert ON public.ingredient_revisions FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisions ingredient_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisions_select ON public.ingredient_revisions FOR SELECT USING (public.can_view('ingredients'::text));


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
-- Name: lots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lots ENABLE ROW LEVEL SECURITY;

--
-- Name: lots lots_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_delete ON public.lots FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: lots lots_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_insert ON public.lots FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: lots lots_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_select ON public.lots FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: lots lots_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_update ON public.lots FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: permission_modules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_modules ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_modules permission_modules_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY permission_modules_select ON public.permission_modules FOR SELECT USING (true);


--
-- Name: product_sheet_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: product_sheet_revisions product_sheet_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisions_insert ON public.product_sheet_revisions FOR INSERT WITH CHECK (public.can_edit('product_sheets'::text));


--
-- Name: product_sheet_revisions product_sheet_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisions_select ON public.product_sheet_revisions FOR SELECT USING (public.can_view('product_sheets'::text));


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
-- Name: recipe_brewing_specs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_brewing_specs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_brewing_specs recipe_brewing_specs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_delete ON public.recipe_brewing_specs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_insert ON public.recipe_brewing_specs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_select ON public.recipe_brewing_specs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_update ON public.recipe_brewing_specs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


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
-- Name: recipe_costs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_costs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_costs recipe_costs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_delete ON public.recipe_costs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_costs recipe_costs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_insert ON public.recipe_costs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_costs recipe_costs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_select ON public.recipe_costs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_costs recipe_costs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_update ON public.recipe_costs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_fermentation ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_fermentation recipe_fermentation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_delete ON public.recipe_fermentation FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_insert ON public.recipe_fermentation FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_select ON public.recipe_fermentation FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_update ON public.recipe_fermentation FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


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
-- Name: recipe_packaging; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_packaging ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_packaging recipe_packaging_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_delete ON public.recipe_packaging FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_insert ON public.recipe_packaging FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_select ON public.recipe_packaging FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_update ON public.recipe_packaging FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_process_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_process_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_process_steps recipe_process_steps_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_delete ON public.recipe_process_steps FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_insert ON public.recipe_process_steps FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_select ON public.recipe_process_steps FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_update ON public.recipe_process_steps FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_revisions recipe_revisions_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_delete ON public.recipe_revisions FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_insert ON public.recipe_revisions FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_select ON public.recipe_revisions FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_update ON public.recipe_revisions FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_specs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_specs recipe_specs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_delete ON public.recipe_specs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_specs recipe_specs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_insert ON public.recipe_specs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specs recipe_specs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_select ON public.recipe_specs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_specs recipe_specs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_update ON public.recipe_specs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


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
-- Name: role_permissions role_permissions_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_delete_admin ON public.role_permissions FOR DELETE USING (public.is_admin());


--
-- Name: role_permissions role_permissions_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_insert_admin ON public.role_permissions FOR INSERT WITH CHECK (public.is_admin());


--
-- Name: role_permissions role_permissions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_select ON public.role_permissions FOR SELECT USING (true);


--
-- Name: role_permissions role_permissions_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_update_admin ON public.role_permissions FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: roles roles_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_delete_admin ON public.roles FOR DELETE USING (public.is_admin());


--
-- Name: roles roles_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_insert_admin ON public.roles FOR INSERT WITH CHECK (public.is_admin());


--
-- Name: roles roles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_select ON public.roles FOR SELECT USING (true);


--
-- Name: roles roles_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_update_admin ON public.roles FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: stock_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: stock_movements stock_movements_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_delete ON public.stock_movements FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: stock_movements stock_movements_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_insert ON public.stock_movements FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: stock_movements stock_movements_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_select ON public.stock_movements FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: stock_movements stock_movements_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_update ON public.stock_movements FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


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
-- Name: users users_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_delete_admin ON public.users FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: users users_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_insert_admin ON public.users FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: users users_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_select ON public.users FOR SELECT TO authenticated USING (true);


--
-- Name: users users_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_update_admin ON public.users FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: water_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: water_settings_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_settings_history ENABLE ROW LEVEL SECURITY;

--
-- Name: water_settings_history water_settings_history_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_history_select ON public.water_settings_history FOR SELECT USING (true);


--
-- Name: water_settings water_settings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_select ON public.water_settings FOR SELECT USING (true);


--
-- Name: water_settings water_settings_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_update ON public.water_settings FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


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
-- Name: FUNCTION log_brew_planning_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.log_brew_planning_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.log_brew_planning_change() TO service_role;


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
-- Name: FUNCTION set_last_login(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_last_login() FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_last_login() TO service_role;
GRANT ALL ON FUNCTION public.set_last_login() TO authenticated;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION water_settings_log(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.water_settings_log() FROM PUBLIC;
GRANT ALL ON FUNCTION public.water_settings_log() TO service_role;


--
-- Name: FUNCTION water_settings_stamp(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.water_settings_stamp() TO service_role;


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
-- Name: TABLE brew_planning_history; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history TO authenticated;
GRANT ALL ON TABLE public.brew_planning_history TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;


--
-- Name: TABLE brew_planning_history_detailed; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history_detailed TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history_detailed TO authenticated;
GRANT ALL ON TABLE public.brew_planning_history_detailed TO service_role;


--
-- Name: TABLE brew_planning_splits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO authenticated;
GRANT ALL ON TABLE public.brew_planning_splits TO service_role;


--
-- Name: TABLE document_types; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO authenticated;
GRANT ALL ON TABLE public.document_types TO service_role;


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
-- Name: TABLE ingredient_declarations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declarations TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declarations TO authenticated;
GRANT ALL ON TABLE public.ingredient_declarations TO service_role;


--
-- Name: TABLE ingredient_documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documents TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documents TO authenticated;
GRANT ALL ON TABLE public.ingredient_documents TO service_role;


--
-- Name: SEQUENCE ingredient_documents_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documents_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documents_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_documents_id_seq TO service_role;


--
-- Name: TABLE ingredient_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisions TO authenticated;
GRANT ALL ON TABLE public.ingredient_revisions TO service_role;


--
-- Name: SEQUENCE ingredient_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_revisions_id_seq TO service_role;


--
-- Name: TABLE recipe_ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO authenticated;
GRANT ALL ON TABLE public.recipe_ingredients TO service_role;


--
-- Name: TABLE ingredient_usage_counts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_usage_counts TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_usage_counts TO authenticated;
GRANT ALL ON TABLE public.ingredient_usage_counts TO service_role;


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
-- Name: TABLE lots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lots TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lots TO authenticated;
GRANT ALL ON TABLE public.lots TO service_role;


--
-- Name: SEQUENCE lots_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.lots_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.lots_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.lots_id_seq TO service_role;


--
-- Name: TABLE permission_modules; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO authenticated;
GRANT ALL ON TABLE public.permission_modules TO service_role;


--
-- Name: TABLE product_sheet_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisions TO authenticated;
GRANT ALL ON TABLE public.product_sheet_revisions TO service_role;


--
-- Name: SEQUENCE product_sheet_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.product_sheet_revisions_id_seq TO service_role;


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
-- Name: TABLE recipe_brewing_specs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brewing_specs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brewing_specs TO authenticated;
GRANT ALL ON TABLE public.recipe_brewing_specs TO service_role;


--
-- Name: TABLE recipe_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO authenticated;
GRANT ALL ON TABLE public.recipe_comments TO service_role;


--
-- Name: TABLE recipe_costs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_costs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_costs TO authenticated;
GRANT ALL ON TABLE public.recipe_costs TO service_role;


--
-- Name: TABLE recipe_fermentation; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentation TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentation TO authenticated;
GRANT ALL ON TABLE public.recipe_fermentation TO service_role;


--
-- Name: SEQUENCE recipe_ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_ingredients_id_seq TO service_role;


--
-- Name: TABLE recipe_packaging; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_packaging TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_packaging TO authenticated;
GRANT ALL ON TABLE public.recipe_packaging TO service_role;


--
-- Name: TABLE recipe_process_steps; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_process_steps TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_process_steps TO authenticated;
GRANT ALL ON TABLE public.recipe_process_steps TO service_role;


--
-- Name: TABLE recipe_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisions TO authenticated;
GRANT ALL ON TABLE public.recipe_revisions TO service_role;


--
-- Name: SEQUENCE recipe_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_revisions_id_seq TO service_role;


--
-- Name: TABLE recipe_specs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specs TO authenticated;
GRANT ALL ON TABLE public.recipe_specs TO service_role;


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
-- Name: TABLE stock_movements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.stock_movements TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.stock_movements TO authenticated;
GRANT ALL ON TABLE public.stock_movements TO service_role;


--
-- Name: SEQUENCE stock_movements_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.stock_movements_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.stock_movements_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stock_movements_id_seq TO service_role;


--
-- Name: TABLE units; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO authenticated;
GRANT ALL ON TABLE public.units TO service_role;


--
-- Name: TABLE water_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings TO authenticated;
GRANT ALL ON TABLE public.water_settings TO service_role;


--
-- Name: TABLE water_settings_history; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings_history TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings_history TO authenticated;
GRANT ALL ON TABLE public.water_settings_history TO service_role;


--
-- Name: SEQUENCE water_settings_history_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.water_settings_history_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.water_settings_history_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.water_settings_history_id_seq TO service_role;


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


