-- The engine functions of no dialect (src/dialect/like.zig, abi.zig,
-- decimal_sql.zig: numerics and their keys, whose bytes are a disk format):
-- their results are part of the file format (docs/extension.md). The
-- recorded output is abi-core.out; `xqt interop ext` checks xqlite and
-- sqlite3 with the extension against it.
SELECT xq_ext_version();
SELECT xq_like('a%', 'abc'), xq_like('A%', 'abc'), xq_like('_b_', 'abc'), xq_like('%', ''), xq_like('a\%', 'a%'), xq_like('a\%', 'ab');
SELECT xq_like('a!_', 'a_', '!'), xq_like('a_', 'a_', ''), xq_like('é_', 'éx'), xq_like(NULL, 'a'), xq_like('a', NULL);
SELECT xq_ilike('A%', 'abc'), xq_ilike('É%', 'éa'), xq_ilike('%B%', 'abc', '\'), quote(xq_ilike('a', NULL, '\'));
SELECT xq_like(1, 1), xq_like('1%', 12), xq_like('%.5', 1.5), xq_like('%', x'00');
SELECT xq_like('a\', 'a');
SELECT xq_like('a', 'a', 'xy');
SELECT hex(xq_dec_key('1.50')), hex(xq_dec('1.50')), hex(xq_dec_key(-1)), hex(xq_dec_key('1e300')), hex(xq_dec_key('-1e-300')), hex(xq_dec_key(0)), hex(xq_dec_key('NaN')), hex(xq_dec_key('inf')), hex(xq_dec_key('-inf'));
SELECT xq_dec_text(xq_dec_add('0.1', '0.2')), xq_dec_text(xq_dec_div(1, 3)), xq_dec_text(xq_dec_mul('1.50', '1.50')), xq_dec_text(xq_dec_mod('-7.5', 2)), xq_dec_text(xq_dec_neg('1.50')), xq_dec_text(xq_dec_key('1.50'), 3);
SELECT xq_dec_text(xq_dec_round('2.5')), xq_dec_text(xq_dec_round('1234.5', -2)), xq_dec_text(xq_dec_trunc('-1.99')), xq_dec_text(xq_dec_ceil('-1.5')), xq_dec_text(xq_dec_floor('-1.5')), xq_dec_text(xq_dec_sign('-3')), xq_dec_text(xq_dec_div_trunc('7.5', 2)), xq_dec_scale('1.500'), xq_dec_min_scale('1.500'), xq_dec_text(xq_dec_trim_scale('1.500'));
SELECT xq_dec_text(xq_dec('12.345', 4, 2)), xq_dec_valid(xq_dec_key('1.5')), xq_dec_valid(xq_dec('1.50')), xq_dec_valid(xq_dec_key('1.234'), 10, 2), xq_dec_valid(1.5), quote(xq_dec_valid(NULL)), xq_dec_int4('2.5'), xq_dec_int8('-2.5'), xq_dec_float8('0.1'), xq_dec_number('3'), xq_dec_number(xq_dec_key('1.25'));
SELECT xq_dec_key('1.5') < xq_dec_key('10'), xq_dec_key('-10') < xq_dec_key('-1.5'), xq_dec_key('inf') < xq_dec_key('NaN');
SELECT xq_dec_text(xq_dec_sum(x)), xq_dec_text(xq_dec_avg(x)) FROM (SELECT '1.5' AS x UNION ALL SELECT '2.25' UNION ALL SELECT NULL);
SELECT xq_dec('x');
SELECT xq_dec('12345.678', 5, 2);
SELECT xq_dec_div(1, 0);
SELECT xq_dec_int2('32767.5');
SELECT xq_dec_text(xq_dec_sqrt(2)), xq_dec_text(xq_dec_exp('1.0')), xq_dec_text(xq_dec_ln('2.0')), xq_dec_text(xq_dec_log(100)), xq_dec_text(xq_dec_log(2, 8)), xq_dec_text(xq_dec_power(2, '0.5')), xq_dec_text(xq_dec_power('-8.0', 3)), xq_dec_text(xq_dec_factorial(20)), xq_dec_width_bucket('5.35', '0.024', '10.06', 5);
SELECT xq_dec_sqrt(-1);
SELECT xq_dec_ln(0);
SELECT xq_dec_power(0, -1);
SELECT xq_dec_power('-2.0', '0.5');
SELECT xq_dec_text(xq_dec_var_samp(x)), xq_dec_text(xq_dec_var_pop(x)), xq_dec_text(xq_dec_stddev_samp(x)), xq_dec_text(xq_dec_stddev_pop(x)) FROM (SELECT '1.5' AS x UNION ALL SELECT '2.25' UNION ALL SELECT 3 UNION ALL SELECT NULL);
SELECT xq_float_var_samp(column1), xq_float_var_pop(column1), xq_float_stddev_samp(column1), xq_float_stddev_pop(column1), quote(xq_float_var_samp(column1) FILTER (WHERE column1 > 2)) FROM (VALUES (1.5), (2.25), (3.0), (NULL));
SELECT xq_corr(column2, column1), xq_covar_pop(column2, column1), xq_covar_samp(column2, column1), xq_regr_count(column2, column1), xq_regr_avgx(column2, column1), xq_regr_avgy(column2, column1), xq_regr_slope(column2, column1), xq_regr_intercept(column2, column1), xq_regr_r2(column2, column1), xq_regr_sxx(column2, column1), xq_regr_syy(column2, column1), xq_regr_sxy(column2, column1) FROM (VALUES (1, 2.0), (2, 4.1), (3, 5.9), (4, 8.2), (5, NULL));
SELECT xq_any_value(column1), xq_percentile_cont(0.3, column1 ORDER BY column1), xq_percentile_disc(0.3, column1 ORDER BY column1), xq_mode(column1 ORDER BY column1) FROM (VALUES (NULL), (5), (2), (2), (1));
SELECT xq_hypo_rank(0, 2, column1, column1 < 2, column1 > 2), xq_hypo_dense_rank(0, 2, column1, column1 < 2, column1 > 2), xq_hypo_percent_rank(0, 2, column1, column1 < 2, column1 > 2), xq_hypo_cume_dist(1, 2, column1, column1 < 2, column1 > 2) FROM (VALUES (1), (1), (2), (5));
SELECT xq_percentile_cont(1.5, column1 ORDER BY column1) FROM (VALUES (1));
SELECT xq_lateral_rows(a, b, c), quote(xq_lateral_rows(a) FILTER (WHERE 0)) FROM (SELECT 1 AS a, 1.5 AS b, 'é' AS c UNION ALL SELECT NULL, x'00ff', -9223372036854775808);
SELECT quote(xq_lateral_col(value, 0)), quote(xq_lateral_col(value, 1)), quote(xq_lateral_col(value, 2, 'bigint')), quote(xq_lateral_col(value, 3)), quote(xq_lateral_col(NULL, 0)) FROM json_each((SELECT xq_lateral_rows(a, b, c) FROM (SELECT 1 AS a, 1.5 AS b, 'é' AS c UNION ALL SELECT NULL, x'00ff', -9223372036854775808)));
SELECT xq_lateral_col('I00', 0);
