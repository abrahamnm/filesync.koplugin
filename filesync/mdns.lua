--- Minimal multicast DNS responder (RFC 6762) with DNS-SD advertisement
--- (RFC 6763) for the FileSync plugin.
---
--- Kobo and Kindle ship no mDNS daemon (avahi, mDNSResponder), so the plugin
--- answers `<hostname>.local` queries itself and announces an `_http._tcp`
--- service so the device shows up in Bonjour browsers. Built on a single
--- non-blocking LuaSocket UDP socket, polled from KOReader's UIManager the
--- same way httpserver.lua polls its TCP socket, so it never blocks the UI.
---
--- The module is split in two layers:
---   * pure wire-format functions (encodeName, decodeName, parseQuery,
---     buildResponse, ...) exported on the module table so they can be unit
---     tested without sockets;
---   * the Mdns object (new / start / stop / isRunning) that owns the socket.
---
--- Limitation: no conflict probing is implemented (RFC 6762 section 8.1).
--- If two KOReader devices on the same network share a hostname, both
--- answer and clients will pick one at random; the user should rename one
--- of them through the "Hostname" menu entry.
---
--- Key dependencies: socket (LuaSocket), UIManager (KOReader), logger (KOReader)

local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

-- mDNS link-local multicast group and port (RFC 6762 section 3).
local MDNS_ADDR = "224.0.0.251"
local MDNS_PORT = 5353
-- TTLs recommended by RFC 6762 section 10: 120 s for records whose name is
-- unique to this host, 75 minutes for shared PTR records.
local TTL_UNIQUE = 120
local TTL_SHARED = 4500
-- How often the socket is polled (seconds), mirroring HttpServer.
local POLL_INTERVAL = 0.1
-- Wall-clock budget for one poll cycle (seconds). Packets are tiny, so a
-- generous cap of 8 datagrams within 50 ms keeps the UI responsive.
local MAX_POLL_TIME = 0.05
local MAX_PACKETS_PER_POLL = 8
-- Delay between the two start-up announcements (RFC 6762 section 8.3).
local ANNOUNCE_INTERVAL = 1
-- Bound on compression-pointer hops while decoding a name, so a crafted
-- packet with a pointer loop cannot spin the decoder forever.
local MAX_POINTER_HOPS = 16
-- Largest datagram we bother reading. Queries are far smaller than this.
local MAX_PACKET_SIZE = 9000

-- DNS record types and classes.
local TYPE_A = 1
local TYPE_PTR = 12
local TYPE_TXT = 16
local TYPE_SRV = 33
local TYPE_ANY = 255
local CLASS_IN = 1
-- Top bit of the class field: cache-flush on answers, unicast-response on
-- questions (RFC 6762 sections 10.2 and 5.4).
local CLASS_TOP_BIT = 0x8000

local Mdns = {
    MDNS_ADDR = MDNS_ADDR,
    MDNS_PORT = MDNS_PORT,
    TTL_UNIQUE = TTL_UNIQUE,
    TTL_SHARED = TTL_SHARED,
    TYPE_A = TYPE_A,
    TYPE_PTR = TYPE_PTR,
    TYPE_TXT = TYPE_TXT,
    TYPE_SRV = TYPE_SRV,
    TYPE_ANY = TYPE_ANY,
    CLASS_IN = CLASS_IN,
    CLASS_CACHE_FLUSH = CLASS_TOP_BIT,
}
Mdns.__index = Mdns

------------------------------------------------------------------------------
-- Pure wire-format helpers (no sockets; Lua 5.1 has no string.pack)
------------------------------------------------------------------------------

local function u16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function readU16(data, pos)
    local hi, lo = data:byte(pos, pos + 1)
    if not lo then return nil end
    return hi * 256 + lo
end

