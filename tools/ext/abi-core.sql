-- The engine functions of no dialect (src/dialect/like.zig, abi.zig):
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
