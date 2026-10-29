"""Apply the approved bridge presentation changes to supported editable sources."""

MARKER = '-- Amaryllis systems menu presentation v1 BEGIN'


def apply_console(payload, helper, require):
    """Core-only presentation. Auxiliary packages and flight modules stay intact."""
    path = '/avionics/common/console.lua'
    text = payload[path].decode('utf-8')
    marker = '-- Amaryllis Panel Home core console v1'
    if marker in text:
        import hashlib
        existing = payload.get('/avionics/panel_console.lua', helper)
        require(existing == helper or hashlib.sha256(existing).hexdigest() in {
            '61eea4fef406c6a0728458bdfe7241968d5c1c0200cd8fcf0c95dbe0b9946054',
            '95e464de8054a31f798789a00b92d56d993137e83b0f8e3cc3bee5f53650fa63',
            '71d6daefba1a37e5c51774407217c83b7da4cab0b7c4a18a664a3c9e4ce597c2'},
            'Unsupported existing Panel Home revision.')
        payload['/avionics/panel_console.lua'] = helper
        return existing != helper
    anchor = '    local mode = arguments[1]\n'
    require(text.count(anchor) == 1, 'Unsupported core console entry point for Panel Home.')
    addition = '''    -- Amaryllis Panel Home core console v1
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
    return True


# Apply the guarded Systems menu and approved navigator wording revisions.
def apply(payload, helper, require):
    path = '/packages/navigation/ui.lua'
    text = payload[path].decode('utf-8')
    helper = helper.decode('utf-8').strip()
    if MARKER in text:
        require(helper in text, 'Unsupported existing Systems menu revision. Update the builder for this source.')
        return False

    def replace(old, new, label):
        nonlocal text
        require(text.count(old) == 1, f'Unsupported bridge {label}. Update the builder for this UI source.')
        text = text.replace(old, new, 1)

    def section(start, end, new, label):
        nonlocal text
        require(text.count(start) == 1 and text.count(end) == 1,
                f'Unsupported bridge {label}. Update the builder for this UI source.')
        first = text.index(start)
        last = text.index(end, first)
        text = text[:first] + new + text[last:]

    replace('label = "ALTITUDE TARGET"', 'label = "SYSTEMS"', 'Systems heading')
    section('            local targets = getTargets(snapshot)\n',
            '            drawButton(surface, group.x1, 3, groupWidth, label, style)',
            '            local label,style="Options [v]","enabled"\n', 'Options control')
    section('        local kill=emergencyLift(snapshot,live)\n',
            '        local lateral=snapshot.lateralControl or {};local modes=snapshot.modes or {}', '', 'standalone kill button')
    replace('    -- Anchor lives under Navigation; retain only FLIGHT\'s emergency action.',
            '    -- Systems actions live in Options; keep the strafe control here.', 'header comment')
    replace('"VERTICAL SPEED " .. vertical .. " b/s"', '"V/S " .. vertical .. " b/s"', 'vertical speed label')
    replace('6, "BOW UP", "cyan"', '6, "^ BOW ^", "cyan"', 'flight orientation label')
    replace('9, "BOW UP / LIFT OUTPUTS", "gray"', '9, "^ BOW ^ / LIFT OUTPUTS", "gray"', 'ship orientation label')
    replace('''        text(12,"Use one writable disk visible to core.","gray")
        text(13,"Installer disks are refused. Flight is unaffected.","gray")''',
            '''        text(12,"Use an empty disk in one of core's disk drives.","gray")''', 'debug disk instructions')
    replace('''        text(16,debug.reason or debug.path or "Logs use /amaryllis-logs/ on the disk.",debug.reason and "red" or "gray")''',
            '''        local location=debug.reason or debug.path or "Logs are located under /amaryllis-logs/ directory on the disk."
        for index,line in ipairs(wrapErrorText(location,surface.width-2)) do
            if index>2 then break end
            text(15+index,line,debug.reason and "red" or "gray")
        end''', 'debug log location')
    replace('        if sub=="DISPLAY" then text(18,"Text scale 0.5; fixed 57 x 24 layout.","gray") end\n', '', 'display footer')
    replace('if killReview and (page~="FLIGHT" or (now or 0)-killReview.at>UI.KILL_REVIEW_SECONDS) then',
            'if killReview and (now or 0)-killReview.at>UI.KILL_REVIEW_SECONDS then', 'kill review page scope')
    replace('if self.page~="FLIGHT" or now-self.killReview.at>UI.KILL_REVIEW_SECONDS then',
            'if now-self.killReview.at>UI.KILL_REVIEW_SECONDS then', 'kill review input scope')
    require(text.count('fillRect(surface,2,6,width-2,15,"black","white")') == 2,
            'Unsupported bridge confirmation surface. Update the builder for this UI source.')
    text=text.replace('fillRect(surface,2,6,width-2,15,"black","white")',
                      'fillRect(surface,1,6,width,15,"black","white")')
    replace('function UI.new(monitor, config)', helper + '\n\nfunction UI.new(monitor, config)', 'menu helpers')
    replace('    snapshot = retainedDisplay(self,snapshot)',
            '    local actionSnapshot=snapshot\n    snapshot = retainedDisplay(self,snapshot)', 'raw snapshot preservation')
    replace('        surface = drawTooSmall(self, width, height, false)\n        self.tabs = {}',
            '        surface = drawTooSmall(self, width, height, false)\n        self.tabs = {};self.systemsMenu=nil', 'small screen menu reset')
    replace('        surface = drawMain(self, snapshot, width, height, now)',
            '        surface = drawMain(self, snapshot, width, height, now)\n'
            '        surface = drawSystemsMenu(surface,self,actionSnapshot)', 'menu overlay draw')
    section('    local killWidth=math.floor((width-3)/3)\n',
            '    if self.page=="NAV" and (self.navView or "ANCHOR")=="ANCHOR"', '', 'old kill touch target')
    replace('    local lateralWidth=math.floor((width-3)/3)',
            '    local menuHandled,menuAction=touchSystemsMenu(self,x,y,snapshot,width)\n'
            '    if menuHandled then return menuAction end\n'
            '    local lateralWidth=math.floor((width-3)/3)', 'menu input routing')
    section('    if fleetBootBlocked(snapshot) then\n        if x>math.floor(width*2/3) and y==3 then',
            '    if y==3 and isLive(snapshot) and x<=math.floor(width*2/3)',
            '    if fleetBootBlocked(snapshot) then return nil end\n', 'old blocked header actions')
    section('    -- The existing altitude button toggles altitude authority only.',
            '\n    return nil\nend\n\n\nfunction UI:editorKey', '', 'old altitude button input')
    replace('function UI:input(event,value)\n',
            'function UI:input(event,value)\n'
            '    if self.systemsMenu then\n'
            '        if event=="key" and keys and value==keys.escape then self.systemsMenu=nil;self.systemsMenuNotice=nil end\n'
            '        return nil\n'
            '    end\n', 'menu keyboard routing')
    payload[path] = text.encode('utf-8')
    return True

def apply_remote(payload, helper, require):
    """Unified pocket presentation; preserves pairing and flight request handlers."""
    import hashlib
    client = '/avionics/remote_client.lua'
    existing = payload.get(client)
    require(existing == helper or existing is not None and hashlib.sha256(existing).hexdigest() in {
            '2bc5416623af6cae5c5008c8e13c7aa4be9c4777e5deb97364f54a10b7b7adaa',
            '8352aa3c937a392d68870e85c80f79822ac08ad046c18b362648eda64ad9200e',
            'dd8ae8d9c194529a999ffd81b5297f8893cd76a9a65e1d9aee18ac2371aa9d2c'},
            'Unsupported remote client revision. Update the builder for this source.')
    console = '/avionics/common/console.lua'
    text = payload[console].decode('utf-8')
    marker = '-- Amaryllis remote fleet presentation v1'
    if marker not in text:
        anchor = '        return {lines=result}\n    end,function(sender,pair,packet)'
        require(text.count(anchor) == 1, 'Unsupported remote status callback for Panel Home.')
        replacement = '''        -- Amaryllis remote fleet presentation v1
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
    installer = '/avionics/remote_install.lua'
    source = payload[installer]
    old = b'local BUILD = "amaryllis-remote-ap-v2"'
    new = b'local BUILD = "amaryllis-remote-panel-v1"'
    require(source.count(old)==1 or source.count(new)==1, 'Unsupported remote provisioning revision.')
    payload[installer] = source.replace(old,new,1)
    payload[client] = helper
    return existing != helper

