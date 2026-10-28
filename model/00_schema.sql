-- Called first by build_model.ps1, inside its single transaction.
-- The locks keep another session from changing raw during the comparison.
LOCK TABLE raw.orders, raw.order_items, raw.order_payments, raw.order_reviews,
    raw.products, raw.sellers, raw.customers, raw.product_category_translation
    IN SHARE MODE;

CREATE OR REPLACE FUNCTION pg_temp.raw_fingerprints()
RETURNS TABLE (table_name text, row_count bigint, content_hash text)
LANGUAGE plpgsql AS $$
DECLARE
    source_name text;
BEGIN
    FOREACH source_name IN ARRAY ARRAY[
        'orders', 'order_items', 'order_payments', 'order_reviews',
        'products', 'sellers', 'customers', 'product_category_translation'
    ] LOOP
        -- Sort row hashes before hashing the multiset, so physical row order
        -- does not matter and repeated rows still contribute repeatedly.
        RETURN QUERY EXECUTE format(
            'SELECT %L::text, count(*)::bigint, '
            'md5(coalesce(string_agg(md5(to_jsonb(t)::text), '''' '
            'ORDER BY md5(to_jsonb(t)::text)), '''')) FROM raw.%I AS t',
            source_name, source_name
        );
    END LOOP;
END;
$$;

CREATE TEMP TABLE raw_snapshot ON COMMIT DROP AS
SELECT * FROM pg_temp.raw_fingerprints();

-- In addition to row contents, track the schema and table definitions. This
-- catches DDL such as adding a raw table, dropping a constraint or changing a
-- column default even when the existing row values happen to be unchanged.
CREATE OR REPLACE FUNCTION pg_temp.raw_structure_fingerprint()
RETURNS text LANGUAGE sql AS $$
    WITH objects AS (
        SELECT 'schema|' || jsonb_build_array(n.oid, n.nspname, n.nspowner, n.nspacl)::text AS item
        FROM pg_namespace n WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'relation|' || jsonb_build_array(c.oid, c.relname, c.relkind, c.relowner,
            c.relpersistence, c.relacl, c.reloptions, c.relrowsecurity, c.relforcerowsecurity)::text
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'column|' || jsonb_build_array(c.oid, a.attnum, a.attname, a.atttypid,
            a.atttypmod, a.attcollation, a.attnotnull, a.attidentity, a.attgenerated,
            a.attacl, a.attoptions, pg_get_expr(ad.adbin, ad.adrelid))::text
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
        WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'constraint|' || jsonb_build_array(c.oid, c.conname, c.conrelid,
            c.convalidated, c.condeferrable, c.condeferred, pg_get_constraintdef(c.oid, true))::text
        FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'index|' || jsonb_build_array(i.indexrelid, i.indrelid, i.indisvalid,
            i.indisready, pg_get_indexdef(i.indexrelid))::text
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'trigger|' || jsonb_build_array(t.oid, t.tgrelid, t.tgenabled,
            pg_get_triggerdef(t.oid, true))::text
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'rule|' || jsonb_build_array(r.oid, r.ev_class, pg_get_ruledef(r.oid, true))::text
        FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class
        JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'policy|' || jsonb_build_array(p.oid, p.polrelid, p.polname, p.polcmd,
            p.polpermissive, p.polroles, pg_get_expr(p.polqual, p.polrelid),
            pg_get_expr(p.polwithcheck, p.polrelid))::text
        FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'type|' || jsonb_build_array(t.oid, t.typname, t.typowner, t.typtype,
            t.typcategory, t.typbasetype, t.typtypmod, t.typnotnull, t.typacl)::text
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'raw'
        UNION ALL
        SELECT 'routine|' || jsonb_build_array(p.oid, p.proname, p.proargtypes::text,
            p.prorettype, p.proowner, p.prokind, p.provolatile, p.prosrc, p.probin,
            p.proacl, p.proconfig)::text
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'raw'
    )
    SELECT md5(coalesce(string_agg(item, E'\n' ORDER BY item), '')) FROM objects;
$$;

CREATE TEMP TABLE raw_structure_snapshot ON COMMIT DROP AS
SELECT pg_temp.raw_structure_fingerprint() AS structure_hash;

CREATE OR REPLACE FUNCTION pg_temp.assert_raw_unchanged()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    differences text;
BEGIN
    WITH current_snapshot AS MATERIALIZED (SELECT * FROM pg_temp.raw_fingerprints()),
    changed AS (
        (SELECT * FROM pg_temp.raw_snapshot EXCEPT ALL SELECT * FROM current_snapshot)
        UNION
        (SELECT * FROM current_snapshot EXCEPT ALL SELECT * FROM pg_temp.raw_snapshot)
    )
    SELECT string_agg(changed.table_name, ', ' ORDER BY changed.table_name)
    INTO differences FROM changed;

    IF differences IS NOT NULL THEN
        RAISE EXCEPTION 'raw changed during build: %', differences;
    END IF;
    IF pg_temp.raw_structure_fingerprint() IS DISTINCT FROM
       (SELECT structure_hash FROM pg_temp.raw_structure_snapshot) THEN
        RAISE EXCEPTION 'raw schema or table definitions changed during build';
    END IF;
END;
$$;

-- CASCADE is needed for objects within core/mart. Reject dependants outside
-- those schemas first, so a rebuild cannot silently remove someone else's view
-- or constraint. pg_identify_object also identifies dependencies via rules.
DO $$
DECLARE
    external_dependants text;
BEGIN
    SELECT string_agg(DISTINCT dependent.identity, E'\n  ')
    INTO external_dependants
    FROM pg_depend AS d
    CROSS JOIN LATERAL pg_identify_object(d.refclassid, d.refobjid, d.refobjsubid) AS referenced
    CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) AS dependent
    -- Rules (including view definitions), triggers, defaults and policies may
    -- not have a schema in pg_identify_object. Resolve it through their table.
    LEFT JOIN pg_rewrite AS rule ON d.classid = 'pg_rewrite'::regclass AND rule.oid = d.objid
    LEFT JOIN pg_trigger AS trigger_row ON d.classid = 'pg_trigger'::regclass AND trigger_row.oid = d.objid
    LEFT JOIN pg_attrdef AS default_row ON d.classid = 'pg_attrdef'::regclass AND default_row.oid = d.objid
    LEFT JOIN pg_policy AS policy_row ON d.classid = 'pg_policy'::regclass AND policy_row.oid = d.objid
    LEFT JOIN pg_class AS owner_relation ON owner_relation.oid =
        COALESCE(rule.ev_class, trigger_row.tgrelid, default_row.adrelid, policy_row.polrelid)
    LEFT JOIN pg_namespace AS owner_schema ON owner_schema.oid = owner_relation.relnamespace
    WHERE referenced.schema IN ('core', 'mart')
      AND COALESCE(dependent.schema, owner_schema.nspname) IS NOT NULL
      -- TOAST tables are internal storage of the model's own tables.
      AND COALESCE(dependent.schema, owner_schema.nspname) NOT IN ('core', 'mart', 'pg_toast')
      AND COALESCE(dependent.schema, owner_schema.nspname) NOT LIKE 'pg_temp_%'
      AND COALESCE(dependent.schema, owner_schema.nspname) NOT LIKE 'pg_toast_temp_%'
      AND d.deptype IN ('n', 'a', 'i', 'e');

    IF external_dependants IS NOT NULL THEN
        RAISE EXCEPTION 'objects outside core/mart depend on the model:%  %',
            E'\n', external_dependants;
    END IF;
END;
$$;

DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;
CREATE SCHEMA mart;
