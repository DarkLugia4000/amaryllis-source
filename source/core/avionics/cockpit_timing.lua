-- @ama-section: Timing evidence | Input completion, service intervals and scheduler pulses.
-- Bounded, read-only timing evidence. No filesystem, peripheral or output writes.
local Timing={};Timing.__index=Timing
local KEYS={"left_press","left_lift","right_press","right_lift","prop_forward","prop_reverse","ap_disconnect","altitude_up","altitude_down"}
local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function clean(v,n)return type(v)=="string" and v:gsub("[%c]"," "):sub(1,n or 80) or nil end
local function number(v)return finite(v) and v or nil end
local function clone(row)local out={};for k,v in pairs(row)do if type(v)~="table" then out[k]=v end end;return out end
function Timing.new(role,boot,clock)
 return setmetatable({role=role,boot=boot,clock=clock or function()return os.epoch("utc")/1000 end,
  capacity=256,rows={},lookup={},nextID=0,nextUpdate=0,retiredUpdate=0,count=0,jobs={},jobCount=0,slow={},slowID=0,
  wake={count=0,total=0,maximum=0,overHalfSecond=0},wakeSlow={},wakeID=0,received=0,consumed=0},Timing)
end
function Timing:touch(row)
 self.nextUpdate=self.nextUpdate+1;row.updateID=self.nextUpdate
