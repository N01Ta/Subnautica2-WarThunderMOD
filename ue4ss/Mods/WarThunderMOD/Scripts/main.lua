-- WarThunderMOD runtime companion.
-- Owns user files that must live beside the cooked LogicMod payload.
-- The Blueprint mod remains responsible for UI and gameplay; this companion
-- is the only owner of binds.ini/scens persistence.

local ModName = "WarThunderMOD"
local sourceDirectory = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
if sourceDirectory then package.path = sourceDirectory .. "?.lua;" .. package.path end
local ScenarioDocument = require("WTScenarioDocument")
local EditorModel = require("WTEditorModel")
local EditorInspector = require("WTEditorInspector")
local EditorLinks = require("WTEditorLinks")
local EditorUI = require("WTEditorUI").new()
local PlaybackRuntime = require("WTNativePlayback")
local ModelCatalog = require("WTModelCatalog")
local GameplayKeys = require("WTGameplayKeys")
local Noclip = require("WTNoclip")
local VibeLayout = require("WTVibeLayout")
local Vibe = require("WTVibeRuntime").new({})
local PlaybackCommands={}
local function RegisterPlaybackCommand(name,callback)
    PlaybackCommands[name]=callback
    RegisterConsoleCommandHandler(name,callback)
end
local UEHelpers = require("UEHelpers")
local FormatVersion = 1
local RuntimeApiVersion = 1
local ScenarioApiVersion = 1
local MaxScenarioBytes = 2 * 1024 * 1024
local ScenarioPickerResponseName = ".scenario_picker.response"

-- Task 2.1 contract. IDs are stable persistence keys; display text belongs
-- to the UI and must never be used as a binds.ini key.
local BindingSpecs = {
    { Id = "MenuToggle", DefaultKey = "Insert", Description = "Open or close the menu" },
    { Id = "ScenarioStart", DefaultKey = "F6", Description = "Start the selected scenario" },
    { Id = "EditorToggle", DefaultKey = "F7", Description = "Open or close the desktop editor" },
    { Id = "PlaybackPause", DefaultKey = "F8", Description = "Pause or resume playback" },
    { Id = "PlaybackStop", DefaultKey = "F9", Description = "Stop playback" },
    { Id = "NoclipToggle", DefaultKey = "F5", Description = "Toggle noclip and free flight in a loaded world" },
}

local function Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function BuildDefaultBindings()
    local bindings = {}
    for _, spec in ipairs(BindingSpecs) do
        bindings[spec.Id] = spec.DefaultKey
    end
    return bindings
end

local function IsValidBindingValue(value)
    value = Trim(value)
    if value == "" or value == "Escape"
        or value == "Ctrl" or value == "Alt" or value == "Shift" then
        return false
    end
    -- Canonical names produced by the future capture layer: key names,
    -- mouse/wheel names and Ctrl+Alt+Shift combinations.  Mouse button
    -- display names may contain spaces, so spaces are accepted deliberately;
    -- the console save command treats the whole value after '=' as one field.
    return value:match("^[A-Za-z0-9_+%- ]+$") ~= nil
end

