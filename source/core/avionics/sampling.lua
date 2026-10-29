-- @ama-section: Sampling lifecycle | Attempt deadlines and observed completion progress.
-- Local sampling recovery. Cancels an expired attempt without refreshing its data.
local Sampling={}
-- @ama-section: Sampling lifecycle | Attempt deadlines and observed completion progress.
-- @ama-summary: Supervise a sampling attempt with deadline, progress and cancellation tracking.
function Sampling.run(name,operation,options)
    local api=options.os or os
    local workers=options.parallel or parallel
    local state=options.state
    local log=options.log or print
    local failures=0
    local function active() return not options.isActive or options.isActive() end
    local function delay(seconds)
        local deadline=api.clock()+seconds
        local wake=api.startTimer(seconds)
        while active() and api.clock()<deadline do api.pullEventRaw() end
        if type(api.cancelTimer)=="function" then pcall(api.cancelTimer,wake) end
    end
    local function record(message)
        if state.lastNotice~=message then log(name..": "..message);state.lastNotice=message end
    end
    while active() do
        state.phase="READING";state.startedAt=api.clock();state.attempt=failures+1
        local completed,result,issue=false,nil,nil
        local timer=api.startTimer(options.timeout)
        local deadline=state.startedAt+options.timeout
        workers.waitForAny(function()
            local ok,value=pcall(function()
                if state.rediscover and options.recover then options.recover();state.rediscover=nil end
                return operation()
            end)
            completed=true
            if ok then result=value else issue=tostring(value) end
        end,function()
            while active() and api.clock()<deadline do
                -- Timer IDs are wakeups, not the source of truth. A dropped
                -- timer must not strand a reader while other events continue.
                api.pullEventRaw()
            end
        end)
        if type(api.cancelTimer)=="function" then pcall(api.cancelTimer,timer) end
        state.duration=math.max(0,api.clock()-state.startedAt)
        if not completed then
            state.lastTimeoutStage=state.stage
            local pending={}
            for key in pairs(state.pending or {}) do pending[#pending+1]=key end
            table.sort(pending);state.lastTimeoutPending=pending
            -- Name the stage and the calls that never answered.
            issue="READ TIMED OUT after "..options.timeout.."s"..
                (state.stage and (" at "..tostring(state.stage)) or "")..
                (#pending>0 and (" waiting: "..table.concat(pending,", ")) or "")
        end
        if not issue and options.validate then issue=options.validate(result) end
        if issue then
            failures=failures+1
            state.failures=failures;state.lastError=issue;state.phase=failures>=3 and "DEGRADED" or "RETRYING"
            record(state.phase.." / "..issue)
            -- Rediscovery runs under the next attempt deadline, independently
            -- of the other readers and the rednet/status task.
            if options.recover and failures%3==0 then state.rediscover=true end
            delay(failures>=3 and 3 or .25)
        else
            if failures>0 then record("RECOVERED") end
            failures=0;state.failures=0;state.lastError=nil;state.phase="READY";state.lastCompletedAt=api.clock()
            state.completedCount=(state.completedCount or 0)+1
            delay(options.interval)
        end
    end
end
return Sampling