end
-- @ama-section: Timing evidence | Input completion, service intervals and scheduler pulses.
-- @ama-summary: Create or return the timing record for a named cockpit path.
function Timing:row(input,boot,seq,source)
 if type(input)~="table" or not finite(input.at) then return nil end
 boot=clean(boot,128) or self.boot
 local key=boot..":"..string.format("%.3f",input.at)
 local row=self.lookup[key]
 if row then return row end
 self.nextID=self.nextID+1
 local slot=(self.nextID-1)%self.capacity+1
 local previous=self.rows[slot]
 if previous then self.lookup[previous.key]=nil;self.retiredUpdate=math.max(self.retiredUpdate,previous.updateID or 0) end
 row={id=self.nextID,key=key,boot=boot,seq=number(seq),sampleAt=input.at,source=source,
      readCompletedAt=input.at,readStartedAt=number(input.startedAt)}
 local t=input.timing
 if type(t)=="table" and t.boot==boot and t.readCompletedAt==input.at then
  row.seq=number(t.seq);row.readStartedAt=number(t.readStartedAt)
  row.readCompletedAt=number(t.readCompletedAt);row.sendAttemptAt=number(t.sendAttemptAt)
 end
 local levels={}
 for _,k in ipairs(KEYS)do local v=input.raw and input.raw[k];levels[#levels+1]=finite(v) and v%1==0 and v>=0 and v<=15 and string.format("%X",v) or "?" end
 row.levels=table.concat(levels)
 self.rows[slot]=row;self.lookup[key]=row;self.count=math.min(self.capacity,self.count+1)
 self:touch(row)
 return row
end
function Timing:read(input,boot,seq,started,completed)
 local row=self:row(input,boot,seq,"state")
 if row then row.readStartedAt=number(started);row.readCompletedAt=input.at;row.readReturnedAt=number(completed);row.valid=input.valid==true;self:touch(row) end
 return row
end
function Timing:sent(row,started,finished,ok)
 if row then row.sendAttemptAt=number(started);row.sendReturnedAt=number(finished);row.sendOK=ok==true;self:touch(row) end
end
function Timing:receivedInput(input,boot,seq,source,entered,validated)
 local row=self:row(input,boot,seq,source)
 if row and not row.receiverAt then
  row.receiverAt=number(entered);row.validatedAt=number(validated);self.received=self.received+1;self:touch(row)
 end
 return row
end
function Timing:consumedInput(input,at)
 -- Search by the trusted core input's sample stamp, including local failover.
 local t=type(input)=="table" and input.timing
 local row=self:row(input,type(t)=="table" and t.boot or self.boot,type(t)=="table" and t.seq or nil,"local")
 if row and not row.consumedAt then row.consumedAt=number(at);self.consumed=self.consumed+1;self:touch(row) end
 return row
end
function Timing:service(input,started,finished,consumed)
 local t=type(input)=="table" and input.timing
 local row=self:row(input,type(t)=="table" and t.boot or self.boot,type(t)=="table" and t.seq or nil,"local")
 if row and not row.serviceStartedAt then
  row.serviceStartedAt=number(started);row.serviceReturnedAt=number(finished);row.consumedSampleAt=number(consumed);self:touch(row)
 end
end
function Timing:rejectedInput(reason,at)
 self.rejected=(self.rejected or 0)+1;self.lastReject=clean(reason);self.lastRejectAt=number(at)
end
-- @ama-summary: Record the start of a measured cockpit service interval.
function Timing:beginWork(name,at)
 if type(name)~="string" or #name>40 then return end
 local job=self.jobs[name]
 if not job then
  if self.jobCount>=24 then return end
  job={count=0,total=0,maximum=0};self.jobs[name]=job;self.jobCount=self.jobCount+1
 end
 job.startedAt=number(at)
end
-- @ama-summary: Record completion timing and elapsed work for the active service interval.
function Timing:finishWork(name,started,finished)
 local job=self.jobs[name];if not job or not finite(started) or not finite(finished) then return end
 local elapsed=finished-started
 if elapsed<0 then self.clockRegressions=(self.clockRegressions or 0)+1;return end
 job.count=job.count+1;job.total=job.total+elapsed;job.last=elapsed;job.maximum=math.max(job.maximum,elapsed)
 job.finishedAt=finished;job.startedAt=nil
 if elapsed>=.25 then
  self.slowID=self.slowID+1
  self.slow[(self.slowID-1)%16+1]={id=self.slowID,name=name,startedAt=started,finishedAt=finished,seconds=elapsed}
 end
end
-- @ama-summary: Record event wake timing for the current cockpit service.
function Timing:woke(expected,actual)
 if not finite(expected) or not finite(actual) then return end
 local lag=actual-expected
 if lag<0 then self.clockRegressions=(self.clockRegressions or 0)+1;return end
 local w=self.wake;w.count=w.count+1;w.total=w.total+lag;w.last=lag;w.maximum=math.max(w.maximum,lag)
 w.at=actual;w.expectedAt=expected
 if lag>=.5 then w.overHalfSecond=w.overHalfSecond+1 end
 if lag>=.1 then
  self.wakeID=self.wakeID+1
  self.wakeSlow[(self.wakeID-1)%32+1]={id=self.wakeID,at=actual,expectedAt=expected,seconds=lag}
 end
end
-- @ama-summary: Issue and measure the local timing pulse used to observe scheduler delay.
function Timing:runPulse(api,active)
 while not active or active() do
  local expected=self.clock()+.5
  local timer=api.startTimer(.5)
  repeat api.pullEventRaw() until (active and not active()) or self.clock()>=expected
  if api.cancelTimer then pcall(api.cancelTimer,timer) end
  if not active or active() then self:woke(expected,self.clock()) end
 end
end
function Timing:pulseWorker(api,active)
 local ok,issue=pcall(self.runPulse,self,api,active)
 if not ok then self.pulseError=tostring(issue):sub(1,120) end
 -- A failed diagnostic must not make waitForAny cancel the live receiver.
 while not active or active() do api.pullEventRaw() end
end
-- @ama-summary: Return the bounded timing counters and recorded path measurements.
function Timing:dump(after,limit)
 after=finite(after) and after>=0 and math.floor(after) or 0
 limit=finite(limit) and math.max(1,math.min(12,math.floor(limit))) or 12
 local first=math.max(1,self.nextID-self.count+1)
 local out={schemaVersion=1,role=self.role,boot=self.boot,now=self.clock(),capacity=self.capacity,
  oldestID=first,newestID=self.nextID,latestUpdateID=self.nextUpdate,cursor=after,gap=after>0 and after<self.retiredUpdate,
  overwritten=math.max(0,self.nextID-self.capacity),received=self.received,consumed=self.consumed,
  wake=clone(self.wake),clockRegressions=self.clockRegressions or 0,pulseError=self.pulseError,
  rejected=self.rejected or 0,lastReject=self.lastReject,lastRejectAt=self.lastRejectAt,rows={},jobs={},slow={},wakeEvents={}}
 -- Cursor follows mutations, so a delayed consumption is exported even if
 -- its earlier receipt record has already been read by the collector.
 local pending={}
 for _,row in pairs(self.rows)do if row.updateID>after then pending[#pending+1]=row end end
 table.sort(pending,function(a,b)return a.updateID<b.updateID end)
 for i=1,math.min(limit,#pending)do
  local r=clone(pending[i]);r.key=nil;out.rows[#out.rows+1]=r;out.cursor=r.updateID
 end
 for name,job in pairs(self.jobs)do out.jobs[name]=clone(job) end
 for id=math.max(1,self.slowID-7),self.slowID do
  local row=self.slow[(id-1)%16+1];if row and row.id==id then out.slow[#out.slow+1]=clone(row) end
 end
 for id=math.max(1,self.wakeID-7),self.wakeID do
  local row=self.wakeSlow[(id-1)%32+1];if row and row.id==id then out.wakeEvents[#out.wakeEvents+1]=clone(row) end
 end
 return out
end
return Timing
