-- Lua validates/builds the flight once. Movement, clock and spline queries are
-- native Blueprint Tick; no ExecuteWithDelay or per-frame console round trip.
local R=require('WTRoute')
local Catalog=require('WTModelCatalog')
local P={};P.__index=P
local profiles={Instant=0,Linear=1,Exponential=2}
local function number(v,default,lo,hi,label)
    if v==nil then v=default end
    assert(type(v)=='number' and v==v and v>=lo and v<=hi,label..' outside allowed range')
    return v
end
local function vector(v)
    assert(type(v)=='table','invalid flight vector')
    return {X=number(v.x,nil,-1e9,1e9,'X'),Y=number(v.y,nil,-1e9,1e9,'Y'),Z=number(v.z,nil,-1e9,1e9,'Z')}
end
local function valid(actor) return actor and actor:IsValid() end
function P.new(document,token)
    local playback=document.playback or {}
    local self=setmetatable({state='Ready',token=token,units={},
        rate=number(playback.previewSpeed,1,.01,20,'playback speed'),
        tail=number(playback.postRouteSeconds,2,0,86400,'post route seconds'),
        loop=playback.loop==true},P)
    local plannedIds={}
    for _,route in ipairs(document.routes or {}) do
        assert(Catalog.get(route.modelId),'unknown model: '..tostring(route.modelId))
        for _,path in ipairs(R.paths(route)) do
            local model=assert(Catalog.get(path.modelId),'unknown model: '..tostring(path.modelId))
            assert(type(path.id)=='string' and path.id:match('^[A-Za-z0-9_-]+$'),'invalid flight identifier')
            assert(not plannedIds[path.id],'duplicate flight identifier');plannedIds[path.id]=true
            assert(#path.points<=4096,'flight has too many points')
            local plan={id=path.id,model=model,fadeSeconds=number(path.fadeSeconds,0,0,10,'line fade seconds'),points={}}
            for i,p in ipairs(path.points) do
                plan.points[i]={position=vector(p.location),
                    speed=number(p.targetSpeedMps,40,0,1e6,'point speed'),
                    smooth=number(p.speedSmoothing,.5,0,1,'speed smoothing'),
                    blend=number(p.speedBlendSeconds,0,0,86400,'speed transition'),
                    profile=assert(profiles[p.speedProfile or 'Linear'],'invalid speed profile')}
            end
            for i=1,#path.points-1 do
                local a,b,mode=R.segmentTangents(path,i)
                plan.points[i].leave=vector(a);plan.points[i].linear=mode=='Linear'
                plan.points[i+1].arrive=vector(b)
            end
            plan.points[1].arrive=plan.points[1].leave
            plan.points[#plan.points].leave=plan.points[#plan.points].arrive
            assert(R.compile(path,64).lengthCm>.01,'flight points must have different positions')
            self.units[#self.units+1]=plan
        end
    end
    assert(#self.units>0,'no connected flight path')
    assert(#self.units<=30,'scenario supports at most 30 simultaneous flights')
    return self
end
function P:start(spawn)
    assert(self.state=='Ready','playback is already initialized')
    local ok,err=pcall(function()
        for _,unit in ipairs(self.units) do
            unit.actor=assert(spawn(unit.model),'model spawn failed')
            assert(valid(unit.actor),'model actor is invalid')
            unit.actor:PrepareFlight()
            unit.actor.FadeSeconds=unit.fadeSeconds
            for _,p in ipairs(unit.points) do
                unit.actor:AddFlightPoint(p.position,p.arrive,p.leave,p.linear==true,p.speed,p.smooth,p.blend,p.profile)
            end
        end
        self.state='Playing'
        for _,unit in ipairs(self.units) do
            unit.done=false
            unit.actor:StartFlight(self.token,unit.id,self.rate,unit.fadeSeconds)
            assert(unit.actor.Playing==true,'native flight rejected the route')
        end
    end)
    if not ok then self:_cleanup();self.state='Stopped';return false,tostring(err) end
    return true
end
function P:_cleanup()
    for _,unit in ipairs(self.units) do
        if valid(unit.actor) then unit.actor.Playing=false;unit.actor:K2_DestroyActor() end
        unit.actor=nil
    end
end
function P:canEdit()
    if self.state=='Playing' or self.state=='Paused' then
        for _,unit in ipairs(self.units) do if valid(unit.actor) then return false end end
        -- World teardown destroys native actors. A later menu command must not
        -- leave the next world locked in an old Playing state.
        self.state='Stopped'
    end
    return true
end
function P:pause()
    if self.state~='Playing' then return false,'playback is not running' end
    for _,unit in ipairs(self.units) do if valid(unit.actor) then unit.actor.Paused=true end end
    self.state='Paused';return true
end
function P:resume()
    if self.state~='Paused' then return false,'playback is not paused' end
    for _,unit in ipairs(self.units) do if valid(unit.actor) then unit.actor.Paused=false end end
    self.state='Playing';return true
end
function P:stop()
    if self:canEdit() then return false,'playback is not active' end
    self.state='Stopped';self:_cleanup();return true
end
function P:finished(token,id)
    if token~=self.token or self:canEdit() then return false end
    local found=false
    for _,unit in ipairs(self.units) do if unit.id==id then unit.done=true;found=true end end
    if not found then return false end
    for _,unit in ipairs(self.units) do if not unit.done then return true end end
    if self.loop then
        for _,unit in ipairs(self.units) do
            unit.done=false;unit.actor:StartFlight(self.token,unit.id,self.rate,unit.fadeSeconds)
            unit.actor.Paused=self.state=='Paused'
        end
    else self:stop() end
    return true
end
function P:snapshot()
    local result={state=self.state,registryCount=0,units={}}
    for _,unit in ipairs(self.units) do
        if valid(unit.actor) then
            result.registryCount=result.registryCount+1
            result.units[unit.id]={modelId=unit.model.id,distanceCm=unit.actor.FlightDistance,speedMps=unit.actor.CurrentSpeed,done=unit.done}
        end
    end
    return result
end
return P
