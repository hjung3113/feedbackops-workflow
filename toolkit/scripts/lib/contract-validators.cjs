#!/usr/bin/env node
"use strict";
// Shared contract-validation predicates — the single import surface for
// checks that were previously copy-pasted across toolkit scripts.
// The model-family regex and effort enums are owned by runtime-registry.cjs;
// this module re-exports effortValid for a uniform import surface and must
// never redefine them.
const { effortValid } = require("./runtime-registry.cjs");

module.exports = { effortValid };
