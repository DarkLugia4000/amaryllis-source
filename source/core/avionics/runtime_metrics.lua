-- @ama-section: Runtime metrics | Bounded elapsed-work observations.
-- Bounded in-memory elapsed timings. No disk/peripheral I/O.
local Metrics={};Metrics.__index=Metrics
function Metrics.new(clock,observer) return setmetatable({clock=clock or function() return os.epoch("utc") end,jobs={},observer=observer},Metrics) end
-- @ama-section: Runtime metrics | Bounded elapsed-work observations.
-- @ama-summary: Record elapsed work time and return the measured operation result.
function Metrics:measure(name,fn,...)
 local started=self.clock()
 if self.observer then pcall(self.observer.beginWork,self.observer,name,started/1000) end
 local result=table.pack(fn(...));local finished=self.clock();local elapsed=math.max(0,finished-started)
 if self.observer then pcall(self.observer.finishWork,self.observer,name,started/1000,finished/1000) end
 local job=self.jobs[name] or {count=0,totalMs=0,maximumMs=0};self.jobs[name]=job
 job.count=job.count+1;job.totalMs=job.totalMs+elapsed;job.lastMs=elapsed;job.maximumMs=math.max(job.maximumMs,elapsed)
 return table.unpack(result,1,result.n)
end
function Metrics:snapshot()
 local out={}
 for name,j in pairs(self.jobs) do out[name]={count=j.count,averageMs=j.totalMs/j.count,lastMs=j.lastMs,maximumMs=j.maximumMs} end
 return out
end
return Metrics
