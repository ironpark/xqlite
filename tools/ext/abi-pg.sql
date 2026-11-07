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
-- uuid (src/dialect/postgres/uuid.zig): 16 bytes, the text of an older column.
SELECT hex(xq_pg_uuid('A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11')), hex(xq_pg_uuid('{a0eebc999c0b4ef8bb6d6bb9bd380a11}')), hex(xq_pg_uuid(x'00112233445566778899aabbccddeeff')), quote(xq_pg_uuid(NULL));
SELECT xq_pg_uuid('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1');
SELECT xq_pg_uuid(x'0102');
SELECT xq_pg_uuid(7);
SELECT xq_pg_uuid_text(x'a0eebc999c0b4ef8bb6d6bb9bd380a11'), xq_pg_uuid_text('A0EE-BC99-9C0B-4EF8-BB6D-6BB9-BD38-0A11'), quote(xq_pg_uuid_text(NULL));
SELECT xq_pg_uuid_text(' a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
SELECT xq_postgres_uuid_extract_version(x'11111111111151118111111111111111'), quote(xq_postgres_uuid_extract_version('11111111-1111-1111-1111-111111111111')), xq_postgres_uuid_extract_timestamp('017F22E2-79B0-7CC3-98C4-DC0C0C07398F'), xq_postgres_uuid_extract_timestamp(x'c232ab00941411ecb3c89f6bdeced846'), quote(xq_postgres_uuid_extract_timestamp(x'11111111111141118111111111111111'));
SELECT xq_postgres_uuid_extract_version(xq_postgres_uuidv4()), xq_postgres_uuid_extract_version(xq_postgres_uuidv7()), length(xq_postgres_uuidv7('1 day')), xq_postgres_uuidv7() < xq_postgres_uuidv7();
SELECT xq_postgres_uuidv7('-1000 years');
SELECT quote(xq_pg_iv('1 mon')), quote(xq_pg_iv_key('30 days')), quote(xq_pg_iv_high('1 day')), xq_pg_iv_valid(xq_pg_iv('1 day')), xq_pg_iv_valid(x'00'), xq_pg_iv_valid('1 day');
SELECT xq_pg_iv_text(xq_pg_iv('P1Y2M3DT4H5M6.5S')), xq_pg_iv_text('-infinity'), xq_pg_iv_text(xq_pg_iv_interval_pl('1 day', xq_pg_iv('25 hours'))), xq_pg_iv_text(xq_pg_iv_interval_mul(xq_pg_iv('1 mon 1 day'), 1.5)), xq_pg_iv_text(xq_pg_iv_timestamp_mi('2024-03-01 00:00:00', '2024-02-28 12:00:00'));
SELECT xq_pg_iv('soon');
SELECT xq_pg_iv_text(x'0011');
SELECT xq_pg_iv_interval_pl(xq_pg_iv('infinity'), xq_pg_iv('-infinity'));
SELECT xq_pg_iv_text(xq_pg_iv_sum(column1)), xq_pg_iv_text(xq_pg_iv_avg(column1)) FROM (VALUES ('1 mon'), ('30 days'), (NULL), ('1 hour'));
SELECT xq_pg_iv_date_pl_interval('2024-01-31', xq_pg_iv('1 mon')), xq_pg_iv_time_pl_interval('23:00:00', '2 hours');
SELECT xq_pg_iv_time_pl_interval('23:00:00', 'infinity');
SELECT xq_pg_iv_text(xq_postgres_justify_hours('52 hours')), xq_pg_iv_text(xq_postgres_justify_days(xq_pg_iv('36 days'))), xq_pg_iv_text(xq_postgres_justify_interval('1 mon -1 hour')), xq_postgres_isfinite(xq_pg_iv('infinity')), xq_postgres_isfinite('1 day');
SELECT xq_pg_iv_out(xq_pg_iv('1 day 2 hours')), xq_pg_iv_out('-infinity'), quote(xq_pg_iv_out(NULL)), xq_pg_iv_text(xq_pg_iv_in('-1 2:03:04', -1, 1)), xq_pg_iv_text(xq_pg_iv_in('-1 2:03:04', -1, 0)), xq_pg_iv_text(xq_pg_iv_in('-1 2:03:04', -1));
-- jsonb as SQLite's JSONB: the canonical blob, its text, the sort key; the
-- operators of a blob (sqlite3's jsonb() too) give blobs.
SELECT hex(xq_pg_jsonb_bin('{"b":1,"a":[1.50,"x\"y",null,true],"a":false}')), xq_pg_jsonb_text(xq_pg_jsonb_bin('{"b":1,"a":"x"}')), json(xq_pg_jsonb_bin('{"b":1,"a":"x"}')), quote(xq_pg_jsonb_text(NULL));
SELECT hex(xq_pg_jsonb_bin(jsonb('{"z":1,"a":1e2,"a":"A"}'))), xq_pg_jsonb_text(jsonb('{"z":1,"a":1e2}')), xq_pg_jsonb_text('{"z": 1,  "a":0.50}'), hex(xq_pg_jsonb(xq_pg_jsonb_bin('[1]'))), xq_pg_json(xq_pg_jsonb_bin('{"a":[1]}'));
SELECT hex(xq_pg_jsonb_key('{"a":[1.0,"x",true,null]}')), xq_pg_jsonb_key('1.0') = xq_pg_jsonb_key(xq_pg_jsonb_bin('1')), xq_pg_jsonb_key('[]') < xq_pg_jsonb_key('null'), xq_pg_jsonb_key('-2.5') < xq_pg_jsonb_key('-2'), quote(xq_pg_jsonb_key(NULL));
SELECT hex(xq_pg_jsonb_get(xq_pg_jsonb_bin('{"a":{"b":[1]}}'), 'a')), xq_pg_jsonb_get_text(jsonb('{"a":"x","a":"y"}'), 'a'), xq_pg_jsonb_path_text(xq_pg_jsonb_bin('{"a":[1,{"c":"d"}]}'), '{a,1,c}'), xq_pg_jsonb_exists(jsonb('["a"]'), 'a'), xq_pg_jsonb_contains(jsonb('{"a":[1,2]}'), '{"a":[2]}');
SELECT hex(xq_pg_jsonb_concat(xq_pg_jsonb_bin('{"a":1}'), '{"b":2}')), xq_pg_jsonb_concat('{"a":1}', '{"b":2}'), hex(xq_pg_jsonb_delete_path(xq_pg_jsonb_bin('{"a":{"b":1,"c":2}}'), '{a,b}')), xq_postgres_jsonb_typeof(jsonb('1.5')), xq_postgres_jsonb_pretty(xq_pg_jsonb_bin('{"a":[]}'));
SELECT xq_pg_cast_int2(32767), xq_pg_cast_int4('  0x2A '), xq_pg_cast_int8('-1_000'), xq_pg_cast_int8(2.5), xq_pg_cast_int8(3.5), xq_pg_cast_int4(-2.5), quote(xq_pg_cast_int2(NULL));
SELECT xq_pg_cast_int2('32768');
SELECT xq_pg_cast_int4('1__0');
SELECT xq_pg_cast_int8(9.3e18);
SELECT xq_pg_int_xor(123, 456), xq_pg_int_xor(-1, 5), quote(xq_pg_int_xor(NULL, 1));
-- Regular expressions (regexp.zig, are.zig).
SELECT xq_pg_re('abab', '^(ab)\1$', ''), xq_pg_re('ABC', '[[:lower:]]', 'i'), xq_pg_re('foo bar', '\mbar\M', ''), xq_pg_re('aXb', 'a.b', 'n'), quote(xq_pg_re(NULL, 'a', ''));
SELECT xq_pg_re('a', '(', '');
SELECT xq_pg_similar_escape('a%b_c#"d#"', '#'), xq_pg_similar_escape('(a|b)\.'), quote(xq_pg_similar_escape('a', NULL)), xq_pg_re('abc', xq_pg_similar_escape('a(b|x)%'), '');
SELECT xq_pg_similar_escape('a', 'xy');
SELECT xq_pg_rows_regexp_matches('a1b22', '([a-z])(\d+)', 'g'), xq_pg_rows_regexp_matches('abc', 'z', ''), xq_pg_rows_regexp_split('a, b,c', ',\s*', ''), xq_pg_rows_regexp_split(NULL, ',', '');
SELECT xq_postgres_regexp_match('abc01234xyz', '(.*?)(\d+)(.*)'), xq_postgres_regexp_replace('foobarbaz', 'b(..)', 'X\1Y', 'g'), xq_postgres_regexp_count('ABCABC', 'b', 1, 'i'), xq_postgres_regexp_instr('aébc', 'b'), xq_postgres_regexp_substr('ABCDEFGHI', '(c..)(...)', 1, 1, 'i', 2);
SELECT xq_postgres_regexp_like('Hello', 'hello', 'i'), xq_postgres_regexp_split_to_array('a,b,,c', ','), xq_postgres_textregexsubstr('foobar', 'o(.)b'), xq_postgres_textregexsubstr('foobar', '%#"o_b#"%', '#'), xq_postgres_similar_to_escape('a_b');
SELECT xq_postgres_regexp_match('abc', 'b', 'g');
-- inet, cidr (inet.zig), enums (enums.zig), digests and encode (funcs.zig).
SELECT xq_pg_inet('127.0.0.1'), xq_pg_inet('10.1.2.3/8'), xq_pg_inet('2001:0DB8:0:0::1'), xq_pg_inet('::ffff:1.2.3.4/128'), xq_pg_cidr('10.0.0.0/8'), quote(xq_pg_inet(NULL));
SELECT xq_pg_inet('1.2.3');
SELECT xq_pg_cidr('10.0.0.1/8');
SELECT xq_postgres_host('10.1.2.3/8'), xq_postgres_masklen('10.1.2.3/8'), xq_postgres_family('::1');
SELECT xq_pg_enum_in('ok', '["sad","ok"]', 'mood'), quote(xq_pg_enum_in(NULL, '["sad"]', 'mood'));
SELECT xq_pg_enum_in('meh', '["sad","ok"]', 'mood');
SELECT xq_postgres_md5('a'), hex(xq_postgres_sha224('')), hex(xq_postgres_sha256('abc')), length(xq_postgres_sha384('x')), length(xq_postgres_sha512('x'));
SELECT xq_postgres_encode(x'00ff5c41', 'hex'), xq_postgres_encode(x'00ff5c41', 'escape'), xq_postgres_encode('hello world', 'base64'), hex(xq_postgres_decode('aGVsbG8=', 'base64')), hex(xq_postgres_decode('6869', 'hex'));
SELECT xq_postgres_encode('x', 'nope');
-- A boolean made text, pg_typeof() of a type known (overload.zig).
SELECT xq_pg_bool_text(1), xq_pg_bool_text(0), quote(xq_pg_bool_text(NULL)), xq_pg_bool_out(1), xq_pg_bool_out(0), xq_pg_typeof_as(1, 'bigint'), xq_pg_typeof_as(NULL, 'text');
