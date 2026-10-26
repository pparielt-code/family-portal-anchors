#!/usr/bin/env node
/**
 * Сверка внешнего якоря с текущим состоянием базы (ADR-013, шаг 2).
 *
 * Что проверяет и почему именно это:
 *  - `chainLength` не уменьшился. Уменьшение — единственный случай, ради которого якорь
 *    существует: валидное подмножество цепочки остаётся валидным, и сводка честно скажет
 *    `COHERENT`, хотя часть истории исчезла.
 *  - при том же счёте головы те же. Иначе новейшие манифесты удалили и добавили другие.
 *  - `sequence` без пропусков и дублей. Пропуск = запись из журнала удалена.
 *  - текущий вердикт `COHERENT`. `UNPROVEN` означает, что часть манифестов судить нельзя
 *    (подпись не сходится, ключ отозван) — это не «в порядке».
 *
 * Коды выхода: 0 — сходится, 1 — расхождение, 2 — судить нельзя.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const LOG_PATH = "anchors/anchor-log.jsonl";
const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--api") args.api = argv[++i];
    else if (arg === "--token") args.token = argv[++i];
    else if (arg === "--from") args.from = argv[++i];
    else if (arg === "--log") args.log = argv[++i];
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`неизвестный аргумент: ${arg}`);
  }
  return args;
}

async function fetchSummary(args) {
  if (args.from) return JSON.parse(readFileSync(args.from, "utf8"));
  if (!args.api) throw new Error("нужен --api или --from");
  const token = args.token ?? process.env.FP_TOKEN;
  if (!token) throw new Error("нужен --token или переменная FP_TOKEN");
  const url = `${args.api.replace(/\/$/, "")}/integrity/chain`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${token}`, accept: "application/json" },
  });
  if (!response.ok) throw new Error(`GET /integrity/chain → HTTP ${response.status}`);
  return response.json();
}

function readLog(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

function main2(summary, records) {
  const problems = [];

  for (let i = 0; i < records.length; i += 1) {
    const expected = i + 1;
    if (records[i].sequence !== expected) {
      problems.push(
        `журнал: на позиции ${i + 1} стоит sequence ${records[i].sequence} — номер сдвинут или запись удалена`,
      );
    }
  }

  const last = records[records.length - 1];
  if (summary.verdict !== "COHERENT") {
    problems.push(
      `вердикт ${summary.verdict}: цепочка не сходится — сверка якоря не имеет смысла до устранения`,
    );
  }
  if (summary.manifestCount < last.chainLength) {
    problems.push(
      `УДАЛЕНИЕ: манифестов ${summary.manifestCount}, в якоре (sequence ${last.sequence}) было ${last.chainLength}`,
    );
  }
  const currentHeads = new Set(summary.headIds ?? []);
  const anchorHeads = last.headIds ?? [];
  if (
    summary.manifestCount === last.chainLength &&
    anchorHeads.length > 0 &&
    anchorHeads.some((id) => !currentHeads.has(id))
  ) {
    problems.push(
      `голова заменена при том же счёте (${summary.manifestCount}): новейшие манифесты удалены и добавлены другие`,
    );
  }

  console.log(`записей в якоре: ${records.length}, последняя sequence ${last.sequence}`);
  console.log(`в якоре: ${last.chainLength} манифестов, головы ${last.headIds.join(", ") || "—"}`);
  console.log(`в базе:  ${summary.manifestCount} манифестов, вердикт ${summary.verdict}`);
  console.log(`головы:  ${(summary.headIds ?? []).join(", ") || "—"}`);

  if (problems.length === 0) {
    console.log("СХОДИТСЯ");
    return 0;
  }
  console.error("РАСХОЖДЕНИЕ:");
  for (const problem of problems) console.error(`  - ${problem}`);
  return 1;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`Сверка якоря с базой.

  node tools/verify-anchor.mjs --api <base-url> --token <token>
  node tools/verify-anchor.mjs --from <summary.json> [--log <path>]`);
    return 0;
  }

  const records = readLog(args.log ?? join(ROOT, LOG_PATH));
  if (records.length === 0) {
    console.error("Записей в якоре нет — сверять нечего. Это не успех, это отсутствие проверки.");
    return 2;
  }

  const summary = await fetchSummary(args);
  if (summary.verdict === "EMPTY" || summary.verdict === "TOO_LARGE") {
    console.error(`Вердикт ${summary.verdict}: сводка не состоялась, сверка невозможна.`);
    return 2;
  }
  return main2(summary, records);
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    console.error(`ОШИБКА: ${error.message}`);
    process.exit(2);
  });
