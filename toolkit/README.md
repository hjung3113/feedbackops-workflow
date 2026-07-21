# feedbackops-workflow

분리된 워크트리와 독립적인 검증으로 Orca 또는 cmux × Claude × Codex 작업을 운영하는 **opt-in 멀티 에이전트 워크플로 툴킷**입니다. 병렬 작성자의 작업을 디스크 산출물로 추적하고, 에이전트의 “완료했습니다”가 아니라 현재 HEAD에 결속된 증거로 병합 여부를 판단합니다.

**Merge authority:** worker prose나 프로세스 종료, `RUN.json`은 완료 증거가 아닙니다. 병합 가능한 상태는 현재 HEAD에 맞는 canonical `REVIEW`와 `VERIFY` 산출물로 Release Captain이 판정합니다.

현재 릴리스는 [`STATUS.md`](STATUS.md)에서 확인하세요. 상태 문구와 Git 기록이 다르면 `git log`와 실제 schemas/scripts가 우선합니다. 이 저장소에서 개발하는 것과 타겟에 적용하는 것은 별도 경로이며, 이 툴킷 자체에 적용하려면 명시적인 `--self-test` dogfooding 승인이 필요합니다.

## 시작 전에: 적용 가능성과 선택

### 필요한 환경

- macOS stock Bash 3.2 호환 셸 (`declare -A`, `mapfile`, `${var,,}`를 사용하지 않음)
- Git, Codex CLI, 그리고 명시적으로 선택한 Orca 또는 cmux CLI
- 설치된 타겟의 Git checkout 또는 plain checkout
- 병렬 작업마다 별도 worktree와, FeedbackOps 스타일 DB 테스트라면 별도 일회성 DB

신선한 설치는 네 개의 managed leaf를 **self-contained 복사본**으로 배포합니다. 설치는 원본 toolkit을 가리키는 절대 symlink를 만들지 않으며, 타겟 저장소와 함께 커밋하거나 다른 머신으로 옮길 수 있습니다.

### 현재 호환성 경계

| 영역 | 현재 계약 |
|---|---|
| dispatch, watchdog, artifact lifecycle | 명시적으로 선택한 Orca 또는 cmux + Codex가 있는 Git 저장소에서 재사용 가능 |
| `prepare-worktree.sh` | pnpm 및 root/`apps/backend` 환경 구조 |
| `tier-probe.sh` | TypeScript/TSX exported-contract 휴리스틱 |
| `target-verify.sh <profile> <issue>` | target-neutral required-group verifier |
| `verify.sh` | 명시적 FeedbackOps pnpm/Vitest/Postgres 호환 어댑터 |
| `prepare-verify-db.sh` | 이슈별 local PostgreSQL DB |
| branch/cluster helpers | `feature/*`, pane-label, integration-branch 관례 |

따라서 새 저장소에 적용하기 전에 [적용 가이드의 compatibility interview](.claude/skills/agent-workflow/references/adoption.md)를 실행하세요. 두 번째 실제 타겟이 생기기 전까지 worktree 준비·risk probe·verification·DB 생성은 일반화하지 않습니다. 의도된 분리는 안정적인 coordination core와 타겟별 install 명령, env 경로, branch 패턴, tier trigger, verification 명령, service isolation을 담는 작은 adapter입니다.

### 설치할까요, 업그레이드할까요?

최신 toolkit checkout/export에서 타겟에 처음 적용하면 **install**입니다.

```bash
scripts/install-into.sh ../my-project
```

기존의 완전한 copy 설치 또는 인식된 current/legacy absolute-link 설치를 바꾸면 **upgrade**입니다.

```bash
scripts/install-into.sh ../my-project --upgrade
```

설치/업그레이드는 `.agent-workflow`, `.agent-workflow/docs`, `.claude`, `.claude/skills`, `.review`, `.review/agent-workflow-install-backups`가 타겟 안의 실제 디렉터리일 때만 진행합니다. 교체 범위는 정확히 다음 네 leaf입니다.

```text
.agent-workflow/scripts
.agent-workflow/schemas
.agent-workflow/docs/agents
.claude/skills/agent-workflow
```

