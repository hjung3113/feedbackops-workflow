"use strict";

const { parseRfc3339 } = require("./rfc3339.cjs");

function validateTelemetrySampleClosure(sample, closureSchema, validate) {
  const errors = [];
  const artifacts = Array.isArray(sample?.artifacts) ? sample.artifacts : [];
  const byKind = (kind) => artifacts.filter((artifact) => artifact.kind === kind);
  const closureArtifacts = byKind("candidate_closure");
  const integrationArtifacts = byKind("integration");
  const evidenceArtifacts = byKind("candidate_evidence");
  const receiptArtifacts = byKind("transport_receipt");
  if (sample?.schema_version === "2") {
    const expectedReceipt = `.review/ISSUE-${sample.issue}-TRANSPORT.json`;
    if (receiptArtifacts.length !== 1 || receiptArtifacts[0]?.path !== expectedReceipt)
      errors.push("routing_receipt_artifact_missing_or_mismatched");
  } else if (receiptArtifacts.length) {
    errors.push("legacy_sample_has_routing_receipt");
  }
  if (sample?.closure === null) {
    if (closureArtifacts.length || integrationArtifacts.length || evidenceArtifacts.length || sample.terminal === "green") errors.push("closure_absence_mismatch");
    return errors;
  }
  const closure = sample?.closure;
  const value = closure?.value;
  if (!closure || !value || validate(closureSchema, value).length) errors.push("closure_schema_invalid");
  if (closureArtifacts.length !== 1 || integrationArtifacts.length !== 1 || evidenceArtifacts.length !== 1) errors.push("closure_dependency_artifacts_missing_or_duplicated");
  if (!value) return errors;
  const expected = {
    closure: `.review/ISSUE-${sample.issue}-CLOSURE.json`,
    integration: `.review/ISSUE-${sample.issue}-INTEGRATION.json`,
    evidence: `.review/ISSUE-${sample.issue}-CANDIDATE-EVIDENCE.json`,
  };
  const closureArtifact = closureArtifacts[0];
  const integrationArtifact = integrationArtifacts[0];
  const evidenceArtifact = evidenceArtifacts[0];
  if (closure.source !== expected.closure || closureArtifact?.path !== expected.closure) errors.push("closure_path_mismatch");
  if (integrationArtifact?.path !== expected.integration || evidenceArtifact?.path !== expected.evidence) errors.push("closure_dependency_path_mismatch");
  if (closureArtifact?.sha256 !== closure.sha256) errors.push("closure_digest_mismatch");
  if (integrationArtifact?.sha256 !== value.integration_sha256) errors.push("integration_digest_mismatch");
  if (evidenceArtifact?.sha256 !== value.evidence_set_sha256) errors.push("candidate_evidence_digest_mismatch");
  if (value.issue !== sample.issue || value.round !== sample.round || value.manifest_revision !== sample.manifest_revision || value.candidate_head !== sample.head_sha) errors.push("closure_identity_mismatch");
  if (parseRfc3339(value.evaluated_at) === null) errors.push("closure_timestamp_invalid");
  const closed = value.status === "closed";
  if ((closed && value.reason_codes.length !== 0) || (!closed && value.reason_codes.length === 0) || (sample.terminal === "green") !== closed) errors.push("closure_terminal_mismatch");
  return errors;
}

module.exports = { validateTelemetrySampleClosure };
