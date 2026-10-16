local M = {}
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Skip = dofile(_PLUGIN.path .. '/SkipPolicy.lua')
local Tasks = import 'LrTasks'

function M.read(photo)
    local settings = photo:getDevelopSettings()
    local make = photo:getFormattedMetadata('cameraMake')
    local model = photo:getFormattedMetadata('cameraModel')
    local format = photo:getRawMetadata('fileFormat')
    local historyOK, processed = Tasks.pcall(function()
        -- Existing v0.1 snapshots also protect photos processed before this option.
        for _, snapshot in ipairs(photo:getDevelopSnapshots()) do
            if type(snapshot.name) == 'string' and snapshot.name:find('Before Adaptive Noise ', 1, true) == 1 then
                return true
            end
        end
        return false
    end)
    local input = {
        cameraKey = Model.cameraKey(make, model),
        cameraMake = make,
        cameraModel = model,
        format = format,
        iso = photo:getRawMetadata('isoSpeedRating'),
        exposure = settings.Exposure2012 or settings.Exposure,
        shadows = settings.Shadows2012,
        luminance = settings.LuminanceSmoothing,
        color = settings.ColorNoiseReduction,
        processVersion = settings.ProcessVersion,
        processed = historyOK and processed or 'unknown',
        manualNR = Skip.manualState(settings, format),
        aiDenoise = Skip.aiState(settings),
    }
    -- Preserve false (Lua's and/or idiom cannot distinguish it from failure).
    if historyOK then input.processed = processed end
    for _, control in ipairs(Model.extraControls()) do input[control.id] = settings[control.setting] end
    return input
end

function M.name(photo)
    return photo:getFormattedMetadata('fileName') or '(unnamed photo)'
end

return M
