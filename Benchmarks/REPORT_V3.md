# MCV Semantic Benchmark V3 — WebKit Coverage

Дата: 2026-08-16. Модель, ID-only schema та V2 verifier не змінювались.
Змінено лише extraction/hydration layer. Той самий corpus із 10 URL,
три повтори на сторінку.

## Результат

| Метрика | V2 | V3 |
|---|---:|---:|
| Semantic coverage | 73% | **93%** |
| Extraction median | 34 ms | **34 ms** |
| Semantic API JSON validity | 100% | **100%** |
| Semantic API stability | 97% | **100%** |
| Hallucinated fields | 0 | **0** |

Coverage виріс на 20 процентних пунктів. Ціль `>90%` досягнута без обходу
anti-bot та без послаблення verifier.

## Що додано

- до 5 hydration retries із секундним інтервалом лише для слабких snapshots;
- OpenGraph і довільні `meta[name/property]`;
- JSON-LD, `application/json`, `__NEXT_DATA__`;
- runtime bootstrap objects: `ytInitialPlayerResponse`, `ytInitialData`,
  `__APOLLO_STATE__`;
- ARIA headings/controls, tabs/menuitems, form values;
- media, tables, forms;
- open shadow roots і доступні same-origin iframe documents;
- public initial-HTML fallback через звичайний HTTPS GET, якщо WebKit
  навігація стала порожнім документом;
- явне розпізнавання `Page Not Found`, access denied, CAPTCHA/robot pages без
  retries або спроб обходу.

## Провальні та відновлені випадки

- YouTube: V2 мав порожній snapshot; V3 дочекався hydration і отримав title,
  40 meta fields, media та видимий опис відео.
- CNN: тестовий WebView повертав `about:blank`; initial public HTML fallback
  отримав `Breaking News, Latest News and Videos | CNN` і 14.9K тексту.
- Amazon: URL стабільно повертає `Page Not Found`; результат лишився
  `insufficient_evidence`, як і вимагає політика.

Raw: `snapshots_v3.json`, `results_v3.json`, `summary_v3.json`.
