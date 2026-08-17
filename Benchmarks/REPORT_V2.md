# MCV Semantic Benchmark V2 — ID-only Gemma 3 1B

Дата: 2026-08-16. Той самий corpus із 10 типів сторінок, три повтори на
сторінку. V1 — модель генерує semantic values. V2 — модель може повернути
тільки класифікацію та існуючі `factIds`; schema/evidence verifier відхиляє
все інше, а багаті snapshot мають deterministic fallback.

## Порівняння

| Метрика | V1 | V2 |
|---|---:|---:|
| Semantic coverage | 73% | 73% |
| Extraction median | 30 ms | 34 ms |
| Raw model JSON validity | 53% | 70% |
| Semantic API JSON validity | 53% | **100%** |
| Semantic API stability | 45% | **97%** |
| Hallucinated fields | 4 / 4 checked | **0** |
| Model latency median | 6.53 s | **3.90 s** |
| Median compact context | 4013 chars | **3788 chars** |

Один із трьох login runs в benchmark process перевищив timeout, тому виміряна
стабільність — 97%. У застосунку network/model error проходить через той самий
deterministic ID fallback, тому timeout не може додати непідтверджений факт.

## Поведінка verifier

- Кожен факт створюється до виклику моделі й отримує ID `fN`.
- Ollama отримує короткий каталог `id|kind|value`, максимум 70 фактів.
- JSON Schema обмежує status, page type, labels, кількість sections та форму ID.
- Runtime verifier повторно перевіряє schema, label enum, confidence і наявність
  кожного ID у конкретному catalog.
- Невідомий ID, неправильний label/type, invalid JSON або timeout не проходять.
- Для багатого snapshot використовується deterministic fallback з існуючих ID.
- Для порожнього snapshot/error page повертається `null / insufficient_evidence`.

## JS-heavy extraction

V2 додає OpenGraph/meta, JSON-LD, `__NEXT_DATA__`, форми, таблиці, media,
ARIA controls, відкриті shadow roots та до двох hydration retries. На цьому
corpus CNN і YouTube все одно повернули порожній browser/anti-bot shell, а
Amazon — `Page Not Found`; вони коректно стали `insufficient_evidence`, а не
вигаданими product/video/news objects.

Raw: `snapshots_v2.json`, `results_v2.json`, `summary_v2.json`.
Runner: `score_semantic_v2.py`.
