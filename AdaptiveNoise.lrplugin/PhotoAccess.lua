local M = {}
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')

function M.read(photo)
    local settings = photo:getDevelopSettings()
    local make = photo:getFormattedMetadata('cameraMake')
    local model = photo:getFormattedMetadata('cameraModel')
    return {
        cameraKey = Model.cameraKey(make, model),
        cameraMake = make,
        cameraModel = model,
        format = photo:getRawMetadata('fileFormat'),
        iso = photo:getRawMetadata('isoSpeedRating'),
        exposure = settings.Exposure2012 or settings.Exposure,
        shadows = settings.Shadows2012,
        luminance = settings.LuminanceSmoothing,
        color = settings.ColorNoiseReduction,
        processVersion = settings.ProcessVersion,
    }
end

function M.name(photo)
    return photo:getFormattedMetadata('fileName') or '(unnamed photo)'
end

return M
