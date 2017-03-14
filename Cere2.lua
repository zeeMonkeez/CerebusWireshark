info("")
info("Loading Cerebus protocol v 2")

klass = {}
function klass:new (o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

PktField = klass:new{
    t='UINT8',
    n='name',
    lf=nil,
    lfactor=1,
    len=nil,
    d=nil,
    format='NONE',
    valuestring=nil,
    mask=nil,
    _data_width={
        UINT8=1,
        INT8=1,
        BYTES=1,
        UINT16=2,
        INT16=2,
        UINT32=4,
        INT32=4,
        FLOAT=4,
    },
    _data_rng_getter={
        UINT8='le_uint',
        INT8='le_int',
        UINT16='le_uint',
        INT16='le_int',
        UINT32='le_uint',
        INT32='le_int',
        FLOAT='le_float',
    }
    -- field=nil,
    -- _owner=nil,

    -- new=function(self, type, name, lenfield)
    --     return klass.new(self, {t=type, n=name, lenfield=lenfield})
    -- end
}
function PktField:dataWidth()
    local dw = self._data_width[self.t]
    return dw
end
function PktField:rangeGetter()
    return self._data_rng_getter[self.t]
end

CbPkt = klass:new{
    name='HEADER',
    fields={
        PktField:new{t='UINT32', n='time', d='Timestamp in tics'},
        PktField:new{t='UINT16', n='chid', format='HEX_DEC'},
        PktField:new{t='UINT8', n='type', format='HEX'},
        PktField:new{t='UINT8', n='dlen', d='Packet Data Length (in quadlets)'}
    },
    dfields={},
    pkttypes={},
    _conf_pkg_ch=0x8000
}
function CbPkt:new(name, addfields)
    local newobj = klass:new()
    newobj.fields = {}
    for i, f in ipairs(self.fields) do
        newobj.fields[i] = f:new()
    end
    newobj.name = name
    newobj.dfields = {}
    addfields = addfields or {}
    for _, f in pairs(addfields) do
        table.insert(newobj.fields, f)
    end
    for i, f in ipairs(newobj.fields) do
        newobj.fields[f.n] = f
    end

    self.pkttypes[name] = newobj
    setmetatable(newobj, self)
    self.__index = self

    return newobj
end
function CbPkt:match(chid, type)
    for _,p in pairs(self.pkttypes) do
        if p.name ~= 'cbPKT_GENERIC' and p:match(chid, type) then
            return p
        end
    end
    return self.pkttypes['cbPKT_GENERIC']
end

function CbPkt:iterate(b_len)
    local i=0
    local n=#self.fields
    local buf_pos=0
    -- store how many bytes we expect in total. That's composed of 8 header bytes and the reported 'dlen'
    local dlen
    -- for k,v in pairs(self.dfields) do
    --     info("iterate key: " .. k .. " " .. v())
    -- end
    return function()
        i = i + 1
        if i <= n then
            local f = self.fields[i]
            -- if dlen hasn't been read yet, test if it is available, read it from field; add header size
            if dlen == nil and self.dfields['dlen'] ~= nil and self.dfields['dlen']() ~= nil then
                dlen =  8 + self.dfields['dlen']()() * 4
            end

            local width = f:dataWidth()
            local field_w = width
            local mult = 1
            if f.len ~= nil then
                mult = f.len
            elseif f.lf ~= nil and self.dfields[f.lf] ~= nil then
                mult = f.lfactor * self.dfields[f.lf]()()
            end
            width = width * mult
            local old_buf_pos = buf_pos
            buf_pos = buf_pos + width
            if f.t=='BYTES' or f.t=='STRING' then
                field_w = width
                mult = 1
            end
            -- if we'd exceed buffer length (as passed through b_len) or dlen, stop by returning nil
            if (b_len ~= nil and buf_pos > b_len) or (dlen ~= nil and buf_pos > dlen) then return nil end
            return i, old_buf_pos, field_w, f, mult
        end
    end
end

-- Generic packets

CbPktGeneric = CbPkt:new('cbPKT_GENERIC',
    {
        PktField:new{t='BYTES', n='data', lf='dlen', lfactor=4},
    }
)
function CbPktGeneric:match(chid, type)
    return true
end

-- System heartbeat
CbPktSysHeartbeat = CbPkt:new('cbPKT_SYSHEARTBEAT')
function CbPktSysHeartbeat:match(chid, type)
    return chid == self._conf_pkg_ch and type == 0x00
end

-- System protocol monitor
CbPktSysProtocolMonitor = CbPkt:new('cbPKT_SYSPROTOCOLMONITOR',
    {
        PktField:new{t='UINT32', n='sentpkts', d='Packets sent since last cbPKT_SYSPROTOCOLMONITOR (or 0 if timestamp=0)'},
    }
)
function CbPktSysProtocolMonitor:match(chid, type)
    return chid == self._conf_pkg_ch and type == 0x01
end

-- System condition report packet
CbPktSysInfo = CbPkt:new('cbPKT_SYSINFO',
    {
        PktField:new{t='UINT32', n='sysfreq', d='System clock frequency in Hz', format='DEC'},
        PktField:new{t='UINT32', n='spikelen', d='The length of the spike events', format='DEC'},
        PktField:new{t='UINT32', n='spikepre', d='Spike pre-trigger samples', format='DEC'},
        PktField:new{t='UINT32', n='resetque', d='The channel for the reset to que on', format='DEC'},
        PktField:new{t='UINT32', n='runlevel', d='System runlevel', format='DEC_HEX'},
        PktField:new{t='UINT32', n='runflags', d='System clock frequency in Hz', format='HEX'},
    }
)
CbPktSysInfo.fields['type'].valuestring = {
    [0x10] = "System Condition Report cbPKTTYPE_SYSREP",
    [0x11] = "System Spike Length Report cbPKTTYPE_SYSREPSPKLEN",
    [0x12] = "System Runlevel Report cbPKTTYPE_SYSREPRUNLEV",
    [0x90] = "System set Req cbPKTTYPE_SYSSET",
    [0x91] = "System set Spike Length cbPKTTYPE_SYSSETSPKLEN",
    [0x92] = "System set Runlevel cbPKTTYPE_SYSSETRUNLEV",
}
function CbPktSysInfo:match(chid, type)
    local p_types = {
        [0x10] = true,
        [0x11] = true,
        [0x12] = true,
        [0x90] = true,
        [0x91] = true,
        [0x92] = true,
    }
    return chid == self._conf_pkg_ch and  p_types[type] ~= nil
end

-- System condition report packet
CbPktSSModelSet = CbPkt:new('cbPKT_SS_MODELSET',
    {
        PktField:new{t='UINT32', n='chan', d='Channel being configured (zero-based)', format='DEC'},
        PktField:new{t='UINT32', n='unit_number', d='unit number (0 = noise)', format='DEC'},
        PktField:new{t='UINT32', n='valid', valuestring={[0]="invalid", [1]="valid"}, format='DEC'},
        PktField:new{t='UINT32', n='inverted', valuestring={[0]="not inverted", [1]="inverted"}, format='DEC'},
        PktField:new{t='INT32', n='num_samples', d='non-zero value means that the block stats are valid', format='DEC'},
        PktField:new{t='FLOAT', n='mu', len=2},
        PktField:new{t='FLOAT', n='Sigma_x', len=4},
        PktField:new{t='FLOAT', n='determinant_Sigma_x'},
        PktField:new{t='FLOAT', n='Sigma_x_inv', len=4},
        PktField:new{t='FLOAT', n='log_determinant_Sigma_x'},
        PktField:new{t='FLOAT', n='subcluster_spread_factor_numerator'},
        PktField:new{t='FLOAT', n='subcluster_spread_factor_denominator'},
        PktField:new{t='FLOAT', n='mu_e'},
        PktField:new{t='FLOAT', n='sigma_e_squared'},

    }
)
CbPktSSModelSet.fields['type'].valuestring = {
    [0x51] = "SS Model response cbPKTTYPE_SS_MODELREP",
    [0xD1] = "SS Model request cbPKTTYPE_SS_MODELSET",
}
function CbPktSSModelSet:match(chid, type)
    return chid == self._conf_pkg_ch and self.fields['type'].valuestring[type] ~= nil
end


CbPktStreamPrev = CbPkt:new('cbPKT_STREAMPREV',
    {
        PktField:new{t='INT16', n='rawmin', format='DEC'},
        PktField:new{t='INT16', n='rawmax'},
        PktField:new{t='INT16', n='smpmin'},
        PktField:new{t='INT16', n='smpmax'},
        PktField:new{t='INT16', n='spkmin'},
        PktField:new{t='INT16', n='spkmax'},
        PktField:new{t='UINT32', n='spkmos'},
        PktField:new{t='UINT32', n='eventflag'},
        PktField:new{t='INT16', n='envmin'},
        PktField:new{t='INT16', n='envmax'},
        PktField:new{t='INT32', n='spkthrlevel'},
        PktField:new{t='UINT32', n='nWaveNum'},
        PktField:new{t='UINT32', n='nSampleRows'},
        PktField:new{t='UINT32', n='nFlags'},
    }
)
function CbPktStreamPrev:match(chid, type)
    local p_types = {
        -- [0x81] = true,
        -- [0x82] = true,
        -- [0x83] = true,
        -- [0x03] = true,
        -- [0x01] = true,
        [0x02] = true,
    }
    return bit32.band(chid, 0x8FFF) > self._conf_pkg_ch and p_types[type] ~= nil
end

ProtoMaker = klass:new{
    name='Cerebus',
    desc="Cerebus NSP Communication",
    colname="Cerebus",
    port=51001
}
function ProtoMaker:new(o)
    -- info("ProtoMaker:new")
    o = o or {}
    local newobj = klass.new(self)
    for k,v in pairs(o) do newobj[k] = v end
    newobj.proto = Proto(newobj.name, newobj.desc)
    newobj.pfields = newobj.proto.fields
    newobj.fByPkt = {}
    -- info("ProtoMaker:new proto ..." .. newobj.name ..", " .. newobj.desc)
    return newobj
end
function ProtoMaker:register()
    info("register proto ...")

    for _,p in pairs(CbPkt.pkttypes) do
        self:makeFieldsForPacket(p)
    end


    function self.proto.dissector(buffer, pinfo, tree)
        -- info("self.proto.dissector ...")

        pinfo.cols.protocol = self.colname
        local buflen = buffer:len()
        local offset = 0
        local header_len = 8
        local buf_remain = buffer():tvb()
        local i = 0
        while buflen >= header_len do
            local chid = buf_remain(4,2):le_uint()
            local ptype = buf_remain(6,1):uint()
            local packet = CbPkt:match(chid, ptype)
            -- get current
            local packet_len = buf_remain(7,1):uint() * 4 + header_len
            -- info(packet.name)
            if i == 0 then
                pinfo.cols.info = packet.name
            end

            local subtree = tree:add(self.proto, buf_remain(0, packet_len), "Cerebus Protocol Data (" .. packet.name .. ")" )

            self:addSubtreeForPkt(buf_remain(0, packet_len):tvb(), subtree, packet)
            buflen = buflen - packet_len
            buf_remain = buf_remain(packet_len):tvb()
            i = i + 1
        end
        if i > 1 then
            pinfo.cols.info:append(" (+ " .. (i-1) .. " other" .. (i>2 and 's' or '') .. ")")
        end
    end
    local udp_table = DissectorTable.get("udp.port")
    -- register our protocol to handle udp port (default 51001)
    udp_table:add(self.port, self.proto)
end
function ProtoMaker:makeFieldsForPacket(pkt)
    local n = self.name .. "." .. pkt.name .. "."
    local fn = pkt.name .. "_"
    self.fByPkt[pkt] = {}
    for i, f in ipairs(pkt.fields) do
        local thisfn = fn .. f.n
        local thisn = n .. f.n
        local pf = ProtoField.new(f.d and f.d or f.n, thisn, ftypes[f.t], f.valuestring, base[f.format], f.mask, f.d)
        self.pfields[thisfn] = pf
        self.fByPkt[pkt][f.n] = pf
        local df = Field.new(thisn)
        table.insert(pkt.dfields, df)
        pkt.dfields[f.n] = df
    end
     -- .. " " .. pkt.dfields[f.n] .. " " .. self.fByPkt[pkt])
end

function ProtoMaker:addSubtreeForPkt(buffer, tree, pkt)
    for i, bPos, width, pf, mult in pkt:iterate(buffer:len()) do
        local subtree = tree:add_le(self.fByPkt[pkt][pf.n], buffer(bPos, width))
        if mult > 1 then
            local n = mult - 1
            subtree:append_text(" and "..n.." more item"..(n>1 and "s" or ""))
            for i=1,n do
                local brng = buffer(bPos + width * i, width)
                subtree:add( brng, 'item '..i..': ' .. brng[pf:rangeGetter()](brng))
                -- subtree:add_le('it '..(i-1)..':', brng)--, brng[pf:rangeGetter()](brng))
            end
        end
    end

end


local pm = ProtoMaker:new()
-- pm:makeFieldsForPacket(CbPktStreamPrev)
-- pm:makeFieldsForPacket(CbPktGeneric)
pm:register()
