local K={};local active,callbacks,registered={},{},{}
local api
-- UE4SS entry-script APIs must be supplied by their owning mod. Required
-- modules must not silently depend on the host's main-thread global table.
function K.configure(host) api=assert(host);return K end
local function log(message)
    if api and api.log then api.log(message) else print('[WarThunderMOD] '..message) end
end
local function resolve(binding)
    local keys=api and api.keys or Key
    local modifierKeys=api and api.modifiers or ModifierKey
    if type(binding)~='string' or not keys then return end
    local token=binding:match('([^+]+)$');if not token then return end
    local name=token:gsub(' ','_'):upper()
    name=({INSERT='INS',DELETE='DEL',ENTER='RETURN',SPACE_BAR='SPACE',LEFT='LEFT_ARROW',RIGHT='RIGHT_ARROW',UP='UP_ARROW',DOWN='DOWN_ARROW',
        LEFTMOUSEBUTTON='LEFT_MOUSE_BUTTON',RIGHTMOUSEBUTTON='RIGHT_MOUSE_BUTTON',MIDDLEMOUSEBUTTON='MIDDLE_MOUSE_BUTTON',
        THUMB_MOUSE_BUTTON='XBUTTON_ONE',THUMB_MOUSE_BUTTON_2='XBUTTON_TWO',
        ['0']='ZERO',['1']='ONE',['2']='TWO',['3']='THREE',['4']='FOUR',['5']='FIVE',['6']='SIX',['7']='SEVEN',['8']='EIGHT',['9']='NINE'})[name] or name
    local key=keys[name];if not key then return end
    local modifiers={}
    for part in binding:gmatch('([^+]+)%+') do
        local id=({Ctrl='CONTROL',Control='CONTROL',Alt='ALT',Shift='SHIFT'})[part]
        if not id or not modifierKeys or not modifierKeys[id] then return end
        modifiers[#modifiers+1]=modifierKeys[id]
    end
    table.sort(modifiers)
    local parts={tostring(key)}
    for _,value in ipairs(modifiers) do parts[#parts+1]=tostring(value) end
    return key,modifiers,table.concat(parts,':')
end
function K.refresh(bindings,actions)
    active=bindings or {};callbacks=actions or callbacks
    local register=api and api.register or RegisterKeyBindAsync
    local schedule=api and api.schedule or ExecuteInGameThread
    if not register or not schedule then log('GAMEPLAY_KEYS_ERROR | key registration/game-thread API unavailable');return false end
    local owners={}
    for action in pairs(callbacks) do
        local _,_,id=resolve(active[action]);if id then owners[id]=action end
    end
    -- Replace dispatch targets even for keys already registered: UE4SS has no
    -- unregister operation, and old closures must follow the current mapping.
    K.owners=owners
    for action in pairs(callbacks) do
        local binding=active[action];local key,modifiers,id=resolve(binding)
        if key and not registered[id] then
            local function pressed()
                schedule(function()
                    local current=K.owners[id]
                    if not current then return end
                    if api and api.canDispatch and not api.canDispatch(current) then
                        log('GAMEPLAY_KEY_BLOCKED | '..current);return
                    end
                    log('GAMEPLAY_KEY_PRESSED | '..current..' | '..tostring(active[current]))
                    local ok,err=pcall(callbacks[current])
                    if not ok then log('GAMEPLAY_KEY_ERROR | '..current..' | '..tostring(err)) end
                end)
            end
            local ok,err=pcall(function()
                if #modifiers>0 then register(key,modifiers,pressed) else register(key,pressed) end
            end)
            if ok then registered[id]=true
            else log('GAMEPLAY_KEYS_ERROR | '..binding..' | '..tostring(err)) end
        elseif not key then
            log('GAMEPLAY_KEYS_ERROR | '..action..' | unsupported binding='..tostring(binding))
        end
        if key and registered[id] then log('GAMEPLAY_KEY_READY | '..action..' | '..binding) end
    end
    return true
end
return K
