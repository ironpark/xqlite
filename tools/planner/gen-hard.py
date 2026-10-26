#!/usr/bin/env python3
"""A second random case generator for diff.py, aimed at the harder parts
of the planner: skip-scan and ANALYZE statistics, collations, expression
and partial indexes, row values, correlated subqueries, nested joins,
automatic indexes, ORDER BY/GROUP BY/DISTINCT through indexes, DESC
indexes, and DML through triggers and foreign keys.

usage: gen-hard.py SEED NBLOCKS NQUERIES > cases.txt
"""
import random, sys

seed, nblocks, nq = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
R = random.Random(seed)


def schema():
    out = []
    tabs = []
    for ti in range(R.randint(2, 4)):
        name = f't{ti}'
        cols = ['a', 'b', 'c', 'd'][:R.randint(3, 4)]
        kind = R.choice(['rowid', 'ipk', 'wr'])
        defs = []
        for i, c in enumerate(cols):
            ty = R.choice(['INT', 'TEXT', '', 'TEXT COLLATE NOCASE', 'REAL', 'INTEGER'])
            if kind == 'ipk' and i == 0:
                defs.append(f'{c} INTEGER PRIMARY KEY')
            else:
                defs.append(f'{c} {ty}'.strip())
        tail = ''
        if kind == 'wr':
            defs.append(f'PRIMARY KEY({cols[0]}, {cols[1]})')
            tail = ' WITHOUT ROWID'
        if ti > 0 and R.random() < 0.3:
            defs.append(f'FOREIGN KEY({cols[-1]}) REFERENCES t0')
        out.append(f'CREATE TABLE {name}({", ".join(defs)}){tail};')
        for ii in range(R.randint(1, 3)):
            r = R.random()
            if r < 0.15:
                body = f'{cols[1]}+{cols[2]}'
            elif r < 0.25:
                body = f'lower({cols[1]}), {cols[2]}'
            elif r < 0.35:
                body = f'{cols[1]} COLLATE NOCASE'
            else:
                k = R.sample(cols, R.randint(1, 3))
                body = ', '.join(c + (' DESC' if R.random() < 0.2 else '') for c in k)
            uniq = 'UNIQUE ' if R.random() < 0.15 else ''
            where = f' WHERE {R.choice(cols)} IS NOT NULL' if R.random() < 0.12 else ''
            out.append(f'CREATE {uniq}INDEX {name}i{ii} ON {name}({body}){where};')
        n = R.choice([10, 100, 1000, 3000])
        vals = []
        for c in cols:
            m = R.choice([2, 4, 10, 50, 100000])
            vals.append(R.choice([f'i%{m}', f"'k'||(i%{m})", f"CASE WHEN i%{R.randint(3,9)}=0 THEN NULL ELSE i%{m} END",
                                  f"char(65+i%{min(m, 26)})||(i%{m})"]))
        if kind != 'rowid':
            vals[0] = 'i'
            if kind == 'wr':
                vals[1] = 'i%7'
        out.append(f'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{n}) '
                   f'INSERT OR IGNORE INTO {name} SELECT {", ".join(vals)} FROM n;')
        tabs.append((name, cols))
    if R.random() < 0.6:
        out.append('ANALYZE;')
    if R.random() < 0.3:
        t, cols = R.choice(tabs[1:])
        out.append(f'CREATE TRIGGER tr AFTER UPDATE ON {t} BEGIN '
                   f'UPDATE t0 SET {tabs[0][1][1]}={tabs[0][1][1]} WHERE {tabs[0][1][0]}=new.{cols[0]}; END;')
    return tabs, out


def lit():
    return R.choice([str(R.randint(0, 60)), f"'k{R.randint(0, 50)}'", f"'K{R.randint(0, 9)}'", "'A1'", 'NULL',
                     f'?{R.randint(1, 3)}'])


def col(tabs, alias):
    t, cols = R.choice(tabs)
    return f'{alias[t]}.{R.choice(cols)}', t, cols


def term(tabs, alias, depth=0):
    c, t, cols = col(tabs, alias)
    r = R.random()
    if r < 0.18:
        return f'{c}={lit()}'
    if r < 0.28:
        return f'{c}{R.choice(["<", ">", "<=", ">="])}{lit()}'
    if r < 0.33:
        return f'{c} BETWEEN {lit()} AND {lit()}'
    if r < 0.4:
        return f'{c} IN ({", ".join(lit() for _ in range(R.randint(1, 5)))})'
    if r < 0.43:
        return f'{c} IS NULL'
    if r < 0.47:
        return f"{c} LIKE '{R.choice(['k1', 'K', 'a', 'k'])}%'"
    if r < 0.5:
        return f"{c} GLOB 'k1*'"
    if r < 0.55:
        a2 = alias[t]
        return f'({a2}.{cols[0]}, {a2}.{cols[1]}) {R.choice(["=", ">", "<", ">=", "<="])} ({lit()}, {lit()})'
    if r < 0.6:
        a2 = alias[t]
        return f'{a2}.{cols[1]}+{a2}.{cols[2]}={R.randint(0, 40)}'
    if r < 0.63:
        a2 = alias[t]
        return f"lower({a2}.{cols[1]})='{R.choice(['k1', 'a1', 'k2'])}'"
    if r < 0.66:
        return f"{c}='k1' COLLATE NOCASE"
    if r < 0.74 and len(tabs) > 1:
        c2, _, _ = col(tabs, alias)
        return f'{c}={c2}'
    if r < 0.8 and depth < 2:
        return f'({term(tabs, alias, depth+1)} OR {term(tabs, alias, depth+1)})'
    if r < 0.84:
        t2, cols2 = R.choice(tabs)
        return f'{c} {R.choice(["IN", "NOT IN"])} (SELECT {R.choice(cols2)} FROM {t2} WHERE {R.choice(cols2)}>{R.randint(0,20)})'
    if r < 0.88:
        t2, cols2 = R.choice(tabs)
        return f'{R.choice(["", "NOT "])}EXISTS (SELECT 1 FROM {t2} AS x WHERE x.{R.choice(cols2)}={c})'
    if r < 0.91:
        t2, cols2 = R.choice(tabs)
        return f'{c} = (SELECT max(y.{cols2[0]}) FROM {t2} AS y WHERE y.{cols2[1]}={c})'
    if r < 0.94:
        return f'{c} IS NOT {lit()}'
    if r < 0.97:
        return f'coalesce({c},0)>{R.randint(0, 5)}'
    return f'{c} NOT BETWEEN {R.randint(0, 5)} AND {R.randint(5, 30)}'


