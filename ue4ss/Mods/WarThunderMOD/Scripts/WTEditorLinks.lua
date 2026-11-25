-- Topology/properties are synced only on document changes. Native link actors
-- read point actor transforms on Tick; no Lua callback participates in dragging.
local Route=require('WTRoute')
local L={}
local modes={Linear=0,Cubic=1,Smooth=2}
local function valid(actor)
    if not actor then return false end
    local ok,result=pcall(function() return actor:IsValid() end)
    return ok and result==true
end
local function vector(v)
    return {X=v and v.x or 0,Y=v and v.y or 0,Z=v and v.z or 0}
end
function L.clear(links)
    local keys={}; for key in pairs(links or {}) do keys[#keys+1]=key end
    for _,key in ipairs(keys) do
        local actor=links[key]
        if valid(actor) then actor.Enabled=false;actor:K2_DestroyActor() end
        links[key]=nil
    end
end
function L.sync(model,pointActors,links,spawn)
    links=links or {}; local live={}
    for _,route in ipairs(model:routeList()) do
        for _,path in ipairs(Route.paths(route)) do
            for i=1,#path.points-1 do
                local a,b=path.points[i],path.points[i+1]
                local first=pointActors[route.id..':'..a.id]
                local last=pointActors[route.id..':'..b.id]
                if valid(first) and valid(last) then
                    local key=route.id..':'..a.id..'->'..b.id
                    local actor=links[key]
                    if not valid(actor) then actor=assert(spawn(key),'live link spawn failed');links[key]=actor end
                    live[key]=true
                    actor.StartPoint=first;actor.EndPoint=last
                    actor.BeforePoint=i>1 and pointActors[route.id..':'..path.points[i-1].id] or nil
                    actor.AfterPoint=i+1<#path.points and pointActors[route.id..':'..path.points[i+2].id] or nil
                    actor.CurveMode=assert(modes[a.curveType or a.interpolationMode or path.curveType or 'Smooth'],'invalid curve mode')
                    actor.StartSmoothing=a.angleSmoothing==nil and .5 or a.angleSmoothing
                    actor.EndSmoothing=b.angleSmoothing==nil and .5 or b.angleSmoothing
                    actor.StartSmooth=a.smooth~=false and a.interpolationMode~='Linear'
                    actor.EndSmooth=b.smooth~=false and b.interpolationMode~='Linear'
                    actor.StartManual=a.tangentOut~=nil;actor.EndManual=b.tangentIn~=nil
                    actor.Manual0=vector(a.tangentOut);actor.Manual1=vector(b.tangentIn)
                    actor.Enabled=true
                    actor:RefreshCurve()
                end
            end
        end
    end
    local stale,keys={},{}
    for key in pairs(links) do if not live[key] then stale[key]=links[key];keys[#keys+1]=key end end
    L.clear(stale)
    for _,key in ipairs(keys) do links[key]=nil end
    return links
end
return L
