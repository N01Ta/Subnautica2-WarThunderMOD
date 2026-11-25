local Route=require('WTRoute')
local Catalog=require('WTModelCatalog')
local I={}
local profiles={Instant='Мгновенно',Linear='Линейный',Exponential='Экспоненциальный'}
local curves={Linear='Ломаная',Cubic='Кубическая',Smooth='Плавная'}
function I.describe(model)
    if not model then return {details='Редактор не активен',canEdit=false,canLink=false} end
    local route=model:route()
    local point=model:selectedPoint()
    local paths=Route.paths(route)
    local sourcePoint,targetPoint=model:linkSelection()
    local linkHint=sourcePoint and string.format('Связать: %s → %s',sourcePoint.name or sourcePoint.id,targetPoint.name or targetPoint.id)
        or 'Для связи выберите две разные точки по очереди и нажмите «Связать».'
    local selectedModel=Catalog.get(model:lineModelId())
    local header=string.format('%s · точек: %d · линий: %d',route.name or route.id,#route.points,#paths)
    if point then header=header..'\nМодель линии: '..(selectedModel and selectedModel.label or 'Неизвестная модель')..string.format(' · Фейд: %.1f с',model:lineFadeSeconds()) end
    if not point then return {details=header..'\nТочка не выбрана. Выберите стрелку в мире или точку кнопками ниже.\n'..linkHint,canEdit=false,canLink=false} end
    local previous,nextPoint='—','—'
    for _,edge in ipairs(Route.edges(route)) do
        if edge.to==point.id then local p=model:find(edge.from); previous=p and (p.name or p.id) or '—' end
        if edge.from==point.id then local p=model:find(edge.to); nextPoint=p and (p.name or p.id) or '—' end
    end
    local speed=point.targetSpeedMps or 0
    local blend=point.speedBlendSeconds or 0
    local angleNote=(previous=='—' or nextPoint=='—') and ' (край линии: поворота нет)' or ''
    local details=table.concat({header,
        string.format('Выбрана: %s [%s]',point.name or point.id,point.id),
        string.format('Скорость: %.1f м/с (%.0f км/ч) · Сглаживание угла: %.0f%%%s',speed,speed*3.6,(point.angleSmoothing or .5)*100,angleNote),
        string.format('Сглаживание скорости: %.0f%% · Алгоритм: %s',(point.speedSmoothing or .5)*100,profiles[point.speedProfile] or tostring(point.speedProfile)),
        string.format('Кривая: %s · Время перехода: %s',curves[point.curveType] or tostring(point.curveType),blend==0 and 'авто' or string.format('%.1f с',blend)),
        string.format('Связи: %s → %s → %s',previous,point.name or point.id,nextPoint),
        linkHint},'\n')
    return {details=details,canEdit=true,canLink=sourcePoint~=nil}
end
return I