Fresh install은 기존 managed leaf가 있으면 덮어쓰지 않고 `--upgrade`를 안내합니다. Upgrade는 source를 target 내부 staging에 먼저 복사·검증하고 기존 leaf를 `.review/agent-workflow-install-backups/<id>/`에 보존한 뒤 transaction으로 교체합니다. partial/mixed/식별 불가능한 layout, 상관없는 symlink, symlink인 managed parent는 fail closed합니다. rollback 이동까지 거부되면 exit `70`과 보존된 backup 경로를 출력합니다. 기존 `.review` 증거와 그 밖의 타겟 파일은 삭제하지 않습니다. 제거된 `--mode`, `--force`, `--migrate-legacy`는 작업을 수행하지 않고 `--upgrade` 안내와 함께 거부됩니다.

## 5분 안에 첫 controlled run

아래는 호환되는 타겟 `../my-project`에 issue `123`을 적용하는 최소 운영 경로입니다. 상세 admission과 liveness 규칙은 [운영 플레이북](docs/agents/multi-agent-workflow.md)을 따릅니다.

### 1. 제품을 검증하고 설치

```bash
git clone https://github.com/hjung3113/feedbackops-workflow.git
cd feedbackops-workflow/toolkit
NODE_OPTIONS= bash scripts/__tests__/run-all.sh
scripts/install-into.sh ../my-project
```

설치 후 타겟 구조는 다음과 같습니다.

```text
my-project/
├── .agent-workflow/
│   ├── scripts/
│   ├── schemas/
│   └── docs/agents/
├── .claude/skills/agent-workflow/
└── .review/
```

설치된 `.env.example`은 환경 계약 예시일 뿐입니다. 실제 계정·DB 정보는 별도 프로필에 넣고, 공유 `.env`는 명시적으로 `--allow-shared-env`를 주지 않는 한 사용하지 않습니다.

### 2. 격리된 worktree 준비

```bash
scripts/prepare-worktree.sh ../wt-123 --env-profile ../env/issue-123.env
```

### 3. transport와 canonical contract를 준비하고 구현자를 dispatch

Standard/Full Cluster 최초 write 전에는 CONDUCTOR가 `schemas/round_state.schema.json` 전체를 만족하는 `ISSUE-123-ROUND-STATE.json`을 만들고 issue, tier, revision, 실제 worktree, live HEAD, base freshness에 결속해야 합니다. Standard는 별도 mini-state를 만들지 않고 `pr_draft`와 `review` pointer를 유지합니다. Trivial 최초 write만 `--tier trivial`과 기존 `pr_draft`-only 계약을 사용합니다.

CONDUCTOR는 dispatch 전에 `.review/ISSUE-123-CONTEXT.md`에 원자료를 정제 없이 모으고, 필요한 사용자 역질문을 한 번(최대 4문항)으로 끝낸 뒤, `.review/ISSUE-123-PROMPT.md`를 압축합니다. Standard/Full과 canonical redispatch는 prompt 안의 delimited JSON AC block이 ROUND-STATE `acceptance.criteria[]`의 ID·statement·순서를 정확히 복사하지 않으면 launch 전에 거부됩니다. 두 Markdown 파일은 uncommitted/non-archival scratch이며, `model-alloc.json`의 `prompt_authoring.target_tokens`는 길이 안내·telemetry일 뿐 launch 거부 조건이 아닙니다.

CLI `--orchestrator`가 `AGENT_WORKFLOW_ORCHESTRATOR`보다 우선하고, 환경 변수가 target-local `.agent-workflow/workflow-config.json`보다 우선합니다. 어느 곳에도 선택이 없으면 fail closed하며 자동 기본값이나 fallback은 없습니다. 설치된 [config example](docs/agents/workflow-config.example.json)은 오직 `orchestrator`만 허용합니다.

```bash
cp docs/agents/workflow-config.example.json ../wt-123/.agent-workflow/workflow-config.json

NODE_OPTIONS= scripts/agent-workflow.sh dispatch \
  --orchestrator cmux \
  --issue 123 \
  --worktree ../wt-123 \
  --tier standard \
  --prompt-file ../wt-123/.review/ISSUE-123-PROMPT.md \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 1 \
  --name issue-123-impl \
  --allocate \
  --allocator-role implementation
```

