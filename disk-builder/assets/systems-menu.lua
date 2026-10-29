-- Amaryllis systems menu presentation v1 BEGIN
-- Pure display/input helpers. Core remains the authority for every command.
local function systemsMenuItems(snapshot)
    local live=isLive(snapshot)
    local systems=snapshot.systemsStartup or {}
    local restart=snapshot.systemsRestart or {}
    local lift=snapshot.emergencyLift or {}
    local kill=emergencyLift(snapshot,live)
    local assembled=not assemblyProblem(snapshot,live)
    local function item(label,action,available,reason,danger)
        if not live then available=false;reason="WAITING FOR FRESH CORE STATUS"
        elseif not fleetActionAllowed(snapshot,action) then available=false;reason="FLEET NOT READY" end
        return {label=label,action=action,enabled=available==true,reason=reason,danger=danger}
    end
    local startReason=lift.latched and "DISARM KILL BEFORE START" or
        (not assembled and "VESSEL ASSEMBLY NOT READY") or systems.reason or "START SYSTEMS UNAVAILABLE"
    local killAvailable=not kill.pending and not kill.accepted and not kill.complete
    return {
        item("Start Systems",{type="start_systems"},systems.available==true and not systems.active and
            not lift.latched and assembled,startReason),
        item("Stop Systems",{type="systems_stop"},systemsStopAvailable(snapshot),"SYSTEMS ARE NOT RUNNING"),
        item("Restart Systems",{type="restart_systems"},restart.available==true and not lift.latched and assembled,
            restart.reason or (lift.latched and "DISARM KILL BEFORE RESTART") or "SYSTEMS RESTART UNAVAILABLE"),
        item(kill.disarm and "Disarm Kill" or "Kill Lift",
            {type=kill.disarm and "disarm_lift_kill" or "emergency_kill_lift"},killAvailable,
            kill.message or "LIFT KILL IN PROGRESS",not kill.disarm)
    }
end

local function systemsMenuLayout(width)
    local menuWidth=28
    return {x=width-menuWidth+1,y=4,width=menuWidth,height=12}
end

local function drawSystemsMenu(surface,renderer,snapshot)
    if renderer.killReview or snapshot.systemsStopReview then renderer.systemsMenu=nil end
    renderer.systemsMenuRegions={}
    if not renderer.systemsMenu then return surface end
    local layout=systemsMenuLayout(surface.width)
    local headerX=math.floor(surface.width*2/3)+1
    drawButton(surface,headerX,3,surface.width-headerX+1,"Options [v]","selected")
    fillRect(surface,layout.x,layout.y,layout.width,layout.height,"gray","white")
    for index,entry in ipairs(systemsMenuItems(snapshot)) do
        local y=layout.y+1+(index-1)*2
        drawButton(surface,layout.x+1,y,layout.width-2,entry.label,
            entry.enabled and (entry.danger and "danger" or "enabled") or "disabled")
        renderer.systemsMenuRegions[index]={x1=layout.x+1,x2=layout.x+layout.width-2,
            y1=y,y2=y,action=entry.action,enabled=entry.enabled,reason=entry.reason}
    end
    if renderer.systemsMenuNotice then
        for index,line in ipairs(wrapErrorText(renderer.systemsMenuNotice,layout.width-2)) do
            if index>2 then break end
            put(surface,layout.x+1,layout.y+8+index,line,"white")
        end
    end
    return finishSurface(surface)
end

local function touchSystemsMenu(renderer,x,y,snapshot,width)
    if renderer.killReview or snapshot.systemsStopReview then renderer.systemsMenu=nil;return false end
    local trigger=y==3 and x>math.floor(width*2/3)
    if not renderer.systemsMenu then
        if not trigger then return false end
        renderer.systemsMenu=true;renderer.systemsMenuNotice=nil
        return true
    end
    local layout=systemsMenuLayout(width)
    for index,entry in ipairs(systemsMenuItems(snapshot)) do
        local row=layout.y+1+(index-1)*2
        if y==row and x>=layout.x+1 and x<=layout.x+layout.width-2 then
            -- Recompute from this touch's raw snapshot, never cached draw state.
            if not entry.enabled then renderer.systemsMenuNotice=entry.reason;return true end
            renderer.systemsMenu=nil;renderer.systemsMenuNotice=nil;renderer.actionNotice=nil
            if entry.action.type=="emergency_kill_lift" then
                renderer.killReview={at=os.clock and os.clock() or 0}
                return true
            end
            return true,entry.action
        end
    end
    if trigger or x<layout.x or x>=layout.x+layout.width or y<layout.y or y>=layout.y+layout.height then
        renderer.systemsMenu=nil;renderer.systemsMenuNotice=nil
    end
    -- Gaps and outside touches are consumed; nothing underneath receives them.
    return true
end
-- Amaryllis systems menu presentation v1 END
