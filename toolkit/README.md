# feedbackops-workflow

분리된 워크트리와 독립적인 검증으로 Orca 또는 cmux × Codex·Claude Code·OpenCode 작업을 운영하는 **opt-in 멀티 에이전트 워크플로 툴킷**입니다. 병렬 작성자의 작업을 디스크 산출물로 추적하고, 에이전트의 “완료했습니다”가 아니라 현재 HEAD에 결속된 증거로 병합 여부를 판단합니다.

**Merge authority:** worker prose나 프로세스 종료, `RUN.json`은 완료 증거가 아닙니다. 병합 가능한 상태는 현재 HEAD에 맞는 canonical `REVIEW`와 `VERIFY` 산출물로 Release Captain이 판정합니다.

현재 릴리스는 [`STATUS.md`](STATUS.md)에서 확인하세요. 상태 문구와 Git 기록이 다르면 `git log`와 실제 schemas/scripts가 우선합니다. 이 저장소에서 개발하는 것과 타겟에 적용하는 것은 별도 경로이며, 이 툴킷 자체에 적용하려면 명시적인 `--self-test` dogfooding 승인이 필요합니다.

## 시작 전에: 적용 가능성과 선택

### 필요한 환경

- macOS stock Bash 3.2 호환 셸 (`declare -A`, `mapfile`, `${var,,}`를 사용하지 않음)
- Git, 명시적으로 선택·capability-probe 된 Codex·Claude Code·OpenCode 중 하나, 그리고 명시적으로 선택한 Orca 또는 cmux CLI
- 설치된 타겟의 Git checkout 또는 plain checkout
- 병렬 작업마다 별도 worktree와, FeedbackOps 스타일 DB 테스트라면 별도 일회성 DB

신선한 설치는 네 개의 managed leaf를 **self-contained 복사본**으로 배포합니다. 설치는 원본 toolkit을 가리키는 절대 symlink를 만들지 않으며, 타겟 저장소와 함께 커밋하거나 다른 머신으로 옮길 수 있습니다.

### 현재 호환성 경계

| 영역 | 현재 계약 |
|---|---|
| dispatch, watchdog, artifact lifecycle | distribution profile·runtime·role·transport를 독립 선택하는 Git 저장소에서 재사용 가능 |
| `prepare-worktree.sh` | pnpm 및 root/`apps/backend` 환경 구조 |
| `tier-probe.sh` | TypeScript/TSX exported-contract 휴리스틱 |
| `target-verify.sh <profile> <issue>` | target-neutral required-group verifier |
| `verify.sh` | 명시적 FeedbackOps pnpm/Vitest/Postgres 호환 어댑터 |
| `prepare-verify-db.sh` | 이슈별 local PostgreSQL DB |
| branch/cluster helpers | `feature/*`, pane-label, integration-branch 관례 |

따라서 새 저장소에 적용하기 전에 [적용 가이드의 compatibility interview](.claude/skills/agent-workflow/references/adoption.md)를 실행하세요. 두 번째 실제 타겟이 생기기 전까지 worktree 준비·risk probe·verification·DB 생성은 일반화하지 않습니다. 의도된 분리는 안정적인 coordination core와 타겟별 install 명령, env 경로, branch 패턴, tier trigger, verification 명령, service isolation을 담는 작은 adapter입니다.

### 설치할까요, 업그레이드할까요?

기존 FeedbackOps 호환 타겟에는 명시적으로 `feedbackops` profile을, 관련 없는 저장소에는 `generic` profile을 선택합니다. generic은 FeedbackOps의 tracker, labels, domain, Vitest, PostgreSQL, pnpm layout 또는 maintainer 규칙을 설치하지 않습니다.

최신 toolkit checkout/export에서 타겟에 처음 적용하면 **install**입니다.

```bash
scripts/install-into.sh ../my-project --profile generic
```

기존의 완전한 copy 설치 또는 인식된 current/legacy absolute-link 설치를 바꾸면 **upgrade**입니다.

```bash
scripts/install-into.sh ../feedbackops-target --profile feedbackops --upgrade
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
scripts/install-into.sh ../my-project --profile generic
```

`scripts/__tests__/`는 source checkout에서만 실행하는 maintainer 검증 자산입니다. 설치된 PRODUCT_HOME에는 복사되지 않으며, 타겟에서는 workflow 명령과 target-owned verification만 실행합니다.

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

