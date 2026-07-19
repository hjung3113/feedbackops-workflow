"use strict";

// Dependency-free validator for the draft-07 keyword subset used by this toolkit.
// Unknown assertion keywords fail closed so schema growth cannot silently bypass gates.

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
  "minLength",
  "pattern",
  "minItems",
  "uniqueItems",
]);

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function valueType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
}

function validate(schema, value, path = "$") {
  const errors = [];

  for (const keyword of Object.keys(schema)) {
    if (!supported.has(keyword)) {
      errors.push(`${path}: unsupported schema keyword ${keyword}`);
    }
  }
  if (errors.length > 0) return errors;

  if (Object.prototype.hasOwnProperty.call(schema, "const") && !same(value, schema.const)) {
    errors.push(`${path}: must equal ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum && !schema.enum.some((candidate) => same(value, candidate))) {
    errors.push(`${path}: must be one of ${JSON.stringify(schema.enum)}`);
  }

  if (schema.type) {
    const actual = valueType(value);
    const matches = schema.type === "number"
      ? actual === "number" || actual === "integer"
      : actual === schema.type;
    if (!matches) {
      errors.push(`${path}: must be ${schema.type}, got ${actual}`);
      return errors;
    }
  }

  if (schema.type === "object") {
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
    for (const [name, childSchema] of Object.entries(properties)) {
      if (Object.prototype.hasOwnProperty.call(value, name)) {
        errors.push(...validate(childSchema, value[name], `${path}.${name}`));
      }
    }
  }

  if (schema.type === "array") {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path}: must contain at least ${schema.minItems} items`);
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
      value.forEach((item, index) => errors.push(...validate(schema.items, item, `${path}[${index}]`)));
    }
  }

  if (schema.type === "string") {
    if (schema.minLength !== undefined && Array.from(value).length < schema.minLength) {
      errors.push(`${path}: must contain at least ${schema.minLength} characters`);
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(value)) {
      errors.push(`${path}: must match ${schema.pattern}`);
    }
  }

  if ((schema.type === "integer" || schema.type === "number")
      && schema.minimum !== undefined && value < schema.minimum) {
    errors.push(`${path}: must be at least ${schema.minimum}`);
  }

  return errors;
}

module.exports = { validate };
