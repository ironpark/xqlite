-- The Oracle dialect's engine functions as the schema calls them
-- (src/dialect/abi.zig, docs/extension.md). Recorded in abi-oracle.out.
SELECT xq_ora_coerce('12', 'NUMBER(5)', 'T', 'C', 0), quote(xq_ora_coerce('', 'VARCHAR2(5)', 'T', 'C', 0)), xq_ora_coerce(1.256, 'NUMBER(5,2)', 'T', 'C', 0), xq_ora_coerce('2024-02-29', 'DATE', 'T', 'C', 0);
SELECT xq_ora_coerce('abcdef', 'VARCHAR2(3)', 'T', 'C', 0);
SELECT xq_ora_coerce('x', 'NUMBER', 'T', 'C', 0);
SELECT xq_ora_coerce(123456, 'NUMBER(5)', 'T', 'C', 0);
SELECT xq_ora_coerce(NULL, 'NUMBER', 'T', 'C', 1);
SELECT xq_ora_cast('12.50', 'NUMBER'), xq_ora_cast(12.5, 'VARCHAR2(10)'), xq_ora_cast('2024-02-29', 'DATE'), xq_ora_cast(0.5, 'VARCHAR2(10)');
SELECT xq_ora_is_json('{"a":1}', 0), xq_ora_is_json('{x', 0), xq_ora_is_json('1', 0), quote(xq_ora_is_json(NULL, 0));
SELECT xq_ora_json_value('{"a":{"b":"x"}}', '$.a.b', '|||', NULL, NULL), quote(xq_ora_json_value('{"a":[1]}', '$.a', '|||', NULL, NULL)), xq_ora_json_query('{"a":{"b":"x"}}', '$.a', '|||N||');
SELECT xq_oracle_substr('abcdef', 2, 3), xq_oracle_substr('abcdef', -2), quote(xq_oracle_substr('abc', 5)), xq_oracle_instr('abcabc', 'b', 1, 2), xq_oracle_instr('abcabc', 'b', -1);
SELECT xq_oracle_lpad('7', 3, '0'), xq_oracle_rpad('ab', 1), xq_oracle_ltrim('xxa', 'x'), xq_oracle_trim('  a  '), xq_oracle_replace('abcb', 'b'), xq_oracle_translate('abc', 'ab', 'x'), xq_oracle_initcap('hello wORLD');
SELECT xq_oracle_round(2.5), xq_oracle_round(-2.5), xq_oracle_round(1.2345, 2), xq_oracle_trunc(-1.9), xq_oracle_mod(-7, 3), xq_oracle_power(2, 0.5), xq_oracle_sign(-3);
SELECT xq_oracle_to_char(1234.5, '9,999.99'), xq_oracle_to_char(0.5), xq_oracle_to_char('2024-02-29 13:04:05', 'YYYY-MM-DD HH24:MI:SS DY'), xq_oracle_to_number('1,234.5', '9,999.9'), xq_oracle_to_date('29-02-2024', 'DD-MM-YYYY');
SELECT xq_oracle_to_number('x');
SELECT xq_oracle_add_months('2024-01-31 00:00:00', 1), xq_oracle_months_between('2024-03-31', '2024-02-29'), xq_oracle_last_day('2024-02-10'), xq_oracle_next_day('2024-02-29', 'MONDAY'), xq_oracle_extract('YEAR', '2024-02-29');
SELECT xq_oracle_greatest(1, 3, 2), quote(xq_oracle_greatest(1, NULL)), xq_oracle_least('b', 'a'), xq_oracle_lengthb('é'), xq_oracle_lengthc('é');
SELECT xq_ora_data_type('NUMBER(5,2)', 'ANY'), xq_ora_data_length('VARCHAR2(20)', 'TEXT'), xq_ora_data_precision('NUMBER(5,2)', 'ANY'), xq_ora_data_scale('NUMBER(5,2)', 'ANY');
SELECT xq_ora_json_arrayagg('|1', column1) FROM (VALUES (1), (2));
SELECT xq_oracle_nextval('NOPE');