`.agent-workflow`는 설치한 checkout에 남는 **PRODUCT_HOME**입니다. Git이 무시하는 이 디렉터리는 새 linked worktree에 복사되지 않으므로, worktree 안의 상대 `scripts/...` 또는 `.agent-workflow/...`를 호출하지 마세요. 설치 checkout에서 절대 경로를 한 번 고정하고, 모든 workflow 명령은 그 PRODUCT_HOME에서 실행하며 `--worktree`만 새 checkout을 가리킵니다. `workflow-config.json`과 `model-alloc.json`도 PRODUCT_HOME 소유이고, `.review`와 prompt 파일의 상대경로 기준은 계속 `--worktree`입니다.

```bash
PRODUCT_HOME="$(cd ../my-project/.agent-workflow && pwd -P)"
cp "$PRODUCT_HOME/docs/agents/workflow-config.example.json" "$PRODUCT_HOME/workflow-config.json"
```

### 2. 격리된 worktree 준비

```bash
git -C ../my-project worktree add -b issue-123 ../wt-123 HEAD
mkdir -p ../wt-123/.review
```

의존성·환경 파일·서비스 격리는 target-owned profile과 해당 저장소의 운영 절차로 준비합니다. generic install에는 특정 package manager, DB 또는 env layout을 가정하는 worktree 준비 명령이 없습니다.

### 3. transport와 canonical contract를 준비하고 구현자를 dispatch

Standard/Full Cluster 최초 write 전에는 CONDUCTOR가 `schemas/round_state.schema.json` 전체를 만족하는 `ISSUE-123-ROUND-STATE.json`을 만들고 issue, tier, revision, 실제 worktree, live HEAD, base freshness에 결속해야 합니다. Standard는 별도 mini-state를 만들지 않고 `pr_draft`와 `review` pointer를 유지합니다. Trivial 최초 write만 `--tier trivial`과 기존 `pr_draft`-only 계약을 사용합니다.

CONDUCTOR는 dispatch 전에 `.review/ISSUE-123-CONTEXT.md`에 원자료를 정제 없이 모으고, 필요한 사용자 역질문을 한 번(최대 4문항)으로 끝낸 뒤, `.review/ISSUE-123-PROMPT.md`를 압축합니다. Standard/Full과 canonical redispatch는 prompt 안의 delimited JSON AC block이 ROUND-STATE `acceptance.criteria[]`의 ID·statement·순서를 정확히 복사하지 않으면 launch 전에 거부됩니다. 두 Markdown 파일은 uncommitted/non-archival scratch이며, `model-alloc.json`의 `prompt_authoring.target_tokens`는 길이 안내·telemetry일 뿐 launch 거부 조건이 아닙니다.

`orchestrator`, `runtime`, `role`은 직교하는 축입니다. 각각 CLI가 환경 변수보다, 환경 변수가 PRODUCT_HOME `workflow-config.json`보다 우선합니다. runtime/role을 생략하면 legacy compatibility 값(Codex/implementation)만 사용하며, 새 설치는 세 축을 명시하는 것이 운영 계약입니다. 선택한 runtime 또는 transport의 capability probe가 실패하면 admission 전 machine-readable reason으로 거부하며 다른 runtime/transport로 바꾸지 않습니다.

산출물을 생성하는 좌석은 프롬프트에 스키마에서 파생한 출력 계약을 넣습니다. `"$PRODUCT_HOME/scripts/output-contract.sh" render --role reviewer` 또는 `--role implementation`으로 블록을 만들고, `check`로 설치된 스키마와의 일치를 검증하세요. BLOCKER는 스키마 검증을 통과한 fresh 파일만 디스패치 liveness 증거가 됩니다.

```bash
NODE_OPTIONS= "$PRODUCT_HOME/scripts/agent-workflow.sh" dispatch \
  --orchestrator cmux \
  --runtime codex \
  --role implementation \
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

같은 worktree와 canonical 산출물을 유지한 채 transport만 Orca로 바꾸려면 일회성 실행에는 `--orchestrator orca`를 사용합니다. 반복 실행은 환경 변수나 타겟 설정으로 고정할 수 있습니다.

```bash
# 이 호출만 Orca 사용
NODE_OPTIONS= "$PRODUCT_HOME/scripts/agent-workflow.sh" dispatch \
  --orchestrator orca \
  --runtime claude \
  --role implementation \
  --issue 123 \
  --worktree ../wt-123 \
  --tier standard \
  --prompt-file ../wt-123/.review/ISSUE-123-PROMPT.md \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 1 \
  --name issue-123-impl

