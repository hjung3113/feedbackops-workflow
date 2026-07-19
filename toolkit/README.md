# feedbackops-workflow

cmux × Claude × Codex 작업을 **분리된 워크트리, 구조화된 산출물, 독립 검증**으로 운영하는 멀티 에이전트 개발 워크플로 툴킷입니다.

에이전트의 “완료했습니다”를 믿지 않고, 커밋·리뷰·테스트 산출물을 기계적으로 대조해 병렬 작업의 false green과 상태 손실을 막는 것이 목적입니다. FeedbackOps에서 실전 검증한 워크플로를 별도 저장소로 분리했으며, 타겟 프로젝트에 설치해 사용합니다.

> 현재 `verify.sh`는 `pnpm` workspace의 `backend` 패키지와 Vitest를 사용하는 타겟을 기준으로 합니다. 두 번째 실제 타겟이 생기기 전까지 검증 오라클은 의도적으로 일반화하지 않습니다.

## 핵심 특성

- **보이는 디스패치** — `cmux-dispatch.sh`가 워크스페이스, cwd, prompt, 모델, liveness 예산을 하나의 경로로 고정합니다.
- **샌드박스 경계** — 구현자 Codex는 `workspace-write` 안에서 실행되며 DB·네트워크 검증은 호스트의 VERIFIER가 담당합니다.
- **false-green 방지** — 전체 skip, 0 tests, 스위트 초기화 실패, 잘못된 DB, 증거 산출물 누락을 성공으로 처리하지 않습니다.
- **독립 완료 계산** — CONDUCTOR가 worker prose나 `RUN.json` 대신 live `base..HEAD` diff와 target-native test discovery를 계약과 대조합니다.
- **병렬 격리** — 작업별 워크트리와 일회성 DB를 사용해 파일·스키마·락 간섭을 막습니다.
- **디스크가 정본** — CONDUCTOR는 대화 메모리가 아니라 `.review/*.json`만으로 상태를 복원합니다.
- **계약 영향 스코프** — exported-contract 변경은 scope lock 전에 target-native 소비자 탐색을 수행하고, 구현 후 전체 typecheck로 결과를 gate하며, 실행 증거를 ROUND-STATE `live_probes[]`에 남깁니다.
- **macOS Bash 3.2 호환** — 주요 계약은 오프라인 smoke로 검증하고 GitHub Actions에서도 실행합니다.

## 빠른 시작

### 1. 툴킷 검증

```bash
git clone https://github.com/hjung3113/feedbackops-workflow.git
cd feedbackops-workflow/toolkit
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

Installer는 자신의 `scripts/` 위치에서 물리적인 product home을 찾습니다. Git 저장소 루트는 self-install 같은 저장소 안전 검사를 위한 선택적 컨텍스트일 뿐이며, Git 메타데이터가 없는 export와 공백이 포함된 경로도 설치할 수 있습니다. Source와 installed command는 같은 home의 형제 `scripts/`, `schemas/`, `docs/` 구조를 사용합니다.

기존 설치를 갱신할 때 installer는 사용자 파일을 덮어쓰지 않고 `skip existing` 합니다. toolkit 정본으로 교체할 범위를 확인한 뒤 `--force`를 사용하세요.

```text
my-project/
├── .agent-workflow/
│   ├── scripts   -> <product-home>/scripts
│   ├── schemas   -> <resolved-product-schemas>
│   └── docs      -> <product-home>/docs/agents
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
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 3 \
  --tests ../wt-123/.review/ISSUE-123-DISCOVERED-TESTS.txt
```

acceptance manifest는 별도 파일이 아니라 CONDUCTOR가 작성하는 ROUND-STATE의 `acceptance.criteria[]` 뷰입니다. 디스패치는 ROUND-STATE의 `revision`을 `--manifest-revision`으로 고정합니다. gate는 전체 스키마와 base freshness를 먼저 검증하고, stale revision·중복 AC-ID·테스트에서 발견되지 않는 ID가 있으면 리뷰로 넘어가지 않습니다.

### 5.5 CONDUCTOR 완료 계산

구현 종료 후 CONDUCTOR는 worker의 완료 주장이나 `RUN.json`을 입력으로 쓰지 않고, 같은 ROUND-STATE와 target-native discovery 결과로 현재 worktree의 실제 diff를 계산합니다.

```bash
scripts/completion-check.sh \
  --round-state ../wt-123/.review/ISSUE-123-ROUND-STATE.json \
  --manifest-revision 3
