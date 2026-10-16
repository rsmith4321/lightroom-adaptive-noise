-- Run from the repository root: lua5.1 tests/skip_policy.lua
-- Pure eligibility tests and SDK doubles; this never opens Lightroom or a catalog.
_PLUGIN = { path = 'AdaptiveNoise.lrplugin' }
local Tasks = { pcall = pcall, sleep = function() end, yield = function() end }
function import(name)
    assert(name == 'LrTasks', 'Unexpected import: ' .. tostring(name))
    return Tasks
end
local Skip = dofile(_PLUGIN.path .. '/SkipPolicy.lua')
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Batch = dofile(_PLUGIN.path .. '/Batch.lua')
local passed = 0
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then io.stderr:write('FAIL: ' .. name .. '\n' .. tostring(err) .. '\n'); os.exit(1) end
    passed = passed + 1
    print('PASS: ' .. name)
end
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = clone(v) end
    return result
end
local function options(overrides)
    local result = Skip.defaults()
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end
local reasons = {
    processed = 'Previously processed by Adaptive Noise',
    history = 'Processing history unavailable; skipped for protection',
    manual = 'Existing manual noise reduction settings',
    manualUnknown = 'Manual noise reduction state unavailable; skipped for protection',
    ai = 'AI Denoise applied',
    aiUnknown = 'AI enhancement state uncertain; skipped for protection',
}
local allowed = { LuminanceSmoothing = true, ColorNoiseReduction = true,
    SharpenEdgeMasking = true, Contrast2012 = true, Clarity2012 = true, Texture = true }
