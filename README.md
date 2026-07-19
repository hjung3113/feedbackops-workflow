# feedbackops-workflow

[![smoke](https://github.com/hjung3113/feedbackops-workflow/actions/workflows/smoke.yml/badge.svg)](https://github.com/hjung3113/feedbackops-workflow/actions/workflows/smoke.yml)

cmux × Claude × Codex 작업을 **분리된 워크트리, 구조화된 산출물, 독립 검증**으로 운영하는 멀티 에이전트 개발 워크플로 툴킷입니다.

에이전트의 “완료했습니다”를 믿지 않고, 커밋·리뷰·테스트 산출물을 기계적으로 대조해 병렬 작업의 false green과 상태 손실을 막는 것이 목적입니다. FeedbackOps에서 실전 검증한 워크플로를 별도 저장소로 분리했으며, 타겟 프로젝트에 설치해 사용합니다.

> 현재 `verify.sh`는 `pnpm` workspace의 `backend` 패키지와 Vitest를 사용하는 타겟을 기준으로 합니다. 두 번째 실제 타겟이 생기기 전까지 검증 오라클은 의도적으로 일반화하지 않습니다.

## 핵심 특성

- **보이는 디스패치** — `cmux-dispatch.sh`가 워크스페이스, cwd, prompt, 모델, liveness 예산을 하나의 경로로 고정합니다.
- **샌드박스 경계** — 구현자 Codex는 `workspace-write` 안에서 실행되며 DB·네트워크 검증은 호스트의 VERIFIER가 담당합니다.
- **false-green 방지** — 전체 skip, 0 tests, 스위트 초기화 실패, 잘못된 DB, 증거 산출물 누락을 성공으로 처리하지 않습니다.
- **병렬 격리** — 작업별 워크트리와 일회성 DB를 사용해 파일·스키마·락 간섭을 막습니다.
- **디스크가 정본** — CONDUCTOR는 대화 메모리가 아니라 `.review/*.json`만으로 상태를 복원합니다.
- **macOS Bash 3.2 호환** — 주요 계약은 오프라인 smoke로 검증하고 GitHub Actions에서도 실행합니다.

## 빠른 시작

### 1. 툴킷 검증

```bash
git clone https://github.com/hjung3113/feedbackops-workflow.git
cd feedbackops-workflow
NODE_OPTIONS= bash scripts/__tests__/run-all.sh
```

실행할 smoke 목록만 보려면:

```bash
bash scripts/__tests__/run-all.sh --list
```

### 2. 타겟 프로젝트에 설치

```bash
scripts/install-into.sh ../my-project
```

기본값은 현재 머신의 toolkit 업데이트를 즉시 따라가는 symlink 모드입니다. 이 절대경로 symlink는 머신 로컬용이므로 커밋해 다른 머신에 배포하지 마세요. 타겟 저장소와 함께 버전 관리할 스냅샷은 `--mode copy`로 설치한 뒤 검토·커밋하세요.

기존 설치를 갱신할 때 installer는 사용자 파일을 덮어쓰지 않고 `skip existing` 합니다. toolkit 정본으로 교체할 범위를 확인한 뒤 `--force`를 사용하세요.

```text
my-project/
├── .agent-workflow/
│   ├── scripts   -> feedbackops-workflow/scripts
│   ├── schemas   -> feedbackops-workflow/.review/schemas
│   └── docs      -> feedbackops-workflow/docs/agents
├── .claude/skills/agent-workflow
└── .review/
```

`.env.example`은 타겟용 환경 계약 예시입니다. 실제 계정·DB 정보를 채운 자체 프로필을 별도로 만드세요.

### 3. 격리된 워크트리 준비

```bash
scripts/prepare-worktree.sh ../wt-123 --env-profile ../env/issue-123.env
```

두 개 이상의 워크트리를 병렬 운영할 때는 각 워크트리에 독립 환경 프로필과 일회성 DB를 주입하세요. 공유 `.env`는 명시적으로 `--allow-shared-env`를 주지 않는 한 거부됩니다.

### 4. Codex 구현자 디스패치

```bash
NODE_OPTIONS= scripts/cmux-dispatch.sh \
  --issue 123 \
  --worktree ../wt-123 \
  --prompt-file ../wt-123/.review/ISSUE-123-PROMPT.txt \
  --name issue-123-impl \
  --model gpt-5.6-terra \
  --effort medium
```

`gpt-5.6-terra`는 현재 운영 환경의 구현 모델 alias입니다. 다른 계정·머신에서는 플레이북의 capability ordering을 유지하는 명시적 모델을 preflight한 뒤 사용하세요. `--model`을 생략해 글로벌 기본값으로 fallback하지 마세요.

읽기·사고 중심 작업은 파일 변경이 없어도 stall로 오판하지 않도록 `--read-only`를 추가합니다. 긴 ARCH/리뷰 시트는 필요할 때 `--first-progress-timeout`과 `--stall-timeout`을 명시하세요.

`codex exec`를 직접 실행하거나 `cmux workspace create --command ...`를 손으로 조립하는 경로는 지원하지 않습니다.

### 5. 리뷰 전 AC-ID 검사

```bash
scripts/ac-check.sh \
  --manifest ../wt-123/.review/ISSUE-123-AC.json \
  --tests ../wt-123/.review/ISSUE-123-DISCOVERED-TESTS.txt
```

manifest는 `{"acs":[{"id":"AC-1"}]}` 형태이며, tests 파일은 실제로 발견된 테스트 이름·경로를 한 줄씩 담습니다. 중복 AC-ID나 테스트에서 발견되지 않는 ID가 있으면 리뷰로 넘어가지 않습니다.

### 6. 호스트 VERIFIER 실행

```bash
eval "$(scripts/prepare-verify-db.sh \
  --issue 123 \
  --target ../wt-123 \
  --base-url "$PGADMIN_URL" | tail -1)"

cd ../wt-123
VERIFY_ISSUE=123 \
VERIFY_DATABASE_URL="$VERIFY_DATABASE_URL" \
  .agent-workflow/scripts/verify.sh create-voc
```

`prepare-verify-db.sh`는 DB 생성·migration·seed 중 하나라도 실패하면 `VERIFY_DATABASE_URL=`을 출력하지 않습니다. `VERIFY_ISSUE`가 설정된 상태에서 `VERIFY_DATABASE_URL`이 없으면 `verify.sh`도 공유 `.env` DB로 fallback하지 않고 거부합니다.

## 작동 방식

```text
Issue / acceptance contract
        │
        ▼
prepare-worktree.sh  ──▶  isolated worktree + env
        │
        ▼
cmux-dispatch.sh ─▶ codex-watchdog.sh ─▶ codex-safe.sh ─▶ CODEX
        │                    │
        │                    └─ RUN / HEARTBEAT / BLOCKER
        ▼
REVIEWER + ac-check.sh
        │
        ▼
host VERIFIER ──▶ ISSUE-N-VERIFY.json
        │
        ▼
Release Captain ──▶ merge decision
```

CONDUCTOR는 이 상태를 `scripts/conductor-rebuild.sh .review`로 복원합니다. `RUN.json` 종료 코드는 프로세스 상태일 뿐 작업 완료 증거가 아니며, 병합 가능 여부는 현재 HEAD에서 생성된 REVIEW와 VERIFY 산출물로 판정합니다.

## 주요 도구

| 도구 | 역할 |
|---|---|
| `install-into.sh` | 툴킷을 symlink 또는 copy 모드로 타겟에 설치 |
| `prepare-worktree.sh` | 의존성·환경 프로필을 갖춘 격리 워크트리 준비 |
| `cmux-dispatch.sh` | 보이는 cmux 워크스페이스 생성과 fresh RUN/BLOCKER 폴링 |
| `codex-watchdog.sh` | 프로세스·파일 liveness, stall 재시도, 이중 probe 기반 refusal 분류 |
| `codex-safe.sh` | Codex 샌드박스·cwd·모델 effort 경계, 실패 시 partial stash |
| `ac-check.sh` | manifest AC-ID가 발견된 테스트에 존재하는지 pre-review 검사 |
| `verify.sh` | Vitest JSON 분류, DB 경계, typecheck baseline, canonical VERIFY 산출물 |
| `conductor-rebuild.sh` | `.review/*.json`에서 현재 클러스터 상태 복원 |
| `artifact-fresh.sh` / `review-archive.sh` | 산출물 신선도 검사와 병합 후 아카이브 |
| `rebase-inflight.sh` | dirty worktree를 건드리지 않는 진행 중 브랜치 rebase |

전체 목록과 옵션은 [`AGENTS.md`](AGENTS.md)와 [`docs/agents/multi-agent-workflow.md`](docs/agents/multi-agent-workflow.md)에서 확인하세요.

## 산출물 계약

`.review/schemas/`의 JSON Schema가 정본입니다.

| 산출물 | 의미 |
|---|---|
| `ISSUE-N-PR-DRAFT.json` | CODEX의 구현 handoff. 자체 테스트 주장은 참고일 뿐입니다. |
| `ISSUE-N-REVIEW.json` | 독립 REVIEWER의 판정과 patch instruction |
| `ISSUE-N-VERIFY.json` | 현재 HEAD에 대한 VERIFIER의 canonical 검증 증거 |
| `ISSUE-N-RUN.json` | watchdog 실행 상태. 병합 증거가 아닙니다. |
| `ISSUE-N-BLOCKER.json` | 구조화된 중단 사유와 필요한 의사결정 |
| `HEARTBEAT-*.json` | liveness 증거. correctness 증거가 아닙니다. |

상세한 lifecycle·freshness·validation 규칙은 [`.review/README.md`](.review/README.md)를 따릅니다.

## 재사용 경계

이 저장소는 스킬의 정본을 [`.claude/skills/agent-workflow/SKILL.md`](.claude/skills/agent-workflow/SKILL.md)로 관리합니다. 스킬은 진입점·필수 게이트·완료 보고만 가지고, 모델 배치와 산출물 계약은 버전 관리되는 플레이북에서 읽습니다.

다만 현재 모든 스크립트가 일반화된 것은 아닙니다. dispatch·watchdog·artifact lifecycle은 대부분 재사용 가능하지만, worktree 준비·risk probe·verification·DB 생성은 pnpm, TypeScript, Vitest, PostgreSQL 계약을 가진 target adapter입니다. 새 저장소에 적용할 때는 [적용 가이드](.claude/skills/agent-workflow/references/adoption.md)의 compatibility interview를 먼저 실행하세요.

## 안전 경계

- `codex-safe.sh` 우회 디스패치 금지
- 하나의 checkout에서 두 개의 workspace-write 구현자 동시 실행 금지
- 원격·staging·production DB 검증 금지
- 구현자와 REVIEWER/VERIFIER 세션 분리
- prose PASS로 병합 금지; 현재 HEAD의 canonical 산출물 필수
- 파괴적 자동 rebase 금지; `rebase-inflight.sh`는 dirty worktree를 skip하고 conflict를 abort

## 문서

- [운영 플레이북](docs/agents/multi-agent-workflow.md)
- [CONDUCTOR 페르소나](docs/agents/conductor-persona.md)
- [VISUAL-REVIEWER 페르소나](docs/agents/visual-reviewer-persona.md)
- [산출물 계약과 lifecycle](.review/README.md)
- [실전 trial 기록](docs/agents/workflow-trial-log.md)
- [현재 상태와 roadmap](STATUS.md)
- [새 저장소 적용 가이드](.claude/skills/agent-workflow/references/adoption.md)

## 기여

1. macOS Bash 3.2 문법을 유지합니다. `declare -A`, `mapfile`, `${var,,}`를 사용하지 마세요.
2. 변경한 스크립트의 smoke를 추가·실행합니다.
3. 계약이 바뀌면 README, 운영 플레이북, STATUS를 같은 커밋에서 동기화합니다.
4. 최종으로 `NODE_OPTIONS= bash scripts/__tests__/run-all.sh`를 실행합니다.

저장소 작업 규칙은 [`AGENTS.md`](AGENTS.md)가 정본입니다.
