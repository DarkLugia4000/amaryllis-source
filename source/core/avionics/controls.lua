-- @ama-section: Cockpit interpretation | Selected targets, pilot modes and neutral handover.
-- Interpret cockpit inputs into selected targets and live propulsion demand.
-- Core owns modes/selected targets; bridge requests changes and renders them.
-- Positive yaw means right, positive propulsion means bow-forward. Conflicting
-- directional buttons cancel. Input loss clears demands and requires neutral
-- before recovery, so a retained lever cannot unexpectedly resume a command.
local Controls={};local Lateral=require("avionics.lateral")
local InputTuning=require("avionics.input_tuning")
local KEYS={"left_press","left_lift","right_press","right_lift","prop_forward",
    "prop_reverse","ap_disconnect","altitude_up","altitude_down"}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function pressed(raw,key) return raw[key]>0 end
local function currentTime(io,now)
    if io and type(io.nowSeconds)=="function" then
        local ok,value=pcall(io.nowSeconds,io)
        if ok and finite(value) and (not finite(now) or value>now) then now=value end
    end
    return now
end
function Controls.new(config)
    local valid,reason=InputTuning.ensure(config.cockpit);assert(valid,reason)
    return setmetatable({config=config.cockpit,altitudeConfig=config.altitude_control,
        staleSeconds=config.network.sensor_stale_seconds,modes={heading="MANUAL",throttle="MANUAL",altitude="TGT",lateral="MANUAL"},lateral=Lateral.new(config),
        targets={},headingTargetUuid=nil,waitHeading=true,waitThrottle=true,waitAltitude=true,
        holds={},request=0,yaw=0}, {__index=Controls})
end
-- @ama-section: Cockpit interpretation | Selected targets, pilot modes and neutral handover.
-- @ama-summary: Reset live input history and neutral gates while retaining selected pilot modes.
function Controls:clear()
    self.lateral:cancel();self.modes.lateral="MANUAL"
    self.request=0; self.yaw=0; self.holds={}; self.lastSample=nil
    self.headingKind=nil
    -- Selected modes and targets (heading / throttle SEL) are kept through
    -- errors and interruptions; only live demands are reset. Propulsion stays
    -- paused while the neutral gates are set and resumes the retained
    -- selection once the levers read neutral again.
    self.waitHeading=true; self.waitThrottle=true; self.waitAltitude=true
end
-- @ama-summary: Validate the age, identity and completeness of the cockpit sample.
function Controls:fresh(io,now)
    local input=io.inputs
    now=currentTime(io,now)
    if not finite(now) then return false,"COCKPIT CLOCK UNAVAILABLE",now,input end
    if not input or not input.valid then return false,input and input.reason or "COCKPIT INPUT READ FAILED" end
    if not finite(input.at) or now<input.at or
        now-input.at>(self.config.input_stale_seconds or self.config.maximum_input_gap_seconds or self.staleSeconds) then
        return false,"COCKPIT INPUTS STALE",now,input
    end
    if type(input.raw)~="table" then return false,"COCKPIT INPUT SAMPLE INVALID",now,input end
    for _,key in ipairs(KEYS) do
        local n=input.raw[key]
        if not finite(n) or n%1~=0 or n<0 or n>15 then return false,"INVALID COCKPIT LEVEL: "..key,now,input end
    end
    return true,nil,now,input
end
-- Whether the control state itself is current and usable. Lever data is
-- optional: when it is unreadable the levers count as neutral, while modes,
-- selected targets, autopilot, anchor and START SYSTEMS keep working.
-- @ama-summary: Whether the control state itself is current and usable. Lever data is optional: when it is unreadable the levers count as neutral, while modes, selected targets, autopilot, anchor and START SYSTEMS keep working.
function Controls:usable(io,now)
    now=currentTime(io,now)
    if self.available~=true then return false,self.reason or "COCKPIT CONTROLS UNAVAILABLE" end
    local limit=self.config.input_stale_seconds or self.config.maximum_input_gap_seconds or self.staleSeconds
    if not finite(now) or not finite(self.updatedAt) or now<self.updatedAt-1 or now-self.updatedAt>limit then
        return false,"COCKPIT CONTROL STATE STALE"
    end
    return true