local function photo(overrides)
    local p = { format = 'RAW', snapshots = {}, snapshotsCreated = 0, patchCalls = 0,
        settings = { Exposure2012 = 2, Shadows2012 = 30, LuminanceSmoothing = 0,
            ColorNoiseReduction = 25, SharpenEdgeMasking = 0, Contrast2012 = 17,
            Clarity2012 = 0, Texture = 0, ProcessVersion = '15.4', CropTop = 0.2,
            Temperature = 5100, MaskGroupBasedCorrections = { { original = true } },
            LuminanceNoiseReductionDetail = 50, LuminanceNoiseReductionContrast = 0,
            ColorNoiseReductionDetail = 50, ColorNoiseReductionSmoothness = 50 } }
    for key, value in pairs(overrides or {}) do p[key] = value end
    function p:getDevelopSettings() return clone(self.settings) end
    function p:getDevelopSnapshots()
        if self.historyUnavailable then error('Snapshot history unavailable') end
        return clone(self.snapshots)
    end
    function p:getRawMetadata(key)
        if key == 'isoSpeedRating' then return 3250 end
        if key == 'fileFormat' then return self.format end
        error('Unsupported raw metadata key: ' .. tostring(key))
    end
    function p:getFormattedMetadata(key)
        if key == 'cameraMake' then return 'Test Make' end
        if key == 'cameraModel' then return 'Test Model' end
        if key == 'fileName' then return 'test.dng' end
        error('Unsupported formatted metadata key: ' .. tostring(key))
    end
    function p:createDevelopSnapshot(name, replace)
        equal(replace, false)
        self.snapshotsCreated = self.snapshotsCreated + 1
        self.snapshots[#self.snapshots + 1] = { name = name, settings = clone(self.settings) }
        return true
    end
    function p:applyDevelopSettings(patch, historyName)
        equal(historyName, 'Adaptive Noise Reduction')
        assert(self.snapshotsCreated > 0, 'Write must follow recovery snapshot')
        self.patchCalls = self.patchCalls + 1
        self.lastPatch = clone(patch)
        for key, value in pairs(patch) do
            assert(allowed[key], 'Unrelated develop setting in patch: ' .. tostring(key))
            self.settings[key] = value
        end
    end
    return p
end
local function profile(overrides)
    local c = Model.defaults()
    for key, value in pairs(overrides or {}) do c[key] = value end
    return c
end
local function planFor(p, opts, c)
    local input = Access.read(p)
    return Batch.plan({ { photo = p, input = input, name = Access.name(p) } },
        { [input.cameraKey] = c or profile() }, opts)
end
local function catalog(beforeGate)
    local c = { gates = 0 }
    function c:withWriteAccessDo(name, callback, opts)
        equal(name, 'Adaptive Noise Reduction'); equal(opts.asynchronous, false)
        self.gates = self.gates + 1
        if beforeGate then beforeGate() end
        callback()
        return 'executed'
    end
    return c
end
local function untouched(p)
    equal(p.snapshotsCreated, 0); equal(p.patchCalls, 0)
    equal(p.settings.LuminanceSmoothing, 0); equal(p.settings.ColorNoiseReduction, 25)
end
local function skipped(p, opts, reason)
    local plan = planFor(p, opts)
    equal(#plan.changes, 0); equal(plan.skipped, 1); equal(plan.reasons[reason], 1)
    local c = catalog()
    local result = Batch.apply(c, plan, nil, 'skip')
    equal(result.applied, 0); equal(result.failed, 0); equal(c.gates, 0)
    untouched(p)
end
local function aiFilter(filter)
    return { FilterList = { Filters = { filter } } }
end

test('all skip flags default to false and defaults are independent tables', function()
    local a, b = Skip.defaults(), Skip.defaults()
    equal(a.skipProcessed, false); equal(a.skipManualNR, false); equal(a.skipAIDenoise, false)
    a.skipProcessed = true; equal(b.skipProcessed, false)
    equal(Skip.reason({ processed = true, manualNR = 'adjusted', aiDenoise = 'applied' }), nil)
    equal(Skip.reason({ processed = 'unknown', manualNR = 'unknown', aiDenoise = 'unknown' }), nil)
end)
test('each enabled skip rule is independent of other disabled rules', function()
    local states = { processed = true, manualNR = 'adjusted', aiDenoise = 'applied' }
    equal(Skip.reason(states, options { skipProcessed = true }), reasons.processed)
    equal(Skip.reason(states, options { skipManualNR = true }), reasons.manual)
    equal(Skip.reason(states, options { skipAIDenoise = true }), reasons.ai)
    equal(Skip.reason({ processed = false, manualNR = 'adjusted', aiDenoise = 'applied' },
        options { skipProcessed = true }), nil)
    equal(Skip.reason({ processed = true, manualNR = 'default', aiDenoise = 'applied' },
        options { skipManualNR = true }), nil)
    equal(Skip.reason({ processed = true, manualNR = 'adjusted', aiDenoise = 'none' },
        options { skipAIDenoise = true }), nil)
end)
test('combined rules have stable processed then manual then AI precedence', function()
    local opts = options { skipProcessed = true, skipManualNR = true, skipAIDenoise = true }
    local states = { processed = true, manualNR = 'adjusted', aiDenoise = 'applied' }
    equal(Skip.reason(states, opts), reasons.processed)
    states.processed = 'unknown'; equal(Skip.reason(states, opts), reasons.history)
    states.processed = false; equal(Skip.reason(states, opts), reasons.manual)
    states.manualNR = 'unknown'; equal(Skip.reason(states, opts), reasons.manualUnknown)
    states.manualNR = 'default'; equal(Skip.reason(states, opts), reasons.ai)
    states.aiDenoise = 'unknown'; equal(Skip.reason(states, opts), reasons.aiUnknown)
    states.aiDenoise = 'none'; equal(Skip.reason(states, opts), nil)
end)
test('manual NR recognizes RAW DNG and non-RAW baseline amounts', function()
    local settings = { LuminanceSmoothing = 0, ColorNoiseReduction = 25 }
    equal(Skip.manualState(settings, 'RAW'), 'default')
    equal(Skip.manualState(settings, 'DNG'), 'default')
    equal(Skip.manualState(settings, 'JPG'), 'adjusted')
    settings.ColorNoiseReduction = 0
    equal(Skip.manualState(settings, 'JPG'), 'default')
    equal(Skip.manualState(settings, 'TIFF'), 'default')
    equal(Skip.manualState(settings, 'RAW'), 'adjusted')
    settings.LuminanceSmoothing = 1
    equal(Skip.manualState(settings, 'JPG'), 'adjusted')
end)
test('manual NR includes detail contrast and smoothness edits', function()
    local defaults = photo().settings
    for _, key in ipairs({ 'LuminanceNoiseReductionDetail', 'LuminanceNoiseReductionContrast',
        'ColorNoiseReductionDetail', 'ColorNoiseReductionSmoothness' }) do
        local changed = clone(defaults); changed[key] = changed[key] + 1
        equal(Skip.manualState(changed, 'RAW'), 'adjusted')
    end
    equal(Skip.manualState(defaults, 'RAW'), 'default')
end)
test('partial NR settings never guess missing amount values', function()
    equal(Skip.manualState({}, 'RAW'), 'unknown')
    equal(Skip.manualState({ LuminanceSmoothing = 0 }, 'RAW'), 'unknown')
    equal(Skip.manualState({ ColorNoiseReduction = 25 }, 'RAW'), 'unknown')
    equal(Skip.manualState({ LuminanceSmoothing = '0', ColorNoiseReduction = 25 }, 'RAW'), 'unknown')
    equal(Skip.reason({ manualNR = 'unknown' }, options { skipManualNR = true }), reasons.manualUnknown)
    equal(Skip.reason({ manualNR = 'adjusted' }, options { skipManualNR = false }), nil)
end)
test('AI detects legacy baked Denoise markers without depending on strength', function()
    for _, marker in ipairs({ true, 1, 'True', 'true' }) do
        equal(Skip.aiState { EnhanceDenoiseAlreadyApplied = marker }, 'applied')
    end
    for _, marker in ipairs({ false, 0, 'False', 'false' }) do
        equal(Skip.aiState { EnhanceDenoiseAlreadyApplied = marker }, 'none')
    end
    equal(Skip.aiState { DenoiseAmount = 75 }, 'none')
    equal(Skip.aiState { EnhanceDenoiseAmount = 75, DenoiseAmount = 0 }, 'none')
end)
test('AI detects modern FilterList denoise flags in nested and direct settings', function()
    for _, marker in ipairs({ true, 1, 'True', 'true' }) do
        equal(Skip.aiState(aiFilter { Name = 'Enhance', Settings = { Denoise = marker } }), 'applied')
        equal(Skip.aiState { FilterList = { { Name = 'enhance', Denoise = marker } } }, 'applied')
        equal(Skip.aiState(aiFilter { FilterID = 1, Settings = { denoise = marker } }), 'applied')
    end
    for _, marker in ipairs({ false, 0, 'False', 'false' }) do
        equal(Skip.aiState(aiFilter { Name = 'Enhance', Settings = { Denoise = marker } }), 'none')
    end
end)
test('AI recognizes compressed title tokens and conservatively skips opaque enhancements', function()
    equal(Skip.aiState(aiFilter { Name = 'Enhance', Settings = 'compressed',
        Title = 'Enhance/RawDetails=on/Denoise=50' }), 'applied')
    equal(Skip.aiState(aiFilter { FilterID = 1, Title = 'Denoise' }), 'applied')
    equal(Skip.aiState(aiFilter { Name = 'Enhance', Settings = 'compressed', Title = 'Ameliorer' }), 'unknown')
    equal(Skip.aiState(aiFilter { Name = 'Enhance', Settings = {} }), 'unknown')
    equal(Skip.aiState { FilterList = 'compressed' }, 'unknown')
    equal(Skip.aiState { FilterList = { Filters = 'compressed' } }, 'unknown')
    equal(Skip.reason({ aiDenoise = 'unknown' }, options { skipAIDenoise = true }), reasons.aiUnknown)
end)
test('AI unrelated filters and explicit false flags do not cause false positives', function()
    equal(Skip.aiState { FilterList = {} }, 'none')
    equal(Skip.aiState(aiFilter { Name = 'LensBlur', DenoiseAmount = 50 }), 'none')
    equal(Skip.aiState(aiFilter { Name = 'LocalCorrections', Settings = { Denoise = true } }), 'none')
    equal(Skip.aiState(aiFilter { Name = 'Enhance', Denoise = false,
        Title = 'Enhance/Denoise=old' }), 'none')
    equal(Skip.aiState { FilterList = { { Name = 'Enhance', Settings = {} },
        { Name = 'Enhance', Denoise = true } } }, 'applied')
end)
test('photo access reads persistent snapshots and all adjustment inputs', function()
    local p = photo(); local input = Access.read(p)
    equal(input.processed, false); equal(input.manualNR, 'default'); equal(input.aiDenoise, 'none')
    equal(input.mask, 0); equal(input.contrast, 17); equal(input.clarity, 0); equal(input.texture, 0)
    p.snapshots = { { name = 'User edit' }, { name = 'Before Adaptive Noise original-run' } }
    equal(Access.read(p).processed, true)
    p.snapshots = { { name = 'User Before Adaptive Noise original-run' } }
    equal(Access.read(p).processed, false)
    p.historyUnavailable = true; equal(Access.read(p).processed, 'unknown')
    untouched(p)
end)
test('default Batch options permit existing history manual NR and AI filters', function()
    local p = photo { snapshots = { { name = 'Before Adaptive Noise old' } } }
    p.settings.LuminanceSmoothing = 7
    p.settings.FilterList = { { Name = 'Enhance', Denoise = true } }
    local plan = planFor(p)
    equal(#plan.changes, 1); equal(plan.skipped, 0)
    equal(plan.options.skipProcessed, false); equal(plan.options.skipManualNR, false)
    equal(plan.options.skipAIDenoise, false)
    local result = Batch.apply(catalog(), plan, nil, 'all-off')
    equal(result.applied, 1); equal(result.protected, 0); equal(p.patchCalls, 1)
end)
test('processed option skips an existing snapshot without snapshot or write', function()
    skipped(photo { snapshots = { { name = 'Before Adaptive Noise v0.1' } } },
        options { skipProcessed = true }, reasons.processed)
end)
test('manual option skips detail edits independently of all other rules', function()
    local p = photo(); p.settings.ColorNoiseReductionDetail = 42
    skipped(p, options { skipManualNR = true }, reasons.manual)
end)
test('AI option skips legacy modern and unknown enhancements independently', function()
    local legacy = photo(); legacy.settings.EnhanceDenoiseAlreadyApplied = true
    skipped(legacy, options { skipAIDenoise = true }, reasons.ai)
    local modern = photo(); modern.settings.FilterList = { { Name = 'Enhance', Denoise = true } }
    skipped(modern, options { skipAIDenoise = true }, reasons.ai)
    local opaque = photo(); opaque.settings.FilterList = { { Name = 'Enhance', Settings = 'opaque' } }
    skipped(opaque, options { skipAIDenoise = true }, reasons.aiUnknown)
end)
test('unknown history fails closed only when processed protection is enabled', function()
    skipped(photo { historyUnavailable = true }, options { skipProcessed = true }, reasons.history)
    local p = photo { historyUnavailable = true }
    local plan = planFor(p, options { skipProcessed = false })
    equal(#plan.changes, 1)
    local result = Batch.apply(catalog(), plan, nil, 'history-off')
    equal(result.applied, 1); equal(result.protected, 0); equal(p.patchCalls, 1)
end)
test('combined Batch skip options preserve precedence without touching photos', function()
    local p = photo { snapshots = { { name = 'Before Adaptive Noise old' } } }
    p.settings.ColorNoiseReductionDetail = 42
    p.settings.EnhanceDenoiseAlreadyApplied = true
    skipped(p, options { skipProcessed = true, skipManualNR = true, skipAIDenoise = true }, reasons.processed)
end)
test('preview retains skip choices when the caller later changes its options', function()
    local opts = options { skipAIDenoise = true }
    local p = photo(); local plan = planFor(p, opts)
    opts.skipAIDenoise = false
    p.settings.EnhanceDenoiseAlreadyApplied = true
    local result = Batch.apply(catalog(), plan, nil, 'options-copy')
    equal(result.protected, 1); equal(result.applied, 0); untouched(p)
end)
test('AI appearing while waiting for the write gate is protected before any snapshot', function()
    local p = photo(); local plan = planFor(p, options { skipAIDenoise = true })
    equal(#plan.changes, 1)
    local result = Batch.apply(catalog(function()
        p.settings.FilterList = { { Name = 'Enhance', Denoise = true } }
    end), plan, nil, 'ai-race')
    equal(result.protected, 1); equal(result.applied, 0); equal(result.stale, 0)
    assert(result.details[1]:find(reasons.ai, 1, true)); untouched(p)
end)
test('snapshot appearing after preview is protected inside the write gate', function()
    local p = photo(); local plan = planFor(p, options { skipProcessed = true })
    local result = Batch.apply(catalog(function()
        p.snapshots[#p.snapshots + 1] = { name = 'Before Adaptive Noise concurrent-run' }
    end), plan, nil, 'history-race')
    equal(result.protected, 1); equal(result.applied, 0); equal(result.stale, 0)
    equal(#p.snapshots, 1); untouched(p)
end)
test('snapshot read failure after preview also protects without a guessed history', function()
    local p = photo(); local plan = planFor(p, options { skipProcessed = true })
    local result = Batch.apply(catalog(function() p.historyUnavailable = true end), plan, nil, 'history-failed')
    equal(result.protected, 1); equal(result.applied, 0)
    assert(result.details[1]:find(reasons.history, 1, true)); untouched(p)
end)
test('manual detail edits after preview are protected before the normal stale check', function()
    local p = photo(); local plan = planFor(p, options { skipManualNR = true })
    local result = Batch.apply(catalog(function()
        p.settings.LuminanceNoiseReductionDetail = 42
    end), plan, nil, 'manual-race')
    equal(result.protected, 1); equal(result.applied, 0); equal(result.stale, 0); untouched(p)
end)
test('six enabled controls write and verify only their targets with recovery snapshot', function()
    local p = photo(); local before = clone(p.settings)
    local c = profile { maskEnabled = true, maskLow = 10, maskHigh = 50,
        maskExposurePoints = 2, maskShadowPoints = 1,
        contrastEnabled = true, contrastLow = 40, contrastHigh = -80,
        contrastExposurePoints = -5, contrastShadowPoints = -2, contrastCap = 31.5,
        clarityEnabled = true, clarityLow = 80, clarityHigh = 60, clarityCap = 27.5,
        textureEnabled = true, textureLow = -40, textureHigh = -80, textureCap = 42.5 }
    local plan = planFor(p, options { skipProcessed = true, skipManualNR = true, skipAIDenoise = true }, c)
    equal(#plan.changes, 1)
    local expected = { LuminanceSmoothing = 38, ColorNoiseReduction = 33, SharpenEdgeMasking = 37,
        Contrast2012 = -31, Clarity2012 = 27, Texture = -42 }
    local result = Batch.apply(catalog(), plan, nil, 'six-controls')
    equal(result.applied, 1); equal(result.protected, 0); equal(result.unverified, 0)
    equal(p.snapshotsCreated, 1); equal(p.patchCalls, 1)
    local count = 0
    for key, value in pairs(p.lastPatch) do equal(value, expected[key]); count = count + 1 end
    equal(count, 6)
    for key, value in pairs(expected) do equal(p.settings[key], value) end
    equal(p.settings.CropTop, before.CropTop); equal(p.settings.Temperature, before.Temperature)
    equal(p.settings.ProcessVersion, before.ProcessVersion)
    equal(p.settings.MaskGroupBasedCorrections[1].original, true)
    equal(p.snapshots[1].settings.LuminanceSmoothing, 0)
    equal(p.snapshots[1].settings.Contrast2012, 17)
    equal(Access.read(p).processed, true)
    equal(planFor(p, options { skipProcessed = true }, c).reasons[reasons.processed], 1)
end)
test('every extra slider changed after preview is stale and receives no snapshot', function()
    for _, control in ipairs(Model.extraControls()) do
        local p = photo(); local plan = planFor(p)
        p.settings[control.setting] = p.settings[control.setting] + 1
        local result = Batch.apply(catalog(), plan, nil, 'stale-' .. control.id)
        equal(result.stale, 1); equal(result.applied, 0); equal(result.protected, 0); untouched(p)
    end
end)

test('Lightroom 15.6 runtime shape distinguishes active Denoise from remembered amount', function()
    -- Sanitized structure observed on a private DNG; no image data or source hashes.
    local settings = { FilterList = { Filters = { {
        Name = 'Enhance', FilterID = 1,
        Title = '$$$/CRaw/Filter/Title/Denoise=Denoise',
        CompressedSettings = 'synthetic-placeholder',
        Table_synthetic_placeholder = 'opaque fixture payload',
    } } } }
    equal(Skip.aiState(settings), 'applied')
    settings.FilterList = {}
    settings.DenoiseAmount = 20
    equal(Skip.aiState(settings), 'none')
    equal(Skip.aiState({ FilterList = { Filters = { 'unrecognized entry' } } }), 'unknown')
end)

print(string.format('\n%d skip-policy/integration tests passed under %s', passed, _VERSION))
