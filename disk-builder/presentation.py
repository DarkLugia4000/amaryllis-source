"""Generate the core console from the package console: Panel Home entry and remote fleet status."""

def apply_console(payload, helper, require):
    """Insert the Panel Home entry into the core console; auxiliary packages keep the package console."""
    path = '/avionics/common/console.lua'
    text = payload[path].decode('utf-8')
    anchor = '    local mode = arguments[1]\n'
    require(text.count(anchor) == 1, 'Unsupported core console entry point for Panel Home.')
    addition = '''    -- Panel Home core entry: route the core console to the application host.
    if Console.isCore() and (mode==nil or mode=="panel") then
        local Panel=require("avionics.panel_console")
        if mode=="panel" then
            local owner=os.__amaryllisPanelOwner
            if owner and owner.active and type(owner.focus)=="function"and owner.focus()then return end
            Panel.start(Console,openTab,reportError);return
        end
        -- A manually reopened UI must reuse existing control processes.
        if type(os.__amaryllisRuntime)=="table" and os.__amaryllisRuntime.running==true and
            not os.__amaryllisPanelOwner then Panel.start(Console,openTab,reportError);return end
        local ok,issue=pcall(Panel.host)
        if ok then return end
        reportError("Application host unavailable: "..safeText(issue),"panel-host")
        Panel.start(Console,openTab,reportError);return
    end
'''
    payload[path] = text.replace(anchor, anchor + addition, 1).encode('utf-8')
    payload['/avionics/panel_console.lua'] = helper


def apply_remote(payload, helper, require):
    """Attach registered computer status to the core console's remote FLEET page."""
    client = '/avionics/remote_client.lua'
    require(payload.get(client) == helper, 'Remote client differs from the builder remote-panel asset.')
    console = '/avionics/common/console.lua'
    text = payload[console].decode('utf-8')
    anchor = '        return {lines=result}\n    end,function(sender,pair,packet)'
    require(text.count(anchor) == 1, 'Unsupported remote status callback for Panel Home.')
    replacement = '''        -- Remote fleet page: attach registered computer status for Panel Home.
        local data={lines=result}
        if page=="FLEET" then
            local Panel=require("avionics.panel_console")
            local fleet=readJson("/fleet.json")or{}
            local catalog=readJson("/installer/library.json")or{}
            data.computers=Panel.remoteComputers({runtime=runtime,capture=capture,now=os.clock(),
                fleet=fleet.computers,catalog=catalog.roles})
        end
        return data
    end,function(sender,pair,packet)'''
    text = text.replace(anchor,replacement,1)
    payload[console] = text.encode('utf-8')
    require(payload['/avionics/remote_install.lua'].count(b'local BUILD = "amaryllis-remote-panel-v1"') == 1,
            'Unsupported remote provisioning revision.')

