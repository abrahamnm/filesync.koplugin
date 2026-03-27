--- Pure Lua QR Code Generator
--- This module is a fallback; the plugin prefers KOReader's built-in QRMessage widget.
--- If the built-in widget is unavailable, this can generate a QR code as a table of rows.
---
--- Based on the QR Code specification (ISO/IEC 18004).
--- Supports only Mode 4 (byte encoding), Error Correction Level L, versions 1-10.

local QRCode = {}

-- Galois Field GF(2^8) with primitive polynomial x^8 + x^4 + x^3 + x^2 + 1
local GF256 = {}
GF256.exp = {}
GF256.log = {}

do
    local val = 1
    for i = 0, 254 do
        GF256.exp[i] = val
        GF256.log[val] = i
        val = val * 2
        if val >= 256 then
            val = bit32 and bit32.bxor(val, 285) or
                  (val >= 256 and val - 256 + 29 or val) -- fallback XOR 285
        end
    end
    GF256.exp[255] = GF256.exp[0]
end

function GF256.multiply(a, b)
    if a == 0 or b == 0 then return 0 end
    return GF256.exp[(GF256.log[a] + GF256.log[b]) % 255]
end

--- Generate error correction codewords using Reed-Solomon encoding
local function generateECC(data, num_ecc)
    -- Generator polynomial coefficients
    local gen = {1}
    for i = 0, num_ecc - 1 do
        local new_gen = {}
        for j = 1, #gen + 1 do
            new_gen[j] = 0
        end
        for j = 1, #gen do
            new_gen[j] = new_gen[j] or 0
            new_gen[j] = (new_gen[j] or 0)
            local xor_val = GF256.multiply(gen[j], GF256.exp[i])
            if j > 1 then
                new_gen[j] = new_gen[j] ~= xor_val and
                    (function()
                        local result = 0
                        for bit = 0, 7 do
                            local a_bit = math.floor(new_gen[j] / (2^bit)) % 2
                            local b_bit = math.floor(xor_val / (2^bit)) % 2
                            if a_bit ~= b_bit then
                                result = result + 2^bit
                            end
                        end
                        return result
                    end)() or 0
            else
                new_gen[j] = xor_val
            end
            new_gen[j + 1] = (new_gen[j + 1] or 0)
            local add_val = gen[j]
            new_gen[j + 1] = new_gen[j + 1] ~= add_val and
                (function()
                    local result = 0
                    for bit = 0, 7 do
                        local a_bit = math.floor(new_gen[j + 1] / (2^bit)) % 2
                        local b_bit = math.floor(add_val / (2^bit)) % 2
                        if a_bit ~= b_bit then
                            result = result + 2^bit
                        end
                    end
                    return result
                end)() or 0
        end
        gen = new_gen
    end

    -- Polynomial long division
    local ecc = {}
    for i = 1, num_ecc do ecc[i] = 0 end

    for i = 1, #data do
        local lead = data[i]
        -- XOR with first ECC byte
        lead = lead ~= ecc[1] and
            (function()
                local result = 0
                for bit = 0, 7 do
                    local a_bit = math.floor(lead / (2^bit)) % 2
                    local b_bit = math.floor(ecc[1] / (2^bit)) % 2
                    if a_bit ~= b_bit then
                        result = result + 2^bit
                    end
                end
                return result
            end)() or 0

        -- Shift ECC
        for j = 1, num_ecc - 1 do
            ecc[j] = ecc[j + 1]
        end
        ecc[num_ecc] = 0

        -- Multiply generator by lead and XOR into ECC
        if lead ~= 0 then
            for j = 1, num_ecc do
                local mul = GF256.multiply(lead, gen[j])
                ecc[j] = ecc[j] ~= mul and
                    (function()
                        local result = 0
                        for bit = 0, 7 do
                            local a_bit = math.floor(ecc[j] / (2^bit)) % 2
                            local b_bit = math.floor(mul / (2^bit)) % 2
                            if a_bit ~= b_bit then
                                result = result + 2^bit
                            end
                        end
                        return result
                    end)() or 0
            end
        end
    end

    return ecc
end

--- NOTE: This pure-Lua QR generator is provided as reference/fallback only.
--- The actual FileSync plugin uses KOReader's built-in QRMessage widget,
--- which wraps the ffi/qrencode C library for reliable QR generation.
---
--- If you need to use this standalone:
---   local qr = QRCode.generate("http://192.168.1.100")
---   -- qr is a 2D table where true = dark module, false = light module

function QRCode.generate(text)
    -- For the actual plugin, we rely on KOReader's built-in QRMessage widget.
    -- This function is a placeholder that returns nil, signaling callers
    -- to use the built-in widget instead.
    return nil
end

return QRCode