`scripts/agent-workflow.sh capabilities --worktree ../wt-123`는 두 adapter의 availability와 필요한 capability 근거를 JSON으로 보여 줍니다. cmux는 admission 전에 side-effect 없는 version/help probe로 최소 `0.64.0`과 실제 `workspace create --cwd --command` 계약을 증명하고, Orca는 launch에 쓰는 `--worktree --title --command --json` 및 read-only list 인자를 모두 증명합니다. probe 실패는 marker를 소비하지 않고 `required_capability_missing`으로 종료합니다. 모든 write-capable Codex는 `agent-workflow.sh` → shared dispatch core → selected adapter → launch runner → `codex-watchdog.sh` → `codex-safe.sh` 경로를 사용합니다. `inspect --receipt <file>`은 adapter의 read-only list를 통해 external handle을 조회해 `live`, `stale`, `handle_unverifiable`로 정규화하고 runner identity도 확인합니다. Orca launch와 inspect는 같은 normalizer로 `terminal_id`, `terminalId`, `handle`, `id` 응답을 해석하므로 발급된 handle 필드가 list에서 바뀌어도 동일 identity를 유지합니다. receipt와 terminal/workspace 상태는 lifecycle 진단일 뿐 완료 authority가 아닙니다. `codex exec` 직접 실행이나 transport command 수동 조립은 지원하지 않습니다. 기존 `cmux-dispatch.sh`는 cmux를 명시 선택하는 호환 facade입니다.

Shared core는 admission 전에 caller `PATH`의 `codex`를 canonical absolute executable로 확정해 runner/watchdog/safe wrapper 전체에 고정합니다. 제어된 host launch 환경만 `AGENT_WORKFLOW_CODEX_BIN`으로 absolute executable을 명시할 수 있으며, target config에는 이 권한이 없고 상대·누락·비실행 경로는 admission 전에 거부됩니다. cmux receipt도 display name을 identity로 쓰지 않고 create JSON에서 증명된 단 하나의 `id`/`workspace_id`/`workspaceId`/`ref`만 기록합니다. Create와 inspect는 같은 내부 handle module을 사용하므로 허용 키나 탐색 방식이 갈라질 수 없고, 같은 이름의 workspace가 있어도 inspect는 생성된 고유 handle만 조회합니다.

둘 이상의 write seat를 제안할 때는 먼저 canonical `ISSUE-123-EXECUTION-PLAN.json`을 만들고 `scripts/parallel-plan.sh decide --plan <plan> --target <repo>`를 실행합니다. 정확하고 배타적인 target-relative write set, dependency 없음, shared generated/lock/migration surface 비접촉, per-seat DB/env 격리, rate-limit budget이 모두 증명된 pair만 병렬입니다. 나머지는 reason code와 함께 직렬화됩니다. 각 dispatch는 `--execution-plan <plan> --seat <id>`로 plan binding을 소비합니다.

좌석 작업 후에는 clean candidate에서 선언된 순서대로 `scripts/candidate-integrate.sh`를 실행하고, candidate HEAD에 새 REVIEW/VERIFY/PR-DRAFT/completion/seat outcomes 전체가 모인 뒤 `scripts/candidate-close.sh evaluate`를 실행합니다. Integration step은 plan 순서와 정확히 일치하는 unique seat 목록이어야 하며, 각 evidence artifact 자체가 issue/round/revision/candidate HEAD/attempt/generation time을 직접 바인딩합니다. REVIEW는 `final`, PR-DRAFT는 `active` lifecycle만 현재 closure evidence입니다. Wrapper attempt ID만 바꾼 재사용, draft/superseded artifact, 비정상 RFC3339 timestamp, Worker HEAD의 green, mixed retry attempt, 이전 candidate HEAD, active blocker, dirty/conflicted candidate는 closure가 아닙니다. `candidate-close.sh inspect`는 closure 뒤의 한 커밋도 즉시 stale로 판정합니다. 기존 단일 write는 유효한 one-seat sequential plan이며, legacy no-plan 경로도 보수적인 직렬 실행으로 유지됩니다.

