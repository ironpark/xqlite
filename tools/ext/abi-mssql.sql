-- The SQL Server dialect's engine functions as the schema calls them
-- (src/dialect/abi.zig, docs/extension.md). Recorded in abi-mssql.out.
SELECT xq_tsql_add(1, 2), xq_tsql_add('a', 'b'), xq_tsql_add('1', 2), quote(xq_tsql_add(NULL, 'x')), xq_tsql_add(1.5, '2');
SELECT xq_tsql_add('a', 1);
SELECT xq_tsql_like('ABC', 'a%'), xq_tsql_like('a_c', 'a[_]c'), xq_tsql_like('abc', '[a-c]bc'), xq_tsql_like('xbc', '[^a]bc'), xq_tsql_like('a%', 'a!%', '!');
SELECT xq_tsql_cast('123', 'int'), xq_tsql_cast(1.5, 'int'), xq_tsql_cast('abcdef', 'varchar(3)'), xq_tsql_cast('2024-02-29 10:11:12.1234567', 'datetime'), xq_tsql_cast('2024-02-29', 'datetime2(3)');
SELECT xq_tsql_cast('x', 'int');
SELECT quote(xq_tsql_try_cast('x', 'int')), xq_tsql_try_cast('12', 'smallint'), quote(xq_tsql_try_cast(70000, 'smallint')), xq_tsql_try_cast(12.345, 'decimal(5,1)'), xq_tsql_try_cast(1, 'bit');
SELECT xq_tsql_store('abc', 'varchar(5)'), xq_tsql_store('ab   ', 'varchar(2)'), xq_tsql_store(12.5, 'money'), xq_tsql_store('1', 'bit');
SELECT xq_tsql_store('abcdef', 'varchar(3)|t|c');
SELECT xq_tsql_store(70000, 'smallint');
SELECT xq_tsql_json_value('{"a":{"b":"x"}}', '$.a.b'), quote(xq_tsql_json_value('{"a":{"b":"x"}}', '$.a')), xq_tsql_json_query('{"a":{"b":"x"}}', '$.a'), xq_tsql_isjson('{"a":1}', 0), xq_tsql_isjson('1', 0), xq_tsql_isjson('[]', 1);
SELECT xq_tsql_json_value('{"a":1}', 'strict $.b');
SELECT xq_tsql_json_modify('{"a":1}', '$.b', 'x', 0), xq_tsql_json_path_exists('{"a":1}', '$.a'), xq_tsql_json_escape('a"b\'), xq_tsql_json_object('a', 1, 'b', NULL), xq_tsql_json_array(1, 'x', NULL);
SELECT xq_mssql_left('abc', 2), xq_mssql_charindex('b', 'abcb', 3), xq_mssql_replicate('ab', 3), xq_mssql_stuff('abcdef', 2, 3, 'X'), xq_mssql_round(2.567, 1), xq_mssql_round(2.5, 0), xq_mssql_isnumeric('1e5'), xq_mssql_isnumeric('x');
SELECT xq_mssql_dateadd('day', 1, '2024-02-28'), xq_mssql_dateadd('month', 1, '2024-01-31 10:00:00'), xq_mssql_datediff('day', '2024-01-01', '2024-03-01'), xq_mssql_datepart('weekday', '2024-02-29'), xq_mssql_eomonth('2024-02-10'), xq_mssql_datename('month', '2024-02-29');
SELECT xq_tsql_avg(column1) FROM (VALUES (1), (2), (4));
SELECT xq_tsql_avg(column1) FROM (VALUES (1.0), (2), (4));
SELECT xq_mssql_typeinfo('nvarchar(20)', 'max_length'), xq_mssql_typeinfo('decimal(9,3)', 'scale'), xq_mssql_typeinfo('datetime2(4)', 'name');
