-- The PostgreSQL dialect's engine functions and collations as the schema
-- calls them (src/dialect/abi.zig, docs/extension.md). Recorded in
-- abi-pg.out.
SELECT xq_pg_bool('t'), xq_pg_bool('yes'), xq_pg_bool(' off '), xq_pg_bool(1), quote(xq_pg_bool(NULL));
SELECT xq_pg_bool('maybe');
SELECT xq_pg_int2(32767), xq_pg_int4('  42 '), xq_pg_int8(2.5), xq_pg_int8(3.5), xq_pg_int4(-2.5);
SELECT xq_pg_int2(32768);
SELECT xq_pg_int4('1e3');
SELECT xq_pg_int8(9.3e18);
SELECT quote(xq_pg_jsonb('{"b": 1, "a": [1, 2.50, null], "a": true}')), quote(xq_pg_json(' {"b" : 1} '));
SELECT xq_pg_jsonb('{');
SELECT xq_pg_jsonb_get('{"a":{"b":[1,"x"]}}', 'a'), xq_pg_jsonb_get_text('{"a":"x"}', 'a'), quote(xq_pg_jsonb_get_text('{"a":null}', 'a')), xq_pg_jsonb_get('[1,2,3]', -1);
SELECT xq_pg_jsonb_path('{"a":{"b":[1,"x"]}}', '{a,b,1}'), xq_pg_jsonb_path_text('{"a":{"b":[1,"x"]}}', '{a,b,1}');
SELECT xq_pg_jsonb_contains('{"a":1,"b":[1,2]}', '{"b":[2]}'), xq_pg_jsonb_contains('[1,2]', '3'), xq_pg_jsonb_exists('{"a":1}', 'a'), xq_pg_jsonb_exists('["a"]', 'a');
SELECT xq_pg_jsonb_exists_any('{"a":1}', '{b,a}'), xq_pg_jsonb_exists_all('{"a":1}', '{b,a}');
SELECT xq_pg_jsonb_concat('{"a":1}', '{"b":2,"a":3}'), xq_pg_jsonb_delete('{"a":1,"b":2}', 'a'), xq_pg_jsonb_delete_path('{"a":{"b":1,"c":2}}', '{a,b}');
SELECT xq_postgres_jsonb_set('{"a":[1,2]}', '{a,0}', '"x"'), xq_postgres_jsonb_typeof('[1]'), xq_postgres_jsonb_strip_nulls('{"a":null,"b":1}');
SELECT xq_pg_regex('abc', '^a.c$', ''), xq_pg_regex('ABC', '^a', 'i'), xq_pg_regex('a.c', 'a\.c', ''), xq_pg_regex('foo123', '[0-9]{3}', ''), quote(xq_pg_regex(NULL, 'a', ''));
SELECT xq_pg_regex('a', '(', '');
SELECT xq_pg_interval('1 day 2 hours'), xq_pg_interval('P1Y2M3DT4H5M6.5S'), xq_pg_interval('-1 mon 3 days'), xq_pg_interval('90 minutes'), xq_pg_interval('1.5 years');
SELECT xq_pg_interval('soon');
SELECT xq_pg_interval_pl('1 day', '25 hours'), xq_pg_interval_mi('1 mon', '1 day'), xq_pg_interval_um('1 day -2 hours'), xq_pg_interval_mul('1 mon 1 day', 1.5), xq_pg_interval_div('3 days', 2);
SELECT xq_pg_date('2024-02-29'), xq_pg_date('20240229'), xq_pg_time('12:34:56.789'), xq_pg_timestamp('2024-02-29 12:34:56.5'), xq_pg_timestamptz('2024-02-29 12:34:56+02');
SELECT xq_pg_date('2023-02-29');
SELECT xq_pg_date_pli('2024-02-28', 2), xq_pg_date_mii('2024-03-01', 1), xq_pg_date_mi('2024-03-01', '2024-02-01'), xq_pg_date_pl_interval('2024-01-31', '1 mon'), xq_pg_timestamp_mi('2024-03-01 00:00:00', '2024-02-28 12:00:00');
SELECT xq_pg_timestamptz_pl_interval('2024-03-30 12:00:00', '1 day'), xq_pg_time_pl_interval('23:00:00', '2 hours'), xq_pg_time_mi_time('12:00:00', '01:30:00');
SELECT xq_pg_array_valid('{1,2,3}'), xq_pg_array_valid('{a,"b c",NULL}'), xq_pg_array_valid('{{1,2},{3,4}}'), xq_pg_array_valid('{1,'), xq_pg_array_valid(NULL);
SELECT xq_pg_array_int4('{1, 2 ,3}'), xq_pg_array_text('{a,"b c",NULL}'), xq_pg_array_numeric('{1.50,2}'), xq_pg_array_bool('{t,f,yes}');
SELECT xq_pg_array_int4('{1,x}');
SELECT xq_pg_subscript_k('{10,20,30}', 2, 3), quote(xq_pg_subscript_k('{10,20,30}', 4, 3)), xq_pg_subscript_k('{a,b}', 1, 8), xq_pg_slice('{1,2,3,4}', 2, 3);
SELECT xq_pg_array_append('{1,2}', 3), xq_pg_array_prepend(0, '{1,2}'), xq_pg_array_cat2('{1}', '{2,3}'), xq_pg_array_contains('{1,2,3}', '{3,1}'), xq_pg_array_overlap('{1,2}', '{5,2}');
SELECT xq_postgres_array_length('{1,2,3}', 1), xq_postgres_array_to_string('{a,NULL,c}', ',', '*'), xq_postgres_string_to_array('a,b,,c', ','), xq_postgres_cardinality('{{1,2},{3,4}}');
SELECT xq_postgres_left('héllo', 2), xq_postgres_right('héllo', -2), xq_postgres_lpad('7', 3, '0'), xq_postgres_split_part('a,b,c', ',', -1), xq_postgres_reverse('abc');
SELECT xq_postgres_greatest(1, NULL, 3, 2), xq_postgres_least('b', 'a'), xq_postgres_mod(-7, 3), xq_postgres_trunc(-1.5), xq_postgres_power(2, 10), xq_postgres_sign(-0.5);
SELECT xq_postgres_log(0);
SELECT xq_pg_char_max('varchar(10)', 'TEXT'), xq_pg_num_precision('numeric(10,2)', 'ANY'), xq_pg_num_scale('numeric(10,2)', 'ANY'), xq_pg_data_type('int[]', 'TEXT'), xq_pg_udt_name('timestamptz', 'TEXT');
SELECT quote(xq_postgres_array_agg(column1)) FROM (VALUES (3), (NULL), (1));
SELECT quote(xq_postgres_jsonb_agg(column1)), quote(xq_postgres_jsonb_object_agg(column1, column1)) FROM (VALUES ('k'), ('j'));
