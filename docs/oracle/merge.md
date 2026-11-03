# MERGE와 INSERT ALL

[Oracle 호환](README.md)의 일부입니다.

`MERGE`는 같은 프로그램 안에서 문장 셋으로 내립니다.

```
MERGE INTO t USING s ON (c)
  WHEN MATCHED THEN UPDATE SET ... [WHERE u] [DELETE WHERE d]
  WHEN NOT MATCHED THEN INSERT (cols) VALUES (...) [WHERE i]
=>
UPDATE t SET ... FROM s WHERE c [AND u];
INSERT INTO t (cols) SELECT ... FROM s WHERE NOT EXISTS (SELECT 1 FROM t WHERE c) [AND i];
DELETE FROM t WHERE EXISTS (SELECT 1 FROM s WHERE c [AND u] AND d);
```

- 한 문장(한 VDBE 프로그램)이므로 함께 커밋되고 함께 실패합니다.
- ON 조건이 읽는 열을 UPDATE하면 Oracle처럼 `ORA-38104`입니다. 그래서 UPDATE 뒤에도 같은 행이 일치합니다.
- `DELETE WHERE`는 UPDATE 뒤의 값으로 판단합니다. INSERT 뒤에 실행해서 INSERT가 지울 행을 일치한 행으로 봅니다. 대신 INSERT가 넣은 행이 `DELETE WHERE`를 만족하면 그 행도 지워집니다(Oracle은 UPDATE한 행만 지움).
- 한 대상 행에 원본 행이 여럿 일치하면 Oracle은 `ORA-30926` 오류지만, 여기서는 SQLite의 UPDATE FROM처럼 그중 하나로 갱신합니다.
- UPDATE의 `WHERE u`는 DELETE에서 갱신된 값으로 다시 판단합니다.

`INSERT ALL`/`INSERT FIRST`는 INTO마다 `INSERT INTO ti (cols) SELECT values FROM (subquery) [WHERE ...]` 하나입니다. `INSERT FIRST`의 조건은 `CASE WHEN c1 THEN 1 WHEN c2 THEN 2 ... ELSE 0 END = k`입니다. 서브쿼리는 INTO마다 다시 실행되므로, 비결정적인 식(`SYSTIMESTAMP`는 문장 안에서 같음, `s.NEXTVAL`은 INTO마다 늘어남)은 Oracle과 다를 수 있습니다.
