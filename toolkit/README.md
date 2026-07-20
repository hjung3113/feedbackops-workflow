# feedbackops-workflow

분리된 워크트리와 독립적인 검증으로 cmux × Claude × Codex 작업을 운영하는 **opt-in 멀티 에이전트 워크플로 툴킷**입니다. 병렬 작성자의 작업을 디스크 산출물로 추적하고, 에이전트의 “완료했습니다”가 아니라 현재 HEAD에 결속된 증거로 병합 여부를 판단합니다.

**Merge authority:** worker prose나 프로세스 종료, `RUN.json`은 완료 증거가 아닙니다. 병합 가능한 상태는 현재 HEAD에 맞는 canonical `REVIEW`와 `VERIFY` 산출물로 Release Captain이 판정합니다.

현재 릴리스는 [`STATUS.md`](STATUS.md)에서 확인하세요. 상태 문구와 Git 기록이 다르면 `git log`와 실제 schemas/scripts가 우선합니다. 이 저장소에서 개발하는 것과 타겟에 적용하는 것은 별도 경로이며, 이 툴킷 자체에 적용하려면 명시적인 `--self-test` dogfooding 승인이 필요합니다.

## 시작 전에: 적용 가능성과 선택

### 필요한 환경

- macOS stock Bash 3.2 호환 셸 (`declare -A`, `mapfile`, `${var,,}`를 사용하지 않음)
- Git, cmux, Codex CLI
- 설치된 타겟의 Git checkout 또는 plain checkout
- 병렬 작업마다 별도 worktree와, FeedbackOps 스타일 DB 테스트라면 별도 일회성 DB

신선한 설치는 네 개의 managed leaf를 **self-contained 복사본**으로 배포합니다. 설치는 원본 toolkit을 가리키는 절대 symlink를 만들지 않으며, 타겟 저장소와 함께 커밋하거나 다른 머신으로 옮길 수 있습니다.

### 현재 호환성 경계

| 영역 | 현재 계약 |
|---|---|
| dispatch, watchdog, artifact lifecycle | cmux + Codex가 있는 Git 저장소에서 재사용 가능 |
| `prepare-worktree.sh` | pnpm 및 root/`apps/backend` 환경 구조 |
| `tier-probe.sh` | TypeScript/TSX exported-contract 휴리스틱 |
| `verify.sh` | pnpm workspace의 `backend` 패키지 + Vitest |
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

### 3. canonical contract를 준비하고 구현자를 dispatch

Standard/Full Cluster 최초 write 전에는 CONDUCTOR가 `schemas/round_state.schema.json` 전체를 만족하는 `ISSUE-123-ROUND-STATE.json`을 만들고 issue, tier, revision, 실제 worktree, live HEAD, base freshness에 결속해야 합니다. Standard는 별도 mini-state를 만들지 않고 `pr_draft`와 `review` pointer를 유지합니다. Trivial 최초 write만 `--tier trivial`과 기존 `pr_draft`-only 계약을 사용합니다.

```bash
NODE_OPTIONS= scripts/cmux-dispatch.sh \
  --issue 123 \
  --worktree ../wt-123 \
  --tier standard \
  --prompt-file ../wt-123/.review/ISSUE-123-PROMPT.txt \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 1 \
  --name issue-123-impl \
  --allocate \
  --allocator-role implementation
```

`gpt-5.6-terra low`가 현재 운영 환경의 기본 구현 allocation입니다. 다른 계정·머신에서는 capability ordering을 유지하는 명시적 모델을 preflight하고, 직접 모델을 고를 때만 `--model`/`--effort`를 함께 pin 하세요. 모든 write-capable Codex는 `cmux-dispatch.sh` → `codex-watchdog.sh` → `codex-safe.sh` 경로를 사용합니다. `codex exec` 직접 실행이나 `cmux workspace create --command ...` 수동 조립은 지원하지 않습니다.

