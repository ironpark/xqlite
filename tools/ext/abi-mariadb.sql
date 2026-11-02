-- The MariaDB dialect's engine functions as the schema calls them
-- (src/dialect/abi.zig, docs/extension.md). Recorded in abi-mariadb.out.
SELECT xq_div(7, 2), xq_div(-7, 2), xq_div(7.9, 2), quote(xq_div(1, 0)), quote(xq_div(NULL, 1)), xq_div('9', '4');
SELECT xq_xor(1, 0), xq_xor(1, 1), quote(xq_xor(NULL, 1)), xq_bitxor(5, 3), xq_bitxor(-1, 1);
SELECT xq_cast('12abc', 'SIGNED'), xq_cast(-1, 'UNSIGNED'), xq_cast('2024-02-29 10:00:00', 'DATE'), xq_cast(1.555, 'DECIMAL(5,2)'), xq_cast('x', 'CHAR');
SELECT xq_date_add('2024-01-31', 1, 'MONTH'), xq_date_add('2024-02-29 23:59:59', 1, 'SECOND'), xq_date_add('2024-02-29', -1, 'YEAR'), quote(xq_date_add('nope', 1, 'DAY'));
SELECT xq_extract('YEAR', '2024-02-29 10:11:12'), xq_extract('MONTH', '2024-02-29'), xq_extract('HOUR', '2024-02-29 10:11:12'), xq_extract('DAY_SECOND', '2024-02-29 10:11:12');
SELECT xq_timestampdiff('DAY', '2024-01-01', '2024-03-01'), xq_timestampdiff('MONTH', '2024-01-31', '2024-02-29'), xq_timestampdiff('SECOND', '2024-01-01 00:00:00', '2024-01-01 01:00:01');
SELECT xq_bit_length('abc'), xq_bit_length('é'), quote(xq_bit_length(NULL));
SELECT xq_coerce('12', 'int', 'main', 't', 'c', 0, 1), xq_coerce('abc', 'varchar(2)', 'main', 't', 'c', 1, 1), xq_coerce('2024-02-29 10:11:12.5', 'datetime', 'main', 't', 'c', 0, 1), xq_coerce(1.555, 'decimal(5,2)', 'main', 't', 'c', 0, 1);
SELECT xq_coerce('x', 'int', 'main', 't', 'c', 0, 1);
SELECT xq_coerce('abc', 'varchar(2)', 'main', 't', 'c', 0, 1);
SELECT xq_coerce(NULL, 'int', 'main', 't', 'c', 2, 1);
SELECT xq_coerce('green', 'enum(''red'',''green'')', 'main', 't', 'c', 0, 1), xq_coerce(300, 'tinyint', 'main', 't', 'c', 1, 1);
SELECT xq_maria_json_bool(1), xq_maria_json_bool(0), xq_maria_json_col('{"a":1}'), xq_maria_json_cmp('[1]');
SELECT xq_mariadb_json_extract('{"a":[1,{"b":2}]}', '$.a[1].b'), xq_mariadb_json_extract('{"a":1,"b":2}', '$.a', '$.b'), xq_mariadb_json_unquote('"x\ny"'), xq_mariadb_json_length('[1,2,[3]]'), xq_mariadb_json_type('{}');
SELECT xq_mariadb_json_value('{"a":"x"}', '$.a'), quote(xq_mariadb_json_query('{"a":"x"}', '$.a')), xq_mariadb_json_contains('[1,2]', '1'), xq_mariadb_json_set('{"a":1}', '$.b', 2), xq_mariadb_json_compact('{ "a" : 1 }');
SELECT xq_mariadb_concat('a', 1, 2.5), quote(xq_mariadb_concat('a', NULL)), xq_mariadb_left('abc', 2), xq_mariadb_lpad('7', 3, '0'), xq_mariadb_round(2.5), xq_mariadb_round(-2.5), xq_mariadb_round(1.2345, 2), xq_mariadb_truncate(1.999, 1);
SELECT xq_mariadb_date_format('2024-02-29 13:04:05', '%Y/%m/%d %H:%i:%s %W %M %j'), xq_mariadb_str_to_date('29/02/2024', '%d/%m/%Y'), xq_mariadb_last_day('2024-02-10'), xq_mariadb_dayofweek('2024-02-29');
SELECT xq_stddev_pop(column1), xq_stddev_samp(column1), xq_var_pop(column1), xq_var_samp(column1) FROM (VALUES (1), (2), (4), (NULL));
SELECT quote(xq_stddev_samp(column1)) FROM (VALUES (1));
SELECT xq_mariadb_json_arrayagg(column1), xq_mariadb_json_objectagg(column1, column1) FROM (VALUES ('a'), ('b'));
SELECT xq_mariadb_nextval('nope');
