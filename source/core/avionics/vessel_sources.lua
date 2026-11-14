local Mathx = require("avionics.mathx")
-- Section: Vessel observations | Timestamped Sable fields and calibrated peripheral fallback.
-- Retained vessel association v1
-- Independent read-only fallback sensors and per-field vessel source selection.
-- Source ages record successful getter completion times.
local Sources={}
local Storage=require("avionics.storage")
local CALIBRATION_PATH="/avionics/data/sensor-fallback.json"
local finite = Mathx.finite
local function copy(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function vec(v)
    if type(v)~="table" then return nil end
    local x,y,z=v.x or v[1],v.y or v[2],v.z or v[3]
    if finite(x) and finite(y) and finite(z) then return {x=x,y=y,z=z} end
end
-- Section: Vessel observations | Timestamped Sable fields and calibrated peripheral fallback.
-- Summary: Validate and normalize an observed quaternion.
local function quat(v)
    if type(v)~="table" then return nil end
    if type(v.v)=="table" and finite(v.a) then v={x=v.v.x or v.v[1],y=v.v.y or v.v[2],z=v.v.z or v.v[3],w=v.a} end
    local x,y,z,w=v.x or v[1],v.y or v[2],v.z or v[3],v.w or v[4]
    if not (finite(x) and finite(y) and finite(z) and finite(w)) then return nil end
    local n=math.sqrt(x*x+y*y+z*z+w*w);if not finite(n) or n<1e-8 then return nil end
    return {x=x/n,y=y/n,z=z/n,w=w/n}
end
local function mul(a,b) return {x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
    z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z} end
local function inverse(q) return {x=-q.x,y=-q.y,z=-q.z,w=q.w} end
local function rotate(q,v)
    local r=mul(mul(q,{x=v.x,y=v.y,z=v.z,w=0}),inverse(q));return {x=r.x,y=r.y,z=r.z}
end
local function dot(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
local function cross(a,b) return {x=a.y*b.z-a.z*b.y,y=a.z*b.x-a.x*b.z,z=a.x*b.y-a.y*b.x} end
local function norm(v)
    v=vec(v);if not v then return nil end
    local n=math.sqrt(dot(v,v));if not finite(n) or n<1e-8 then return nil end
    return {x=v.x/n,y=v.y/n,z=v.z/n}
end
local function asin(x) return math.deg(math.asin(math.max(-1,math.min(1,x)))) end
local function heading(f)
    if not f or f.x*f.x+f.z*f.z<1e-8 then return nil end
    return (math.deg(math.atan2(f.x,-f.z))+360)%360
end
local function validID(v) return type(v)=="string" and #v>0 and #v<=128 end
local function fresh(now,at,limit) return finite(at) and now>=at and now-at<=limit end
local function validCalibration(c,fingerprint)
    return type(c)=="table" and validID(c.uuid) and type(fingerprint)=="string" and fingerprint~="" and
        c.fingerprint==fingerprint and finite(c.heightOffset) and math.abs(c.heightOffset)<10000 and
        (c.headingOffset==nil or finite(c.headingOffset)) and quat(c.navToPose)~=nil and norm(c.bow)~=nil
end
-- Summary: Load the sensor-frame calibration that matches vessel identity and hardware bindings.
function Sources.loadCalibration(io)
    if not io.fs and not io.sourceCalibrationStore then return end
    local store=io.sourceCalibrationStore or Storage
    for _,path in ipairs({CALIBRATION_PATH,CALIBRATION_PATH..".bak"}) do
        local ok,data=pcall(store.readJson,path,{fs=io.fs,textutils=io.json})
        if ok and type(data)=="table" and data.schemaVersion==1 and validCalibration(data.calibration,io.hardwareFingerprint) then
            io.fallbackCalibration=copy(data.calibration)
            io.fallbackCalibration.navToPose=quat(data.calibration.navToPose)
            io.fallbackCalibration.bow=norm(data.calibration.bow)
            return
        end
    end
end
-- Summary: Persist the current vessel sensor-frame calibration.
function Sources.persistCalibration(io,now)
    if not io.fs and not io.sourceCalibrationStore then return end
    local c=io.fallbackCalibration
    if not validCalibration(c,io.hardwareFingerprint) then return end
    if io.lastSourceCalibrationSave and now>=io.lastSourceCalibrationSave and now-io.lastSourceCalibrationSave<30 then return end
    io.lastSourceCalibrationSave=now
    local store=io.sourceCalibrationStore or Storage
    local called,saved,reason=pcall(store.writeJson,CALIBRATION_PATH,{schemaVersion=1,calibration=copy(c)},
        {fs=io.fs,textutils=io.json})
    io.sourceCalibrationError=not (called and saved) and tostring(called and reason or saved) or nil
end
local function store(io,key,value,at,errorText)
    io.fallbackReadings=io.fallbackReadings or {}
    local previous=io.fallbackReadings[key] or {}
    if value~=nil then previous={value=value,at=at} end
    previous.error=errorText;io.fallbackReadings[key]=previous
end
-- Summary: Build independent assembler identity, mass and centre-of-mass reader jobs.
local function assemblerJobs(io,jobs,pending,fingerprint)
    local assemblers=io.assemblyTrack and io.assemblyTrack.assemblers
    if not assemblers and type(io.findAssemblers)=="function" then assemblers=io:findAssemblers() end
    local name=assemblers and assemblers[1]
    if not name then return end
    for _,spec in ipairs({{"uuid","getSubLevelId"},{"mass","getMass"},{"com","getCenterOfMass"}}) do
        local key,method=spec[1],spec[2]
        jobs[#jobs+1]=function()
            pending[key]=true
            local ok,value,reason=pcall(io.readSensor,io,name,method)
            pending[key]=nil
            if io.hardwareFingerprint~=fingerprint then return end
            local checked
            if ok then
                if key=="uuid" and validID(value) then checked=value
                elseif key=="mass" and finite(value) and value>0 then checked=value
                elseif key=="com" then checked=vec(value) end
            end
            store(io,key,checked,io:nowSeconds(),checked==nil and tostring(reason or (ok and "INVALID READBACK" or value)) or nil)
        end
    end
end
-- Summary: Read assembler identity, mass and centre of mass with independent result ages.
function Sources.sampleAssembler(io)
    local progress=io.sampling and io.sampling.assembler
    local pending={}
    if progress then progress.pending=pending;progress.stage="ASSEMBLER IDENTITY / MASS / CoM" end
    local jobs={}
    assemblerJobs(io,jobs,pending,io.hardwareFingerprint)
    if #jobs>0 then
        if io.parallel and type(io.parallel.waitForAll)=="function" then io.parallel.waitForAll(table.unpack(jobs))
        else for _,job in ipairs(jobs) do job() end end
    end
    return true
end
function Sources.reading(io,key,now,limit)
    local r=(io.fallbackReadings or {})[key]
    if r and fresh(now,r.at,limit) then return r.value,r.at end
end
-- The wired reader reports the same raw source records as the local worker.
-- Ingestion validates each shape and keeps the original measurement time.
-- Summary: The wired reader reports the same raw source records as the local worker. Ingestion validates each shape and keeps the original measurement time.
function Sources.acceptBackup(io,key,value,at,now)
    if not finite(at) or at>now+.25 or now-at>120 then return false end
    local checked
    if key=="orientation" then checked=quat(value)
    elseif key=="gravity" or key=="rates" or key=="com" then checked=vec(value)
    elseif key=="uuid" and validID(value) then checked=value
    elseif (key=="mass" or key=="pressure") and finite(value) and value>0 then checked=value
    elseif (key=="height" or key=="heading" or key=="verticalSpeed") and finite(value) then checked=value
    elseif type(key)=="string" and key:sub(1,9)=="velocity:" and type(value)=="table" and
        (value.axis=="x" or value.axis=="y" or value.axis=="z") and finite(value.speed) and
        type(value.name)=="string" and #value.name<=256 and key=="velocity:"..value.name then
        checked={axis=value.axis,speed=value.speed,name=value.name}
    end
    if checked==nil then return false end
    local previous=(io.fallbackReadings or {})[key]
    if previous and finite(previous.at) and at<previous.at then return false end
    store(io,key,checked,at)
    return true
end

-- Summary: Validate and timestamp a primary Sable observation.
-- origin is "core" for core's own Sable reads and "reader" for readings relayed by the state reader.
-- Keep one Sable velocity sample per origin. Prefer core's sample for 2 s,
-- then allow the state reader to supply the shared velocity slot.
function Sources.acceptPrimary(io,key,value,at,origin)
    local checked
    if key=="uuid" and validID(value) then checked=value
    elseif key=="mass" and finite(value) and value>0 then checked=value
    elseif key=="pose" and type(value)=="table" then
        local orientation=quat(value.orientation)
        if orientation then checked={orientation=orientation,position=vec(value.position),rotationPoint=vec(value.rotationPoint),scale=vec(value.scale)} end
    elseif key=="com" or key=="velocity" or key=="angular" then checked=vec(value) end
    if checked==nil then return end
    io.primaryReadings=io.primaryReadings or {}
    if key=="velocity" and finite(at) then
        origin=origin=="reader" and "reader" or "core"
        io.sableVelocityBy=io.sableVelocityBy or {}
        io.sableVelocityBy[origin]={value=checked,at=at}
        local own=io.sableVelocityBy.core
        if origin=="reader" and own and finite(own.at) and at-own.at<2 then return false end
    end
    local previous=io.primaryReadings[key]
    if not finite(at) or (previous and finite(previous.at) and (at<previous.at or (key=="uuid" and at==previous.at and previous.value~=checked))) then return false end
    local old=io.primaryReadings.uuid
    if key=="uuid" and old and old.value~=checked then
        io.primaryReadings={};io.fallbackCalibration=nil;io.primaryVessel=nil;io.sableVelocityBy=nil
    end
    io.primaryReadings[key]={value=checked,at=at}
end
-- Summary: Build a primary vessel-source view from timestamped readings and metadata.
local function primaryView(io)
    local p={};for k,v in pairs(io.primaryVessel or {}) do p[k]=v end
    p.sableReadAt=copy(p.sableReadAt or {})
    local raw=io.primaryReadings or {}
    for key,name in pairs({uuid="sableUuid",mass="sableMass",velocity="sableVelocity",angular="sableAngular",com="localCenterOfMass"}) do
        local r=raw[key];if r then p[name]=r.value;p.sableReadAt[key]=r.at end
    end
    local pose=raw.pose
    if pose then
        local v=pose.value;p.sableReadAt.pose=pose.at
        p.sableOrientation=v.orientation;p.sablePosePosition=v.position;p.sableRotationPoint=v.rotationPoint;p.sableScale=v.scale
    end
    local com,origin,r,scale,q=vec(p.localCenterOfMass),vec(p.sablePosePosition),vec(p.sableRotationPoint),vec(p.sableScale),quat(p.sableOrientation)
    if com and origin and r and scale and q then
        local offset=rotate(q,{x=(com.x-r.x)*scale.x,y=(com.y-r.y)*scale.y,z=(com.z-r.z)*scale.z})
        p.sableWorldCom={x=origin.x+offset.x,y=origin.y+offset.y,z=origin.z+offset.z}
    end
    local bow=(io.config.geometry or {}).bow_forward
    -- geometry.sable_bow_axis sets the Sable pose-frame bow on core as well,
    -- whatever axis the state reader reports.
    local configured=vec((io.config.geometry or {}).sable_bow_axis)
    if configured then p.attitudeBow={x=configured.x,y=0,z=configured.z};p.attitudeAxisSource="CONFIGURED"
    elseif not p.attitudeBow then p.attitudeBow=norm(bow) end
    return p
end

-- Summary: Read configured fallback sensor fields with independent completion tracking.
function Sources.sample(io,now)
    local bindings=io.sensorBindings or io.config.hardware or {}
    local fingerprint=io.hardwareFingerprint
    if io.fallbackFingerprint~=fingerprint then
        io.fallbackReadings={};io.fallbackAxes={};io.fallbackCalibration=nil
        io.fallbackFingerprint=fingerprint
        Sources.loadCalibration(io)
    end
    local progress=io.sampling and io.sampling.fallback
    if progress then progress.pending={};progress.stage="INDEPENDENT FALLBACK READS" end
    local pending=progress and progress.pending or {}
    local jobs={}
    -- Summary: Collect the selected sensor getter result and its completion timestamp.
    local function read(key,name,method,validate)
        if type(name)~="string" then return end
        jobs[#jobs+1]=function()
            pending[key]=true
            local ok,value,reason=pcall(io.readSensor,io,name,method)
            pending[key]=nil
            if io.hardwareFingerprint~=fingerprint then return end
            local checked=ok and validate(value) or nil
            store(io,key,checked,io:nowSeconds(),checked==nil and tostring(reason or (ok and "INVALID READBACK" or value)) or nil)
        end
    end
    read("orientation",bindings.navigation_table,"getOrientation",quat)
    read("heading",bindings.navigation_table,"getHeading",function(v) if finite(v) then return v end end)
    read("height",bindings.altitude_sensor,"getHeight",function(v) if finite(v) then return v end end)
    read("verticalSpeed",bindings.altitude_sensor,"getVerticalSpeed",function(v) if finite(v) then return v end end)
    read("pressure",bindings.altitude_sensor,"getAirPressure",function(v) if finite(v) and v>0 then return v end end)
    read("gravity",bindings.gimbal_sensor,"getGravity",vec)
    read("rates",bindings.gimbal_sensor,"getAngularRates",vec)
    io.fallbackAxes=io.fallbackAxes or {}
    for _,name in ipairs(bindings.velocity_sensors or {}) do
        local sensor=name
        jobs[#jobs+1]=function()
            local key="velocity:"..sensor
            pending[key]=true
            local axis=io.fallbackAxes[sensor]
            if not axis then
                local ok,a=pcall(io.readSensor,io,sensor,"getAxis")
                if ok and (a=="x" or a=="y" or a=="z") then axis=a;io.fallbackAxes[sensor]=a end
            end
            local ok,value=pcall(io.readSensor,io,sensor,"getVelocity")
            pending[key]=nil
            if io.hardwareFingerprint~=fingerprint then return end
            store(io,key,axis and ok and finite(value) and {axis=axis,speed=value,name=sensor} or nil,io:nowSeconds(),
                not (axis and ok and finite(value)) and "VELOCITY READBACK INVALID" or nil)
        end
    end
    -- Main-thread assembler getters need their own longer-lived worker.
    -- Cancelling them at the fast-sensor deadline repeatedly loses answers.
    if not io.independentAssemblerSources then assemblerJobs(io,jobs,pending,fingerprint) end
    local function collect()
        if #jobs==0 then return end
        if io.parallel and type(io.parallel.waitForAll)=="function" then io.parallel.waitForAll(table.unpack(jobs))
        else for _,job in ipairs(jobs) do job() end end
    end
    if io.parallel and type(io.parallel.waitForAny)=="function" then
        -- An incomplete backup batch is still useful. End it before the
        -- outer worker timeout, keeping its healthy getters on their normal
        -- retry schedule instead of imposing a whole-reader fault backoff.
        local deadline=os.clock()+2
        local timer
        io.parallel.waitForAny(collect,function()
            timer=os.startTimer(2)
            while os.clock()<deadline do os.pullEventRaw() end
        end)
        if timer then pcall(os.cancelTimer,timer) end
        for key in pairs(pending) do
            local r=(io.fallbackReadings or {})[key] or {}
            r.error="READ TIMED OUT";io.fallbackReadings=io.fallbackReadings or {};io.fallbackReadings[key]=r
        end
    else collect() end
    local result=Sources.compose(io,io:nowSeconds())
    Sources.persistCalibration(io,io:nowSeconds())
    return result
end

-- The old primary sampler consumes cached backup readings instead of issuing
-- the same peripheral calls again. It remains the sole direct Sable reader.
-- Summary: Convert existing vessel/sensor observations into independent source records.
function Sources.legacyInputs(io,now)
    local limit=(io.config.network or {}).sensor_stale_seconds or 6
    local readings={}
    for _,key in ipairs({"orientation","heading","height","verticalSpeed","gravity","rates"}) do readings[key]=Sources.reading(io,key,now,limit) end
    local body={}
    for _,name in ipairs((io.sensorBindings or io.config.hardware or {}).velocity_sensors or {}) do
        local r=Sources.reading(io,"velocity:"..name,now,limit)
        if r then body[#body+1]=copy(r) end
    end
    return readings,body
end

-- Summary: Select fresh primary and calibrated fallback values for each vessel field.
function Sources.compose(io,now)
    local limit=(io.config.network or {}).sensor_stale_seconds or 6
    -- Sable readings routinely arrive 1-2.4 s old through the state reader
    -- (0.5 s interval + read time + transport). A 2 s window flipped to the
    -- backup sensors on every slow sample, blanking absolute position and
    -- flickering the anchor/autopilot. Prefer Sable for up to 5 s.
    local primaryLimit=math.min(limit,5)
    local p=primaryView(io)
    local track=io.assemblyTrack

    local primaryAge=p.sableReadAt or {}
    local function primary(key,value)
        if value~=nil and fresh(now,primaryAge[key],primaryLimit) then return value,primaryAge[key] end
    end
    local function backup(key) return Sources.reading(io,key,now,limit) end
    -- Identity is not a motion measurement. The two-second source preference
    -- window must not expire a verified ID before the configured stale gate.
    local primaryID,idAt
    if validID(p.sableUuid) and fresh(now,primaryAge.uuid,limit) then primaryID,idAt=p.sableUuid,primaryAge.uuid end
    local backupID,backupIDAt=backup("uuid")
    local id=primaryID or backupID or io.retainedVesselUUID or
        (io.fallbackCalibration and io.fallbackCalibration.uuid)
    if primaryID or backupID then io.retainedVesselUUID=primaryID or backupID end
    local assemblerFresh=track and fresh(now,track.definiteAt,limit)
    if not primaryID and assemblerFresh and track.definite==false then id=nil end
    if not primaryID and assemblerFresh and track.definite==false then
        io.fallbackCalibration=nil;io.primaryVessel=nil;io.primaryReadings={}
        io.vessel={valid=false,at=now,reason="VESSEL DISASSEMBLED",positionUnavailable=true,sources={mode="UNAVAILABLE"}}
        return io.vessel
    end
    local c=io.fallbackCalibration
    if c and ((id and c.uuid~=id) or c.fingerprint~=io.hardwareFingerprint) then c=nil;io.fallbackCalibration=nil end
    local nav,navAt=backup("orientation")
    local q,qAt=primary("pose",p.sableOrientation)
    -- Absolute position has no backup source. Expiring it at the 5 s motion
    -- preference window paused (and braked) the autopilot whenever frames
    -- ran late, so position stays usable to the full stale limit, projected
    -- forward horizontally along the frame's own velocity.
    local position,positionAt,projectedSeconds,rawPosition
    if p.sableWorldCom~=nil and fresh(now,primaryAge.pose,limit) and p.localCenterOfMass~=nil and fresh(now,primaryAge.com,limit) then
        position,positionAt=copy(p.sableWorldCom),primaryAge.pose
        local vel=vec(p.sableVelocity)
        local age=now-positionAt
        if position and vel and age>0 and fresh(now,primaryAge.velocity,limit) then
            local span=math.min(age,limit)
            rawPosition=copy(position)
            position.x=position.x+vel.x*span;position.z=position.z+vel.z*span
            projectedSeconds=span
        end
    end
    local positionSource="SABLE"
    if not position and id and q and vec(p.sablePosePosition) and vec(p.sableRotationPoint) and vec(p.sableScale) then
        local com,comAt=backup("com")
        if com then
            local r,scale=p.sableRotationPoint,p.sableScale
            local offset=rotate(q,{x=(com.x-r.x)*scale.x,y=(com.y-r.y)*scale.y,z=(com.z-r.z)*scale.z})
            local origin=p.sablePosePosition
            position={x=origin.x+offset.x,y=origin.y+offset.y,z=origin.z+offset.z}
            positionAt=math.min(qAt,comAt);positionSource="SABLE POSE / PHYSICS ASSEMBLER"
        end
    end
    local h,hAt=backup("height")
    if id and q and (not primaryID or primaryID==id) then
        c=c or {uuid=id,fingerprint=io.hardwareFingerprint}
        if nav and math.abs(qAt-navAt)<=.75 then
            local matched=q
            local dt=navAt-qAt
            local rates,ratesAt=backup("rates")
            if rates and math.abs(ratesAt-navAt)<=.75 then
                local speed=math.sqrt(dot(rates,rates))
                if speed>1e-8 then
                    local angle=math.rad(speed)*dt/2;local k=math.sin(angle)/speed
                    matched=mul(q,{x=rates.x*k,y=rates.y*k,z=rates.z*k,w=math.cos(angle)})
                end
            elseif math.abs(dt)>.1 then matched=nil end
            if matched then c.navToPose=mul(inverse(nav),matched) end
        end
        if position and h and math.abs(positionAt-hAt)<=.75 then
            local vs=backup("verticalSpeed")
            if finite(vs) or math.abs(positionAt-hAt)<=.1 then
                local matchedHeight=h+(vs or 0)*(positionAt-hAt)
                c.heightOffset=position.y-matchedHeight;c.heightOffsetAt=now;c.localCom=copy(p.localCenterOfMass)
            end
        end
        if vec(p.attitudeBow) then c.bow=copy(p.attitudeBow) end
        local rawHeading,rawHeadingAt=backup("heading")
        local actualHeading=c.bow and heading(rotate(q,c.bow))
        if finite(rawHeading) and actualHeading and math.abs(qAt-rawHeadingAt)<=.1 then
            c.headingOffset=(actualHeading-rawHeading+180)%360-180
        end
        io.fallbackCalibration=c
    end
    local v={uuid=id,at=now,position=position,positionUnavailable=position==nil,
        sources={mode="PRIMARY",fields={}},validFields={},telemetryErrors=copy(p.telemetryErrors or {})}
    local selectedAt={}
    local function field(key,value,source,at)
        v[key]=value;v.validFields[key]=value~=nil
        v.sources.fields[key]={source=value~=nil and source or "UNAVAILABLE",at=at,ageSeconds=at and math.max(0,now-at) or nil}
        if value~=nil and at then selectedAt[#selectedAt+1]=at end
        if value~=nil and source~="SABLE" then v.sources.mode="FALLBACK" end
    end
    field("position",position,positionSource,positionAt)
    -- Keep the original coordinates and projection inputs for strafe diagnostics.
    v.positionObservation={raw=rawPosition or position,at=positionAt,
        projectedAt=projectedSeconds and positionAt+projectedSeconds or positionAt,
        projectionVelocityAt=projectedSeconds and primaryAge.velocity or nil}
    local orientation=q;local orientationAt=qAt;local orientationSource="SABLE"
    if not orientation and id and nav and c and c.navToPose then
        orientation=quat(mul(nav,c.navToPose));orientationAt=navAt;orientationSource="NAVIGATION TABLE"
    end
    -- The configured Sable bow axis takes priority over the saved fallback calibration.
    local lockedBow=vec((io.config.geometry or {}).sable_bow_axis)
    local bow=lockedBow and {x=lockedBow.x,y=0,z=lockedBow.z} or (c and c.bow) or vec(p.attitudeBow)
    local geometry=io.config.geometry or {}
    if not bow and q and geometry.orientation_verified then bow=norm(geometry.bow_forward) end
    local forward=orientation and bow and norm(rotate(orientation,bow))
    local hdg=heading(forward)
    local hdgAt=orientationAt
    if not hdg and id and c and c.headingOffset then
        local raw,at=backup("heading")
        if raw then hdg=(raw+c.headingOffset)%360;hdgAt=at;orientationSource="NAVIGATION TABLE" end
    end
    field("heading",id and hdg or nil,orientationSource,hdgAt)
    v.headingSource=orientationSource;v.orientation=orientation;v.forwardDirection=forward
    v.geometryVerified=id~=nil and geometry.orientation_verified==true and hdg~=nil
    local pitch,roll
    if q and bow then
        local f=rotate(q,bow);local r=rotate(q,{x=-bow.z,y=0,z=bow.x})
        pitch=asin(f.y);roll=asin(-r.y)
    end
    local gravity,gravityAt=backup("gravity")
    local down=gravity and norm(gravity)
    local attitudeAt,attitudeSource=qAt,"SABLE"
    if not pitch and id and bow and down then
        pitch=asin(-dot(down,bow));roll=asin(dot(down,{x=-bow.z,y=0,z=bow.x}))
        attitudeAt,attitudeSource=gravityAt,"GIMBAL SENSOR"
    elseif not pitch and forward and orientation and bow then
        pitch=asin(forward.y);roll=asin(-rotate(orientation,{x=-bow.z,y=0,z=bow.x}).y)
        attitudeAt,attitudeSource=orientationAt,orientationSource
    end
    field("pitch",id and pitch or nil,attitudeSource,attitudeAt);field("roll",id and roll or nil,attitudeSource,attitudeAt)
    v.attitudeBow=bow;v.attitudeAxisSource=p.attitudeAxisSource
    local basis,basisAt
    if not orientation and id and hdg and pitch and roll and bow then
        local h,pit,bank=math.rad(hdg),math.rad(pitch),math.rad(roll)
        local f={x=math.sin(h)*math.cos(pit),y=math.sin(pit),z=-math.cos(h)*math.cos(pit)}
        local r0={x=math.cos(h),y=0,z=math.sin(h)};local u0=cross(r0,f)
        local r={x=r0.x*math.cos(bank)-u0.x*math.sin(bank),y=-u0.y*math.sin(bank),
            z=r0.z*math.cos(bank)-u0.z*math.sin(bank)}
        basis={f=f,r=r,u=cross(r,f)};basisAt=math.min(hdgAt,attitudeAt)
        forward=f;v.forwardDirection=f
    end
    local function toWorld(body)
        if orientation then return rotate(orientation,body) end
        if not basis then return nil end
        local f=dot(body,bow);local r=dot(body,{x=-bow.z,y=0,z=bow.x})
        return {x=f*basis.f.x+r*basis.r.x+body.y*basis.u.x,y=f*basis.f.y+r*basis.r.y+body.y*basis.u.y,
            z=f*basis.f.z+r*basis.r.z+body.y*basis.u.z}
    end
    local altitude=position and position.y;local altAt=positionAt;local altitudeSource=positionSource
    if not altitude and id and h and c and finite(c.heightOffset) then
        altitude=h+c.heightOffset;altAt=hAt;altitudeSource="ALTITUDE SENSOR / CALIBRATED CoM"
        local localCom=backup("com")
        if (orientation or basis) and localCom and vec(c.localCom) then
            altitude=altitude+toWorld({x=localCom.x-c.localCom.x,y=localCom.y-c.localCom.y,z=localCom.z-c.localCom.z}).y
        end
    end
    field("altitude",altitude,altitudeSource,altAt);v.altitudeSource=altitudeSource;v.altitudeUnit="world Y"
    local velocity,velocityAt=primary("velocity",vec(p.sableVelocity))
    local velocitySource="SABLE"
    local body,counts,bodyAt,axisAt={},{},nil,{}
    for _,name in ipairs((io.sensorBindings or io.config.hardware or {}).velocity_sensors or {}) do
        local reading,at=backup("velocity:"..name)
        if reading then
            body[reading.axis]=reading.speed;counts[reading.axis]=(counts[reading.axis] or 0)+1
            bodyAt=bodyAt and math.min(bodyAt,at) or at;axisAt[reading.axis]=at
        end
    end
    for axis,count in pairs(counts) do if count~=1 then body[axis]=nil end end
    local bodyVector=vec(body)
    if not velocity and id and (orientation or basis) and bodyVector and geometry.velocity_frame_verified and geometry.velocity_unit=="blocks_per_second" then
        velocity=toWorld(bodyVector);velocityAt=math.min(bodyAt,orientationAt or basisAt);velocitySource="AXIS VELOCITY SENSORS"
    end
    v.velocityFrameVerified=geometry.velocity_frame_verified==true and geometry.velocity_unit=="blocks_per_second" and velocity~=nil
    field("linearVelocity",id and velocity or nil,velocitySource,velocityAt)
    local vs=velocity and velocity.y;local vsAt=velocityAt;local vsSource=velocitySource
    if not vs and id then vs,vsAt=backup("verticalSpeed");vsSource="ALTITUDE SENSOR" end
    field("verticalSpeed",vs,vsSource,vsAt)
    local horizontal=forward and math.sqrt(forward.x^2+forward.z^2)
    local speed=velocity and horizontal and horizontal>.1 and (velocity.x*forward.x+velocity.z*forward.z)/horizontal or nil
    local speedAt=speed and math.min(velocityAt,orientationAt or basisAt) or nil
    local speedSource=velocitySource
    -- Forward speed is Sable's world velocity along the horizontal bow. The velocity sensor on the
    -- bow axis (geometry.velocity_forward) is the fallback when no velocity vector is available.
    local vf=vec(geometry.velocity_forward)
    local bowAxis,bowSign
    if vf then
        for _,axis in ipairs({"x","y","z"}) do
            if math.abs(vf[axis])>0.5 then bowAxis,bowSign=axis,vf[axis]>0 and 1 or -1 end
        end
    end
    local sensorSpeed=bowAxis and counts[bowAxis]==1 and finite(body[bowAxis]) and body[bowAxis]*bowSign or nil
    if not speed and id and sensorSpeed and geometry.velocity_frame_verified and geometry.velocity_unit=="blocks_per_second" then
        speed,speedAt,speedSource=sensorSpeed,axisAt[bowAxis],"VELOCITY SENSOR"
    end
    field("forwardSpeed",speed,speedSource,speedAt)
    -- Each reader's Sable velocity along the horizontal bow, and the bow sensor, for the debug recording.
    local by={}
    for origin,r in pairs(io.sableVelocityBy or {}) do
        local w=vec(r.value)
        if w and horizontal and horizontal>.1 then by[origin]=(w.x*forward.x+w.z*forward.z)/horizontal end
    end
    v.forwardSpeedSableCore,v.forwardSpeedSableReader,v.forwardSpeedSensor=by.core,by.reader,sensorSpeed
    v.forwardSpeedSource=speedSource;v.velocityForward=copy(geometry.velocity_forward);v.forwardSpeedAlongBow=velocity and forward and dot(velocity,forward) or nil
    local angular,angularAt=primary("angular",vec(p.sableAngular))
    local angularSource="SABLE"
    if not angular and (orientation or basis) then
        local rates,at=backup("rates")
        if rates then angular=toWorld({x=math.rad(rates.x),y=math.rad(rates.y),z=math.rad(rates.z)});angularAt=math.min(at,orientationAt or basisAt);angularSource="GIMBAL SENSOR" end
    end
    field("angularVelocity",angular,angularSource,angularAt)
    local mass,massAt=primary("mass",p.sableMass);local massSource="SABLE"
    if not mass and id then mass,massAt=backup("mass");massSource="PHYSICS ASSEMBLER" end
    field("mass",mass,massSource,massAt)
    local pressure,pressureAt=backup("pressure")
    local environment=copy(p.environment or {})
    if not primaryID or not fresh(now,p.at,primaryLimit) then environment={} end
    -- Prefer current Sable pressure at the vessel CoM. Hold it for up to
    -- 30 seconds within three altitude blocks when the sensor differs by
    -- more than 30%; otherwise use the available sensor reading. The physics
    -- monitor can explicitly prefer the sensor for this session. Sampling
    -- height differences matter in the upper pressure taper.
    local sablePressure=finite(environment.airPressure) and environment.airPressure>0 and environment.airPressure or nil
    environment.airPressureSensor=pressure;environment.airPressureSable=sablePressure
    local held=io.pressureHold
    local chosen,source
    if io.pressurePreference=="ALTITUDE SENSOR" and pressure then
        -- Set by the physics monitor when Sable's value contradicted the
        -- measured acceleration and the sensor's fitted (this session only).
        chosen,source=pressure,"ALTITUDE SENSOR (PREFERRED)"
    elseif sablePressure then
        chosen,source=sablePressure,"SABLE AERO"
        io.pressureHold={value=sablePressure,at=now,altitude=v.altitude}
    elseif held and finite(held.value) and now-(held.at or -1e9)<=30 and
        (not finite(v.altitude) or not finite(held.altitude) or math.abs(v.altitude-held.altitude)<=3) and
        not (pressure and math.abs(pressure-held.value)<=0.3*held.value) then
        chosen,source=held.value,"SABLE AERO (HELD)"
    elseif pressure then
        chosen,source=pressure,"ALTITUDE SENSOR"
    end
    environment.airPressure=chosen;environment.airPressureSource=source
    if gravity then local g=math.sqrt(dot(gravity,gravity));if g>0 then environment.gravity={x=0,y=-g,z=0} end end
    environment.valid=environment.gravity~=nil and finite(environment.airPressure)
    v.environment=environment
    v.localCenterOfMass=backup("com") or p.localCenterOfMass
    v.sensors={bodyVelocity=body,navigation={rawHeading=backup("heading"),orientation=nav},
        gimbal={gravity=gravity,angularRates=backup("rates")},altitude={worldY=h,verticalSpeed=backup("verticalSpeed")}}
    v.valid=id~=nil and (altitude~=nil or hdg~=nil or position~=nil)
    v.reason=not v.valid and ("NO VERIFIED VESSEL TELEMETRY") or nil
    if not v.valid then v.sources.mode="UNAVAILABLE" end
    if #selectedAt>0 then v.at=math.max(table.unpack(selectedAt)) end
    v.sources.positionAvailable=position~=nil;v.sources.positionProjectedSeconds=projectedSeconds;v.sources.identitySource=primaryID and "SABLE"
        or (backupID and "PHYSICS ASSEMBLER" or "RETAINED ASSOCIATION")
    v.sources.calibrated=c~=nil;v.sources.primaryAgeSeconds=primaryAge.pose and math.max(0,now-primaryAge.pose) or nil
    v.sources.calibrationPersistenceError=io.sourceCalibrationError
    local readErrors={}
    for key,r in pairs(io.fallbackReadings or {}) do if r.error then readErrors[key]=r.error end end
    v.sources.backupReadErrors=next(readErrors) and readErrors or nil
    io.vessel=v
    return v
end
Sources.quaternion={multiply=mul,inverse=inverse,rotate=rotate}
return Sources
