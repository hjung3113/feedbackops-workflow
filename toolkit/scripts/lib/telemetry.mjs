#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url),
  { validate } = require("./json-schema-subset.cjs"),
  { parseRfc3339 } = require("./rfc3339.cjs"),
  { validateTelemetrySampleClosure } = require("./telemetry-sample.cjs"),
  product = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const die = (m, c = 2) => {
    console.error(`telemetry: ${m}`);
    process.exit(c);
  },
  sha = (b) => crypto.createHash("sha256").update(b).digest("hex"),
  hmac = (key, value) => crypto.createHmac("sha256", key).update(value).digest("hex");
const [command, ...argv] = process.argv.slice(2),
  opt = {};
for (let i = 0; i < argv.length; i++) {
  const k = argv[i];
  if (!k.startsWith("--") || i + 1 >= argv.length) die(`bad argument: ${k}`);
  opt[k.slice(2).replaceAll("-", "_")] = argv[++i];
}
const json = (f) => {
    try {
      return JSON.parse(fs.readFileSync(f, "utf8"));
    } catch {
      die(`malformed JSON: ${f}`);
    }
  },
  schema = (n) => json(path.join(product, "schemas", n));
const root = () => {
  if (!opt.worktree) die("--worktree is required");
  try {
    return fs.realpathSync(
      execFileSync(
        "git",
        ["-C", opt.worktree, "rev-parse", "--show-toplevel"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      ).trim(),
    );
  } catch {
    die("invalid git worktree");
  }
};
const assertArtifact = (source, name) => {
  if (!source) return;
  let s = schema(name);
  if (name === "review.schema.json") {
    s = { ...s };
    delete s.if;
    delete s.then;
  }
  const errors = validate(s, source.value);
  if (errors.length) die(`${source.kind} schema rejected: ${errors[0]}`);
  if (
    source.kind === "review" &&
    source.value.status === "fail" &&
    (!source.value.findings?.length || !source.value.patch_instructions)
  )
    die("failed review lacks findings or patch instructions");
};
const safeSource = (repo, kind, p) => {
  if (!p) return null;
  let real;
  try {
    real = fs.realpathSync(path.resolve(repo, p));
  } catch {
    die(`${kind} artifact missing`);
  }
  if (real !== repo && !real.startsWith(`${repo}${path.sep}`))
    die(`${kind} artifact escapes project`);
  const rel = path.relative(repo, real).split(path.sep).join("/");
  if (
    rel.startsWith("../") ||
    rel.includes(".env") ||
    /token|secret|password|credential/i.test(rel)
  )
    die(`${kind} artifact path violates privacy allowlist`);
  const raw = fs.readFileSync(real);
  return {
    kind,
    path: rel,
    absolute: real,
    sha256: sha(raw),
    value: json(real),
  };
};
const targetPath = (repo, p, label) => {
  const resolved = path.resolve(repo, p);
  if (resolved !== repo && !resolved.startsWith(`${repo}${path.sep}`))
    die(`${label} must remain target-local`);
  return resolved;
};
const containedPath = (
  repo,
  p,
  label,
  { mustExist = false, createDirectory = false } = {},
) => {
  const resolved = targetPath(repo, p, label);
  let existing = resolved;
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing)
      die(`${label} has no checkable target-local ancestor`);
    existing = parent;
  }
  let existingReal;
  try {
    existingReal = fs.realpathSync(existing);
  } catch {
    die(`${label} has an uncheckable existing component`);
  }
  if (existingReal !== repo && !existingReal.startsWith(`${repo}${path.sep}`))
    die(`${label} existing component escapes project`);
  if (mustExist && existing !== resolved) die(`${label} is required`);
  if (createDirectory) {
    try {
      fs.mkdirSync(resolved, { recursive: true, mode: 0o700 });
    } catch {
      die(`${label} cannot be created`);
    }
  }
  if (fs.existsSync(resolved)) {
    let real;
    try {
      real = fs.realpathSync(resolved);
    } catch {
      die(`${label} is uncheckable`);
    }
    if (real !== repo && !real.startsWith(`${repo}${path.sep}`))
      die(`${label} escapes project`);
    return real;
  }
  return resolved;
};
const validRfc3339 = (value) => parseRfc3339(value) !== null;
const sampleIdentity = (sample) => {
  const identity = {
    project: sample.project_pseudonym,
    issue: sample.issue,
    round: sample.round,
    revision: sample.manifest_revision,
    attempt: sample.attempt,
    role: sample.role,
    task_class: sample.task_class,
    tier: sample.tier,
    model: sample.model,
    effort: sample.effort,
    head: sample.head_sha,
    retry_of: sample.retry_of,
  };
  if (sample.schema_version === "2") {
    identity.schema_version = "2";
    identity.routing = sample.routing;
  }
  return identity;
};
const safeAdmissionKey = (value) => /^issue-[1-9][0-9]*-dispatch-[1-9][0-9]*$/.test(value || "");
const safeRegularFile = (file) => {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
};
const safeDirectory = (directory) => {
  try {
    const stat = fs.lstatSync(directory);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
};
const commonDir = (repo) => {
  let value;
  try {
    value = execFileSync("git", ["-C", repo, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
    }).trim();
  } catch {
    die("cannot resolve git common directory");
  }
  try {
    return fs.realpathSync(path.isAbsolute(value) ? value : path.join(repo, value));
  } catch {
    die("git common directory is uncheckable");
  }
};
const sameRealpath = (left, right) => {
  try {
    return fs.realpathSync(left) === fs.realpathSync(right);
  } catch {
    return false;
  }
};
const telemetryRole = (receiptRole) => ({
  implementation: "implementation",
  reviewer: "review",
  verifier: "verification",
}[receiptRole] || null);
const routedProvenance = ({ repo, round, roundSource, receiptSource, issue, salt }) => {
  const receipt = receiptSource.value;
  if (receipt.schema_version !== "3" || !receipt.routing)
    die("policy telemetry requires a v3 transport receipt");
  if (
    receipt.issue !== issue || !receipt.runtime || !receipt.role || !receipt.routing.selected ||
    !/^[a-f0-9]{64}$/.test(receipt.routing.route_digest || "") ||
    !/^[a-f0-9]{64}$/.test(receipt.routing.policy_digest || "")
  )
    die("transport receipt routing provenance is malformed");
  const role = telemetryRole(receipt.role);
  if (!role) die("transport receipt role is not telemetry-collectable");
  try {
    if (fs.realpathSync(receipt.worktree_path) !== repo)
      die("transport receipt worktree does not match telemetry target");
  } catch {
    die("transport receipt worktree is uncheckable");
  }
  const key = round.round_control?.last_admission_key;
  if (!safeAdmissionKey(key)) die("policy telemetry lacks current admission binding");
  const admissionRoot = path.join(commonDir(repo), "agent-workflow", "redispatch-admissions");
  const admissionDir = path.join(admissionRoot, key);
  const bindingFile = path.join(admissionDir, ".admission-transaction.json");
  if (!safeDirectory(admissionRoot) || !safeDirectory(admissionDir) || !safeRegularFile(bindingFile))
    die("policy telemetry admission binding is missing or unsafe");
  const binding = json(bindingFile);
  const bindingFailures = [
    binding.version !== 1 && "version",
    binding.status !== "committed" && "status",
    String(binding.issue) !== String(issue) && "issue",
    binding.admission_key !== key && "admission_key",
    !sameRealpath(binding.round_state, roundSource.absolute) && "round_state",
    binding.route_digest !== receipt.routing.route_digest && "route_digest",
    !["normal", "integrated"].includes(binding.kind) && "kind",
  ].filter(Boolean);
  if (bindingFailures.length)
    die(`policy telemetry admission binding does not match receipt: ${bindingFailures.join(",")}`);
  if (binding.kind === "integrated") {
    const singletonFile = path.join(admissionRoot, `issue-${issue}-integrated-fix`, ".admission-transaction.json");
    const singletonDir = path.dirname(singletonFile);
    if (!safeDirectory(singletonDir) || !safeRegularFile(singletonFile))
      die("policy telemetry integrated binding is missing or unsafe");
    const singleton = json(singletonFile);
    if (
      singleton.version !== 1 || singleton.status !== "committed" || singleton.kind !== "integrated" ||
      String(singleton.issue) !== String(issue) || singleton.admission_key !== key ||
      !sameRealpath(singleton.round_state, roundSource.absolute) || singleton.route_digest !== binding.route_digest
    )
      die("policy telemetry integrated binding does not match ordinal");
  }
  return {
    selection_basis: receipt.routing.selection_basis,
    route_pseudonym: hmac(salt, receipt.routing.route_digest),
    policy_digest: `sha256:${receipt.routing.policy_digest}`,
    runtime: receipt.runtime,
    decision_reason_codes: receipt.routing.decision_reason_codes,
    model: receipt.routing.selected.model,
    effort: receipt.routing.selected.effort,
    transport: receipt.adapter,
    role,
  };
};
function checkUsage(value) {
  const keys = [
      "kind",
      "input_tokens",
      "output_tokens",
      "cost",
      "currency",
      "source",
      "provenance_version",
    ],
    measureKeys = keys.slice(1),
    versions = /^[A-Za-z0-9._-]{1,64}$/;
  if (!value || Object.keys(value).sort().join() !== [...keys].sort().join())
    die("usage has unknown or missing fields");
  for (const n of ["input_tokens", "output_tokens", "cost"])
    if (value[n] !== null && (!Number.isFinite(value[n]) || value[n] < 0))
      die("usage values must be non-negative or null");
  if (
    value.provenance_version !== null &&
    !versions.test(value.provenance_version)
  )
    die("usage provenance version is not allowlisted");
  if (value.kind === "unavailable") {
    if (measureKeys.some((k) => value[k] !== null))
      die("unavailable usage must remain null");
  } else if (value.kind === "observed") {
    if (
      !Number.isInteger(value.input_tokens) ||
      !Number.isInteger(value.output_tokens) ||
      typeof value.cost !== "number" ||
      value.currency !== "USD" ||
      value.source !== "provider_usage" ||
      !value.provenance_version
    )
      die(
        "observed usage requires allowlisted provider token/cost/pricing provenance",
      );
  } else if (value.kind === "estimated") {
    if (
      typeof value.cost !== "number" ||
      value.currency !== "USD" ||
      !["local_token_estimator", "operator_pricing_estimate"].includes(
        value.source,
      ) ||
      !value.provenance_version
    )
      die(
        "estimated usage requires allowlisted method/version and numeric cost",
      );
  } else die("usage kind must be observed, estimated, or unavailable");
  return value;
}
function collect() {
  const repo = root(),
    roundS = safeSource(repo, "round_state", opt.round_state),
    runS = safeSource(repo, "run", opt.run),
    reviewS = safeSource(repo, "review", opt.review),
    verifyS = safeSource(repo, "verify", opt.verify),
    blockerS = safeSource(repo, "blocker", opt.blocker),
    closureS = safeSource(repo, "candidate_closure", opt.closure),
    integrationS = safeSource(repo, "integration", opt.integration),
    evidenceS = safeSource(repo, "candidate_evidence", opt.evidence_set),
    receiptS = safeSource(repo, "transport_receipt", opt.receipt);
  assertArtifact(roundS, "round_state.schema.json");
  assertArtifact(runS, "run.schema.json");
  assertArtifact(reviewS, "review.schema.json");
  assertArtifact(verifyS, "verify.schema.json");
  assertArtifact(blockerS, "blocker.schema.json");
  assertArtifact(closureS, "candidate_closure.schema.json");
  assertArtifact(integrationS, "integration_result.schema.json");
  assertArtifact(evidenceS, "candidate_evidence_set.schema.json");
  assertArtifact(receiptS, "transport_receipt.schema.json");
  if (opt.route_digest || opt.policy_digest || opt.routing)
    die("raw routing provenance is never accepted from telemetry CLI");
  if (receiptS && (opt.model || opt.effort || opt.transport || opt.runtime || opt.role))
    die("policy telemetry derives role/runtime/model/effort/transport from receipt; omit tuple flags");
  if (closureS && (!integrationS || !evidenceS))
    die("candidate_closure requires canonical integration and evidence sources");
  if (!closureS && (integrationS || evidenceS))
    die("integration and evidence sources require candidate_closure");
  if (verifyS) {
    let canonical = false;
    try {
      execFileSync(
        process.execPath,
        [
          path.join(product, "scripts/lib/verify-result.cjs"),
          "validate-artifact",
          verifyS.absolute,
          path.join(product, "schemas/verify.schema.json"),
          path.join(product, "scripts/lib/json-schema-subset.cjs"),
        ],
        { stdio: "ignore" },
      );
      canonical = true;
    } catch {}
    if (!canonical)
      die("verify artifact failed canonical aggregate validation");
  }
  const round = roundS.value,
    run = runS.value,
    issue = Number(opt.issue),
    revision = Number(opt.manifest_revision),
    attempt = Number(opt.attempt),
    now = Date.now(),
    expectedPaths = {
      round_state: `.review/ISSUE-${issue}-ROUND-STATE.json`,
      run: `.review/ISSUE-${issue}-RUN.json`,
      review: `.review/ISSUE-${issue}-REVIEW.json`,
      verify: `.review/ISSUE-${issue}-VERIFY.json`,
      blocker: `.review/ISSUE-${issue}-BLOCKER.json`,
      candidate_closure: `.review/ISSUE-${issue}-CLOSURE.json`,
      integration: `.review/ISSUE-${issue}-INTEGRATION.json`,
      candidate_evidence: `.review/ISSUE-${issue}-CANDIDATE-EVIDENCE.json`,
      transport_receipt: `.review/ISSUE-${issue}-TRANSPORT.json`,
    };
  for (const s of [
    roundS,
    runS,
    reviewS,
    verifyS,
    blockerS,
    closureS,
    integrationS,
    evidenceS,
    receiptS,
  ].filter(Boolean))
    if (s.path !== expectedPaths[s.kind])
      die(`${s.kind} artifact path is not canonical`);
  if (
    round.lifecycle !== "active" ||
    round.issue?.number !== issue ||
    round.revision !== revision ||
    fs.realpathSync(round.worktree_path) !== repo ||
    round.head_sha !==
      execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], {
        encoding: "utf8",
      }).trim()
  )
    die("ROUND-STATE issue/revision/worktree/HEAD mismatch");
  if (
    run.issue !== issue ||
    run.attempt !== attempt ||
    run.status === "running"
  )
    die("RUN issue/attempt/lifecycle mismatch or nonterminal");
  const start = Date.parse(run.started_at),
    end = Date.parse(run.updated_at);
  if (
    !validRfc3339(run.started_at) ||
    !validRfc3339(run.updated_at) ||
    !Number.isFinite(start) ||
    !Number.isFinite(end) ||
    end < start ||
    end > now + 300000
  )
    die("RUN timestamps are malformed, negative, or future");
  const roundNumber = Number(opt.round),
    liveHead = execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim();
  if (!Number.isInteger(roundNumber) || roundNumber < 0)
    die("round must identify an admitted lineage");
  let terminal = run.status === "exited" ? "transport_exit" : run.status;
  for (const s of [reviewS, verifyS, blockerS].filter(Boolean)) {
    const v = s.value;
    if ((v.issue?.number ?? v.issue) !== issue) die(`${s.kind} issue mismatch`);
    const h = s.kind === "review" ? v.reviewed_head_sha : v.head_sha;
    if (h !== round.head_sha) die(`${s.kind} HEAD mismatch`);
    if (
      (s.kind === "review" && v.lifecycle !== "final") ||
      v.lifecycle === "superseded" ||
      v.lifecycle === "draft"
    )
      die(`${s.kind} lifecycle is not publishable`);
  }
  if (verifyS) {
    if (
      verifyS.value.classifier !== "PASS" ||
      verifyS.value.verdict?.exit_code !== 0
    )
      terminal = "failed";
  } else if (reviewS)
    terminal =
      reviewS.value.status === "blocked"
        ? "blocked"
        : reviewS.value.status === "fail"
          ? "failed"
          : terminal;
  else if (blockerS) terminal = "blocked";
  let closure = null;
  if (closureS) {
    const value = closureS.value,
      integration = integrationS.value,
      evidence = evidenceS.value,
      evaluated = Date.parse(value.evaluated_at),
      integratedAt = Date.parse(integration.created_at),
      evidencedAt = Date.parse(evidence.created_at),
      identityMatches =
        value.issue === issue &&
        value.round === roundNumber &&
        value.manifest_revision === revision &&
        value.candidate_head === liveHead &&
        integration.issue === issue &&
        integration.round === roundNumber &&
        integration.manifest_revision === revision &&
        integration.plan_revision === value.plan_revision &&
        integration.candidate_head === liveHead &&
        evidence.issue === issue &&
        evidence.round === roundNumber &&
        evidence.manifest_revision === revision &&
        evidence.plan_revision === value.plan_revision &&
        evidence.candidate_head === liveHead &&
        evidence.attempt_id === value.attempt_id;
    if (!identityMatches)
      die("candidate dependency issue/round/revision/HEAD mismatch");
    if (
      !validRfc3339(value.evaluated_at) ||
      !validRfc3339(integration.created_at) ||
      !validRfc3339(evidence.created_at)
    )
      die("candidate dependency timestamp is not semantic RFC3339");
    if (
      evaluated > now + 300000 ||
      integratedAt > now + 300000 ||
      evidencedAt > now + 300000
    )
      die("candidate dependency timestamp is future");
    if (
      evidencedAt < integratedAt ||
      evaluated < integratedAt ||
      evaluated < evidencedAt ||
      evaluated < end
    )
      die("candidate_closure is older than admitted run or dependency evidence");
    if (
      value.integration_sha256 !== integrationS.sha256 ||
      value.evidence_set_sha256 !== evidenceS.sha256
    )
      die("candidate_closure dependency digest mismatch");
    if (
      integration.status !== "pass" ||
      !integration.candidate_clean ||
      integration.steps.length === 0 ||
      integration.steps.some((step) => step.status !== "integrated")
    )
      die("candidate integration is not complete");
    if (
      evidence.evidence.some(
        (entry) =>
          entry.status !== "pass" || entry.attempt_id !== evidence.attempt_id,
      )
    )
      die("candidate evidence set is not green or attempt-bound");
    if (
      (value.status === "closed" && value.reason_codes.length !== 0) ||
      (value.status !== "closed" && value.reason_codes.length === 0)
    )
      die("candidate_closure status/reason semantics rejected");
    terminal =
      value.status === "closed"
        ? "green"
        : value.status === "blocked"
          ? "blocked"
          : "failed";
    closure = {
      source: closureS.path,
      sha256: closureS.sha256,
      value,
    };
  }
  let usageRaw;
  try {
    usageRaw = opt.usage
      ? JSON.parse(opt.usage)
      : {
          kind: "unavailable",
          input_tokens: null,
          output_tokens: null,
          cost: null,
          currency: null,
          source: null,
          provenance_version: null,
        };
  } catch {
    die("usage is malformed JSON");
  }
  const usage = checkUsage(usageRaw);
  const saltPath = containedPath(
    repo,
    opt.salt_file || ".agent-workflow/telemetry-salt",
    "salt file",
    { mustExist: true },
  );
  let salt;
  try {
    salt = fs.readFileSync(saltPath);
  } catch {
    die("target-local --salt-file is required");
  }
  const routing = receiptS
    ? routedProvenance({ repo, round, roundSource: roundS, receiptSource: receiptS, issue, salt })
    : null;
  let projectIdentity;
  try {
    projectIdentity = execFileSync(
      "git",
      ["-C", repo, "remote", "get-url", "origin"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
  } catch {
    projectIdentity = execFileSync(
      "git",
      ["-C", repo, "rev-list", "--max-parents=0", "HEAD"],
      { encoding: "utf8" },
    ).trim();
  }
  const project = sha(Buffer.concat([salt, Buffer.from(projectIdentity)])),
    identity = {
      project,
      issue,
      round: roundNumber,
      revision,
      attempt,
      role: routing ? routing.role : opt.role,
      task_class: opt.task_class,
      tier: round.tier?.name,
      model: routing ? routing.model : opt.model,
      effort: routing ? routing.effort : opt.effort,
      head: round.head_sha,
      retry_of: opt.retry_of || "",
    },
    versionedIdentity = routing ? { ...identity, schema_version: "2", routing: {
      selection_basis: routing.selection_basis,
      route_pseudonym: routing.route_pseudonym,
      policy_digest: routing.policy_digest,
      runtime: routing.runtime,
      decision_reason_codes: routing.decision_reason_codes,
    } } : identity,
    sampleId = sha(JSON.stringify(versionedIdentity)),
    artifacts = [
      roundS,
      runS,
      reviewS,
      verifyS,
      blockerS,
      closureS,
      integrationS,
      evidenceS,
      receiptS,
    ]
      .filter(Boolean)
      .map(({ kind, path, sha256 }) => ({ kind, path, sha256 }));
  const sample = {
    schema_version: routing ? "2" : "1",
    artifact_type: "telemetry_sample",
    sample_id: sampleId,
    project_pseudonym: project,
    issue,
    round: roundNumber,
    manifest_revision: revision,
    attempt,
    role: routing ? routing.role : opt.role,
    task_class: opt.task_class,
    tier: round.tier.name,
    model: routing ? routing.model : opt.model,
    effort: routing ? routing.effort : opt.effort,
    base_sha: round.base_sha,
    head_sha: round.head_sha,
    transport: routing ? routing.transport : opt.transport,
    started_at: new Date(start).toISOString(),
    ended_at: new Date(end).toISOString(),
    duration_ms: end - start,
    terminal,
    retry_of: opt.retry_of || "",
    closure,
    artifacts,
    usage,
  };
  if (routing) {
    sample.routing = {
      selection_basis: routing.selection_basis,
      route_pseudonym: routing.route_pseudonym,
      policy_digest: routing.policy_digest,
      runtime: routing.runtime,
      decision_reason_codes: routing.decision_reason_codes,
    };
  }
  const errors = validate(schema("telemetry_sample.schema.json"), sample);
  if (errors.length) die(`sample schema rejected: ${errors[0]}`);
  const store = containedPath(
    repo,
    opt.store || ".agent-workflow/telemetry/samples",
    "telemetry store",
    { createDirectory: true },
  );
  const dest = path.join(store, `${sampleId}.json`),
    body = `${JSON.stringify(sample, null, 2)}\n`,
    temporary = path.join(store, `.${sampleId}.tmp-${process.pid}`);
  fs.writeFileSync(temporary, body, { flag: "wx", mode: 0o600 });
  try {
    try {
      fs.linkSync(temporary, dest);
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      const old = fs.readFileSync(dest, "utf8");
      if (old !== body) die("conflicting sample rewrite refused", 1);
    }
  } finally {
    try {
      fs.unlinkSync(temporary);
    } catch {}
  }
  console.log(`${sampleId}\t${path.relative(repo, dest)}`);
}
function report() {
  const repo = root(),
    from = Date.parse(opt.from),
    to = Date.parse(opt.to),
    minimum = Number(opt.minimum_samples),
    threshold = Number(opt.minimum_completeness);
  if (
    !Number.isFinite(from) ||
    !Number.isFinite(to) ||
    from >= to ||
    !Number.isInteger(minimum) ||
    minimum < 1 ||
    !Number.isFinite(threshold) ||
    threshold < 0 ||
    threshold > 1
  )
    die(
      "report requires valid --from/--to/--minimum-samples/--minimum-completeness",
    );
  const dir = containedPath(
      repo,
      opt.store || ".agent-workflow/telemetry/samples",
      "telemetry store",
    ),
    samples = [],
    sampleSchema = schema("telemetry_sample.schema.json"),
    closureSchema = schema("candidate_closure.schema.json");
  for (const name of fs.existsSync(dir)
    ? fs
        .readdirSync(dir)
        .filter((n) => /^[0-9a-f]{64}\.json$/.test(n))
        .sort()
    : []) {
    const s = json(path.join(dir, name)),
      errors = validate(sampleSchema, s);
    if (errors.length || `${s.sample_id}.json` !== name)
      die(`stored sample rejected: ${name}`);
    const t = Date.parse(s.started_at);
    if (t >= from && t < to) samples.push(s);
  }
  const byId = new Map(samples.map((s) => [s.sample_id, s])),
    groups = new Map();
  for (const s of samples) {
    if (sha(JSON.stringify(sampleIdentity(s))) !== s.sample_id)
      die(`stored sample identity rejected: ${s.sample_id}`);
    const closureErrors = validateTelemetrySampleClosure(s, closureSchema, validate);
    if (closureErrors.length)
      die(`stored sample semantic rejected: ${s.sample_id}: ${closureErrors[0]}`);
    const id = sha(
      JSON.stringify({
        project: s.project_pseudonym,
        issue: s.issue,
        round: s.round,
        manifest_revision: s.manifest_revision,
      }),
    );
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(s);
  }
  const chains = [...groups.entries()].sort().map(([id, list]) => {
    list.sort(
      (a, b) =>
        a.attempt - b.attempt ||
        a.started_at.localeCompare(b.started_at) ||
        a.sample_id.localeCompare(b.sample_id),
    );
    const first = list[0],
      sameLineage = list.every(
        (s) =>
          s.project_pseudonym === first.project_pseudonym &&
          s.issue === first.issue &&
          s.round === first.round &&
          s.manifest_revision === first.manifest_revision,
      ),
      contiguousCoverage = list.every((s, index) => s.attempt === index + 1),
      validRetryEdges =
        list[0].attempt === 1 &&
        list[0].retry_of === "" &&
        list
          .slice(1)
          .every(
            (s, index) =>
              s.retry_of === list[index].sample_id &&
              byId.get(s.retry_of)?.issue === s.issue,
          ),
      green =
        list[list.length - 1].terminal === "green" &&
        list[list.length - 1].closure?.value.status === "closed",
      available = list.filter((s) => s.usage.kind !== "unavailable").length,
      models = [...new Set(list.map((s) => s.model))],
      allocationMode = models.length === 1 ? "single_model" : "mixed_model";
    return {
      chain_id: id,
      project_pseudonym: list[0].project_pseudonym,
      issue: list[0].issue,
      round: list[0].round,
      manifest_revision: list[0].manifest_revision,
      sample_ids: list.map((s) => s.sample_id),
      green,
      complete: sameLineage && contiguousCoverage && validRetryEdges && green,
      attempts: list.length,
      retries: Math.max(0, list.length - 1),
      wall_time_ms:
        Math.max(...list.map((s) => Date.parse(s.ended_at))) -
        Math.min(...list.map((s) => Date.parse(s.started_at))),
      roles: [...new Set(list.map((s) => s.role))].sort(),
      allocation_mode: allocationMode,
      allocations: list.map((s) => ({
        attempt: s.attempt,
        role: s.role,
        task_class: s.task_class,
        tier: s.tier,
        model: s.model,
        effort: s.effort,
        usage_kind: s.usage.kind,
      })),
      observed_cost: list
        .filter((s) => s.usage.kind === "observed")
        .reduce((n, s) => n + s.usage.cost, 0),
      estimated_cost: list
        .filter((s) => s.usage.kind === "estimated")
        .reduce((n, s) => n + s.usage.cost, 0),
      unavailable_samples: list.length - available,
      usage_completeness: list.length ? available / list.length : 0,
    };
  });
  const cohortMap = new Map();
  const suppressed = [];
  for (const chain of chains) {
    if (chain.allocation_mode === "mixed_model") {
      suppressed.push(`mixed-model:${chain.chain_id}`);
      continue;
    }
    const first = byId.get(chain.sample_ids[0]),
      key = [first.task_class, first.tier, first.model, first.effort].join("|");
    if (!cohortMap.has(key)) cohortMap.set(key, []);
    cohortMap.get(key).push(chain);
  }
  const cohorts = [];
  for (const [key, list] of [...cohortMap.entries()].sort()) {
    const total = list.reduce((n, c) => n + c.attempts, 0),
      available = list.reduce(
        (n, c) => n + c.attempts - c.unavailable_samples,
        0,
      ),
      ratio = total ? available / total : 0;
    if (total < minimum || ratio < threshold) {
      suppressed.push(key);
      continue;
    }
    cohorts.push({
      key,
      sample_count: total,
      chain_count: list.length,
      complete_green_chains: list.filter((c) => c.complete).length,
      observed_cost: list.reduce((n, c) => n + c.observed_cost, 0),
      estimated_cost: list.reduce((n, c) => n + c.estimated_cost, 0),
      unavailable_samples: total - available,
      usage_completeness: ratio,
    });
  }
  const routingCohortMap = new Map(),
    hasRoutingSamples = samples.some((s) => s.schema_version === "2");
  for (const chain of chains) {
    const list = chain.sample_ids.map((id) => byId.get(id));
    if (!list.some((s) => s.schema_version === "2")) continue;
    const first = list[0],
      routingSignature = JSON.stringify({
        selection_basis: first.routing?.selection_basis,
        policy_digest: first.routing?.policy_digest,
        runtime: first.routing?.runtime,
        decision_reason_codes: first.routing?.decision_reason_codes,
      }),
      tupleSignature = JSON.stringify({
        role: first.role, task_class: first.task_class, tier: first.tier,
        model: first.model, effort: first.effort,
      });
    if (
      !list.every((s) => s.schema_version === "2") ||
      !list.every((s) => JSON.stringify({
        selection_basis: s.routing?.selection_basis,
        policy_digest: s.routing?.policy_digest,
        runtime: s.routing?.runtime,
        decision_reason_codes: s.routing?.decision_reason_codes,
      }) === routingSignature) ||
      !list.every((s) => JSON.stringify({
        role: s.role, task_class: s.task_class, tier: s.tier,
        model: s.model, effort: s.effort,
      }) === tupleSignature)
    ) {
      suppressed.push(`routing-inhomogeneous:${chain.chain_id}`);
      continue;
    }
    const key = [
      first.routing.selection_basis, first.routing.policy_digest,
      first.routing.runtime, first.role,
      first.task_class, first.tier, first.model, first.effort,
    ].join("|");
    if (!routingCohortMap.has(key)) routingCohortMap.set(key, []);
    routingCohortMap.get(key).push(chain);
  }
  const routingCohorts = [];
  for (const [key, list] of [...routingCohortMap.entries()].sort()) {
    const firstChain = list[0],
      first = byId.get(firstChain.sample_ids[0]),
      total = list.reduce((n, c) => n + c.attempts, 0),
      available = list.reduce((n, c) => n + c.attempts - c.unavailable_samples, 0),
      ratio = total ? available / total : 0,
      completeIndependent = list.filter((c) => c.complete).length;
    if (completeIndependent < minimum || ratio < threshold) {
      suppressed.push(`routing:${key}`);
      continue;
    }
    routingCohorts.push({
      key,
      selection_basis: first.routing.selection_basis,
      policy_digest: first.routing.policy_digest,
      runtime: first.routing.runtime,
      role: first.role,
      task_class: first.task_class,
      tier: first.tier,
      model: first.model,
      effort: first.effort,
      sample_count: total,
      chain_count: list.length,
      complete_independent_chains: completeIndependent,
      observed_cost: list.reduce((n, c) => n + c.observed_cost, 0),
      estimated_cost: list.reduce((n, c) => n + c.estimated_cost, 0),
      unavailable_samples: total - available,
      usage_completeness: ratio,
    });
  }
  const out = {
    schema_version: hasRoutingSamples ? "2" : "1",
    artifact_type: "telemetry_report",
    window: {
      from: new Date(from).toISOString(),
      to: new Date(to).toISOString(),
    },
    policy: hasRoutingSamples
      ? { minimum_samples: minimum, minimum_complete_independent_chains: minimum, minimum_completeness: threshold }
      : { minimum_samples: minimum, minimum_completeness: threshold },
    samples: samples.length,
    chains,
    cohorts,
    suppressed_cohorts: suppressed,
    interpretation: hasRoutingSamples
      ? "Advisory local evidence only. No-green and incomplete chains remain visible. Observed and estimated costs are separate; unavailable is never zero. Routing cohorts describe associations, not causal improvement; confounders remain. Only homogeneous schema-v2 policy samples form routing cohorts, and insufficient evidence is suppressed. This command never mutates model allocation or tier policy."
      : "Advisory local evidence only. No-green and incomplete chains remain visible. Observed and estimated costs are separate; unavailable is never zero. This command never mutates model allocation or tier policy.",
  };
  if (hasRoutingSamples) out.routing_cohorts = routingCohorts;
  const errors = validate(schema("telemetry_report.schema.json"), out);
  if (errors.length) die(`report schema rejected: ${errors[0]}`);
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
}
function erase() {
  const repo = root();
  if (!/^[0-9a-f]{64}$/.test(opt.sample_id || "") || opt.confirm !== "DELETE")
    die("delete requires exact --sample-id and --confirm DELETE");
  const dir = containedPath(
      repo,
      opt.store || ".agent-workflow/telemetry/samples",
      "telemetry store",
    ),
    target = path.join(dir, `${opt.sample_id}.json`);
  if (!target.startsWith(`${dir}${path.sep}`) || !fs.existsSync(target))
    die("scoped sample does not exist");
  fs.unlinkSync(target);
  console.log(`deleted ${opt.sample_id}`);
}
if (command === "collect") collect();
else if (command === "report") report();
else if (command === "delete") erase();
else die("usage: telemetry.sh collect|report|delete ...");
