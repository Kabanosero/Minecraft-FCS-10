-- lib/md5.lua
-- Pure Lua 5.1 MD5 + HMAC-MD5 primitive for CraftOS/CC:Tweaked.
--
-- CC:Tweaked's Lua 5.1 runtime exposes the Lua 5.2-style `bit32` library
-- globally (band/bor/bxor/bnot/lshift/rshift) - that's what this module
-- relies on for all bitwise work, since Lua 5.1 has no native bitwise
-- operators. If you run this outside CraftOS (e.g. unit-testing under
-- vanilla PUC Lua 5.1), load a bit32 polyfill first.
--
-- MD5 is used here strictly as the primitive under HMAC-MD5 LAN-local
-- packet authentication (see secnet.lua) - not for anything that needs
-- real collision resistance.

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift = bit32.lshift, bit32.rshift

local md5 = {}

local K = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local S = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}

local MOD32 = 4294967296

local function leftrotate(x, c)
    return bor(lshift(x, c), rshift(x, 32 - c))
end

local function toHex(raw)
    return (raw:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

-- Pads/splits `msg` (a raw byte string) into 512-bit chunks of sixteen
-- 32-bit little-endian words each. Assumes #msg is well under 2^29 bytes
-- (true for any network packet on this project), so the high 32 bits of
-- the MD5 length field are always zero.
local function preprocess(msg)
    local lenBits = #msg * 8
    msg = msg .. string.char(0x80)
    while (#msg % 64) ~= 56 do
        msg = msg .. string.char(0)
    end
    for i = 0, 3 do
        msg = msg .. string.char(band(rshift(lenBits, i * 8), 0xFF))
    end
    msg = msg .. string.char(0, 0, 0, 0) -- high 32 bits of bit-length, always 0 here

    local chunks = {}
    for chunkStart = 1, #msg, 64 do
        local words = {}
        for w = 0, 15 do
            local base = chunkStart + w * 4
            local b1, b2, b3, b4 = string.byte(msg, base, base + 3)
            words[w] = b1 + lshift(b2, 8) + lshift(b3, 16) + lshift(b4, 24)
        end
        chunks[#chunks + 1] = words
    end
    return chunks
end

-- Returns the raw 16-byte MD5 digest of `msg` (a byte string).
function md5.digestRaw(msg)
    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

    for _, M in ipairs(preprocess(msg)) do
        local A, B, C, D = a0, b0, c0, d0
        for i = 0, 63 do
            local F, g
            if i < 16 then
                F = bor(band(B, C), band(bnot(B), D))
                g = i
            elseif i < 32 then
                F = bor(band(D, B), band(bnot(D), C))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                F = bxor(bxor(B, C), D)
                g = (3 * i + 5) % 16
            else
                F = bxor(C, bor(B, bnot(D)))
                g = (7 * i) % 16
            end
            F = (F + A + K[i + 1] + M[g]) % MOD32
            A = D
            D = C
            C = B
            B = (B + leftrotate(F, S[i + 1])) % MOD32
        end
        a0 = (a0 + A) % MOD32
        b0 = (b0 + B) % MOD32
        c0 = (c0 + C) % MOD32
        d0 = (d0 + D) % MOD32
    end

    local function toLE(n)
        return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF),
                            band(rshift(n, 16), 0xFF), band(rshift(n, 24), 0xFF))
    end
    return toLE(a0) .. toLE(b0) .. toLE(c0) .. toLE(d0)
end

-- Returns the lowercase hex digest of `msg`.
function md5.digestHex(msg)
    return toHex(md5.digestRaw(msg))
end

-- ===========================================================================
-- HMAC-MD5
-- ===========================================================================
local BLOCK_SIZE = 64

local function xorPad(key, padByte)
    local out = {}
    for i = 1, BLOCK_SIZE do
        out[i] = string.char(bxor(string.byte(key, i) or 0, padByte))
    end
    return table.concat(out)
end

-- Returns the raw 16-byte HMAC-MD5 of `message` under `key`.
function md5.hmacRaw(key, message)
    if #key > BLOCK_SIZE then
        key = md5.digestRaw(key)
    end
    if #key < BLOCK_SIZE then
        key = key .. string.rep(string.char(0), BLOCK_SIZE - #key)
    end
    local inner = md5.digestRaw(xorPad(key, 0x36) .. message)
    return md5.digestRaw(xorPad(key, 0x5c) .. inner)
end

-- Returns the lowercase hex HMAC-MD5 of `message` under `key`.
function md5.hmacHex(key, message)
    return toHex(md5.hmacRaw(key, message))
end

return md5
