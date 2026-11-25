local C={defaultId='debug_red_sphere'}
local models={{id='debug_red_sphere',label='Красный шар',
    actorClass='/Game/Mods/WarThunderMOD/BP_WTPlaybackSphere.BP_WTPlaybackSphere_C'},
    {id='wt_po2',label='По-2',
    actorClass='/Game/Mods/WarThunderMOD/Aircraft/Po2/BP_WTPlaybackPo2.BP_WTPlaybackPo2_C'},
    {id='wt_bismarck',label='Бисмарк',defaultSpeedMps=8,
    actorClass='/Game/Mods/WarThunderMOD/Ships/Bismarck/BP_WTPlaybackBismarck.BP_WTPlaybackBismarck_C'}}
function C.list() return models end
function C.get(id)
    id=id or C.defaultId
    for _,model in ipairs(models) do if model.id==id then return model end end
end
function C.byLabel(label)
    for _,model in ipairs(models) do if model.label==label then return model end end
end
return C