```

`base_sha..HEAD`의 모든 변경 경로는 `contract.touch_allowlist`에 들어가야 하고, 모든 AC-ID는 target-native `contract.test_discovery_command`의 실제 출력에서 발견되어야 합니다. 이 명령은 declared worktree에서 직접 실행되며, 출력의 non-empty record 수는 canonical `acceptance.expected_test_count`와 정확히 같아야 합니다. 불일치는 `mismatches` 배열을 가진 JSON으로 출력되며 exit 1로 리뷰를 hard-stop합니다. 입력·신선도·discovery 실행 오류도 stable error code가 든 JSON으로 exit 2를 반환합니다. discovery 명령은 target profile의 책임이며 core는 Vitest를 가정하지 않습니다.

Full Cluster의 migration·권한·저장 제약 결정은 ARCH 확정 전에 feasibility appendix를 남깁니다. 실제 grant/privilege, migration principal capability, 직전 migration/journal 관례, 관련 uniqueness constraint를 확인한 정확한 명령과 간결한 결과는 기존 ROUND-STATE `live_probes[]`에 기록하며, 관측 불가나 불가능한 capability는 구현 추측이 아니라 blocker/결정으로 처리합니다.

모든 테스트 matrix 행은 canonical ROUND-STATE `acceptance.criteria[]` 항목이며 AC-ID의 유일한 정본은 `id`입니다. 각 `statement`에는 명시적 precondition과 관측 가능한 checkpoint를 inline으로 적고, privacy 경계 행에만 positive field allowlist assertion을 추가합니다; 외부 인용은 이 필수 inline 내용의 정본을 대체할 수 없으며, privacy 적용 여부가 모호할 때만 이를 명시합니다.

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
completion-check.sh ──▶ REVIEWER + ac-check.sh
        │
        ▼
host VERIFIER ──▶ ISSUE-N-VERIFY.json
        │
        ▼
Release Captain ──▶ merge decision
```

CONDUCTOR는 이 상태를 `scripts/conductor-rebuild.sh .review`로 복원합니다. `RUN.json` 종료 코드는 프로세스 상태일 뿐 작업 완료 증거가 아니며, 병합 가능 여부는 현재 HEAD에서 생성된 REVIEW와 VERIFY 산출물로 판정합니다.

공개 계약을 바꾸는 청크는 touch allowlist를 확정하기 전에 타겟 프로필의 repository-native 명령으로 compile-time consumer를 열거합니다. CodeGraph는 사용 가능한 선택지일 뿐 필수 의존성이 아닙니다. 구현 후에는 전체 typecheck를 결정론적 gate로 실행합니다. 각 명령과 결과는 canonical ROUND-STATE의 `live_probes[]`에 기록하며, dynamic/convention 소비자는 adversarial review의 잔여 위험으로 남깁니다. Triggered watch-item 절차는 #10에서 정의합니다.

## 주요 도구

| 도구 | 역할 |
|---|---|
| `install-into.sh` | 툴킷을 symlink 또는 copy 모드로 타겟에 설치 |
| `prepare-worktree.sh` | 의존성·환경 프로필을 갖춘 격리 워크트리 준비 |
| `cmux-dispatch.sh` | 보이는 cmux 워크스페이스 생성과 fresh RUN/BLOCKER 폴링 |
| `codex-watchdog.sh` | 프로세스·파일 liveness, stall 재시도, 이중 probe 기반 refusal 분류 |
| `codex-safe.sh` | Codex 샌드박스·cwd·모델 effort 경계, 최소 Git metadata 쓰기 권한, 실패 시 partial stash |
| `ac-check.sh` | ROUND-STATE revision과 AC-ID 발견 여부를 검사하는 pre-review gate |
| `completion-check.sh` | live `base..HEAD` 변경과 test discovery를 ROUND-STATE 계약에 독립 대조 |
| `verify.sh` | Vitest JSON 분류, DB 경계, typecheck baseline, canonical VERIFY 산출물 |
| `conductor-rebuild.sh` | `.review/*.json`에서 현재 클러스터 상태 복원 |
| `artifact-fresh.sh` / `review-archive.sh` | 산출물 신선도 검사와 병합 후 아카이브 |
| `rebase-inflight.sh` | dirty worktree를 건드리지 않는 진행 중 브랜치 rebase |

