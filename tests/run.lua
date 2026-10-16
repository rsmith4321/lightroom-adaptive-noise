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
        shadows = 0, luminance = 0, color = 25, processVersion = '15.4' }
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
            assert(k == 'LuminanceSmoothing' or k == 'ColorNoiseReduction', 'Unrelated setting in patch')
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
end)
test('original screenshot settings can be reproduced', function()
    local c = config { luminanceHigh = 40, luminanceCap = 40, exposurePoints = 5, shadowPoints = 1 }
    equal(Model.calculate(sample { iso = 3250, exposure = 2, shadows = 30 }, c).LuminanceSmoothing, 33)
end)
print(string.format('\n%d tests passed under %s', passed, _VERSION))