def apply_remote_transient(payload, require):
    """Remote destinations are named on core and never replace the onboard draft."""
    def change(path, old, new, label):
        source=payload[path].decode('utf-8')
        if new in source:
            require(source.count(new)==1 and source.count(old)==new.count(old), 'Partial remote transient overlay: '+label)
            return
        require(source.count(old)==1, 'Unsupported remote destination source: '+label)
        payload[path]=source.replace(old,new,1).encode('utf-8')

    path='/avionics/remote_ap.lua'
    change(path, 'd={name=d.name,x=d.x,z=d.z,altitude=d.altitude,cruiseSpeed=d.cruiseSpeed}',
           'd={name="Remote CMD",x=d.x,z=d.z,altitude=d.altitude,cruiseSpeed=d.cruiseSpeed}',
           'fixed remote command name')
    change(path, '    if anchor and anchor.active then anchor:cancel(nil,"REMOTE ROUTE ACCEPTED; DIGITAL ANCHOR RELEASED") end',
           '''    -- Remote CMD is transient; retain navigator's destination editor.
    ap.draft=previous
    if anchor and anchor.active then anchor:cancel(nil,"REMOTE ROUTE ACCEPTED; DIGITAL ANCHOR RELEASED") end''',
           'onboard draft isolation')
    change('/avionics/autopilot.lua',
           'function AP:checkpoint()\n    if not self.active then return nil end',
           'function AP:checkpoint()\n    -- Remote CMD has no persistent route checkpoint.\n    if not self.active or self.remoteOwner then return nil end',
           'transient route checkpoint')
    change(path,
           'local previous=ap.draft;local previousAltitude=f.controls.targets.altitude',
           'local previous=ap.draft;local previousRoute=ap.route;local previousAltitude=f.controls.targets.altitude',
           'route rollback capture')
    change(path,
           '        ap.draft=previous;f.controls.targets.altitude=previousAltitude',
           '        ap.route=previousRoute;ap.draft=previous;f.controls.targets.altitude=previousAltitude',
           'route rollback restoration')
    change('/avionics/autopilot.lua',
           'function AP:cancel(io,controls,reason,brake)\n    self.remoteOwner=nil',
           'function AP:cancel(io,controls,reason,brake)\n    -- End a one-off remote command without retaining its destination.\n    if self.remoteOwner then self.route=nil end\n    self.remoteOwner=nil',
           'remote route cleanup')

    legacy='/avionics/remote_ap_client.lua'
    source=payload[legacy].decode('utf-8')
    marker='-- Transient Remote CMD compatibility client.'
    if marker not in source:
        require('local form={name="Remote #"..os.getComputerID(),cruiseSpeed=3}' in source,
                'Unsupported legacy remote AP client.')
        source=source.replace('local form={name="Remote #"..os.getComputerID(),cruiseSpeed=3}',
                              marker+'\nlocal form={name="Remote CMD",cruiseSpeed=3}',1)
        first=source.index('local saved=readJSON("/remote/destination.json")')
        last=source.index('local releaseAnchor=false',first)
        source=source[:first]+source[last:]
        first=source.index('local function saveDraft()')
        last=source.index('local function startReview(cancel)',first)
        source=source[:first]+source[last:]
        block='''    if not review.cancel then
        local savedOK=pcall(saveDraft)
        if not savedOK then notice="Cannot save pocket destination";return end
    end
'''
        require(source.count(block)==1,'Unsupported legacy remote destination save.')
        source=source.replace(block,'',1)
        payload[legacy]=source.encode('utf-8')

