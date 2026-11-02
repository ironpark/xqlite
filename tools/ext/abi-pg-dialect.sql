.dialect postgres
-- The PostgreSQL dialect's collations and the sequence functions by
-- their plain names (nextval() of an identity's DEFAULT), which xqlite
-- finds in the PostgreSQL dialect only: the line above, which sqlite3
-- reads as a comment, makes `xqt interop ext` run this file in it.
-- Recorded in abi-pg-dialect.out.
SELECT CASE WHEN xq_pg_jsonb('[1,2]') < xq_pg_jsonb('{"a":1}') COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN '"a"' < '1' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN 'null' < 'true' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN '[1,2]' < '[1,2,3]' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN '{"b":1}' < '{"a":1,"c":0}' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END;
SELECT CASE WHEN '{"a":1}' = '{ "a" : 1 }' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN '1.0' = '1' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END, CASE WHEN '"b"' > '"a"' COLLATE xq_pg_jsonb THEN 1 ELSE 0 END;
SELECT CASE WHEN '1 day' < '25 hours' COLLATE xq_pg_interval THEN 1 ELSE 0 END, CASE WHEN '30 days' = '1 mon' COLLATE xq_pg_interval THEN 1 ELSE 0 END, CASE WHEN '-1 day' < '0' COLLATE xq_pg_interval THEN 1 ELSE 0 END, CASE WHEN '1 year' > '364 days' COLLATE xq_pg_interval THEN 1 ELSE 0 END;
SELECT CASE WHEN '{1,2}' < '{1,10}' COLLATE xq_pg_array THEN 1 ELSE 0 END, CASE WHEN '{1,2}' < '{1,10}' COLLATE xq_pg_array_num THEN 1 ELSE 0 END, CASE WHEN '{a}' < '{a,b}' COLLATE xq_pg_array THEN 1 ELSE 0 END, CASE WHEN '{NULL}' > '{z}' COLLATE xq_pg_array THEN 1 ELSE 0 END, CASE WHEN '{2.5}' < '{10}' COLLATE xq_pg_array_num THEN 1 ELSE 0 END;
SELECT nextval('nope');
SELECT currval('nope');
SELECT lastval();
SELECT setval('nope', 1);
