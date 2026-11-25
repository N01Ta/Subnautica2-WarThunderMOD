-- Called on the game thread only. Native Blueprint owns picking and drags;
-- Lua owns identity and persistence, never polls mouse input or actor pointers.
local Layout=require('WTVibeLayout')
local R={};R.__index=R
local function valid(a) return a and a:IsValid() end
function R.new(host)
    return setmetatable({host=host,layout=Layout.new(),actors={},modelId='kefir',active=false},R)
end
function R:status(message)
    self.message=message
    if self.host.status then self.host.status(message,self) end
end
function R:world()
    local world,err=self.host.world()
    if not valid(world) then
        self.active=false
        if valid(self.driver) then self.driver.Enabled=false end
        return nil,err or 'Загрузите игровой мир'
    end
    local identity=world:GetFullName()
    if self.worldId and self.worldId~=identity then
        -- Old UObjects belong to a previous world. Do not dereference them.
        self.actors={};self.driver=nil;self.layout=Layout.new();self.active=false
    end
    self.worldId=identity
    return world
end
function R:open()
    local world,err=self:world();if not world then self:status(err);return false end
    local driver=self.driver
    if not valid(driver) then
        driver,err=self.host.controller(world)
        if not valid(driver) then self:status(err or 'Не удалось открыть редактор моделей');return false end
        self.driver=driver
    end
    self.active=true;driver.Enabled=true
    self:status('Выберите модель и добавьте её. Закройте меню для управления в мире.')
    return true
end
function R:finish()
    if valid(self.driver) and self.driver.Dragging then self.driver:FinishDrag() end
end
function R:close()
    self:finish();self.active=false;self.layout:select(nil)
    if valid(self.driver) then self.driver:ClearSelection();self.driver.Enabled=false end
end
function R:setModel(id)
    assert(Layout.model(id),'unknown model');self.modelId=id
end
function R:spawnRecord(world,p)
    local called,a,err=pcall(self.host.spawn,world,p)
    if not called then return nil,a end
    if not valid(a) then return nil,err or 'Не удалось создать модель' end
    local ok,result=pcall(function()
        a.PlacementId=p.id;a.ModelId=p.modelId
        a:SetModel(Layout.model(p.modelId).index)
        a:ApplyPose({X=p.position.x,Y=p.position.y,Z=p.position.z},
            {Roll=p.rotation.x,Pitch=p.rotation.y,Yaw=p.rotation.z},
            {X=p.scale,Y=p.scale,Z=p.scale})
    end)
    if not ok then a:K2_DestroyActor();return nil,result end
    return a
end
function R:spawn()
    local world,err=self:world()
    if not world or not self.active or not valid(self.driver) then self:status(err or 'Сначала откройте «Мир вайба»');return false end
    self:finish()
    -- Camera sampling is native, including when a UMG menu owns the cursor.
    self.driver:CaptureCamera()
    if not self.driver.CameraValid then self:status('Камера ещё не готова');return false end
    local v=self.driver.SpawnPosition
    local previous=self.layout.selected
    local ok,p=pcall(function() return self.layout:add(self.modelId,{x=v.X,y=v.Y,z=v.Z}) end)
    if not ok then self:status(tostring(p));return false end
    local actor;actor,err=self:spawnRecord(world,p)
    if not actor then self.layout:remove(p.id);self.layout:select(previous);self:status(tostring(err));return false end
    self.actors[p.id]=actor;self.driver:SelectProp(actor)
    self:status('Добавлена модель: '..Layout.model(p.modelId).label)
    return true
end
function R:selectActor(name)
    if not self:world() or not self.active then return false end
    if name=='none' then self.layout:select(nil);self:status('Модель не выбрана');return true end
    for id,a in pairs(self.actors) do
        if valid(a) and a:GetFName():ToString()==name then
            self.layout:select(id);self:status('Выбрана '..Layout.model(self.layout:find(id).modelId).label..' — '..id)
            return true
        end
    end
    return false
end
function R:capture()
    self:finish()
    -- Validate every snapshot into a staging document before replacing state.
    local nextLayout=Layout.decode(self.layout:encode())
    nextLayout.selected=self.layout.selected
    for _,p in ipairs(nextLayout.props) do
        local a=self.actors[p.id];assert(valid(a),'Модель недоступна: '..p.id)
        a:CapturePose()
        local v,r,s=a.SnapshotPosition,a.SnapshotRotation,a.SnapshotScale
        assert(math.abs(s.X-s.Y)<.0001 and math.abs(s.X-s.Z)<.0001,'nonuniform model scale')
        nextLayout:update(p.id,{x=v.X,y=v.Y,z=v.Z},{x=r.Roll,y=r.Pitch,z=r.Yaw},s.X)
    end
    self.layout=nextLayout
end
function R:save()
    local world,err=self:world();if not world then self:status(err);return false end
    local ok,result=pcall(function() self:capture();return self.layout:encode() end)
    if not ok then self:status('Не удалось сохранить: '..tostring(result));return false end
    local saved;saved,err=self.host.write(result)
    if not saved then self:status('Не удалось сохранить: '..tostring(err));return false end
    self.layout.dirty=false;self:status('Расстановка сохранена: '..#self.layout.props..' моделей')
    return true
end
function R:destroyActors(actors)
    for _,a in pairs(actors) do if valid(a) then a:K2_DestroyActor() end end
end
function R:load()
    local world,err=self:world();if not world or not self.active then self:status(err or 'Откройте «Мир вайба»');return false end
    self:finish()
    local text;text,err=self.host.read()
    if not text then self:status('Не удалось загрузить: '..tostring(err));return false end
    local ok,document=pcall(Layout.decode,text)
    if not ok then self:status('Файл расстановки повреждён: '..tostring(document));return false end
    -- Stage all actors first. Failed loading leaves the previous scene intact.
    local staged={}
    for _,p in ipairs(document.props) do
        local a;a,err=self:spawnRecord(world,p)
        if not a then self:destroyActors(staged);self:status('Загрузка отменена: '..tostring(err));return false end
        staged[p.id]=a
    end
    if valid(self.driver) then self.driver:ClearSelection() end
    self:destroyActors(self.actors);self.actors=staged;self.layout=document
    self:status('Загружено моделей: '..#document.props)
    return true
end
function R:deleteSelected()
    if not self:world() or not self.active then return false end
    self:finish()
    local id=self.layout.selected
    if not id then self:status('Сначала выберите модель в мире');return false end
    self.driver:ClearSelection()
    local a=self.actors[id];if valid(a) then a:K2_DestroyActor() end
    self.actors[id]=nil;self.layout:remove(id);self:status('Модель удалена');return true
end
function R:clear()
    if not self:world() or not self.active then return false end
    self:finish();self.driver:ClearSelection();self:destroyActors(self.actors)
    self.actors={};self.layout:clear();self:status('Мир очищен от моделей. Сохранённый файл оставлен для восстановления.')
    return true
end
return R