end
-- @ama-summary: Validate and apply an explicit cockpit-mode selection.
function Controls:mode(io,action,now)
    self:update(io,now)
    if not self.available then return false,self.reason end
    local axis,mode=action.axis,action.mode
    if axis=="throttle" and self.leversAvailable and io.inputs and type(io.inputs.raw)=="table" and
        pressed(io.inputs.raw,"ap_disconnect") then
        return false,"THROTTLE SHORTCUT BUTTON HELD"
    end
    if axis=="lateral" then
        if self.lateralStopLock and mode=="SEL" then return false,"START SYSTEMS BEFORE USING STRAFE" end
        local ok,reason=self.lateral:select(mode,io,self,now)
        self.modes.lateral=self.lateral.mode;return ok,reason
    end
    if axis~="heading" and axis~="throttle" then return false,"INVALID MODE AXIS" end
    if mode~="MANUAL" and mode~="SEL" and not (axis=="throttle" and mode=="DIRECT") then
        return false,"INVALID COCKPIT MODE"
    end
    if self.modes[axis]==mode then return true end
    local v=io.vessel or {}
    if mode=="SEL" then
        local value=axis=="heading" and v.heading or v.forwardSpeed
        if not v.valid or not finite(v.at) or now<v.at or now-v.at>self.staleSeconds or not finite(value) then
            return false,"FRESH VESSEL MEASUREMENT REQUIRED"
        end
        if axis=="heading" and v.geometryVerified~=true then
            return false,"VERIFIED HEADING MEASUREMENT REQUIRED"
        end
        if axis=="heading" and (type(v.uuid)~="string" or v.uuid=="") then
            return false,"VESSEL ID REQUIRED"
        end
        if axis=="throttle" and v.velocityFrameVerified~=true then return false,"VERIFIED SIGNED SPEED AXIS REQUIRED" end
        if axis=="throttle" and finite(self.config.minimum_selected_speed) and
            value<self.config.minimum_selected_speed then
            return false,"SPEED TARGET BELOW CONFIGURED MINIMUM"
        end
        if axis=="throttle" and finite(self.config.maximum_selected_speed) and
            value>self.config.maximum_selected_speed then
            return false,"SPEED TARGET ABOVE CONFIGURED MAXIMUM"
        end
        self.targets[axis=="heading" and "heading" or "speed"]=axis=="heading" and value%360 or value
        if axis=="heading" then self.headingTargetUuid=v.uuid end
    end
    self.modes[axis]=mode
    if axis=="heading" then
        self.waitHeading=true; self.yaw=0; self.holds.heading=nil; self.headingKind=nil
        if mode~="SEL" then self.targets.heading=nil; self.headingTargetUuid=nil end
    else
        self.waitThrottle=true; self.request=0
        self.waitSpeedSelection=false
        self.speedTargetUuid=mode=="SEL" and v.uuid or nil
    end
    return true
end
-- Return one discrete step on the edge, then elapsed-time repeat. Capping dt
-- prevents a stalled program from replaying several seconds of held input.
-- @ama-summary: Return one discrete step on the edge, then elapsed-time repeat. Capping dt prevents a stalled program from replaying several seconds of held input.
function Controls:step(name,direction,at,dt,delay,rate)
    if direction==0 then self.holds[name]=nil; return 0 end
    local hold=self.holds[name]
    if not hold or hold.direction~=direction then
        self.holds[name]={direction=direction,start=at}; return direction
    end
    local active=math.max(0,at-hold.start-delay)
    local previous=math.max(0,at-dt-hold.start-delay)
    return direction*(active-previous)*rate
end
-- A tap retains the configured heading step. Held input accelerates only
-- through fresh samples. Release, reversal and neutral gates discard the ramp.
-- @ama-summary: A tap retains the configured heading step. Held input accelerates only through fresh samples. Release, reversal and neutral gates discard the ramp.
function Controls:rampedSelection(name,direction,at,dt,delay,initial,acceleration,maximum,step)
    if direction==0 then self.holds[name]=nil;return 0 end
    local hold=self.holds[name]
    if not hold or hold.direction~=direction then
        hold={direction=direction,start=at,elapsed=0,remainder=0};self.holds[name]=hold
        if step then return direction*step end
    end
    local active=math.max(0,at-hold.start-delay)
    local previous=math.max(0,at-dt-hold.start-delay)
    local elapsed=math.min(math.max(0,dt),.5,math.max(0,active-previous))
    -- Speed selection already acts on the first fresh directional sample.
    if not step and at==hold.start then elapsed=math.min(math.max(0,dt),.5) end
    local before=hold.elapsed
    hold.elapsed=before+elapsed
    local amount=InputTuning.area(hold.elapsed,initial,acceleration,maximum)-
        InputTuning.area(before,initial,acceleration,maximum)
    if step then
        amount=amount+hold.remainder
        local count=math.floor(amount/step+1e-9)
        hold.remainder=math.max(0,amount-count*step)
        amount=count*step
    end
    return direction*amount
