CREATE OR REPLACE FUNCTION
_param_expression_string(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
  SELECT CASE
    WHEN _modifier = '' THEN
      quote_ident(_table) || '.value ilike ' || quote_literal('%' || _value || '%')
    WHEN _modifier = 'exact' THEN
      quote_ident(_table) || '.value = ' || quote_literal(_value)
    END;
$$;

CREATE OR REPLACE FUNCTION
_param_expression_reference(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
  SELECT
    '(' || quote_ident(_table) || '.logical_id = ' || quote_literal(_value) || ' OR ' || quote_ident(_table) || '.url = ' || quote_literal(_value) || ')' ||
    CASE WHEN _modifier <> '' THEN
      ' AND ' || quote_ident(_table) || '.resource_type = ' || quote_literal(_modifier)
    ELSE
      ''
    END;
$$;

CREATE OR REPLACE FUNCTION
_param_expression_quantity(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
  SELECT
  quote_ident(_table) || '.value ' ||

  CASE
  WHEN op = '' OR op IS NULL THEN
    '= ' || quote_literal(p.val)
  WHEN op = '<' THEN
    '< ' || quote_literal(p.val)
  WHEN op = '>' THEN
    '>' || quote_literal(p.val)
  WHEN op = '~' THEN
    '<@ numrange(' || val - val * 0.05 || ',' || val + val * 0.05 || ')'
  ELSE
    '= "unknown operator: ' || op || '"'
  END ||

  CASE WHEN array_length(p.c, 1) = 3 THEN
    CASE WHEN p.c[2] IS NOT NULL AND p.c[2] <> '' THEN
      ' AND ' || quote_ident(_table) || '.system = ' || quote_literal(p.c[2])
    ELSE
      ''
    END ||
    CASE WHEN p.c[3] IS NOT NULL AND p.c[3] <> '' THEN
      ' AND ' || quote_ident(_table) || '.units = ' || quote_literal(p.c[3])
    ELSE
      ''
    END
  WHEN array_length(p.c, 1) = 1 THEN
    ''
  ELSE
    '"wrong number of compoments of search string, must be 1 or 3"'
  END
  FROM
  (SELECT
    regexp_split_to_array(_value, '\|') AS c,
    (regexp_matches(split_part(_value, '|', 1), '^(<|>|~)?'))[1] AS op,
    (regexp_matches(split_part(_value, '|', 1), '^(<|>|~)?(.+)$'))[2]::numeric AS val) p;
$$;

CREATE OR REPLACE FUNCTION
_param_expression_token(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
  (SELECT
  CASE WHEN _modifier = '' THEN
    CASE WHEN p.count = 1 THEN
      quote_ident(_table) || '.code = ' || quote_literal(p.c1)
    WHEN p.count = 2 THEN
      quote_ident(_table) || '.code = ' || quote_literal(p.c2) || ' AND ' ||
      quote_ident(_table) || '.namespace = ' || quote_literal(p.c1)
    END
  WHEN _modifier = 'text' THEN
    quote_ident(_table) || '.text = ' || quote_literal(_value)
  ELSE
    '"unknown modifier' || _modifier || '"'
  END
  FROM
    (SELECT split_part(_value, '|', 1) AS c1,
     split_part(_value, '|', 2) AS c2,
     array_length(regexp_split_to_array(_value, '\|'), 1) AS count) p);
$$;

CREATE OR REPLACE FUNCTION
_param_expression_date(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
  SELECT
  CASE WHEN op IS NULL THEN
    quote_literal(val) || '::tstzrange @> tstzrange(' || quote_ident(_table) || '."start", ' || quote_ident(_table) || '."end")'
  WHEN op = '>' THEN
    'tstzrange(' || quote_ident(_table) || '."start", ' || quote_ident(_table) || '."end") && ' || 'tstzrange(' || quote_literal(upper(val)) || ', NULL)'
  WHEN op = '<' THEN
    'tstzrange(' || quote_ident(_table) || '."start", ' || quote_ident(_table) || '."end") && ' || 'tstzrange(NULL, ' || quote_literal(lower(val)) || ')'
  ELSE
  '1'
  END
  FROM
  (SELECT
    (regexp_matches(_value, '^(<|>)?'))[1] AS op,
    convert_fhir_date_to_pgrange((regexp_matches(_value, '^(<|>)?(.+)$'))[2]) AS val) p;
$$;

CREATE OR REPLACE FUNCTION
param_expression(_table varchar, _param varchar, _type varchar, _modifier varchar, _value varchar)
RETURNS text LANGUAGE sql AS $$
WITH val_cond AS (SELECT
  CASE WHEN _type = 'string' THEN
    _param_expression_string(_table, _param, _type, _modifier, regexp_split_to_table)
  WHEN _type = 'token' THEN
    _param_expression_token(_table, _param, _type, _modifier, regexp_split_to_table)
  WHEN _type = 'date' THEN
    _param_expression_date(_table, _param, _type, _modifier, regexp_split_to_table)
  WHEN _type = 'quantity' THEN
    _param_expression_quantity(_table, _param, _type, _modifier, regexp_split_to_table)
  WHEN _type = 'reference' THEN
    _param_expression_reference(_table, _param, _type, _modifier, regexp_split_to_table)
  ELSE 'implement_me' END as cond
  FROM regexp_split_to_table(_value, ','))
SELECT
  eval_template($SQL$
    (resource.logical_id = "{{tbl}}".resource_id
     AND "{{tbl}}".param = {{param}}
     AND ({{vals_cond}}))
  $SQL$, 'tbl', _table
       , 'param', quote_literal(_param)
       , 'vals_cond',
       (SELECT string_agg(cond, ' OR ') FROM val_cond));
$$;

CREATE OR REPLACE FUNCTION
parse_search_params(_resource_type varchar, query jsonb)
RETURNS text LANGUAGE sql AS $$
    SELECT
      eval_template($SQL$
        SELECT DISTINCT(resource.logical_id)
          FROM {{res-tbl}} resource,
               {{idx_tables}}
         WHERE {{idx_conds}}
      $SQL$, 'res-tbl', lower(_resource_type)
           , 'idx_tables', string_agg((z.tbl || ' "' || z.alias || '"'), ', ')
           , 'idx_conds', string_agg(z.cond, '  AND  '))
      FROM (
      SELECT
         z.tbl
        ,z.alias
        ,string_agg(
          param_expression(z.alias, z.param_name, z.search_type, z.modifier, z.value)
          , ' AND ') as cond
        FROM (
          SELECT
            lower(_resource_type) || '_search_' || fri.search_type as tbl
            ,fri.param_name || '_idx' as alias
            ,split_part(x.key, ':', 2) as modifier
            ,*
          FROM jsonb_each_text(query) x
          JOIN fhir.resource_indexables fri
            ON fri.param_name = split_part(x.key, ':', 1)
            AND fri.resource_type =  _resource_type
        ) z
        GROUP BY tbl, alias
      ) z
$$ IMMUTABLE;

CREATE OR REPLACE FUNCTION
search_resource(resource_type varchar, query jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  res record;
BEGIN
  EXECUTE
    eval_template($SQL$
      WITH entries AS
      (SELECT
        x.logical_id as id
        ,x.last_modified_date as last_modified_date
        ,x.published as published
        ,x.data as content
        FROM "{{tbl}}" x
        WHERE logical_id IN ({{search_sql}}))
      SELECT
        json_build_object(
          'title', 'search',
          'resourceType', 'Bundle',
          'updated', now(),
          'id', gen_random_uuid(),
          'entry', COALESCE(json_agg(y.*), '[]'::json)
        ) as json
        FROM entries y
   $SQL$,
  'tbl', lower(resource_type),
  'search_sql', coalesce(
                   parse_search_params(resource_type, query),
                   ('SELECT logical_id FROM ' || lower(resource_type))))
  INTO res;

  RETURN res.json;
END
$$;

CREATE OR REPLACE FUNCTION
history_resource(_resource_type varchar, _id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  res record;
BEGIN
  EXECUTE
    eval_template($SQL$
      WITH entries AS
      (SELECT
          x.logical_id as id
          ,x.last_modified_date as last_modified_date
          ,x.published as published
          ,x.data as content
        FROM "{{tbl}}" x
        WHERE x.logical_id  = $1
        UNION
        SELECT
          x.logical_id as id
          ,x.last_modified_date as last_modified_date
          ,x.published as published
          ,x.data as content
        FROM {{tbl}}_history x
        WHERE x.logical_id  = $1)
      SELECT
        json_build_object(
          'title', 'search',
          'resourceType', 'Bundle',
          'updated', now(),
          'id', gen_random_uuid(),
          'entry', COALESCE(json_agg(y.*), '[]'::json)
        ) as json
        FROM entries y
   $SQL$, 'tbl', lower(_resource_type))
  INTO res USING _id;

  RETURN res.json;
END
$$;