local function NormalizeBindingValue(value)
    value = Trim(value)
    local aliases = {
        ["Ins"] = "Insert",
        ["INS"] = "Insert",
        ["Del"] = "Delete",
        ["DEL"] = "Delete",
        ["Control"] = "Ctrl",
        ["CONTROL"] = "Ctrl",
        ["CTRL"] = "Ctrl",
        ["ALT"] = "Alt",
        ["SHIFT"] = "Shift",
        ["MouseWheelUp"] = "MouseScrollUp",
        ["MouseWheelDown"] = "MouseScrollDown",
    }

    local parts = {}
    for part in value:gmatch("[^+]+") do
        local trimmed = Trim(part)
        parts[#parts + 1] = aliases[trimmed] or trimmed
    end
    if #parts == 0 then return value end
    return table.concat(parts, "+")
end

local function FindBindingConflicts(bindings)
    local owners = {}
    for _, spec in ipairs(BindingSpecs) do
        local value = NormalizeBindingValue(bindings and bindings[spec.Id] or "")
        if IsValidBindingValue(value) then
            owners[value] = owners[value] or {}
            owners[value][#owners[value] + 1] = spec.Id
        end
    end

    local conflicts = {}
    for value, actions in pairs(owners) do
        if #actions > 1 then
            table.sort(actions)
            conflicts[#conflicts + 1] = {
                Value = value,
                Actions = actions,
            }
        end
    end
    table.sort(conflicts, function(left, right)
        return left.Value < right.Value
    end)
    return conflicts
end

local function FormatBindingConflict(conflict)
    return tostring(conflict.Value) .. " used by " .. table.concat(conflict.Actions, ", ")
end

local function BindingConflictPrompt(conflict)
    local owner = conflict and conflict.Actions and conflict.Actions[1] or "другое действие"
    return "Клавиша уже используется для " .. tostring(owner) .. ". Заменить старый bind?"
end

local function ValidateBindingSet(bindings)
    local issues = {}
    for _, spec in ipairs(BindingSpecs) do
        local value = NormalizeBindingValue(bindings and bindings[spec.Id] or "")
        if not IsValidBindingValue(value) then
            issues[#issues + 1] = spec.Id .. ": invalid value"
        end
    end
    local conflicts = FindBindingConflicts(bindings)
    for _, conflict in ipairs(conflicts) do
        issues[#issues + 1] = "conflict: " .. FormatBindingConflict(conflict)
    end
    return #issues == 0, issues, conflicts
end

local function ParseBindings(content)
    local bindings = BuildDefaultBindings()
    local seen = {}
    local issues = {}
    local section = ""
    local formatVersion = 0
    local hasFormatVersion = false

    local lineNumber = 0
    for line in (content or ""):gmatch("[^\r\n]+") do
        lineNumber = lineNumber + 1
        local text = Trim(line)
        if text ~= "" and not text:match("^;") and not text:match("^#") then
            local sectionName = text:match("^%[([^%]]+)%]$")
            if sectionName then
                section = Trim(sectionName)
            else
                local key, value = text:match("^([^=]+)=(.*)$")
                if not key then
                    table.insert(issues, "line " .. tostring(lineNumber) .. ": malformed entry")
                else
                    key = Trim(key)
                    value = Trim(value)
                    if section == "Bindings" then
                        local known = false
                        for _, spec in ipairs(BindingSpecs) do
                            if spec.Id == key then
                                known = true
                                seen[key] = true
                                local normalizedValue = NormalizeBindingValue(value)
                                if IsValidBindingValue(normalizedValue) then
                                    bindings[key] = normalizedValue
                                else
                                    table.insert(issues, key .. ": invalid value; default retained")
                                end
                                break
                            end
                        end
                        if not known then
                            table.insert(issues, key .. ": unknown action ID ignored")
                        end
                    elseif section == "Meta" and key == "FormatVersion" then
                        local parsedVersion = tonumber(value)
                        if parsedVersion then
                            formatVersion = parsedVersion
                            hasFormatVersion = true
                        else
                            table.insert(issues, "Meta.FormatVersion: invalid value; migration required")
                        end
                    end
                end
            end
        end
    end

    local needsMigration = not hasFormatVersion or formatVersion < FormatVersion
    -- Add newly introduced actions without resetting existing assignments or
    -- changing the on-disk format understood by the menu loader.
    for _, spec in ipairs(BindingSpecs) do
        if not seen[spec.Id] then needsMigration = true end
    end
    if not seen.NoclipToggle then
        local used = {}
        for id, value in pairs(bindings) do if id ~= 'NoclipToggle' then used[value] = true end end
        if used[bindings.NoclipToggle] then
            local candidates={'Ctrl+F5','Alt+F5','Shift+F5','Ctrl+Alt+F5'}
            for key=10,24 do candidates[#candidates+1]='F'..key end
            for _, candidate in ipairs(candidates) do
                if not used[candidate] then bindings.NoclipToggle=candidate;break end
            end
        end
    end
    if formatVersion > FormatVersion then
        table.insert(issues, "Meta.FormatVersion: newer format is not rewritten")
        needsMigration = false
    end
    return bindings, issues, formatVersion, needsMigration
end

local function Log(message)
    print("[WarThunderMOD] " .. tostring(message) .. "\n")
end

local function NormalizePath(path)
    if not path then return nil end
    return tostring(path):gsub("/", "\\")
end

local function JoinPath(left, right)
    left = NormalizePath(left)
    right = NormalizePath(right)
    if not left or not right then return nil end
    if left:sub(-1) == "\\" then return left .. right end
    return left .. "\\" .. right
end

local function QuoteWindowsPath(path)
    -- A discovered Windows path cannot contain a double quote. Keep the
    -- command quoted so spaces in Steam library paths are safe.
    return '"' .. tostring(path):gsub('"', '""') .. '"'
end

local function CommandSucceeded(result)
    return result == true or result == 0
end

local function EnsureDirectory(path)
    if not path or path == "" then
        return false, "empty directory path"
    end

    -- UE4SS exposes Lua's standard os/io libraries. mkdir is only used for
    -- the user-data directory; all user-controlled filenames are validated
    -- before reaching this function.
    local command = "if not exist " .. QuoteWindowsPath(path)
        .. " mkdir " .. QuoteWindowsPath(path)
    local ok, reason, code = os.execute(command)
    if CommandSucceeded(ok) or code == 0 then
        return true
    end
    return false, string.format("mkdir failed (%s, %s)", tostring(reason), tostring(code))
end

local function ResolveModRoot()
    local dirs = IterateGameDirectories()
    if not dirs or not dirs.Game then
        return nil, "IterateGameDirectories returned no Game entry"
    end

    local logicMods = dirs.Game.Content
        and dirs.Game.Content.Paks
        and dirs.Game.Content.Paks.LogicMods
    if not logicMods then
        return nil, "Content/Paks/LogicMods was not found"
    end

    local modDirectory = logicMods[ModName]
    if modDirectory and modDirectory.__absolute_path then
        return NormalizePath(modDirectory.__absolute_path)
    end

    if logicMods.__absolute_path then
        return JoinPath(logicMods.__absolute_path, ModName)
    end

    return nil, "WarThunderMOD directory was not found under LogicMods"
end

local function FileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function ReadText(path)
    local file, errorText = io.open(path, "rb")
    if not file then return nil, errorText or "open failed" end
    local content, readError = file:read("*a")
    file:close()
    if not content then return nil, readError or "read failed" end
    return content
end

local function IsSafeScenarioFileName(fileName)
    if type(fileName) ~= "string" then return false end
    -- Scenario names are deliberately narrow: English letters, digits,
    -- underscore and dash, followed by the only supported extension.
    return fileName:match("^[A-Za-z0-9_-]+%.json$") ~= nil
end

local function ResolveScenarioPath(scens, fileName)
    if not IsSafeScenarioFileName(fileName) then
        return nil, "scenario filename must match [A-Za-z0-9_-]+.json"
    end
    return JoinPath(scens, fileName)
end

local function WriteTextAtomic(path, content)
    local temporary = path .. ".tmp"
    local backup = path .. ".bak"

    local file, errorText = io.open(temporary, "wb")
    if not file then return false, errorText or "temporary open failed" end

    local writeOk, writeError = file:write(content)
    local closeOk, closeError = file:close()
    if not writeOk or not closeOk then
        os.remove(temporary)
        return false, writeError or closeError or "temporary write failed"
    end

    if FileExists(path) then
        os.remove(backup)
        local moved, moveError = os.rename(path, backup)
        if not moved then
            os.remove(temporary)
            return false, moveError or "backup rename failed"
        end
    end

    local renamed, renameError = os.rename(temporary, path)
    if not renamed then
        if FileExists(backup) then os.rename(backup, path) end
        os.remove(temporary)
        return false, renameError or "atomic rename failed"
    end

    os.remove(backup)
    return true
end

local function ValidateScenarioEnvelope(content)
    if type(content) ~= "string" or #content == 0 then
        return false, "scenario content is empty"
    end
    if #content > MaxScenarioBytes then
        return false, "scenario content exceeds 2 MiB"
    end
    -- Full schema validation is owned by the scenario manager.  The runtime
    -- bridge still rejects obvious non-JSON or wrong-version payloads before
    -- touching user data, so a UI failure cannot create an arbitrary file.
    if not content:match("^%s*{") or not content:match("}%s*$") then
        return false, "scenario content must be a JSON object"
    end
    if not content:match('"formatVersion"%s*:%s*1') then
        return false, "scenario formatVersion 1 is required"
    end
    for _, field in ipairs({ "id", "displayName", "groups", "routes", "playback" }) do
        if not content:match('"' .. field .. '"%s*:') then
            return false, "scenario field is missing: " .. field
        end
    end
    return true
end

local function ListScenarioFiles(scens)
    local files = {}
    local pattern = JoinPath(scens, "*.json")
    if not pattern or not io.popen then
        return files, "directory enumeration is unavailable"
    end

    local pipe = io.popen("dir /b /a-d " .. QuoteWindowsPath(pattern) .. " 2>nul", "r")
    if not pipe then
        return files, "scenario directory enumeration failed"
    end
    for line in pipe:lines() do
        local fileName = Trim(line)
        if IsSafeScenarioFileName(fileName) then
            files[#files + 1] = fileName
        end
    end
    pipe:close()
    table.sort(files)
    return files
end

local function ReadScenarioText(fileName)
    if not WTModRuntime then return nil, "runtime companion is not initialized" end
    local path, pathError = ResolveScenarioPath(WTModRuntime.Scens, fileName)
    if not path then return nil, pathError end
    return ReadText(path)
end

local function WriteScenarioText(fileName, content)
    if not WTModRuntime then return false, "runtime companion is not initialized" end
    local path, pathError = ResolveScenarioPath(WTModRuntime.Scens, fileName)
    if not path then return false, pathError end
    local valid, validationError = ValidateScenarioEnvelope(content)
    if not valid then return false, validationError end
    return WriteTextAtomic(path, content)
end

local function DeleteScenarioFile(fileName)
    if not WTModRuntime then return false, "runtime companion is not initialized" end
    local path, pathError = ResolveScenarioPath(WTModRuntime.Scens, fileName)
    if not path then return false, pathError end
    if not FileExists(path) then return false, "scenario file does not exist" end
    local removed, removeError = os.remove(path)
    if not removed then return false, removeError or "scenario delete failed" end
    return true
end

local function InvokeScenarioPicker(callback)
    if not WTModRuntime then return false, "runtime companion is not initialized" end
    if WTModRuntime.ScenarioPickerPending then
        return false, "scenario picker is already open"
    end
    if type(callback) ~= "function" then
        return false, "scenario picker callback is required"
    end

    local helper = WTModRuntime.ScenarioPickerHelper
    if not helper or not FileExists(helper) then
        return false, "ScenarioPickerBridge.ps1 is missing beside the mod payload"
    end

    local response = JoinPath(WTModRuntime.Scens, ScenarioPickerResponseName)
    os.remove(response)
    local command = 'start "" /b powershell.exe -NoProfile -STA -WindowStyle Hidden'
        .. ' -ExecutionPolicy Bypass -File ' .. QuoteWindowsPath(helper)
        .. ' -Mode PickScenario -ScensDirectory ' .. QuoteWindowsPath(WTModRuntime.Scens)
        .. ' -ResponseFile ' .. QuoteWindowsPath(response)
    local result, reason, code = os.execute(command)
    if not CommandSucceeded(result) and code ~= 0 then
        return false, string.format("scenario picker launch failed (%s, %s)", tostring(reason), tostring(code))
    end

    local requestToken = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    WTModRuntime.ScenarioPickerPending = requestToken
    local pollCount = 0
    Log("SCENARIO_PICKER_STARTED | token=" .. requestToken)

    local function PollPickerResponse()
        if not WTModRuntime or WTModRuntime.ScenarioPickerPending ~= requestToken then
            return
        end
        local responseText = ReadText(response)
        if not responseText then
            pollCount = pollCount + 1
            if pollCount >= 3600 then
                WTModRuntime.ScenarioPickerPending = nil
                os.remove(response)
                local callbackOk, callbackError = pcall(callback, "error", nil, nil,
                    "scenario picker timed out after 15 minutes")
                if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
                Log("SCENARIO_PICKER_TIMEOUT | token=" .. requestToken)
                return
            end
            ExecuteWithDelay(250, PollPickerResponse)
            return
        end

        WTModRuntime.ScenarioPickerPending = nil
        os.remove(response)
        local status = responseText:match("status=([^\r\n]+)") or "error"
        local fileName = responseText:match("filename=([^\r\n]*)") or ""
        if status == "selected" then
            if not IsSafeScenarioFileName(fileName) then
                status = "rejected"
                local callbackOk, callbackError = pcall(callback, status, nil, nil,
                    "selected filename is outside the scenario allowlist")
                if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
            else
                local content, readError = ReadScenarioText(fileName)
                if content then
                    WTModRuntime.LastSelectedScenario = fileName
                    local callbackOk, callbackError = pcall(callback, "selected", fileName, content)
                    if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
                else
                    local callbackOk, callbackError = pcall(callback, "error", nil, nil, readError)
                    if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
                end
            end
        elseif status == "cancelled" then
            local callbackOk, callbackError = pcall(callback, "cancelled")
            if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
        elseif status == "rejected" then
            local callbackOk, callbackError = pcall(callback, "rejected", nil, nil,
                "selected file must be inside scens and use an English .json filename")
            if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
        else
            local callbackOk, callbackError = pcall(callback, "error", nil, nil,
                "scenario picker helper returned an error")
            if not callbackOk then Log("SCENARIO_PICKER_CALLBACK_ERROR | " .. tostring(callbackError)) end
        end
        Log("SCENARIO_PICKER_COMPLETE | status=" .. status .. " | file=" .. tostring(fileName))
    end

    ExecuteWithDelay(250, PollPickerResponse)
    return true
end

local function OpenScensFolder()
    if not WTModRuntime then return false, "runtime companion is not initialized" end
    local helper = WTModRuntime.ScenarioPickerHelper
    if not helper or not FileExists(helper) then
        return false, "ScenarioPickerBridge.ps1 is missing beside the mod payload"
    end
    local command = 'start "" /b powershell.exe -NoProfile -STA -WindowStyle Hidden'
        .. ' -ExecutionPolicy Bypass -File ' .. QuoteWindowsPath(helper)
        .. ' -Mode OpenScens -ScensDirectory ' .. QuoteWindowsPath(WTModRuntime.Scens)
    local result, reason, code = os.execute(command)
    if not CommandSucceeded(result) and code ~= 0 then
        return false, string.format("Explorer launch failed (%s, %s)", tostring(reason), tostring(code))
    end
    Log("SCENS_FOLDER_OPEN_REQUESTED")
    return true
end

local function DefaultBindsIni()
    local lines = { "[Bindings]" }
    for _, spec in ipairs(BindingSpecs) do
        table.insert(lines, spec.Id .. "=" .. spec.DefaultKey)
    end
    table.insert(lines, "")
    table.insert(lines, "[Meta]")
    table.insert(lines, "FormatVersion=" .. tostring(FormatVersion))
    table.insert(lines, "")
    return table.concat(lines, "\r\n")
end

local function SerializeBindings(bindings)
    local lines = { "[Bindings]" }
    for _, spec in ipairs(BindingSpecs) do
        local value = bindings[spec.Id] or spec.DefaultKey
        table.insert(lines, spec.Id .. "=" .. value)
    end
    table.insert(lines, "")
    table.insert(lines, "[Meta]")
    table.insert(lines, "FormatVersion=" .. tostring(FormatVersion))
    table.insert(lines, "")
    return table.concat(lines, "\r\n")
end

local function SaveBindingSet(bindings, allowConflicts)
    if not WTModRuntime then
        return false, "runtime companion is not initialized"
    end

    local canonical = {}
    for _, spec in ipairs(BindingSpecs) do
        canonical[spec.Id] = NormalizeBindingValue(bindings and bindings[spec.Id] or "")
    end
    local valid, issues, conflicts = ValidateBindingSet(canonical)
    if not valid then
        local blockingIssues = {}
        for _, issue in ipairs(issues) do
            if not tostring(issue):match("^conflict:") then
                blockingIssues[#blockingIssues + 1] = issue
            end
        end
        if #blockingIssues > 0 or (#conflicts > 0 and not allowConflicts) then
            return false, table.concat(issues, " | "), issues, conflicts
        end
    end

    local content = SerializeBindings(canonical)
    local saved, saveError = WriteTextAtomic(WTModRuntime.Binds, content)
    if not saved then
        return false, saveError or "binds.ini write failed"
    end

    local parsed, parsedIssues, version = ParseBindings(content)
    local parsedConflicts = FindBindingConflicts(parsed)
    for _, conflict in ipairs(parsedConflicts) do
        parsedIssues[#parsedIssues + 1] = "conflict: " .. FormatBindingConflict(conflict)
    end
    WTModRuntime.Bindings = parsed
    GameplayKeys.refresh(parsed)
    WTModRuntime.BindingIssues = parsedIssues
    WTModRuntime.BindingCount = #BindingSpecs
    WTModRuntime.BindingsFormatVersion = version
    WTModRuntime.BindsText = content
    return true, nil, nil, conflicts
end

local function SaveBindingValues(menuToggle, scenarioStart)
    if not WTModRuntime then
        return false, "runtime companion is not initialized"
    end

    menuToggle = NormalizeBindingValue(menuToggle)
    scenarioStart = NormalizeBindingValue(scenarioStart)
    if not IsValidBindingValue(menuToggle) then
        return false, "MenuToggle has an invalid value"
    end
    if not IsValidBindingValue(scenarioStart) then
        return false, "ScenarioStart has an invalid value"
    end

    local bindings = {}
    for _, spec in ipairs(BindingSpecs) do
        bindings[spec.Id] = WTModRuntime.Bindings[spec.Id] or spec.DefaultKey
    end
    bindings.MenuToggle = menuToggle
    bindings.ScenarioStart = scenarioStart
    return SaveBindingSet(bindings)
end

local function ParseBindingSaveCommand(raw)
    local values = {}
    -- Unreal's console splits commands at '|'; the cooked UI uses '~'.
    -- Retain pipe support for direct API callers and older tools.
    local text = Trim(raw):gsub("~", "|")
    if text == "" then
        return nil, "empty binding command"
    end

    -- New format uses a pipe between fields so mouse display names may safely
    -- contain spaces.  The old two-field command remains accepted for the
    -- already cooked Blueprint until its next UI revision.
    if text:find("|", 1, true) then
        for field in text:gmatch("[^|]+") do
            local key, value = field:match("^%s*([^=]+)=(.-)%s*$")
            if not key or not value then
                return nil, "malformed binding field"
            end
            values[Trim(key)] = NormalizeBindingValue(value)
        end
    else
        local menuToggle, scenarioStart = text
            :match("^MenuToggle=(.-)%s+ScenarioStart=(.+)$")
        if menuToggle and scenarioStart then
            values.MenuToggle = NormalizeBindingValue(menuToggle)
            values.ScenarioStart = NormalizeBindingValue(scenarioStart)
        else
            -- Older cooked bindings widgets sent only the row that changed.
            -- Merge that single action with the current runtime set instead
            -- of rejecting the save before conflict validation.
            local key, value = text:match("^([A-Za-z][A-Za-z0-9_]*)=(.+)$")
            if not key or not value then
                return nil, "expected pipe-delimited fields or a binding field"
            end
            values[Trim(key)] = NormalizeBindingValue(value)
        end
    end
    return values
end

local RouteEvaluator = require("WTRoute")
local EvaluateRoutePosition = RouteEvaluator.position
local EvaluateRouteSpeed = RouteEvaluator.speed

local function Initialize()
    local root, rootError = ResolveModRoot()
    if not root then
        Log("RUNTIME_ERROR | " .. tostring(rootError))
        return false, rootError
    end

    local scens = JoinPath(root, "scens")
    local binds = JoinPath(root, "binds.ini")
    local ok, directoryError = EnsureDirectory(scens)
    if not ok then
        Log("RUNTIME_ERROR | scens | " .. tostring(directoryError))
        return false, directoryError
    end

    if not FileExists(binds) then
        local saved, saveError = WriteTextAtomic(binds, DefaultBindsIni())
        if not saved then
            Log("RUNTIME_ERROR | binds.ini | " .. tostring(saveError))
            return false, saveError
        end
        Log("RUNTIME_DEFAULTS | binds.ini created")
    end

    local content, readError = ReadText(binds)
    if not content then
        Log("RUNTIME_ERROR | binds.ini read | " .. tostring(readError))
        return false, readError
    end

    local bindings, bindingIssues, bindingsFormatVersion, needsMigration = ParseBindings(content)
    for _, issue in ipairs(bindingIssues) do
        Log("BINDING_WARNING | " .. issue)
    end
    local startupConflicts = FindBindingConflicts(bindings)
    for _, conflict in ipairs(startupConflicts) do
        local issue = "conflict: " .. FormatBindingConflict(conflict)
        table.insert(bindingIssues, issue)
        Log("BINDING_WARNING | " .. issue)
    end
    if #startupConflicts > 0 then
        -- Do not rewrite a conflicted legacy file during migration. The user
        -- must resolve ownership in the bindings UI before any replacement.
        needsMigration = false
    end

    local migrationCompleted = false
    local originalFormatVersion = bindingsFormatVersion
    if needsMigration then
        local migratedContent = SerializeBindings(bindings)
        local migrated, migrationError = WriteTextAtomic(binds, migratedContent)
        if migrated then
            content = migratedContent
            bindingsFormatVersion = FormatVersion
            migrationCompleted = true
            Log("BINDINGS_MIGRATED | from=" .. tostring(originalFormatVersion)
                .. " | to=" .. tostring(FormatVersion))
        else
            table.insert(bindingIssues, "migration failed: " .. tostring(migrationError))
            Log("BINDING_WARNING | migration failed: " .. tostring(migrationError))
        end
    end

    local bindingCount = 0
    for _, spec in ipairs(BindingSpecs) do
        if bindings[spec.Id] then bindingCount = bindingCount + 1 end
    end

    WTModRuntime = {
        ApiVersion = RuntimeApiVersion,
        BindingSpecs = BindingSpecs,
        Root = root,
        Scens = scens,
        Binds = binds,
        BindsText = content,
        Bindings = bindings,
        BindingIssues = bindingIssues,
        BindingCount = bindingCount,
        Playback = nil,
        PlaybackActors = {},
        PlaybackToken = nil,
        BindingsFormatVersion = bindingsFormatVersion,
        BindingsMigrated = migrationCompleted,
        FormatVersion = FormatVersion,
        Paths = {
            Root = root,
            Scens = scens,
            Binds = binds,
        },
        GetPath = function(kind)
            if kind == "Root" then return root end
            if kind == "Scens" then return scens end
            if kind == "Binds" then return binds end
            return nil, "unknown runtime path kind"
        end,
        ReadText = ReadText,
        WriteTextAtomic = WriteTextAtomic,
        ReadBinds = function()
            return ReadText(binds)
        end,
        ParseBinds = ParseBindings,
        ReadValidatedBinds = function()
            local text, errorText = ReadText(binds)
            if not text then return nil, errorText end
            local values, issues, version, migration = ParseBindings(text)
            return values, issues, version, migration
        end,
        WriteBinds = function(value)
            if type(value) ~= "string" then
                return false, "binds content must be text"
            end
            return WriteTextAtomic(binds, value)
        end,
        ResolveScenarioPath = function(fileName)
            return ResolveScenarioPath(scens, fileName)
        end,
        ScenarioApiVersion = ScenarioApiVersion,
        MaxScenarioBytes = MaxScenarioBytes,
        ScenarioPickerHelper = JoinPath(root, "ScenarioPickerBridge.ps1"),
        ListScenarioFiles = function()
            return ListScenarioFiles(scens)
        end,
        ReadScenarioText = ReadScenarioText,
        WriteScenarioText = WriteScenarioText,
        DeleteScenarioFile = DeleteScenarioFile,
        ValidateScenarioEnvelope = ValidateScenarioEnvelope,
        RequestScenarioPicker = InvokeScenarioPicker,
        OpenScensFolder = OpenScensFolder,
        FindBindingConflicts = FindBindingConflicts,
        BindingConflictPrompt = BindingConflictPrompt,
        ValidateBindingSet = ValidateBindingSet,
        SaveBindingSet = SaveBindingSet,
        SaveBindingValues = SaveBindingValues,
        ParseBindingSaveCommand = ParseBindingSaveCommand,
        SerializeBindings = SerializeBindings,
        RouteEvaluator = RouteEvaluator,
        CreateEditorModel = EditorModel.new,
        EvaluateRoutePosition = EvaluateRoutePosition,
        EvaluateRouteSpeed = EvaluateRouteSpeed,
    }

    Log("RUNTIME_API_READY | version=" .. tostring(RuntimeApiVersion))
    Log("BINDINGS_READY | count=" .. tostring(bindingCount)
        .. " | issues=" .. tostring(#bindingIssues)
        .. " | format=" .. tostring(bindingsFormatVersion))
    Log("RUNTIME_READY | root=" .. root)
    Log("RUNTIME_READY | scens=" .. scens)
    Log("RUNTIME_READY | binds=" .. binds)
    return true
end

Initialize()

local function SetBindingConflictText(target, text)
    if not target then return false end
    local ok, errorText = pcall(function()
        if target:IsValid() then
            target:SetText(FText(tostring(text or "")))
        end
    end)
    if not ok then
        Log("BINDING_CONFLICT_TEXT_ERROR | " .. tostring(errorText))
    end
    return ok
end

local function SetBindingConflictVisibility(target, visible)
    if not target then return false end
    local ok = pcall(function()
        if target:IsValid() then
            target:SetVisibility(visible and ESlateVisibility.Visible or ESlateVisibility.Collapsed)
        end
    end)
    if ok then return true end

    -- Some UE4SS builds expose UWidget::SetVisibility but do not expose the
    -- ESlateVisibility enum table to Lua.  The underlying enum values are
    -- stable in UE5: Visible=0, Collapsed=2. Keep this fallback isolated so
    -- a missing enum cannot prevent the binding command handlers from loading.
    local fallbackOk, fallbackError = pcall(function()
        if target:IsValid() then
            target:SetVisibility(visible and 0 or 2)
        end
    end)
    if not fallbackOk then
        Log("BINDING_CONFLICT_VISIBILITY_ERROR | " .. tostring(fallbackError))
    end
    return fallbackOk
end

-- The widget instance delivered by NotifyOnNewObject is authoritative.  In
-- cooked sessions FindAllOf may not enumerate an already-created UserWidget,
-- which previously made the conflict command fail visually even though the
-- runtime had detected the duplicate bind.
local function GetBindingWidgets()
    local widgets = {}
    local seen = {}
    local function add(widget)
        if not widget then return end
        local ok, valid = pcall(function() return widget:IsValid() end)
        if not ok or not valid then return end
        local key = tostring(widget)
        if seen[key] then return end
        seen[key] = true
        widgets[#widgets + 1] = widget
    end

    if WTModRuntime then add(WTModRuntime.BindingWidget) end
    if FindAllOf then
        local ok, found = pcall(FindAllOf, "WBP_WarThunderBindings_C")
        if ok and found then
            for _, widget in pairs(found) do add(widget) end
        end
    end
    return widgets
end

local BindingActionDisplayNames = {
    MenuToggle = "открытия/закрытия меню",
    ScenarioStart = "запуска сценария",
    EditorToggle = "режима редактирования",
    PlaybackPause = "паузы сценария",
    PlaybackStop = "остановки сценария",
    NoclipToggle = "ноклипа / свободного полёта",
}

local function ConflictPromptText(conflicts)
    local first = conflicts and conflicts[1]
    if not first then
        return "Клавиша уже используется для другого действия. Заменить старый bind?"
    end
    local owners = {}
    for _, conflict in ipairs(conflicts) do
        local foundOwner = false
        if WTModRuntime and WTModRuntime.Bindings then
            for _, action in ipairs(conflict.Actions or {}) do
                local existing = NormalizeBindingValue(WTModRuntime.Bindings[action] or "")
                if existing == conflict.Value then
                    owners[#owners + 1] = BindingActionDisplayNames[action] or action
                    foundOwner = true
                end
            end
        end
        if not foundOwner then
            local action = (conflict.Actions or {})[1]
            owners[#owners + 1] = BindingActionDisplayNames[action] or action or "другое действие"
        end
    end
    return "Клавиша уже используется для " .. table.concat(owners, ", ")
        .. ". Заменить старый bind?"
end

local function HideBindingConflictPrompt()
    local shown = false
    for _, widget in pairs(GetBindingWidgets()) do
        if widget and widget:IsValid() then
            local dialog = widget.BindingConflictDialog
            if dialog then
                SetBindingConflictVisibility(dialog, false)
                shown = true
            end
        end
    end
    return shown
end

local function ClearBindingConflictPrompt()
    if WTModRuntime then
        WTModRuntime.PendingBindingSet = nil
        WTModRuntime.PendingBindingConflicts = nil
    end
    HideBindingConflictPrompt()
end

local function ShowBindingConflictPrompt(conflicts, bindings)
    if not WTModRuntime then return false end
    WTModRuntime.PendingBindingSet = bindings
    WTModRuntime.PendingBindingConflicts = conflicts or {}
    local message = ConflictPromptText(conflicts or {})
    local shown = false
    for _, widget in pairs(GetBindingWidgets()) do
        if widget and widget:IsValid() then
            SetBindingConflictText(widget.BindingConflictTitle, "Конфликт бинда")
            SetBindingConflictText(widget.BindingConflictMessage, message)
            SetBindingConflictText(widget.BindingConflictConfirmText, "Заменить")
            SetBindingConflictText(widget.BindingConflictCancelText, "Отмена")
            if widget.BindingConflictDialog then
                SetBindingConflictVisibility(widget.BindingConflictDialog, true)
                shown = true
            end
        end
    end
    Log("BINDING_CONFLICT_PROMPT | " .. message)
    return shown
end

local function ResolveConfirmedBindingConflicts(bindings)
    local resolved = {}
    for _, spec in ipairs(BindingSpecs) do
        resolved[spec.Id] = NormalizeBindingValue(bindings and bindings[spec.Id] or spec.DefaultKey)
    end

    for _, conflict in ipairs(FindBindingConflicts(resolved)) do
        local winner = nil
        -- In the normal UI flow the changed row owns the requested key; the
        -- previous owner receives the changed row's former key (a real
        -- replacement/swap), rather than being reset to a default that might
        -- itself equal the requested key.
        if WTModRuntime and WTModRuntime.Bindings then
            for _, action in ipairs(conflict.Actions or {}) do
                local previous = NormalizeBindingValue(WTModRuntime.Bindings[action] or "")
                if previous ~= resolved[action] then
                    winner = action
                    break
                end
            end
        end
        if not winner then
            winner = (conflict.Actions or {})[#(conflict.Actions or {})]
        end

        local winnerPrevious = WTModRuntime and WTModRuntime.Bindings
            and NormalizeBindingValue(WTModRuntime.Bindings[winner] or "") or ""
        local group = {}
        for _, action in ipairs(conflict.Actions or {}) do group[action] = true end
        local used = {}
        for _, spec in ipairs(BindingSpecs) do
            if not group[spec.Id] then
                used[NormalizeBindingValue(resolved[spec.Id])] = true
            end
        end
        used[NormalizeBindingValue(resolved[winner])] = true

        for _, action in ipairs(conflict.Actions or {}) do
            if action ~= winner then
                local fallback = nil
                if winnerPrevious ~= "" and not used[winnerPrevious] then
                    fallback = winnerPrevious
                end
                for _, spec in ipairs(BindingSpecs) do
                    if spec.Id == action then
                        if not fallback and not used[spec.DefaultKey] then
                            fallback = spec.DefaultKey
                        end
                        if not fallback then
                            for suffix = 10, 35 do
                                local candidate = "F" .. tostring(suffix)
                                if not used[candidate] then
                                    fallback = candidate
                                    break
                                end
                            end
                        end
                        if fallback then
                            resolved[action] = fallback
                            used[fallback] = true
                        end
                        break
                    end
                end
            end
        end
    end
    local remaining = FindBindingConflicts(resolved)
    if #remaining > 0 then
        return nil, "conflict resolution left duplicate bindings"
    end
    return resolved
end

local function ApplySavedBindingsToWidget(widget)
    if not widget or not widget:IsValid() or not WTModRuntime then
        return false
    end

    local menuToggle = WTModRuntime.Bindings.MenuToggle or "Insert"
    local scenarioStart = WTModRuntime.Bindings.ScenarioStart or "F6"
    local editorToggle = WTModRuntime.Bindings.EditorToggle or "F7"
    local playbackPause = WTModRuntime.Bindings.PlaybackPause or "F8"
    local playbackStop = WTModRuntime.Bindings.PlaybackStop or "F9"
    local noclipToggle = WTModRuntime.Bindings.NoclipToggle or "F5"
    Log("BINDING_UI_APPLY | MenuToggle=" .. tostring(menuToggle)
        .. " | ScenarioStart=" .. tostring(scenarioStart)
        .. " | EditorToggle=" .. tostring(editorToggle)
        .. " | PlaybackPause=" .. tostring(playbackPause)
        .. " | PlaybackStop=" .. tostring(playbackStop)
        .. " | NoclipToggle=" .. tostring(noclipToggle))

    -- Keep the Blueprint state and its two visible button labels in sync.
    -- The widget is intentionally updated from the runtime companion so a
    -- newly-created settings screen reads the same file as the save handler.
    widget.PendingMenuDisplay = FText(menuToggle)
    widget.PendingScenarioDisplay = FText(scenarioStart)
    widget.PendingEditorDisplay = FText(editorToggle)
    widget.PendingPauseDisplay = FText(playbackPause)
    widget.PendingStopDisplay = FText(playbackStop)
    widget.PendingNoclipDisplay = FText(noclipToggle)

    local menuText = widget.MenuToggleCaptureButton_Text
    if menuText and menuText:IsValid() then
        menuText:SetText(FText(menuToggle))
    end
    local scenarioText = widget.ScenarioStartCaptureButton_Text
    if scenarioText and scenarioText:IsValid() then
        scenarioText:SetText(FText(scenarioStart))
    end
    local editorText = widget.EditorToggleCaptureButton_Text
    if editorText and editorText:IsValid() then
        editorText:SetText(FText(editorToggle))
    end
    local pauseText = widget.PlaybackPauseCaptureButton_Text
    if pauseText and pauseText:IsValid() then
        pauseText:SetText(FText(playbackPause))
    end
    local stopText = widget.PlaybackStopCaptureButton_Text
    if stopText and stopText:IsValid() then
        stopText:SetText(FText(playbackStop))
    end
    local noclipText = widget.NoclipToggleCaptureButton_Text
    if noclipText and noclipText:IsValid() then noclipText:SetText(FText(noclipToggle)) end
    return true
end

if NotifyOnNewObject then
    -- NotifyOnNewObject requires the full class path without a type prefix.
    -- Keep registration isolated so a class-path/API mismatch cannot prevent
    -- the save command handler below from being registered.
    local notifyOk, notifyError = pcall(function()
        NotifyOnNewObject(
            "/Game/Mods/WarThunderMOD/WBP_WarThunderBindings.WBP_WarThunderBindings_C",
            function(widget)
                WTModRuntime.BindingWidget = widget
                ExecuteWithDelay(50, function()
                    ApplySavedBindingsToWidget(widget)
                end)
            end)
        end)
    if not notifyOk then
        Log("BINDING_UI_HYDRATION_ERROR | " .. tostring(notifyError))
    else
        Log("BINDING_UI_HYDRATION_READY")
    end
end

local function SetScenarioStatus(text)
    WTModRuntime.ScenarioStatus=tostring(text or "")
    local widget=EditorUI:get("scenarios")
    if widget then widget:ApplyScenarioStatus(WTModRuntime.ScenarioStatus) end
end

if NotifyOnNewObject then
    local notifyOk, notifyError = pcall(function()
        NotifyOnNewObject("/Game/Mods/WarThunderMOD/WBP_WarThunderScenarios.WBP_WarThunderScenarios_C", function(widget)
            EditorUI:created("scenarios",widget)
        end)
    end)
    if not notifyOk then Log("SCENARIO_UI_HYDRATION_ERROR | " .. tostring(notifyError)) end
end

-- Blueprint calls this command from the Apply button.  Keeping the actual
-- file write in the runtime companion means the pak never becomes a save
-- location and the same parser/validator is used on read and write.
local function RefreshEditorInspector()
    local widget=EditorUI:get("editor")
    if not widget then return end
    local info=EditorInspector.describe(WTModRuntime.EditorModel)
    -- Children and FText are handled by typed native Blueprint nodes. Lua never
    -- indexes a cached child property on a removed or half-constructed widget.
    widget:ApplyEditorState(info.details,WTModRuntime.EditorStatus or "",info.canEdit,info.canLink)
    local editor=WTModRuntime.EditorModel
    local model=ModelCatalog.get(editor and editor:lineModelId())
    widget:ApplyRouteModel(model and model.label or 'Неизвестная модель')
    widget:ApplyLineFade(editor and editor:lineFadeSeconds() or 0,editor~=nil and (editor:selectedPoint()~=nil or #editor:points()==0))
end

local function SetEditorStatus(text)
    WTModRuntime.EditorStatus=tostring(text or "")
    RefreshEditorInspector()
end

if NotifyOnNewObject then
    pcall(function()
        NotifyOnNewObject("/Game/Mods/WarThunderMOD/WBP_WarThunderEditor.WBP_WarThunderEditor_C", function(widget)
            EditorUI:created("editor",widget)
        end)
    end)
end

local function EditorWorld()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then return nil, "no active game world" end
    local nameOk,name=pcall(function() return world:GetFName():ToString() end)
    if not nameOk or type(name)~="string" or name=="" then return nil,"cannot identify active world" end
    local lower = string.lower(tostring(name))
    if lower:find("mainmenu", 1, true) or lower:find("frontend", 1, true)
        or lower:find("clientlobby", 1, true) or lower:find("lobby", 1, true)
        or lower:find("menu", 1, true) then
        return nil, "point editor is available only in a loaded world"
    end
    return world
end

local function FindRuntimeClass(path)
    local class = StaticFindObject(path)
    if (not class or not class:IsValid()) and StaticLoadObject then
        local ok, loaded = pcall(function() return StaticLoadObject(path) end)
        if ok then class = loaded end
    end
    if class and class:IsValid() then return class end
    return nil
end

local function SpawnRoutePointActor(point)
    local world, worldError = EditorWorld()
    if not world then return nil, worldError end
    local class = FindRuntimeClass("/Game/Mods/WarThunderMOD/BP_WarThunderRoutePoint.BP_WarThunderRoutePoint_C")
    if not class then return nil, "route point class is not loaded" end
    local actor = world:SpawnActor(class, {}, {})
    if not actor or not actor:IsValid() then return nil, "route point spawn failed" end
    local location = point.location
    local ok = pcall(function() actor:K2_SetActorLocation({X=location.x,Y=location.y,Z=location.z}, false, {}, true) end)
    if not ok then pcall(function() actor:SetActorLocation({X=location.x,Y=location.y,Z=location.z}, false, {}, true) end) end
    return actor
end

local function EnsureEditorInteraction()
    local actor=WTModRuntime.EditorInteraction
    if actor and actor:IsValid() then actor.Enabled=true; return actor end
    local world,err=EditorWorld()
    if not world then return nil,err end
    local class=FindRuntimeClass("/Game/Mods/WarThunderMOD/BP_WTEditorInteraction.BP_WTEditorInteraction_C")
    if not class then return nil,"interaction Blueprint class unavailable" end
    actor=world:SpawnActor(class,{}, {})
    if not actor or not actor:IsValid() then return nil,"interaction controller spawn failed" end
    actor.Enabled=true
    WTModRuntime.EditorInteraction=actor
    Log("EDITOR_INTERACTION_READY | native-ray-axis-v1")
    return actor
end

local function FinishPendingEditorDrag()
    local actor=WTModRuntime and WTModRuntime.EditorInteraction
    if actor and actor:IsValid() and actor.Dragging==true then
        -- The native function clears Dragging before emitting its one commit.
        -- Finish before a panel sync can restore document coordinates.
        actor:FinishDrag()
    end
end

local function ReadEditorMousePosition()
        local controller = UEHelpers.GetPlayerController()
        if not controller or not controller:IsValid() then return nil, nil end
        local ok, a, b, c = pcall(function() return controller:GetMousePosition() end)
        if ok then
            if type(a) == "number" and type(b) == "number" then return a, b end
            if type(a) == "boolean" and type(b) == "number" and type(c) == "number" and a then return b, c end
        end
        return nil, nil
    end
-- Frame input and axis geometry belong exclusively to BP_WTEditorInteraction.
local SyncEditorActors

local function EditorCursorRay()
    local controller=UEHelpers.GetPlayerController()
    if not controller or not controller:IsValid() then return nil,nil end
    local x,y=ReadEditorMousePosition()
    if x and y then
        local ok,origin,direction=pcall(function() return controller:DeprojectScreenPositionToWorld(x,y) end)
        if ok and origin and direction then return {x=origin.X,y=origin.Y,z=origin.Z},{x=direction.X,y=direction.Y,z=direction.Z} end
    end
    -- The editor UI can hide the cursor, so screen deprojection is not always available.
    -- PlayerViewPoint is independent of mouse capture and gives the actual camera pose.
    local ok,viewOrigin,viewRotation=pcall(function() return controller:GetPlayerViewPoint() end)
    if ok and viewOrigin and viewRotation then
        local pitch=tonumber(viewRotation.Pitch) or 0
        local yaw=tonumber(viewRotation.Yaw) or 0
        local pitchRad=math.rad(pitch)
        local yawRad=math.rad(yaw)
        local cp=math.cos(pitchRad)
        local direction={x=cp*math.cos(yawRad),y=cp*math.sin(yawRad),z=math.sin(pitchRad)}
        return {x=viewOrigin.X,y=viewOrigin.Y,z=viewOrigin.Z},direction
    end
    -- Some game builds expose the same pose through ControlRotation instead.
    local okRot,rotation=pcall(function() return controller:GetControlRotation() end)
    if okRot and rotation then
        local pawn
        pcall(function() pawn=controller:GetPawn() end)
        if pawn and pawn:IsValid() then
            local okLoc,location=pcall(function() return pawn:GetActorLocation() end)
            if okLoc and location then
                local pitch=tonumber(rotation.Pitch) or 0
                local yaw=tonumber(rotation.Yaw) or 0
                local pitchRad=math.rad(pitch)
                local yawRad=math.rad(yaw)
                local cp=math.cos(pitchRad)
                return {x=location.X,y=location.Y,z=location.Z},{x=cp*math.cos(yawRad),y=cp*math.sin(yawRad),z=math.sin(pitchRad)}
            end
        end
    end
    -- UE4SS can return a lightweight controller wrapper without the camera methods.
    -- Resolve the camera manager directly in that case.
    local cameraManager
    pcall(function() cameraManager=controller:GetPlayerCameraManager() end)
    if not cameraManager then pcall(function() cameraManager=FindFirstOf("PlayerCameraManager") end) end
    if cameraManager then
        local okLoc,location=pcall(function() return cameraManager:GetCameraLocation() end)
        local okRot2,cameraRotation=pcall(function() return cameraManager:GetCameraRotation() end)
        if okLoc and okRot2 and location and cameraRotation then
            local pitch=tonumber(cameraRotation.Pitch) or 0
            local yaw=tonumber(cameraRotation.Yaw) or 0
            local pitchRad=math.rad(pitch)
            local yawRad=math.rad(yaw)
            local cp=math.cos(pitchRad)
            return {x=location.X,y=location.Y,z=location.Z},{x=cp*math.cos(yawRad),y=cp*math.sin(yawRad),z=math.sin(pitchRad)}
        end
    end
    -- Last-resort actor transform: this still creates a usable point if camera APIs are hidden.
    local okActor,actorLocation=pcall(function() return controller:GetActorLocation() end)
    if okActor and actorLocation then
        return {x=actorLocation.X,y=actorLocation.Y,z=actorLocation.Z},{x=1,y=0,z=0}
    end
    local pawn=UEHelpers.GetPlayer()
    if pawn and pawn:IsValid() then
        local ok,location,forward=pcall(function() return pawn:GetActorLocation(),pawn:GetActorForwardVector() end)
        if ok then return {x=location.X,y=location.Y,z=location.Z},{x=forward.X,y=forward.Y,z=forward.Z} end
    end
    return nil,nil
end

local function EditorSurfaceResolve()
    local controller=UEHelpers.GetPlayerController()
    if not controller or not controller:IsValid() then return nil end
    local ok,hit=pcall(function() return controller:GetHitResultUnderCursorByChannel(0,true) end)
    local actor=nil
    if ok and hit then pcall(function() actor=hit.Actor end) end
    local actorPoint=false
    if actor then pcall(function() actorPoint=actor.PointId~=nil end) end
    if ok and hit and not actorPoint then
        local point=nil
        pcall(function() point=hit.ImpactPoint end)
        if not point then pcall(function() point=hit.Location end) end
        if point then return {x=point.X or point.x,y=point.Y or point.y,z=point.Z or point.z} end
    end
    local world=UEHelpers.GetWorld()
    local origin,direction=EditorCursorRay()
    if world and world:IsValid() and origin and direction then
        local start={X=origin.x,Y=origin.y,Z=origin.z}
        local finish={X=origin.x+direction.x*100000,Y=origin.y+direction.y*100000,Z=origin.z+direction.z*100000}
        local traceLib=FindRuntimeClass("/Script/Engine.Default__KismetSystemLibrary")
        local traced,hitOk,tr=traceLib and pcall(function() return traceLib:LineTraceSingle(world,start,finish,0,true,{},0,{},true) end) or false,false,nil
        if traced and hitOk and tr then
            local point=nil
            pcall(function() point=tr.ImpactPoint end)
            if not point then pcall(function() point=tr.Location end) end
            if point then return {x=point.X or point.x,y=point.Y or point.y,z=point.Z or point.z} end
        end
    end
    return nil
end

-- Link actors retain references to point actors and update their native curve
-- on movement. World-coordinate samples must never be the live editor state.
local function DrawRouteLines()
    local model=WTModRuntime and WTModRuntime.EditorModel
    local renderer=WTModRuntime and WTModRuntime.EditorInteraction
    if not model or not renderer or not renderer:IsValid() then return end
    -- Remove geometry made by the old static renderer (also on hot/reopen sync).
    renderer:ClearRoutePreview()
    WTModRuntime.EditorLinks=WTModRuntime.EditorLinks or {}
    EditorLinks.sync(model,WTModRuntime.EditorActors,WTModRuntime.EditorLinks,function(key)
        local world=UEHelpers.GetWorld()
        local class=FindRuntimeClass('/Game/Mods/WarThunderMOD/BP_WTEditorLink.BP_WTEditorLink_C')
        if not class then Log('EDITOR_LINK_RENDER_ERROR | live link class unavailable');return end
        local actor=world:SpawnActor(class,{}, {})
        if actor and actor:IsValid() then Log('EDITOR_LINK_LIVE_BOUND | '..key);return actor end
    end)
end
local function RefreshPointSelection()
    local model=WTModRuntime and WTModRuntime.EditorModel
    if not model then return end
    local point=model:selectedPoint()
    local selectedKey=point and (tostring(model.activeRouteId)..':'..tostring(point.id))
    -- Selection is visual state only. In particular, grabbing a handle must
    -- not run model -> actor position sync over an in-progress native drag.
    for key,actor in pairs(WTModRuntime.EditorActors or {}) do
        if actor and actor:IsValid() then
            local ok,err=pcall(function() actor:ApplySelection(key==selectedKey) end)
            if not ok then Log('EDITOR_SELECTION_ERROR | '..tostring(key)..' | '..tostring(err)) end
        end
    end
end
SyncEditorActors = function()
    if not WTModRuntime or not WTModRuntime.EditorModel then return false end
    WTModRuntime.CurrentScenario=WTModRuntime.EditorModel.document
    WTModRuntime.ScenarioDirty=WTModRuntime.EditorModel:dirty()
    WTModRuntime.EditorActors=WTModRuntime.EditorActors or {}
    for id,actor in pairs(WTModRuntime.EditorActors) do
        local ok,valid=pcall(function() return actor:IsValid() end)
        if not ok or not valid then WTModRuntime.EditorActors[id]=nil end
    end
    local live={}
    for _,route in ipairs(WTModRuntime.EditorModel:routeList()) do
        for index,point in ipairs(route.points or {}) do
            local key=tostring(route.id)..":"..tostring(point.id)
            live[key]=true
            local actor=WTModRuntime.EditorActors[key]
            if not actor then
                local errorText
                actor,errorText=SpawnRoutePointActor(point)
                if actor then WTModRuntime.EditorActors[key]=actor else Log("EDITOR_POINT_SPAWN_ERROR | route="..tostring(route.id).." | "..tostring(errorText)) end
            end
            actor=WTModRuntime.EditorActors[key]
            if actor then
                local p=point.location
                actor:K2_SetActorLocation({X=p.x,Y=p.y,Z=p.z},false,{},true)
                pcall(function() actor.PointId=point.id end)
                pcall(function() actor.PointName=point.name end)
                for _,componentName in ipairs({"AxisX","AxisY","AxisZ"}) do
                    pcall(function()
                        local component=actor[componentName]
                        if component and component:IsValid() then component:SetVisibility(true,true) end
                    end)
                end
                pcall(function() actor.TargetSpeedMps=point.targetSpeedMps end)
                pcall(function() actor.AngleSmoothing=point.angleSmoothing end)
            end
        end
    end
    for id,actor in pairs(WTModRuntime.EditorActors) do
        if not live[id] then pcall(function() actor:K2_DestroyActor() end); WTModRuntime.EditorActors[id]=nil end
    end
    RefreshPointSelection()
    DrawRouteLines()
    RefreshEditorInspector()
    return true
end

local function ClearEditorWorldVisuals()
    if WTModRuntime then EditorLinks.clear(WTModRuntime.EditorLinks) end
    if WTModRuntime and WTModRuntime.EditorInteraction then
        local actor=WTModRuntime.EditorInteraction
        pcall(function() if actor:IsValid() then actor.Enabled=false; actor:K2_DestroyActor() end end)
        WTModRuntime.EditorInteraction=nil
    end
    if WTModRuntime and WTModRuntime.EditorActors then
        for id, actor in pairs(WTModRuntime.EditorActors) do
            pcall(function() if actor and actor:IsValid() then actor:K2_DestroyActor() end end)
            WTModRuntime.EditorActors[id]=nil
        end
    end
    if WTModRuntime then
        WTModRuntime.EditorPlacementMode=false
        WTModRuntime.EditorDrag=nil
        WTModRuntime.EditorMouseWasDown=false
        WTModRuntime.EditorKeys=nil
        -- Keep the in-memory document when the panel closes; reopening the editor
        -- must show the same unsaved points instead of creating a fresh model.
        WTModRuntime.EditorWidget=nil
    end
    Log("EDITOR_VISUALS_CLEARED")
end
local function SpawnPlaybackActor(model)
    local world,worldError=EditorWorld()
    if not world then error(worldError) end
    local class=FindRuntimeClass(model.actorClass)
    assert(class,'model class unavailable: '..model.id)
    local actor=world:SpawnActor(class,{}, {})
    assert(actor and actor:IsValid(),'model spawn failed: '..model.id)
    Log('PLAYBACK_UNIT_SPAWNED | model='..model.id)
    return actor
end
local function StopPlayback()
    if WTModRuntime.Playback and not WTModRuntime.Playback:canEdit() then WTModRuntime.Playback:stop() end
end

local function EditorMutationAllowed()
    if not WTModRuntime or WTModRuntime.EditorActive ~= true then
        Log("EDITOR_MUTATION_REJECTED | editor is not active")
        return false
    end
    local world, worldError = EditorWorld()
    if not world then
        Log("EDITOR_MUTATION_REJECTED | " .. tostring(worldError))
        return false
    end
    if WTModRuntime and WTModRuntime.Playback and not WTModRuntime.Playback:canEdit() then
        Log("EDITOR_MUTATION_REJECTED | playback is active")
        return false
    end
    return true
end

-- The placement editor has its own actors/document and survives menu lifetime.
Vibe.host.world=EditorWorld
Vibe.host.spawnClass=function(world,name)
    local packageName='/Game/Mods/WarThunderMOD/'..name
    local class=FindRuntimeClass(packageName..'.'..name..'_C')
    if not class then
        local helpers=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
        if helpers and helpers:IsValid() and UEHelpers.FindOrAddFName then
            class=helpers:GetAsset({PackageName=UEHelpers.FindOrAddFName(packageName),AssetName=UEHelpers.FindOrAddFName(name..'_C')})
        end
    end
    if not class or not class:IsValid() then return nil,'Не загружен класс '..name end
    return world:SpawnActor(class,{},{}),'Не удалось создать '..name
end
Vibe.host.controller=function(world) return Vibe.host.spawnClass(world,'BP_WTVibeInteraction') end
Vibe.host.spawn=function(world) return Vibe.host.spawnClass(world,'BP_WTVibeProp') end
Vibe.host.read=function()
    if not WTModRuntime or not WTModRuntime.Root then return nil,'Путь мода недоступен' end
    local f,err=io.open(JoinPath(WTModRuntime.Root,'vibe_layout.json'),'rb')
    if not f then return nil,err end
    local text=f:read(1024*1024+1);f:close();return text
end
Vibe.host.write=function(text)
    if not WTModRuntime or not WTModRuntime.Root then return false,'Путь мода недоступен' end
    return WriteTextAtomic(JoinPath(WTModRuntime.Root,'vibe_layout.json'),text)
end
Vibe.host.status=function(message,state)
    Log('VIBE_STATUS | '..tostring(message))
    local widget=EditorUI:get('vibe')
    if widget then
        local canEdit=state.active and state.driver and state.driver:IsValid() or false
        widget:ApplyVibeState(tostring(message)..'\nМоделей в мире: '..#state.layout.props,
            canEdit and state.layout.selected~=nil,canEdit,VibeLayout.model(state.modelId).index)
    end
end
if NotifyOnNewObject then
    NotifyOnNewObject('/Game/Mods/WarThunderMOD/WBP_WarThunderVibe.WBP_WarThunderVibe_C',function(widget)
        EditorUI:created('vibe',widget)
    end)
end

if RegisterConsoleCommandHandler then
    RegisterConsoleCommandHandler("wt_ui_ready",function(command)
        local kind,name=tostring(command or ""):match("wt_ui_ready%s+(%a+)%s+(%S+)")
        if kind~="editor" and kind~="scenarios" and kind~="vibe" then return true end
        if EditorUI:ready(kind,name) then
            Log("UI_READY | "..kind.." | "..name)
            if kind=='vibe' then
                if WTModRuntime.EditorActive then PlaybackCommands.wt_editor_close() end
                Vibe:open()
            elseif kind=="editor" then
                local widget=EditorUI:get('editor')
                widget:ClearModelOptions()
                for _,model in ipairs(ModelCatalog.list()) do widget:AddModelOption(model.label) end
                RefreshEditorInspector()
            else SetScenarioStatus(WTModRuntime.ScenarioStatus or "Статус: сценарий не выбран") end
        else Log("UI_READY_REJECT | "..kind.." | "..tostring(name)) end
        return true
    end)
    for name,method in pairs({wt_vibe_save='save',wt_vibe_load='load',wt_vibe_clear='clear',wt_vibe_delete='deleteSelected'}) do
        RegisterConsoleCommandHandler(name,function()
            local ok,err=pcall(function() Vibe[method](Vibe) end)
            if not ok then Vibe:status('Ошибка: '..tostring(err));Log('VIBE_ERROR | '..name..' | '..tostring(err)) end
            return true
        end)
    end
    RegisterConsoleCommandHandler('wt_vibe_spawn',function(command)
        local index=tostring(command or ''):match('^wt_vibe_spawn%s+(%d+)%s*$')
        local model=index and VibeLayout.modelAt(tonumber(index))
        if not model then Log('VIBE_SPAWN_REJECT | invalid model index');return true end
        local ok,err=pcall(function() Vibe:setModel(model.id);Vibe:spawn() end)
        if not ok then Vibe:status('Ошибка добавления: '..tostring(err)) end
        return true
    end)
    RegisterConsoleCommandHandler('wt_vibe_select',function(command)
        local name=tostring(command or ''):match('wt_vibe_select%s+(%S+)')
        if name then Vibe:selectActor(name) end
        return true
    end)
    RegisterConsoleCommandHandler('wt_vibe_commit',function()
        if Vibe.active and Vibe:world() then
            local ok,err=pcall(function() Vibe:capture() end)
            if ok then Vibe:status('Положение модели изменено') else Log('VIBE_CAPTURE_ERROR | '..tostring(err)) end
        end
        return true
    end)
    RegisterConsoleCommandHandler('wt_vibe_world',function()
        if Vibe.driver and Vibe.driver:IsValid() then Vibe.driver:ResumeWorldInput() end
        return true
    end)
    RegisterConsoleCommandHandler("wt_ui_closed",function(command)
        local kind,name=tostring(command or ""):match("wt_ui_closed%s+(%a+)%s+(%S+)")
        if kind then EditorUI:closed(kind,name) end
        if kind then Log("UI_CLOSED | "..kind.." | "..tostring(name)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_save_binds", function(FullCommand)
        -- UE4SS versions differ in whether FullCommand includes the command
        -- name. Accept both forms so Apply remains compatible across loaders.
        local raw = tostring(FullCommand or "")
            :gsub("^%s*wt_save_binds%s*", "")
        Log("BINDING_SAVE_COMMAND | " .. raw)
        local requested, parseError = ParseBindingSaveCommand(raw)
        if not requested then
            Log("BINDING_SAVE_ERROR | " .. tostring(parseError))
            return true
        end

        local bindings = {}
        for _, spec in ipairs(BindingSpecs) do
            bindings[spec.Id] = WTModRuntime.Bindings[spec.Id] or spec.DefaultKey
        end
        for key, value in pairs(requested) do
            local known = false
            for _, spec in ipairs(BindingSpecs) do
                if spec.Id == key then known = true; break end
            end
            if not known then
                Log("BINDING_SAVE_ERROR | unknown action " .. tostring(key))
                return true
            end
            bindings[key] = value
        end

        local saved, saveError, saveIssues, saveConflicts = SaveBindingSet(bindings)
        if saved then
            for _, widget in pairs(GetBindingWidgets()) do
                ApplySavedBindingsToWidget(widget)
            end
            ClearBindingConflictPrompt()
            Log("BINDING_SAVE_OK | " .. SerializeBindings(bindings):gsub("\r\n", " | "):gsub("\r?\n", " | "))
        else
            if saveConflicts and #saveConflicts > 0 then
                ShowBindingConflictPrompt(saveConflicts, bindings)
            end
            Log("BINDING_SAVE_ERROR | " .. tostring(saveError))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_confirm_binds", function()
        local pending = WTModRuntime and WTModRuntime.PendingBindingSet
        if not pending then
            Log("BINDING_CONFLICT_CONFIRM_ERROR | no pending binding set")
            return true
        end

        local resolved, resolveError = ResolveConfirmedBindingConflicts(pending)
        if not resolved then
            Log("BINDING_REPLACE_ERROR | " .. tostring(resolveError))
            return true
        end
        local saved, saveError = SaveBindingSet(resolved, true)
        if saved then
            for _, widget in pairs(GetBindingWidgets()) do
                ApplySavedBindingsToWidget(widget)
            end
            ClearBindingConflictPrompt()
            Log("BINDING_REPLACE_OK | " .. SerializeBindings(resolved):gsub("\r\n", " | "):gsub("\r?\n", " | "))
        else
            Log("BINDING_REPLACE_ERROR | " .. tostring(saveError))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_cancel_binds", function()
        ClearBindingConflictPrompt()
        Log("BINDING_CONFLICT_CANCELLED")
        return true
    end)

    -- Scenario screen actions.  The editor owns the document model; these
    -- commands provide the first real file workflow through the same runtime
    -- bridge used by the picker and keep user data outside the pak.
    RegisterConsoleCommandHandler("wt_scenario_new", function()
        StopPlayback()
        ClearEditorWorldVisuals()
        WTModRuntime.EditorActive=false
        local id = "scenario_" .. tostring(os.time())
        WTModRuntime.CurrentScenario = ScenarioDocument.new(id, "Новый сценарий")
        WTModRuntime.EditorModel = nil
        WTModRuntime.CurrentScenarioFile = id .. ".json"
        WTModRuntime.ScenarioDirty = true
        WTModRuntime.LastSelectedScenario = nil
        SetScenarioStatus("Создан: " .. tostring(WTModRuntime.CurrentScenario.displayName))
        Log("SCENARIO_NEW_READY | id=draft_01")
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_pick", function()
        local ok, errorText = InvokeScenarioPicker(function(status, fileName, content, pickerError)
            if status == "selected" then
                local document, decodeError = ScenarioDocument.decode(content)
                if not document or type(document) ~= "table" or document.formatVersion ~= 1
                    or type(document.routes) ~= "table" or type(document.groups) ~= "table" then
                    Log("SCENARIO_LOAD_ERROR | " .. tostring(decodeError or "invalid scenario schema/version"))
                    return
                end
                StopPlayback()
                ClearEditorWorldVisuals()
                WTModRuntime.EditorActive=false
                WTModRuntime.CurrentScenario = document
                WTModRuntime.EditorModel = nil
                WTModRuntime.CurrentScenarioFile = fileName
                WTModRuntime.ScenarioDirty = false
                SetScenarioStatus("Загружен: " .. tostring(fileName))
                Log("SCENARIO_SELECTED | file=" .. tostring(fileName))
            elseif status == "cancelled" then
                Log("SCENARIO_PICK_CANCELLED")
            else
                Log("SCENARIO_PICK_ERROR | " .. tostring(pickerError))
            end
        end)
        if not ok then Log("SCENARIO_PICK_ERROR | " .. tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_open_folder", function()
        local ok, errorText = OpenScensFolder()
        if not ok then Log("SCENS_FOLDER_ERROR | " .. tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_list", function()
        local files, errorText = ListScenarioFiles(WTModRuntime.Scens)
        if not files then Log("SCENARIO_LIST_ERROR | "..tostring(errorText)); return true end
        SetScenarioStatus("Сценарии: " .. table.concat(files, "\n"))
        Log("SCENARIO_LIST | count="..tostring(#files))
        for _, fileName in ipairs(files) do Log("SCENARIO_FILE | "..fileName) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_save", function()
        if WTModRuntime.EditorModel then
            WTModRuntime.CurrentScenario = WTModRuntime.EditorModel.document
        end
        if not WTModRuntime.CurrentScenario then
            Log("SCENARIO_SAVE_ERROR | no current document")
            return true
        end
        local ok, content = pcall(ScenarioDocument.encode, WTModRuntime.CurrentScenario)
        if not ok then Log("SCENARIO_SAVE_ERROR | " .. tostring(content)); return true end
        local saved, errorText = WriteScenarioText(WTModRuntime.CurrentScenarioFile, content)
        if saved then
            if WTModRuntime.EditorModel then WTModRuntime.EditorModel:markSaved() end
            WTModRuntime.ScenarioDirty = false
            WTModRuntime.LastSelectedScenario = WTModRuntime.CurrentScenarioFile
            SetScenarioStatus("Сохранён: " .. tostring(WTModRuntime.CurrentScenarioFile))
            Log("SCENARIO_SAVE_OK | file=" .. WTModRuntime.CurrentScenarioFile)
        else Log("SCENARIO_SAVE_ERROR | " .. tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_delete", function()
        local fileName = WTModRuntime and WTModRuntime.LastSelectedScenario
        if not fileName then
            Log("SCENARIO_DELETE_ERROR | no selected scenario")
            return true
        end
        WTModRuntime.PendingScenarioDelete = fileName
        SetScenarioStatus("Подтвердите удаление: " .. tostring(fileName))
        Log("SCENARIO_DELETE_CONFIRM_REQUIRED | file=" .. fileName)
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_delete_cancel", function()
        WTModRuntime.PendingScenarioDelete = nil
        SetScenarioStatus("Удаление отменено")
        Log("SCENARIO_DELETE_CANCELLED")
        return true
    end)

    RegisterConsoleCommandHandler("wt_scenario_delete_confirm", function()
        local fileName = WTModRuntime.PendingScenarioDelete
        if not fileName then return true end
        WTModRuntime.PendingScenarioDelete = nil
        local ok, errorText = DeleteScenarioFile(fileName)
        if ok then
            WTModRuntime.LastSelectedScenario = nil
            SetScenarioStatus("Удалён: " .. tostring(fileName))
            Log("SCENARIO_DELETE_OK | file=" .. tostring(fileName))
        else
            Log("SCENARIO_DELETE_ERROR | " .. tostring(errorText))
        end
        return true
    end)

    RegisterPlaybackCommand("wt_playback_start", function(fullCommand)
        local world,worldError=EditorWorld()
        if not world then SetScenarioStatus("Запуск доступен только в загруженном мире");Log("PLAYBACK_START_ERROR | "..tostring(worldError));return true end
        if not WTModRuntime.CurrentScenario then SetScenarioStatus("Сначала создайте или загрузите сценарий");Log("PLAYBACK_START_ERROR | no current scenario");return true end
        FinishPendingEditorDrag()
        local restart=tostring(fullCommand or ""):find("restart",1,true)~=nil
        if WTModRuntime.Playback and not WTModRuntime.Playback:canEdit() and not restart then
            SetScenarioStatus("Сценарий уже запущен");Log("PLAYBACK_START_ERROR | already active");return true
        end
        local token=tostring(os.time()).."_"..tostring(math.random(100000,999999))
        local ok,playback=pcall(PlaybackRuntime.new,WTModRuntime.CurrentScenario,token)
        if not ok then SetScenarioStatus("Нельзя запустить: соедините разные точки и проверьте модель/параметры");Log("PLAYBACK_START_ERROR | "..tostring(playback));return true end
        StopPlayback()
        local started,errorText=playback:start(SpawnPlaybackActor)
        if not started then SetScenarioStatus("Ошибка запуска модели. Подробности записаны в лог");Log("PLAYBACK_START_ERROR | "..tostring(errorText));return true end
        WTModRuntime.Playback=playback
        WTModRuntime.EditorActive=false
        ClearEditorWorldVisuals()
        SetScenarioStatus("Сценарий запущен · линий: "..#playback.units)
        for _,kind in ipairs({'editor','scenarios'}) do
            local widget=EditorUI:get(kind)
            if widget then widget:RemoveFromParent() end
        end
        Log("PLAYBACK_STARTED | native-spline-v1 | flights="..#playback.units.." | session="..token)
        return true
    end)
    RegisterPlaybackCommand("wt_playback_pause",function()
        local playback=WTModRuntime.Playback
        if not playback then return true end
        local ok,errorText=playback:pause()
        if ok then SetScenarioStatus("Сценарий на паузе");Log("PLAYBACK_PAUSED") else Log("PLAYBACK_PAUSE_ERROR | "..tostring(errorText)) end
        return true
    end)
    RegisterPlaybackCommand("wt_playback_resume",function()
        local playback=WTModRuntime.Playback
        if not playback then return true end
        local ok,errorText=playback:resume()
        if ok then SetScenarioStatus("Сценарий продолжается");Log("PLAYBACK_RESUMED") else Log("PLAYBACK_RESUME_ERROR | "..tostring(errorText)) end
        return true
    end)
    RegisterPlaybackCommand("wt_playback_stop",function()
        local playback=WTModRuntime.Playback
        if not playback then return true end
        local ok,errorText=playback:stop()
        if ok then SetScenarioStatus("Сценарий остановлен");Log("PLAYBACK_STOPPED") else Log("PLAYBACK_STOP_ERROR | "..tostring(errorText)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_playback_finished",function(command)
        local token,id=tostring(command or ''):match('wt_playback_finished%s+(%S+)%s+(%S+)')
        local playback=WTModRuntime.Playback
        if playback and playback:finished(token,id) then
            Log('PLAYBACK_UNIT_FINISHED | '..tostring(id))
            if playback.state=='Stopped' then SetScenarioStatus('Сценарий завершён');Log('PLAYBACK_FINISHED') end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_playback_list", function()
        if not WTModRuntime.Playback then Log("PLAYBACK_LIST | state=Ready"); return true end
        local snapshot = WTModRuntime.Playback:snapshot()
        Log("PLAYBACK_LIST | state=" .. snapshot.state .. " | registry=" .. tostring(snapshot.registryCount))
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_route_new", function(fullCommand)
        if not EditorMutationAllowed() or not WTModRuntime.EditorModel then return true end
        local id,name=tostring(fullCommand or ""):match("wt_editor_route_new%s*([A-Za-z0-9_-]*)%s*(.*)")
        id=(id and id~="" and id) or nil; name=(name and name~="" and name) or nil
        local ok,result=pcall(function() return WTModRuntime.EditorModel:addRoute(id,name) end)
        if ok then SyncEditorActors(); Log("EDITOR_ROUTE_CREATED | id="..tostring(result)) else Log("EDITOR_ROUTE_ERROR | "..tostring(result)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_route_select", function(fullCommand)
        local id=tostring(fullCommand or ""):match("wt_editor_route_select%s+([A-Za-z0-9_-]+)")
        if WTModRuntime.EditorModel and id then
            local ok,errorText=pcall(function() WTModRuntime.EditorModel:setActiveRoute(id) end)
            if ok then Log("EDITOR_ROUTE_SELECTED | id="..id) else Log("EDITOR_ROUTE_ERROR | "..tostring(errorText)) end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_route_next", function()
        local model=WTModRuntime.EditorModel
        if not model then return true end
        local ids=model:routeIds(); local index=1
        for i,id in ipairs(ids) do if id==model.activeRouteId then index=i; break end end
        local nextId=ids[index%#ids+1]
        pcall(function() model:setActiveRoute(nextId) end)
        SetEditorStatus("Маршрут: "..tostring(nextId))
        Log("EDITOR_ROUTE_SELECTED | id="..tostring(nextId))
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_route_delete", function(fullCommand)
        if not EditorMutationAllowed() or not WTModRuntime.EditorModel then return true end
        local id=tostring(fullCommand or ""):match("wt_editor_route_delete%s+([A-Za-z0-9_-]+)") or WTModRuntime.EditorModel.activeRouteId
        local ok,errorText=pcall(function() WTModRuntime.EditorModel:removeRoute(id) end)
        if ok then SyncEditorActors(); Log("EDITOR_ROUTE_DELETED | id="..tostring(id)) else Log("EDITOR_ROUTE_ERROR | "..tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_route_list", function()
        local model=WTModRuntime.EditorModel
        if not model then Log("EDITOR_ROUTE_LIST_ERROR | editor is not open"); return true end
        local lines={}
        for _,route in ipairs(model:routeList()) do
            local names={}
            for index,point in ipairs(route.points or {}) do names[#names+1]=tostring(index)..". "..tostring(point.name) end
            lines[#lines+1]=tostring(route.id).." ("..tostring(#(route.points or {}))..") "..table.concat(names,", ")
            Log("EDITOR_ROUTE | id="..tostring(route.id).." | name="..tostring(route.name).." | points="..tostring(#(route.points or {})))
        end
        SetEditorStatus(table.concat(lines,"\n"))
        return true
    end)

    RegisterPlaybackCommand("wt_editor_close", function()
        FinishPendingEditorDrag()
        WTModRuntime.EditorActive=false
        WTModRuntime.EditorPollToken=(WTModRuntime.EditorPollToken or 0)+1
        WTModRuntime.EditorPollPending=false
        WTModRuntime.EditorPollCallback=nil
        local controller=UEHelpers.GetPlayerController()
        if controller and controller:IsValid() then
            pcall(function() controller.bEnableClickEvents=false end)
            pcall(function() controller.bEnableMouseOverEvents=false end)
        end
        ClearEditorWorldVisuals()
        return true
    end)
    RegisterPlaybackCommand("wt_editor_open", function()
        local world, errorText = EditorWorld()
        if not world then Log("EDITOR_OPEN_ERROR | " .. tostring(errorText)); return true end
        if WTModRuntime.Playback and not WTModRuntime.Playback:canEdit() then
            SetScenarioStatus("Остановите сценарий перед редактированием")
            SetEditorStatus("Сценарий запущен. Остановите его перед редактированием")
            Log("EDITOR_OPEN_REJECT | playback active");return true
        end
        Vibe:close()
        FinishPendingEditorDrag()
        if not WTModRuntime.CurrentScenario then
            local id = "scenario_" .. tostring(os.time())
            WTModRuntime.CurrentScenario = ScenarioDocument.new(id, "Новый сценарий")
            WTModRuntime.CurrentScenarioFile = id .. ".json"
            WTModRuntime.ScenarioDirty = true
            SetScenarioStatus("Создан черновик: "..WTModRuntime.CurrentScenarioFile)
            Log("SCENARIO_NEW_READY | id="..id)
        end
        local model = WTModRuntime.EditorModel
        if not model then
            local ok, created = pcall(EditorModel.new, WTModRuntime.CurrentScenario)
            if not ok then Log("EDITOR_OPEN_ERROR | " .. tostring(created)); return true end
            model = created
            WTModRuntime.EditorModel = model
        end
        WTModRuntime.EditorActive=true
        local controller=UEHelpers.GetPlayerController()
        if controller and controller:IsValid() then
            pcall(function() controller.bEnableClickEvents=true end)
            pcall(function() controller.bEnableMouseOverEvents=true end)
            pcall(function() controller.bShowMouseCursor=true end)
        end
        WTModRuntime.EditorMouseWasDown=false
        WTModRuntime.EditorActors = WTModRuntime.EditorActors or {}
        local interaction,interactionError=EnsureEditorInteraction()
        if not interaction then
            WTModRuntime.EditorActive=false
            Log("EDITOR_OPEN_ERROR | "..tostring(interactionError))
            SetEditorStatus("Ошибка контроллера редактора: "..tostring(interactionError))
            return true
        end
        SyncEditorActors()
        SetEditorStatus("Точек: "..tostring(#model:points())..". Закройте меню клавишей меню; наведитесь на стрелку, удерживайте ЛКМ и двигайте мышь.")
        Log("EDITOR_OPEN_OK | mode=Navigation | points=" .. tostring(#model:points()))
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_add_point", function()
        if not EditorMutationAllowed() then return true end
        local model=WTModRuntime.EditorModel
        if not model then Log("EDITOR_ADD_ERROR | editor is not open"); return true end
        local origin,direction=EditorCursorRay()
        if not origin or not direction then
            Log("EDITOR_ADD_ERROR | camera ray unavailable")
            SetEditorStatus("Не удалось получить направление камеры")
            return true
        end
        local ok,pointId=pcall(function() return model:add(origin,direction,1000,false) end)
        if ok then
            WTModRuntime.EditorPlacementMode=false
            SyncEditorActors()
            SetEditorStatus("Добавлена "..tostring(pointId)..". «Связать» соединяет предыдущую выбранную точку с текущей.")
            Log("EDITOR_POINT_ADDED | id="..tostring(pointId).." | route="..tostring(model.activeRouteId))
        else
            Log("EDITOR_ADD_ERROR | "..tostring(pointId))
            SetEditorStatus("Ошибка добавления точки")
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_undo", function()
        if not EditorMutationAllowed() then return true end
        if WTModRuntime.EditorModel and WTModRuntime.EditorModel:undo() then SyncEditorActors(); Log("EDITOR_UNDO_OK") end
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_redo", function()
        if not EditorMutationAllowed() then return true end
        if WTModRuntime.EditorModel and WTModRuntime.EditorModel:redo() then SyncEditorActors(); Log("EDITOR_REDO_OK") end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_select_all", function()
        local model=WTModRuntime.EditorModel
        if model then model:selectAll(); SyncEditorActors(); SetEditorStatus("Выбраны все точки маршрута") end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_select_toggle", function(fullCommand)
        local id=tostring(fullCommand or ""):match("wt_editor_select_toggle%s+([A-Za-z0-9_-]+)")
        local model=WTModRuntime.EditorModel
        if model and id then pcall(function() model:toggleSelect(id) end); SyncEditorActors() end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_copy", function()
        local model=WTModRuntime.EditorModel
        if model then model:copySelected(); SetEditorStatus("Точки скопированы") end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_paste", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local x,y,z=tostring(fullCommand or ""):match("wt_editor_paste%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)")
        local model=WTModRuntime.EditorModel
        if model then
            local ok,errorText=pcall(function() model:paste({x=tonumber(x) or 100,y=tonumber(y) or 0,z=tonumber(z) or 0}) end)
            if ok then SyncEditorActors(); SetEditorStatus("Точки вставлены") else SetEditorStatus("Ошибка вставки: "..tostring(errorText)) end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_rename", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local id,name=tostring(fullCommand or ""):match("wt_editor_rename%s+([A-Za-z0-9_-]+)%s+(.+)")
        local model=WTModRuntime.EditorModel
        if model and id and name then
            local ok,errorText=pcall(function() model:properties(id,{name=name}) end)
            if ok then SyncEditorActors(); SetEditorStatus("Переименовано: "..name) else SetEditorStatus("Ошибка имени: "..tostring(errorText)) end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_reorder", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local id,index=tostring(fullCommand or ""):match("wt_editor_reorder%s+([A-Za-z0-9_-]+)%s+(%d+)")
        local model=WTModRuntime.EditorModel
        if model and id and index then
            local ok,errorText=pcall(function() model:reorder(id,tonumber(index)) end)
            if ok then SyncEditorActors(); SetEditorStatus("Порядок точки изменён") else SetEditorStatus("Ошибка порядка: "..tostring(errorText)) end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_mouse_move", function()
        -- OnMouseMove is emitted continuously by UMG. Do not route it through
        -- Lua/console while no drag has been established; that path can saturate
        -- the game thread and the log writer.
        if not WTModRuntime or not WTModRuntime.EditorDrag or not WTModRuntime.EditorDrag.active then return true end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_save", function()
        if not EditorMutationAllowed() then return true end
        FinishPendingEditorDrag()
        local model = WTModRuntime.EditorModel
        if not model then Log("EDITOR_SAVE_ERROR | editor is not open"); return true end
        WTModRuntime.CurrentScenario = model.document
        local fileName = WTModRuntime.CurrentScenarioFile or "draft_01.json"
        local ok, content = pcall(ScenarioDocument.encode, model.document)
        if not ok then Log("EDITOR_SAVE_ERROR | " .. tostring(content)); return true end
        local saved, errorText = WriteScenarioText(fileName, content)
        if saved then
            model:markSaved()
            WTModRuntime.ScenarioDirty = false
            WTModRuntime.LastSelectedScenario = fileName
            SetScenarioStatus("Сохранён: "..fileName)
            SetEditorStatus("Сценарий сохранён: "..fileName)
            Log("EDITOR_SAVE_OK | file=" .. fileName)
        else Log("EDITOR_SAVE_ERROR | " .. tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_grab", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local name=tostring(fullCommand or ""):match("wt_editor_grab%s+(%S+)")
        local model=WTModRuntime.EditorModel
        if not model then return true end
        for key,actor in pairs(WTModRuntime.EditorActors or {}) do
            if actor:IsValid() and actor:GetFName():ToString()==name then
                local routeId,pointId=key:match("^(.-):(.+)$")
                model:setActiveRoute(routeId)
                model:select(pointId)
                RefreshPointSelection()
                Log("EDITOR_DRAG_BEGIN | "..key.." | actor="..name)
                SetEditorStatus("Перетаскивание "..pointId..": отпустите ЛКМ для фиксации")
                return true
            end
        end
        Log("EDITOR_DRAG_REJECT | grab actor not in document: "..tostring(name))
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_commit", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local name,x,y,z=tostring(fullCommand or ""):match("wt_editor_commit%s+(%S+)%s+X=([%d%.%+%-eE]+)%s+Y=([%d%.%+%-eE]+)%s+Z=([%d%.%+%-eE]+)")
        local model=WTModRuntime.EditorModel
        if not model or not name or not tonumber(x) or not tonumber(y) or not tonumber(z) then
            Log("EDITOR_DRAG_REJECT | invalid commit: "..tostring(fullCommand)); return true
        end
        for key,actor in pairs(WTModRuntime.EditorActors or {}) do
            if actor:IsValid() and actor:GetFName():ToString()==name then
                local routeId,pointId=key:match("^(.-):(.+)$")
                local ok,err=pcall(function() model:commitWorldPosition(routeId,pointId,{x=tonumber(x),y=tonumber(y),z=tonumber(z)}) end)
                if ok then
                    WTModRuntime.CurrentScenario=model.document
                    WTModRuntime.ScenarioDirty=model:dirty()
                    SyncEditorActors()
                    SetEditorStatus("Перемещена "..pointId..". Сохраните сценарий.")
                    Log("EDITOR_DRAG_COMMIT | "..key.." | "..x..","..y..","..z)
                else
                    SyncEditorActors()
                    Log("EDITOR_DRAG_REJECT | "..tostring(err))
                end
                return true
            end
        end
        Log("EDITOR_DRAG_REJECT | actor not in current document: "..name)
        return true
    end)

    
    -- Legacy mouse/UMG entry points deliberately cannot start a second drag.
    RegisterConsoleCommandHandler("wt_editor_begin_drag", function() return true end)
    RegisterConsoleCommandHandler("wt_editor_end_drag", function() return true end)

    RegisterConsoleCommandHandler("wt_editor_axis", function(fullCommand)
        local axis = tostring(fullCommand or ""):match("wt_editor_axis%s+([XYZxyz])")
        if axis then
            WTModRuntime.EditorDrag = WTModRuntime.EditorDrag or {}
            WTModRuntime.EditorDrag.axis = string.lower(axis)
            Log("EDITOR_DRAG_AXIS | " .. string.lower(axis))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_tick", function()
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_grid_toggle", function()
        if WTModRuntime.EditorModel then WTModRuntime.EditorModel.gridSnap = not WTModRuntime.EditorModel.gridSnap; Log("EDITOR_GRID_SNAP | "..tostring(WTModRuntime.EditorModel.gridSnap)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_surface_toggle", function()
        if WTModRuntime.EditorModel then WTModRuntime.EditorModel.surfaceSnap = not WTModRuntime.EditorModel.surfaceSnap; Log("EDITOR_SURFACE_SNAP | "..tostring(WTModRuntime.EditorModel.surfaceSnap)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_through_world_toggle", function()
        if WTModRuntime.EditorModel then WTModRuntime.EditorModel.throughWorld = not WTModRuntime.EditorModel.throughWorld; Log("EDITOR_THROUGH_WORLD | "..tostring(WTModRuntime.EditorModel.throughWorld)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_refresh", function()
        RefreshEditorInspector()
        return true
    end)
    RegisterConsoleCommandHandler('wt_editor_fade',function(command)
        if not EditorMutationAllowed() or not WTModRuntime.EditorModel then return true end
        local text=tostring(command or ''):match('wt_editor_fade%s+([%d%.%-]+)')
        local value=tonumber(text)
        local ok,err=pcall(function() WTModRuntime.EditorModel:setLineFadeSeconds(value) end)
        if ok then
            RefreshEditorInspector()
            WTModRuntime.ScenarioDirty=WTModRuntime.EditorModel:dirty()
            Log('EDITOR_LINE_FADE | seconds='..tostring(value))
        else Log('EDITOR_LINE_FADE_ERROR | '..tostring(err));SetEditorStatus(tostring(err)) end
        return true
    end)
    RegisterConsoleCommandHandler('wt_editor_model',function(command)
        if not EditorMutationAllowed() or not WTModRuntime.EditorModel then return true end
        local label=tostring(command or ''):match('wt_editor_model%s+(.+)')
        local choice=ModelCatalog.byLabel(label)
        if not choice then Log('EDITOR_MODEL_REJECT | '..tostring(label));return true end
        local model=WTModRuntime.EditorModel
        if (model:lineModelId() or ModelCatalog.defaultId)==choice.id then return true end
        local ok,err=pcall(function() model:setLineModel(choice.id) end)
        if not ok then SetEditorStatus(tostring(err));RefreshEditorInspector();return true end
        SyncEditorActors()
        local point=model:selectedPoint()
        SetEditorStatus('Модель линии: '..choice.label..'. Сохраните сценарий.')
        Log('EDITOR_MODEL_SELECTED | '..model.activeRouteId..' | point='..tostring(point and point.id)..' | '..choice.id)
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_link_source", function()
        if not EditorMutationAllowed() then return true end
        -- Compatibility with older UI assets: selection now supplies the pair.
        SetEditorStatus("Выберите две разные точки по очереди и нажмите «Связать».")
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_link_connect", function()
        if not EditorMutationAllowed() then return true end
        local model=WTModRuntime.EditorModel
        local source,point
        if model then source,point=model:linkSelection() end
        if not source then SetEditorStatus("Выберите две разные точки по очереди в одном маршруте, затем нажмите «Связать»."); return true end
        local ok,err=pcall(function() model:link(source.id,point.id) end)
        if ok then
            WTModRuntime.CurrentScenario=model.document; WTModRuntime.ScenarioDirty=model:dirty()
            SyncEditorActors()
            SetEditorStatus("Связь: "..source.id.." → "..point.id)
            Log("EDITOR_LINK_CREATED | route="..model.activeRouteId.." | "..source.id.." -> "..point.id)
        else SetEditorStatus("Связь не создана: нельзя соединить точку с собой или замкнуть цепочку"); Log("EDITOR_LINK_ERROR | "..tostring(err)) end
        return true
    end)
    RegisterConsoleCommandHandler("wt_editor_link_disconnect", function()
        if not EditorMutationAllowed() then return true end
        local model=WTModRuntime.EditorModel; local point=model and model:selectedPoint()
        if not point then SetEditorStatus("Сначала выберите точку"); return true end
        local ok,err=pcall(function() model:disconnect(point.id) end)
        if ok then SyncEditorActors(); SetEditorStatus("Связи точки разорваны") else SetEditorStatus(tostring(err)) end
        return true
    end)

    local function EditorSelectedPoint()
        local model = WTModRuntime.EditorModel
        if not model then return nil, nil end
        return model:selectedPoint()
    end

    local function EditorAdjustSelected(field, delta, minimum, maximum)
        if not EditorMutationAllowed() then return false end
        local model = WTModRuntime.EditorModel
        local point = EditorSelectedPoint()
        if not model or not point then SetEditorStatus("Сначала выберите точку"); return false end
        local value = tonumber(point[field]) or 0
        value = math.max(minimum, math.min(maximum, value + delta))
        if math.abs(value-minimum)<1e-9 then value=minimum end
        if math.abs(value-maximum)<1e-9 then value=maximum end
        local id = point.id
        local ok = pcall(function() model:properties(id, {[field]=value}) end)
        if ok then SyncEditorActors(); Log("EDITOR_POINT_PROPERTY | id="..id.." | "..field.."="..tostring(value)) end
        return ok
    end

    local function EditorSelectAdjacent(step)
        local model = WTModRuntime.EditorModel
        if not model then return false end
        local points = model:points(); if #points == 0 then return false end
        local current
        for i,p in ipairs(points) do if model.selected[p.id] then current=i; break end end
        local index = current and (((current - 1 + step) % #points) + 1) or (step>0 and 1 or #points)
        model:select(points[index].id)
        RefreshPointSelection()
        RefreshEditorInspector()
        Log("EDITOR_SELECT_OK | id=" .. tostring(points[index].id))
        return true
    end
    RegisterConsoleCommandHandler("wt_editor_select_previous", function() EditorSelectAdjacent(-1); return true end)
    RegisterConsoleCommandHandler("wt_editor_select_next", function() EditorSelectAdjacent(1); return true end)
    RegisterConsoleCommandHandler("wt_editor_angle_down", function() EditorAdjustSelected("angleSmoothing", -0.1, 0, 5); return true end)
    RegisterConsoleCommandHandler("wt_editor_angle_up", function() EditorAdjustSelected("angleSmoothing", 0.1, 0, 5); return true end)
    RegisterConsoleCommandHandler("wt_editor_speed_down", function() EditorAdjustSelected("targetSpeedMps", -5, 0, 1000000); return true end)
    RegisterConsoleCommandHandler("wt_editor_speed_up", function() EditorAdjustSelected("targetSpeedMps", 5, 0, 1000000); return true end)
    RegisterConsoleCommandHandler("wt_editor_blend_down", function() EditorAdjustSelected("speedBlendSeconds", -.5, 0, 86400); return true end)
    RegisterConsoleCommandHandler("wt_editor_blend_up", function() EditorAdjustSelected("speedBlendSeconds", .5, 0, 86400); return true end)
    RegisterConsoleCommandHandler("wt_editor_speed_smoothing_cycle", function()
        if not EditorMutationAllowed() then return true end
        local model, point = WTModRuntime.EditorModel, EditorSelectedPoint()
        if model and point then local nextValue = (tonumber(point.speedSmoothing) or 0.5) >= 0.95 and 0 or math.min(1, (tonumber(point.speedSmoothing) or 0.5) + 0.25); pcall(function() model:properties(point.id,{speedSmoothing=nextValue}) end); Log("EDITOR_POINT_PROPERTY | id="..point.id.." | speedSmoothing="..tostring(nextValue)) end
        SyncEditorActors(); return true
    end)
    RegisterConsoleCommandHandler("wt_editor_profile_cycle", function()
        if not EditorMutationAllowed() then return true end
        local model, point = WTModRuntime.EditorModel, EditorSelectedPoint()
        if model and point then local values={"Instant","Linear","Exponential"}; local current=point.speedProfile or "Linear"; local index=1; for i,v in ipairs(values) do if v==current then index=i end end; local nextValue=values[index%#values+1]; pcall(function() model:properties(point.id,{speedProfile=nextValue}) end); Log("EDITOR_POINT_PROPERTY | id="..point.id.." | speedProfile="..nextValue) end
        SyncEditorActors(); return true
    end)
    RegisterConsoleCommandHandler("wt_editor_curve_cycle", function()
        if not EditorMutationAllowed() then return true end
        local model, point = WTModRuntime.EditorModel, EditorSelectedPoint()
        if model and point then local values={"Linear","Cubic","Smooth"}; local current=point.curveType or "Smooth"; local index=1; for i,v in ipairs(values) do if v==current then index=i end end; local nextValue=values[index%#values+1]; pcall(function() model:properties(point.id,{curveType=nextValue}) end); Log("EDITOR_POINT_PROPERTY | id="..point.id.." | curveType="..nextValue) end
        SyncEditorActors(); return true
    end)
    RegisterConsoleCommandHandler("wt_editor_mode", function(fullCommand)
        local mode = tostring(fullCommand or ""):match("wt_editor_mode%s+([%a]+)")
        if WTModRuntime.EditorModel and mode then
            local ok, errorText = pcall(function() WTModRuntime.EditorModel:setMode(mode) end)
            if ok then SetEditorStatus("Режим: "..mode); SyncEditorActors(); Log("EDITOR_MODE | " .. mode) else SetEditorStatus("Ошибка режима: "..tostring(errorText)); Log("EDITOR_MODE_ERROR | " .. tostring(errorText)) end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_move", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local x,y,z = tostring(fullCommand or ""):match("wt_editor_move%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)")
        local model = WTModRuntime.EditorModel
        if not model or not x then Log("EDITOR_MOVE_ERROR | editor or delta missing"); return true end
        local ok, errorText = pcall(function() model:move({x=tonumber(x),y=tonumber(y),z=tonumber(z)}, EditorSurfaceResolve) end)
        if ok then SyncEditorActors(); Log("EDITOR_MOVE_OK") else Log("EDITOR_MOVE_ERROR | " .. tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_axis_move", function(fullCommand)
        if not EditorMutationAllowed() then return true end
        local axis, distance = tostring(fullCommand or ""):match("wt_editor_axis_move%s+([XYZxyz])%s+([^%s]+)")
        local model = WTModRuntime.EditorModel
        if not model or not axis or not tonumber(distance) then
            Log("EDITOR_AXIS_MOVE_ERROR | editor, axis or distance missing"); return true
        end
        axis = string.lower(axis)
        local delta = {x=0,y=0,z=0}; delta[axis] = tonumber(distance)
        local ok, errorText = pcall(function() model:move(delta, EditorSurfaceResolve) end)
        if ok then SyncEditorActors(); Log("EDITOR_AXIS_MOVE_OK | axis="..axis)
        else Log("EDITOR_AXIS_MOVE_ERROR | "..tostring(errorText)) end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_grid_snap", function(fullCommand)
        local value = tostring(fullCommand or ""):match("wt_editor_grid_snap%s+(%a+)")
        if WTModRuntime.EditorModel and value then
            WTModRuntime.EditorModel.gridSnap = string.lower(value) == "on"
            Log("EDITOR_GRID_SNAP | "..tostring(WTModRuntime.EditorModel.gridSnap))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_surface_snap", function(fullCommand)
        local value = tostring(fullCommand or ""):match("wt_editor_surface_snap%s+(%a+)")
        if WTModRuntime.EditorModel and value then
            WTModRuntime.EditorModel.surfaceSnap = string.lower(value) == "on"
            Log("EDITOR_SURFACE_SNAP | "..tostring(WTModRuntime.EditorModel.surfaceSnap))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_through_world", function(fullCommand)
        local value = tostring(fullCommand or ""):match("wt_editor_through_world%s+(%a+)")
        if WTModRuntime.EditorModel and value then
            WTModRuntime.EditorModel.throughWorld = string.lower(value) == "on"
            Log("EDITOR_THROUGH_WORLD | "..tostring(WTModRuntime.EditorModel.throughWorld))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_list", function()
        local model = WTModRuntime.EditorModel
        if not model then Log("EDITOR_LIST_ERROR | editor is not open"); return true end
        for index, point in ipairs(model:points()) do
            Log(string.format("EDITOR_POINT | index=%d | id=%s | name=%s | x=%.3f | y=%.3f | z=%.3f",
                index, tostring(point.id), tostring(point.name), point.location.x, point.location.y, point.location.z))
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_select", function(fullCommand)
        local id = tostring(fullCommand or ""):match("wt_editor_select%s+([A-Za-z0-9_-]+)")
        if WTModRuntime.EditorModel and id then
            local ok, errorText = pcall(function() WTModRuntime.EditorModel:select(id) end)
            if not ok then Log("EDITOR_SELECT_ERROR | " .. tostring(errorText))
            else
                RefreshPointSelection()
                RefreshEditorInspector()
                Log("EDITOR_SELECT_OK | id=" .. id)
            end
        end
        return true
    end)

    RegisterConsoleCommandHandler("wt_editor_delete", function()
        if not EditorMutationAllowed() then return true end
        if WTModRuntime.EditorModel then
            local ok, errorText = pcall(function() WTModRuntime.EditorModel:deleteSelected() end)
            if not ok then Log("EDITOR_DELETE_ERROR | " .. tostring(errorText))
            else Log("EDITOR_DELETE_OK"); end
        end
        return true
    end)
else
    Log("BINDING_SAVE_ERROR | RegisterConsoleCommandHandler is unavailable")
end

if RegisterConsoleCommandHandler then
    GameplayKeys.configure({
        keys=Key,modifiers=ModifierKey,register=RegisterKeyBindAsync,
        schedule=ExecuteInGameThread,log=Log,
        canDispatch=function()
            -- Block all scenario shortcuts while the settings page is visible.
            -- Capturing a new bind must never start playback or close its UI.
            for _,widget in ipairs(GetBindingWidgets()) do
                if widget:IsInViewport() then return false end
            end
            return true
        end
    })
    local function CloseModPanels()
        for _,name in ipairs({'WBP_WarThunderMenu_C','WBP_WarThunderScenarios_C','WBP_WarThunderEditor_C','WBP_WarThunderVibe_C'}) do
            for _,widget in pairs(FindAllOf and FindAllOf(name) or {}) do
                if widget:IsValid() and widget:IsInViewport() then widget:RemoveFromParent() end
            end
        end
    end
    local noclip=Noclip.new({
        world=EditorWorld,
        pawn=function()
            local controller=UEHelpers.GetPlayerController()
            if controller and controller:IsValid() then return controller:K2_GetPawn() end
        end,
        spawn=function(world)
            local class,err=Noclip.loadClass(StaticFindObject,UEHelpers.FindOrAddFName,Log)
            if not class then return nil,err end
            return world:SpawnActor(class,{},{}),'noclip controller spawn failed'
        end,
        log=Log,status=SetScenarioStatus
    })
    GameplayKeys.refresh(WTModRuntime and WTModRuntime.Bindings or {},{
        NoclipToggle=function() noclip:toggle() end,
        ScenarioStart=function() PlaybackCommands.wt_playback_start('wt_playback_start') end,
        EditorToggle=function()
            local world,err=EditorWorld()
            if not world then Log('EDITOR_TOGGLE_REJECT | '..tostring(err));return end
            if WTModRuntime.EditorActive then
                CloseModPanels()
                local actor=WTModRuntime.EditorInteraction
                if actor and actor:IsValid() then actor:ResumeWorldInput() end
                PlaybackCommands.wt_editor_close()
                Log('EDITOR_TOGGLE_CLOSED')
            else
                PlaybackCommands.wt_editor_open()
                if WTModRuntime.EditorActive then
                    CloseModPanels()
                    WTModRuntime.EditorInteraction:OpenEditorPanel()
                    Log('EDITOR_TOGGLE_OPENED')
                end
            end
        end,
        PlaybackPause=function()
            local p=WTModRuntime.Playback
            if p and p.state=='Paused' then PlaybackCommands.wt_playback_resume()
            else PlaybackCommands.wt_playback_pause() end
        end,
        PlaybackStop=function() PlaybackCommands.wt_playback_stop() end
    })
end






