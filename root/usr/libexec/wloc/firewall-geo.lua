#!/usr/bin/lua
-- SPDX-License-Identifier: Apache-2.0
-- Compile and fold WLOC nftables GeoIP macros without changing the saved source.

local geoip = dofile "/usr/libexec/wloc/geoip.lua"
local nft_source = dofile "/usr/libexec/wloc/nft-source.lua"

local OWNED_TABLE = "wloc"

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellquote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function exec_capture(command)
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then return false, "" end
    local output = pipe:read("*a") or ""
    local ok, _, code = pipe:close()
    return ok == true or code == 0, output
end

local function uci_get(option, default)
    local ok, output = exec_capture("/sbin/uci -q get wloc.main." .. option)
    output = trim(output)
    return ok and output ~= "" and output or default
end

local function geoip_path()
    return trim(uci_get("geoip_file", "/usr/share/wloc/geoip.dat"))
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err or ("cannot read " .. tostring(path)) end
    local value = file:read("*a") or ""
    file:close()
    return value
end

local function write_file(path, value)
    local file, err = io.open(path, "wb")
    if not file then return nil, err or ("cannot write " .. tostring(path)) end
    local ok, write_error = file:write(value)
    if not ok then file:close(); return nil, write_error or "write failed" end
    local closed, close_error = file:close()
    if not closed then return nil, close_error or "close failed" end
    return true
end

local function normalize(raw)
    raw = tostring(raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if raw ~= "" and raw:sub(-1) ~= "\n" then raw = raw .. "\n" end
    return raw
end

local function add_warning(warnings, seen, message)
    if seen[message] then return end
    seen[message] = true
    warnings[#warnings + 1] = message
end

local function omit_empty_macro(segment, raw, next_position)
    local without_comma, removed = segment:gsub(",%s*$", "", 1)
    if removed > 0 then return without_comma, next_position end

    local tail = raw:sub(next_position)
    local _, finish = tail:find("^%s*,")
    if finish then return segment, next_position + finish end
    return segment, next_position
end

local function remove_empty_elements_blocks(raw)
    local parsed = nft_source.parse(raw)
    if not parsed then return raw end

    local removals = {}
    for _, set_spec in ipairs(parsed.sets) do
        if set_spec.elements_start and trim(set_spec.elements_body or "") == "" then
            removals[#removals + 1] = {
                start_position = set_spec.elements_start,
                finish_position = set_spec.elements_close
            }
        end
    end

    table.sort(removals, function(left, right)
        return left.start_position > right.start_position
    end)
    for _, removal in ipairs(removals) do
        raw = raw:sub(1, removal.start_position - 1) .. raw:sub(removal.finish_position + 1)
    end
    return raw
end

local function queue_geoip_elements(deferred, order, set_spec, values)
    local bucket = deferred[set_spec.key]
    if not bucket then
        bucket = { spec = set_spec, values = {}, seen = {} }
        deferred[set_spec.key] = bucket
        order[#order + 1] = bucket
    end
    for _, value in ipairs(values) do
        if not bucket.seen[value] then
            bucket.seen[value] = true
            bucket.values[#bucket.values + 1] = value
        end
    end
end

local function append_geoip_elements(output, order)
    for _, bucket in ipairs(order) do
        if #bucket.values > 0 then
            output[#output + 1] = string.format(
                "\nadd element %s %s %s { %s }\n",
                bucket.spec.table_family, bucket.spec.table_name, bucket.spec.name,
                table.concat(bucket.values, ", ")
            )
        end
    end
end

local function compile(raw)
    raw = normalize(raw)
    local parsed, parse_error = nft_source.inspect(raw, OWNED_TABLE)
    if not parsed then return nil, parse_error end

    local warnings, warning_seen = {}, {}
    if #parsed.macros == 0 then return raw, nil, warnings end

    local cache, output, position = {}, {}, 1
    local deferred, deferred_order = {}, {}
    local path = geoip_path()
    for _, macro in ipairs(parsed.macros) do
        local segment = raw:sub(position, macro.start_position - 1)
        local next_position = macro.finish_position + 1
        local key = string.upper(macro.tag)

        if cache[key] == nil then
            local data, data_error, data_kind = geoip.load(path, key)
            if not data then
                if data_kind == "missing_file" or data_kind == "missing_tag" then
                    cache[key] = { ipv4 = {}, ipv6 = {}, missing = true }
                    add_warning(warnings, warning_seen,
                        "geoip:" .. macro.tag .. " is unavailable in " .. path .. "; macro ignored")
                else
                    return nil, data_error
                end
            else
                cache[key] = data
            end
        end

        local values = macro.family == 4 and cache[key].ipv4 or cache[key].ipv6
        if #values == 0 then
            if not cache[key].missing then
                add_warning(warnings, warning_seen,
                    "geoip:" .. macro.tag .. " has no IPv" .. tostring(macro.family) .. " CIDRs; macro ignored")
            end
        else
            queue_geoip_elements(deferred, deferred_order, macro.set, values)
        end

        segment, next_position = omit_empty_macro(segment, raw, next_position)
        output[#output + 1] = segment
        position = next_position
    end
    output[#output + 1] = raw:sub(position)

    local compiled_output = { remove_empty_elements_blocks(table.concat(output)) }
    append_geoip_elements(compiled_output, deferred_order)
    return table.concat(compiled_output), nil, warnings
end

local command = arg[1]
if command == "compile" then
    local source, source_error = read_file(arg[2])
    if not source then io.stderr:write(source_error .. "\n"); os.exit(1) end
    local compiled, compile_error, warnings = compile(source)
    if not compiled then io.stderr:write(tostring(compile_error) .. "\n"); os.exit(1) end
    local ok, write_error = write_file(arg[3], compiled)
    if not ok then io.stderr:write(tostring(write_error) .. "\n"); os.exit(1) end
    if arg[4] then
        local warning_text = #warnings > 0 and table.concat(warnings, "\n") .. "\n" or ""
        local warning_ok, warning_error = write_file(arg[4], warning_text)
        if not warning_ok then io.stderr:write(tostring(warning_error) .. "\n"); os.exit(1) end
    end
elseif command == "fold" then
    local source = read_file(arg[2]) or ""
    local runtime = read_file(arg[3]) or ""
    local source_sets = nft_source.macro_sets(source, OWNED_TABLE)
    io.write(nft_source.fold_runtime(runtime, source_sets))
else
    io.stderr:write("usage: firewall-geo.lua compile SOURCE OUTPUT [WARNINGS] | fold SOURCE RUNTIME\n")
    os.exit(2)
end
