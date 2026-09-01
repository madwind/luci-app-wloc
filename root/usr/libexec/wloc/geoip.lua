-- SPDX-License-Identifier: Apache-2.0
-- Minimal Xray/V2Ray geoip.dat reader used by WLOC nftables macros.

local M = {}

local function read_varint_file(file)
    local value, multiplier = 0, 1
    for _ = 1, 10 do
        local raw = file:read(1)
        if not raw then return nil, "unexpected end of GeoIP file" end
        local byte = raw:byte()
        value = value + (byte % 128) * multiplier
        if byte < 128 then return value end
        multiplier = multiplier * 128
    end
    return nil, "invalid protobuf varint"
end

local function read_varint(data, position)
    local value, multiplier = 0, 1
    for _ = 1, 10 do
        local byte = data:byte(position)
        if not byte then return nil, nil, "unexpected end of protobuf message" end
        position = position + 1
        value = value + (byte % 128) * multiplier
        if byte < 128 then return value, position end
        multiplier = multiplier * 128
    end
    return nil, nil, "invalid protobuf varint"
end

local function skip_wire(data, position, wire)
    if wire == 0 then
        local _, next_position, err = read_varint(data, position)
        return next_position, err
    elseif wire == 1 then
        if position + 7 > #data then return nil, "truncated protobuf fixed64" end
        return position + 8
    elseif wire == 2 then
        local length, next_position, err = read_varint(data, position)
        if not length then return nil, err end
        local finish = next_position + length
        if finish - 1 > #data then return nil, "truncated protobuf bytes" end
        return finish
    elseif wire == 5 then
        if position + 3 > #data then return nil, "truncated protobuf fixed32" end
        return position + 4
    end
    return nil, "unsupported protobuf wire type " .. tostring(wire)
end

local function load_body(path, tag)
    local file, open_error = io.open(path, "rb")
    if not file then
        return nil, open_error or ("cannot open " .. path), "missing_file"
    end

    local code = string.upper(tag)
    while true do
        local field_key = file:read(1)
        if not field_key then
            file:close()
            return nil, "GeoIP tag not found in " .. path .. ": " .. tag, "missing_tag"
        end
        if field_key:byte() ~= 10 then
            file:close()
            return nil, "unsupported GeoIP database structure", "invalid"
        end

        local body_length, length_error = read_varint_file(file)
        if not body_length then
            file:close()
            return nil, length_error, "invalid"
        end
        if body_length < 1 or body_length > 64 * 1024 * 1024 then
            file:close()
            return nil, "invalid GeoIP entry length", "invalid"
        end

        local prefix_length = math.min(body_length, #code + 2)
        local prefix = file:read(prefix_length)
        if not prefix or #prefix ~= prefix_length then
            file:close()
            return nil, "truncated GeoIP entry", "invalid"
        end

        local matched = body_length >= #code + 2 and prefix:byte(1) == 10 and
            prefix:byte(2) == #code and prefix:sub(3, #code + 2) == code
        local remaining = body_length - prefix_length
        if matched then
            local tail = remaining > 0 and file:read(remaining) or ""
            file:close()
            if not tail or #tail ~= remaining then
                return nil, "truncated GeoIP entry body", "invalid"
            end
            return prefix .. tail
        end

        if remaining > 0 and not file:seek("cur", remaining) then
            file:close()
            return nil, "cannot seek through GeoIP file", "invalid"
        end
    end
end

local function parse_cidr(data)
    local position, ip, prefix = 1, nil, nil
    while position <= #data do
        local key, next_position, err = read_varint(data, position)
        if not key then return nil, err end
        position = next_position
        local field, wire = math.floor(key / 8), key % 8
        if field == 1 and wire == 2 then
            local length, content_position
            length, content_position, err = read_varint(data, position)
            if not length then return nil, err end
            local finish = content_position + length - 1
            if finish > #data then return nil, "truncated CIDR address" end
            ip = data:sub(content_position, finish)
            position = finish + 1
        elseif field == 2 and wire == 0 then
            prefix, position, err = read_varint(data, position)
            if prefix == nil then return nil, err end
        else
            position, err = skip_wire(data, position, wire)
            if not position then return nil, err end
        end
    end

    if not ip or prefix == nil then return nil, "incomplete CIDR entry in GeoIP data" end
    if #ip ~= 4 and #ip ~= 16 then return nil, "unsupported GeoIP address length " .. tostring(#ip) end
    if (#ip == 4 and prefix > 32) or (#ip == 16 and prefix > 128) then
        return nil, "invalid GeoIP CIDR prefix"
    end
    return { ip = ip, prefix = prefix, family = #ip == 4 and 4 or 6 }
end

local function parse_body(body)
    local position = 1
    local result = { ipv4 = {}, ipv6 = {} }
    while position <= #body do
        local key, next_position, err = read_varint(body, position)
        if not key then return nil, err end
        position = next_position
        local field, wire = math.floor(key / 8), key % 8
        if field == 2 and wire == 2 then
            local length, content_position
            length, content_position, err = read_varint(body, position)
            if not length then return nil, err end
            local finish = content_position + length - 1
            if finish > #body then return nil, "truncated GeoIP CIDR message" end
            local cidr, cidr_error = parse_cidr(body:sub(content_position, finish))
            if not cidr then return nil, cidr_error end
            local target = cidr.family == 4 and result.ipv4 or result.ipv6
            target[#target + 1] = cidr
            position = finish + 1
        elseif field == 3 and wire == 0 then
            local reverse
            reverse, position, err = read_varint(body, position)
            if reverse == nil then return nil, err end
            if reverse ~= 0 then
                return nil, "reverse-match GeoIP entries cannot be expanded into nftables elements"
            end
        else
            position, err = skip_wire(body, position, wire)
            if not position then return nil, err end
        end
    end
    return result
end

local function format_cidr(cidr)
    local bytes = { cidr.ip:byte(1, #cidr.ip) }
    if cidr.family == 4 then
        return string.format("%d.%d.%d.%d/%d", bytes[1], bytes[2], bytes[3], bytes[4], cidr.prefix)
    end

    local groups = {}
    for index = 1, 16, 2 do
        groups[#groups + 1] = string.format("%x", bytes[index] * 256 + bytes[index + 1])
    end
    return table.concat(groups, ":") .. "/" .. tostring(cidr.prefix)
end

function M.load(path, tag)
    local body, body_error, body_kind = load_body(path, tag)
    if not body then return nil, body_error, body_kind end

    local parsed, parse_error = parse_body(body)
    if not parsed then return nil, parse_error, "invalid" end

    local result = { ipv4 = {}, ipv6 = {} }
    for _, cidr in ipairs(parsed.ipv4) do
        result.ipv4[#result.ipv4 + 1] = format_cidr(cidr)
    end
    for _, cidr in ipairs(parsed.ipv6) do
        result.ipv6[#result.ipv6 + 1] = format_cidr(cidr)
    end
    return result
end

return M