end
-- @ama-summary: Interpret fresh cockpit inputs into selected targets and live propulsion demands.
function Controls:update(io,now)
    local good,inputReason,evaluatedAt=self:fresh(io,now)
    now=evaluatedAt or now
    local anchored=io.anchor=="ANCHORED" or io.anchor=="BRAKING"
    -- Assembly gate: while disassembled/unconfirmed, cockpit inputs are not
    -- interpreted and nothing accumulates. clear() retains selections and
    -- requires neutral levers once the vessel is confirmed assembled again.
    local assembled,assemblyReason=true,nil
    if type(io.assemblyGate)=="function" then assembled,assemblyReason=io:assemblyGate(now) end
    local identityReady=io.identityReady~=false
    local identityReason=io.identityReason or "CORE IDENTITY IS NOT VERIFIED AGAINST /fleet.json"
    self.available=not anchored and assembled and identityReady
    self.reason=(not assembled and assemblyReason) or (not identityReady and identityReason) or
        (anchored and "ANCHOR SUPPRESSES COCKPIT") or nil
    self.updatedAt=now
    if not self.available then self:clear(); return end
    -- Assembly checks may yield while the independent input worker publishes a
    -- newer sample. Revalidate and consume the same sample whose age was checked.
    local latestInput
    good,inputReason,evaluatedAt,latestInput=self:fresh(io,now)
    now=evaluatedAt or now
    if not good then
        -- Lever data lost: levers count as neutral. Modes, SEL targets and
        -- automatic control are kept; nothing else is locked out. On return
        -- every lever must be neutral again before any lever acts.
        self.leversAvailable=false;self.requireNeutral=true
        self.reason="COCKPIT LEVERS UNAVAILABLE: "..tostring(inputReason or "NO DATA")
        self.request=0;self.yaw=0;self.holds={};self.lastSample=nil
        self.lateral:cancel();self.modes.lateral="MANUAL"
        -- Unreadable levers count as neutral, so the neutral gates can open:
        -- retained SEL modes keep working. requireNeutral protects the
        -- moment the levers become readable again.
        self.waitHeading=false;self.waitThrottle=false;self.waitAltitude=false;self.waitSpeedSelection=false
        return
    end
    self.leversAvailable=true
    local binding=io.inventory and io.inventory.linkBridge
    if binding~=self.linkBinding then
        self:clear(); self.linkBinding=binding
    end
    local input,v=latestInput,io.vessel or {}
    -- Stale vessel data no longer drops SEL: the propulsion layer already
    -- withholds thrust while speed / heading data is stale, and the retained
    -- selection resumes when fresh data returns.
    if v.valid and finite(v.at) and now>=v.at and now-v.at<=self.staleSeconds and v.uuid then
        if self.uuid~=v.uuid then
            -- New Sable vessel identity (first sample or reassembly): keep the
            -- selected modes and targets, rebind them, and require neutral.
            self:clear(); self.uuid=v.uuid
            if self.modes.heading=="SEL" and finite(self.targets.heading) then self.headingTargetUuid=v.uuid
            elseif self.modes.heading=="SEL" then self.modes.heading="MANUAL" end
            if self.modes.throttle=="SEL" and finite(self.targets.speed) then self.speedTargetUuid=v.uuid
            elseif self.modes.throttle=="SEL" then self.modes.throttle="MANUAL" end
        end
        if self.targets.altitude==nil and finite(v.altitude) then self.targets.altitude=v.altitude end
    end
    if self.lastSample==input.at then return end -- One sample can be published repeatedly.
    local dt=self.lastSample and input.at-self.lastSample or 0
    if dt<0 or dt>self.config.maximum_input_gap_seconds then
        -- A long gap restarts lever interpretation without dropping modes.
        self.holds={};self.requireNeutral=true;dt=0
    end
    self.lastSample=input.at
    -- Stamp the first actual consumption, never a later duplicate check.
    io.cockpitProcessedAt=type(io.nowSeconds)=="function" and io:nowSeconds() or now
    io.cockpitProcessedSampleAt=input.at
    if io.cockpitTrace then pcall(io.cockpitTrace.consumedInput,io.cockpitTrace,input,io.cockpitProcessedAt) end
    local raw=input.raw
    if self.requireNeutral then
        for _,key in ipairs(KEYS) do
            if raw[key]~=0 then
                self.request=0;self.yaw=0
                self.reason="COCKPIT LEVERS RETURNED: SET "..string.upper(key).." TO NEUTRAL"
                return
            end
        end
        self.requireNeutral=false
    end
    local anchorActive=io.positionAnchor and io.positionAnchor.active
    local apActive=io.autopilot and io.autopilot.active
    if apActive and pressed(raw,"ap_disconnect") then
        io.autopilot:cancel(io,self,"PILOT DISENGAGED AUTOPILOT; SELECTED MODES RETAINED")
        return -- Do not consume the disconnect sample again as a manual command.
    end
    -- With AP currently inactive, LMB is a throttle shortcut. SEL requests
    -- zero signed speed; MANUAL transfers to DIRECT through the neutral gate.
    -- It has no effect on heading, altitude, or an already-DIRECT throttle.
    if not apActive and not anchorActive and pressed(raw,"ap_disconnect") then
        if self.modes.throttle=="SEL" then
            self.targets.speed=0
            -- Keep the velocity controller active so it can brake while the
            -- click is held. Only speed-selection inputs must return neutral.
            self.waitThrottle=false;self.waitSpeedSelection=true
        elseif self.modes.throttle=="MANUAL" then
            self.modes.throttle="DIRECT";self.waitThrottle=true
            self.waitSpeedSelection=false;self.speedTargetUuid=nil
        end
    end
    self.lateral:input(raw,input.at,dt,anchorActive or apActive or self.lateralStopLock)
    self.modes.lateral=self.lateral.mode
    local left=pressed(raw,"left_press")
    local right=pressed(raw,"right_press")
    if not left and not right then self.waitHeading=false end
    local direction=left==right and 0 or (right and 1 or -1)
    local coarse=pressed(raw,"left_press") or pressed(raw,"right_press")
    if self.waitHeading then direction=0 end
    if apActive then direction=0 end
    self.yaw=0
    -- Heading centre: in SEL, holding both heading pedals (A and D, not the
    -- strafe pedals) for heading_center_hold_seconds (default 1.5 s) makes
    -- the selected heading the vessel's current heading. Both must then be
    -- released before the pedals act again. A single-pedal step taken while
    -- the second pedal was being pressed is overwritten by the centre.
    if self.modes.heading=="SEL" and left and right and not self.waitHeading and not apActive then
        self.headingCenterSince=self.headingCenterSince or input.at
        local holdSeconds=finite(self.config.heading_center_hold_seconds) and self.config.heading_center_hold_seconds or 1.5
        if input.at-self.headingCenterSince>=holdSeconds then
            self.headingCenterSince=nil;self.waitHeading=true;self.holds.heading=nil
            local current=v.valid and finite(v.heading) and finite(v.at) and now>=v.at and
                now-v.at<=self.staleSeconds and v.uuid
            if current then
                self.targets.heading=v.heading%360;self.headingTargetUuid=v.uuid
                if io.thrust and type(io.thrust.resetHeadingLoop)=="function" then io.thrust:resetHeadingLoop() end
                self.headingCentredAt=input.at
                if type(os.__amaryllisLog)=="function" then
                    pcall(os.__amaryllisLog,string.format("Heading centred: SEL heading set to current %.1f",self.targets.heading),"core.controls")
                end
            elseif type(os.__amaryllisLog)=="function" then
                pcall(os.__amaryllisLog,"Heading centre ignored: no fresh vessel heading","core.controls")
            end
        end
    else self.headingCenterSince=nil end
    if self.modes.heading=="SEL" then
        local kind=coarse and "coarse" or "fine"
        if self.headingKind~=kind then self.holds.heading=nil; self.headingKind=kind end
        local step=coarse and self.config.coarse_heading_degrees or self.config.fine_heading_degrees
        local scale=step/self.config.coarse_heading_degrees
        local change=self:rampedSelection("heading",direction,input.at,dt,self.config.repeat_delay_seconds,
            self.config.heading_selection_rate*scale,self.config.heading_selection_acceleration*scale,
            self.config.heading_selection_max_rate*scale,step)
        if finite(self.targets.heading) then self.targets.heading=(self.targets.heading+change)%360 end
    else
        self.holds.heading=nil
        self.yaw=direction*(coarse and 1 or self.config.fine_heading_degrees/self.config.coarse_heading_degrees)*
            self.config.manual_yaw_sensitivity_percent/100
    end
    if raw.prop_forward==0 and raw.prop_reverse==0 then
        self.waitThrottle=false;self.waitSpeedSelection=false
    end
    -- Simultaneous W/S cancels even when the two analog strengths differ.
    self.request=(raw.prop_forward>0 and raw.prop_reverse>0) and 0 or
        (raw.prop_forward-raw.prop_reverse)/15
    if self.waitThrottle or self.waitSpeedSelection or
        (self.modes.throttle=="SEL" and pressed(raw,"ap_disconnect")) then self.request=0 end
    if anchorActive or apActive then self.request=0 end
    -- Speed/RPM/acceleration mapping stays absent until physical limits are
    -- verified. A percentage is a pilot request, never an applied throttle.
    local speedRate=self.config.speed_selection_blocks_per_second_per_second
    if self.modes.throttle=="SEL" and finite(speedRate) and finite(self.targets.speed) then
        local minimum=self.config.minimum_selected_speed or 0
        local direction=self.request>0 and 1 or (self.request<0 and -1 or 0)
        local change=self:rampedSelection("speed",direction,input.at,dt,0,speedRate,
            self.config.speed_selection_acceleration,self.config.speed_selection_max_rate)
        self.targets.speed=clamp(self.targets.speed+change*math.abs(self.request),
            minimum,self.config.maximum_selected_speed)
    else self.holds.speed=nil end
    local up,down=pressed(raw,"altitude_up"),pressed(raw,"altitude_down")
    if not up and not down then self.waitAltitude=false end
    local altitudeDirection=up==down and 0 or (up and 1 or -1)
    if self.waitAltitude then altitudeDirection=0 end
    local hold=self.holds.altitude
    local held=hold and input.at-hold.start or 0
    local rate=self.config.altitude_rate_slow
    if held>=self.config.altitude_fast_after_seconds then rate=self.config.altitude_rate_fast
    elseif held>=self.config.altitude_medium_after_seconds then rate=self.config.altitude_rate_medium end
    local change=self:step("altitude",altitudeDirection,input.at,dt,self.config.repeat_delay_seconds,rate)
    if finite(self.targets.altitude) then self.targets.altitude=clamp(self.targets.altitude+change,
        self.altitudeConfig.minimum_world_y,self.altitudeConfig.maximum_world_y) end
