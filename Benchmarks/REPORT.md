# MCV Semantic Benchmark — Gemma 3 1B

Дата: 2026-08-16. Движок страницы: WebKit-compatible browser runtime.
Модель: локальная `gemma3:1b` через Ollama. Три повторных model run на страницу,
`temperature=0.1`, `num_ctx=4096`, `num_predict=180`, `num_thread=4`.

## Итог

| Метрика | Результат |
|---|---:|
| Страниц | 10 |
| Semantic coverage accuracy | 73% |
| Median extraction latency | 30 ms |
| Snapshot JSON validity | 100% |
| Snapshot stability | 100% |
| Model JSON validity | 53% |
| Model stability | 45% |
| Model latency median | 6.53 s |
| Худший median latency | 10.85 s |
| Hallucinated fields | 4 / 4 проверяемых non-null fields |

`Semantic coverage accuracy` — доля заранее заданных контрольных фактов,
которые реально присутствуют в WebKit snapshot. `Model stability` — доля
повторных прогонов с одинаковой парой `pageType + primaryEntity`.
`Hallucinated fields` считаются строго: non-null поле считается подтверждённым
только когда его `evidence` является точной подстрокой исходного snapshot.

## По типам страниц

| Тип | Coverage | Extract | Model JSON | Model stability | Hallucinations | Model latency | Prompt tokens | Context chars |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Wikipedia/article | 100% | 62 ms | 0% | 0% | 0/0 | 6.50 s | 2034 | 36156 |
| Amazon/product | 33% | 10 ms | 100% | 100% | 0/0 | 2.84 s | 148 | 401 |
| YouTube/video | 0% | 23 ms | 67% | 50% | 1/1 | 3.61 s | 96 | 149 |
| GitHub/repository | 100% | 34 ms | 0% | 0% | 0/0 | 9.85 s | 1956 | 25751 |
| Reddit/thread | 100% | 47 ms | 100% | 100% | 0/0 | 6.62 s | 2245 | 46998 |
| news article | 100% | 14 ms | 100% | 33% | 3/3 | 6.57 s | 639 | 3685 |
| documentation | 100% | 38 ms | 0% | 0% | 0/0 | 10.85 s | 1314 | 34653 |
| web app/dashboard | 100% | 27 ms | 0% | 0% | 0/0 | 10.82 s | 1011 | 4340 |
| login/form | 100% | 11 ms | 67% | 100% | 0/0 | 5.84 s | 357 | 1770 |
| messy JS-heavy site | 0% | 332 ms | 100% | 67% | 0/0 | 4.26 s | 98 | 149 |

## Что сломалось

- Amazon вернул `Page Not Found`; scorer не подменял его другим товаром.
- YouTube и CNN в зафиксированном прогоне дали практически пустой snapshot
  (149 символов сериализованного контекста). Это честный провал coverage,
  типичный для anti-bot/consent/JS-shell страниц.
- Gemma 1B часто возвращала JSON-подобный текст, не являющийся JSON. Особенно
  плохо: длинные Wikipedia, GitHub и MDN snapshots, а также dashboard.
- Даже при валидном JSON модель нарушала заявленную схему: например,
  `primaryEntity` иногда был объектом вместо строки.
- Все четыре non-null semantic field, для которых модель дала evidence,
  не прошли точную проверку источника. Для forensic/API функций это blocker.

## Вывод

WebKit extraction пригоден как быстрый детерминированный слой: median 30 ms,
100% валидных snapshot и 100% стабильность между тремя чтениями. Узкое место —
не extraction, а Gemma 1B. Её можно оставить для свободного summary/`ai ask`,
но нельзя использовать как единственный источник типизированного Personal Web
API, scam verdict или автоматических действий без отдельного schema validator,
retry/repair pass и evidence verifier.

Raw corpus: `snapshots.json`. Полные результаты модели: `results.json`.
Агрегат: `summary.json`. Воспроизводимый scorer: `score_semantic.py`.
