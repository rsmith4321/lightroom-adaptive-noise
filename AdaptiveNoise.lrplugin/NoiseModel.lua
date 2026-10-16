-- Original implementation. No Lightroom dependencies; compatible with Lua 5.1.
local M = {}

local function finite(n)
    return type(n) == 'number' and n == n and n > -math.huge and n < math.huge
end

local function clamp(n, low, high)
    return math.max(low, math.min(high, n))
end

local function rounded(n)
    return math.floor(n + 0.5)
end

-- Each optional adjustment shares the ISO range but has its own target curve.
function M.extraControls()
    return {
        { id = 'mask', label = 'Sharpening Mask', setting = 'SharpenEdgeMasking', min = 0, max = 100 },
        { id = 'contrast', label = 'Contrast', setting = 'Contrast2012', min = -100, max = 100 },
        { id = 'clarity', label = 'Clarity', setting = 'Clarity2012', min = -100, max = 100 },
        { id = 'texture', label = 'Texture', setting = 'Texture', min = -100, max = 100 },
    }
end

function M.defaults()
    local c = {
        enabled = true, includeNonRaw = false, logarithmic = false,
        isoLow = 100, isoHigh = 6400,
        luminanceEnabled = true, luminanceLow = 0, luminanceHigh = 50,
        luminanceCap = 100, exposurePoints = 5, shadowPoints = 1,
        colorEnabled = true, colorLow = 25, colorHigh = 40,
        colorCap = 100,
    }
    for _, control in ipairs(M.extraControls()) do
        local id = control.id
        c[id .. 'Enabled'] = false
        c[id .. 'Low'], c[id .. 'High'], c[id .. 'Cap'] = 0, 0, 100
        c[id .. 'ExposurePoints'], c[id .. 'ShadowPoints'] = 0, 0
    end
    return c
end

function M.validate(c)
    if type(c) ~= 'table' then return nil, 'Missing camera profile.' end
    for _, key in ipairs({ 'enabled', 'includeNonRaw', 'logarithmic',
        'luminanceEnabled', 'colorEnabled' }) do
        if type(c[key]) ~= 'boolean' then return nil, 'Invalid option: ' .. key end
    end
    for _, key in ipairs({ 'isoLow', 'isoHigh', 'luminanceLow', 'luminanceHigh',
        'luminanceCap', 'exposurePoints', 'shadowPoints', 'colorLow', 'colorHigh', 'colorCap' }) do
        if not finite(c[key]) then return nil, 'Enter a finite number for ' .. key .. '.' end
    end
    if c.isoLow < 1 or c.isoHigh <= c.isoLow or c.isoHigh > 10000000 then
        return nil, 'ISO high must exceed ISO low; use ISO values from 1 to 10,000,000.'
    end
    for _, key in ipairs({ 'luminanceLow', 'luminanceHigh', 'luminanceCap',
        'exposurePoints', 'shadowPoints', 'colorLow', 'colorHigh', 'colorCap' }) do
        if c[key] < 0 or c[key] > 100 then return nil, key .. ' must be between 0 and 100.' end
    end
    if c.luminanceHigh < c.luminanceLow or c.colorHigh < c.colorLow then
        return nil, 'Noise reduction at high ISO must be at least the low-ISO value.'
    end
    for _, control in ipairs(M.extraControls()) do
        local id = control.id
        if type(c[id .. 'Enabled']) ~= 'boolean' then return nil, 'Invalid option: ' .. id .. 'Enabled' end
        for _, suffix in ipairs({ 'Low', 'High', 'Cap', 'ExposurePoints', 'ShadowPoints' }) do
            local key = id .. suffix
            if not finite(c[key]) then return nil, 'Enter a finite number for ' .. key .. '.' end
            local minimum = suffix == 'Cap' and 0 or control.min
            if c[key] < minimum or c[key] > control.max then
                return nil, key .. ' must be between ' .. minimum .. ' and ' .. control.max .. '.'
            end
        end
        if control.min == 0 and c[id .. 'High'] < c[id .. 'Low'] then
            return nil, control.label .. ' at high ISO must be at least the low-ISO value.'
        end
    end
    return true
end

