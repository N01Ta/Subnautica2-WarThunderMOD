local Json = require("WTScenarioDocument")
local Route = require("WTRoute")
local Catalog = require("WTModelCatalog")
local E = {}
E.__index = E
local function copy(v) return assert(Json.decode(Json.encode(v))) end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function dot(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
local function sub(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end
local function add(a,b) return {x=a.x+b.x,y=a.y+b.y,z=a.z+b.z} end
local function mul(a,s) return {x=a.x*s,y=a.y*s,z=a.z*s} end
local function position(p) assert(type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z),"invalid position") end
local function ensureRoutes(document)
    if type(document.routes)~="table" then document.routes=Json.array() end
    if #document.routes==0 then document.routes[1]={id="route_01",name="Маршрут 1",points=Json.array()} end
    for i,route in ipairs(document.routes) do
        route.id=route.id or ("route_"..string.format("%02d",i))
        route.name=route.name or ("Маршрут "..tostring(i))
        route.modelId=route.modelId or Catalog.defaultId
        route.points=route.points or Json.array()
        if #route.points==0 and route.links==nil then route.links=Json.array() end
        Route.paths(route) -- reject malformed explicit links on load
    end
end
function E.new(document)
    local self=setmetatable({document=copy(document),selected={},undoStack={},redoStack={},
        mode="Navigation",gridSnap=false,surfaceSnap=false,throughWorld=false,gridCm=100},E)
    ensureRoutes(self.document)
    self.activeRouteId=self.document.routes[1].id
    self.saved=Json.encode(self.document)
    return self
end
function E:route(id)
    id=id or self.activeRouteId
    for _,route in ipairs(self.document.routes) do if route.id==id then return route end end
end
function E:routeList() return self.document.routes end
function E:setRouteModel(modelId)
    assert(Catalog.get(modelId),'unknown model: '..tostring(modelId))
    return self:mutate(function()
        self:route().modelId=modelId
        for _,point in ipairs(self:points()) do point.lineModelId=modelId end
    end)
end
function E:lineModelId(pointId)
    local p=pointId and self:find(pointId) or self:selectedPoint()
    if not p then return self:route().modelId end
    return Route.lineModelId(self:route(),Route.linePoints(self:route(),p.id)) or Catalog.defaultId
end
function E:setLineModel(modelId)
    assert(Catalog.get(modelId),'unknown model: '..tostring(modelId))
    local p=self:selectedPoint()
    if not p and #self:points()==0 then return self:setRouteModel(modelId) end
    assert(p,'Выберите точку линии, для которой меняете модель')
    return self:mutate(function()
        for _,point in ipairs(Route.linePoints(self:route(),p.id)) do point.lineModelId=modelId end
    end)
end
function E:lineFadeSeconds(pointId)
    local p=pointId and self:find(pointId) or self:selectedPoint()
    return Route.lineFadeSeconds(self:route(),p and Route.linePoints(self:route(),p.id) or {})
end
function E:setLineFadeSeconds(value)
    assert(finite(value) and value>=0 and value<=10,'Фейд линии должен быть от 0 до 10 секунд')
    local p=self:selectedPoint()
    assert(p or #self:points()==0,'Выберите точку линии, для которой меняете фейд')
    return self:mutate(function()
        if not p then self:route().fadeSeconds=value;return end
        for _,point in ipairs(Route.linePoints(self:route(),p.id)) do point.lineFadeSeconds=value end
    end)
end
function E:routeIds()
    local result={}; for _,route in ipairs(self.document.routes) do result[#result+1]=route.id end; return result
end
function E:setActiveRoute(id)
    assert(self:route(id),"route not found")
    if self.activeRouteId==id then return id end
    self.activeRouteId=id; self.selected={}; self.focusedPointId=nil; self.previousPointId=nil; return id
end
function E:points() return self:route().points end
function E:dirty() return Json.encode(self.document) ~= self.saved end
function E:markSaved() self.saved=Json.encode(self.document) end
function E:setMode(mode)
    assert(mode=="Navigation" or mode=="Editing" or mode=="Preview","unknown editor mode")
    if mode=="Preview" then assert(#self:points()>=2,"preview requires two points") end
    self.mode=mode
end
function E:find(id)
    for _,p in ipairs(self:points()) do if p.id==id then return p end end
end
function E:findInRoute(routeId,id)
    local route=self:route(routeId); if not route then return nil end
    for _,p in ipairs(route.points) do if p.id==id then return p end end
end
function E:select(id,extend)
    assert(self:find(id),"point not found")
    local previous=self:selectedPoint()
    if previous and previous.id~=id then self.previousPointId=previous.id end
    if not extend then self.selected={} end
    self.selected[id]=true
    self.focusedPointId=id
end
-- Selection history belongs to the active route, not to the saved document.
-- Repeated grabs/commits of the same point must keep the last distinct pair.
function E:linkSelection()
    local point=self:selectedPoint()
    local source=self.previousPointId and self:find(self.previousPointId)
    if source and point and source.id~=point.id then return source,point end
end
function E:selectedPoint()
    if self.focusedPointId and self.selected[self.focusedPointId] then return self:find(self.focusedPointId) end
    for _,p in ipairs(self:points()) do if self.selected[p.id] then return p end end
end
function E:toggleSelect(id)
    assert(self:find(id),"point not found")
    if not self.selected[id] then self:select(id,true)
    else
        self.selected[id]=nil
        if self.focusedPointId==id then self.focusedPointId=nil; self.previousPointId=nil end
    end
    return self.selected[id]
end
function E:selectAll()
    self.selected={}
    for _,p in ipairs(self:points()) do self.selected[p.id]=true end
    return self.selected
end
function E:selectedPoints()
    local result={}
    for _,p in ipairs(self:points()) do if self.selected[p.id] then result[#result+1]=p end end
    return result
end
function E:mutate(fn)
    assert(self.mode~="Preview","document changes disabled during preview")
    local before=copy(self.document); local selected=copy(self.selected); local active=self.activeRouteId; local focus=self.focusedPointId; local previous=self.previousPointId
    local ok,result=pcall(fn)
    if not ok then self.document=before; self.selected=selected; self.activeRouteId=active; self.focusedPointId=focus; self.previousPointId=previous; error(result,0) end
    if Json.encode(before)~=Json.encode(self.document) then
        self.undoStack[#self.undoStack+1]={document=before,selected=selected,activeRouteId=active,focusedPointId=focus,previousPointId=previous}
        if #self.undoStack>100 then table.remove(self.undoStack,1) end
        self.redoStack={}
    end
    return result
end
function E:nextId()
    local n=1; while self:find("point_"..n) do n=n+1 end; return "point_"..n
end
-- One native Blueprint drag is one document mutation/undo step. IDs are scoped
-- to a route; point_1 can legitimately exist in several routes.
function E:commitWorldPosition(routeId, pointId, target)
    position(target)
    assert(math.abs(target.x)<1e9 and math.abs(target.y)<1e9 and math.abs(target.z)<1e9,"position outside editor bounds")
    assert(self:findInRoute(routeId,pointId),"point not found")
    return self:mutate(function()
        self:setActiveRoute(routeId)
        self:select(pointId)
        self:findInRoute(routeId,pointId).location={x=target.x,y=target.y,z=target.z}
    end)
end
function E:addRoute(id,name)
    return self:mutate(function()
        id=id or ("route_"..string.format("%02d",#self.document.routes+1))
        assert(not self:route(id),"route already exists")
        self.document.routes[#self.document.routes+1]={id=id,name=name or ("Маршрут "..tostring(#self.document.routes+1)),modelId=Catalog.defaultId,points=Json.array(),links=Json.array()}
        self:setActiveRoute(id); return id
    end)
end
function E:removeRoute(id)
    assert(#self.document.routes>1,"scenario must keep one route")
    return self:mutate(function()
        local route,index=self:route(id),nil
        for i,r in ipairs(self.document.routes) do if r.id==id then index=i; break end end
        assert(route and index,"route not found")
        table.remove(self.document.routes,index)
        self.activeRouteId=nil
        self:setActiveRoute(self.document.routes[math.max(1,index-1)].id)
    end)
end
function E:add(camera,forward,distanceCm,connectPrevious)
    position(camera); position(forward); assert(finite(distanceCm) and distanceCm>0,"invalid placement distance")
    local size=math.sqrt(dot(forward,forward)); assert(size>1e-6,"invalid camera direction")
    return self:mutate(function()
        local route=self:route()
        local previous=route.points[#route.points]
        if route.links~=nil or connectPrevious==false then route.links=Json.array(copy(Route.edges(route))) end
        local p={id=self:nextId(),name="Точка "..(#route.points+1),location=add(camera,mul(forward,distanceCm/size)),targetSpeedMps=40,
            angleSmoothing=.5,speedSmoothing=.5,speedBlendSeconds=0,speedProfile="Linear",curveType="Smooth",smooth=true,
            interpolationMode="Smooth",dwell=0,postRouteDuration=0,postRouteDistance=0,fadeInDuration=0,fadeOutDuration=0,collisionMode="Ignore"}
        p.lineModelId=connectPrevious~=false and previous and self:lineModelId(previous.id) or route.modelId
        p.lineFadeSeconds=connectPrevious~=false and previous and self:lineFadeSeconds(previous.id) or (route.fadeSeconds or 0)
        local placementModel=Catalog.get(p.lineModelId)
        if placementModel and placementModel.defaultSpeedMps then p.targetSpeedMps=placementModel.defaultSpeedMps end
        route.points[#route.points+1]=p; self:select(p.id)
        if connectPrevious~=false and previous and route.links then
            local hasNext=false
            for _,edge in ipairs(route.links) do if edge.from==previous.id then hasNext=true end end
            if not hasNext then route.links[#route.links+1]={from=previous.id,to=p.id} end
        end
        return p.id
    end)
end
function E:properties(id,fields)
    return self:mutate(function()
        local p=assert(self:find(id),"point not found")
        for k,v in pairs(fields) do
            if k=="name" then assert(type(v)=="string" and #v>0 and #v<=256,"invalid name")
            elseif k=="targetSpeedMps" then assert(finite(v) and v>=0 and v<=1000000,"invalid speed")
            elseif k=="angleSmoothing" then assert(finite(v) and v>=0 and v<=5,"invalid angle smoothing")
            elseif k=="speedSmoothing" then assert(finite(v) and v>=0 and v<=1,"invalid speed smoothing")
            elseif k=="speedBlendSeconds" or k=="dwell" or k=="postRouteDuration" or k=="postRouteDistance" or k=="fadeInDuration" or k=="fadeOutDuration" then assert(finite(v) and v>=0 and v<=86400,"invalid duration/distance")
            elseif k=="curveType" or k=="interpolationMode" then assert(v=="Linear" or v=="Cubic" or v=="Smooth","invalid curve")
            elseif k=="speedProfile" then assert(v=="Instant" or v=="Linear" or v=="Exponential","invalid profile")
            elseif k=="smooth" then assert(type(v)=="boolean","invalid smooth flag")
            elseif k=="collisionMode" then assert(v=="Avoid" or v=="Ignore","invalid collision mode")
            elseif k=="tangentIn" or k=="tangentOut" then position(v)
            else error("unsupported point property "..tostring(k)) end
            p[k]=v
        end
    end)
end
function E:move(delta,surfaceResolver)
    position(delta)
    return self:mutate(function()
        for _,p in ipairs(self:points()) do if self.selected[p.id] then
            local target=add(p.location,delta)
            if self.gridSnap then
                assert(finite(self.gridCm) and self.gridCm>0,"invalid grid size")
                for _,k in ipairs({"x","y","z"}) do target[k]=math.floor(target[k]/self.gridCm+.5)*self.gridCm end
            end
            if self.surfaceSnap then assert(surfaceResolver,"surface resolver unavailable"); target=assert(surfaceResolver(target)); position(target) end
            p.location=target
        end end
    end)
end
function E:reorder(id,index)
    assert(index%1==0 and index>=1 and index<=#self:points(),"order index out of range")
    return self:mutate(function()
        local p,i=self:find(id),nil; for n,item in ipairs(self:points()) do if item.id==id then i=n; break end end
        assert(p and i,"point not found"); table.remove(self:points(),i); table.insert(self:points(),index,p)
    end)
end
function E:deleteSelected()
    return self:mutate(function()
        local route=self:route(); local links=Json.array()
        for _,edge in ipairs(Route.edges(route)) do
            if not self.selected[edge.from] and not self.selected[edge.to] then links[#links+1]=copy(edge) end
        end
        route.links=links
        for i=#self:points(),1,-1 do if self.selected[self:points()[i].id] then table.remove(self:points(),i) end end
        self.selected={}; self.focusedPointId=nil; self.previousPointId=nil
    end)
end
function E:link(fromId,toId)
    assert(self:find(fromId) and self:find(toId),"point not found")
    assert(fromId~=toId,"cannot link point to itself")
    local sourceModel=self:lineModelId(fromId)
    local sourceFade=self:lineFadeSeconds(fromId)
    return self:mutate(function()
        local route=self:route(); local links=Json.array()
        -- Replacing a connection keeps the other chains intact.
        for _,edge in ipairs(Route.edges(route)) do
            if edge.from~=fromId and edge.to~=toId then links[#links+1]=copy(edge) end
        end
        links[#links+1]={from=fromId,to=toId}
        route.links=links
        -- Joining two lines uses the model of the chosen link source.
        for _,point in ipairs(Route.linePoints(route,fromId)) do point.lineModelId=sourceModel;point.lineFadeSeconds=sourceFade end
        Route.paths(route) -- reject cycles atomically
    end)
end
function E:disconnect(id)
    assert(self:find(id),"point not found")
    return self:mutate(function()
        local route=self:route(); local links=Json.array()
        for _,edge in ipairs(Route.edges(route)) do
            if edge.from~=id and edge.to~=id then links[#links+1]=copy(edge) end
        end
        route.links=links
    end)
end
function E:copySelected()
    local points=Json.array(); for _,p in ipairs(self:points()) do if self.selected[p.id] then points[#points+1]=copy(p) end end; self.clipboard=points
end
function E:paste(offset)
    position(offset)
    return self:mutate(function()
        assert(self.clipboard and #self.clipboard>0,"clipboard is empty"); self.selected={}
        for _,source in ipairs(self.clipboard) do local p=copy(source); p.id=self:nextId(); p.location=add(p.location,offset); self:points()[#self:points()+1]=p; self.selected[p.id]=true end
    end)
end
local function history(self,source,destination)
    assert(self.mode~="Preview","history unavailable in preview"); local snapshot=table.remove(source); if not snapshot then return false end
    destination[#destination+1]={document=copy(self.document),selected=copy(self.selected),activeRouteId=self.activeRouteId,focusedPointId=self.focusedPointId,previousPointId=self.previousPointId}
    self.document=snapshot.document; self.selected=snapshot.selected; self.activeRouteId=snapshot.activeRouteId; self.focusedPointId=snapshot.focusedPointId; self.previousPointId=snapshot.previousPointId; return true
end
function E:undo() return history(self,self.undoStack,self.redoStack) end
function E:redo() return history(self,self.redoStack,self.undoStack) end
function E.axisParameter(origin,direction,anchor,axis)
    local w=sub(origin,anchor); local a,b,c=dot(direction,direction),dot(direction,axis),dot(axis,axis); local denominator=a*c-b*b
    if math.abs(denominator)<1e-8 then return nil,"axis parallel to view" end
    return (a*dot(axis,w)-b*dot(direction,w))/denominator
end
function E:preview(routeId)
    local route=self:route(routeId); assert(route and #route.points>=2,"preview requires two points")
    return Route.compile(route,64)
end
function E:previewAll()
    local result={}; for _,route in ipairs(self.document.routes) do for _,path in ipairs(Route.paths(route)) do result[path.id]=Route.compile(path,64) end end; return result
end
return E
