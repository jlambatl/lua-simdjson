#!/usr/bin/env lua

-- encode_probe.lua: CLI to test error-path probes for non-finite values
-- Usage: lua scripts/ci/encode_probe.lua <case> <module-dir>
-- Cases: nan, negative-nan, positive-infinity, negative-infinity, array-nan, object-nan, infinite-key, repeat-nan

local arg = arg or {}
if #arg < 2 then
    io.stderr:write("Usage: lua scripts/ci/encode_probe.lua <case> <module-dir>\n")
    os.exit(1)
end

local case = arg[1]
local module_dir = arg[2]

-- Log version and environment
io.stdout:write("Lua/JIT: " .. _VERSION .. "\n")
if jit then
    io.stdout:write("JIT version: " .. jit.version .. "\n")
end
io.stdout:flush()

-- Load simdjson from explicit path (no fallback to globally installed module)
local platform_name
if package.config:sub(1, 1) == '\\' then
    platform_name = "simdjson.dll"
else
    platform_name = "simdjson.so"
end

-- Ensure absolute path; no fallback
local module_path = module_dir .. "/" .. platform_name
if module_path:sub(1, 1) ~= "/" and not (module_path:match("^%w:")) then
    io.stderr:write("FAIL: module path must be absolute, got: " .. module_path .. "\n")
    os.exit(1)
end

local simdjson_lib, err = package.loadlib(module_path, "luaopen_simdjson")
if not simdjson_lib then
    io.stderr:write("FAIL: cannot load module from " .. module_path .. ": " .. tostring(err) .. "\n")
    os.exit(1)
end

local simdjson = simdjson_lib()

-- Validate case name
local valid_cases = {
    ["nan"] = true,
    ["negative-nan"] = true,
    ["positive-infinity"] = true,
    ["negative-infinity"] = true,
    ["array-nan"] = true,
    ["object-nan"] = true,
    ["infinite-key"] = true,
    ["repeat-nan"] = true,
}

if not valid_cases[case] then
    io.stderr:write("FAIL: unknown case '" .. case .. "'\n")
    os.exit(1)
end

io.stdout:write("Module path: " .. module_path .. "\n")
io.stdout:write("Active implementation: " .. tostring(simdjson.activeImplementation()) .. "\n")
io.stdout:write("BEGIN\n")
io.stdout:flush()

-- Helper: test error contract
local function test_error_contract(value, context_name)
    io.stdout:write("BEFORE_ERROR_CALL " .. context_name .. "\n")
    io.stdout:flush()
    
    local success, error_msg = pcall(function()
        return simdjson.encode(value)
    end)
    
    io.stdout:write("AFTER_PCALL " .. context_name .. "\n")
    io.stdout:flush()
    
    if success then
        io.stderr:write("FAIL: expected error but encode succeeded\n")
        return false
    end
    
    if not error_msg or not error_msg:match("cannot encode NaN or infinity as JSON") then
        io.stderr:write("FAIL: error message does not match pattern. Got: " .. tostring(error_msg) .. "\n")
        return false
    end
    
    -- Test recovery
    local recovery_ok, recovery_result = pcall(function()
        return simdjson.encode({valid = true})
    end)
    
    if not recovery_ok or recovery_result ~= '{"valid":true}' then
        io.stderr:write("FAIL: recovery after error failed\n")
        return false
    end
    
    return true
end

-- Execute test case
local test_passed = false

if case == "nan" then
    test_passed = test_error_contract(0 / 0, "nan")
elseif case == "negative-nan" then
    test_passed = test_error_contract(-0 / 0, "negative-nan")
elseif case == "positive-infinity" then
    test_passed = test_error_contract(math.huge, "positive-infinity")
elseif case == "negative-infinity" then
    test_passed = test_error_contract(-math.huge, "negative-infinity")
elseif case == "array-nan" then
    test_passed = test_error_contract({1, 0 / 0, 3}, "array-nan")
elseif case == "object-nan" then
    test_passed = test_error_contract({a = 1, b = 0 / 0, c = 3}, "object-nan")
elseif case == "infinite-key" then
    test_passed = test_error_contract({[math.huge] = "value"}, "infinite-key")
elseif case == "repeat-nan" then
    -- 10,000 rejection/recovery iterations
    local iterations = 10000
    test_passed = true
    for i = 1, iterations do
        local success, error_msg = pcall(function()
            return simdjson.encode(0 / 0)
        end)
        
        if success then
            io.stderr:write("FAIL: iteration " .. i .. " expected error but encode succeeded\n")
            test_passed = false
            break
        end
        
        if not error_msg or not error_msg:match("cannot encode NaN or infinity as JSON") then
            io.stderr:write("FAIL: iteration " .. i .. " error message mismatch\n")
            test_passed = false
            break
        end
        
        -- Recovery check every iteration (bounded logging: only report failures or every 1000)
        local recovery_ok, recovery_result = pcall(function()
            return simdjson.encode({valid = true})
        end)
        if not recovery_ok or recovery_result ~= '{"valid":true}' then
            io.stderr:write("FAIL: iteration " .. i .. " recovery failed\n")
            test_passed = false
            break
        elseif i % 1000 == 0 then
            io.stdout:write("Recovery check passed at iteration " .. i .. "\n")
            io.stdout:flush()
        end
    end
end

io.stdout:write("PASS " .. case .. "\n")
io.stdout:flush()

if test_passed then
    os.exit(0)
else
    os.exit(1)
end