--- Encode a dotted DNS name as a sequence of length-prefixed labels
--- terminated by a zero byte. No output compression is used; that is valid
--- and keeps the encoder trivial.
--- @param name string: e.g. "filesync.local" (a trailing dot is tolerated)
--- @return string: the encoded name
function Mdns.encodeName(name)
    local parts = {}
    for label in name:gmatch("[^%.]+") do
        if #label > 63 then
            error("DNS label too long: " .. label)
        end
        parts[#parts + 1] = string.char(#label) .. label
    end
    parts[#parts + 1] = "\0"
    return table.concat(parts)
end

--- Decode a DNS name starting at `pos`, following 0xC0 compression pointers.
--- @param data string: the whole packet
--- @param pos number: 1-based offset of the first label byte
--- @return string|nil: the dotted name (labels joined with ".")
--- @return number|string: offset just past the name in the *original* stream
---   on success, or an error message on failure
function Mdns.decodeName(data, pos)
    local labels = {}
    local next_pos = nil -- position after the name in the caller's stream
    local hops = 0
    local len = #data
    while true do
        if pos > len then return nil, "name runs past end of packet" end
        local n = data:byte(pos)
        if n == 0 then
            pos = pos + 1
            break
        elseif n >= 0xC0 then
            -- Two-byte pointer: low 14 bits are an offset from packet start.
            if pos + 1 > len then return nil, "truncated compression pointer" end
            hops = hops + 1
            if hops > MAX_POINTER_HOPS then
                return nil, "too many compression pointers"
            end
            local target = (n - 0xC0) * 256 + data:byte(pos + 1)
            if not next_pos then next_pos = pos + 2 end
            pos = target + 1 -- offsets are 0-based on the wire
        elseif n >= 0x40 then
            return nil, "unsupported label type"
        else
            if pos + n > len then return nil, "label runs past end of packet" end
            labels[#labels + 1] = data:sub(pos + 1, pos + n)
            pos = pos + n + 1
        end
    end
    return table.concat(labels, "."), next_pos or pos
end

--- Parse the header and question section of a DNS packet.
--- Answer/authority/additional sections are not decoded; the responder
--- only needs the questions.
--- @param data string: raw datagram
--- @return table|nil: { id, is_response, questions = { {name, qtype, qclass,
---   unicast_response} } }, or nil plus an error message
function Mdns.parseQuery(data)
    if #data < 12 then return nil, "packet shorter than DNS header" end
    local id = readU16(data, 1)
    local flags = readU16(data, 3)
    local qdcount = readU16(data, 5)
    local packet = {
        id = id,
        is_response = flags >= 0x8000,
        questions = {},
    }
    local pos = 13
    for _ = 1, qdcount do
        local name, after = Mdns.decodeName(data, pos)
        if not name then return nil, after end
        local qtype = readU16(data, after)
        local qclass = readU16(data, after + 2)
        if not qtype or not qclass then return nil, "truncated question" end
        packet.questions[#packet.questions + 1] = {
            name = name,
            qtype = qtype,
            qclass = qclass % CLASS_TOP_BIT,
            unicast_response = qclass >= CLASS_TOP_BIT,
        }
        pos = after + 4
    end
    return packet
end

--- Encode one resource record.
--- @param rr table: { name, rtype, ttl, rdata, cache_flush }
--- @return string: the encoded record
function Mdns.encodeRecord(rr)
    local class = CLASS_IN
    if rr.cache_flush then class = class + CLASS_TOP_BIT end
    return Mdns.encodeName(rr.name)
        .. u16(rr.rtype)
        .. u16(class)
        .. u32(rr.ttl)
        .. u16(#rr.rdata)
        .. rr.rdata
end

--- Build a response packet (QR=1, AA=1) from answer and additional records.
--- @param opts table: { id = number|nil, answers = {rr...}, additionals = {rr...}|nil }
--- @return string: the encoded packet
function Mdns.buildResponse(opts)
    local answers = opts.answers or {}
    local additionals = opts.additionals or {}
    local parts = {
        u16(opts.id or 0),
        u16(0x8400), -- QR=1, AA=1
        u16(0),      -- QDCOUNT
        u16(#answers),
        u16(0),      -- NSCOUNT
        u16(#additionals),
    }
    for _, rr in ipairs(answers) do
        parts[#parts + 1] = Mdns.encodeRecord(rr)
    end
    for _, rr in ipairs(additionals) do
        parts[#parts + 1] = Mdns.encodeRecord(rr)
    end
    return table.concat(parts)
end

--- RDATA for an A record.
function Mdns.rdataA(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then error("invalid IPv4 address: " .. tostring(ip)) end
    return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

--- RDATA for a PTR record.
function Mdns.rdataPTR(target)
    return Mdns.encodeName(target)
end

--- RDATA for an SRV record.
function Mdns.rdataSRV(priority, weight, port, target)
    return u16(priority) .. u16(weight) .. u16(port) .. Mdns.encodeName(target)
end

--- RDATA for a TXT record: a sequence of length-prefixed strings.
function Mdns.rdataTXT(strings)
    local parts = {}
    for _, s in ipairs(strings) do
        if #s > 255 then error("TXT string too long") end
        parts[#parts + 1] = string.char(#s) .. s
    end
    if #parts == 0 then parts[1] = "\0" end
    return table.concat(parts)
end

--- Validate a hostname label as typed by the user (without ".local").
--- Rules: 1-63 chars, a-z 0-9 and "-", no leading or trailing hyphen.
--- Callers should lowercase the input first.
--- @return boolean
function Mdns.isValidHostname(label)
    if type(label) ~= "string" then return false end
    if #label < 1 or #label > 63 then return false end
    if not label:match("^[a-z0-9%-]+$") then return false end
    if label:sub(1, 1) == "-" or label:sub(-1) == "-" then return false end
    return true
end

------------------------------------------------------------------------------
-- Record set
------------------------------------------------------------------------------

--- Create a responder. Nothing is bound until start() is called.
--- @param o table: { hostname = "filesync", port = 80, ip = "192.168.1.5" }
function Mdns:new(o)
    o = o or {}
    setmetatable(o, self)
    o.hostname = o.hostname or "filesync"
    o.port = o.port or 80
    o.ip = o.ip
    o._socket = nil
    o._running = false
    return o
end

function Mdns:isRunning()
    return self._running
end

function Mdns:getFQDN()
    return self.hostname .. ".local"
end

function Mdns:getInstanceName()
    return "FileSync on " .. self.hostname .. "._http._tcp.local"
end

--- Every record this responder serves, with the given TTLs (nil = defaults).
--- Records carry a `kind` tag so answerQuestion can pick additionals.
--- @param ttl_unique number|nil, ttl_shared number|nil: override TTLs (0 for goodbyes)
--- @return table: list of records
function Mdns:getRecords(ttl_unique, ttl_shared)
    ttl_unique = ttl_unique or TTL_UNIQUE
    ttl_shared = ttl_shared or TTL_SHARED
    local fqdn = self:getFQDN()
    local instance = self:getInstanceName()
    local service = "_http._tcp.local"
    return {
        { kind = "a", name = fqdn, rtype = TYPE_A, ttl = ttl_unique,
          cache_flush = true, rdata = Mdns.rdataA(self.ip) },
        { kind = "ptr", name = service, rtype = TYPE_PTR, ttl = ttl_shared,
          cache_flush = false, rdata = Mdns.rdataPTR(instance) },
        { kind = "enum", name = "_services._dns-sd._udp.local", rtype = TYPE_PTR,
          ttl = ttl_shared, cache_flush = false, rdata = Mdns.rdataPTR(service) },
        { kind = "srv", name = instance, rtype = TYPE_SRV, ttl = ttl_unique,
          cache_flush = true, rdata = Mdns.rdataSRV(0, 0, self.port, fqdn) },
        { kind = "txt", name = instance, rtype = TYPE_TXT, ttl = ttl_unique,
          cache_flush = true, rdata = Mdns.rdataTXT({ "path=/" }) },
    }
end

local function findByKind(records, kind)
    for _, rr in ipairs(records) do
        if rr.kind == kind then return rr end
    end
end

--- Compute the answer for one question.
--- @param q table: { name, qtype, qclass }
--- @param records table|nil: record set to answer from (shared across the
---   questions of one packet so duplicates can be detected by identity)
--- @return table answers, table additionals (both possibly empty)
function Mdns:answerQuestion(q, records)
    local answers, additionals = {}, {}
    if q.qclass ~= CLASS_IN then return answers, additionals end
    records = records or self:getRecords()
    local qname = q.name:lower()
    local in_answers = {}
    for _, rr in ipairs(records) do
        if rr.name:lower() == qname and (q.qtype == TYPE_ANY or q.qtype == rr.rtype) then
            answers[#answers + 1] = rr
            in_answers[rr.kind] = true
        end
    end
    if #answers == 0 then return answers, additionals end

    -- Additional records so one round trip gives browsers everything:
    -- PTR -> SRV + TXT + A, SRV -> A.
    local wanted = {}
    if in_answers.ptr then
        wanted = { "srv", "txt", "a" }
    elseif in_answers.srv then
        wanted = { "a" }
    end
    for _, kind in ipairs(wanted) do
        if not in_answers[kind] then
            additionals[#additionals + 1] = findByKind(records, kind)
        end
    end
    return answers, additionals
end

------------------------------------------------------------------------------
-- Socket layer
------------------------------------------------------------------------------

--- Bind the mDNS socket, join the multicast group, announce, and start polling.
--- Never throws: returns false (and logs a warning) when anything fails, so
--- the HTTP server can keep running without a name.
--- @return boolean: true when the responder is up
function Mdns:start()
    if self._running then return true end
    if not self.ip then
        logger.warn("FileSync mDNS: no IP address, responder not started")
        return false
    end

    local ok, result = pcall(function()
        -- LuaSocket 3.x creates the OS socket lazily with socket.udp(), so
        -- options set before bind would be lost; udp4() creates it eagerly.
        -- Older builds only have udp(), which is eager already.
        local udp = socket.udp4 and socket.udp4() or socket.udp()
        if not udp then error("socket.udp() failed") end

        -- Other mDNS stacks (e.g. on desktops) also own 5353; share it.
        pcall(udp.setoption, udp, "reuseaddr", true)
        pcall(udp.setoption, udp, "reuseport", true) -- newer LuaSocket only

        local bound, bind_err = udp:setsockname("*", MDNS_PORT)
        if not bound then
            udp:close()
            error("bind failed: " .. tostring(bind_err))
        end

        -- Without group membership no query would ever reach us, so this
        -- one is fatal. Prefer our LAN interface; fall back to "any".
        local joined = false
        local join_err
        for _, iface in ipairs({ self.ip, "*" }) do
            local jok, jres, jerr = pcall(udp.setoption, udp, "ip-add-membership",
                { multiaddr = MDNS_ADDR, interface = iface })
            if jok and jres then
                joined = true
                break
            end
            join_err = jok and jerr or jres
        end
        if not joined then
            udp:close()
            error("multicast join failed: " .. tostring(join_err))
        end

        pcall(udp.setoption, udp, "ip-multicast-if", self.ip)
        pcall(udp.setoption, udp, "ip-multicast-ttl", 255)
        udp:settimeout(0)
        return udp
    end)

    if not ok then
        logger.warn("FileSync mDNS: could not start responder:", result)
        return false
    end

    self._socket = result
    self._running = true
    logger.info("FileSync mDNS: announcing", self:getFQDN(), "->", self.ip, "port", self.port)

    -- Two unsolicited announcements one second apart (RFC 6762 section 8.3).
    self:_announce()
    UIManager:scheduleIn(ANNOUNCE_INTERVAL, function()
        if self._running then self:_announce() end
    end)
    self:_schedulePoll()
    return true
end

--- Send a goodbye packet (all TTLs 0) and close the socket.
function Mdns:stop()
    if not self._running then return end
    self._running = false
    if self._socket then
        pcall(function()
            self:_sendMulticast(Mdns.buildResponse({ answers = self:getRecords(0, 0) }))
        end)
        pcall(function() self._socket:close() end)
        self._socket = nil
    end
    logger.info("FileSync mDNS: responder stopped")
end

function Mdns:_announce()
    local ok, err = pcall(function()
        return self:_sendMulticast(Mdns.buildResponse({ answers = self:getRecords() }))
    end)
    if not ok then
        logger.warn("FileSync mDNS: announcement failed:", err)
    end
end

--- sendto() reports failure as (nil, err) rather than throwing, so log it
--- here; a host that blocks multicast (e.g. macOS local-network privacy)
--- would otherwise fail silently.
function Mdns:_send(data, ip, port)
    local sent, err = self._socket:sendto(data, ip, port)
    if not sent then
        logger.warn("FileSync mDNS: send to", ip, port, "failed:", err)
    end
    return sent, err
end

function Mdns:_sendMulticast(data)
    return self:_send(data, MDNS_ADDR, MDNS_PORT)
end

function Mdns:_schedulePoll()
    if not self._running then return end
    UIManager:scheduleIn(POLL_INTERVAL, function()
        self:_poll()
    end)
end

function Mdns:_poll()
    if not self._running or not self._socket then return end
    local poll_start = socket.gettime()
    for _ = 1, MAX_PACKETS_PER_POLL do
        if socket.gettime() - poll_start >= MAX_POLL_TIME then
            logger.dbg("FileSync mDNS: poll time budget exceeded")
            break
        end
        local data, from_ip, from_port = self._socket:receivefrom(MAX_PACKET_SIZE)
        if not data then break end -- "timeout": nothing pending
        local ok, err = pcall(function()
            self:_handlePacket(data, from_ip, from_port)
        end)
        if not ok then
            logger.dbg("FileSync mDNS: dropped malformed packet from", from_ip, err)
        end
    end
    self:_schedulePoll()
end

--- Handle one datagram: parse, match questions, and reply.
function Mdns:_handlePacket(data, from_ip, from_port)
    local packet, err = Mdns.parseQuery(data)
    if not packet then
        logger.dbg("FileSync mDNS: unparsable packet from", from_ip, err)
        return
    end
    -- Only queries (QR=0) are answered; responses from other hosts are ignored.
    if packet.is_response then return end

    -- Legacy unicast queries (source port != 5353, RFC 6762 section 6.7):
    -- echo the ID and reply directly to the sender.
    local legacy = from_port ~= MDNS_PORT
    local answers, additionals = {}, {}
    local seen = {}
    local unicast = legacy
    local records = self:getRecords()
    for _, q in ipairs(packet.questions) do
        local a, add = self:answerQuestion(q, records)
        if #a > 0 then
            if q.unicast_response then unicast = true end
            for _, rr in ipairs(a) do
                if not seen[rr] then
                    seen[rr] = true
                    answers[#answers + 1] = rr
                end
            end
            for _, rr in ipairs(add) do
                if not seen[rr] then
                    seen[rr] = true
                    additionals[#additionals + 1] = rr
                end
            end
        end
    end
    if #answers == 0 then return end

    local response = Mdns.buildResponse({
        id = legacy and packet.id or 0,
        answers = answers,
        additionals = additionals,
    })
    if unicast then
        logger.dbg("FileSync mDNS: unicast reply to", from_ip, from_port)
        self:_send(response, from_ip, from_port)
    else
        logger.dbg("FileSync mDNS: multicast reply for query from", from_ip)
        self:_sendMulticast(response)
    end
end

return Mdns
