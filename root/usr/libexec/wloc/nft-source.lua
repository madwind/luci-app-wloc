-- SPDX-License-Identifier: Apache-2.0
-- Narrow parser for WLOC-owned nftables tables and GeoIP macros.

local M = {}

local function mask(raw)
    local output, quoted, escaped, comment = {}, false, false, false
    for index = 1, #raw do
        local character = raw:sub(index, index)
        if comment then
            if character == "\n" then comment = false; output[#output + 1] = character else output[#output + 1] = " " end
        elseif quoted then
            output[#output + 1] = character == "\n" and character or " "
            if escaped then escaped = false elseif character == "\\" then escaped = true elseif character == '"' then quoted = false end
        elseif character == "#" then
            comment = true; output[#output + 1] = " "
        elseif character == '"' then
            quoted = true; output[#output + 1] = " "
        else
            output[#output + 1] = character
        end
    end
    return table.concat(output)
end

local function matching_brace(text, open_position, limit)
    local depth, last = 0, math.min(limit or #text, #text)
    for position = open_position, last do
        local character = text:sub(position, position)
        if character == "{" then depth = depth + 1
        elseif character == "}" then
            depth = depth - 1
            if depth == 0 then return position end
            if depth < 0 then return nil end
        end
    end
end

local function skip_space(text, position)
    while position <= #text and text:sub(position, position):match("%s") do position = position + 1 end
    return position
end

local function count_elements(body)
    local count = 0
    for value in mask(body or ""):gmatch("[^,]+") do
        if value:match("%S") then count = count + 1 end
    end
    return count
end

local function fold_elements(body)
    body = tostring(body or "")
    local count = count_elements(body)
    local leading = body:match("^(%s*)") or ""
    local trailing = body:match("(%s*)$") or ""
    if leading == "" and trailing == "" then
        return " # " .. tostring(count) .. " entries "
    end
    return leading .. "# " .. tostring(count) .. " entries" .. trailing
end

function M.parse(raw)
    raw = tostring(raw or "")
    local text, tables, position = mask(raw), {}, 1
    while true do
        position = skip_space(text, position)
        if position > #text then break end
        local start_position, open_position, family, name = text:find(
            "%f[%a]table%f[%A]%s+([%a%d]+)%s+([%a_][%w_.%-]*)%s*{", position)
        if start_position ~= position then return nil, "unsupported top-level nft statement" end
        local close_position = matching_brace(text, open_position)
        if not close_position then return nil, "unbalanced nft table block" end
        tables[#tables + 1] = {
            family = family, name = name, key = family .. " " .. name,
            start_position = start_position, open_position = open_position, close_position = close_position
        }
        position = close_position + 1
    end

    local sets = {}
    for _, table_spec in ipairs(tables) do
        position = table_spec.open_position + 1
        while position < table_spec.close_position do
            local start_position, open_position, name = text:find(
                "%f[%a]set%f[%A]%s+([%a_][%w_.%-]*)%s*{", position)
            if not start_position or start_position >= table_spec.close_position then break end
            local close_position = matching_brace(text, open_position, table_spec.close_position)
            if not close_position then return nil, "unbalanced nft set block" end
            local block = text:sub(open_position + 1, close_position - 1)
            local set_type = block:match("%f[%a]type%f[%A]%s+([%w_.%-]+)")
            local elements_start, elements_open = text:find("%f[%a]elements%f[%A]%s*=%s*{", open_position + 1)
            local elements_close
            if elements_start and elements_start < close_position then
                elements_close = matching_brace(text, elements_open, close_position)
                if not elements_close then return nil, "unbalanced nft set elements block" end
            else
                elements_start, elements_open = nil, nil
            end
            sets[#sets + 1] = {
                table_family = table_spec.family, table_name = table_spec.name, table_key = table_spec.key,
                name = name, key = table_spec.key .. "\0" .. name, type = set_type,
                start_position = start_position, open_position = open_position, close_position = close_position,
                elements_start = elements_start, elements_open = elements_open, elements_close = elements_close,
                elements_body = elements_open and raw:sub(elements_open + 1, elements_close - 1) or nil
            }
            position = close_position + 1
        end
    end
    return { raw = raw, text = text, tables = tables, sets = sets }
end

function M.inspect(raw, owned_table)
    local parsed, parse_error = M.parse(raw)
    if not parsed then return nil, parse_error end
    if parsed.text:match("%f[%a]include%f[%A]") then return nil, "firewall file must not use include directives" end
    for _, table_spec in ipairs(parsed.tables) do
        if table_spec.name ~= owned_table then return nil, "firewall file may only manage tables named " .. owned_table end
    end

    local macros, macro_start, search_position = {}, {}, 1
    while true do
        local start_position, finish_position, tag = parsed.text:find("%%geoip:([%w_-]+)%%", search_position)
        if not start_position then break end
        if #tag > 63 then return nil, "GeoIP macro tag is too long" end
        local owner
        for _, set_spec in ipairs(parsed.sets) do
            if set_spec.elements_open and start_position > set_spec.elements_open and finish_position < set_spec.elements_close then
                owner = set_spec; break
            end
        end
        if not owner then return nil, "%geoip:<tag>% may only be used inside a named set elements block" end
        local family
        if owner.type == "ipv4_addr" then family = 4
        elseif owner.type == "ipv6_addr" then family = 6
        else return nil, "%geoip:<tag>% requires a set of type ipv4_addr or ipv6_addr" end
        macros[#macros + 1] = {
            start_position = start_position, finish_position = finish_position,
            tag = tag, family = family, set = owner
        }
        macro_start[start_position] = true
        owner.has_geoip_macro = true
        search_position = finish_position + 1
    end

    local literal_position = 1
    while true do
        local found = parsed.text:find("%geoip:", literal_position, true)
        if not found then break end
        if not macro_start[found] then return nil, "invalid GeoIP macro; expected %geoip:<tag>%" end
        literal_position = found + 1
    end
    parsed.macros = macros
    return parsed
end

function M.macro_sets(source, owned_table)
    if not source or source == "" then return {} end
    local parsed = M.inspect(source, owned_table)
    if not parsed then return {} end
    local result = {}
    for _, set_spec in ipairs(parsed.sets) do
        if set_spec.has_geoip_macro then result[set_spec.key] = set_spec end
    end
    return result
end

function M.fold_runtime(runtime, source_sets)
    if not source_sets or next(source_sets) == nil then return runtime end
    local parsed = M.parse(runtime)
    if not parsed then return runtime end
    local replacements = {}
    for _, set_spec in ipairs(parsed.sets) do
        local source = source_sets[set_spec.key]
        if source and set_spec.elements_open and source.elements_body ~= nil then
            replacements[#replacements + 1] = {
                start_position = set_spec.elements_open + 1,
                finish_position = set_spec.elements_close - 1,
                value = fold_elements(set_spec.elements_body)
            }
        end
    end
    table.sort(replacements, function(left, right) return left.start_position > right.start_position end)
    for _, replacement in ipairs(replacements) do
        runtime = runtime:sub(1, replacement.start_position - 1) .. replacement.value ..
            runtime:sub(replacement.finish_position + 1)
    end
    return runtime
end

return M
