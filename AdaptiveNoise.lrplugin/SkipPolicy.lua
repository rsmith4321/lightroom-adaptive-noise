-- Read-only eligibility rules. No image/settings mutations occur here.
local M = {}
function M.defaults()
    return { skipProcessed = false, skipManualNR = false, skipAIDenoise = false }
end
local function isTrue(value)
    return value == true or value == 1 or value == 'True' or value == 'true'
end
local function isFalse(value)
    return value == false or value == 0 or value == 'False' or value == 'false'
end

function M.aiState(settings)
    -- Older Enhance-to-DNG workflow, when Lightroom exposes the baked marker.
    if isTrue(settings.EnhanceDenoiseAlreadyApplied) then return 'applied' end
    local filters = settings.FilterList
    if filters == nil then return 'none' end
    if type(filters) ~= 'table' then return 'unknown' end
    filters = filters.Filters or filters
    if type(filters) ~= 'table' then return 'unknown' end
    local uncertain = false
    for _, filter in pairs(filters) do
        if type(filter) == 'table' then
            local name = tostring(filter.Name or ''):lower()
            if name == 'enhance' or filter.FilterID == 1 then
                local values = type(filter.Settings) == 'table' and filter.Settings or filter
                local denoise = values.Denoise
                if denoise == nil then denoise = values.denoise end
                if isTrue(denoise) then return 'applied' end
                if not isFalse(denoise) then
                    -- Lightroom may expose only a compressed enhancement payload.
                    -- Its localized title is a positive hint, never an absence test.
                    local title = tostring(filter.Title or '')
                    if title:find('/Denoise=', 1, true) or title:lower() == 'denoise' then
                        return 'applied'
                    end
                    uncertain = true
                end
            end
        else uncertain = true end
    end
    return uncertain and 'unknown' or 'none'
end

function M.manualState(settings, format)
    -- This detects existing slider edits, including presets/import defaults;
    -- the SDK cannot distinguish who moved a slider.
    local colorDefault = (format == 'RAW' or format == 'DNG') and 25 or 0
    if type(settings.LuminanceSmoothing) ~= 'number' or type(settings.ColorNoiseReduction) ~= 'number' then
        return 'unknown'
    end
    local defaults = { LuminanceSmoothing = 0, ColorNoiseReduction = colorDefault,
        LuminanceNoiseReductionDetail = 50, LuminanceNoiseReductionContrast = 0,
        ColorNoiseReductionDetail = 50, ColorNoiseReductionSmoothness = 50 }
    for key, expected in pairs(defaults) do
        if settings[key] ~= nil and settings[key] ~= expected then return 'adjusted' end
    end
    return 'default'
end

function M.reason(input, options)
    options = options or M.defaults()
    if options.skipProcessed then
        if input.processed == true then return 'Previously processed by Adaptive Noise' end
        if input.processed == 'unknown' then return 'Processing history unavailable; skipped for protection' end
    end
    if options.skipManualNR then
        if input.manualNR == 'adjusted' then return 'Existing manual noise reduction settings' end
        if input.manualNR ~= 'default' then return 'Manual noise reduction state unavailable; skipped for protection' end
    end
    if options.skipAIDenoise then
        if input.aiDenoise == 'applied' then return 'AI Denoise applied' end
        if input.aiDenoise ~= 'none' then return 'AI enhancement state uncertain; skipped for protection' end
    end
end
return M
