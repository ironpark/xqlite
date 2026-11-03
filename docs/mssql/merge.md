# MERGE

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

```sql
MERGE INTO t USING (VALUES (2, 'B'), (4, 'D')) AS s (id, v) ON t.id = s.id
WHEN MATCHED AND s.v = 'del' THEN DELETE
WHEN MATCHED THEN UPDATE SET v = s.v
WHEN NOT MATCHED [BY TARGET] THEN INSERT (id, v) VALUES (s.id, s.v)
WHEN NOT MATCHED BY SOURCE THEN UPDATE SET v = 'gone';
```

한 문장(한 VDBE 프로그램) 안에서 다음 순서로 실행합니다.

1. `WHEN NOT MATCHED`: 대상에 맞는 행이 없는 원본 행을 INSERT하고, 그 원본 행을 표시합니다.
2. `WHEN NOT MATCHED BY SOURCE`: 원본에 맞는 행이 없는 대상 행을 DELETE/UPDATE하고, 그 대상 행(rowid)을 표시합니다.
3. `WHEN MATCHED`: DELETE를 먼저, 그다음 `UPDATE ... FROM 원본`. 1.과 2.에서 표시한 행은 건드리지 않습니다.

- 그래서 각 절은 MERGE 전의 행을 기준으로 정해집니다(1.이 넣은 행이 다시 맞거나, 2.가 바꾼 행이 맞게 되어도 다시 처리하지 않음).
- 원본에는 `row_number() OVER ()`로 번호를 붙여 표시합니다. 원본은 단계마다 다시 읽으므로 같은 행을 같은 순서로 돌려주어야 합니다(대상을 읽는 서브쿼리 원본은 그렇지 않을 수 있음).
- 같은 종류의 절이 둘이면 SQL Server처럼 먼저 쓴 절의 조건이 참이 아닌 행만 뒤의 절이 받습니다.
- 다른 점: 한 대상 행에 원본 행이 여럿 맞으면 SQL Server는 실패하지만, 여기서는 그중 하나로 한 번 바뀝니다.
- 지원하지 않는 것: `OUTPUT`과 `$action`, `MERGE TOP`, `WITH ... MERGE`, `INSERT DEFAULT VALUES`, INSERT 값의 `DEFAULT`.
- SQL Server처럼 `;`로 끝나야 합니다.
