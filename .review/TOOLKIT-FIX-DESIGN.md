# agent-workflow 툴킷 수정 설계서 (Opus, 2026-07-12) — v2 · REWORK 반영

> **설계 전용 문서.** 이 문서는 구현하지 않는다. 대상 레포/스크립트/SKILL.md를 수정하지 않는다.
> 근거 입력: `.review/TOOLKIT-AUDIT.md`(감사+codex 반영), `.review/codex-out/CODEX-DEBATE.md`(per-finding 판정·fix order·Hard NOs), `.review/codex-out/TOOLKIT-DESIGN-REVIEW.md`(v1 리뷰 — 치명 6+경미).
> gpt-5.5의 per-finding 판정과 Hard NOs를 **존중**한다. 뒤집는 항목 없음.

### v2 변경 요약 (v1 REWORK 리뷰 반영)
1. **C1 스키마 호환**: `pr_draft.verify_result`를 **삭제하지 않고 deprecated-optional로 유지**(conductor 무시). `if/then` self-certify 제약만 제거(제약 제거는 기존 valid 문서를 깨지 않음). 기존 fixture/artifacts hard-fail 없음. schema_version bump 불필요.
2. **C2 B3 smoke**: `--classify-json`은 아티팩트 emit 전에 조기 exit(`verify.sh:288`)이라 게이트 검증 불가 → **pnpm stub 기반 filter-mode smoke**로 재설계.
3. **C3 B3 exit 흐름**: 아티팩트 write 실패는 **cls_ec==0(PASS)일 때만 exit 5로 뒤집고, FAIL이면 cls_ec 유지**로 명시.
4. **C4 외부 SKILL 분리**: 정책 본문은 **in-repo 플레이북(`docs/agents/multi-agent-workflow.md`)에 반영**(배치 커밋에 포함). 레포 밖 `~/.claude/skills/.../SKILL.md`는 **별도 "Skill-sync 절차"(커밋 아님, 최종 단계)** 로 분리 → 각 배치 독립 green 유지.
5. **C5 B5 검증 명령**: brace expansion 버그 제거 — smoke를 **개별 `bash` 호출**로.
6. **C6 M2 db_database**: verify.sh main은 `db_user/db_host`만 계산(`:342`), database 파싱은 `emit_verify_artifact()` 내부(`:189`)뿐 → **공유 헬퍼 `parse_db_url()`** 신설로 main/emit 단일화, `set -u` 안전.
7. 경미: 필터-적정성 잔여리스크 문서화, branch 교차검증 fail-closed, `parse_verify_artifact` 캡처 코드 명시, `--first-progress-timeout` 개명, RUN 마커 경로 `$WT/.review` 명시, watchdog가 codex-safe를 `$SCRIPT_DIR` 절대경로로 호출.

대상 레포: `/Users/hyojung/Desktop/2026/feedbackops-workflow`
별도 산출물(레포 밖, 커밋 아님): `/Users/hyojung/.claude/skills/agent-workflow/SKILL.md` — "Skill-sync 절차" 참조.

fix order(codex 기준): **M1 → M4 → M3 → M2(좁게) → M5 → verify 아티팩트 fail-closed → I6(heartbeat) → I7(문서화만) → 플레이북 정책(+Skill-sync)**

---

## 공통 원칙 (모든 항목에 적용)

