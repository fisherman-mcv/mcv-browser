# MCV Browser

```text
M C V / B R O W S E R
LESS CHROME. MORE WEB.
```

A native, command-first browser for macOS.

MCV uses AppKit and the system WebKit. No embedded Chromium. No 300 MB engine tax. No permanent toolbar assembled by committee. The page gets the window; everything else appears when requested.

> If a page is doing nothing, the browser should be doing approximately nothing.

## The equation

```text
browser = WebKit + tabs + commands + restraint
idle work = 0, whenever reality permits
generated facts = 0
cloud AI requests = 0
```

MCV is not trying to out-Safari Safari. Apple owns the engine, private APIs and half the operating system. Competing with that would be theatre. MCV keeps the good machinery and changes the part users actually touch.

## What it is

- A 36 px vertical tab rail with groups, pinned tabs and hibernation.
- A floating Spotlight-style URL, search and command bar (`⌘E` / `⌘L`).
- Native blank tabs: no fake start page, no `about:blank` wallpaper.
- A local semantic engine constrained to evidence extracted by WebKit.
- A Chrome-compatible extension runtime implemented over public WebKit APIs.
- Native ad/tracker blocking through `WKContentRuleList`.
- A Firefox-style video control backed by one existing `WKWebView`, not a second decoder.
- Enough keyboard control to make the mouse optional, but not illegal.

## What it is not

