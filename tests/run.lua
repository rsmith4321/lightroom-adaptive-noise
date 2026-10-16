-- Run from the repository root with Lua 5.1 or later: lua tests/run.lua
_PLUGIN = { path = 'AdaptiveNoise.lrplugin' }
local Tasks = { pcall = pcall, sleep = function() end, yield = function() end }
function import(name)
    assert(name == 'LrTasks', 'Unexpected import: ' .. name)
    return Tasks
end
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Batch = dofile(_PLUGIN.path .. '/Batch.lua')
local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then io.stderr:write('FAIL: ' .. name .. '\n' .. tostring(err) .. '\n'); os.exit(1) end
    passed = passed + 1
    print('PASS: ' .. name)
end
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function sample(overrides)
    local p = { cameraKey = 'test', format = 'RAW', iso = 3250, exposure = 0,
        shadows = 0, luminance = 0, color = 25, mask = 0, contrast = 17,
        clarity = 0, texture = 0, processVersion = '15.4' }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end
local function config(overrides)
    local c = Model.defaults()
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end
local function mockPhoto(overrides)
    local photo = { settings = {
        Exposure2012 = 2, Shadows2012 = 30, LuminanceSmoothing = 0,
        ColorNoiseReduction = 25, ProcessVersion = '15.4',
        CropTop = 0.2, Temperature = 5100, Contrast2012 = 17,
        SharpenEdgeMasking = 0, Clarity2012 = 0, Texture = 0,
        Masking = { original = true },
    }, snapshots = {}, patchCalls = 0 }
    for k, v in pairs(overrides or {}) do photo[k] = v end
    function photo:getDevelopSettings() return self.settings end
    function photo:getFormattedMetadata(key)
        if key == 'cameraMake' then return 'Test Make' end
        if key == 'cameraModel' then return 'Test Model' end
        if key == 'fileName' then return 'test.dng' end
        error('Unexpected formatted metadata key: ' .. key)
    end
    function photo:getRawMetadata(key)
        if key == 'isoSpeedRating' then return 3250 end
        if key == 'fileFormat' then return 'RAW' end
        error('Unexpected raw metadata key: ' .. key)
    end
    function photo:createDevelopSnapshot(name, replace)
        equal(replace, false)
        if self.snapshotFail then return false end
        local before = {}
        for k, v in pairs(self.settings) do before[k] = v end
        self.snapshots[name] = before
        return true
    end
    function photo:applyDevelopSettings(patch, historyName)
        equal(historyName, 'Adaptive Noise Reduction')
        self.patchCalls = self.patchCalls + 1
        assert(next(self.snapshots), 'Must snapshot before applying')
        for k, v in pairs(patch) do
            assert(k == 'LuminanceSmoothing' or k == 'ColorNoiseReduction'
                or k == 'SharpenEdgeMasking' or k == 'Contrast2012'
                or k == 'Clarity2012' or k == 'Texture', 'Unrelated setting in patch')
            if not self.ignoreWrite then self.settings[k] = v end
        end
        if self.throwAfterWrite then error('Simulated write exception') end
    end
    return photo
end
local function catalog(abort)
    return { withWriteAccessDo = function(_, name, fn, options)
        equal(name, 'Adaptive Noise Reduction'); equal(options.asynchronous, false)
        if abort then return 'aborted' end
        fn(); return 'executed'
    end }
end
local function planPhoto(photo, c)
    local input = Access.read(photo)
    return Batch.plan({ { photo = photo, input = input, name = Access.name(photo) } },
        { [input.cameraKey] = c or config() })
end

