#!/usr/bin/env node
/**
 * Запись внешнего якоря цепочки манифестов (ADR-013, шаг 2).
 *
 * Что делает: читает состояние цепочки через `GET /api/v1/integrity/chain`, строит запись
 * из БЕЛОГО СПИСКА полей и дописывает её строкой в `anchors/anchor-log.jsonl`, затем коммитит
 * и пушит. Запись не переписывается никогда — только добавление.
 *
 * Почему белый список, а не «сохранить ответ как есть»: якорь лежит вне контура, где живут
 * персональные данные, поэтому в него обязаны попадать только идентификаторы, счётчики и метки
 * времени. Поле, добавленное в API позже, не просочится сюда само.
 *
 * Коды выхода: 0 — запись сделана (или было нечего писать), 1 — отказ по существу,
 * 2 — ошибка окружения, 3 — новых голов нет (запись не нужна).
 */
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ANCHOR_VERSION = 1;
const LOG_PATH = "anchors/anchor-log.jsonl";
const ACCEPTABLE_VERDICT = "COHERENT";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

function parseArgs(argv) {
  const args = { dryRun: false, noPush: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--api") args.api = argv[++i];
    else if (arg === "--token") args.token = argv[++i];
    else if (arg === "--from") args.from = argv[++i];
    else if (arg === "--out") args.out = argv[++i];
    else if (arg === "--log") args.log = argv[++i];
    else if (arg === "--dry-run") args.dryRun = true;
    else if (arg === "--no-push") args.noPush = true;
    else if (arg === "--help" || arg === "-h") args.help = true;
    else throw new Error(`неизвестный аргумент: ${arg}`);
  }
  return args;
}

function usage() {
  console.log(`Запись якоря цепочки манифестов.

  node tools/record-anchor.mjs --api <base-url> --token <token> [--dry-run] [--no-push]
  node tools/record-anchor.mjs --from <summary.json> [--dry-run] [--no-push]

  --api      база API, например https://family.waibcraft.ru/api/v1
  --token    токен с правом integrity.summarize (или переменная FP_TOKEN)
  --from     сохранённый JSON-ответ GET /chain (офлайн, без сети)
  --out      перезаписать файл журнала целиком (для тестов и первичной установки)
  --log      путь к журналу вместо anchors/anchor-log.jsonl (для тестов)
  --dry-run  показать запись, ничего не записывая
  --no-push  закоммитить локально, но не пушить`);
}

async function fetchSummary(args) {
  if (args.from) {
    return JSON.parse(readFileSync(args.from, "utf8"));
  }
  if (!args.api) throw new Error("нужен --api или --from");
  const token = args.token ?? process.env.FP_TOKEN;
  if (!token) throw new Error("нужен --token или переменная FP_TOKEN");

  const url = `${args.api.replace(/\/$/, "")}/integrity/chain`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${token}`, accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`GET /integrity/chain → HTTP ${response.status}: ${await response.text()}`);
  }
  return response.json();
}

/** Последняя запись журнала или null, если журнала ещё нет. */
function readLog(path) {
  if (!existsSync(path)) return [];
  const text = readFileSync(path, "utf8");
  const records = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    records.push(JSON.parse(trimmed));
  }
  return records;
}

/**
 * Строит запись. Поля перечислены явно: это и есть защита от попадания лишнего.
 */
function buildRecord(summary, sequence, manifestIds, now) {
  return {
    anchorVersion: ANCHOR_VERSION,
    sequence,
    manifestIds,
    chainLength: summary.manifestCount,
    rootIds: [...(summary.rootIds ?? [])],
    headIds: [...(summary.headIds ?? [])],
    verdict: summary.verdict,
    checkedAt: summary.checkedAt,
    writtenAt: now.toISOString(),
  };
}

function git(args) {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trim();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return 0;
  }

  const summary = await fetchSummary(args);
  const verdict = summary.verdict;

  if (verdict !== ACCEPTABLE_VERDICT) {
    // EMPTY и TOO_LARGE — не успех: судить нечего либо отказались судить. BROKEN/DRIFTED/UNPROVEN
    // означают, что цепочка не сходится; якорь закрепил бы расхождение как норму.
    console.error(`ОТКАЗ: вердикт ${verdict}, якорь ставится только на ${ACCEPTABLE_VERDICT}.`);
    if (verdict === "EMPTY") console.error("Манифестов нет — проверка не состоялась, а не прошла.");
    if (verdict === "TOO_LARGE") console.error("Выше потолка — сводка не выполнена.");
    return 1;
  }

  const logPath = args.log ?? join(ROOT, LOG_PATH);
  const records = readLog(logPath);
  const previous = records.length > 0 ? records[records.length - 1] : null;
  const previousHeads = new Set(previous?.headIds ?? []);
  const headIds = summary.headIds ?? [];
  const manifestIds = headIds.filter((id) => !previousHeads.has(id));

  if (records.length > 0 && manifestIds.length === 0) {
    console.error(
      `Новых голов нет (sequence ${previous.sequence}, chainLength ${previous.chainLength}). ` +
        "Похоже, импорта не было: повторная запись того же состояния не нужна.",
    );
    return 3;
  }

  if (previous && summary.manifestCount < previous.chainLength) {
    console.error(
      `ОТКАЗ: манифестов ${summary.manifestCount}, а в якоре ${previous.chainLength}. ` +
        "Меньше быть не может — это удаление, а не импорт. Разбирать как инцидент.",
    );
    return 1;
  }

  const sequence = previous ? previous.sequence + 1 : 1;
  const record = buildRecord(summary, sequence, manifestIds, new Date());
  const line = `${JSON.stringify(record)}\n`;

  if (args.dryRun) {
    console.log("dry-run, запись не сохранена:");
    console.log(JSON.stringify(record, null, 2));
    return 0;
  }

  mkdirSync(dirname(logPath), { recursive: true });
  if (args.out) writeFileSync(args.out, line, "utf8");
  else appendFileSync(logPath, line, "utf8");

  console.log(JSON.stringify(record, null, 2));

  if (!args.noPush) {
    git(["add", LOG_PATH]);
    git(["commit", "-m", `anchor: sequence ${sequence}, chainLength ${record.chainLength}`]);
    git(["push", "origin", "HEAD:main"]);
    console.log(`Записано и отправлено: sequence ${sequence}.`);
  }
  return 0;
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    console.error(`ОШИБКА: ${error.message}`);
    process.exit(2);
  });
