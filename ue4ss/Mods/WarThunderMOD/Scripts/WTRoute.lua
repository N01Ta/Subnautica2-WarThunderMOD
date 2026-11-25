-- Shared runtime curve evaluator. Positions: cm. Speeds: m/s. Time: seconds.
local R = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function checked(v, label, lo, hi)
    assert(finite(v) and v >= lo and v <= hi, label .. ": out of range")
    return v
end
local function vec(x,y,z) return {x=x,y=y,z=z} end
local function add(a,b) return vec(a.x+b.x,a.y+b.y,a.z+b.z) end
local function sub(a,b) return vec(a.x-b.x,a.y-b.y,a.z-b.z) end
local function mul(a,s) return vec(a.x*s,a.y*s,a.z*s) end
local function length(a) return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z) end
local function lerp(a,b,u) return add(mul(a,1-u),mul(b,u)) end
-- Missing links means the original ordered route format. An explicit empty
-- links array means isolated editor points, not an implicit flight path.
function R.edges(route)
    if route.links~=nil then return route.links end
    local links={}
    for i=1,#route.points-1 do links[#links+1]={from=route.points[i].id,to=route.points[i+1].id} end
    return links
end
-- Model ownership follows the connected points, not a generated path index.
-- Deleting the first point or splitting a chain therefore keeps its model.
function R.linePoints(route,pointId)
    local byId,neighbors={},{ }
    for _,p in ipairs(route.points) do byId[p.id]=p;neighbors[p.id]={} end
    assert(byId[pointId],'point not found')
    for _,edge in ipairs(R.edges(route)) do
        assert(byId[edge.from] and byId[edge.to],'link endpoint missing')
        table.insert(neighbors[edge.from],edge.to);table.insert(neighbors[edge.to],edge.from)
    end
    local found,seen,stack={},{},{pointId}
    while #stack>0 do
        local id=table.remove(stack)
        if not seen[id] then
            seen[id]=true;found[#found+1]=byId[id]
            for _,nextId in ipairs(neighbors[id]) do stack[#stack+1]=nextId end
        end
    end
    return found
end
function R.lineModelId(route,points)
    local explicit
    for _,p in ipairs(points) do
        if p.lineModelId then
            assert(not explicit or explicit==p.lineModelId,'connected line has conflicting models')
            explicit=p.lineModelId
        end
    end
    return explicit or route.modelId
end
function R.lineFadeSeconds(route,points)
    local explicit
    for _,p in ipairs(points) do
        if p.lineFadeSeconds~=nil then
            checked(p.lineFadeSeconds,'line fade seconds',0,10)
            assert(explicit==nil or explicit==p.lineFadeSeconds,'connected line has conflicting fade times')
            explicit=p.lineFadeSeconds
        end
    end
    return checked(explicit==nil and (route.fadeSeconds or 0) or explicit,'line fade seconds',0,10)
end
function R.paths(route)
    if route.links==nil then
        if #route.points<2 then return {} end
        local path={};for k,v in pairs(route) do path[k]=v end
        path.modelId=R.lineModelId(route,route.points)
        path.fadeSeconds=R.lineFadeSeconds(route,route.points)
        return {path}
    end
    local byId,outgoing,incoming={},{},{}
    for _,p in ipairs(route.points) do assert(p.id and not byId[p.id],"duplicate point id"); byId[p.id]=p end
    for _,edge in ipairs(route.links) do
        assert(byId[edge.from] and byId[edge.to],"link endpoint missing")
        assert(edge.from~=edge.to,"cannot link point to itself")
        assert(not outgoing[edge.from] and not incoming[edge.to],"flight path cannot branch")
        outgoing[edge.from]=edge.to; incoming[edge.to]=edge.from
    end
    local result,visited={},{}
    for _,p in ipairs(route.points) do
        if outgoing[p.id] and not incoming[p.id] then
            local points,id={},p.id
            while id do
                assert(not visited[id],"flight path cycle")
                visited[id]=true; points[#points+1]=byId[id]; id=outgoing[id]
            end
            result[#result+1]={id=(route.id or "route").."__"..p.id,sourceRouteId=route.id,name=route.name,points=points,
                modelId=R.lineModelId(route,points),fadeSeconds=R.lineFadeSeconds(route,points)}
        end
    end
    for id in pairs(outgoing) do assert(visited[id],"flight path cycle") end
    if #result==1 then result[1].id=route.id end
    return result
end
local function ordered(route)
    if route.links==nil then return route end
    local paths=R.paths(route)
    assert(#paths==1,"route must contain one connected flight path")
    return paths[1]
end
local function tangent(points,i,chord,mode,outgoing)
    local p = points[i]
    local s = p.angleSmoothing == nil and 0.5 or p.angleSmoothing
    checked(s, "angleSmoothing", 0, 5)
    if s == 0 or p.smooth == false or p.interpolationMode == "Linear" then return chord end
    local manual = outgoing and p.tangentOut or p.tangentIn
    if manual then return manual end
    local before = i > 1 and sub(p.location,points[i-1].location) or nil
    local after = i < #points and sub(points[i+1].location,p.location) or nil
    local automatic = before and after and mul(add(before,after),0.5) or before or after or chord
    if mode == "Smooth" then
        local limit = math.min(before and length(before) or math.huge,after and length(after) or math.huge)
        local size = length(automatic)
        if size > limit then automatic = mul(automatic,limit/size) end
    end
    -- Keep the original 0..100% blend. Above 100%, lengthen the common
    -- tangent at an internal point without extrapolating its direction.
    -- Endpoints keep the chord; manual tangents remain explicit overrides.
    if before and after and s>1 then automatic=mul(automatic,s) end
    return lerp(chord,automatic,math.min(s,1))
end

function R.segmentTangents(route,index)
    route=ordered(route)
    local points = assert(route.points,"route.points required")
    assert(index >= 1 and index < #points,"segment index out of range")
    local a,b = points[index],points[index+1]
    local mode = a.curveType or a.interpolationMode or route.curveType or "Smooth"
    assert(mode == "Linear" or mode == "Cubic" or mode == "Smooth","unknown curveType")
    local chord = sub(b.location,a.location)
    if mode == "Linear" then return chord,chord,mode end
    local m0,m1 = tangent(points,index,chord,mode,true),tangent(points,index+1,chord,mode,false)
    return m0,m1,mode
end
function R.segment(route,index,u)
    route=ordered(route)
    checked(u,"u",0,1)
    local m0,m1,mode=R.segmentTangents(route,index)
    local a,b=route.points[index],route.points[index+1]
    if mode == "Linear" then return lerp(a.location,b.location,u),m0 end
    local u2,u3 = u*u,u*u*u
    local p = add(add(mul(a.location,2*u3-3*u2+1),mul(m0,u3-2*u2+u)),
        add(mul(b.location,-2*u3+3*u2),mul(m1,u3-u2)))
    local derivative = add(add(mul(a.location,6*u2-6*u),mul(m0,3*u2-4*u+1)),
        add(mul(b.location,-6*u2+6*u),mul(m1,3*u2-2*u)))
    return p,derivative
end

function R.position(route,t)
    route=ordered(route)
    checked(t,"route parameter",0,1)
    local points = route.points
    if #points == 0 then return nil,vec(0,0,0) end
    if #points == 1 then return points[1].location,vec(0,0,0) end
    local scaled = t*(#points-1)
    local index = math.min(#points-1,math.floor(scaled)+1)
    return R.segment(route,index,scaled-index+1)
end

function R.speed(start,target,u,profile,smoothing)
    checked(start,"start speed",0,1000000)
    checked(target,"target speed",0,1000000)
    checked(u,"speed parameter",0,1)
    smoothing = smoothing == nil and 0.5 or checked(smoothing,"speedSmoothing",0,1)
    profile = profile or "Linear"
    assert(profile == "Instant" or profile == "Linear" or profile == "Exponential","unknown speedProfile")
    if profile == "Instant" or u == 1 then return target end
    if u == 0 then return start end
    local alpha = u
    if profile == "Exponential" then
        -- Normalization makes the destination speed exact at u=1.
        local k = 1+9*smoothing
        alpha = (1-math.exp(-k*u))/(1-math.exp(-k))
    else
        -- The control blends a linear ramp with a zero-acceleration endpoint ramp.
        alpha = u*(1-smoothing)+(3*u*u-2*u*u*u)*smoothing
    end
    return start+(target-start)*alpha
end

-- Build once when the document changes; both the line and the moving unit use
-- these same samples. Distance lookup avoids one equal-duration slot per point.
function R.compile(route,samplesPerSegment)
    if route.links~=nil then route=ordered(route) end
    local n = #route.points
    local count = samplesPerSegment or 64
    assert(count >= 4 and count <= 1024 and count%1 == 0,"sample count out of range")
    local result = {route=route,samples={},lengthCm=0,segmentEnds={}}
    if n == 0 then return result end
    local previous = route.points[1].location
    result.samples[1] = {distance=0,t=0,position=previous}
    for i=1,n-1 do
        for j=1,count do
            local u = j/count
            local p = R.segment(route,i,u)
            result.lengthCm = result.lengthCm+length(sub(p,previous))
            result.samples[#result.samples+1] = {distance=result.lengthCm,
                t=(i-1+u)/(n-1),position=p}
            previous = p
        end
        result.segmentEnds[i]=result.lengthCm
    end
    return result
end

function R.atDistance(compiled,distanceCm)
    assert(finite(distanceCm),"invalid distance")
    local samples = compiled.samples
    if #samples == 0 then return nil,vec(0,0,0) end
    local d = math.max(0,math.min(compiled.lengthCm,distanceCm))
    local lo,hi = 1,#samples
    while lo < hi do
        local mid = math.floor((lo+hi)/2)
        if samples[mid].distance < d then lo=mid+1 else hi=mid end
    end
    local b,a = samples[lo],samples[math.max(1,lo-1)]
    local span = b.distance-a.distance
    local t = span > 1e-9 and a.t+(b.t-a.t)*(d-a.distance)/span or b.t
    return R.position(compiled.route,t)
end

function R.advance(compiled,state,dt,rate)
    checked(dt,"delta time",0,60)
    checked(rate or 1,"preview rate",0.01,20)
    assert(#compiled.route.points >= 2,"playback requires two points")
    local points = compiled.route.points
    local distance = state.distanceCm or 0
    local elapsed = state.segmentSeconds or 0
    local index = state.segmentIndex or 1
    local remaining = dt*(rate or 1)
    local speed = state.speedMps or points[1].targetSpeedMps
    -- Fixed maximum integration step also permits a zero-speed departure:
    -- acceleration progresses with time rather than depending on distance.
    while remaining > 1e-10 do
        local step = math.min(remaining,1/120)
        while index < #points and distance >= compiled.segmentEnds[index]-1e-8 do
            index=index+1; elapsed=0
        end
        if index >= #points then
            speed=points[#points].targetSpeedMps
        else
            local a,b=points[index],points[index+1]
            local segmentLength=compiled.segmentEnds[index]-(compiled.segmentEnds[index-1] or 0)
            local mean=(a.targetSpeedMps+b.targetSpeedMps)*50
            -- Zero is the editor's Auto setting. Instant is a speed profile;
            -- a default zero duration must not silently disable smoothing.
            local duration=b.speedBlendSeconds
            if not duration or duration==0 then duration=mean>1e-8 and segmentLength/mean or 1 end
            checked(duration,"speedBlendSeconds",0,86400)
            elapsed=elapsed+step
            speed=R.speed(a.targetSpeedMps,b.targetSpeedMps,
                duration>0 and math.min(1,elapsed/duration) or 1,b.speedProfile,b.speedSmoothing)
        end
        distance=distance+speed*100*step
        remaining=remaining-step
    end
    local position,derivative = R.atDistance(compiled,distance)
    local directionLength = length(derivative)
    local direction = directionLength > 1e-6 and mul(derivative,1/directionLength)
        or state.forward or vec(1,0,0)
    if distance > compiled.lengthCm then
        position = add(position,mul(direction,distance-compiled.lengthCm))
    end
    return {distanceCm=distance,position=position,forward=direction,speedMps=speed,
        segmentIndex=index,segmentSeconds=elapsed}
end
return R
