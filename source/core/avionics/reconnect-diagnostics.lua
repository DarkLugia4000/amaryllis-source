-- @ama-section: Diagnostic entry | Launch the configured read-only connection probe.
-- One-shot read-only recovery probe. Does not restart or control flight tasks.
local r=os.__amaryllisRuntime or {}
local s=r.snapshot or {}
local tabs={}
if multishell then
    for id=1,multishell.getCount() do tabs[#tabs+1]={id=id,title=multishell.getTitle(id)} end
end
local now=os.clock()
local probe={clock=now,epoch=os.epoch("utc"),runtimeAge=r.publishedAt and now-r.publishedAt,
    diskCapacityBytes=type(fs.getCapacity)=="function" and fs.getCapacity("/") or nil,
    diskFreeBytes=fs.getFreeSpace("/"),
    running=r.running,sampling=r.sampling,assembly=s.assembly,seq=s.seq,
    inputAge=s.inputs and s.inputs.sampleAgeSeconds,vessel=s.vessel and s.vessel.reason,
    nativeWorkers=os.__amaryllisCoreWorkerTabs,tabs=tabs}
os.__amaryllisRecoveryProbe=probe
local saved,issue=pcall(function()
    fs.makeDir("/avionics/data")
    local h=assert(fs.open("/avionics/data/core-debug.json","w"))
    h.write(textutils.serializeJSON(probe));h.close()
end)
if saved then print("Saved current worker state to /avionics/data/core-debug.json")
else print("Report retained in memory; disk save failed: "..tostring(issue)) end
if type(shell.openTab)=="function" then
    local tab=shell.openTab("/avionics/diagnostics.lua")
    if multishell then multishell.setTitle(tab,"diagnostics") end
    print("Started fresh diagnostics in tab "..tostring(tab))
else
    shell.run("/avionics/diagnostics.lua")
end
