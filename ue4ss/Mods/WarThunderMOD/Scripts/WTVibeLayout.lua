-- The placement document is independent of flight scenarios. No UObject is
-- serialized; every transform includes position, rotation and uniform scale.
local J=require('WTScenarioDocument')
local L={};L.__index=L
L.catalog={
    {id='kefir',index=0,label='Кефир',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/kefir/SM_KefirBottle.SM_KefirBottle'},
    {id='radmir',index=1,label='Radmir',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/radmir/SM_Radmir.SM_Radmir'},
    {id='baks_ai',index=2,label='Бакс ИИ',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/baks_ai/SM_BaksAI.SM_BaksAI'},
    {id='baks_full',index=3,label='Бакс фулл',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/baks_full/SM_BaksFull.SM_BaksFull'},
    {id='bulka_v1',index=4,label='Булка v1',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/bulka_v1/SM_BulkaV1.SM_BulkaV1'},
    {id='bulka_v2',index=5,label='Булка v2',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/bulka_v2/SM_BulkaV2.SM_BulkaV2'},
    {id='kefir_games',index=6,label='Кефир Гамес',mesh='/Game/Mods/WarThunderMOD/ModelsFor3D/kefir_games/SM_KefirGames.SM_KefirGames'},
}
local models={};for _,m in ipairs(L.catalog) do models[m.id]=m end
function L.model(id) return models[id] end
function L.modelAt(index)
    if type(index)~='number' or index%1~=0 then return nil end
    return L.catalog[index+1]
end
local function number(v,limit)
    return type(v)=='number' and v==v and math.abs(v)<=limit
end
local function triple(v,limit)
    assert(type(v)=='table','missing transform vector')
    assert(number(v.x,limit) and number(v.y,limit) and number(v.z,limit),'invalid transform vector')
    return {x=v.x,y=v.y,z=v.z}
end
local function item(v)
    assert(type(v)=='table' and type(v.id)=='string' and v.id:match('^prop_%d+$'),'invalid prop id')
    local suffix=v.id:match('%d+$');local n=tonumber(suffix)
    assert(n and n>=1 and n<1e9 and tostring(n)==suffix,'invalid prop id')
    assert(models[v.modelId],'unknown prop model')
    assert(number(v.scale,100) and v.scale>=.01,'scale must be 0.01..100')
    return {id=v.id,modelId=v.modelId,position=triple(v.position,1e8),rotation=triple(v.rotation,1e6),scale=v.scale}
end
function L.new() return setmetatable({props=J.array(),nextId=1,selected=nil,dirty=false},L) end
function L:find(id)
    for i,p in ipairs(self.props) do if p.id==id then return p,i end end
end
function L:add(modelId,position,rotation,scale)
    assert(#self.props<256,'placement limit: 256 models')
    local p=item({id='prop_'..self.nextId,modelId=modelId,position=position,rotation=rotation or {x=0,y=0,z=0},scale=scale or 1})
    self.nextId=self.nextId+1;self.props[#self.props+1]=p;self.selected=p.id;self.dirty=true
    return p
end
function L:select(id)
    assert(id==nil or self:find(id),'unknown selection')
    self.selected=id
end
function L:update(id,position,rotation,scale)
    local old,index=self:find(id);assert(old,'unknown prop')
    local p=item({id=id,modelId=old.modelId,position=position,rotation=rotation,scale=scale})
    self.props[index]=p;self.dirty=true;return p
end
function L:remove(id)
    local _,i=self:find(id);if not i then return false end
    table.remove(self.props,i);if self.selected==id then self.selected=nil end
    self.dirty=true;return true
end
function L:clear() self.props=J.array();self.selected=nil;self.dirty=true end
function L:encode()
    return J.encode({format='WarThunderVibeLayout',version=1,props=self.props})
end
function L.decode(text)
    assert(type(text)=='string' and #text<=1024*1024,'layout exceeds 1 MiB')
    local d,err=J.decode(text);assert(d,err)
    assert(type(d)=='table' and d.format=='WarThunderVibeLayout' and d.version==1,'unsupported layout format')
    assert(type(d.props)=='table' and #d.props<=256,'invalid prop list')
    assert(getmetatable(d.props)==getmetatable(J.array()),'props must be an array')
    local result=L.new();local used={}
    for key in pairs(d.props) do assert(type(key)=='number' and key%1==0 and key>=1 and key<=#d.props,'invalid prop list') end
    for _,v in ipairs(d.props) do
        local p=item(v);assert(not used[p.id],'duplicate prop id');used[p.id]=true
        result.props[#result.props+1]=p
        local n=tonumber(p.id:match('%d+$'));assert(n and n<1e9,'invalid prop id')
        result.nextId=math.max(result.nextId,n+1)
    end
    return result
end
return L
