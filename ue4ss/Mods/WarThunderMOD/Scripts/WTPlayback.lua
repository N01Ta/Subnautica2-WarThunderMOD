local Route = require("WTRoute")
local P = {}
P.__index = P
P.STATES = {Ready="Ready", Playing="Playing", Paused="Paused", Stopped="Stopped"}
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k,v in pairs(value) do result[k]=copy(v) end
    return result
end
local function findRoute(document, id)
    for _, route in ipairs(document.routes or {}) do if route.id == id then return route end end
    return nil
end
function P.new(document, opts)
    assert(type(document)=="table" and type(document.routes)=="table","scenario document required")
    local self=setmetatable({document=document,state="Ready",units={},registry={},elapsed=0,
        previewRate=(document.playback and document.playback.previewSpeed) or 1,
        loop=(document.playback and document.playback.loop) or false,
        postRouteSeconds=(document.playback and document.playback.postRouteSeconds) or 0,
        onStep=opts and opts.onStep,onCleanup=opts and opts.onCleanup},P)
    for _, route in ipairs(document.routes) do
        for _,path in ipairs(Route.paths(route)) do
            self.units[path.id]={routeId=path.id,sourceRouteId=route.id,compiled=Route.compile(path,64),state={distanceCm=0,segmentIndex=1,segmentSeconds=0,speedMps=path.points[1].targetSpeedMps or 0},done=false,postElapsed=0}
        end
    end
    return self
end
function P:_resetUnits()
    for _, unit in pairs(self.units) do
        unit.state={distanceCm=0,segmentIndex=1,segmentSeconds=0,speedMps=unit.compiled.route.points[1].targetSpeedMps or 0}
        unit.done=false; unit.postElapsed=0
    end
    self.elapsed=0
end
function P:_clearRegistry()
    for i=#self.registry,1,-1 do
        local item=table.remove(self.registry,i)
        if self.onCleanup then pcall(self.onCleanup,item) end
        if item.actor then pcall(function() item.actor:K2_DestroyActor() end) end
    end
end
function P:register(kind, actor, metadata)
    assert(self.state=="Playing" or self.state=="Paused","cannot register outside playback")
    local item={kind=kind or "actor",actor=actor,metadata=copy(metadata or {})}
    self.registry[#self.registry+1]=item
    return item
end
function P:start(restart)
    if not next(self.units) then return false,"no connected flight path" end
    if self.state=="Playing" then
        if not restart then return false,"already playing" end
        self:stop()
    elseif self.state=="Paused" then
        if not restart then return false,"already paused" end
        self:stop()
    end
    self:_resetUnits(); self.state="Playing"; self.elapsed=0
    return true
end
function P:pause()
    if self.state~="Playing" then return false,"pause requires Playing" end
    self.state="Paused"; return true
end
function P:resume()
    if self.state~="Paused" then return false,"resume requires Paused" end
    self.state="Playing"; return true
end
function P:stop()
    if self.state~="Playing" and self.state~="Paused" then return false,"stop requires Playing or Paused" end
    self.state="Stopped"; self:_clearRegistry(); return true
end
function P:update(dt)
    assert(type(dt)=="number" and dt>=0 and dt<=60,"invalid delta time")
    if self.state~="Playing" then return self:snapshot() end
    self.elapsed=self.elapsed+dt
    local active=false
    local snapshots={}
    for id,unit in pairs(self.units) do
        if not unit.done then
            active=true
            unit.state=Route.advance(unit.compiled,unit.state,dt,self.previewRate)
            if unit.state.distanceCm >= unit.compiled.lengthCm then
                unit.postElapsed=unit.postElapsed+dt
                if unit.postElapsed >= self.postRouteSeconds then unit.done=true end
            end
            local snapshot={routeId=id,position=unit.state.position,forward=unit.state.forward,speedMps=unit.state.speedMps,distanceCm=unit.state.distanceCm,done=unit.done}
            snapshots[#snapshots+1]=snapshot
            if self.onStep then pcall(self.onStep,snapshot,unit) end
        end
    end
    if not active then
        if self.loop then self:_resetUnits() else self.state="Stopped"; self:_clearRegistry() end
    end
    return snapshots
end
function P:snapshot()
    local result={state=self.state,elapsed=self.elapsed,registryCount=#self.registry,units={}}
    for id,unit in pairs(self.units) do result.units[id]={distanceCm=unit.state.distanceCm,speedMps=unit.state.speedMps,done=unit.done} end
    return result
end
function P:canEdit() return self.state~="Playing" and self.state~="Paused" end
return P
