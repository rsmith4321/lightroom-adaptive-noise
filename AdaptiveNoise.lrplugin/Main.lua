local Application = import 'LrApplication'
local Binding = import 'LrBinding'
local Context = import 'LrFunctionContext'
local Dialogs = import 'LrDialogs'
local Prefs = import 'LrPrefs'
local Progress = import 'LrProgressScope'
local Tasks = import 'LrTasks'
local View = import 'LrView'
local Date = import 'LrDate'
local Http = import 'LrHttp'
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Batch = dofile(_PLUGIN.path .. '/Batch.lua')
local Skip = dofile(_PLUGIN.path .. '/SkipPolicy.lua')

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
            local named, name = Tasks.pcall(function() return Access.name(photo) end)
            if not named then name = 'Selected photo ' .. i .. ' (name unavailable)' end
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
        local saved = type(prefs.profilesV1) == 'table' and prefs.profilesV1 or {}
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
        local savedSkip = type(prefs.skipOptionsV1) == 'table' and prefs.skipOptionsV1 or {}
        for key in pairs(Skip.defaults()) do props[key] = savedSkip[key] == true end
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
        local function number(key, minimum, maximum, enabled)
            return f:edit_field { value = bind(key), precision = 2, width_in_chars = 7, immediate = true,
                min = minimum or 0, max = maximum or 100, enabled = enabled and bind(enabled) or nil }
        end
        local function label(title)
            return f:static_text { title = title, width_in_chars = 29 }
        end
        local function section(title, children)
            children.title, children.spacing, children.margin = title, 8, 14
            children.fill_horizontal = 1
            return f:group_box(children)
        end
        local function header()
            return f:row { spacing = 14, fill_horizontal = 1,
                f:picture { value = _PLUGIN:resourceId('assets/shootcal-logo.png'), width = 48, height = 48 },
                f:column { spacing = 3,
                    f:static_text { title = 'Adaptive Noise', font = '<system/bold>', size = 'large' },
                    f:static_text { title = 'ISO-aware adjustments for Lightroom Classic', size = 'small' },
                },
                f:spacer { fill_horizontal = 1 },
                f:push_button { title = 'Developed by ShootCal',
                    action = function() Http.openUrlInBrowser('https://shootcal.com/') end },
            }
        end
        local contentSpec = { bind_to_object = props, spacing = 14, margin = 16,
            section('Camera and ISO', {
                f:row { label('Camera'), f:popup_menu { value = bind 'camera', items = items, width_in_chars = 38 } },
                f:checkbox { title = 'Enable this camera', value = bind 'enabled' },
                f:checkbox { title = 'Also adjust non-RAW photos from this camera', value = bind 'includeNonRaw' },
                f:row { label('ISO range'), number('isoLow', 1, 10000000), f:static_text { title = 'to' }, number('isoHigh', 1, 10000000) },
                f:checkbox { title = 'Use logarithmic ISO scale (unchecked = linear)', value = bind 'logarithmic' },
            }),
            section('Luminance noise reduction', {
                f:checkbox { title = 'Adjust luminance noise reduction', value = bind 'luminanceEnabled' },
                f:row { label('At low / high ISO'), number('luminanceLow', nil, nil, 'luminanceEnabled'), number('luminanceHigh', nil, nil, 'luminanceEnabled') },
                f:row { label('Per +1 Exposure / +10 Shadows'), number('exposurePoints', nil, nil, 'luminanceEnabled'), number('shadowPoints', nil, nil, 'luminanceEnabled') },
                f:row { label('Maximum luminance NR'), number('luminanceCap', nil, nil, 'luminanceEnabled') },
            }),
            section('Color noise reduction', {
                f:checkbox { title = 'Adjust color noise reduction (ISO only)', value = bind 'colorEnabled' },
                f:row { label('At low / high ISO'), number('colorLow', nil, nil, 'colorEnabled'), number('colorHigh', nil, nil, 'colorEnabled') },
                f:row { label('Maximum color NR'), number('colorCap', nil, nil, 'colorEnabled') },
            }),
        }
        for _, control in ipairs(Model.extraControls()) do
            local id = control.id
            contentSpec[#contentSpec + 1] = section(control.label, {
                f:checkbox { title = 'Adjust ' .. control.label, value = bind(id .. 'Enabled') },
                f:row { label('At low / high ISO'), number(id .. 'Low', control.min, control.max, id .. 'Enabled'), number(id .. 'High', control.min, control.max, id .. 'Enabled'),
                    f:static_text { title = control.min < 0 and '(-100 to +100)' or '(0 to 100)' } },
                f:row { label('Per +1 Exposure / +10 Shadows'), number(id .. 'ExposurePoints', control.min, control.max, id .. 'Enabled'), number(id .. 'ShadowPoints', control.min, control.max, id .. 'Enabled') },
                f:row { label(control.min < 0 and 'Maximum magnitude' or 'Maximum value'), number(id .. 'Cap', nil, nil, id .. 'Enabled') },
            })
        end
        contentSpec[#contentSpec + 1] = section('Optional skips', {
            f:static_text { title = 'Apply to all cameras in this batch. Each option is off by default.', size = 'small' },
            f:checkbox { title = 'Skip photos previously processed by Adaptive Noise (recovery snapshot present)', value = bind 'skipProcessed' },
            f:checkbox { title = 'Skip photos with existing manual noise reduction adjustments', value = bind 'skipManualNR' },
            f:static_text { title = 'Manual NR includes presets and import settings that differ from usual defaults.\nLuminance 0; Color 25 for RAW/DNG, 0 otherwise; Detail 50, Contrast 0, Smoothness 50.', height_in_lines = 2, size = 'small' },
            f:checkbox { title = 'Skip photos with AI Denoise applied (also skips uncertain AI enhancement state)', value = bind 'skipAIDenoise' },
        })
        local content = f:column { bind_to_object = props, spacing = 12, margin = 8,
            header(),
            f:static_text { title = #photos .. (#photos == 1 and ' selected photo' or ' selected photos') .. '  |  Settings saved separately for each camera', size = 'small' },
            f:scrolled_view { width = 850, height = 500, f:column(contentSpec) },
            f:static_text { title = 'Preview to review, or Process to apply. Each changed photo gets a recovery snapshot.', size = 'small' },
        }
        local previewRequested
        while true do
            local answer = Dialogs.presentModalDialog { title = 'Adaptive Noise Reduction', contents = content, actionVerb = 'Process', otherVerb = 'Preview' }
            if answer ~= 'ok' and answer ~= 'other' then return end
            previewRequested = answer == 'other'
            save(active)
            local invalid
            for _, item in ipairs(items) do
                local ok, message = Model.validate(profiles[item.value])
                if not ok then
                    invalid = item.value
                    Dialogs.message('Check settings for ' .. item.title, message, 'warning')
                    break
                end
            end
            if not invalid then break end
            -- Retain all edits and show the camera that needs a correction.
            props.camera = invalid
        end
        local merged = copy(saved)
        for key, profile in pairs(profiles) do merged[key] = copy(profile) end
        prefs.profilesV1 = merged
        local options = {}
        for key in pairs(Skip.defaults()) do options[key] = props[key] == true end
        prefs.skipOptionsV1 = options
        local plan = Batch.plan(records, profiles, options)
        local summary = #plan.changes .. ' to change; ' .. plan.unchanged .. ' already match; ' .. plan.skipped .. ' skipped.'
        local lines = { summary }
        local reasons = reasonLines(plan.reasons)
        if reasons ~= '' then lines[#lines + 1] = reasons end
        for i = 1, math.min(#plan.changes, 100) do
            local item = plan.changes[i]
            local line = string.format('%s  |  ISO %s  Exp %s  Shadows %s  |  Luminance %s -> %s  Color %s -> %s',
                item.name, tostring(item.input.iso), tostring(item.input.exposure), tostring(item.input.shadows),
                tostring(item.input.luminance), tostring(item.patch.LuminanceSmoothing or item.input.luminance),
                tostring(item.input.color), tostring(item.patch.ColorNoiseReduction or item.input.color))
            for _, control in ipairs(Model.extraControls()) do
                if item.patch[control.setting] ~= nil then
                    line = line .. string.format('  %s %s -> %s', control.label, tostring(item.input[control.id]), tostring(item.patch[control.setting]))
                end
            end
            lines[#lines + 1] = line
        end
        if #plan.changes > 100 then lines[#lines + 1] = 'Showing the first 100 changes of ' .. #plan.changes .. '.' end
        if #plan.changes == 0 then Dialogs.message('Adaptive Noise: no changes', table.concat(lines, '\n'), 'info'); return end
        if previewRequested then
            local preview = f:column { spacing = 12, margin = 8,
                header(),
                f:static_text { title = summary },
                f:scrolled_view { width = 850, height = math.min(320, math.max(100, #lines * 18 + 32)),
                    f:column { margin = 16,
                        f:static_text { title = table.concat(lines, '\n', 2), width_in_chars = 170, height_in_lines = #lines },
                    },
                },
                f:static_text { title = 'Process replaces the enabled adjustment values, including previous manual edits.\nA before snapshot is saved for each changed photo. Cancel leaves all photos unchanged.', height_in_lines = 2 },
            }
            if Dialogs.presentModalDialog { title = 'Preview Adaptive Noise', contents = preview, actionVerb = 'Process' } ~= 'ok' then return end
        end
        local runId = string.format('%.6f', Date.currentTime())
        local applying = Progress { title = 'Adaptive Noise: applying changes', functionContext = context }
        local result = Batch.apply(catalog, plan, applying, runId)
        local report = string.format('%d change%s confirmed in Lightroom.\n%d already matched; %d skipped.\n%d changed since reading; %d protected by a skip rule before processing.\n%d failed; %d unverified; %d not attempted after Cancel.',
            result.applied, result.applied == 1 and '' or 's', plan.unchanged, plan.skipped, result.stale, result.protected, result.failed, result.unverified, result.cancelled)
        if #result.details > 0 then
            local details = {}
            for i = 1, math.min(#result.details, 20) do details[i] = result.details[i] end
            report = report .. '\n\n' .. table.concat(details, '\n')
            if #result.details > 20 then
                report = report .. '\n' .. (#result.details - 20) .. ' additional photo details omitted.'
            end
        end
        report = report .. '\n\nRecovery snapshot: Before Adaptive Noise ' .. runId
        Dialogs.message('Adaptive Noise results', report, (result.failed + result.unverified > 0) and 'warning' or 'info')
    end)
end)
