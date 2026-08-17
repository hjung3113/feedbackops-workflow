"use strict";

// Validator for the draft-07 keyword subset used by this toolkit.
// Unknown assertion keywords fail closed so schema growth cannot silently bypass gates.
// Node stdlib plus the intra-lib sameJson predicate are its only dependencies.

const { sameJson } = require("./contract-validators.cjs");

const supported = new Set([
  "$schema",
  "title",
  "description",
  "type",
  "const",
  "enum",
  "required",
  "additionalProperties",
  "properties",
  "items",
  "minimum",
  "maximum",
  "minLength",
  "pattern",
  "minItems",
  "maxItems",
  "uniqueItems",
  "minProperties",
  "definitions",
  "$ref",
  "allOf",
  "oneOf",
  "not",
]);

function valueType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
}

function validate(schema, value, path = "$", root = schema) {
  const errors = [];

  for (const keyword of Object.keys(schema)) {
    if (!supported.has(keyword)) {
      errors.push(`${path}: unsupported schema keyword ${keyword}`);
    }
  }
  if (errors.length > 0) return errors;

  if (schema.$ref) {
    const match = /^#\/definitions\/([^/]+)$/.exec(schema.$ref);
    if (!match || !root.definitions || !root.definitions[match[1]]) {
      return [`${path}: unresolved schema reference ${schema.$ref}`];
    }
    return validate(root.definitions[match[1]], value, path, root);
  }

  if (schema.allOf) {
    for (const member of schema.allOf) errors.push(...validate(member, value, path, root));
  }
  if (schema.oneOf) {
    const branchErrors = schema.oneOf.map((member) => validate(member, value, path, root));
    const matching = branchErrors.filter((messages) => messages.length === 0).length;
    if (matching !== 1) {
      errors.push(`${path}: must match exactly one oneOf branch, matched ${matching}`);
      for (const messages of branchErrors) errors.push(...messages);
    }
  }
  if (schema.not && validate(schema.not, value, path, root).length === 0) {
    errors.push(`${path}: must not match forbidden schema`);
  }

  if (Object.prototype.hasOwnProperty.call(schema, "const") && !sameJson(value, schema.const)) {
    errors.push(`${path}: must equal ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum && !schema.enum.some((candidate) => sameJson(value, candidate))) {
    errors.push(`${path}: must be one of ${JSON.stringify(schema.enum)}`);
  }

  if (schema.type) {
    const actual = valueType(value);
    const acceptedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    const matches = acceptedTypes.some((candidate) => candidate === "number"
      ? actual === "number" || actual === "integer"
      : actual === candidate);
    if (!matches) {
      errors.push(`${path}: must be ${acceptedTypes.join(" or ")}, got ${actual}`);
      return errors;
    }
  }

  const actualType = valueType(value);
  const hasType = (type) => schema.type === type
    || (Array.isArray(schema.type) && schema.type.includes(type));

  if (hasType("object") && actualType === "object") {
    const properties = schema.properties || {};
    for (const name of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(value, name)) {
        errors.push(`${path}: missing required property ${name}`);
      }
    }
    if (schema.additionalProperties === false) {
      for (const name of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(properties, name)) {
          errors.push(`${path}: unexpected property ${name}`);
        }
      }
    }
    if (schema.minProperties !== undefined && Object.keys(value).length < schema.minProperties) {
      errors.push(`${path}: must contain at least ${schema.minProperties} properties`);
    }
    for (const [name, childSchema] of Object.entries(properties)) {
      if (Object.prototype.hasOwnProperty.call(value, name)) {
        errors.push(...validate(childSchema, value[name], `${path}.${name}`, root));
      }
    }
    if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
      for (const name of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(properties, name)) {
          errors.push(...validate(schema.additionalProperties, value[name], `${path}.${name}`, root));
        }
      }
    }
  }

  if (hasType("array") && actualType === "array") {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path}: must contain at least ${schema.minItems} items`);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      errors.push(`${path}: must contain at most ${schema.maxItems} items`);
    }
    if (schema.uniqueItems) {
      const seen = new Set();
      for (const item of value) {
        const key = JSON.stringify(item);
        if (seen.has(key)) errors.push(`${path}: must not contain duplicate items`);
        seen.add(key);
      }
    }
    if (schema.items) {
      value.forEach((item, index) => errors.push(...validate(schema.items, item, `${path}[${index}]`, root)));
    }
  }

  if (hasType("string") && actualType === "string") {
    if (schema.minLength !== undefined && Array.from(value).length < schema.minLength) {
      errors.push(`${path}: must contain at least ${schema.minLength} characters`);
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(value)) {
      errors.push(`${path}: must match ${schema.pattern}`);
    }
  }

  if ((hasType("integer") || hasType("number"))
      && (actualType === "integer" || actualType === "number")
      && schema.minimum !== undefined && value < schema.minimum) {
    errors.push(`${path}: must be at least ${schema.minimum}`);
  }
  if ((hasType("integer") || hasType("number"))
      && (actualType === "integer" || actualType === "number")
      && schema.maximum !== undefined && value > schema.maximum) {
    errors.push(`${path}: must be at most ${schema.maximum}`);
  }

  return errors;
}

module.exports = { validate };