def frm(tabs):
    k = R.randint(1, min(3, len(tabs)))
    use = R.sample(tabs, k)
    alias = {t: t for t, _ in tabs}
    parts = [use[0][0]]
    for i in range(1, k):
        t, cols = use[i]
        pt, pc = R.choice(use[:i])
        j = R.choice(['JOIN', ',', 'LEFT JOIN', 'CROSS JOIN', 'RIGHT JOIN', 'FULL JOIN', 'NATURAL JOIN', 'JOIN USING'])
        if j == ',':
            parts.append(f', {t}')
        elif j == 'NATURAL JOIN':
            parts.append(f' NATURAL JOIN {t}')
        elif j == 'JOIN USING':
            parts.append(f' JOIN {t} USING({cols[0]})')
        else:
            parts.append(f' {j} {t} ON {t}.{R.choice(cols)}={pt}.{R.choice(pc)}')
    s = ''.join(parts)
    if k >= 3 and R.random() < 0.3 and ',' not in s and 'NATURAL' not in s and 'USING' not in s:
        # A parenthesized (nested) join.
        a, b, c = use
        s = f'{a[0]} LEFT JOIN ({b[0]} JOIN {c[0]} ON {c[0]}.{c[1][0]}={b[0]}.{b[1][1]}) ON {b[0]}.{b[1][0]}={a[0]}.{a[1][0]}'
    if R.random() < 0.1:
        t, cols = use[0]
        s = f'(SELECT * FROM {t} WHERE {cols[1]} IS NOT NULL LIMIT 50) AS {t}' + s[len(t):]
    return use, alias, s


def query(tabs):
    use, alias, f = frm(tabs)
    nt = R.choice([0, 1, 1, 2, 2, 3])
    where = (' WHERE ' + ' AND '.join(term(use, alias) for _ in range(nt))) if nt else ''
    allc = [f'{t}.{c}' for t, cols in use for c in cols]
    group = order = limit = ''
    r = R.random()
    if r < 0.12:
        sel = 'count(*)'
    elif r < 0.25:
        g = R.sample(allc, R.randint(1, 2))
        sel = f'{", ".join(g)}, count(*), sum({R.choice(allc)})'
        group = ' GROUP BY ' + ', '.join(g)
        if R.random() < 0.3:
            group += f' HAVING count(*)>{R.randint(1, 3)}'
    elif r < 0.32:
        sel = f'{R.choice(["min", "max"])}({R.choice(allc)})'
    elif r < 0.42:
        sel = 'DISTINCT ' + ', '.join(R.sample(allc, R.randint(1, 2)))
    else:
        sel = ', '.join(R.sample(allc, R.randint(1, min(4, len(allc)))))
    if R.random() < 0.55 and not sel.startswith(('count(*)', 'min(', 'max(')):
        obs = R.sample(allc, R.randint(1, min(3, len(allc))))
        order = ' ORDER BY ' + ', '.join(o + R.choice(['', ' DESC', ' ASC', ' NULLS FIRST', ' DESC NULLS LAST']) for o in obs)
    if R.random() < 0.3:
        limit = f' LIMIT {R.randint(1, 8)}' + (f' OFFSET {R.randint(1, 4)}' if R.random() < 0.3 else '')
    return f'SELECT {sel} FROM {f}{where}{group}{order}{limit}'


def dml(tabs):
    t, cols = R.choice(tabs)
    alias = {x: x for x, _ in tabs}
    w = ' WHERE ' + term([(t, cols)], alias)
    r = R.random()
    if r < 0.45:
        c = R.choice(cols[1:])
        return f'UPDATE {t} SET {c}={R.choice([lit(), c, "NULL"])}{w}'
    if r < 0.85:
        return f'DELETE FROM {t}{w}'
    t2, c2 = R.choice(tabs)
    return f'INSERT OR IGNORE INTO {t} SELECT {", ".join(c2[i % len(c2)] for i in range(len(cols)))} FROM {t2}{" WHERE " + term([(t2, c2)], alias)}'


def dml_fk(tabs):
    q = dml(tabs)
    return ('PRAGMA foreign_keys=ON; ' + q) if R.random() < 0.4 else q


blocks = []
for bi in range(nblocks):
    tabs, setup = schema()
    qs = [query(tabs) for _ in range(nq)] + [dml_fk(tabs) for _ in range(max(1, nq // 5))]
    blocks.append('\n'.join(setup) + '\n==\n' + '\n'.join(qs))
print('\n----\n'.join(blocks))