# 현재 셸의 기본 transport
export AGENT_WORKFLOW_ORCHESTRATOR=orca

# PRODUCT_HOME의 기본 transport (환경 변수가 없을 때 적용)
printf '%s\n' '{"orchestrator":"orca","runtime":"opencode","role":"implementation"}' \
  > "$PRODUCT_HOME/workflow-config.json"
```

설정값은 transport `orca|cmux`, runtime `codex|claude|opencode`, role `conductor|architect|implementation|reviewer|verifier|visual|release`만 허용하며, 위 우선순위에 따라 언제든 명시적으로 교체할 수 있습니다. `capabilities`로 선택 전에 두 adapter와 세 runtime을 함께 점검하고, dispatch receipt는 실제 선택된 transport·runtime·role을 기록합니다.

`"$PRODUCT_HOME/scripts/agent-workflow.sh" capabilities --worktree ../wt-123`는 두 adapter와 세 runtime의 availability, version, role/mode 및 필요한 capability 근거를 JSON으로 보여 줍니다. Orca version은 `orca status --json`의 `result.runtime.appVersion`에서 읽으며, 값이 없거나 implausible하면 `unknown`입니다. cmux와 Orca도 실제 launch/list 계약을 admission 전에 증명합니다. runtime probe 실패는 marker를 소비하지 않고 machine-readable reason으로 종료하며 fallback은 없습니다. OpenCode permission JSON은 top-level과 named primary `agent-workflow` agent 양쪽에서 `*`, `external_directory`, `webfetch`, `websearch`를 deny합니다. Read는 `edit`와 `bash`도 deny하고, write만 구현·빌드·테스트·Git 실행을 위해 양쪽을 명시적으로 allow합니다. Adapter는 검증한 내용을 `OPENCODE_CONFIG_CONTENT`로 전달하고 항상 `--agent agent-workflow`를 사용하므로 built-in/default agent fallback은 없습니다. Codex, Claude Code, OpenCode 모두 같은 public interface와 typed runtime adapter를 통해 conductor를 포함한 모든 role을 실행합니다.

같은 issue를 다시 dispatch할 때 기존 RUN/BLOCKER는 cross-platform nanosecond mtime과 `started_at` 결합 서명으로 구분합니다. 현재 launch에서 서명이 바뀌지 않은 stale artifact는 liveness로 인정하지 않고 timeout 처리합니다.

새 runtime 공통 경로는 `agent-watchdog.sh`입니다. 각 시도는 `artifact_type:"agent_run"`과 runtime/role/version을 가진 RUN을 갱신하고, non-zero stderr를 `ISSUE-N-agent-attempt<K>-stderr.log`로 보존합니다. Non-Codex REVIEWER가 거부되면 raw stdout도 non-authoritative `ISSUE-N-review-attempt<K>-output.log`로 보존하고 RUN의 `refusal_reason`으로 `unparseable_output` 등을 구분합니다. `attempt`는 watchdog 내부 시도 횟수이지 redispatch admission ordinal이나 실패 round가 아닙니다. `codex-watchdog.sh`와 `codex_run`은 기존 직접 호출/과거 산출물을 읽기 위한 호환 경로일 뿐 새 multi-runtime authority가 아닙니다.

Conductor가 canonical ROUND-STATE를 갱신해야 할 때는 `--runtime <runtime> --role conductor --read-only --conductor-control`을 사용합니다. Runtime은 product-code write 권한 없이 proposal 하나만 출력하고, host publisher가 issue, live HEAD, worktree, base, schema, exact path, monotonic revision을 검증한 뒤 해당 ROUND-STATE만 원자 게시합니다. 검증 실패 시 아무 control artifact도 게시하지 않습니다.

Shared core는 admission 전에 선택 runtime의 runtime-specific host seam 또는 caller PATH를 canonical absolute executable로 고정하고, runner에는 `AGENT_WORKFLOW_RUNTIME_BIN` 하나만 전달합니다. 관측된 version은 `agent_run` RUN과 schema v2 transport receipt에 runtime/role과 함께 바인딩됩니다. 같은 issue의 receipt publish와 runner cleanup은 직렬화되며, 현재 receipt runner는 보존하고 superseded receipt-marked runner만 정리합니다. Policy-opted canonical redispatch만 schema v3 receipt에 host admission과 교차 검증된 route/policy digest 및 선택 tuple을 파생 복사합니다. 이 receipt는 비권위 provenance이며 route를 재생성하거나 completion을 증명하지 않습니다. v1 receipt는 legacy transport-only read compatibility이며 현재 runtime provenance를 증명하지 않습니다. Target config는 executable을 주입할 수 없습니다.

둘 이상의 write seat를 제안할 때는 먼저 canonical `ISSUE-123-EXECUTION-PLAN.json`을 만들고 `scripts/parallel-plan.sh decide --plan <plan> --target <repo>`를 실행합니다. 정확하고 배타적인 target-relative write set, dependency 없음, shared generated/lock/migration surface 비접촉, per-seat DB/env 격리, rate-limit budget이 모두 증명된 pair만 병렬입니다. 나머지는 reason code와 함께 직렬화됩니다. 각 dispatch는 `--execution-plan <plan> --seat <id>`로 plan binding을 소비합니다.

좌석 작업 후에는 clean candidate에서 선언된 순서대로 `scripts/candidate-integrate.sh`를 실행하고, candidate HEAD에 새 REVIEW/VERIFY/PR-DRAFT/completion/seat outcomes 전체가 모인 뒤 `scripts/candidate-close.sh evaluate`를 실행합니다. Integration step은 plan 순서와 정확히 일치하는 unique seat 목록이어야 하며, 각 evidence artifact 자체가 issue/round/revision/candidate HEAD/attempt/generation time을 직접 바인딩합니다. REVIEW는 `final`, PR-DRAFT는 `active` lifecycle만 현재 closure evidence입니다. Wrapper attempt ID만 바꾼 재사용, draft/superseded artifact, 비정상 RFC3339 timestamp, Worker HEAD의 green, mixed retry attempt, 이전 candidate HEAD, active blocker, dirty/conflicted candidate는 closure가 아닙니다. `candidate-close.sh inspect`는 closure 뒤의 한 커밋도 즉시 stale로 판정합니다. 기존 단일 write는 유효한 one-seat sequential plan이며, legacy no-plan 경로도 보수적인 직렬 실행으로 유지됩니다.

설치하면 PRODUCT_HOME의 프로젝트 소유 `model-alloc.json`도 함께 생성됩니다. `"$PRODUCT_HOME/scripts/model-alloc.sh" --role implementation|reviewer --runner <codex|claude|opencode>`은 실행 시 같은 schema로 설정을 검증하고, 증거가 없으면 안전한 기본 배치만 출력하며, canonical evidence의 연속된 findings round·작업량·계약 터치·재리뷰에 따라 배치 근거를 JSON으로 기록합니다. 구현 dispatch에 모델을 생략하면 PRODUCT_HOME의 이 설정을 사용해 선택 tuple을 결정하고 preflight와 launch에 동일하게 전달합니다. 리뷰 기본 우위는 source/release가 기록된 LiveBench의 `static_coding + reasoning` 단순 합으로 결정되고, 프로젝트가 명시적으로 완화할 때만 경고합니다. `agent-workflow.sh dispatch --orchestrator <cmux|orca> --allocate --allocator-role implementation`은 Codex 구현 모델만 자동 전달합니다. REVIEWER는 `--produce-review --allocate --allocator-role reviewer`로 runtime별 tuple을 요청할 수 있습니다. 새 기본값은 Claude Code의 `sonnet` alias를 제공하지만, OpenCode 모델은 연결한 provider에 따라 `provider/model` 식별자가 다르므로 target이 `reviewer_by_runtime.opencode`에 preflightable tuple을 설정해야 합니다. OpenCode provider/model을 추측하거나 fallback하지 않습니다. 업그레이드는 사용자 설정 파일을 보존합니다. 이전 schema-v1 설정에 `available_via`가 없으면 upgrade는 경고만 내고 보존하며, dispatch는 알려진 모델 family의 runtime만 제한적으로 추론하고 알 수 없는 model은 fail-closed로 migration을 요구합니다.

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

`ac-check.sh`는 schema/base freshness와 revision을 확인하고 중복·미발견 AC-ID를 거부합니다. 구현 프롬프트는 각 test 이름에 충족하는 canonical AC-ID(예: `AC-1 ...`)를 포함하도록 요구하며, pre-review gate는 discovered test name에서 그 ID를 찾습니다. `completion-check.sh`는 worker 주장이나 `RUN.json`을 보지 않고 live `base_sha..HEAD` diff, target-native test discovery, `acceptance.expected_test_count`, compile consumers, full typecheck, trigger된 review obligation을 계약과 대조합니다. `contract.test_count`가 없으면 discovery stdout의 비어 있지 않은 줄 하나가 test 하나이고, 있으면 `{pattern, group}`의 첫 multiline regex capture에서 양의 10진 test count를 읽습니다. extractor는 count만 바꾸며 AC-ID는 항상 discovery 원문에서 찾습니다. 불일치는 JSON과 non-zero exit로 리뷰를 hard-stop하고, discovery command 실패 JSON에는 exit code와 bounded UTF-8-safe stdout/stderr diagnostics가 포함됩니다. discovery 명령은 target profile 책임이며 core는 Vitest를 가정하지 않습니다.

실패한 구현 라운드를 다시 보낼 때는 먼저 canonical ROUND-STATE의 `round_control.failures[]`에 primary origin, owner/action, 실패 AC와 HEAD-bound 증거를 기록한 뒤 다음 gate를 사용합니다. REVIEW는 게시 시 `ISSUE-N-REVIEW-<reviewed_head_sha>.json` immutable snapshot도 남기며, 후속 실패 REVIEW가 이전 AC 일부를 명시적으로 닫을 때는 `closed_by.kind: "superseded_by"`와 snapshot checklist assertion을 사용합니다. integrated fix는 singleton transaction을 ordinal보다 먼저 기록하므로 그 사이의 강제 종료도 다음 admission이 pair 전체를 회수할 수 있습니다. live owner의 issue lock은 오래된 mtime만으로 회수하지 않으며, dry-run은 admission recovery를 포함해 durable state를 바꾸지 않습니다. malformed pre-existing BLOCKER는 canonical evidence로 승격하지 않고 `ISSUE-N-BLOCKER-QUARANTINED-<sha>.json`에 보존되며 host-owned recovery가 새 ordinal admission을 한 번만 허용합니다.

```bash
새 파일은 `touch_allowlist` glob만으로는 충분하지 않습니다. dispatch는 admission 전에 각 `touch_allowlist` path/glob가 `base_sha` tree의 기존 경로를 실제로 매칭함을 검증합니다. `base_sha`에 없던 변경 경로는 canonical `contract.new_file_allowlist[]`에 정확한 target-relative 파일명으로도 선언해야 하며, 그 항목도 `touch_allowlist` 패턴에 매칭되어야 하고 glob은 허용되지 않습니다. partial `superseded_by` closure는 남은 AC 전부가 뒤의 active failure에 승계될 때만 유효합니다. redispatch ordinal은 하나씩 연속 소비되고 active failure ordinal은 unique/order이며 `last_admission_key`는 같은 issue의 정확히 하나인 failure ordinal에 결속되어야 합니다.

