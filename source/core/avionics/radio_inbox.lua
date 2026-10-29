-- @ama-section: Prioritized inbox | Bounded packet coalescing and next-work selection.
-- Bounded core work queue. Protocol/identity validation still happens in IO.
local Inbox={};Inbox.__index=Inbox
local replaceable={lift_status=true,role_status=true,subsystem_status=true,thrust_status=true,primary_status=true}
local function integer(value,minimum,maximum)
    return type(value)=="number" and value==value and value%1==0 and value>=minimum and value<=maximum
end
-- Scheduling hints only. IO still validates identity, ordering, provider maps
-- and readbacks before a report can acknowledge any command.
-- @ama-section: Prioritized inbox | Bounded packet coalescing and next-work selection.
-- @ama-summary: Scheduling hints only. IO still validates identity, ordering, provider maps and readbacks before a report can acknowledge any command.
function Inbox.corePriority(io,run,sender,message)
    if not io or io.identityReady~=true or not integer(sender,0,65535) or type(message)~="table" or message.v~=1 or
        message.session~=io.session then return 0 end
    local config=io.config or {};local maximum=(config.network or {}).max_sequence or 2147483647
    if sender==config.bridge_id and message.kind=="bridge_request" and integer(message.seq,1,maximum) and
        type(message.boot)=="string" and #message.boot>0 and #message.boot<=128 and
        message.boot:match("^[%w_%.%-:]+$")~=nil then return 2 end
    if message.kind~="lift_status" then return 0 end
    local q=message.quadrant
    local node=io.nodes and io.nodes[q]
    local pending=run and run.pending and run.pending[q]
    if node and pending and integer(sender,0,65535) and sender==node.id and message.id==node.id and
        type(node.boot)=="string" and message.boot==node.boot and pending.boot==node.boot and
        integer(pending.seq,1,maximum) and message.lastReceivedSeq==pending.seq and
        message.lastAppliedSeq==pending.seq and message.systemsStage==pending.stage and message.systemsProbeReady==true and
        integer(message.statusSeq,1,maximum) and
        (not node.statusSeq or message.statusSeq>node.statusSeq) then return 1 end
    return 0
end
function Inbox.new(protocol,limit,priority)
    return setmetatable({protocol=protocol,limit=limit or 128,priority=priority,queue={},counts={accepted=0,ignored=0,coalesced=0,dropped=0,highWater=0}},Inbox)
end
local function add(counts,key) counts[key]=(counts[key]+1)%2147483647 end
local function key(sender,message)
    if replaceable[message.kind] then return tostring(sender)..":"..message.kind..":"..tostring(message.role or message.quadrant or "") end
end
-- @ama-summary: Validate packet shape and enqueue or coalesce its bounded work item.
function Inbox:push(sender,message,protocol,at,receiverEpochMs)
    if protocol~=self.protocol or type(message)~="table" or message.v~=1 or type(message.kind)~="string" then
        add(self.counts,"ignored");return false
    end
    local rank=0
    if type(self.priority)=="function" then
        local ok,value=pcall(self.priority,sender,message)
        if ok and value==true then rank=2
        elseif ok and integer(value,0,2) then rank=value end
    end
    local k=key(sender,message)
    local firstAckEpochMs,ackReportsCoalesced
    if k then
        for index,item in ipairs(self.queue) do
            if item.key==k then
                -- An older/out-of-order ordinary report must not erase the
                -- pending applied report before its readback is checked.
                if item.priority>rank then add(self.counts,"dropped");return false end
                if rank==1 and item.priority==1 and item[5] and item[2].boot==message.boot and
                    item[2].session==message.session and item[2].lastAppliedSeq==message.lastAppliedSeq then
                    firstAckEpochMs=item[5].firstAckReceiverEpochMs or item[5].receiverEpochMs
                    ackReportsCoalesced=math.min(2147483647,(item[5].ackReportsCoalesced or 0)+1)
                end
                -- Move a replacement to its actual arrival position, retaining
                -- FIFO ordering relative to command and acknowledgement packets.
                table.remove(self.queue,index);add(self.counts,"coalesced");break
            end
        end
    end
    if #self.queue>=self.limit then
        local removable
        for index,item in ipairs(self.queue) do
            if item.key and ((not k and rank>=item.priority) or rank>item.priority) and
                (not removable or item.priority<self.queue[removable].priority) then removable=index end
        end
        add(self.counts,"dropped")
        if removable then table.remove(self.queue,removable) else return false end
    end
    local timing=integer(receiverEpochMs,0,9007199254740991) and
        {receiverEpochMs=receiverEpochMs,priority=rank} or nil
    if timing and rank==1 then
        -- Keep newest telemetry, but also retain when an eligible applied
        -- report first entered this queue. Otherwise periodic coalescing can
        -- hide a long ACK wait by continually refreshing the arrival stamp.
        timing.firstAckReceiverEpochMs=firstAckEpochMs or receiverEpochMs
        timing.ackReportsCoalesced=ackReportsCoalesced or 0
    end
    self.queue[#self.queue+1]={sender,message,protocol,at,timing,key=k,priority=rank}
    add(self.counts,"accepted");self.counts.highWater=math.max(self.counts.highWater,#self.queue)
    return true
end
-- @ama-summary: Select the next queued item using cockpit and ship-service priorities.
function Inbox:pop()
    local selected=1
    if self.priority then
        local highest=-1
        for index,item in ipairs(self.queue) do
            if item.priority>highest then selected=index;highest=item.priority end
        end
    end
    return table.remove(self.queue,selected)
end
-- @ama-summary: Report bounded inbox depth, drops and service counters.
function Inbox:snapshot()
    local out={queued=#self.queue,limit=self.limit}
    out.navigatorQueued,out.liftAckQueued,out.routineQueued=0,0,0
    for _,item in ipairs(self.queue) do
        local k=item.priority==2 and "navigatorQueued" or item.priority==1 and "liftAckQueued" or "routineQueued"
        out[k]=out[k]+1
    end
    for k,v in pairs(self.counts) do out[k]=v end
    return out
end
return Inbox