test('linear midpoint and two-key whitelist', function()
    local p = assert(Model.calculate(sample(), config()))
    equal(p.LuminanceSmoothing, 25); equal(p.ColorNoiseReduction, 33)
    for k in pairs(p) do assert(k == 'LuminanceSmoothing' or k == 'ColorNoiseReduction') end
end)
test('exposure and shadows add to target, not current NR', function()
    local p = Model.calculate(sample { exposure = 2, shadows = 30, luminance = 7 }, config())
    equal(p.LuminanceSmoothing, 38)
end)
test('negative exposure and shadows add nothing', function()
    equal(Model.calculate(sample { exposure = -4, shadows = -100 }, config()).LuminanceSmoothing, 25)
end)
test('ISO endpoints clamp independently of final cap', function()
    equal(Model.calculate(sample { iso = 50, exposure = 2 }, config()).LuminanceSmoothing, 10)
    equal(Model.calculate(sample { iso = 25600, exposure = 2 }, config()).LuminanceSmoothing, 60)
end)
test('final cap applies after bonuses', function()
    equal(Model.calculate(sample { iso = 6400, exposure = 5, shadows = 100 }, config { luminanceCap = 40 }).LuminanceSmoothing, 40)
end)
test('integer sliders never exceed fractional caps', function()
    local p = Model.calculate(sample { iso = 6400, exposure = 5 }, config { luminanceCap = 40.5, colorCap = 32.5 })
    equal(p.LuminanceSmoothing, 40); equal(p.ColorNoiseReduction, 32)
end)
test('second run is a no-op', function()
    local input = sample { exposure = 2, shadows = 30 }
    local p = Model.calculate(input, config())
    input.luminance = p.LuminanceSmoothing; input.color = p.ColorNoiseReduction
    local patch, why = Model.calculate(input, config())
    equal(next(patch), nil); equal(why, 'Already matches')
end)
test('RAW and DNG included; JPG requires opt-in', function()
    assert(Model.calculate(sample { format = 'DNG' }, config()))
    local p, why = Model.calculate(sample { format = 'JPG' }, config())
    equal(p, nil); equal(why, 'Non-RAW disabled')
    assert(Model.calculate(sample { format = 'JPG' }, config { includeNonRaw = true }))
end)
test('video always excluded', function()
    local p, why = Model.calculate(sample { format = 'VIDEO' }, config { includeNonRaw = true })
    equal(p, nil); equal(why, 'Video')
end)
test('missing ISO skipped; no guessed settings', function()
    local input = sample(); input.iso = nil
    local p, why = Model.calculate(input, config()); equal(p, nil); equal(why, 'Missing or invalid ISO')
end)
test('non-finite and invalid configuration rejected', function()
    for _, c in ipairs({ config { isoLow = 6400 }, config { isoHigh = 0/0 }, config { exposurePoints = math.huge }, config { luminanceHigh = 101 } }) do
        equal(Model.validate(c), nil)
    end
end)
test('color-only does not need exposure or shadows', function()
    local input = sample(); input.exposure = nil; input.shadows = nil
    local p = assert(Model.calculate(input, config { luminanceEnabled = false }))
    equal(p.ColorNoiseReduction, 33); equal(p.LuminanceSmoothing, nil)
end)
test('missing shadow input only matters with enabled shadow bonus', function()
    local input = sample(); input.shadows = nil
    equal(Model.calculate(input, config()), nil)
    assert(Model.calculate(input, config { shadowPoints = 0 }))
end)
test('log scale midpoint uses stops', function()
    equal(Model.calculate(sample { iso = 800 }, config { logarithmic = true }).LuminanceSmoothing, 25)
end)
test('extra adjustment defaults preserve the original NR behavior', function()
    local c = config()
    for _, control in ipairs(Model.extraControls()) do
        local id = control.id
        equal(c[id .. 'Enabled'], false)
        equal(c[id .. 'Low'], 0); equal(c[id .. 'High'], 0); equal(c[id .. 'Cap'], 100)
        equal(c[id .. 'ExposurePoints'], 0); equal(c[id .. 'ShadowPoints'], 0)
    end
    equal(c.luminanceLow, 0); equal(c.luminanceHigh, 50); equal(c.exposurePoints, 5)
    equal(c.shadowPoints, 1); equal(c.colorLow, 25); equal(c.colorHigh, 40)
end)
test('extra adjustments work when both NR controls are disabled', function()
    local p = assert(Model.calculate(sample(), config {
        luminanceEnabled = false, colorEnabled = false, maskEnabled = true,
        maskLow = 10, maskHigh = 70,
    }))
    equal(p.SharpenEdgeMasking, 40); equal(p.LuminanceSmoothing, nil); equal(p.ColorNoiseReduction, nil)
end)
test('signed targets allow negative values and decreasing ISO curves', function()
    local c = config { luminanceEnabled = false, colorEnabled = false,
        contrastEnabled = true, contrastLow = 40, contrastHigh = -80,
        clarityEnabled = true, clarityLow = -80, clarityHigh = -40,
        textureEnabled = true, textureLow = 50, textureHigh = -50 }
    local p = assert(Model.calculate(sample(), c))
    equal(p.Contrast2012, -20); equal(p.Clarity2012, -60); equal(p.Texture, nil)
    p = assert(Model.calculate(sample { iso = 25600 }, c))
    equal(p.Contrast2012, -80); equal(p.Clarity2012, -40); equal(p.Texture, -50)
    p = assert(Model.calculate(sample { iso = 50 }, c))
    equal(p.Contrast2012, 40); equal(p.Clarity2012, -80); equal(p.Texture, 50)
end)
test('signed coefficients use positive exposure and shadows to form fresh targets', function()
    local c = config { luminanceEnabled = false, colorEnabled = false,
        contrastEnabled = true, contrastLow = 40, contrastHigh = 0,
        contrastExposurePoints = -5, contrastShadowPoints = -2,
        clarityEnabled = true, clarityExposurePoints = 4, clarityShadowPoints = -3 }
    local input = sample { exposure = 2, shadows = 30, contrast = 88, clarity = -70 }
    local p = assert(Model.calculate(input, c))
    equal(p.Contrast2012, 4); equal(p.Clarity2012, -1)
    input.contrast, input.clarity = p.Contrast2012, p.Clarity2012
    local again = assert(Model.calculate(input, c))
    equal(next(again), nil)
    p = assert(Model.calculate(sample { exposure = -2, shadows = -30 }, c))
    equal(p.Contrast2012, 20); equal(p.Clarity2012, nil)
end)
test('extra caps limit positive and negative magnitude after bonuses', function()
    local p = assert(Model.calculate(sample { exposure = 5, shadows = 100 }, config {
        maskEnabled = true, maskLow = 10, maskHigh = 50, maskCap = 45.5,
        maskExposurePoints = 10, maskShadowPoints = 2,
        contrastEnabled = true, contrastExposurePoints = -20, contrastCap = 31.5,
        clarityEnabled = true, clarityExposurePoints = 20, clarityCap = 27.5,
        textureEnabled = true, textureHigh = -100, textureCap = 0,
    }))
    equal(p.SharpenEdgeMasking, 45); equal(p.Contrast2012, -31); equal(p.Clarity2012, 27)
    equal(p.Texture, nil)
end)
test('extra adjustments use the shared logarithmic ISO interpolation', function()
    local p = assert(Model.calculate(sample { iso = 800 }, config {
        logarithmic = true, maskEnabled = true, maskLow = 20, maskHigh = 80,
        contrastEnabled = true, contrastLow = 80, contrastHigh = -40,
    }))
    equal(p.SharpenEdgeMasking, 50); equal(p.Contrast2012, 20)
end)
test('disabled extra controls are never added to the patch', function()
    local input = sample { mask = 99, contrast = -55, clarity = -45, texture = 85 }
    local p = assert(Model.calculate(input, config {
        maskLow = 20, maskHigh = 80, contrastLow = -20, contrastHigh = 40,
        clarityLow = -50, clarityHigh = 30, textureLow = -90, textureHigh = -80,
    }))
    equal(p.SharpenEdgeMasking, nil); equal(p.Contrast2012, nil)
    equal(p.Clarity2012, nil); equal(p.Texture, nil)
end)
test('unavailable enabled extra adjustment skips the whole photo', function()
    for _, control in ipairs(Model.extraControls()) do
        for _, bad in ipairs({ false, 0/0, math.huge }) do
            local input = sample(); input[control.id] = bad
            local p, why = Model.calculate(input, config { [control.id .. 'Enabled'] = true })
            equal(p, nil); equal(why, control.label .. ' control unavailable')
        end
        local input = sample(); input[control.id] = nil
        equal(Model.calculate(input, config { [control.id .. 'Enabled'] = true }), nil)
    end
end)
test('signed nonzero coefficients require their exposure and shadows inputs', function()
    local input = sample(); input.exposure = nil; input.shadows = nil
    local c = config { luminanceEnabled = false, colorEnabled = false, contrastEnabled = true,
        contrastLow = -10, contrastHigh = -30 }
    equal(assert(Model.calculate(input, c)).Contrast2012, -20)
    c.contrastExposurePoints = -1
    local p, why = Model.calculate(input, c); equal(p, nil); equal(why, 'Exposure setting unavailable')
    c.contrastExposurePoints = 0; c.contrastShadowPoints = -1
    p, why = Model.calculate(input, c); equal(p, nil); equal(why, 'Shadows setting unavailable')
end)
test('extra profile fields validate ranges, booleans, and finite values', function()
    for _, control in ipairs(Model.extraControls()) do
        for _, suffix in ipairs({ 'Low', 'High', 'Cap', 'ExposurePoints', 'ShadowPoints' }) do
            for _, invalid in ipairs({ 101, -101, math.huge, 0/0, '10' }) do
                equal(Model.validate(config { [control.id .. suffix] = invalid }), nil)
            end
            local c = config(); c[control.id .. suffix] = nil
            equal(Model.validate(c), nil)
        end
        equal(Model.validate(config { [control.id .. 'Enabled'] = 1 }), nil)
        equal(Model.validate(config { [control.id .. 'Cap'] = -1 }), nil)
    end
    equal(Model.validate(config { maskLow = 50, maskHigh = 20 }), nil)
    equal(Model.validate(config { maskExposurePoints = -1 }), nil)
    equal(Model.validate(config { maskShadowPoints = -1 }), nil)
    assert(Model.validate(config { contrastLow = 100, contrastHigh = -100,
        clarityExposurePoints = -100, textureShadowPoints = -100 }))
end)
test('mixed adjustments produce only the six whitelisted develop keys', function()
    local p = assert(Model.calculate(sample(), config {
        maskEnabled = true, maskHigh = 80, contrastEnabled = true, contrastHigh = -60,
        clarityEnabled = true, clarityHigh = 60, textureEnabled = true, textureHigh = -80,
    }))
    local allowed = { LuminanceSmoothing = true, ColorNoiseReduction = true,
        SharpenEdgeMasking = true, Contrast2012 = true, Clarity2012 = true, Texture = true }
    local count = 0
    for key in pairs(p) do assert(allowed[key], 'Unexpected develop key ' .. key); count = count + 1 end
    equal(count, 6)
end)
test('changes to every extra preview input are stale', function()
    for _, control in ipairs(Model.extraControls()) do
        local before, after = sample(), sample()
        assert(Model.sameInputs(before, after))
        after[control.id] = after[control.id] + 1
        equal(Model.sameInputs(before, after), false)
    end
end)
test('camera keys do not collide', function()
    assert(Model.cameraKey('ab', 'c') ~= Model.cameraKey('a', 'bc'))
    equal(Model.cameraKey('', ''), nil)
end)
test('access uses correct metadata APIs', function()
    local input = Access.read(mockPhoto())
    equal(input.cameraMake, 'Test Make'); equal(input.cameraModel, 'Test Model'); equal(input.iso, 3250)
end)
test('preview never writes', function()
    local photo = mockPhoto(); local plan = planPhoto(photo)
    equal(#plan.changes, 1); equal(photo.patchCalls, 0); equal(next(photo.snapshots), nil)
end)
test('write verifies two NR values and preserves other edits', function()
    local photo = mockPhoto(); local masks = photo.settings.Masking
    local result = Batch.apply(catalog(), planPhoto(photo), nil, 'test')
    equal(result.applied, 1); equal(photo.settings.LuminanceSmoothing, 38)
    equal(photo.settings.ColorNoiseReduction, 33); equal(photo.settings.CropTop, 0.2)
    equal(photo.settings.Temperature, 5100); equal(photo.settings.Masking, masks)
    equal(photo.settings.Contrast2012, 17); equal(photo.settings.ProcessVersion, '15.4')
    equal(photo.snapshots['Before Adaptive Noise test'].LuminanceSmoothing, 0)
end)
test('stale preview skips write and snapshot', function()
    local photo = mockPhoto(); local plan = planPhoto(photo); photo.settings.Exposure2012 = 3
    local result = Batch.apply(catalog(), plan, nil, 'test')
    equal(result.stale, 1); equal(photo.patchCalls, 0); equal(next(photo.snapshots), nil)
end)
test('snapshot failure blocks adjustment', function()
    local photo = mockPhoto { snapshotFail = true }
    local result = Batch.apply(catalog(), planPhoto(photo), nil, 'test')
    equal(result.failed, 1); equal(photo.patchCalls, 0)
end)
test('busy catalog does not claim success', function()
    local photo = mockPhoto()
    local result = Batch.apply(catalog(true), planPhoto(photo), nil, 'test')
    equal(result.failed, 1); equal(result.applied, 0); equal(photo.patchCalls, 0)
end)
test('Cancel during catalog wait prevents the pending photo and remaining batch', function()
    local first, second = mockPhoto(), mockPhoto()
    local plan = planPhoto(first)
    plan.changes[2] = planPhoto(second).changes[1]
    local cancelled, done, gates = false, false, 0
    local waitingCatalog = { withWriteAccessDo = function(_, _, callback)
        gates = gates + 1
        cancelled = true -- User clicked Cancel while another operation held the gate.
        callback()
        return 'executed'
    end }
    local progress = { isCanceled = function() return cancelled end,
        setCaption = function() end, setPortionComplete = function() end,
        done = function() done = true end }
    local result = Batch.apply(waitingCatalog, plan, progress, 'cancel-wait')
    equal(result.cancelled, 2); equal(result.applied, 0); equal(gates, 1)
    equal(first.patchCalls, 0); equal(second.patchCalls, 0)
    equal(next(first.snapshots), nil); equal(next(second.snapshots), nil); assert(done)
end)
test('exception during a partial SDK write is unverified and retains recovery snapshot', function()
    local photo = mockPhoto { throwAfterWrite = true }
    local result = Batch.apply(catalog(), planPhoto(photo), nil, 'partial-write')
    equal(result.unverified, 1); equal(result.failed, 0); equal(result.applied, 0)
    equal(photo.settings.LuminanceSmoothing, 38)
    equal(photo.snapshots['Before Adaptive Noise partial-write'].LuminanceSmoothing, 0)
end)
test('readback exception after write is unverified', function()
    local photo = mockPhoto()
    local plan = planPhoto(photo)
    function photo:getDevelopSettings()
        if self.patchCalls > 0 then error('Readback unavailable') end
        return self.settings
    end
    local result = Batch.apply(catalog(), plan, nil, 'readback-error')
    equal(result.unverified, 1); equal(result.failed, 0); equal(result.applied, 0)
end)
test('mixed batch continues after failed and uncertain photos with accurate totals', function()
    local photos = { mockPhoto { snapshotFail = true }, mockPhoto { throwAfterWrite = true }, mockPhoto() }
    local plan = { changes = {} }
    for i, photo in ipairs(photos) do plan.changes[i] = planPhoto(photo).changes[1] end
    local result = Batch.apply(catalog(), plan, nil, 'mixed')
    equal(result.failed, 1); equal(result.unverified, 1); equal(result.applied, 1)
    equal(photos[1].patchCalls, 0); equal(photos[3].settings.LuminanceSmoothing, 38)
end)
test('unconfirmed readback is reported separately', function()
    local photo = mockPhoto { ignoreWrite = true }
    local result = Batch.apply(catalog(), planPhoto(photo), nil, 'test')
    equal(result.unverified, 1); equal(result.applied, 0); equal(result.failed, 0)
end)
test('cancellation does not touch remaining photos', function()
    local photo = mockPhoto()
    local result = Batch.apply(catalog(), planPhoto(photo), { isCanceled = function() return true end, done = function() end }, 'test')
    equal(result.cancelled, 1); equal(photo.patchCalls, 0)
end)
test('disabled and unreadable photos have explicit skip reasons', function()
    local photo = mockPhoto(); local plan = planPhoto(photo, config { enabled = false })
    equal(plan.skipped, 1); equal(plan.reasons['Camera profile disabled'], 1)
    plan = Batch.plan({ { input = {}, error = 'Could not read develop settings' } }, {})
    equal(plan.reasons['Could not read develop settings'], 1)
    plan = planPhoto(photo, config { luminanceEnabled = false, colorEnabled = false })
    equal(plan.skipped, 1); equal(plan.unchanged, 0)
    equal(plan.reasons['All adjustment controls disabled'], 1)
end)
test('original screenshot settings can be reproduced', function()
    local c = config { luminanceHigh = 40, luminanceCap = 40, exposurePoints = 5, shadowPoints = 1 }
    equal(Model.calculate(sample { iso = 3250, exposure = 2, shadows = 30 }, c).LuminanceSmoothing, 33)
end)
print(string.format('\n%d tests passed under %s', passed, _VERSION))
