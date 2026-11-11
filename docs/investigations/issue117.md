# Issue #117: simdjson 5.1.1 upgrade and Windows investigation

## Scope and status

Compare only the current bundled **5.0.5** with **5.1.1**, against identical binding/test code. No intermediate-version CI is in scope. The Windows crash **was reproduced natively** (MSVC Lua 5.3/5.5 with 5.1.1) and fixed in `src/lua_encoder.cpp` only; vendored simdjson is unchanged. See the results below.

- Issue: https://github.com/FourierTransformer/lua-simdjson/issues/117
- Baseline repository commit: `d12a8b062ee7f9229e3e9ab2a1665f085f1a695b`
- Target simdjson release: `v5.1.1`
- Pinned target release commit: `40a686ab89dc5ee58ec10d0514dd5c99abbc472b`
- Vendor sources: official `singleheader/simdjson.h` and `singleheader/simdjson.cpp` from that same commit, unchanged.

## Execution prerequisites

The fork and upstream default branches are **master**. The existing CI workflow triggers on `pull_request`; a draft PR within `jlambatl/lua-simdjson`, from `investigate/simdjson-5.1.1-issue117` to `master`, will trigger it, including subsequent pushes to the open PR. Fork Actions are enabled and the authenticated account has push access, verified 2026-11-11.

The agent shell overrides `XDG_CONFIG_HOME` for Rovo tooling. GitHub CLI commands use `env -u XDG_CONFIG_HOME gh ...` to discover the user's authenticated GitHub CLI configuration without modifying global settings. The token used for the fork has `repo` and `workflow` scopes.

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

Local macOS results alone do not establish that issue #117 is fixed; native Windows results are below. The Windows dump self-test is synthetic infrastructure validation, not issue117 reproduction evidence.

## Native Windows RED evidence

Tested code: `45afd879a3db9ee31438570acd4385f6b07a4600`.
Comparison: https://github.com/jlambatl/lua-simdjson/actions/runs/42936457771
Full platform CI: https://github.com/jlambatl/lua-simdjson/actions/runs/42936457974

The identical binding/test revision with 5.0.5 passes all 8 probes in all five control configurations. 5.1.1 passes on MSVC Lua 5.2, MSVC LuaJIT 2.1, and MinGW Lua 5.3, but all 8 probes fail on MSVC Lua 5.3 and Lua 5.5 with exit `0xC0000409`, before returning from `pcall`. Normal full CI also fails only on MSVC Lua 5.3/5.4/5.5 (32/35 jobs pass).

ProcDump captures and CDB analyzes `dumps/lua.exe_261111_010832.dmp`, artifact `issue117-5.1.1-lua53-vs`. Its `native-lua.exe_261111_010832.txt` identifies `FAST_FAIL_FATAL_APP_EXIT`, subcode 7, and the actual stack:

```text
simdjson!abort
simdjson!terminate
simdjson!__std_terminate
simdjson!__FrameHandler4::FrameUnwindToState
simdjson!__CxxFrameHandler4
ntdll!RtlUnwindEx
VCRUNTIME140!__longjmp_internal
lua53!lua_error
lua53!luaL_error
simdjson!serialize_append_number+0x785
simdjson!serialize_data
simdjson!encode
```

This proves the Lua error enters longjmp and terminates during MSVC C++ frame unwinding, not normal fall-through into append. It does not show allocation failure or an actual stack-buffer overrun despite the generic Windows status description.

## Fix attempts and native results

Both attempts changed only `src/lua_encoder.cpp`, one variable at a time, and were validated on hosted Windows runners.

### Attempt 1 (`5dbffc9`): non-inlined numeric builder append

`append_number<T>()` is `simdjson_never_inline` and wraps `builder.append(value)` for the integer and float paths. Native result (comparison run 42937854229, CI run 42937854195): MSVC Lua 5.3/5.4/5.5 pass, but a **regression** appeared on MSVC Lua 5.1/5.2 and LuaJIT 2.1: only the `infinite-key` probe failed with `0xC0000409`. 5.0.5 controls still passed.

Dump of the regression (`simdjson!serialize_append_object+0x15b` calling `luaL_error`) shows the same terminate-during-longjmp stack as above. The PDB shows `serialize_append_number`, including its `std::isfinite` check and `luaL_error`, was inlined into `serialize_append_object`, a frame that carries C++ EH state; for plain values it was not inlined into such a frame, which is why the other seven probes passed.

### Attempt 2 (`7b54b3d`): non-inlined `serialize_append_number`

`serialize_append_number` is now `simdjson_never_inline`, so the Lua error for non-finite numbers (value or key) is raised from a dedicated frame with no builder code inlined, as in the passing value path.

Native result at `7b54b3d`:

- Comparison run 42946913661: **10/10 green** (5.0.5 and 5.1.1 across MSVC Lua 5.2/5.3/5.5, MSVC LuaJIT 2.1, MinGW Lua 5.3).
- Full CI run 42946913648: **35/35 green**, including MSVC Lua 5.1-5.5, LuaJIT 2.0/2.1, MinGW, macOS, Linux and sanitizers.

### Root-cause statement and limits

Evidence supports: with simdjson 5.1.1's inlined `noexcept` builder code, MSVC builds of lua-simdjson can place `luaL_error` (a longjmp) in a frame whose C++ unwind state makes MSVC's longjmp unwinder call `terminate`, producing fail-fast `0xC0000409`. Keeping Lua error raising and builder appends in separate non-inlined frames avoids it in all tested configurations. The exact compiler state-table mechanism was not inspected at instruction level, and the fix relies on the compiler honoring `never_inline`; it is a mitigation validated empirically, not a formal guarantee. Whether the original reporter's exact environment matches the hosted runners is unconfirmed.