설치하면 프로젝트 소유 `.agent-workflow/model-alloc.json`도 함께 생성됩니다. `scripts/model-alloc.sh --role implementation`은 실행 시 같은 schema로 설정을 검증하고, 증거가 없으면 안전한 기본 배치만 출력하며, canonical evidence의 연속된 findings round·작업량·계약 터치·재리뷰에 따라 배치 근거를 JSON으로 기록합니다. 리뷰 기본 우위는 source/release가 기록된 LiveBench의 `static_coding + reasoning` 단순 합으로 결정되고, 프로젝트가 명시적으로 완화할 때만 경고합니다. `cmux-dispatch.sh --allocate --allocator-role implementation`은 Codex 구현 모델만 자동 전달합니다. Opus/Fable/Claude 역할은 Codex로 전달하지 않으며, 업그레이드는 사용자 설정 파일을 보존합니다.

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

인자 없는 `verify.sh`는 backend 전체 모듈을 검증합니다. 좁은 Vitest 이름/경로 filter는 touched behavior 전체를 덮는다는 Release Captain의 확인이 있을 때만 사용합니다. `VERIFY_ISSUE` 실행은 `VERIFY_DATABASE_URL`과 target-owned `VERIFY_CLEAN_COMMAND`를 요구하며, local이 아닌 DB·shared `.env` fallback·superuser·clean-state 불일치·실패한 migration/seed를 fail closed합니다. `--fresh`는 target DB lifecycle adapter가 생길 때까지 `fresh_requires_adapter`로 거부됩니다. 통과하더라도 `.review/ISSUE-123-VERIFY.json`을 쓰고 다시 읽지 못하면 성공이 아닙니다.

REVIEWER는 `cmux-dispatch.sh --produce-review`로 실행합니다. Codex를 실제 read-only sandbox에서 실행하고 host-side에서 JSON schema, producer, issue, live HEAD를 검증한 뒤 canonical `.review/ISSUE-123-REVIEW.json`을 원자 게시합니다. legacy `--read-only`는 liveness-only이며 filesystem sandbox를 read-only로 만들지 않습니다.

## Mental model

```text
Issue / acceptance contract
        ↓
isolated worktree + env
        ↓
cmux-dispatch → watchdog → safe Codex
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

- write dispatch는 `cmux-dispatch.sh`와 `codex-safe.sh`를 우회하지 않습니다.
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
| visible dispatch·liveness | `cmux-dispatch.sh`, `codex-watchdog.sh`, `codex-safe.sh` | [디스패치 오퍼레이터 규칙](docs/agents/multi-agent-workflow.md#dispatch-liveness-operator-rules) |
| 계약·완료 gate | `ac-check.sh`, `completion-check.sh`, `redispatch-check.sh` | [Artifact lifecycle](docs/agents/artifact-lifecycle.md) |
| DB·테스트 검증 | `prepare-verify-db.sh`, `verify.sh` | [VERIFIER protocol](docs/agents/multi-agent-workflow.md#verifier-protocol) |
| 상태 복원·보존 | `conductor-rebuild.sh`, `artifact-fresh.sh`, `review-archive.sh` | [Artifact lifecycle](docs/agents/artifact-lifecycle.md) |

`schemas/`의 JSON Schema가 산출물 계약의 정본입니다.

| 산출물 | 의미 |
|---|---|
| `ISSUE-N-ROUND-STATE.json` | CONDUCTOR가 dispatch 0부터 유지하는 canonical contract와 revision-pinned AC manifest |
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

전체 스크립트는 `ls scripts/`로, smoke inventory는 `bash scripts/__tests__/run-all.sh --list`로 확인합니다. 이 source repository의 release gate는 product containment, source/portable-install Markdown link, installation non-leakage, CI routing을 별도로 소유하며 타겟에 설치되지 않습니다.

## 기여

1. macOS Bash 3.2 문법을 유지합니다.
2. 변경한 스크립트에는 해당 smoke를 추가·실행합니다.
3. 스크립트·schema·workflow contract를 바꾸면 playbook, README, STATUS와 installer/skill reference를 같은 커밋에서 동기화합니다.
4. 최종으로 `NODE_OPTIONS= bash scripts/__tests__/run-all.sh`를 실행합니다.

현재 release와 남은 작업은 [STATUS.md](STATUS.md)와 GitHub Issues가 정본입니다.
