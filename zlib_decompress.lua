local zlib = {}

-- Safely load the bit manipulation library.
local ok, bit = pcall(require, "bit")
if not ok then
    ok, bit = pcall(require, "bit32")
    if not ok then
        error("FATAL: Could not find 'bit' or 'bit32' library.")
    end
end

local string_byte = string.byte
local string_char = string.char
local table_concat = table.concat
local lshift, rshift, band, bor = bit.lshift, bit.rshift, bit.band, bit.bor

function zlib.decompress(data)
    local state = {
        data = data,
        pos = 1,
        bit_buffer = 0,
        bit_count = 0,
        output = {},
        loop = true
    }

    local function get_bits(n)
        while state.bit_count < n do
            local byte = string_byte(state.data, state.pos)
            if not byte then error("Unexpected end of data stream", 2) end
            state.bit_buffer = bor(state.bit_buffer, lshift(byte, state.bit_count))
            state.pos = state.pos + 1
            state.bit_count = state.bit_count + 8
        end
        local result = band(state.bit_buffer, lshift(1, n) - 1)
        state.bit_buffer = rshift(state.bit_buffer, n)
        state.bit_count = state.bit_count - n
        return result
    end

    local function huffman_decode(tree, max_bits)
        local code = 0
        for i = 1, max_bits do
            code = bor(lshift(code, 1), get_bits(1))
            local symbol = tree[i][code]
            if symbol then return symbol end
        end
        error("Invalid Huffman code", 2)
    end

    local function build_huffman_tree(lengths)
        local max_bits = 0
        for _, len in ipairs(lengths) do if len > max_bits then max_bits = len end end
        local tree = {}
        for i = 1, max_bits do tree[i] = {} end
        local code = 0
        local bl_count = {}
        for i = 1, max_bits do bl_count[i] = 0 end
        for _, len in ipairs(lengths) do if len > 0 then bl_count[len] = bl_count[len] + 1 end end
        
        local next_code = {}
        bl_count[0] = 0
        for i = 1, max_bits do
            code = lshift(code + bl_count[i - 1], 1)
            next_code[i] = code
        end

        for i, len in ipairs(lengths) do
            if len > 0 then
                tree[len][next_code[len]] = i - 1
                next_code[len] = next_code[len] + 1
            end
        end
        return tree, max_bits
    end

    state.pos = state.pos + 2
    while state.loop do
        local bfinal = get_bits(1)
        if bfinal == 1 then state.loop = false end
        local btype = get_bits(2)

        if btype == 0 then
            state.bit_buffer, state.bit_count = 0, 0
            local len = string_byte(state.data, state.pos) + string_byte(state.data, state.pos + 1) * 256
            state.pos = state.pos + 4
            for i = 1, len do table.insert(state.output, string_char(string_byte(state.data, state.pos))); state.pos = state.pos + 1 end
        else
            local lit_len_tree, dist_tree, lit_len_max_bits, dist_max_bits
            if btype == 1 then
                local lengths = {}; for i=0,143 do lengths[i+1]=8 end; for i=144,255 do lengths[i+1]=9 end; for i=256,279 do lengths[i+1]=7 end; for i=280,287 do lengths[i+1]=8 end
                lit_len_tree, lit_len_max_bits = build_huffman_tree(lengths)
                lengths = {}; for i=0,31 do lengths[i+1]=5 end
                dist_tree, dist_max_bits = build_huffman_tree(lengths)
            else
                local hlit, hdist, hclen = get_bits(5) + 257, get_bits(5) + 1, get_bits(4) + 4
                local clen_order = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}; local clen_lengths = {}; for i=1,19 do clen_lengths[i]=0 end
                for i=1,hclen do clen_lengths[clen_order[i]+1] = get_bits(3) end
                local clen_tree, clen_max_bits = build_huffman_tree(clen_lengths)
                local lengths, n = {}, 1
                while n <= hlit + hdist do
                    local symbol = huffman_decode(clen_tree, clen_max_bits)
                    if symbol < 16 then lengths[n] = symbol; n = n + 1
                    elseif symbol == 16 then local repeat_len = lengths[n-1]; for j=1,get_bits(2)+3 do lengths[n]=repeat_len; n=n+1 end
                    elseif symbol == 17 then for j=1,get_bits(3)+3 do lengths[n]=0; n=n+1 end
                    else for j=1,get_bits(7)+11 do lengths[n]=0; n=n+1 end
                    end
                end
                local lit_len_lengths, dist_lengths = {}, {}; for i=1,hlit do lit_len_lengths[i] = lengths[i] end; for i=1,hdist do dist_lengths[i] = lengths[hlit+i] end
                lit_len_tree, lit_len_max_bits = build_huffman_tree(lit_len_lengths); dist_tree, dist_max_bits = build_huffman_tree(dist_lengths)
            end
            while true do
                local symbol = huffman_decode(lit_len_tree, lit_len_max_bits)
                if symbol < 256 then table.insert(state.output, string_char(symbol))
                elseif symbol == 256 then break
                else
                    local len_base = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
                    local len_extra_bits = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
                    local len = len_base[symbol-256] + get_bits(len_extra_bits[symbol-256])
                    local dist_symbol = huffman_decode(dist_tree, dist_max_bits)
                    local dist_base = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
                    local dist_extra_bits = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
                    local dist = dist_base[dist_symbol+1] + get_bits(dist_extra_bits[dist_symbol+1])
                    for i=1,len do table.insert(state.output, state.output[#state.output-dist+1]) end
                end
            end
        end
    end
    return table_concat(state.output)
end

return zlib