설치하면 프로젝트 소유 `.agent-workflow/model-alloc.json`도 함께 생성됩니다. `scripts/model-alloc.sh --role implementation`은 실행 시 같은 schema로 설정을 검증하고, 증거가 없으면 안전한 기본 배치만 출력하며, canonical evidence의 연속된 findings round·작업량·계약 터치·재리뷰에 따라 배치 근거를 JSON으로 기록합니다. 리뷰 기본 우위는 source/release가 기록된 LiveBench의 `static_coding + reasoning` 단순 합으로 결정되고, 프로젝트가 명시적으로 완화할 때만 경고합니다. `agent-workflow.sh dispatch --orchestrator <cmux|orca> --allocate --allocator-role implementation`은 Codex 구현 모델만 자동 전달합니다. Opus/Fable/Claude 역할은 Codex로 전달하지 않으며, 업그레이드는 사용자 설정 파일을 보존합니다.

### 4. 리뷰 전 계약 gate

```bash
scripts/ac-check.sh \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 3 \
  --tests ../wt-123/.review/ISSUE-123-DISCOVERED-TESTS.txt

scripts/completion-check.sh \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 3
```

`ac-check.sh`는 schema/base freshness와 revision을 확인하고 중복·미발견 AC-ID를 거부합니다. `completion-check.sh`는 worker 주장이나 `RUN.json`을 보지 않고 live `base_sha..HEAD` diff, target-native test discovery, `acceptance.expected_test_count`, compile consumers, full typecheck, trigger된 review obligation을 계약과 대조합니다. 불일치는 JSON과 non-zero exit로 리뷰를 hard-stop합니다. discovery 명령은 target profile 책임이며 core는 Vitest를 가정하지 않습니다.

실패한 구현 라운드를 다시 보낼 때는 먼저 canonical ROUND-STATE의 `round_control.failures[]`에 primary origin, owner/action, 실패 AC와 HEAD-bound 증거를 기록한 뒤 다음 gate를 사용합니다.

```bash
scripts/redispatch-check.sh \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 4
```

### 5. 호스트 VERIFIER로 독립 검증

구현자와 REVIEWER/VERIFIER는 서로 다른 세션이어야 합니다. 구현 sandbox는 local DB나 네트워크에 접근할 수 없으므로 DB 검증은 호스트의 VERIFIER가 수행합니다.

```bash
eval "$(scripts/prepare-verify-db.sh \
  --issue 123 \
  --target ../wt-123 \
  --base-url "$PGADMIN_URL" | tail -1)"

cd ../wt-123
VERIFY_ISSUE=123 \
VERIFY_DATABASE_URL="$VERIFY_DATABASE_URL" \
VERIFY_CLEAN_COMMAND="./scripts/verify-clean-state.sh" \
  .agent-workflow/scripts/verify.sh
```

새 타겟은 `schemas/target-profile.schema.json`을 만족하는 target-owned profile 하나에 runtime/setup/environment와 required verification groups를 선언하고 `target-verify.sh <profile> <issue>`를 사용합니다. 명령은 argv 배열과 선택적 repository-relative cwd/env allowlist뿐이며 shell string/eval은 허용하지 않습니다. Generic canonical VERIFY가 PASS이려면 모든 required group command의 `exit_code`가 0이고, profile이 test-count extractor를 선언해 evidence에 `test_count`가 있으면 그 값이 정수이면서 0보다 커야 합니다. schema와 semantic validator가 이 조건을 각각 검사합니다. extractor가 출력과 일치하지 않으면 `test_count:null`인 canonical FAIL 증거를 게시하며, 이를 0개 실행이나 PASS로 해석하지 않습니다. 기존 same-HEAD artifact는 schema와 aggregate 의미 검증을 모두 통과해야 append되므로 손상된 red latch를 새 PASS로 덮을 수 없습니다. 명령 출력의 `output_bytes`는 UTF-8 byte 상한이고 `output_truncated`는 실제 byte 초과 여부입니다. VERIFY schema는 FeedbackOps legacy의 `db_target + clean_state` 또는 generic의 `target_profile + groups` 중 정확히 하나를 요구하며, 증거 없는 empty PASS를 거부합니다. 실제 `node --test`의 `ℹ tests N` 형식을 포함한 Node/Go/Python 예시는 `schemas/profiles/`에 있습니다.