scripts/redispatch-check.sh \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 4
```

### 5. 호스트 VERIFIER로 독립 검증

구현자와 REVIEWER/VERIFIER는 서로 다른 세션이어야 합니다. generic target은 schema를 만족하는 target-owned profile에 runtime/setup/environment와 required verification groups를 선언한 뒤, 실제 worktree에서 호스트 VERIFIER를 실행합니다.

```bash
(cd ../wt-123 && \
  "$PRODUCT_HOME/scripts/target-verify.sh" \
    "$PRODUCT_HOME/target-profile.json" 123)
```

`$PRODUCT_HOME/target-profile.json`은 target이 소유합니다. `schemas/target-profile.schema.json`으로 검증하고 `schemas/profiles/`의 Node/Go/Python 예시 중 가까운 것을 복사해 target 명령으로 고치세요. 명령은 argv 배열과 선택적 repository-relative cwd/env allowlist뿐이며 shell string/eval은 허용하지 않습니다. Generic canonical VERIFY가 PASS이려면 모든 required group command의 `exit_code`가 0이고, profile이 test-count extractor를 선언해 evidence에 `test_count`가 있으면 그 값이 정수이면서 0보다 커야 합니다. schema와 installed generic에도 포함되는 `scripts/lib/verify-artifact.cjs` semantic validator가 이 조건을 각각 검사합니다. extractor가 출력과 일치하지 않으면 `test_count:null`인 canonical FAIL 증거를 게시하며, 이를 0개 실행이나 PASS로 해석하지 않습니다. 기존 same-HEAD artifact는 schema와 aggregate 의미 검증을 모두 통과해야 append되므로 손상된 red latch를 새 PASS로 덮을 수 없습니다. 명령 출력의 `output_bytes`는 UTF-8 byte 상한이고 `output_truncated`는 실제 byte 초과 여부입니다. VERIFY schema는 FeedbackOps legacy의 `db_target + clean_state` 또는 generic의 `target_profile + groups` 중 정확히 하나를 요구하며, 증거 없는 empty PASS를 거부합니다. 실제 `node --test`의 `ℹ tests N` 형식을 포함한 Node/Go/Python 예시는 `schemas/profiles/`에 있습니다.

REVIEWER는 `agent-workflow.sh dispatch --orchestrator <cmux|orca> --runtime <codex|claude|opencode> --role reviewer --produce-review --model <model> --effort <effort>`로 실행합니다. 또는 `--allocate --allocator-role reviewer`로 runtime별 reviewer tuple을 명시적으로 요청할 수 있습니다. 선택 runtime은 capability-probed read mode를 제공해야 하며, non-Codex stdout의 prose-wrapped fenced JSON은 마지막 parseable block만 transcription 후보가 됩니다. Host-side는 그 뒤에도 JSON schema, producer, issue, live HEAD를 검증한 뒤 Git linked-worktree HEAD/ref lock 아래 canonical `.review/ISSUE-123-REVIEW.json`과 immutable snapshot을 원자 게시합니다. lock은 concurrent commit이 publication 사이에 끼어드는 것을 막고 실패 시 안전하게 해제됩니다. legacy `--read-only`는 liveness-only이며 canonical REVIEW publication을 대신하지 않습니다.

## FeedbackOps compatibility alternative

아래는 **`--profile feedbackops`로 설치한 target에만** 적용됩니다. generic install에는 이 adapter들이 없으므로 위의 generic worktree와 target-profile 경로를 사용하세요.

```bash
"$PRODUCT_HOME/scripts/prepare-worktree.sh" ../wt-123 --env-profile ../env/issue-123.env

