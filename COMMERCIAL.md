# MCV Commercial Use

MCV Browser uses a dual-license model.

## Personal

Personal and other noncommercial use is free under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md). No account, activation or
cloud subscription is required. Local WebKit browsing, native blocking,
extensions and local `gemma3:1b` remain available without payment.

## Business

Use by or for a for-profit business requires a separate written commercial
license from F Corp. This includes internal company use, managed deployment,
use in revenue-generating work and redistribution as part of a commercial
product or service.

Commercial pricing, support scope, deployment rights and term are defined in
the commercial agreement. This file is an overview, not that agreement.

To request a license, open a licensing inquiry through the repository owner:
https://github.com/fisherman-mcv

## MCV Cloud AI

MCV Cloud AI is a separate optional service, not a condition of using the
browser. It is intended for machines where the local 1B model is unavailable,
too slow or memory-constrained.

The intended contract is deliberately narrow:

```text
WebKit extracts deterministic facts locally
→ browser removes noise and assigns fact IDs
→ cloud model selects/classifies IDs only
→ local schema validator
→ local evidence verifier
→ result
```

The cloud service must never receive cookies, passwords, form values, browser
history or the raw page DOM. Cloud processing requires explicit opt-in and a
clear per-request indicator. Local mode remains the default.

Subscription revenue pays for inference. It does not buy permission to invent
facts, weaken the verifier or turn ordinary browsing into telemetry.

## Product matrix

| Product | Personal use | Business use | AI execution |
|---|---:|---:|---|
| MCV Personal | Free | Not licensed | Local Gemma, optional Cloud plan |
| MCV Business | — | Paid | Local Gemma, optional team Cloud plan |
| MCV Cloud AI | Optional subscription | Optional subscription | Hosted ID selection |

Prices are intentionally not stated until billing, taxes, quotas, privacy terms
and support obligations are operational. A number beside a dead checkout button
is not a business model.

The technical service boundary is specified in
[`Docs/MCV_CLOUD_API.md`](Docs/MCV_CLOUD_API.md).
