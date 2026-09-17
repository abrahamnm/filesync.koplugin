-- Stub LuaSocket and UIManager before loading the module so the wire-format
-- functions can be exercised without touching the network.
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end,
    show = function() end,
}

-- Fake UDP socket: records every sendto() and lets tests inject failures.
local function fake_udp(overrides)
    local sock = { sent = {}, options = {}, closed = false, inbox = {} }
    function sock:setoption(name, value) self.options[name] = value; return 1 end
    function sock:setsockname() return 1 end
    function sock:settimeout() end
    function sock:close() self.closed = true end
    function sock:sendto(data, ip, port) table.insert(self.sent, { data = data, ip = ip, port = port }); return #data end
    function sock:receivefrom()
        local msg = table.remove(self.inbox, 1)
        if not msg then return nil, "timeout" end
        return msg.data, msg.ip, msg.port
    end
    for k, v in pairs(overrides or {}) do sock[k] = v end
    return sock
end

local current_udp
package.loaded["socket"] = {
    udp = function() return current_udp end,
    gettime = function() return 0 end,
    bind = function() return nil, "stub" end,
}

local Mdns = require("filesync/mdns")

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x ", c:byte()) end)):gsub(" $", "")
end

local function bytes(...)
    return string.char(...)
end

--- Hand-assemble a query packet for one question.
local function query_packet(id, name, qtype, qclass)
    return bytes(math.floor(id / 256), id % 256) -- ID
        .. bytes(0x00, 0x00)                     -- flags: standard query
        .. bytes(0x00, 0x01)                     -- QDCOUNT 1
        .. bytes(0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        .. Mdns.encodeName(name)
        .. bytes(math.floor(qtype / 256), qtype % 256)
        .. bytes(math.floor(qclass / 256), qclass % 256)
end

local function new_responder(o)
    o = o or {}
    return Mdns:new{
        hostname = o.hostname or "filesync",
        port = o.port or 80,
        ip = o.ip or "192.168.1.5",
    }
end

describe("filesync.mdns", function()

    describe("encodeName / decodeName", function()
        it("encodes labels with length prefixes and a zero terminator", function()
            assert.are.equal("\8filesync\5local\0", Mdns.encodeName("filesync.local"))
        end)

        it("tolerates a trailing dot", function()
            assert.are.equal("\8filesync\5local\0", Mdns.encodeName("filesync.local."))
        end)

        it("round-trips a name", function()
            local encoded = Mdns.encodeName("_http._tcp.local")
            local name, after = Mdns.decodeName(encoded, 1)
            assert.are.equal("_http._tcp.local", name)
            assert.are.equal(#encoded + 1, after)
        end)

        it("follows compression pointers", function()
            -- Layout: [0..15] "filesync.local\0" then at offset 16: "\3www" + pointer to 0
            local base = Mdns.encodeName("filesync.local") -- 16 bytes, offsets 0..15
            local packet = base .. "\3www" .. bytes(0xC0, 0x00)
            local name, after = Mdns.decodeName(packet, #base + 1)
            assert.are.equal("www.filesync.local", name)
            -- The caller's stream continues right after the 2-byte pointer.
            assert.are.equal(#packet + 1, after)
        end)

        it("rejects pointer loops", function()
            -- A pointer that points at itself.
            local packet = bytes(0xC0, 0x00)
            local name, err = Mdns.decodeName(packet, 1)
            assert.is_nil(name)
            assert.is_string(err)
        end)

        it("rejects names that run past the packet", function()
            local name = Mdns.decodeName("\10abc", 1)
            assert.is_nil(name)
        end)
    end)

    describe("parseQuery", function()
        it("parses an A query for filesync.local", function()
            local pkt = query_packet(0x1234, "filesync.local", Mdns.TYPE_A, Mdns.CLASS_IN)
            local parsed = Mdns.parseQuery(pkt)
            assert.are.equal(0x1234, parsed.id)
            assert.is_false(parsed.is_response)
            assert.are.equal(1, #parsed.questions)
            local q = parsed.questions[1]
            assert.are.equal("filesync.local", q.name)
            assert.are.equal(Mdns.TYPE_A, q.qtype)
            assert.are.equal(Mdns.CLASS_IN, q.qclass)
            assert.is_false(q.unicast_response)
        end)

        it("parses a PTR query for _http._tcp.local with the unicast bit", function()
            local pkt = query_packet(0, "_http._tcp.local", Mdns.TYPE_PTR, 0x8001)
            local parsed = Mdns.parseQuery(pkt)
            local q = parsed.questions[1]
            assert.are.equal("_http._tcp.local", q.name)
            assert.are.equal(Mdns.TYPE_PTR, q.qtype)
            assert.are.equal(Mdns.CLASS_IN, q.qclass)
            assert.is_true(q.unicast_response)
        end)

        it("flags responses", function()
            local pkt = query_packet(0, "filesync.local", Mdns.TYPE_A, 1)
            pkt = pkt:sub(1, 2) .. bytes(0x84, 0x00) .. pkt:sub(5)
            assert.is_true(Mdns.parseQuery(pkt).is_response)
        end)

        it("rejects packets shorter than a header", function()
            assert.is_nil(Mdns.parseQuery("abc"))
        end)

        it("rejects a truncated question", function()
            local pkt = query_packet(0, "filesync.local", Mdns.TYPE_A, 1)
            assert.is_nil(Mdns.parseQuery(pkt:sub(1, #pkt - 2)))
        end)
    end)

    describe("buildResponse", function()
        it("encodes an A record response with the expected bytes", function()
            local r = new_responder()
            local a = r:getRecords()[1]
            local pkt = Mdns.buildResponse({ answers = { a } })
            local expected = "00 00 84 00 00 00 00 01 00 00 00 00"
                .. " 08 66 69 6c 65 73 79 6e 63 05 6c 6f 63 61 6c 00"
                .. " 00 01 80 01 00 00 00 78 00 04 c0 a8 01 05"
            assert.are.equal(expected, hex(pkt))
        end)

        it("encodes a PTR record without cache-flush and with TTL 4500", function()
            local r = new_responder()
            local ptr = r:getRecords()[2]
            local pkt = Mdns.buildResponse({ answers = { ptr } })
            local body = pkt:sub(13)
            local name_len = #Mdns.encodeName("_http._tcp.local")
            assert.are.equal("00 0c 00 01 00 00 11 94", hex(body:sub(name_len + 1, name_len + 8)))
            local rdata = body:sub(name_len + 11)
            assert.are.equal("FileSync on filesync._http._tcp.local", (Mdns.decodeName(rdata, 1)))
        end)

        it("encodes an SRV record with the port and target", function()
            local r = new_responder({ port = 8080 })
            local srv = r:getRecords()[4]
            assert.are.equal(Mdns.TYPE_SRV, srv.rtype)
            -- priority 0, weight 0, port 8080 (0x1f90), target filesync.local
            assert.are.equal("00 00 00 00 1f 90 " .. hex(Mdns.encodeName("filesync.local")), hex(srv.rdata))
            assert.is_true(srv.cache_flush)
        end)

        it("encodes a TXT record with path=/", function()
            local r = new_responder()
            local txt = r:getRecords()[5]
            assert.are.equal(Mdns.TYPE_TXT, txt.rtype)
            assert.are.equal("\6path=/", txt.rdata)
        end)

        it("counts additionals in ARCOUNT", function()
            local r = new_responder()
            local recs = r:getRecords()
            local pkt = Mdns.buildResponse({ answers = { recs[2] }, additionals = { recs[4], recs[5], recs[1] } })
            assert.are.equal("00 00 84 00 00 00 00 01 00 00 00 03", hex(pkt:sub(1, 12)))
        end)

        it("copies the ID when given", function()
            local pkt = Mdns.buildResponse({ id = 0xBEEF, answers = {} })
            assert.are.equal("be ef", hex(pkt:sub(1, 2)))
        end)
    end)

    describe("goodbye packet", function()
        it("carries TTL 0 on every record", function()
            local r = new_responder()
            for _, rr in ipairs(r:getRecords(0, 0)) do
                assert.are.equal(0, rr.ttl)
                local enc = Mdns.encodeRecord(rr)
                local name_len = #Mdns.encodeName(rr.name)
                assert.are.equal("00 00 00 00", hex(enc:sub(name_len + 5, name_len + 8)))
            end
        end)
    end)

    describe("answerQuestion", function()
        it("matches names case-insensitively", function()
            local r = new_responder()
            local answers = r:answerQuestion({ name = "FileSync.LOCAL", qtype = Mdns.TYPE_A, qclass = 1 })
            assert.are.equal(1, #answers)
            assert.are.equal(Mdns.TYPE_A, answers[1].rtype)
        end)

        it("returns nothing for unknown names", function()
            local r = new_responder()
            local answers = r:answerQuestion({ name = "other.local", qtype = Mdns.TYPE_A, qclass = 1 })
            assert.are.equal(0, #answers)
        end)

        it("ignores AAAA queries", function()
            local r = new_responder()
            local answers = r:answerQuestion({ name = "filesync.local", qtype = 28, qclass = 1 })
            assert.are.equal(0, #answers)
        end)

        it("answers ANY with every record for the name", function()
            local r = new_responder()
            local answers, additionals = r:answerQuestion({
                name = "FileSync on filesync._http._tcp.local", qtype = Mdns.TYPE_ANY, qclass = 1 })
            assert.are.equal(2, #answers)
            assert.are.equal(1, #additionals)
            assert.are.equal(Mdns.TYPE_A, additionals[1].rtype)
        end)

        it("adds SRV, TXT and A as additionals for the service PTR", function()
            local r = new_responder()
            local answers, additionals = r:answerQuestion({ name = "_http._tcp.local", qtype = Mdns.TYPE_PTR, qclass = 1 })
            assert.are.equal(1, #answers)
            local kinds = {}
            for _, rr in ipairs(additionals) do kinds[#kinds + 1] = rr.kind end
            assert.are.same({ "srv", "txt", "a" }, kinds)
        end)

        it("answers the service enumeration PTR", function()
            local r = new_responder()
            local answers = r:answerQuestion({ name = "_services._dns-sd._udp.local", qtype = Mdns.TYPE_PTR, qclass = 1 })
            assert.are.equal(1, #answers)
            assert.are.equal(Mdns.rdataPTR("_http._tcp.local"), answers[1].rdata)
        end)
    end)

    describe("isValidHostname", function()
        it("accepts plain labels", function()
            assert.is_true(Mdns.isValidHostname("filesync"))
            assert.is_true(Mdns.isValidHostname("my-kobo-2"))
        end)

        it("rejects bad labels", function()
            assert.is_false(Mdns.isValidHostname(""))
            assert.is_false(Mdns.isValidHostname("-abc"))
            assert.is_false(Mdns.isValidHostname("abc-"))
            assert.is_false(Mdns.isValidHostname("file sync"))
            assert.is_false(Mdns.isValidHostname("filesync.local"))
            assert.is_false(Mdns.isValidHostname("FileSync"))
            assert.is_false(Mdns.isValidHostname(string.rep("a", 64)))
            assert.is_false(Mdns.isValidHostname(nil))
        end)
    end)

    describe("socket layer", function()
        before_each(function()
            scheduled = {}
        end)

        it("returns false without throwing when bind fails", function()
            current_udp = fake_udp({ setsockname = function() return nil, "address already in use" end })
            local r = new_responder()
            local ok = r:start()
            assert.is_false(ok)
            assert.is_false(r:isRunning())
            assert.is_true(current_udp.closed)
        end)

        it("returns false when the multicast join fails", function()
            current_udp = fake_udp({ setoption = function(_, name)
                if name == "ip-add-membership" then return nil, "unsupported" end
                return 1
            end })
            local r = new_responder()
            assert.is_false(r:start())
            assert.is_true(current_udp.closed)
        end)

        it("returns false when no IP is known", function()
            current_udp = fake_udp()
            local r = Mdns:new{ hostname = "filesync", port = 80 }
            assert.is_false(r:start())
        end)

        it("announces on start and says goodbye on stop", function()
            current_udp = fake_udp()
            local r = new_responder()
            assert.is_true(r:start())
            assert.is_true(r:isRunning())
            assert.are.equal(1, #current_udp.sent)
            assert.are.equal(Mdns.MDNS_ADDR, current_udp.sent[1].ip)
            assert.are.equal(Mdns.MDNS_PORT, current_udp.sent[1].port)
            -- Header: 5 answers, no additionals.
            assert.are.equal("00 00 84 00 00 00 00 05 00 00 00 00", hex(current_udp.sent[1].data:sub(1, 12)))
            -- Second announcement is scheduled ~1 s later, not sent inline.
            assert.are.equal(1, scheduled[1].delay)
            scheduled[1].fn()
            assert.are.equal(2, #current_udp.sent)

            r:stop()
            assert.is_false(r:isRunning())
            assert.is_true(current_udp.closed)
            local goodbye = current_udp.sent[3].data
            local a_len = #Mdns.encodeRecord(r:getRecords(0, 0)[1])
            -- TTL of the first (A) record is zero.
            assert.are.equal("00 00 00 00", hex(goodbye:sub(12 + a_len - 9, 12 + a_len - 6)))
        end)

        it("replies via multicast to a normal query and via unicast when asked", function()
            current_udp = fake_udp()
            local r = new_responder()
            r:start()
            current_udp.sent = {}

            table.insert(current_udp.inbox, {
                data = query_packet(0x4242, "filesync.local", Mdns.TYPE_A, Mdns.CLASS_IN),
                ip = "192.168.1.20", port = Mdns.MDNS_PORT })
            r:_poll()
            assert.are.equal(1, #current_udp.sent)
            assert.are.equal(Mdns.MDNS_ADDR, current_udp.sent[1].ip)
            -- ID is 0 for multicast queries even though the query carried one.
            assert.are.equal("00 00", hex(current_udp.sent[1].data:sub(1, 2)))

            table.insert(current_udp.inbox, {
                data = query_packet(0, "filesync.local", Mdns.TYPE_A, 0x8001),
                ip = "192.168.1.20", port = Mdns.MDNS_PORT })
            r:_poll()
            assert.are.equal(2, #current_udp.sent)
            assert.are.equal("192.168.1.20", current_udp.sent[2].ip)
            assert.are.equal(Mdns.MDNS_PORT, current_udp.sent[2].port)
        end)

        it("copies the ID and replies unicast for legacy unicast queries", function()
            current_udp = fake_udp()
            local r = new_responder()
            r:start()
            current_udp.sent = {}
            table.insert(current_udp.inbox, {
                data = query_packet(0x1234, "filesync.local", Mdns.TYPE_A, Mdns.CLASS_IN),
                ip = "192.168.1.20", port = 51000 })
            r:_poll()
            assert.are.equal(1, #current_udp.sent)
            assert.are.equal("192.168.1.20", current_udp.sent[1].ip)
            assert.are.equal(51000, current_udp.sent[1].port)
            assert.are.equal("12 34", hex(current_udp.sent[1].data:sub(1, 2)))
        end)

        it("ignores responses and unrelated queries", function()
            current_udp = fake_udp()
            local r = new_responder()
            r:start()
            current_udp.sent = {}
            local resp = query_packet(0, "filesync.local", Mdns.TYPE_A, 1)
            resp = resp:sub(1, 2) .. bytes(0x84, 0x00) .. resp:sub(5)
            table.insert(current_udp.inbox, { data = resp, ip = "192.168.1.20", port = 5353 })
            table.insert(current_udp.inbox, {
                data = query_packet(0, "printer.local", Mdns.TYPE_A, 1), ip = "192.168.1.20", port = 5353 })
            table.insert(current_udp.inbox, { data = "garbage", ip = "192.168.1.20", port = 5353 })
            r:_poll()
            assert.are.equal(0, #current_udp.sent)
            assert.is_true(r:isRunning())
        end)
    end)
end)