- **bash-3.2 호환**: `declare -A` 금지, `${var,,}` 금지, `PIPESTATUS`는 배열이므로 사용 시 주의(대신 임시파일+exit 캡처 패턴 사용).
- **fail-closed 우선**: 판정 불가 = 통과 아님. 증거 없음/파싱 불가/쓰기 실패 = FAIL 또는 `unknown`.
- **producer 소유권 불변**: CODEX는 검증 사실을 쓰지 않는다. VERIFIER만 `ISSUE-<n>-VERIFY.json`을 쓴다. CONDUCTOR만 그것을 certify한다. (Hard NO #1)
- **doc-sync**: 각 배치 커밋에 코드/스키마 변경과 함께 **in-repo 문서**(README/STATUS/`docs/agents/multi-agent-workflow.md`)를 **같은 커밋**으로 반영. **레포 밖 SKILL.md는 커밋에 넣지 않고**(C4) 맨 끝 "Skill-sync 절차"로 전파.
- **offline smoke**: 모든 스모크는 네트워크·Postgres 없이 통과해야 함(`run-all.sh`가 live 레이어 self-skip).

---

## M1 — 검증 소유권 이전 (verify_result 임베드 제거 → 정본 VERIFY.json 참조)

### 문제 (근거)
`conductor-rebuild.sh:85-90,130-141`이 **CODEX가 작성한** `pr_draft.verify_result.*`(`verified_head_sha/passed/failed/exit_code`)를 신뢰해 `verified`를 찍는다. 정본 검증 증거인 VERIFIER 작성 `ISSUE-<n>-VERIFY.json`(`verify.sh:183,219-275`)은 로드하지 않는다. `pr_draft.schema.json:46-56`의 `verify_result`와 `verify.schema.json:28-39`의 `verdict`가 **스키마 fork** 상태 — 이 fork가 M1의 근원(CODEX-DEBATE.md Missed Defects). → CODEX가 가짜 green을 임베드하면 그대로 통과.

### fix shape (codex 확정, 존중)
- CODEX는 검증 사실을 **쓰지 않는다.** `pr_draft`는 `status: ready_for_review`로 **주장**만 하고, 검증 사실은 담지 않는다.
- `conductor-rebuild`가 `ISSUE-<n>-VERIFY.json`을 **직접 로드**해 5조건을 강제:
  1. `producer_role == "VERIFIER"`
  2. `classifier == "PASS"`
  3. `verdict.failed == 0`
  4. `verdict.passed >= 1`
  5. `head_sha == 해당 worktree의 live HEAD` (+ 기존 branch-identity 교차검증 유지)
- **Hard NO #1 준수**: `verify.sh`가 CODEX의 `pr_draft`를 패치하지 않는다. 소유권 이전은 전적으로 "conductor가 정본을 읽는다"로만 달성.

### 변경 파일 + 정확한 스펙

#### 1) `.review/schemas/pr_draft.schema.json` (C1 — 하위호환 유지)
- **`properties.verify_result` 블록은 삭제하지 않는다.** description만 갱신: `"DEPRECATED — conductor는 이 필드를 무시한다. 검증 사실의 정본은 VERIFIER 작성 ISSUE-<n>-VERIFY.json이다. 하위호환 위해 스키마상 허용만 유지."` → 기존 `ready_for_review` fixture(`fixtures/pr_draft.valid.json:20-25`)와 진행 중 실아티팩트가 `additionalProperties:false`에서도 **계속 valid**.
- 하단 `"if"/"then"`(61-74행) **삭제** — CODEX self-certify 강제 제약 제거. **제약(constraint) 제거는 기존 valid 문서를 절대 깨지 않는다**(더 느슨해질 뿐). `verify_result`를 안 담은 새 `ready_for_review`도 이제 valid.
- (선택, 정보용) `verify_artifact_path`: `{ "type": "string", "description": "informational pointer only; conductor does NOT trust this — derives ISSUE-<n>-VERIFY.json deterministically" }` 추가. **required 아님.** `additionalProperties:false`이므로 property 정의만 추가하면 기존 fixture는 이 키가 없어도 valid, 새 아티팩트가 넣어도 valid.
- **schema_version bump 불필요**: 필드를 제거하지 않으므로 v1 아티팩트가 그대로 통과. (migration/compat-reader 불요 — 삭제를 피함으로써 회피.)

> **결정(추천)**: `verify_result`는 **deprecated-optional로 남기고 conductor가 무시**, `verify_artifact_path`는 **정보용**(conductor 미신뢰). 실제 경로는 `REVIEW_DIR/ISSUE-<issue>-VERIFY.json`으로 **결정적 유도** → CODEX가 다른 이슈 PASS를 지목하는 cross-issue 재사용 원천 차단.

#### 2) `.review/schemas/verify.schema.json`
- 구조 변경 없음. `head_sha`(required, `^[0-9a-f]{40}$`), `verdict.{passed,failed,pending,exit_code}`, `classifier`, `producer_role:VERIFIER`, `issue`(integer), `branch` 모두 이미 존재 — conductor 교차검증에 필요한 필드가 전부 있음. **fork 해소는 pr_draft 쪽 삭제로 달성.**

#### 3) `scripts/conductor-rebuild.sh` — `process_pr_draft()` 재작성
기존 87-90행(`v_head/v_passed/v_failed/v_exit`를 pr_draft에서 읽음) 제거. 대신:

의사코드:
```
issue   = parse_field(pr_draft, 'issue.number')
branch  = parse_field(pr_draft, 'branch')
status  = parse_field(pr_draft, 'status')
worktree= parse_field(pr_draft, 'worktree_path')

# status가 ready_for_review가 아니면 기존대로 in_progress로 확정하고 반환
if status != "ready_for_review": state=in_progress; print; return

# 정본 VERIFY.json 결정적 유도 (CODEX 포인터 무시)
vfile = "$REVIEW_DIR/ISSUE-${issue}-VERIFY.json"
if not exists(vfile): state=unknown (증거 없음); print; return

# VERIFY.json을 한 번의 node 호출로 모두 읽음 (I10 회귀 방지: 필드당 스폰 금지).
# parse_verify_artifact는 8필드를 TAB 1줄로 출력; 파싱 실패 시 stdout 비우고 exit 2.
# 캡처(경미#3 구체화): 명령치환 + 종료코드 확인, 그다음 tab-split.
vline="$(parse_verify_artifact "$vfile")"; vrc=$?
if [ "$vrc" -ne 0 ] || [ -z "$vline" ]; then
    echo "conductor-rebuild: $vfile parse failed → unknown (fail closed)" >&2
    state=unknown; print; return
fi
# bash-3.2: IFS=tab 로 안전 분해 (값에 tab 없음 — VERIFY.json 값은 sha/enum/int/branch)
oldIFS=$IFS; IFS="$(printf '\t')"
set -- $vline; IFS=$oldIFS
v_role=$1 v_class=$2 v_failed=$3 v_passed=$4 v_exit=$5 v_head=$6 v_issue=$7 v_branch=$8

# 5조건 + 아이덴티티 교차검증. 하나라도 어긋나면 unknown (fail-closed).
# 경미#2: branch는 fail-closed — pr_draft.branch가 없거나 VERIFY.branch와 불일치면 거부.
if not (v_role=="VERIFIER" and v_class=="PASS"
        and v_failed=="0" and v_passed non-empty and v_passed!="0"
        and v_exit=="0"
        and v_issue==issue
        and branch non-empty and branch!="(unknown-branch)" and v_branch==branch):
    log stderr 이유; state=unknown; print; return

# live HEAD 해석은 기존 로직 그대로 재사용 (worktree 존재 + branch-identity 일치 확인,
# fallback은 절대 verified 승격 불가 = 기존 R6/RF2 보존).
resolve actual_head, head_source  (기존 112-127행 로직 그대로)

if actual_head == "":            state=unknown
elif head_source=="fallback":    state=unknown   # 자기인증 금지(R6)
elif v_head == actual_head:      state=verified
else:                            state=stale_verify
```
- **신규 헬퍼 `parse_verify_artifact(vfile)`** (경미#3 구체화): 단일 `node -e`로 8필드를 **TAB 구분 1줄** stdout 출력, 파싱 실패/JSON 비객체면 stdout 비우고 `process.exit(2)`. 기존 `parse_field`는 stderr를 `2>/dev/null`로 죽이는데(`:41,55`), 이 헬퍼도 동일하게 `2>/dev/null`로 감싸 호출측이 exit code만 본다. 출력 순서 고정: `producer_role \t classifier \t verdict.failed \t verdict.passed \t verdict.exit_code \t head_sha \t issue \t branch`. 누락 필드는 빈 문자열(→ 위 조건에서 fail-closed). node 8-스폰 대신 1-스폰(I10 회귀 방지).
  - node 스니펫 형태: `parse_field`와 동형이되 여러 값을 `[a,b,...].join("\t")`로 출력, `catch → process.exit(2)`.
- 헤더 주석(1-17행) 갱신: "verified는 정본 `ISSUE-<n>-VERIFY.json`(VERIFIER 소유)로만 판정. pr_draft.verify_result는 deprecated(무시)."

> **경미#1 잔여리스크(정직하게 명시)**: head/branch/issue가 맞아도, VERIFIER가 **엉뚱하게 좁은 test filter**로 PASS를 냈다면 그 VERIFY.json이 ready를 인증할 수 있다(필터 적정성은 머신-체크 불가). 완화: conductor가 `VERIFY.json.verify_cmd`와 `pr_draft.verify_cmd`(둘 다 의도한 필터를 담음)를 **경고 수준으로 교차대조**(불일치 시 stderr WARN, 상태는 강등하지 않음 — CODEX-authored라 hard-gate 부적합). **근본 방어는 리뷰 단계**(REVIEWER가 필터가 변경 범위를 덮는지 확인)이며, 이를 플레이북 §5/§6에 명시. 이 한계를 v2에서 문서화한다.

### smoke (`scripts/__tests__/conductor-rebuild.smoke.sh` 개정)
기존 Case 1~9는 pr_draft에 `verify_result`를 임베드 → **전면 개정 필요**(그 필드는 이제 무시/폐지). 새 케이스:
- **C1 verified**: pr_draft(ready, worktree=REPO1/feat-101) + `ISSUE-101-VERIFY.json`(role VERIFIER, PASS, failed0 passed5 exit0, head=SHA1, issue101, branch feat/101) → `verified`.
- **C2 stale_verify**: 동일하되 VERIFY 작성 후 REPO2 HEAD 전진 → `stale_verify`, NOT verified.
- **C3 no-artifact**: ready지만 `ISSUE-<n>-VERIFY.json` 파일 없음 → `unknown`(증거 없음), NOT verified. **(가짜 green 회귀 가드 핵심)**
- **C4 classifier FAIL**: VERIFY.json 존재하나 `classifier:FAIL` → `unknown`, NOT verified.
- **C5 wrong producer**: VERIFY.json `producer_role:CODEX`(위조) → `unknown`, NOT verified. **(소유권 위조 가드)**
- **C6 issue mismatch**: `ISSUE-101-VERIFY.json`의 내부 `issue`가 999 → `unknown`. **(cross-issue 재사용 가드)**
- **C7 branch mismatch**: VERIFY.branch != pr_draft.branch → `unknown`.
- **C8 fallback self-certify**: worktree 없음 + fallback==head → `unknown`(R6 보존).
- **C9 branch-identity(RF2)**: 기존 Case 9 이관 — worktree가 다른 브랜치 → `unknown`.
- **C10 in_progress**: status needs_amendment → `in_progress`.
- **C11 superseded skip**, **C12 blocker**: 기존 유지.

### doc-sync (동일 커밋 — in-repo 파일만; SKILL은 Skill-sync 절차로 분리)
- `docs/agents/multi-agent-workflow.md` §7(state reconstruction) + L98 부근: "pr_draft.verify_result는 deprecated(무시), conductor가 정본 VERIFY.json 5+2조건 강제"로 갱신. §5/§6에 "필터 적정성은 REVIEWER가 확인"(경미#1) 추가.
- `README.md` "The model"의 Release Captain 줄, `STATUS.md` "Key operating facts": `pr_draft` conditional verify_result 언급을 "deprecated, VERIFIER 정본 기준"으로 치환.
- (SKILL.md rule #3/Step 7 갱신은 **Skill-sync 절차**에서 — repo 커밋 아님. 아래 별도 섹션.)

### 리스크 / 롤백
- **리스크(C1 해소)**: `verify_result`를 삭제하지 않고 deprecated-optional로 유지 → 기존 `ready_for_review` fixture(`pr_draft.valid.json:20`)와 진행 중 실아티팩트가 **계속 valid**. 마이그레이션/compat-reader 불요. 진행 중 이슈는 다음 VERIFIER 실행 때 정본 VERIFY.json이 생기면 자동 정상화.
- **롤백**: 3파일(schema/스크립트/스모크) 단일 커밋 revert.

---

## M4 — typecheck fail-closed

### 문제 (근거)
`verify.sh:318` `pnpm --filter backend run typecheck 2>&1 | grep -E "error TS[0-9]+" | sort -u > "$tmp_current" || true`. 파이프라인이 **pnpm의 exit를 삼킨다**. typecheck가 **실행조차 안 된 경우**(스크립트 부재, tsc 크래시, config 오류)엔 `error TS` 라인이 0개 → `tmp_current` 비어있음 → `typecheck_diff`가 "새 에러 없음"으로 **PASS**. (CODEX-DEBATE M4)

### fix (codex: "exit를 별도 캡처, TS 에러 관측·diff로 인한 non-zero만 허용, 그 외 fail-closed")
`--typecheck` 분기(308-320행) 교체. 핵심: tsc는 **타입 에러 존재 시 정상적으로 non-zero**를 반환하므로, 단순 "non-zero면 FAIL"은 틀림. **구분**: (a) tsc가 돌았고 TS 에러를 뱉음(non-zero + `error TS` 라인 있음) = 정상 → baseline diff 진행. (b) 명령이 실행 실패/크래시(non-zero + `error TS` 라인 0개) = fail-closed FAIL.

의사코드:
```
raw="$(mktemp -t verify-typecheck-raw.XXXXXX)"
tmp_current="$(mktemp -t verify-typecheck.XXXXXX)"
trap 'rm -f "$raw" "$tmp_current"' EXIT

pnpm --filter backend run typecheck > "$raw" 2>&1
pnpm_ec=$?                                  # 파이프 없이 직접 캡처 (PIPESTATUS 회피)
grep -E "error TS[0-9]+" "$raw" | sort -u > "$tmp_current" || true

if [ "$pnpm_ec" -ne 0 ] && [ ! -s "$tmp_current" ]; then
  echo "FAIL: typecheck command did not run or crashed (exit $pnpm_ec) with no parseable 'error TS' lines — fail closed" >&2
  echo "----- typecheck output (head) -----" >&2
  sed -n '1,40p' "$raw" >&2                 # 진단 노출
  exit 1
fi
typecheck_diff "$baseline" "$tmp_current"
exit $?
```
- `pnpm_ec==0` → 에러 0개 → `tmp_current` 비어 diff PASS(정상).
- `pnpm_ec!=0 && tmp_current 있음` → 실제 TS 에러 → baseline diff(신규 에러만 FAIL, 기존 동작 유지).
- `pnpm_ec!=0 && tmp_current 없음` → 실행 실패 → **FAIL 닫힘**(신규 게이트).

### smoke (`scripts/__tests__/verify.smoke.sh` 보강)
`--typecheck`는 pnpm/tsc 실환경이 필요하므로 순수 유닛화가 어려움. 대신 **주입 가능한 형태로 테스트**:
- 우선 `typecheck_diff`(순수 함수)는 이미 `--typecheck-diff` 서브커맨드로 직접 테스트 가능 → 기존 케이스 유지.
- 신규: `--typecheck`의 fail-closed 로직을 검증하려면 pnpm을 stub해야 함. **설계**: 스모크에서 `PATH` 앞에 가짜 `pnpm`(exit 1, "error TS" 없이 임의 stderr 출력) 셸스크립트를 두고 `verify.sh --typecheck`가 **exit 1(FAIL)** 하는지 확인. 두 번째 stub(`pnpm` exit 1 + "src/x.ts(1,1): error TS2304: ..." 출력, baseline 비어있음)로 diff 경로가 타져 신규 에러로 FAIL 하는지. 세 번째 stub(exit 0, 무출력)로 PASS. → **fail-closed / 정상-fail / pass** 3케이스.
  - stub 주입: `TMPBIN="$(mktemp -d)"; printf '#!/usr/bin/env bash\n...\n' > "$TMPBIN/pnpm"; chmod +x; PATH="$TMPBIN:$PATH" bash verify.sh --typecheck`. bash-3.2 호환.

### doc-sync
- `docs/agents/multi-agent-workflow.md`의 "Baseline-aware typecheck" 섹션: "typecheck 명령 자체가 실행 실패하면 fail-closed(빈 결과=PASS 아님)" 한 줄 추가.
- `STATUS.md` v0.2 typecheck 항목에 fail-closed 보강 명시.

### 리스크 / 롤백
- **리스크**: 대상 레포에 backend `typecheck` 스크립트가 없으면 이제 FAIL(기존엔 조용히 PASS). 이는 **의도된** 엄격화 — I7 문서에 "backend typecheck 스크립트 전제"를 명시. 롤백: verify.sh 단일 커밋 revert.

---

## M3 — codex-safe gpt-5.6 effort 핀 (+ ChatGPT 계정 미지원 주석)

### 문제 (근거)
`codex-safe.sh:32` `_eff="${EFFORT:-medium}"`는 **가드 판정에만** 쓰이고, 실제 디스패치(55-56행)는 `--effort`가 있을 때만 `-c model_reasoning_effort`를 전달. → MODEL이 5.6이고 `--effort` 생략이면 가드는 medium으로 보고 통과하지만 **effort는 codex config 기본값에 위임** → config 기본이 high면 정책 우회. (CODEX-DEBATE M3)

### fix
5.6 매칭 + `EFFORT` 공백이면 **`EFFORT="medium"`으로 실제 핀**(가드용 로컬변수가 아니라 디스패치에 전달되는 변수 자체를 고정). 그 뒤 high/xhigh/max 밴 검사.

의사코드(29-40행 교체):
```
# Policy guard: gpt-5.6 ABOVE medium reasoning is forbidden (cost).
# NOTE(2026-07-12 실측): gpt-5.6은 ChatGPT 계정에서 아예 미지원. 이 가드는
# API 계정/향후 지원 대비 defense-in-depth로 유지한다.
case "$MODEL" in
  *5.6*|*5-6*)
    # config 기본값 상속 방지: effort 미지정이면 medium으로 명시 핀.
    [[ -z "$EFFORT" ]] && EFFORT="medium"
    case "$EFFORT" in
      high|xhigh|max)
        echo "REFUSED: gpt-5.6 at '$EFFORT' reasoning is banned (max allowed: medium); lower --effort or change model" >&2
        exit 2 ;;
    esac ;;
esac
```
- 이렇게 하면 5.6일 때 EFFORT는 항상 non-empty → 55-56행이 `-c model_reasoning_effort="medium"`을 **반드시** 전달 → config 기본값 우회 불가.
- 기존 `_eff` 로컬변수 삭제(불필요해짐).

### smoke (`scripts/__tests__/codex-safe.smoke.sh` 보강)
codex를 실제 호출하지 않는 arg-validation 스타일 유지. 문제: 현재 스모크는 codex 실행 전 인자 검증만 검사. effort 핀은 codex 호출 인자에 반영되므로 **codex를 stub**해야 관측 가능.
- **설계**: `PATH` 앞에 가짜 `codex`(인자를 파일로 기록 후 exit 0) 주입. 케이스:
  - `--model gpt-5.6 --issue 1 --prompt x` → 기록된 인자에 `model_reasoning_effort="medium"` 포함(핀 확인).
  - `--model gpt-5.6 --effort high ...` → **exit 2**(밴 확인, codex 미호출).
  - `--model gpt-5.6 --effort medium ...` → exit 0 + medium 전달.
  - `--model gpt-5.5 ...`(effort 없음) → medium 강제 안 함(핀은 5.6 전용) — codex 인자에 `model_reasoning_effort` 미포함 확인.
  - 기존 3케이스(missing issue/prompt/unknown arg) + `--sandbox workspace-write` grep 유지.

### doc-sync
- (플레이북 모델 배분표에 "5.6은 ChatGPT 계정 미지원; codex는 gpt-5.5" 명시 — B8. SKILL.md 반영은 Skill-sync.)
- `STATUS.md`/`README.md`: codex-safe 설명에 "5.6 effort 자동 medium 핀" 한 줄.

### 리스크 / 롤백
- 낮음. 5.6은 현재 미지원이라 실사용 영향 없음(방어적). 롤백: 단일 커밋 revert.

---

## M2 — env-profile ↔ apps/backend/.env 처리 + 실효 DATABASE_URL 어서션 (좁은 fix)

### 문제 (근거 / codex: 과장 판정, 좁은 real gap)
`prepare-worktree.sh:194-203`: `--env-profile`은 `<wt>/.env`만 쓰고 default 모드는 `<wt>/.env`+`<wt>/apps/backend/.env` **둘 다** 씀. `verify.sh:326-335`는 `./.env` 다음 `apps/backend/.env`를 **나중에** source → 나중 것이 승리. 재사용된 worktree에 **stale `apps/backend/.env`**가 있으면 profile의 `.env`를 덮어써 **엉뚱한 DB**로 검증. (단, 현재 FeedbackOps는 `process.env` 사용 + `verify.sh:337-340`이 `VERIFY_DATABASE_URL`을 env source **후**에 적용해 최종 승리 → 즉시 위험은 아님. codex: EXAGGERATED, 좁은 fix.)

### fix (codex fix shape 중 "write both from the same profile" 채택 + 실효 DB 어서션)

**결정(추천)**: profile 모드에서 profile을 `<wt>/.env`와 `<wt>/apps/backend/.env` **양쪽에 동일 기록**. 이유: default 모드와 대칭 → source 순서와 무관하게 profile의 DATABASE_URL이 최종 승리, stale backend override 원천 차단. (stomp-삭제 대안은 backend .env의 비-DB 키까지 잃을 수 있어 비추천. profile은 "self-contained"가 계약이므로 양쪽 기록이 안전.)

#### 1) `scripts/prepare-worktree.sh` (194-203행)
```
if [[ -n "$ENV_PROFILE" ]]; then
  [[ ! -f "$ENV_PROFILE" ]] && { echo "ERROR: --env-profile file not found: $ENV_PROFILE" >&2; exit 1; }
  copy_env "$ENV_PROFILE" "$WT_PATH/.env"
  copy_env "$ENV_PROFILE" "$WT_PATH/apps/backend/.env"   # 대칭: stale backend override 방지
else
  copy_env "$SOURCE_ENV/.env" "$WT_PATH/.env"
  copy_env "$SOURCE_ENV/apps/backend/.env" "$WT_PATH/apps/backend/.env"
fi
```
> **계약 문서화**: env profile은 **self-contained**(검증에 필요한 모든 키 포함)여야 함 — 양쪽에 같은 파일이 쓰이므로. `.env.example`/README에 명시.

#### 2) `scripts/verify.sh` — 실효 DATABASE_URL 어서션 (C6: 공유 헬퍼로 db_database 정합)
**문제(C6)**: 현재 main(342-357행)은 `db_user`(role)와 `db_host`만 계산하고 **`db_database`는 없다**. database 파싱은 `emit_verify_artifact()` 내부(189-211행)에만 존재. 그대로 stderr에 `$db_database`를 쓰면 `set -u`(26행)에서 **unbound 오류**. 또 main과 emit이 URL 파싱을 이중구현 → 불일치 위험.

**fix**: URL→(host, database, role) 파싱을 **공유 함수 `parse_db_url()`** 로 추출해 main과 emit이 **같은 로직**을 호출. 전역 3변수(`DB_HOST/DB_DATABASE/DB_ROLE`)에 세팅(set -u 안전하게 함수 진입 시 `DB_HOST=""; DB_DATABASE=""; DB_ROLE=""` 초기화).
```
parse_db_url() {                       # $1 = url. 전역 DB_HOST/DB_DATABASE/DB_ROLE 세팅.
  DB_HOST=""; DB_DATABASE=""; DB_ROLE=""
  [ -z "${1:-}" ] && return 0
  # emit_verify_artifact:189-210의 sed 파이프라인을 그대로 이 함수로 이동(중복 제거).
  ... (기존 host/database/role 추출 로직) ...
}
```
- main: `VERIFY_DATABASE_URL` 적용(337-340행) 후 로컬-가드 자리에서 `parse_db_url "$DATABASE_URL"` 호출 → `DB_HOST`로 로컬-호스트 가드(기존 358-364행 대체), `DB_ROLE`로 superuser WARN(기존 344-347행 대체). 그다음 vitest 자식 실행(392행) 직전:
```
echo "VERIFIER effective DB → host=$DB_HOST db=$DB_DATABASE role=$DB_ROLE (injected into vitest child)" >&2
```
- `emit_verify_artifact()`: 자체 189-211행 파싱을 **삭제**하고 `parse_db_url "$DATABASE_URL"` 호출 후 `DB_HOST/DB_DATABASE/DB_ROLE`를 `db_target`에 사용 → **stderr와 아티팩트가 단일 소스**로 정합(C6 해소). password는 어디에도 출력/기록 안 함(host/db/role만).
- set -u 안전: 함수가 항상 3변수를 먼저 빈값 초기화하므로 URL이 없어도 unbound 없음.
- **범위 한정(Hard NO #4 준수)**: "테스트 프로세스 내부(app dotenv 재로드)까지 파고드는 어서션"은 대상별(app config import)이라 **일반화하지 않음**. 현재 FeedbackOps는 process.env 사용이라 자식이 보는 값 == 주입 값. 향후 런타임 dotenv 로드 타깃이 생기면 그때 대상별 프로브 추가(문서에 caveat 명시).

### smoke
- `prepare-worktree.smoke.sh`: profile 모드에서 `<wt>/.env`와 `<wt>/apps/backend/.env`가 **둘 다** profile 내용으로 생성되는지 확인(파일 존재 + 내용 일치). pnpm install은 스킵되는 경로가 없으므로, 기존 스모크가 쓰는 `--report-env-only`/hidden 모드처럼 **env 복사만 검증하는 방식**을 재사용하거나, `pnpm`을 stub해 install 단계를 무력화하고 복사 결과만 assert.
- `verify.smoke.sh`: 신규 공유 함수 `parse_db_url`을 **직접 유닛 테스트**하기 위해 verify.sh에 hidden 서브커맨드 `--parse-db-url <url>`(출력: `host\tdb\trole`)를 추가하거나, 스모크에서 함수를 source해 호출. 다양한 URL(ipv6 `[::1]`, 포트, 쿼리스트링, password 포함/미포함)→기대 host/db/role 케이스. password가 출력에 절대 안 나오는지 assert. 실효 stderr 라인은 B3의 filter-mode stub 스모크에서 부수적으로 관측.

### doc-sync
- `docs/agents/multi-agent-workflow.md`(env/prepare 섹션): "profile 모드는 `.env`+`apps/backend/.env` 양쪽 기록; profile은 self-contained여야; verify가 실효 DATABASE_URL을 redacted로 출력" 반영.
- `.env.example`: profile self-contained 요건 주석.
- `README.md` prepare-worktree 줄에 대칭 기록 명시.

### 리스크 / 롤백
- **리스크**: profile이 root/backend에서 서로 다른 키를 기대하는 앱에선 양쪽 동일 기록이 backend-only 키를 누락시킬 수 있음 → "profile self-contained" 계약으로 방어(문서). 현재 타깃은 process.env라 무해. 롤백: 2파일 단일 커밋 revert.

---

## verify.sh 아티팩트 쓰기실패 fail-closed (VERIFY_ISSUE 모드) — codex "동급 MUST-FIX"

### 문제 (근거)
`verify.sh:276-279` 아티팩트 write 실패 시 `WARN` + `return 0`(non-fatal), `main()`은 반환을 무시하고 `exit "$cls_ec"`(403-407행). 문서(playbook L136)도 "artifact 실패는 exit 불변" 명시. → **green + 아티팩트 미기록**이 exit 0(done)으로 읽힘. 이 워크플로에서 **증거가 제품**이므로 무효. (CODEX-DEBATE Missed Defects)

### fix
`VERIFY_ISSUE` 모드에서 **유효한 아티팩트를 못 쓰면 FAIL**. 단, 테스트가 이미 FAIL이면 그 FAIL은 정당하므로(FAIL classifier 아티팩트도 정당한 증거) — 이 게이트는 **PASS를 FAIL로 뒤집을 뿐, FAIL을 PASS로 만들지 않는다.**

#### 1) `emit_verify_artifact()` (169-280행)
- `mkdir -p .review` 실패(184행), node write 실패(276행)의 `WARN + return 0` → **`echo FAIL... + return 1`** 로 변경.
- write 직후 **검증**: 쓴 파일을 재파싱해 필수 필드(`classifier`, `head_sha` non-empty, `verdict` 존재) 확인. 불충족 시 `return 1`. (부분/깨진 아티팩트도 실패로.)
- `VERIFY_ISSUE`가 정수 아님(177-181행)일 때의 `WARN + return 0`은 **유지**(호출측에서 애초에 아티팩트 요구 안 함 — 아래 main 가드는 정수일 때만).

#### 2) `main()` (403-407행) — C3: PASS만 뒤집고 FAIL은 유지
```
if [ -n "${VERIFY_ISSUE+x}" ] && [ -n "$VERIFY_ISSUE" ]; then
  emit_verify_artifact "$VERIFY_ISSUE" "$filter" "$tmp_report" "$vitest_ec" "$classifier"
  emit_ec=$?
  if [ "$emit_ec" -ne 0 ]; then
    if [ "$cls_ec" -eq 0 ]; then
      # PASS인데 증거 미기록 → done 아님. 뒤집는다.
      echo "FAIL: green run but could not write a valid verify artifact — evidence is the product (fail closed)" >&2
      exit 5
    else
      # 이미 FAIL. 아티팩트 실패는 FAIL을 가리지 못하며 PASS로도 못 만든다 → cls_ec 유지.
      echo "WARN: verify artifact write failed on an already-failing run; preserving test FAIL (exit $cls_ec)" >&2
    fi
  fi
fi
exit "$cls_ec"
```
- green + 아티팩트 실패 → **exit 5**. **FAIL 테스트 + 아티팩트 실패 → exit cls_ec(≠0, 유지)** ← C3 수정 핵심. green + 정상 아티팩트 → exit 0. `VERIFY_ISSUE` 미설정 → 기존 동작 불변.

### smoke (`verify.smoke.sh`) — C2: filter-mode + pnpm stub (‑‑classify-json 경로 불가)
`--classify-json`은 아티팩트 emit 전에 exit(`verify.sh:288`)하므로 게이트를 못 탄다. **filter mode**로만 emit(`:403`)이 돈다 → pnpm/vitest를 stub해 filter mode를 오프라인 구동.

- **stub 설계**: `TMPBIN`에 가짜 `pnpm` 배치. 이 stub은 인자에서 `--outputFile=<path>`를 파싱해 그 경로에 **가짜 green JSON 리포트**(`{"numPassedTests":3,"numFailedTests":0,"numPendingTests":0,"numFailedTestSuites":0,"success":true,"testResults":[]}`)를 쓰고 `exit 0`. verify.sh는 자식을 `env -i ... PATH=$PATH ...`로 띄우는데 `PATH`가 allowlist(`:371`)에 있으므로, 호출 전에 `PATH="$TMPBIN:$PATH"`로 prepend하면 stub이 자식에 도달.
- **케이스 A (green + 아티팩트 실패 → exit 5)**: 워크트리 임시 git repo에서 `.review`를 **파일로 생성**(디렉토리 mkdir 실패 유도) → `VERIFY_ISSUE=1 PATH="$TMPBIN:$PATH" bash verify.sh somefilter` → **exit 5**.
- **케이스 B (green + 정상 → exit 0)**: `.review` 쓰기 가능 → exit 0 + `.review/ISSUE-1-VERIFY.json` 존재 + `verify.schema.json` valid.
- **케이스 C (FAIL + 아티팩트 실패 → exit ≠0, ≠5)**: stub이 `numFailedTests:1, success:false` 리포트 + `exit 1` → `.review` 파일화로 write 실패 → 최종 exit == cls_ec(비-5 실패). C3 회귀 가드.
- **케이스 D (VERIFY_ISSUE 미설정 → 불변)**: green stub, 아티팩트 없이 exit 0.
- 로컬-DB 가드(`:358`)를 통과시키려면 `VERIFY_DATABASE_URL=postgres://fops_app@127.0.0.1/verify_smoke` 등 로컬 URL 주입(실제 접속은 stub이라 불필요).
- bash-3.2 호환, Postgres·네트워크 불요.

### doc-sync
- `docs/agents/multi-agent-workflow.md` L136: "artifact-write는 non-fatal" → **"VERIFY_ISSUE 모드에서 유효 아티팩트 미기록 = FAIL(exit 5)"** 로 정정.
- `STATUS.md` v0.3 provenance 항목의 "Non-fatal; never flips exit" 문구 정정.
- (플레이북에 "증거(아티팩트) 미기록도 done 아님" 반영 — B3. SKILL.md rule #3 반영은 Skill-sync.)

### 리스크 / 롤백
- **리스크**: 아티팩트 쓰기 불가한 CI/권한 환경에서 이전엔 통과하던 것이 이제 FAIL. 의도된 엄격화. 롤백: verify.sh 단일 커밋 revert.

---

## I6 — codex 스톨 워치독 (heartbeat/파일 진행 기반; stdout 첫토큰 금지)

### 문제 (근거)
codex-safe 디스패치가 first-token에서 간헐 스톨(task_started, 0% CPU, 무출력). 자동화 없음. **Hard NO #2: stdout "첫토큰"을 재시도 오라클로 쓰지 말 것**(버퍼링/희소출력/파일-only 상태). codex: **프로세스 liveness + 명시적 아티팩트/heartbeat 파일 계약** 사용. (+ 2026-07-12 실측: **4xx 모델거부는 재시도 무의미 → fail-fast**.)

### fix — 신규 스크립트 `scripts/codex-watchdog.sh`
codex-safe.sh는 **containment 최소 래퍼로 유지**하고, 그 위에 liveness 감시 래퍼를 별도 신설(관심사 분리, codex-safe 오염 방지).

**진행 오라클(핵심, first-token 금지)**: **워크트리 파일시스템 mtime 전진**을 1차 신호로 사용 — codex 협조 불필요. 보조로 heartbeat 파일 계약.

인자(경미#4: `first-token` 용어는 Hard NO와 충돌 → **`--first-progress-timeout`** 으로 개명. 동작은 파일진행 기반이며 stdout과 무관함을 이름으로 못박음):
`--issue N --prompt-file F --cwd WT [--first-progress-timeout 240] [--stall-timeout 180] [--max-retries 2]`
(기본값: 첫 파일진행 대기 4분, 이후 무진행 3분, 재시도 2회 — memory의 watchdog 폴링 규약과 정합.)

의사코드:
```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 경미#6: PATH 아닌 절대경로
CODEX_SAFE="$SCRIPT_DIR/codex-safe.sh"
attempt=0
STAMP="$(mktemp)"                 # -newer 비교 기준
stderr_log="$(mktemp)"            # codex-safe stderr (4xx 분류용 — liveness 아님)
run_marker="$WT/.review/ISSUE-${N}-RUN.json"   # 경미#5: 워크트리의 .review (VERIFY.json과 동일 위치)
mkdir -p "$WT/.review"

progressed() {                    # 워크트리에 STAMP 이후 변경 파일이 있나 (node_modules/.git 제외)
  find "$WT" -path '*/node_modules' -prune -o -path '*/.git' -prune -o -newer "$STAMP" -print -quit
  # 비어있지 않으면 진행함. (POSIX -newer; macOS/bash-3.2 호환)
}

while [ "$attempt" -le "$MAX_RETRIES" ]; do
  attempt=$((attempt+1))
  write run_marker {issue, attempt, pid:(곧), started_at, updated_at, status:"running"}
  NODE_OPTIONS= "$CODEX_SAFE" --issue N --prompt-file F --cwd WT 2>"$stderr_log" &   # NODE_OPTIONS 클리어(오염 방지)
  pid=$!
  touch "$STAMP"; first_seen=0; last_progress=$(now)
  while kill -0 "$pid" 2>/dev/null; do
    sleep POLL(=15s)
    if progressed; then touch "$STAMP"; last_progress=$(now); first_seen=1; fi
    budget = first_seen ? STALL_TIMEOUT : FIRST_PROGRESS_TIMEOUT
    if (now - last_progress) >= budget:
        # 스톨 판정: 프로세스 살아있음 + 파일 진행 없음 (stdout 무관)
        kill_tree "$pid"; update run_marker status:"killed_stall"
        # codex-safe의 EXIT trap이 workflow-stash로 부분작업 보존
        break   # → 재시도 루프
  done
  wait "$pid"; ec=$?
  if [ "$ec" -eq 0 ]; then update run_marker status:"exited",exit_code:0; exit 0; fi

  # 4xx 모델거부 fail-fast 분기: codex-safe stderr를 로그파일로 캡처해 4xx/refusal 서명 검사.
  # (주의: 이건 liveness 오라클이 아니라 '재시도 무의미' 분류기다 — Hard NO #2와 무관.)
  if grep -qiE '4[0-9][0-9]|unsupported model|model_not_found|invalid.*(model|api key)|unauthorized' "$stderr_log":
      update run_marker status:"refused"; echo "FAIL-FAST: model refusal (4xx) — retry futile" >&2; exit 4
  # 그 외 non-zero(스톨 kill 포함)는 재시도
done
update run_marker status:"exhausted"; echo "FAIL: codex stalled/failed after $MAX_RETRIES retries" >&2; exit 6
```

**중요 구분(Hard NO #2 준수)**:
- **liveness 오라클** = 프로세스 생존(`kill -0`) + **파일시스템 진행**(`find -newer`). stdout 첫토큰 **미사용**.
- **4xx 분류기** = codex-safe **stderr/exit** 패턴 — 이는 "재시도 vs 즉시실패" 결정용일 뿐, "살아있음 vs 스톨" 판정에 쓰지 않음. 두 역할을 문서/코드 주석에서 명확히 분리.

### 신규 스키마 `.review/schemas/run.schema.json`
```
artifact_type: "codex_run", schema_version:"1",
required: [schema_version, artifact_type, issue, attempt, started_at, updated_at, status]
issue:int, attempt:int, pid:int(optional), started_at/updated_at:ISO string,
status: enum[running, exited, killed_stall, refused, exhausted],
exit_code:int(optional)
additionalProperties:false
```
(기존 `heartbeat.schema.json`은 pane 상태용이라 재사용 부적합 — run 마커는 별도.)

### smoke (`scripts/__tests__/codex-watchdog.smoke.sh` 신설)
codex 미호출, offline. `PATH`에 가짜 codex 주입:
- **stub A(즉시 성공)**: 파일 하나 touch 후 exit 0 → 워치독 exit 0, run_marker status exited.
- **stub B(스톨)**: `sleep 999` 하며 아무 파일도 안 건드림 → `--first-progress-timeout`을 2s로 낮춰 → 워치독이 kill + 재시도 + 최종 exit 6, status exhausted. (테스트는 타임아웃 파라미터를 초 단위로 축소.) stub은 PATH의 가짜 `codex`(codex-safe.sh가 `codex exec` 호출).
- **stub C(진행하다 완료)**: 주기적으로 파일 touch(진행 신호) 후 exit 0 → 스톨로 오판 안 하고 exit 0.
- **stub D(4xx)**: stderr에 "404 model_not_found" 출력 후 exit 1 → **재시도 없이 exit 4**(fail-fast), status refused.
- run_marker가 `run.schema.json`에 valid한지 fixture 검증.

### doc-sync
- `docs/agents/multi-agent-workflow.md`: 신규 "Codex 스톨 워치독" 섹션 — liveness=프로세스+파일, first-token 금지, 4xx fail-fast, RUN 마커 계약.
- (플레이북 Step 4에 "codex 디스패치는 `codex-watchdog.sh`로 감싸 스톨 자동 kill+재시도; stdout 첫토큰 의존 금지" 반영 — B6. codex-safe 필수(rule #1) 유지, watchdog가 codex-safe를 **호출**. SKILL.md 반영은 Skill-sync.)
- `README.md` core scripts 표 + `STATUS.md`에 codex-watchdog + run.schema 추가.

### 리스크 / 롤백
- **리스크**: `find -newer` 폴링이 대형 워크트리에서 비용 → node_modules/.git prune + `-print -quit`로 조기 종료. 잘못된 스톨 오판 방지 위해 기본 타임아웃 보수적(4분/3분). 4xx 정규식 오탐 가능 → 보수적 패턴 + 로그 노출. 롤백: 신규 파일 3종(스크립트/스키마/스모크) + doc, 단일 커밋 revert(기존 경로 무변경이라 안전).

---

## I7 — backend-only 계약 문서화 (코드 변경 없음)

### 문제 (근거)
`README.md:5` "reused against any target codebase" + `README.md:34`는 일반성 주장. 그러나 `verify.sh:9-17,392`는 `pnpm --filter backend exec vitest` 하드코딩 = **backend Vitest 전용**. (CODEX-DEBATE I7 / Hard NO #4: 두 번째 실타깃 전까지 일반화 금지.)

### fix — 문서만
- `README.md:5`: "reused against any target codebase" → "reused against a target codebase **whose backend is a pnpm workspace tested with Vitest** (the verify oracle is backend-Vitest-specific today; parameterization deferred until a second real target)".
- `verify.sh` 헤더 주석: "현재 계약: pnpm workspace의 `--filter backend` + Vitest 전용. 타깃 일반화는 두 번째 실타깃+fixture 생기면." 명시.
- `docs/agents/multi-agent-workflow.md`: VERIFY 섹션에 backend-Vitest 전제 + M4 typecheck의 backend `typecheck` 스크립트 전제 명시.
- `STATUS.md` "Remaining work"에 "verify.sh 파라미터화 = 2nd 타깃 대기(YAGNI until then)" 항목.

### 리스크 / 롤백
- 없음(문서). 롤백: doc 커밋 revert.

---

## 정책 보강 (사용자 확정 정책) — 플레이북 반영 + Skill-sync 분리 (C4)

> **C4 해소**: 레포 밖 `~/.claude/skills/agent-workflow/SKILL.md`는 이 git repo 커밋에 못 들어간다. 따라서 **정책 본문은 in-repo 플레이북(`docs/agents/multi-agent-workflow.md`)에 넣어 배치 커밋에 포함**(각 배치 독립 green 유지)하고, **SKILL.md 반영은 커밋이 아닌 별도 "Skill-sync 절차"(맨 끝)** 로 분리한다. SKILL.md는 플레이북을 가리키는 얇은 포인터이므로 정책 원문은 플레이북이 정본.

### 플레이북(`docs/agents/multi-agent-workflow.md`)에 추가할 내용 (B8 커밋에 포함)

**1) 신규 섹션 "모델 배분(Model allocation)"**:

| 작업 유형 | 모델 |
|---|---|
| 설계(design) | **opus + gpt-5.5 교차**(adversarial co-design) |
| 간단 작업 | **haiku / sonnet** 서브에이전트 |
| 대량 분석 · 구현 | **codex = gpt-5.5** (5.6은 **ChatGPT 계정 미지원**; medium 이하만) |
| 최종 리뷰 | **Fable, 클린 컨텍스트**(구현 세션과 분리) |

**2) Non-negotiable rules에 신규 항목 추가**:
- **구현 ≠ 리뷰/검증 절대 분리**: 같은 에이전트·같은 세션이 구현과 리뷰/검증을 겸하지 않는다. **재리뷰도 매번 클린 컨텍스트**로 새로 스폰. (자기 코드 자기 승인 = 무효.)
- **같은 repo에 workspace-write codex 동시 2개 금지**: `codex-safe.sh`의 EXIT trap이 실패 시 `workflow-stash.sh`(git stash)를 호출 → 동일 repo 동시 2개면 **stash 경쟁**으로 부분작업 유실. 병렬 구현은 **워크트리 분리**(각자 prepare-worktree)로만.
- **codex/node 실행 전 `NODE_OPTIONS=` 클리어**: cmux preload가 `NODE_OPTIONS`를 오염(예: `--require` 계측) → codex/vitest 자식에 누수. 디스패치·검증 전 명시적으로 비운다. (verify.sh의 `env -i` allowlist가 `NODE_OPTIONS`를 통과시키므로 특히 주의 — 아래 선택 하드닝 참고.)

**3) Step 5/6 강화**: "REVIEW/VERIFY는 구현 pane과 **다른 에이전트**. 구현자가 자기 검증 금지. 재리뷰 시 새 클린 컨텍스트."

### (선택, 비필수) verify.sh NODE_OPTIONS 스크럽 하드닝
정책만으로 충분하나, defense-in-depth로 `verify.sh`의 env allowlist(371행)에서 `NODE_OPTIONS`를 **기본 제외**하고 `VERIFY_ENV_ALLOW`로만 재허용하도록 바꿀 수 있음. **범위 밖으로 두고**(기존 통과 스위트가 NODE_OPTIONS에 의존할 위험) 정책 문서로 우선 처리. 별도 이슈로 분리 권장.

### doc-sync (B8 커밋 — in-repo만)
- 정책 본문은 `docs/agents/multi-agent-workflow.md`(모델 배분·구현≠리뷰 분리·병렬 워크트리·NODE_OPTIONS)에 반영. `README.md`/`STATUS.md` method 섹션도 동일 커밋에 요약 반영. **SKILL.md는 여기 포함하지 않음.**

### Skill-sync 절차 (커밋 아님 — 모든 repo 배치 후 최종 단계)
> repo 밖 파일이라 배치/커밋 경계 밖. repo가 green으로 확정된 뒤, 플레이북 정본을 SKILL.md에 수동 전파한다.
- 대상: `/Users/hyojung/.claude/skills/agent-workflow/SKILL.md`.
- 전파 항목(플레이북에서 그대로): 모델 배분표, rule 추가(구현≠리뷰/검증 분리·재리뷰 클린 / 동일 repo 동시 codex 2개 금지 / `NODE_OPTIONS=` 클리어), Step 4(codex는 `codex-watchdog.sh`로 감쌈; stdout 첫토큰 의존 금지), Step 5/6(구현자 자기검증 금지), rule #3(verified = 정본 VERIFY.json 기준; VERIFY_ISSUE 아티팩트 미기록도 done 아님), Step 7(conductor가 정본 VERIFY.json 5+2조건 강제).
- 검증: SKILL.md는 스모크 대상이 아님 → 수동 리뷰. 플레이북과 문구 정합만 확인.
- **각 배치의 green 판정은 SKILL.md와 무관**(repo 스모크만으로 성립).

### 리스크 / 롤백
- 정책 문서 변경. 리스크 낮음. 롤백: 플레이북/README/STATUS는 B8 커밋 revert; SKILL.md는 수동 되돌림(별도).

---

## 구현 배치 분할 (각 배치 = 1 커밋; 코드+doc-sync 동봉)

> 순서 = codex fix order. 각 배치는 **repo 파일만** 담는 독립 커밋(관련 in-repo 문서 doc-sync 포함). **레포 밖 SKILL.md는 어느 배치 커밋에도 넣지 않는다**(C4) — 맨 끝 Skill-sync 절차로 별도 처리. 각 배치는 SKILL.md 없이 스모크만으로 green.

| # | 배치 | 변경 파일 (repo만) | 검증 |
|---|---|---|---|
| B1 | **M1 검증 소유권 이전** | `pr_draft.schema.json`(verify_result deprecated 유지 + if/then 삭제), `conductor-rebuild.sh`, `conductor-rebuild.smoke.sh`, playbook §5/§6/§7, README, STATUS | `bash scripts/__tests__/conductor-rebuild.smoke.sh` |
| B2 | **M4 typecheck fail-closed** | `verify.sh`, `verify.smoke.sh`, playbook typecheck절, STATUS | `bash scripts/__tests__/verify.smoke.sh` |
| B3 | **verify 아티팩트 fail-closed** | `verify.sh`, `verify.smoke.sh`, playbook L136, STATUS | `bash scripts/__tests__/verify.smoke.sh` |
| B4 | **M3 5.6 effort 핀** | `codex-safe.sh`, `codex-safe.smoke.sh`, README, STATUS | `bash scripts/__tests__/codex-safe.smoke.sh` |
| B5 | **M2 env-profile 대칭 + 실효 DB 어서션** | `prepare-worktree.sh`, `verify.sh`(`parse_db_url` 공유), `prepare-worktree.smoke.sh`, `verify.smoke.sh`, `.env.example`, playbook, README | `bash scripts/__tests__/prepare-worktree.smoke.sh` **그리고** `bash scripts/__tests__/verify.smoke.sh` (개별 호출 — C5) |
| B6 | **I6 워치독** | `scripts/codex-watchdog.sh`(신), `.review/schemas/run.schema.json`(신), `scripts/__tests__/codex-watchdog.smoke.sh`(신), playbook, README표, STATUS | `bash scripts/__tests__/codex-watchdog.smoke.sh` |
| B7 | **I7 backend-only 문서화** | `README.md`, `verify.sh`(주석), playbook, STATUS | `bash scripts/__tests__/run-all.sh`(무회귀 확인) |
| B8 | **플레이북 정책 보강** | `docs/agents/multi-agent-workflow.md`, README, STATUS | `bash scripts/__tests__/run-all.sh`(무회귀) |
| B9 | **M5 스모크 문구 동기화(최종 정합)** | `README.md`, `STATUS.md` | `bash scripts/__tests__/run-all.sh --list` 출력과 문구 대조 |
| — | **Skill-sync (커밋 아님)** | `~/.claude/skills/agent-workflow/SKILL.md` | 수동 리뷰(플레이북 정합) |

**M5를 마지막(B9)에 둔 이유**: B1/B4/B6이 스모크를 추가/개정 → 스모크 총개수·커버리지 문구가 바뀜. 각 배치가 doc-sync로 개별 갱신하되, **B9에서 최종 정합**(README:34의 stale "8 in total" 및 "codex-safe.sh lacks a direct one"[실제는 `codex-safe.smoke.sh` 존재] 정정, STATUS의 N/N pass를 `run-all.sh` 실측과 일치).

### 전체 검증 (각 배치 후 + 최종) — C5: brace expansion 금지, 개별 호출
```
cd /Users/hyojung/Desktop/2026/feedbackops-workflow
bash scripts/__tests__/run-all.sh          # 전체 TAP, live 레이어 self-skip
bash scripts/__tests__/run-all.sh --list   # 스모크 목록/개수 → M5 문구 대조
# 다중 스모크는 반드시 개별 호출 (C5: `{a,b}.smoke.sh`는 첫 파일만 실행됨):
bash scripts/__tests__/prepare-worktree.smoke.sh
bash scripts/__tests__/verify.smoke.sh
```
스키마: B1은 `verify_result`를 **삭제하지 않으므로** `fixtures/pr_draft.valid.json`은 **수정 불필요**(계속 valid). B6은 `.review/schemas/fixtures/run.valid.json` 신규 추가 + fixture 검증 스모크.

---

## Hard NOs 자가 체크리스트

- [x] **verify.sh가 CODEX pr_draft를 패치하지 않음** — M1은 "conductor가 정본 VERIFY.json을 읽는다"로만 소유권 이전. verify.sh는 pr_draft를 건드리지 않음. ✅
- [x] **stdout 첫토큰을 재시도 오라클로 쓰지 않음** — I6 liveness = 프로세스 생존 + 파일시스템 진행(`find -newer`). 4xx 분류는 재시도-여부용 별개 신호(liveness 아님)로 명시 분리. ✅
- [x] **GitNexus를 .mcp.json에 등록하지 않음** — 본 설계 범위 밖, 미수행. ✅
- [x] **verify.sh를 프레임워크로 일반화하지 않음** — I7은 문서화만. M2 어서션도 대상별 app-dotenv 프로브는 명시적으로 보류. ✅

---

## 10줄 요약

1. **M1(B1)**: `pr_draft.verify_result`를 **deprecated-optional로 유지**(삭제 안 함 → 기존 fixture/artifact 호환) + self-certify `if/then`만 제거; `conductor-rebuild`가 정본 `ISSUE-<n>-VERIFY.json`을 결정적 유도·로드해 **producer=VERIFIER/classifier=PASS/failed==0/passed>=1/exit==0 + issue·branch(fail-closed)·live-HEAD 일치** 조건을 강제. 스모크 전면 개정.
2. **M4(B2)**: `verify.sh --typecheck`의 pnpm exit를 별도 캡처 — 실행 실패(비-TS-에러 non-zero + 파싱 라인 0)면 **fail-closed FAIL**, 정상 TS 에러 경로는 baseline diff 유지.
3. **verify 아티팩트 fail-closed(B3)**: `VERIFY_ISSUE` 모드 green + 아티팩트 미기록 시 **exit 5**; **FAIL 테스트 + 아티팩트 실패는 cls_ec 유지**(PASS만 뒤집음). 스모크는 pnpm-stub filter-mode(‑‑classify-json 아님).
4. **M3(B4)**: `codex-safe.sh`가 gpt-5.6 + effort 공백이면 **medium 실제 핀**(config 상속 차단), high+ 밴 유지, "5.6 ChatGPT 계정 미지원" 주석.
5. **M2(B5, 좁게)**: `--env-profile`을 `.env`+`apps/backend/.env` **양쪽 대칭 기록**(stale backend override 차단) + `verify.sh`가 자식 주입 **실효 DATABASE_URL을 redacted 출력**. app-dotenv 프로브는 일반화 보류.
6. **I6(B6)**: 신규 `codex-watchdog.sh` — **프로세스+파일시스템 liveness**(stdout 첫토큰 금지) 기반 스톨 kill+재시도, **4xx는 fail-fast**, `run.schema.json`/RUN 마커 신설.
7. **I7(B7)**: verify.sh backend-Vitest 전용 계약을 **문서화만**(일반화 금지).
8. **정책(B8+Skill-sync)**: 정책 본문은 **in-repo 플레이북**에 반영(배치 커밋), 레포 밖 **SKILL.md는 커밋 아닌 Skill-sync 절차**로 분리(C4 — 각 배치 독립 green). 내용: 모델 배분표(설계=opus+5.5 / 간단=haiku·sonnet / 대량·구현=codex 5.5 / 최종=Fable 클린), 구현≠리뷰·검증 분리·재리뷰 클린, 동일 repo 동시 codex 2개 금지(stash 경쟁)·병렬 워크트리 분리, `NODE_OPTIONS=` 클리어.
9. **M5(B9)**: README 스모크 문구를 `run-all.sh --list` 실측과 정합(stale "8 in total" 및 "codex-safe 직접 스모크 없음"[실제 존재] 정정).
10. **Hard NOs 4개 전부 준수**; 각 배치=repo만 담는 1커밋+doc-sync(개별 스모크 호출 — C5), SKILL은 Skill-sync로 분리. **구현·대상 레포 수정은 본 문서 범위 밖.**
