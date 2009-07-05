local hashes = require "util.hashes"
local xor = require "bit".bxor

module "hmac"

local function arraystr(array)
    local t = {}
    for i = 1,table.getn(array) do
        table.insert(t, string.char(array[i]))
    end

    return table.concat(t)
end

--[[
key
    the key to use in the hash
message
    the message to hash
hash
    the hash function
blocksize
    the blocksize for the hash function in bytes
hex
  return raw hash or hexadecimal string
--]]
function hmac(key, message, hash, blocksize, hex)
    local opad = {}
    local ipad = {}
    
    for i = 1,blocksize do
        opad[i] = 0x5c
        ipad[i] = 0x36
    end

    if #key > blocksize then
        key = hash(key)
    end

    for i = 1,#key do
        ipad[i] = xor(ipad[i],key:sub(i,i):byte())
        opad[i] = xor(opad[i],key:sub(i,i):byte())
    end

    opad = arraystr(opad)
    ipad = arraystr(ipad)

    if hex then
        return hash(opad..hash(ipad..message), true)
    else
        return hash(opad..hash(ipad..message))
    end
end

function md5(key, message, hex)
    return hmac(key, message, hashes.md5, 64, hex)
end

function sha1(key, message, hex)
    return hmac(key, message, hashes.sha1, 64, hex)
end

function sha256(key, message, hex)
    return hmac(key, message, hashes.sha256, 64, hex)
end

return _M
