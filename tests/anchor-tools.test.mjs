#!/usr/bin/env node
/**
 * Тесты инструментов якоря. Без сети и без git: всё через `--from`, `--dry-run` и `--out`.
 *
 * Проверяется то, из-за чего якорь может стать хуже, чем его отсутствие:
 *  - запись ставится только на `COHERENT` (EMPTY и BROKEN не якорятся);
 *  - при повторном состоянии запись не плодится;
 *  - удаление манифестов ловится сверкой, а не проглатывается;
 *  - замена головы при том же счёте ловится;
 *  - пропуск в `sequence` виден.
 *
 * Запуск: node --test tests/
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const RECORD = join(ROOT, "tools", "record-anchor.mjs");
const VERIFY = join(ROOT, "tools", "verify-anchor.mjs");
const FIXTURES = join(ROOT, "tests", "fixtures");

function run(script, args) {
  const result = spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
  return { code: result.status, out: result.stdout ?? "", err: result.stderr ?? "" };
}

function workspace() {
  return mkdtempSync(join(tmpdir(), "anchor-test-"));
}

function writeLog(dir, records) {
  const path = join(dir, "anchor-log.jsonl");
  writeFileSync(path, records.map((r) => `${JSON.stringify(r)}\n`).join(""), "utf8");
  return path;
}

test("COHERENT якорится: запись содержит только белый список полей", () => {
  const dir = workspace();
  const out = join(dir, "log.jsonl");
  const result = run(RECORD, [
    "--from",
    join(FIXTURES, "coherent-two.json"),
    "--out",
    out,
    "--no-push",
  ]);

  assert.equal(result.code, 0, result.err);
  const record = JSON.parse(readFileSync(out, "utf8").trim());
  assert.equal(record.anchorVersion, 1);
  assert.equal(record.sequence, 1);
  assert.equal(record.chainLength, 2);
  assert.deepEqual(record.manifestIds, ["m-002"]);
  assert.deepEqual(record.headIds, ["m-002"]);
  assert.deepEqual(record.rootIds, ["m-001"]);
  assert.equal(record.verdict, "COHERENT");

  // Белый список: ничего лишнего из ответа API в якорь не просочилось.
  const allowed = [
    "anchorVersion",
    "sequence",
    "manifestIds",
    "chainLength",
    "rootIds",
    "headIds",
    "verdict",
    "checkedAt",
    "writtenAt",
  ];
  assert.deepEqual(Object.keys(record).sort(), [...allowed].sort());
});

test("EMPTY не якорится — это отсутствие проверки, а не успех", () => {
  const dir = workspace();
  const result = run(RECORD, ["--from", join(FIXTURES, "empty.json"), "--out", join(dir, "l.jsonl")]);
  assert.equal(result.code, 1);
  assert.match(result.err, /EMPTY|ОТКАЗ/);
});

test("BROKEN не якорится: якорь закрепил бы расхождение как норму", () => {
  const dir = workspace();
  const result = run(RECORD, ["--from", join(FIXTURES, "broken.json"), "--out", join(dir, "l.jsonl")]);
  assert.equal(result.code, 1);
  assert.match(result.err, /ОТКАЗ/);
});

test("повторное состояние не плодит запись", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-002"],
      chainLength: 2,
      rootIds: ["m-001"],
      headIds: ["m-002"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T10:00:00.000Z",
      writtenAt: "2026-11-01T10:03:12.000Z",
    },
  ]);
  const result = run(RECORD, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 3, result.err);
  assert.match(result.err, /Новых голов нет/);

  // Журнал не вырос: одна запись осталась одной.
  const lines = readFileSync(log, "utf8").trim().split("\n");
  assert.equal(lines.length, 1);
});

test("импорт, уменьшивший счёт, отвергается, а не записывается", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-003"],
      chainLength: 3,
      rootIds: ["m-001"],
      headIds: ["m-003"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T09:00:00.000Z",
      writtenAt: "2026-11-01T09:01:00.000Z",
    },
  ]);
  const result = run(RECORD, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 1);
  assert.match(result.err, /ОТКАЗ/);
});

test("сверка: сходится", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-002"],
      chainLength: 2,
      rootIds: ["m-001"],
      headIds: ["m-002"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T10:00:00.000Z",
      writtenAt: "2026-11-01T10:03:12.000Z",
    },
  ]);
  const result = run(VERIFY, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 0, result.err);
  assert.match(result.out, /СХОДИТСЯ/);
});

test("сверка ловит удаление манифестов", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-003"],
      chainLength: 3,
      rootIds: ["m-001"],
      headIds: ["m-003"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T10:00:00.000Z",
      writtenAt: "2026-11-01T10:03:12.000Z",
    },
  ]);
  const result = run(VERIFY, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 1);
  assert.match(result.err, /УДАЛЕНИЕ/);
});

test("сверка ловит замену головы при том же счёте", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-555"],
      chainLength: 2,
      rootIds: ["m-001"],
      headIds: ["m-555"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T10:00:00.000Z",
      writtenAt: "2026-11-01T10:03:12.000Z",
    },
  ]);
  const result = run(VERIFY, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 1);
  assert.match(result.err, /голова заменена/);
});

test("сверка ловит пропуск sequence", () => {
  const dir = workspace();
  const log = writeLog(dir, [
    {
      anchorVersion: 1,
      sequence: 1,
      manifestIds: ["m-001"],
      chainLength: 1,
      rootIds: ["m-001"],
      headIds: ["m-001"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T09:00:00.000Z",
      writtenAt: "2026-11-01T09:01:00.000Z",
    },
    {
      anchorVersion: 1,
      sequence: 3,
      manifestIds: ["m-002"],
      chainLength: 2,
      rootIds: ["m-001"],
      headIds: ["m-002"],
      verdict: "COHERENT",
      checkedAt: "2026-11-01T10:00:00.000Z",
      writtenAt: "2026-11-01T10:03:12.000Z",
    },
  ]);
  const result = run(VERIFY, ["--from", join(FIXTURES, "coherent-two.json"), "--log", log]);
  assert.equal(result.code, 1);
  assert.match(result.err, /sequence/);
});

test("сверка без журнала — это не успех", () => {
  const dir = workspace();
  const result = run(VERIFY, [
    "--from",
    join(FIXTURES, "coherent-two.json"),
    "--log",
    join(dir, "absent.jsonl"),
  ]);
  assert.equal(result.code, 2);
  assert.match(result.err, /нечего/);
});
