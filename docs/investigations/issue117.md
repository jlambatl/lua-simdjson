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

### Wider coverage found the earlier "35/35 green" result was incomplete

Native probes for the remaining encoder error sites (`boolean-key`, `table-key`, `function-value`, `userdata-value`, `thread-value`, `cyclic-object`, `depth-object`, `depth-array`) showed that at `ad3e1c7` (attempts 1 and 2) `boolean-key` and `table-key` still crashed with `0xC0000409` on every MSVC configuration with simdjson 5.1.1 (comparison run 42950950865). The 5.0.5 controls passed all 16 probes; MinGW passed everything.

Version bisect with the same encoder (run 42954000964, commit `1aa3dfc`): **simdjson 5.0.8 fails the same two probes on every MSVC configuration**, so the maintainer's 5.0.8 upgrade hits the crash. simdjson 5.0.6 introduced "builder: store string_builder bytes in a std::string, add move_to()" (#2930); 5.0.6 and 5.0.7 were not tested natively, so where exactly the crash starts is inferred from the release notes.

### Attempt 3 (`7c82525`): non-inlined error-raising helpers: no effect

Routing the unsupported key/value errors through `never_inline` helpers left `boolean-key` and `table-key` crashing identically (run 42951597193). The dump still showed `luaL_error` reached from `serialize_append_object`, so "do not call `luaL_error` directly from frames with inlined builder code" was not a sufficient rule. The compiler's handling of the helper call (which it may treat as non-throwing) is the suspected reason; this was not verified at instruction level.

### Attempt 4 (`fc8bc0e`): structural fix, status codes instead of `luaL_error`

Serializer functions return a status and never call `luaL_error`. `encode_value()` (non-inlined) does all builder work and returns plain data; `encode()` has no C++ objects with destructors and raises the Lua error after `encode_value()` has returned, so the longjmp has no C++ unwind state to unwind. Error messages are unchanged. The `simdjson_never_inline` workarounds were removed, which also removes the dependency on a vendored-simdjson macro.

Native results at `fc8bc0e`:

- Comparison run 42954182594: **15/15 green**: simdjson 5.0.5, 5.0.8 and 5.1.1 across MSVC Lua 5.2/5.3/5.5, MSVC LuaJIT 2.1 and MinGW Lua 5.3, each with all 16 probes and the full Lua suite (28 tests).
- Full CI run 42954182607 (vendored 5.1.1): **35/35 green**.

### Root-cause statement and limits

On MSVC x64, `longjmp` unwinds the frames it skips using their C++ unwind state. With simdjson 5.0.6+ (std::string-backed builder with inlined `noexcept` code), `luaL_error` raised from serializer frames reached `terminate()` (fail-fast `0xC0000409`). Linux and macOS `longjmp` does not consult C++ unwind tables, and MinGW passed, so no crash was observed there (they instead skip destructors, a separate pre-existing leak class). The exact MSVC state-table mechanism was not inspected at instruction level. The fix removes the dependency on it by not raising Lua errors from frames with C++ unwind state. Whether the original reporter's environment matches the hosted runners is unconfirmed.

Pre-existing, separate defects found in review (verified on the baseline): Lua stack overflow on deep nesting (no `lua_checkstack`), leaks from `luaL_error` inside `catch` blocks and with live destructors in `parse_file`, and `__gc` reachable from Lua (double free). These are not addressed by this branch.
