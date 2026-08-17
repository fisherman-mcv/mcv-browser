# Contributing to MCV

MCV optimizes for a smaller interface, lower idle work and explicit behavior.
More code is not automatically more browser.

## A useful change contains

1. A reproducible problem or a precise capability.
2. The narrowest implementation that solves it.
3. A regression test where the behavior can be automated.
4. Before/after measurements for performance claims.

## Before sending a change

```sh
swift build
swift test --skip SmartPopupTests
swift build -c release
```

Keep unrelated formatting and generated files out of the patch. Never commit
downloaded CRX packages, unpacked third-party extensions, browser profiles,
cookies, credentials or `~/.mcv` state.

## Constraints

- Public WebKit and AppKit APIs only.
- No embedded Chromium.
- No cloud requirement for core browsing.
- No polling where a lifecycle event exists.
- No semantic value without deterministic evidence.
- No permission enforced only in JavaScript.

If a public WebKit API cannot provide a Chrome behavior, mark it `PARTIAL` or
`UNSUPPORTED`. Accuracy is cheaper than maintaining a fictional compatibility
claim.
