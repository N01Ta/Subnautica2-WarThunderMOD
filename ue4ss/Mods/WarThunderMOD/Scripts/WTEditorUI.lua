-- NotifyOnNewObject runs before UMG has finished constructing the widget tree.
-- Capture only; native Construct/Destruct delimit when a UI may be updated.
local U={}; U.__index=U
local function valid(object)
    if not object then return false end
    local ok,result=pcall(function() return object:IsValid() end)
    return ok and result==true
end
function U.new() return setmetatable({pending={},active={}},U) end
function U:created(kind,widget)
    local pending=self.pending[kind] or {};self.pending[kind]=pending
    for i=#pending,1,-1 do if not valid(pending[i]) then table.remove(pending,i) end end
    pending[#pending+1]=widget
end
function U:ready(kind,name)
    local pending=self.pending[kind] or {}
    for i=#pending,1,-1 do
        local widget=pending[i]
        if valid(widget) then
            local ok,current=pcall(function() return widget:GetFName():ToString() end)
            if ok and current==name then
                self.active[kind]={name=name,widget=widget}
                return widget
            end
        else table.remove(pending,i) end
    end
    local active=self.active[kind]
    if active and active.name==name then return self:get(kind) end
end
function U:closed(kind,name)
    local active=self.active[kind]
    if active and active.name==name then self.active[kind]=nil end
end
function U:get(kind)
    local active=self.active[kind]
    if active and valid(active.widget) then return active.widget end
    self.active[kind]=nil
end
return U