기존 `verify.sh`는 FeedbackOps 호환 어댑터입니다. 인자 없는 실행은 backend 전체 모듈을 검증하며 `VERIFY_DATABASE_URL`과 target-owned `VERIFY_CLEAN_COMMAND`를 요구합니다. Generic target은 PostgreSQL, backend, Vitest, Node 가정을 상속하지 않습니다.

REVIEWER는 `agent-workflow.sh dispatch --orchestrator <cmux|orca> --produce-review`로 실행합니다. Codex를 실제 read-only sandbox에서 실행하고 host-side에서 JSON schema, producer, issue, live HEAD를 검증한 뒤 canonical `.review/ISSUE-123-REVIEW.json`을 원자 게시합니다. legacy `--read-only`는 liveness-only이며 filesystem sandbox를 read-only로 만들지 않습니다.

## Mental model

```text
Issue / acceptance contract
        ↓
isolated worktree + env
        ↓
agent-workflow → selected Orca/cmux adapter → watchdog → safe Codex
        ↓
completion + AC gate → independent REVIEWER
        ↓
host VERIFIER → canonical VERIFY
        ↓
Release Captain merge decision
```

- **CONDUCTOR**는 contract와 `.review/*.json`을 관리하고 `conductor-rebuild.sh .review`로 디스크에서 상태를 복원합니다.
- **Implementer**는 지정된 worktree에서만 작성합니다.
- **REVIEWER**는 구현자와 독립적으로 patch와 checklist를 판정합니다.
- **VERIFIER**는 host-side DB/test 실행과 현재 HEAD-bound VERIFY를 소유합니다.

## Trust boundary

- write dispatch는 `agent-workflow.sh`, shared dispatch core, `codex-safe.sh`를 우회하지 않습니다.
- 한 checkout에서 두 workspace-write 구현자를 동시에 실행하지 않습니다. 병렬 chunk는 별도 worktree를 사용합니다.
- 원격·staging·production DB를 검증하지 않습니다. local, low-privilege, issue-specific DB만 사용합니다.
- sandbox 구현과 host-side REVIEW/VERIFY를 분리합니다. worker의 테스트 주장과 pane prose는 참고일 뿐입니다.
- `RUN.json`의 `status:"exited"`는 프로세스 종료이지 작업 완료가 아닙니다. `RUN/BLOCKER`는 liveness/중단 기록이며 merge authority가 아닙니다.
- 파괴적 자동 rebase를 하지 않습니다. `rebase-inflight.sh`는 dirty worktree를 건너뛰고 conflict를 abort합니다.

## Capability와 canonical artifacts

