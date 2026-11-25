-- Called only by the saved-binding dispatcher on the game thread. Native GAS
-- tags drive the game's existing fly ability and collision handling.
local N={};N.__index=N
function N.new(host) return setmetatable({host=host},N) end
local function valid(object) return object and object:IsValid() end
function N.loadClass(find,makeName,log)
    local packageName='/Game/Mods/WarThunderMOD/BP_WTNoclip'
    local assetName='BP_WTNoclip_C'
    local class=find(packageName..'.'..assetName)
    if valid(class) then return class end
    -- A file in the mod chunk is not necessarily a loaded UObject. Mirror
    -- BPModLoader's proven cooked-class loader, rather than StaticLoadObject,
    -- which is not available in every UE4SS host and left this class unloaded.
    local helpers=find('/Script/AssetRegistry.Default__AssetRegistryHelpers')
    if not valid(helpers) or not makeName then return nil,'asset registry helper unavailable' end
    local ok,loaded=pcall(function()
        return helpers:GetAsset({PackageName=makeName(packageName),AssetName=makeName(assetName)})
    end)
    if ok and valid(loaded) then
        if log then log('NOCLIP_CLASS_LOADED | asset-registry | '..packageName) end
        return loaded
    end
    return nil,'BP_WTNoclip class load failed | '..tostring(ok and 'asset not found in mounted mod' or loaded)
end
function N:toggle()
    local h=self.host
    local world,err=h.world()
    if not world then h.log('NOCLIP_REJECT | '..tostring(err));return false end
    local pawn=h.pawn()
    if not valid(pawn) then h.log('NOCLIP_REJECT | no possessed player pawn');return false end
    local driver=self.driver
    -- EndPlay owns teardown. Never carry a pointer or an enabled flag across
    -- world travel or a respawn; inspect the new pawn on the next press.
    if valid(driver) and self.pawnId~=pawn:GetFullName() then
        driver:DisableNoclip();driver:K2_DestroyActor();driver=nil
    end
    if not valid(driver) then
        driver,err=h.spawn(world)
        if not valid(driver) then h.log('NOCLIP_ERROR | '..tostring(err));return false end
        self.driver=driver;self.pawnId=pawn:GetFullName()
    end
    if driver.Enabled then
        driver:DisableNoclip()
        h.log('NOCLIP_DISABLED | '..self.pawnId)
        if h.status then h.status('Ноклип выключен') end
        return true
    end
    -- Blueprint out parameters are not native UFUNCTION return values in
    -- every UE4SS version. Read a public typed property, like playback.Playing.
    driver:RefreshNoclipState(pawn)
    local state=driver.NoclipState
    h.log('NOCLIP_NATIVE_STATE | before='..tostring(state)..' | pawn='..self.pawnId)
    if state~=0 then
        h.log('NOCLIP_REJECT | state='..tostring(state)..' | '..self.pawnId)
        if h.status then h.status(state==1 and 'Ноклип уже включён другим режимом' or 'Ноклип недоступен: персонаж ещё не готов') end
        return false
    end
    -- Success is CPF_OutParm, not CPF_ReturnParm: UE4SS counts it as a
    -- required argument and writes it back into a caller-owned Lua table.
    -- See UE4SS LuaUObject::call_function and the non-struct out-param API.
    local enableResult={}
    driver:EnableNoclip(pawn,enableResult)
    driver:RefreshNoclipState(pawn)
    h.log('NOCLIP_NATIVE_STATE | after='..tostring(driver.NoclipState)..' | enabled='..tostring(driver.Enabled)
        ..' | success='..tostring(enableResult.Success))
    if not driver.Enabled or driver.NoclipState~=1 then
        driver:DisableNoclip()
        h.log('NOCLIP_ERROR | native tags were not applied');return false
    end
    h.log('NOCLIP_ENABLED | '..self.pawnId)
    if h.status then h.status('Ноклип включён — повторное нажатие выключает полёт') end
    return true
end
return N
