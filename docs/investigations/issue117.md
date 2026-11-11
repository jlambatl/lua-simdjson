# Issue #117: simdjson 5.1.1 upgrade and Windows investigation

## Scope and status

Compare only the current bundled **5.0.5** with **5.1.1**, against identical binding/test code. No intermediate-version CI is in scope. Windows crash reproduction remains unconfirmed; no speculative production fix has been made.

- Issue: https://github.com/FourierTransformer/lua-simdjson/issues/117
- Baseline repository commit: `d12a8b062ee7f9229e3e9ab2a1665f085f1a695b`
- Target simdjson release: `v5.1.1`
- Pinned target release commit: `40a686ab89dc5ee58ec10d0514dd5c99abbc472b`
- Vendor sources: official `singleheader/simdjson.h` and `singleheader/simdjson.cpp` from that same commit, unchanged.

## Execution prerequisites

The fork and upstream default branches are **master**. The existing CI workflow triggers on `pull_request`; a draft PR within `jlambatl/lua-simdjson`, from `investigate/simdjson-5.1.1-issue117` to `master`, will trigger it, including subsequent pushes to the open PR. Fork Actions are enabled and the authenticated account has push access, verified 2026-11-11.

The agent shell overrides `XDG_CONFIG_HOME` for Rovo tooling. GitHub CLI commands use `env -u XDG_CONFIG_HOME gh ...` to discover the user's authenticated GitHub CLI configuration without modifying global settings. The current token has `repo` but not `workflow` scope; that additional permission must be granted before pushing workflow changes.

Every persisted checkpoint is cryptographically signed and DCO signed off with `git commit -S -s`, then verified. There is no unsigned fallback. Workflow jobs have read-only repository permissions and synthetic inputs; dumps are bounded and retained for seven days.

## Test and evidence contract

- Probe loads the exact built module by absolute path, not an installed fallback.
- Non-finite values must produce `cannot encode NaN or infinity as JSON` through a protected Lua call, then allow valid encoding on the same state.
- Each native probe is a separate process. Capture interpreter/compiler identity, source/module hashes, exit/exception codes, flushed phase markers, and logs; capture native dumps/stacks where available.
- Process crashes, timeouts, missing PASS markers, and setup/build errors remain failures even when evidence collection succeeds.
- Existing green characterization tests do not establish a historical failing state or prove #117 fixed.

## Results

## Local implementation evidence (2026-11-11)

The official 5.1.1 pair was integrated unchanged. SHA-256:

- `src/simdjson.h`: `f3e5ee5f39051960b5ce65762ee4b6919caf270675eb52240ebd92f21a5bcefd`
- `src/simdjson.cpp`: `3ea5f501cef6c2e16e28095b566feeb56021ca473aaf50aad32102f45d734195`

A clean C++17 macOS/ARM64 build of integrated 5.1.1 passed all **27 Lua tests** and all **8 isolated diagnostic cases**, including 10,000 repeated NaN errors with recovery every iteration. The Python diagnostic runner passed **7 real-child-process contract tests**. The Windows comparison workflow passed actionlint 1.7.12. No binding compatibility edit or production crash fix was necessary for these local results.

The diagnostic tests were committed as a signed failing checkpoint before the runner was integrated; the initial missing-runner failures and final passing results were observed. Some worker-added edge tests were written after their implementations despite the requested one-at-a-time TDD protocol; this process deviation is disclosed rather than claimed as full per-behavior RED/GREEN proof. A timeout JSON serialization failure was independently reproduced and corrected. Every actual commit remains signed and signed off.

Native Windows CI is pending. Local green results do not establish that issue #117 is reproduced or fixed. The Windows dump self-test is synthetic infrastructure validation, explicitly not issue117 reproduction evidence.