eval "$("$PRODUCT_HOME/scripts/prepare-verify-db.sh" \
  --issue 123 \
  --target ../wt-123 \
  --base-url "$PGADMIN_URL" | tail -1)"

cd ../wt-123
VERIFY_ISSUE=123 \
VERIFY_DATABASE_URL="$VERIFY_DATABASE_URL" \
VERIFY_CLEAN_COMMAND="./scripts/verify-clean-state.sh" \
  "$PRODUCT_HOME/scripts/verify.sh"
```

`verify.sh`는 FeedbackOps pnpm/Vitest/Postgres 호환 adapter입니다. 인자 없는 실행은 backend 전체 모듈을 검증하며 `VERIFY_DATABASE_URL`과 target-owned `VERIFY_CLEAN_COMMAND`를 요구합니다.

## Mental model

```text
Issue / acceptance contract
        ↓
isolated worktree + env
        ↓
agent-workflow → selected runtime + Orca/cmux adapter → watchdog → typed runtime adapter
        ↓
completion + AC gate → independent REVIEWER
        ↓
host VERIFIER → canonical VERIFY
        ↓
Release Captain merge decision
```

- **CONDUCTOR**는 Codex·Claude Code·OpenCode 중 capability-probed runtime 하나로 contract와 `.review/*.json`을 관리하고 `conductor-rebuild.sh .review`로 디스크에서 상태를 복원합니다.
- **Implementer**는 지정된 worktree에서만 작성합니다.
- **REVIEWER**는 구현자와 독립적으로 patch와 checklist를 판정합니다.
- **VERIFIER**는 host-side DB/test 실행과 현재 HEAD-bound VERIFY를 소유합니다.

## Trust boundary

- write dispatch는 `agent-workflow.sh`, shared dispatch core, selected typed runtime adapter를 우회하지 않습니다.
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
| visible dispatch·liveness | `agent-workflow.sh`, `dispatch-core.sh`, transport adapters, `agent-watchdog.sh`, `agent-runtime.sh` (`codex-watchdog.sh`는 legacy) | [디스패치 오퍼레이터 규칙](docs/agents/multi-agent-workflow.md#dispatch-liveness-operator-rules) |
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
| `ISSUE-N-PR-DRAFT.json` | runtime-neutral 구현 handoff; 자체 테스트 주장은 참고일 뿐 |
| `ISSUE-N-REVIEW.json` | 독립 REVIEWER의 판정과 patch instruction |
| `ISSUE-N-REVIEW-<reviewed_head_sha>.json` | canonical REVIEW의 immutable content-identical evidence snapshot |
| `ISSUE-N-VERIFY.json` | 현재 HEAD에 대한 VERIFIER의 canonical 검증 증거 |
| `ISSUE-N-RUN.json` | shared watchdog의 runtime/role/version/attempt 실행 상태; 병합 증거 아님 |
| `ISSUE-N-TRANSPORT.json` | v2 runtime provenance + transport/runner receipt; policy-opted canonical redispatch는 v3에 admission-bound route provenance를 파생 복사; v1은 legacy read-only 호환, 모두 비권위 |
| `ISSUE-N-BLOCKER.json` | 구조화된 중단 사유와 필요한 결정 |
| `ISSUE-N-BLOCKER-QUARANTINED-<sha>.json` | malformed pre-existing BLOCKER의 raw host recovery copy; worker evidence가 아님 |
| `HEARTBEAT-*.json` | liveness 증거; correctness 증거 아님 |

## 더 읽을 문서

- [운영 플레이북](docs/agents/multi-agent-workflow.md) — risk tier, role, dispatch, sandbox, gate, verifier의 상세 절차
- [산출물 lifecycle](docs/agents/artifact-lifecycle.md) — freshness, supersession, archive, validation
- [적용 가이드](.claude/skills/agent-workflow/references/adoption.md) — 새 저장소 compatibility interview와 target adapter 경계
- [문제 보고 계약](docs/agents/issue-reporting.md) — 재현·redaction·upstream issue 보고
- [CONDUCTOR 페르소나](docs/agents/conductor-persona.md) / [VISUAL-REVIEWER 페르소나](docs/agents/visual-reviewer-persona.md)
- [실전 trial 기록](docs/agents/workflow-trial-log.md) / [현재 상태와 roadmap](STATUS.md)
- [프로젝트용 agent-workflow skill](.claude/skills/agent-workflow/SKILL.md)

전체 스크립트는 `ls scripts/`로, source checkout의 smoke inventory는 `bash scripts/__tests__/run-all.sh --list`로 확인합니다. `scripts/__tests__/`는 설치 대상에 포함되지 않습니다. `--list`는 read-only 조회이므로 임시 저장소를 할당하지 않고 답합니다. smoke가 실패하면 runner가 해당 smoke의 진단을 `--- begin <name> diagnostic ---` 블록으로 출력하고 보존된 캡처 경로를 `diagnostic retained: <path>`로 알려줍니다. 자격 증명을 출력할 수 있는 suite는 `--redact-values-file <path>`를 넘겨야 하며, 파일의 비어 있지 않은 각 줄을 양쪽 진단에서 문자 그대로 `[REDACTED]`로 바꿉니다. runner가 임의의 비밀을 추론하지 않으므로 값 파일의 완전성은 호출자 책임이고, raw 실패 캡처는 sanitized 사본 생성 뒤 보존하지 않습니다. runner 자체의 계약 테스트는 live inventory에 들어가지 않도록 `*.smoke.sh`가 아닌 `scripts/__tests__/run-all-contract.test.sh`이며 직접 실행합니다. 자세한 규칙은 [운영 플레이북](docs/agents/multi-agent-workflow.md)의 Smoke Suite Diagnostics를 따릅니다. 이 source repository의 release gate는 product containment, source/portable-install Markdown link, installation non-leakage, CI routing을 별도로 소유하며 타겟에 설치되지 않습니다.

## 기여

1. macOS Bash 3.2 문법을 유지합니다.
2. 변경한 스크립트에는 해당 smoke를 추가·실행합니다.
3. 스크립트·schema·workflow contract를 바꾸면 playbook, README, STATUS와 installer/skill reference를 같은 커밋에서 동기화합니다.
4. `run-all.sh`를 바꾸면 `bash scripts/__tests__/run-all-contract.test.sh`를 함께 실행합니다.
5. 최종으로 `NODE_OPTIONS= bash scripts/__tests__/run-all.sh`를 실행합니다.

현재 release와 남은 작업은 [STATUS.md](STATUS.md)와 GitHub Issues가 정본입니다.

## Local model/task telemetry

Telemetry는 opt-in이며 네트워크를 사용하지 않습니다. `scripts/telemetry.sh collect`는 target-local salt, canonical ROUND-STATE/RUN과 선택적 REVIEW/VERIFY/BLOCKER를 검증합니다. Parallel candidate의 `ISSUE-N-CLOSURE.json`을 주면 canonical `ISSUE-N-INTEGRATION.json`과 `ISSUE-N-CANDIDATE-EVIDENCE.json`도 반드시 주어야 하며, 세 source의 realpath·공유 #14 schema·identity·semantic과 실제 byte digest를 함께 확인합니다. Closure 시각은 integration/evidence 생성 및 admitted RUN 종료보다 빠를 수 없고, candidate closure와 telemetry가 공유하는 strict calendar parser가 February 30 같은 regex-shaped impossible RFC3339 날짜를 거부합니다. 저장 sample의 closure source/hash/value와 candidate_closure/integration/candidate_evidence artifact path·digest도 하나의 의미 검증을 통과해야 합니다. Green은 closure의 source digest, issue/round/revision/HEAD가 모두 일치하고 `status:"closed"`일 때만 기록되며 REVIEW/VERIFY pass만으로는 green이 아닙니다. Policy-opted canonical redispatch를 수집할 때만 canonical v3 `ISSUE-N-TRANSPORT.json`을 주며, collector는 Git-common-dir의 현재 host admission binding과 receipt의 route digest·runtime·role·model/effort·transport·policy·reason tuple을 모두 교차 검증한 뒤 host tuple에서 telemetry 값을 유도합니다. Receipt의 `implementation`/`reviewer`/`verifier` role은 telemetry의 `implementation`/`review`/`verification`으로만 매핑하며 그 밖의 receipt role은 typed refusal입니다. 이 v2 sample은 raw digest 대신 local-salt HMAC route pseudonym만 저장하고 CLI tuple/routing 값은 거부합니다. Salt/store의 기존 경로 구성요소와 생성된 store는 realpath containment를 확인하므로 target 내부를 가리키는 benign symlink는 허용하지만 외부 탈출은 거부합니다. Usage는 `observed`, `estimated`, `unavailable` 중 하나이며 unavailable은 null로 남아 0원으로 계산되지 않습니다. prompt/output/env/file body, raw provider request ID, 사용자 이름과 절대 경로는 저장하지 않습니다.

`scripts/telemetry.sh report --worktree <target> --from <ISO> --to <ISO> --minimum-samples <N> --minimum-completeness <0..1>`은 JSON을 stdout으로 내보냅니다. Report는 closure 결합을 다시 검증하고 동일 project pseudonym/issue/round/revision에서 attempt 1부터 빠짐없이 이어지고 직전 sample을 가리키는 retry만 complete로 판정합니다. 각 attempt의 모델 allocation을 노출하며 mixed-model chain은 첫 모델 cohort에 귀속하지 않고 `mixed-model:<chain-id>`로 억제합니다. Legacy v1 sample/report parsing은 유지하며, v2 routing cohort는 v2 policy sample만으로 만들고 selection basis·policy digest·runtime·role·task class·tier·model/effort가 homogeneous인 complete independent chain 수와 usage completeness가 기준 미만이면 `insufficient evidence`로 억제합니다. 충족 cohort는 complete-green rate, mean retries-to-green, mean wall time과 usage/cost를 함께 출력합니다. Per-dispatch route pseudonym은 privacy-preserving sample identity일 뿐 cohort dimension이 아닙니다. v2 report는 이를 `policy.minimum_complete_independent_chains`로 명시하며 현재 값은 `--minimum-samples`와 동일합니다. observed/estimated cost를 분리하고 no-green/incomplete/unavailable을 그대로 표시하며, report는 confounder가 있는 descriptive association일 뿐 원인이나 자동 정책 변경을 주장하지 않습니다. 이 보고서는 advisory evidence이며 `model-alloc.json`이나 tier policy를 절대 수정하지 않습니다. 보존과 export는 target 운영자가 정하고 toolkit은 background 수집이나 upload를 하지 않습니다. 개별 삭제는 exact ID에 `telemetry.sh delete ... --sample-id <64hex> --confirm DELETE`를 명시해야 하며, 전체 디렉터리 자동 정리는 제공하지 않습니다. 보고서 예시는 `schemas/fixtures/telemetry_report.valid.json`과 `telemetry_report.routing.valid.json`입니다.