def apply_remote_reads(payload, require):
    """Fast cached reads; only existing AP mutations enter the command queue."""
    path='/avionics/remote_install.lua'
    text=payload[path].decode('utf-8')
    marker='-- Remote cached reads v1'
    if marker in text:
        require(text.count(marker)==1,'Unsupported duplicate remote read overlay.')
        return
    old='''                    local at=os.clock();local prior=last[p.pairID]
                    if prior and at-prior<1 then reply.error="Status requested too quickly"
                    else
                        last[p.pairID]=at
                        local ok,data=pcall(status,p.page)
                        reply.ok=ok;reply.data=ok and data or nil;reply.error=not ok and "Core status unavailable" or nil
                    end'''
    new='''                    -- Remote cached reads v1: no read queue and no hardware probes.
                    local at=os.clock();local pages=last[p.pairID]or{};last[p.pairID]=pages
                    local prior=pages[p.page]
                    if prior and at>=prior.at and at-prior.at<.5 then
                        reply.ok=true;reply.data=prior.data;reply.cachedAgeSeconds=at-prior.at
                    else
                        local ok,data=pcall(status,p.page)
                        reply.ok=ok;reply.data=ok and data or nil;reply.error=not ok and "Core status unavailable" or nil
                        if ok then pages[p.page]={at=at,data=data}end
                    end'''
    require(text.count(old)==1,'Unsupported remote status read handler.')
    payload[path]=text.replace(old,new,1).encode('utf-8')