| 목적 | 주요 진입점 | 상세 권위 |
|---|---|---|
| 설치·업그레이드 | `install-into.sh` | [적용 가이드](.claude/skills/agent-workflow/references/adoption.md) |
| worktree·env 준비 | `prepare-worktree.sh` | [운영 플레이북](docs/agents/multi-agent-workflow.md#worktree-prep) |
| visible dispatch·liveness | `agent-workflow.sh`, `dispatch-core.sh`, transport adapters, `codex-watchdog.sh`, `codex-safe.sh` | [디스패치 오퍼레이터 규칙](docs/agents/multi-agent-workflow.md#dispatch-liveness-operator-rules) |
| 계약·완료 gate | `prompt-ac-check.sh`, `ac-check.sh`, `completion-check.sh`, `redispatch-check.sh` | [Artifact lifecycle](docs/agents/artifact-lifecycle.md) |
| 범용 검증 | `target-verify.sh`, target profile | [VERIFIER protocol](docs/agents/multi-agent-workflow.md#verifier-protocol) |
| FeedbackOps 호환 검증 | `prepare-verify-db.sh`, `verify.sh` | [VERIFIER protocol](docs/agents/multi-agent-workflow.md#verifier-protocol) |
| 상태 복원·보존 | `conductor-rebuild.sh`, `artifact-fresh.sh`, `review-archive.sh` | [Artifact lifecycle](docs/agents/artifact-lifecycle.md) |

`schemas/`의 JSON Schema가 산출물 계약의 정본입니다.

재리뷰는 `scripts/review-capsule.sh`로 현재 ROUND-STATE, 전체 구현 PROMPT, final REVIEW, PR-DRAFT와 live HEAD를 묶어 `.review/ISSUE-N-REVIEW-CAPSULE.{json,md}`를 생성합니다. 입력별 SHA-256과 aggregate digest가 있어 AC 블록 밖 prompt 변조도 stale 처리됩니다. 금지사항은 자연어 regex로 복원하지 않고 canonical ROUND-STATE `contract.prohibitions[]`를 그대로 렌더합니다. `prompt_authoring.target_tokens`는 Markdown 전체 한도이며 배열은 섹션별 누적 budget을 공유하고, 누락 수와 truncation marker를 남깁니다. AC와 prohibitions는 무절단입니다. PR-DRAFT는 ROUND의 base와 실제 worktree를 함께 가리켜야 합니다. 생성물은 reviewer guidance일 뿐 canonical authority가 아닙니다. `agent-workflow.sh dispatch --orchestrator <cmux|orca> --produce-review --re-review`는 canonical capsule JSON만 허용하며 `--prompt-file` 생략 시 canonical capsule Markdown을 자동 선택하고 다른 prompt는 거부합니다.

| 산출물 | 의미 |
|---|---|
| `ISSUE-N-ROUND-STATE.json` | CONDUCTOR가 dispatch 0부터 유지하는 canonical contract와 revision-pinned AC manifest |
| `ISSUE-N-CONTEXT.md`, `ISSUE-N-PROMPT.md` | uncommitted/non-archival CONDUCTOR prompt-authoring scratch; PROMPT에는 exact AC block |
| `ISSUE-N-PR-DRAFT.json` | CODEX 구현 handoff; 자체 테스트 주장은 참고일 뿐 |
| `ISSUE-N-REVIEW.json` | 독립 REVIEWER의 판정과 patch instruction |
| `ISSUE-N-VERIFY.json` | 현재 HEAD에 대한 VERIFIER의 canonical 검증 증거 |
| `ISSUE-N-RUN.json` | watchdog 실행 상태; 병합 증거 아님 |
| `ISSUE-N-BLOCKER.json` | 구조화된 중단 사유와 필요한 결정 |
| `HEARTBEAT-*.json` | liveness 증거; correctness 증거 아님 |

## 더 읽을 문서

- [운영 플레이북](docs/agents/multi-agent-workflow.md) — risk tier, role, dispatch, sandbox, gate, verifier의 상세 절차
- [산출물 lifecycle](docs/agents/artifact-lifecycle.md) — freshness, supersession, archive, validation
- [적용 가이드](.claude/skills/agent-workflow/references/adoption.md) — 새 저장소 compatibility interview와 target adapter 경계
- [문제 보고 계약](docs/agents/issue-reporting.md) — 재현·redaction·upstream issue 보고
- [CONDUCTOR 페르소나](docs/agents/conductor-persona.md) / [VISUAL-REVIEWER 페르소나](docs/agents/visual-reviewer-persona.md)
- [실전 trial 기록](docs/agents/workflow-trial-log.md) / [현재 상태와 roadmap](STATUS.md)
- [프로젝트용 agent-workflow skill](.claude/skills/agent-workflow/SKILL.md)

전체 스크립트는 `ls scripts/`로, smoke inventory는 `bash scripts/__tests__/run-all.sh --list`로 확인합니다. `--list`는 read-only 조회이므로 임시 저장소를 할당하지 않고 답합니다. smoke가 실패하면 runner가 해당 smoke의 진단을 `--- begin <name> diagnostic ---` 블록으로 출력하고 보존된 캡처 경로를 `diagnostic retained: <path>`로 알려줍니다. 자격 증명을 출력할 수 있는 suite는 `--redact-values-file <path>`를 넘겨야 하며, 파일의 비어 있지 않은 각 줄을 양쪽 진단에서 문자 그대로 `[REDACTED]`로 바꿉니다. runner가 임의의 비밀을 추론하지 않으므로 값 파일의 완전성은 호출자 책임이고, raw 실패 캡처는 sanitized 사본 생성 뒤 보존하지 않습니다. runner 자체의 계약 테스트는 live inventory에 들어가지 않도록 `*.smoke.sh`가 아닌 `scripts/__tests__/run-all-contract.test.sh`이며 직접 실행합니다. 자세한 규칙은 [운영 플레이북](docs/agents/multi-agent-workflow.md)의 Smoke Suite Diagnostics를 따릅니다. 이 source repository의 release gate는 product containment, source/portable-install Markdown link, installation non-leakage, CI routing을 별도로 소유하며 타겟에 설치되지 않습니다.

## 기여

1. macOS Bash 3.2 문법을 유지합니다.
2. 변경한 스크립트에는 해당 smoke를 추가·실행합니다.
3. 스크립트·schema·workflow contract를 바꾸면 playbook, README, STATUS와 installer/skill reference를 같은 커밋에서 동기화합니다.
4. `run-all.sh`를 바꾸면 `bash scripts/__tests__/run-all-contract.test.sh`를 함께 실행합니다.
5. 최종으로 `NODE_OPTIONS= bash scripts/__tests__/run-all.sh`를 실행합니다.

현재 release와 남은 작업은 [STATUS.md](STATUS.md)와 GitHub Issues가 정본입니다.

## Local model/task telemetry

Telemetry는 opt-in이며 네트워크를 사용하지 않습니다. `scripts/telemetry.sh collect`는 target-local salt, canonical ROUND-STATE/RUN과 선택적 REVIEW/VERIFY/BLOCKER를 검증합니다. Parallel candidate의 `ISSUE-N-CLOSURE.json`을 주면 canonical `ISSUE-N-INTEGRATION.json`과 `ISSUE-N-CANDIDATE-EVIDENCE.json`도 반드시 주어야 하며, 세 source의 realpath·공유 #14 schema·identity·semantic과 실제 byte digest를 함께 확인합니다. Closure 시각은 integration/evidence 생성 및 admitted RUN 종료보다 빠를 수 없고, candidate closure와 telemetry가 공유하는 strict calendar parser가 February 30 같은 regex-shaped impossible RFC3339 날짜를 거부합니다. 저장 sample의 closure source/hash/value와 candidate_closure/integration/candidate_evidence artifact path·digest도 하나의 의미 검증을 통과해야 합니다. Green은 closure의 source digest, issue/round/revision/HEAD가 모두 일치하고 `status:"closed"`일 때만 기록되며 REVIEW/VERIFY pass만으로는 green이 아닙니다. Salt/store의 기존 경로 구성요소와 생성된 store는 realpath containment를 확인하므로 target 내부를 가리키는 benign symlink는 허용하지만 외부 탈출은 거부합니다. Usage는 `observed`, `estimated`, `unavailable` 중 하나이며 unavailable은 null로 남아 0원으로 계산되지 않습니다. prompt/output/env/file body, raw provider request ID, 사용자 이름과 절대 경로는 저장하지 않습니다.

`scripts/telemetry.sh report --worktree <target> --from <ISO> --to <ISO> --minimum-samples <N> --minimum-completeness <0..1>`은 JSON을 stdout으로 내보냅니다. Report는 closure 결합을 다시 검증하고 동일 project pseudonym/issue/round/revision에서 attempt 1부터 빠짐없이 이어지고 직전 sample을 가리키는 retry만 complete로 판정합니다. 각 attempt의 모델 allocation을 노출하며 mixed-model chain은 첫 모델 cohort에 귀속하지 않고 `mixed-model:<chain-id>`로 억제합니다. observed/estimated cost를 분리하고 no-green/incomplete/unavailable을 그대로 표시하며, 명시한 attempt 수·usage completeness 기준 미만 cohort도 억제합니다. 이 보고서는 advisory evidence이며 `model-alloc.json`이나 tier policy를 절대 수정하지 않습니다. 보존과 export는 target 운영자가 정하고 toolkit은 background 수집이나 upload를 하지 않습니다. 개별 삭제는 exact ID에 `telemetry.sh delete ... --sample-id <64hex> --confirm DELETE`를 명시해야 하며, 전체 디렉터리 자동 정리는 제공하지 않습니다. 보고서 예시는 `schemas/fixtures/telemetry_report.valid.json`입니다.