전체 목록과 옵션은 [`AGENTS.md`](AGENTS.md)와 [`docs/agents/multi-agent-workflow.md`](docs/agents/multi-agent-workflow.md)에서 확인하세요.

## 산출물 계약

`schemas/`의 JSON Schema가 정본입니다.

| 산출물 | 의미 |
|---|---|
| `ISSUE-N-PR-DRAFT.json` | CODEX의 구현 handoff. 자체 테스트 주장은 참고일 뿐입니다. |
| `ISSUE-N-REVIEW.json` | 독립 REVIEWER의 판정과 patch instruction |
| `ISSUE-N-VERIFY.json` | 현재 HEAD에 대한 VERIFIER의 canonical 검증 증거 |
| `ISSUE-N-RUN.json` | watchdog 실행 상태. 병합 증거가 아닙니다. |
| `ISSUE-N-BLOCKER.json` | 구조화된 중단 사유와 필요한 의사결정 |
| `HEARTBEAT-*.json` | liveness 증거. correctness 증거가 아닙니다. |

상세한 lifecycle·freshness·validation 규칙은 [`docs/agents/artifact-lifecycle.md`](docs/agents/artifact-lifecycle.md)를 따릅니다.

## 재사용 경계

이 저장소는 스킬의 정본을 [`.claude/skills/agent-workflow/SKILL.md`](.claude/skills/agent-workflow/SKILL.md)로 관리합니다. 스킬은 진입점·필수 게이트·완료 보고만 가지고, 모델 배치와 산출물 계약은 버전 관리되는 플레이북에서 읽습니다.

다만 현재 모든 스크립트가 일반화된 것은 아닙니다. dispatch·watchdog·artifact lifecycle은 대부분 재사용 가능하지만, worktree 준비·risk probe·verification·DB 생성은 pnpm, TypeScript, Vitest, PostgreSQL 계약을 가진 target adapter입니다. 새 저장소에 적용할 때는 [적용 가이드](.claude/skills/agent-workflow/references/adoption.md)의 compatibility interview를 먼저 실행하세요.

타겟 프로젝트에서 툴킷 문제를 발견하면 로컬 우회만 남기지 마세요. 최소 재현, 툴킷 revision과 설치 모드, 기대/실제 결과, 비밀값을 제거한 증거, 임시 대응을 정리하고 기존 이슈를 검색한 뒤, 외부 쓰기 승인을 받아 upstream GitHub Issue로 등록합니다. 타겟의 handoff나 완료 보고에는 upstream 이슈 URL을 남깁니다. 상세 절차는 [적용 가이드](.claude/skills/agent-workflow/references/adoption.md)와 [문제 보고 계약](docs/agents/issue-reporting.md)을 따릅니다.

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
- [산출물 계약과 lifecycle](docs/agents/artifact-lifecycle.md)
- [타겟 문제 보고 계약](docs/agents/issue-reporting.md)
- [실전 trial 기록](docs/agents/workflow-trial-log.md)
- [현재 상태와 roadmap](STATUS.md)
- [새 저장소 적용 가이드](.claude/skills/agent-workflow/references/adoption.md)

## 기여

1. macOS Bash 3.2 문법을 유지합니다. `declare -A`, `mapfile`, `${var,,}`를 사용하지 마세요.
2. 변경한 스크립트의 smoke를 추가·실행합니다.
3. 계약이 바뀌면 README, 운영 플레이북, STATUS를 같은 커밋에서 동기화합니다.
4. 최종으로 `NODE_OPTIONS= bash scripts/__tests__/run-all.sh`를 실행합니다.

저장소 작업 규칙은 [`AGENTS.md`](AGENTS.md)가 정본입니다.
