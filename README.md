# feedbackops-workflow

An opt-in, reusable multi-agent development workflow toolkit. It gives a team explicit contracts for dispatch, review, verification, and evidence without turning the workflow into a hidden control plane.

## English

### What the toolkit provides

- An explicit dispatch interface for selected runtimes and transports, with no implicit fallback.
- Typed roles and canonical artifacts for controlled work: prompts, RUN/BLOCKER state, REVIEW, VERIFY, and non-authoritative transport receipts.
- A clear authority boundary: transport lifecycle is diagnostic only; fresh REVIEW and VERIFY evidence at the live commit determine completion.
- Portable installation for target repositories, while keeping target runtime state in the target's `.review/` directory.

### Start here

- Read [`toolkit/README.md`](toolkit/README.md) for installation, compatibility, and the first controlled run.
- Read [`toolkit/docs/agents/multi-agent-workflow.md`](toolkit/docs/agents/multi-agent-workflow.md) for the operating playbook.
- Read [`AGENTS.md`](AGENTS.md) for repository contribution rules and [`toolkit/AGENTS.md`](toolkit/AGENTS.md) for product-scoped rules.

### Repository layout

| Path | Purpose |
| --- | --- |
| [`toolkit/`](toolkit/) | The only distributable product root. |
| [`.agents/skills/`](.agents/skills/) and [`skills-lock.json`](skills-lock.json) | Maintainer development environment; never shipped to targets. |
| [`docs/agents/`](docs/agents/) | Maintainer issue-tracker, domain, and triage configuration. |
| [`docs/adr/`](docs/adr/) | Durable architecture decisions (why a design choice was made and what it forecloses) — read this before "cleaning up" anything that looks redundant. |
| [`docs/plans/`](docs/plans/) and [`.review/`](.review/) | Repository-owned plans and runtime evidence. |
| `HANDOFF.md` and [`docs/handoff-archive/`](docs/handoff-archive/) | Session continuity log — `HANDOFF.md` holds only the latest entry; older entries are archived, not appended. `HANDOFF.md` itself is untracked, so no link here. |
| [`.github/`](.github/) and [`.githooks/`](.githooks/) | Repository integration and release checks. |

### Verify the repository

Run the repository-owned release contract and the full product smoke suite from the repository root:

```bash
bash .github/tests/release-contract.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh
```

The release contract checks product containment, valid source and portable-install links, and that maintainer-only files do not leak into target installations.

---

## 한국어

### 이 도구가 제공하는 것

`feedbackops-workflow`는 선택적으로 적용할 수 있는 재사용형 멀티 에이전트 개발 워크플로 도구입니다. dispatch, 리뷰, 검증, 증거 수집에 필요한 명시적 계약을 제공하며, 보이지 않는 제어 평면으로 작업 과정을 대신 결정하지 않습니다.

### 어디서 시작할까요?

- 설치, 호환성, 첫 controlled run은 [`toolkit/README.md`](toolkit/README.md)에서 확인하세요.
- 실제 운영 규칙은 [`toolkit/docs/agents/multi-agent-workflow.md`](toolkit/docs/agents/multi-agent-workflow.md)에 있습니다.
- 저장소 기여 규칙은 [`AGENTS.md`](AGENTS.md), 제품 범위 규칙은 [`toolkit/AGENTS.md`](toolkit/AGENTS.md)에서 확인하세요.

### 저장소 구성

| 경로 | 용도 |
| --- | --- |
| [`toolkit/`](toolkit/) | 유일한 배포 가능 제품 루트 |
| [`.agents/skills/`](.agents/skills/) 및 [`skills-lock.json`](skills-lock.json) | 유지보수용 개발 환경. 대상 저장소에 배포하지 않음 |
| [`docs/agents/`](docs/agents/) | 유지보수용 이슈 트래커·도메인·triage 설정 |
| [`docs/plans/`](docs/plans/) 및 [`.review/`](.review/) | 이 저장소가 소유하는 계획과 런타임 증거 |
| [`.github/`](.github/) 및 [`.githooks/`](.githooks/) | 저장소 통합과 릴리스 검사 |

### 저장소 검증

저장소 루트에서 아래 release contract와 전체 smoke suite를 실행합니다.

```bash
bash .github/tests/release-contract.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh
```

release contract는 제품 경계, 소스와 portable 설치본의 Markdown 링크, 그리고 유지보수 전용 파일이 대상 설치본으로 새지 않는지를 검사합니다.