end
-- @ama-summary: Add selected modes, target values and cockpit readiness to the display snapshot.
function Controls:decorate(snapshot)
    self.modes.lateral=self.lateral.mode
    snapshot.lateralControl=self.lateral:snapshot()
    snapshot.lateralControl.locked=self.lateralStopLock==true
    if self.lateralStopLock then snapshot.lateralControl.state="STOPPED" end
    snapshot.modes=self.modes
    for key,value in pairs(self.targets) do snapshot.targets[key]=value end
    snapshot.settings=snapshot.settings or {}
    snapshot.settings.manualYawSensitivity=self.config.manual_yaw_sensitivity_percent
    snapshot.cockpitControl={available=self.available==true,reason=self.reason,
        leversAvailable=self.leversAvailable==true,
        headingWaitingForNeutral=self.waitHeading,throttleWaitingForNeutral=self.waitThrottle,
        altitudeWaitingForNeutral=self.waitAltitude,yawRequestPercent=self.yaw*100,
        propulsionRequestPercent=self.request*100,propulsionAvailable=false,
        propulsionReason="PROPULSION HARDWARE / LIMITS UNVERIFIED",
        speedSelectionAvailable=finite(self.config.speed_selection_blocks_per_second_per_second)}
    return snapshot
end
return Controls