- Chromium wearing an AppKit hat.
- A Safari extension bundle.
- A cloud account with a browser attached.
- A promise of impossible Chrome API parity over public WebKit.
- Finished. Software that claims to be finished is either dead or invoicing you.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Apple Silicon recommended
- Optional: [Ollama](https://ollama.com/) with `gemma3:1b`

## Build

```sh
git clone <repository-url>
cd mcv-browser
make app
open "MCV Browser.app"
```

```sh
make build      # debug
make run        # debug + launch
make release    # optimized executable
make app        # application bundle
make dmg        # drag-to-install disk image
swift test      # test suite
```

The local build is ad-hoc signed. Distribution still requires an Apple Developer ID signature and notarization. Gatekeeper remains unimpressed by enthusiasm.

## Updates

MCV embeds Sparkle 2. Automatic checks run every six hours and verified updates
may download in the background. **MCV Browser → Check for Updates…** starts a
manual check. Developer builds keep the updater dormant until a real HTTPS feed
and EdDSA public key are injected; unsigned update theatre is not an updater.

One-time signing-key setup:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mcv-browser
```

The private key stays in the macOS Keychain. Back it up securely; never commit
or paste it into an issue. Build a signed Sparkle archive and appcast with:

```sh
Scripts/make_update.sh OWNER/REPOSITORY 1.0.1 2
```

Upload `dist/MCV-Browser-1.0.1.zip` to GitHub release `v1.0.1`, then commit the
generated `appcast.xml` to `main`. Sparkle verifies the EdDSA signature before
installation. Public GitHub hosting is transport; the signing key is authority.

## Put it on GitHub

No remote is configured by default. Install and authenticate GitHub CLI, then:

```sh
brew install gh
gh auth login
git add .
git commit -m "Prepare MCV Browser release"
gh repo create mcv-browser --public --source=. --remote=origin --push
```

For a private repository use `--private`, but remember that unauthenticated
Sparkle clients cannot download private release assets or a private appcast.
Public releases are the uncomplicated option.

## Interface

The default interface is the sidebar:

```text
┌────┐
│ ●  │ window controls
│ ◉  │ pinned tab
│ ◈  │ tab group
│    │
│ ·  │ MCV dot-matrix wordmark
│ ⌕  │ Spotlight bar
│ +  │ new tab
└────┘
```

Tabs can be dragged, grouped, collapsed, bookmarked or hibernated. Pinned and regular tabs have a hard ordering boundary: a normal tab cannot silently become pinned because somebody missed by four pixels.

The Spotlight bar contains quiet Back, Forward and Reload/Stop controls. It is hidden until needed because navigation buttons are useful, not sacred geometry.

## Keyboard

| Keys | Result |
|---|---|
| `⌘E` / `⌘L` | URL, search and command bar |
| `⌘T` | New tab |
| `⌘W` | Close tab; close window when it is the last tab |
| `⇧⌘T` | Reopen closed tab |
| `⌘1…9` | Select tab; `⌘9` always selects the last |
| `⌘D` | Bookmark current page |
| `⌘P` | Pin or unpin current tab |
| `⌃D` | Bookmarks panel |
| `⌘F` | Find on page |
| `⌘[` / `⌘]` | Back / Forward |
| `⇧⌘S` | Toggle sidebar mode |
| `⌘,` | Settings |

## Commands

Type commands in the same bar used for URLs. Unknown input becomes a search.

```text
open <url>              new / close / reopen / dup
back / forward / reload tabs / tab <n> / next / prev
find <text>             reader / src / print / pdf / shot
bm add / bm rm          sidebar on / sidebar off
dark / light            mode classic|safe|secure
js on / js off          perf / help
```

Search prefixes include `g`, `ddg`, `yt`, `wiki`, `gh`, `so`, `npm`, `mdn`, `img` and `maps`. Run `help` for the rest; README tables are not a personality test.

## Local Semantic Runtime

Optional AI runs through local Ollama using `gemma3:1b`. The model is not allowed to write facts.

```text
WebKit snapshot
  → deterministic extraction
  → compact facts [f1, f2, f3…]
  → Gemma selects and classifies existing IDs
  → JSON Schema validator
  → evidence verifier
  → Semantic API
```

`"price": "€999"` from the model is rejected. `"price": "f17"` is accepted only when `f17` exists and contains that observed value. Missing evidence becomes `null / insufficient_evidence`. Boring failure is better than confident fiction.

```sh
ollama pull gemma3:1b
ollama serve
```

| Command | Result |
|---|---|
| `ai page` | Verified semantic page model |
| `ai api` | Personal Web API over observed facts |
| `ai ui` | Task-focused app reader |
| `ai research [question]` | Research across the current tab group |
| `ai research all [question]` | Research across up to 20 tabs |
| `ai memory [query]` | Search local semantic memory |
| `ai tabs` | Group tabs by inferred purpose |
| `ai focus` | Toggle attention firewall |
| `ai scam` | Observable forensic signals; no invented verdict |
| `ai inspect` | Select a DOM element for diagnostics |
| `ai debug` | JS, resource, navigation and layout diagnostics |
| `ai status` | Check Ollama and the ID verifier |

Extraction covers OpenGraph, JSON-LD, `__NEXT_DATA__`, ARIA, shadow DOM, same-origin frames, forms, tables and media. Hydrated pages get bounded retries. CAPTCHAs, access-denied pages and anti-bot walls are reported, not bypassed.

Semantic memory is event-driven, local, disabled for private tabs and switchable under **Settings → Privacy**. It does not poll idle pages.

## Extension Runtime

MCV maps a Chrome-shaped API onto native MCV and WebKit capabilities. Install `.crx`, `.zip` or unpacked extensions through **Tools → Install Chrome Extension…**. Chrome Web Store pages expose **Add to MCV**.

Each extension receives an isolated `WKContentWorld`, isolated storage and permission checks at the native boundary. `browser.*` aliases `chrome.*`.

| Surface | Status | Reality |
|---|:---:|---|
| CRX2 / CRX3 / ZIP / unpacked | PASS | Validated install root and traversal protection |
| MV2 / MV3 manifests | PASS | Unknown fields tolerated |
| Content scripts / CSS | PASS | Match patterns, frames and isolated worlds |
| Storage / runtime / messaging | PASS | Per-extension stores and native bridge |
| Popup / options | PASS | Native window containing extension `WKWebView` |
| Tabs / windows / scripting | PARTIAL | Core operations; WebKit semantics differ |
| MV3 workers | PARTIAL | Event-page runtime, not Chrome's lifecycle |
| DNR / webRequest | PARTIAL | Native blocking; request mutation is limited |
| DevTools / debugger / nativeMessaging / proxy | UNSUPPORTED | No safe public WebKit equivalent |

### Real-extension run

The behavioral suite installs original Chrome Web Store packages without source modification and executes them inside `WKWebView`. Last recorded run:

```text
20 extensions
 2 PASS
14 PARTIAL
 4 FAIL
```

Confirmed PASS: uBlock Origin Lite and Dark Reader. Bitwarden is PARTIAL: popup, storage, messaging and content injection work; full unlocked-vault parity does not. React/Redux DevTools cannot work without the missing WebKit DevTools panel API. That is a limitation, not a motivational challenge.

Extension evidence and exact versions live in the recorded
[`runtime-results.json`](Benchmarks/real-extensions/runtime-results.json) and
[`critical-results.json`](Benchmarks/real-extensions/critical-results.json).
Semantic extraction results live in
[`Benchmarks/REPORT_V3.md`](Benchmarks/REPORT_V3.md). Third-party CRX binaries
are deliberately excluded from git; download them for a local run:

```sh
Scripts/download_real_extensions.sh
MCV_REAL_EXTENSION_TESTS=1 swift test --filter RealExtensionBehaviorTests
```

## Resource model

WebKit owns WebContent, Network and GPU processes, site separation, BFCache, HTTP/2 and HTTP/3, Brotli, streaming parsing, JIT/GC, hardware video decode and incremental rendering. MCV does not reimplement mature engine internals for the pleasure of producing a worse browser.

MCV controls what the shell can control:

- no-render for detached background views;
- background media preserved when the user expects audio;
- inactive safe tabs frozen, then hibernated under age or pressure;
- group hibernation as an explicit operation;
- volatile cache eviction before destructive tab release;
- thermal and memory-pressure reactions;
- event-driven state updates instead of permanent polling;
- one WebView and one decoder for the floating video player.

Run `perf` for the current process and lifecycle state. Performance claims belong next to measurements, not adjectives.

## Security modes

| Mode | Policy |
|---|---|
| Classic | Normal browsing, no native content rules |
| Safe | Native ad/tracker rules and scam signals |
| Secure | JavaScript off and ephemeral storage for new tabs |

Smart popups accept ordinary OAuth, login and payment flows, reject unsafe URL schemes and rate-limit popup spam. Extension permissions are shown before install. Private tabs are excluded from persistent semantic memory.

Security reports belong in [`SECURITY.md`](SECURITY.md). Do not open a public issue containing credentials, session data or a live exploit.

## Data

MCV stores its state under `~/.mcv/`:

```text
config.json          settings
pinned-tabs.json     pinned tabs
tab-groups.json      tab groups
history.json         browsing history
ai-memory.json       optional local semantic memory
extensions/          installed extensions and isolated storage
```

Removing that directory resets the profile. Do not do this accidentally. Unix will not ask whether you had sentimental attachment to your tabs.

## Repository

```text
Sources/MCV/
  BrowserWindowController.swift   native window and layout
  TabManager.swift                tabs, WebKit lifecycle, media
  CommandEngine.swift             command parser and execution
  AIBrowserEngine.swift           evidence-bound semantic runtime
  Extensions/                     Chrome-compatible runtime
  ResourcePressureController.swift
  UI/                             AppKit surfaces and MCV identity
Tests/MCVTests/                   unit and WKWebView behavior tests
Benchmarks/                       reports and recorded results
Resources/                        application metadata and icon
Scripts/                          packaging and benchmark utilities
```

## Verification

```sh
swift build
swift build -c release
swift test --skip SmartPopupTests
make app
codesign --verify --deep --strict "MCV Browser.app"
```

Some integration tests require downloaded extensions or macOS UI services and are skipped by default. A skipped external fixture is not a pass.

## Status

MCV is an experimental macOS browser and a real daily-driver project. Public WebKit APIs define the ceiling. Bugs define the current floor.

Contributions should include a reproducible failure, a narrow patch and a test. Feature requests consisting entirely of another browser's screenshot will be judged by whether the feature makes MCV smaller, faster or more coherent.

## License

No license has been selected yet. Copyright remains with the project owner; no permission to redistribute modified builds is implied. Choose an explicit license before accepting outside code. Legal ambiguity is not open source.