function M.cameraKey(make, model)
    make = tostring(make or ''):gsub('^%s+', ''):gsub('%s+$', '')
    model = tostring(model or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if make == '' and model == '' then return nil end
    -- Length prefixes prevent ambiguous names from sharing a profile.
    return #make .. ':' .. make .. #model .. ':' .. model
end

function M.isRaw(format)
    return format == 'RAW' or format == 'DNG'
end

function M.calculate(photo, c)
    local ok, message = M.validate(c)
    if not ok then return nil, message end
    if not c.enabled then return nil, 'Camera profile disabled' end
    local anyEnabled = c.luminanceEnabled or c.colorEnabled
    for _, control in ipairs(M.extraControls()) do anyEnabled = anyEnabled or c[control.id .. 'Enabled'] end
    if not anyEnabled then return nil, 'All adjustment controls disabled' end
    if type(photo.format) ~= 'string' or photo.format == '' then return nil, 'File format unavailable' end
    if photo.format == 'VIDEO' then return nil, 'Video' end
    if not M.isRaw(photo.format) and not c.includeNonRaw then return nil, 'Non-RAW disabled' end
    if not finite(photo.iso) or photo.iso <= 0 then return nil, 'Missing or invalid ISO' end
    if c.luminanceEnabled and c.exposurePoints > 0 and not finite(photo.exposure) then
        return nil, 'Exposure setting unavailable'
    end
    if c.luminanceEnabled and c.shadowPoints > 0 and not finite(photo.shadows) then
        return nil, 'Shadows setting unavailable'
    end
    for _, control in ipairs(M.extraControls()) do
        local id = control.id
        if c[id .. 'Enabled'] then
            if not finite(photo[id]) then return nil, control.label .. ' control unavailable' end
            if c[id .. 'ExposurePoints'] ~= 0 and not finite(photo.exposure) then
                return nil, 'Exposure setting unavailable'
            end
            if c[id .. 'ShadowPoints'] ~= 0 and not finite(photo.shadows) then
                return nil, 'Shadows setting unavailable'
            end
        end
    end

    local t
    if c.logarithmic then
        t = (math.log(photo.iso) - math.log(c.isoLow)) / (math.log(c.isoHigh) - math.log(c.isoLow))
    else
        t = (photo.iso - c.isoLow) / (c.isoHigh - c.isoLow)
    end
    t = clamp(t, 0, 1)
    local patch = {}
    if c.luminanceEnabled then
        if not finite(photo.luminance) then return nil, 'Luminance control unavailable' end
        local base = c.luminanceLow + t * (c.luminanceHigh - c.luminanceLow)
        local exposure = finite(photo.exposure) and photo.exposure or 0
        local shadows = finite(photo.shadows) and photo.shadows or 0
        local bonus = math.max(0, exposure) * c.exposurePoints
            + math.max(0, shadows) / 10 * c.shadowPoints
        local value = rounded(clamp(base + bonus, 0, math.floor(c.luminanceCap)))
        if value ~= photo.luminance then patch.LuminanceSmoothing = value end
    end
    if c.colorEnabled then
        if not finite(photo.color) then return nil, 'Color control unavailable' end
        local value = rounded(clamp(c.colorLow + t * (c.colorHigh - c.colorLow), 0, math.floor(c.colorCap)))
        if value ~= photo.color then patch.ColorNoiseReduction = value end
    end
    for _, control in ipairs(M.extraControls()) do
        local id = control.id
        if c[id .. 'Enabled'] then
            local base = c[id .. 'Low'] + t * (c[id .. 'High'] - c[id .. 'Low'])
            local exposure = finite(photo.exposure) and photo.exposure or 0
            local shadows = finite(photo.shadows) and photo.shadows or 0
            local bonus = math.max(0, exposure) * c[id .. 'ExposurePoints']
                + math.max(0, shadows) / 10 * c[id .. 'ShadowPoints']
            local cap = math.floor(c[id .. 'Cap'])
            local minimum = control.min < 0 and -cap or 0
            local value = rounded(clamp(base + bonus, minimum, cap))
            if value ~= photo[id] then patch[control.setting] = value end
        end
    end
    if next(patch) == nil then return {}, 'Already matches' end
    return patch
end

-- Compare the full inputs used by the preview. Never apply a stale calculation.
function M.sameInputs(a, b)
    for _, key in ipairs({ 'cameraKey', 'format', 'iso', 'exposure', 'shadows',
        'luminance', 'color', 'mask', 'contrast', 'clarity', 'texture', 'processVersion' }) do
        if a[key] ~= b[key] then return false end
    end
    return true
end

return M
