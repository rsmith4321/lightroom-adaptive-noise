local Application = import 'LrApplication'
local Binding = import 'LrBinding'
local Context = import 'LrFunctionContext'
local Dialogs = import 'LrDialogs'
local Prefs = import 'LrPrefs'
local Progress = import 'LrProgressScope'
local Tasks = import 'LrTasks'
local View = import 'LrView'
local Date = import 'LrDate'
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Batch = dofile(_PLUGIN.path .. '/Batch.lua')

local function copy(source)
    local result = {}
    for k, v in pairs(source) do result[k] = v end
    return result
end

local function reasonLines(reasons)
    local lines = {}
    for reason, count in pairs(reasons) do lines[#lines + 1] = count .. ' - ' .. reason end
    table.sort(lines)
    return table.concat(lines, '\n')
end

Tasks.startAsyncTask(function()
    Context.callWithContext('AdaptiveNoise', function(context)
        Dialogs.attachErrorDialogToFunctionContext(context)
        local catalog = Application.activeCatalog()
        -- SDK getTargetPhotos() means the whole filmstrip when nothing is selected.
        if not catalog:getTargetPhoto() then
            Dialogs.message('Adaptive Noise', 'Select the photos you want to adjust first.', 'info')
            return
        end
        local photos = catalog:getTargetPhotos()
        local records, cameras = {}, {}
        local progress = Progress { title = 'Adaptive Noise: reading ' .. #photos .. ' selected photos', functionContext = context }
        for i, photo in ipairs(photos) do
            if progress:isCanceled() then progress:done(); return end
            progress:setPortionComplete(i - 1, #photos)
            local ok, input = Tasks.pcall(function() return Access.read(photo) end)
            local name = Access.name(photo)
            if ok then
                records[#records + 1] = { photo = photo, name = name, input = input }
                if input.cameraKey then
                    cameras[input.cameraKey] = tostring(input.cameraMake or '') .. ' ' .. tostring(input.cameraModel or '')
                end
            else
                records[#records + 1] = { photo = photo, name = name, input = {}, error = 'Could not read develop settings' }
            end
            if i % 10 == 0 then Tasks.yield() end
        end
        progress:done()
        if next(cameras) == nil then
            Dialogs.message('Adaptive Noise', 'No camera information was available in the selected photos. No photos changed.', 'info')
            return
        end

        local prefs = Prefs.prefsForPlugin()
        local saved = prefs.profilesV1 or {}
        local profiles, items = {}, {}
        for key, title in pairs(cameras) do
            local profile = Model.defaults()
            if type(saved[key]) == 'table' then
                for field in pairs(profile) do
                    if saved[key][field] ~= nil then profile[field] = saved[key][field] end
                end
            end
            profiles[key] = profile
            items[#items + 1] = { title = title, value = key }
        end
        table.sort(items, function(a, b) return a.title < b.title end)
        local props = Binding.makePropertyTable(context)
        local active = items[1].value
        props.camera = active
        local function load(key)
            for field, value in pairs(profiles[key]) do props[field] = value end
        end
        local function save(key)
            for field in pairs(Model.defaults()) do profiles[key][field] = props[field] end
        end
        load(active)
        props:addObserver('camera', function()
            save(active)
            active = props.camera
            load(active)
        end)
        local f = View.osFactory()
        local bind = View.bind
        local function number(key)
            return f:edit_field { value = bind(key), precision = 2, width_in_chars = 7, immediate = true }
        end
        -- Explicit rows keep this compatible with Lightroom's Lua 5.1 runtime.
        local content = f:column {
            bind_to_object = props, spacing = 9,
            f:static_text { title = #photos .. ' selected photos. Settings are remembered separately for each camera.' },
            f:row { f:static_text { title = 'Camera', width_in_chars = 27 }, f:popup_menu { value = bind 'camera', items = items, width_in_chars = 38 } },
            f:checkbox { title = 'Enable this camera', value = bind 'enabled' },
            f:checkbox { title = 'Also adjust non-RAW photos from this camera', value = bind 'includeNonRaw' },
            f:separator { fill_horizontal = 1 },
            f:row { f:static_text { title = 'ISO range', width_in_chars = 27 }, number('isoLow'), f:static_text { title = 'to' }, number('isoHigh') },
            f:checkbox { title = 'Use logarithmic ISO scale (unchecked = linear)', value = bind 'logarithmic' },
            f:checkbox { title = 'Adjust luminance noise reduction', value = bind 'luminanceEnabled' },
            f:row { f:static_text { title = 'Luminance at low / high ISO', width_in_chars = 27 }, number('luminanceLow'), number('luminanceHigh') },
            f:row { f:static_text { title = 'Add per +1 Exposure stop', width_in_chars = 27 }, number('exposurePoints'), f:static_text { title = 'points' } },
            f:row { f:static_text { title = 'Add per +10 Shadows', width_in_chars = 27 }, number('shadowPoints'), f:static_text { title = 'points' } },
            f:row { f:static_text { title = 'Maximum luminance NR', width_in_chars = 27 }, number('luminanceCap') },
            f:separator { fill_horizontal = 1 },
            f:checkbox { title = 'Adjust color noise reduction (ISO only)', value = bind 'colorEnabled' },
            f:row { f:static_text { title = 'Color at low / high ISO', width_in_chars = 27 }, number('colorLow'), number('colorHigh') },
            f:row { f:static_text { title = 'Maximum color NR', width_in_chars = 27 }, number('colorCap') },
            f:separator { fill_horizontal = 1 },
            f:static_text { title = 'Exposure and Shadows bonuses use positive adjustments only.\nThis sets a fresh target each run; it does not add to the current NR value.\nEach changed photo gets a recovery snapshot. Other edits are preserved.', width_in_chars = 83, height_in_lines = 3 },
        }
        local answer = Dialogs.presentModalDialog { title = 'Adaptive Noise Reduction', contents = content, actionVerb = 'Preview changes' }
        if answer ~= 'ok' then return end
        save(active)
        for key, profile in pairs(profiles) do
            local ok, message = Model.validate(profile)
            if not ok then Dialogs.message('Check settings for ' .. cameras[key], message, 'warning'); return end
        end
        local merged = copy(saved)
        for key, profile in pairs(profiles) do merged[key] = copy(profile) end
        prefs.profilesV1 = merged
        local plan = Batch.plan(records, profiles)
        local summary = #plan.changes .. ' to change; ' .. plan.unchanged .. ' already match; ' .. plan.skipped .. ' skipped.'
        local lines = { summary, '', reasonLines(plan.reasons), '' }
        for i = 1, math.min(#plan.changes, 100) do
            local item = plan.changes[i]
            lines[#lines + 1] = string.format('%s  |  ISO %s  Exp %s  Shadows %s  |  Luminance %s -> %s  Color %s -> %s',
                item.name, tostring(item.input.iso), tostring(item.input.exposure), tostring(item.input.shadows),
                tostring(item.input.luminance), tostring(item.patch.LuminanceSmoothing or item.input.luminance),
                tostring(item.input.color), tostring(item.patch.ColorNoiseReduction or item.input.color))
        end
        if #plan.changes > 100 then lines[#lines + 1] = 'Showing the first 100 changes of ' .. #plan.changes .. '.' end
        if #plan.changes == 0 then Dialogs.message('Adaptive Noise: no changes', table.concat(lines, '\n'), 'info'); return end
        local preview = f:column { spacing = 9,
            f:static_text { title = summary },
            f:scrolled_view { width = 780, height = 320,
                f:static_text { title = table.concat(lines, '\n'), width_in_chars = 170, height_in_lines = #lines + 1 },
            },
            f:static_text { title = 'Apply replaces the enabled noise reduction values, including any manual NR edits.\nA before snapshot is saved for each changed photo. Cancel leaves all photos unchanged.', height_in_lines = 2 },
        }
        if Dialogs.presentModalDialog { title = 'Preview Adaptive Noise', contents = preview, actionVerb = 'Apply ' .. #plan.changes .. ' changes' } ~= 'ok' then return end
        local runId = string.format('%.6f', Date.currentTime())
        local applying = Progress { title = 'Adaptive Noise: applying changes', functionContext = context }
        local result = Batch.apply(catalog, plan, applying, runId)
        local report = string.format('%d changes confirmed in Lightroom.\n%d already matched; %d skipped in preview.\n%d changed since preview; %d failed; %d unverified; %d not attempted after Cancel.',
            result.applied, plan.unchanged, plan.skipped, result.stale, result.failed, result.unverified, result.cancelled)
        if #result.details > 0 then
            local details = {}
            for i = 1, math.min(#result.details, 20) do details[i] = result.details[i] end
            report = report .. '\n\n' .. table.concat(details, '\n')
        end
        report = report .. '\n\nRecovery snapshot: Before Adaptive Noise ' .. runId
        Dialogs.message('Adaptive Noise results', report, (result.failed + result.unverified > 0) and 'warning' or 'info')
    end)
end)
