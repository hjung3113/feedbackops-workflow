# feedbackops-workflow

An opt-in, reusable multi-agent development workflow toolkit. It gives a team a small set of explicit contracts for dispatch, review, verification, and evidence without turning the workflow into a hidden control plane.

The workflow is informed by the engineering principles in [Matt Pocock's Skills for Real Engineers](https://github.com/mattpocock/skills): keep practices small, adaptable, and composable; retain human control of the process; and use feedback loops to make changes trustworthy. This repository applies those ideas to a distributable workflow product; it is not a copy or runtime dependency of that skills repository.

## English

### What the toolkit provides

- An explicit dispatch interface for selected runtimes and transports, with no implicit fallback.
- Typed roles and canonical artifacts for controlled work: prompts, RUN/BLOCKER state, REVIEW, VERIFY, and non-authoritative transport receipts.
- A clear authority boundary: transport lifecycle is diagnostic only; fresh REVIEW and VERIFY evidence at the live commit determine completion.
- Portable installation for target repositories, while keeping target runtime state in the target's `.review/` directory.

### Operating principles

1. **Human control stays explicit.** A person chooses the task, scope, runtime, role, transport, and publication actions. The toolkit does not make those decisions silently.
2. **Small contracts compose.** Capability probing, admission, dispatch, review, verification, and recovery have narrow responsibilities instead of one opaque lifecycle controller.
3. **Feedback is evidence.** A failed check should yield concrete evidence for the next attempt; a passing terminal or receipt never substitutes for independent review and verification.
4. **Development tooling is not product payload.** Matt Pocock skills help maintain this repository, but the only distributable product root is [`toolkit/`](toolkit/).

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
| [`docs/plans/`](docs/plans/) and [`.review/`](.review/) | Repository-owned plans and runtime evidence. |
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

`feedbackops-workflow`는 선택적으로 적용할 수 있는 재사용형 멀티 에이전트 개발 워크플로 도구입니다. dispatch, 리뷰, 검증, 증거 수집에 필요한 계약을 작고 명시적으로 제공하며, 보이지 않는 제어 평면으로 작업 과정을 대신 결정하지 않습니다.

[Matt Pocock의 Skills for Real Engineers](https://github.com/mattpocock/skills)가 제시하는 원칙—작고 조정 가능하며 조합 가능한 실천, 사람이 유지하는 프로세스 통제권, 피드백 루프를 통한 신뢰 가능한 변경—을 참고했습니다. 다만 이 저장소는 그 스킬 저장소를 복사하거나 런타임 의존성으로 사용하지 않습니다. 여기서는 그 원칙을 배포 가능한 워크플로 제품에 맞게 적용합니다.

### 운영 원칙

1. **사람의 통제권을 명시합니다.** 작업·범위·런타임·역할·transport·배포 여부는 사람이 선택합니다. 도구가 이를 묵시적으로 결정하지 않습니다.
2. **작은 계약을 조합합니다.** capability probe, admission, dispatch, review, verify, recovery는 하나의 불투명한 라이프사이클 컨트롤러가 아니라 각각 좁은 책임을 가집니다.
3. **피드백은 증거여야 합니다.** 실패한 검사는 다음 시도에 필요한 구체적 증거를 남겨야 합니다. terminal 또는 transport receipt가 성공했다는 사실은 독립 REVIEW·VERIFY를 대체하지 못합니다.
4. **개발 도구와 제품을 분리합니다.** Matt Pocock 스킬은 이 저장소를 유지보수하기 위한 개발 환경입니다. 배포 가능한 제품 루트는 [`toolkit/`](toolkit/) 하나뿐입니다.

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
