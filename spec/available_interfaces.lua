local simdjson = require("simdjson")

-- Check if the library loaded successfully and is a table
if type(simdjson) == "table" then
    print("Functions available in 'simdjson':")
    -- Iterate over all key-value pairs in the table
    for name, func in pairs(simdjson) do
        -- Check if the value is a function
        if type(func) == "function" then
            print("* " .. name)
        else
            print("- " .. name .. " (not a function)")
        end
    end
else
    print("Error: 'simdjson' could not be loaded or is not a table.")
end
