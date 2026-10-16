-- Run from the repository root: lua5.1 tests/main_workflow.lua
-- Drives the real Main.lua dialogs and Batch.lua through in-memory SDK doubles.
-- No Lightroom application, catalog, preferences, or filesystem operations occur.
local pluginPath = (arg and arg[1]) or 'AdaptiveNoise.lrplugin'
local passed = 0

local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function visit(node, callback)
    if type(node) ~= 'table' then return end
    callback(node)
    for _, child in ipairs(node) do visit(child, callback) end
end

local function run(options)
    options = options or {}
    local savedPlugin, savedImport = _PLUGIN, import
    local state = { events = {}, snapshots = 0, writes = 0, gates = 0,
        targetPhotosCalls = 0, dialogs = 0, messages = {}, prefs = {},
        photos = {}, inWrite = false, inTask = false, readbacks = 0, settingsDialogs = 0 }
    if options.savedProfiles ~= nil then state.prefs.profilesV1 = options.savedProfiles end
    local function event(name) state.events[#state.events + 1] = name end
    local function photo(camera, filename)
        local result = { settings = { Exposure2012 = 2, Shadows2012 = 30,
            LuminanceSmoothing = 0, ColorNoiseReduction = 25, ProcessVersion = '15.4',
            CropTop = 0.2, Contrast2012 = 19, Temperature = 5100,
            MaskGroupBasedCorrections = { { preserved = true } } }, snapshots = {} }
        function result:getDevelopSettings()
            assert(state.inTask, 'Develop read escaped async task')
            if self.wasWritten and not state.inWrite then state.readbacks = state.readbacks + 1 end
            return clone(self.settings)
        end
        function result:getFormattedMetadata(key)
            assert(state.inTask, 'Metadata read escaped async task')
            if key == 'cameraMake' then return camera end
            if key == 'cameraModel' then return 'Test Camera' end
            if key == 'fileName' then
                if options.nameError then error('Filename temporarily unavailable') end
                return filename
            end
            error('Unsupported formatted key: ' .. tostring(key))
        end
        function result:getRawMetadata(key)
            assert(state.inTask, 'Metadata read escaped async task')
            if key == 'isoSpeedRating' then return 3250 end
            if key == 'fileFormat' then return 'RAW' end
            error('Unsupported raw key: ' .. tostring(key))
        end
        function result:createDevelopSnapshot(name, replace)
            assert(state.inWrite, 'Snapshot escaped write gate')
            assert(state.applyApproved, 'Snapshot occurred before Process approval')
            assert(replace == false, 'Existing snapshots may not be replaced')
            self.snapshots[name] = clone(self.settings)
            state.snapshots = state.snapshots + 1; event('snapshot')
            return true
        end
        function result:applyDevelopSettings(patch, history, flattenAutoNow)
            assert(state.inWrite and state.applyApproved, 'Photo write occurred before final Apply')
            assert(next(self.snapshots), 'Photo write preceded recovery snapshot')
            assert(history == 'Adaptive Noise Reduction' and flattenAutoNow == nil,
                'Unexpected history name or synchronous Auto flattening')
            local keys = 0
            for key, value in pairs(patch) do
                assert(key == 'LuminanceSmoothing' or key == 'ColorNoiseReduction',
                    'Unrelated adjustment in patch: ' .. tostring(key))
                self.settings[key] = value; keys = keys + 1
            end
            assert(keys > 0, 'Empty photo write')
            self.wasWritten = true
            state.writes = state.writes + 1; event('patch')
        end
        return result
    end
    state.photos[1] = photo('Alpha', 'alpha-test.dng')
    if options.twoCameras then state.photos[2] = photo('Beta', 'beta-test.dng') end
    local originalSettings = {}
    for i, item in ipairs(state.photos) do originalSettings[i] = clone(item.settings) end

    local catalog = {}
    function catalog:getTargetPhoto() return not options.noSelection and state.photos[1] or nil end
    function catalog:getTargetPhotos()
        state.targetPhotosCalls = state.targetPhotosCalls + 1
        assert(not options.noSelection, 'Empty selection expanded into whole filmstrip')
        return state.photos
    end
    function catalog:withWriteAccessDo(name, callback, timeout)
        assert(state.applyApproved, 'Catalog write gate preceded Process approval')
        assert(not state.inWrite, 'Nested write gate')
        assert(type(name) == 'string' and timeout.timeout > 0 and timeout.asynchronous == false,
            'Write gate must name operation, timeout, and wait for completion')
        state.gates = state.gates + 1; state.inWrite = true; event('gate-open')
        local ok, message = pcall(callback)
        state.inWrite = false; event('gate-close')
        if not ok then error(message, 0) end
        return 'executed'
    end

    local factory = {}
    for _, kind in ipairs({ 'column', 'row', 'static_text', 'popup_menu',
        'checkbox', 'separator', 'edit_field', 'scrolled_view' }) do
        factory[kind] = function(_, specification)
            assert(specification.read_only == nil, 'Undocumented read_only property returned')
            specification.kind = kind
            return specification
        end
    end
    local function properties()
        local values, observers = {}, {}
        local methods = { addObserver = function(_, key, callback) observers[key] = callback end }
        return setmetatable({}, {
            __index = function(_, key) return methods[key] or values[key] end,
            __newindex = function(proxy, key, value)
                local changed = values[key] ~= value
                values[key] = value
                if changed and observers[key] then observers[key](proxy, key, value) end
            end,
        })
    end

    local modules = {
        LrApplication = { activeCatalog = function() return catalog end },
        LrBinding = { makePropertyTable = properties },
        LrFunctionContext = { callWithContext = function(_, callback) return callback({}) end },
        LrPrefs = { prefsForPlugin = function() return state.prefs end },
        LrProgressScope = function()
            return { isCanceled = function() return false end, done = function() end,
                setPortionComplete = function() end, setCaption = function() end }
        end,
        LrTasks = { pcall = pcall, sleep = function() end, yield = function() end,
            startAsyncTask = function(callback)
                state.inTask = true
                local ok, message = pcall(callback); state.inTask = false
                if not ok then error(message, 0) end
            end },
        LrView = { osFactory = function() return factory end,
            bind = function(key) return { bindingKey = key } end },
        LrDate = { currentTime = function() return 1234567.123456 end },
    }
    modules.LrDialogs = {
        attachErrorDialogToFunctionContext = function() end,
        message = function(title, text, style)
            state.messages[#state.messages + 1] = { title = title, text = text, style = style }
        end,
        presentModalDialog = function(dialog)
            state.dialogs = state.dialogs + 1
            assert(state.writes == 0 and state.snapshots == 0 and state.gates == 0,
                'Photo mutation occurred while user was reviewing dialogs')
            if dialog.title == 'Adaptive Noise Reduction' then
                state.settingsDialogs = state.settingsDialogs + 1
                state.settingsDialog = dialog
                state.props = dialog.contents.bind_to_object
                visit(dialog.contents, function(control)
                    if control.kind == 'edit_field' then
                        assert(control.immediate == true,
                            'Numeric edit may retain old value when Preview/camera is clicked on macOS')
                        local key = control.value.bindingKey
                        if key == 'isoLow' or key == 'isoHigh' then
                            assert(control.min == 1 and control.max == 10000000, 'ISO entry was limited by native 0-100 default')
                        elseif key:match('^contrast') or key:match('^clarity') or key:match('^texture') then
                            assert(control.min == (key:match('Cap$') and 0 or -100) and control.max == 100,
                                'Signed adjustment entry rejected negative targets')
                        else assert(control.min == 0 and control.max == 100) end
                    end
                end)
                if options.editSettings then options.editSettings(state, dialog) end
                assert(dialog.actionVerb == 'Process' and dialog.otherVerb == 'Preview', 'Missing Process/Preview buttons')
                if options.cancelSettings or options.cancelSettingsAfter == state.settingsDialogs then return 'cancel' end
                if options.directProcess then
                    state.applyApproved = true; event('apply-approved')
                    return 'ok'
                end
                return 'other'
            end
            assert(not state.previewDialog, 'Unexpected extra preview dialog')
            assert(dialog.actionVerb == 'Process', 'Preview must offer Process')
            state.previewDialog = dialog
            if options.beforePreviewDecision then options.beforePreviewDecision(state) end
            if options.cancelPreview then return 'cancel' end
            state.applyApproved = true; event('apply-approved')
            return 'ok'
        end,
    }
    _PLUGIN = { path = pluginPath }
    function import(name) return assert(modules[name], 'Unexpected SDK import: ' .. name) end
    local ok, message = pcall(function() dofile(pluginPath .. '/Main.lua') end)
    _PLUGIN, import = savedPlugin, savedImport
    if not ok then error(message, 0) end
    state.originalSettings = originalSettings
    return state
end

local function test(name, callback)
    local ok, message = pcall(callback)
    if not ok then io.stderr:write('FAIL: ', name, '\n', tostring(message), '\n'); os.exit(1) end
    passed = passed + 1; print('PASS: ' .. name)
end

local function unchanged(state)
    assert(state.gates == 0 and state.snapshots == 0 and state.writes == 0,
        'Cancellation/empty selection mutated photos')
end

test('no selection never requests whole-filmstrip target photos', function()
    local state = run { noSelection = true }
    assert(state.targetPhotosCalls == 0 and state.dialogs == 0)
    assert(#state.messages == 1 and state.messages[1].text:find('Select the photos', 1, true))
    unchanged(state)
end)

test('Cancel in settings opens no preview and performs no photo writes', function()
    local state = run { cancelSettings = true }
    assert(state.dialogs == 1 and state.prefs.profilesV1 == nil)
    unchanged(state)
end)

test('Cancel in preview leaves every photo and snapshot untouched', function()
    local state = run { cancelPreview = true }
    assert(state.dialogs == 2)
    local foundFile = false
    visit(state.previewDialog.contents, function(control)
        if type(control.title) == 'string' and control.title:find('alpha-test.dng', 1, true) then foundFile = true end
    end)
    assert(foundFile, 'Preview did not identify planned photo')
    unchanged(state)
end)

test('final Apply snapshots, uses narrow patches, reads back, and preserves unrelated edits', function()
    local state = run()
    assert(state.writes == 1 and state.snapshots == 1 and state.readbacks >= 1)
    assert(state.events[1] == 'apply-approved' and state.events[2] == 'gate-open'
        and state.events[3] == 'snapshot' and state.events[4] == 'patch'
        and state.events[5] == 'gate-close', 'Write/snapshot ordering changed')
    local photo, before = state.photos[1], state.originalSettings[1]
    for _, key in ipairs({ 'CropTop', 'Contrast2012', 'Temperature', 'Exposure2012', 'Shadows2012', 'ProcessVersion' }) do
        assert(photo.settings[key] == before[key], 'Unrelated edit changed: ' .. key)
    end
    assert(photo.settings.MaskGroupBasedCorrections[1].preserved == true)
    local snapshot = assert(photo.snapshots[next(photo.snapshots)])
    assert(snapshot.LuminanceSmoothing == before.LuminanceSmoothing
        and snapshot.ColorNoiseReduction == before.ColorNoiseReduction)
    assert(state.messages[#state.messages].text:find('1 change confirmed', 1, true), 'Missing verified result')
end)

test('primary Process applies directly with snapshot and readback, without a preview dialog', function()
    local state = run { directProcess = true }
    assert(state.dialogs == 1 and not state.previewDialog)
    assert(state.writes == 1 and state.snapshots == 1 and state.readbacks >= 1)
    assert(state.events[1] == 'apply-approved' and state.events[3] == 'snapshot'
        and state.events[4] == 'patch')
end)

test('Process validates settings before any catalog write', function()
    local state = run { directProcess = true, cancelSettingsAfter = 2,
        editSettings = function(s) s.props.isoHigh = 0 end }
    unchanged(state)
    assert(state.settingsDialogs == 2 and not state.previewDialog and #state.messages == 1)
end)

test('Process with all controls disabled reports no changes without opening a preview', function()
    local state = run { directProcess = true, editSettings = function(s)
        s.props.luminanceEnabled = false; s.props.colorEnabled = false
    end }
    unchanged(state)
    assert(state.dialogs == 1 and not state.previewDialog)
    assert(state.messages[#state.messages].title == 'Adaptive Noise: no changes')
end)

test('change after preview is skipped without creating a snapshot', function()
    local state = run { beforePreviewDecision = function(s) s.photos[1].settings.Exposure2012 = 3 end }
    assert(state.writes == 0 and state.snapshots == 0)
    assert(state.messages[#state.messages].text:find('1 changed since reading', 1, true))
end)

test('camera switch observer retains distinct numeric edits and saves both profiles', function()
    local firstKey, secondKey
    local state = run { twoCameras = true, cancelPreview = true,
        editSettings = function(s, dialog)
            local menu
            visit(dialog.contents, function(control) if control.kind == 'popup_menu' then menu = control end end)
            assert(menu and #menu.items == 2)
            firstKey, secondKey = menu.items[1].value, menu.items[2].value
            s.props.exposurePoints = 7
            s.props.camera = secondKey
            assert(s.props.exposurePoints ~= 7, 'Second camera inherited first camera edits')
            s.props.exposurePoints = 11
            s.props.camera = firstKey
            assert(s.props.exposurePoints == 7, 'First camera lost its edit')
            s.props.camera = secondKey
            assert(s.props.exposurePoints == 11, 'Second camera lost its edit')
        end }
    assert(state.prefs.profilesV1[firstKey].exposurePoints == 7)
    assert(state.prefs.profilesV1[secondKey].exposurePoints == 11)
    unchanged(state)
end)

test('a filename read error uses a fallback label and still completes the batch', function()
    local state = run { nameError = true }
    assert(state.writes == 1 and state.snapshots == 1)
    local found = false
    visit(state.previewDialog.contents, function(control)
        if type(control.title) == 'string' and control.title:find('name unavailable', 1, true) then found = true end
    end)
    assert(found, 'Missing fallback identifier')
end)

test('invalid settings can be corrected without losing edits or touching photos early', function()
    local state = run { editSettings = function(s)
        if s.settingsDialogs == 1 then
            s.props.isoHigh = s.props.isoLow
            s.props.exposurePoints = 7
        else
            assert(s.settingsDialogs == 2 and #s.messages == 1, 'Expected one validation warning')
            assert(s.props.exposurePoints == 7, 'Valid edits were lost')
            s.props.isoHigh = 6400
        end
    end }
    assert(state.settingsDialogs == 2 and state.dialogs == 3 and state.writes == 1)
    assert(state.photos[1].settings.LuminanceSmoothing == 42)
end)

test('Cancel after validation failure persists no edits and writes no photos', function()
    local state = run { editSettings = function(s)
        if s.settingsDialogs == 1 then s.props.isoHigh = 0
        else assert(s.settingsDialogs == 2 and #s.messages == 1) end
    end, cancelSettingsAfter = 2 }
    unchanged(state)
    assert(state.settingsDialogs == 2 and state.prefs.profilesV1 == nil)
end)

test('malformed saved preferences fall back to editable defaults', function()
    local state = run { savedProfiles = 42 }
    assert(state.writes == 1 and type(state.prefs.profilesV1) == 'table')
end)

test('v0.1 camera preferences migrate without enabling extra controls or skip rules', function()
    local Model = dofile(pluginPath .. '/NoiseModel.lua')
    local key = Model.cameraKey('Alpha', 'Test Camera')
    local old = { enabled = true, includeNonRaw = false, logarithmic = false,
        isoLow = 100, isoHigh = 6400, luminanceEnabled = true,
        luminanceLow = 0, luminanceHigh = 40, luminanceCap = 40,
        exposurePoints = 7, shadowPoints = 1, colorEnabled = false,
        colorLow = 25, colorHigh = 40, colorCap = 100 }
    local state = run { savedProfiles = { [key] = old }, cancelPreview = true,
        editSettings = function(s)
            assert(s.props.exposurePoints == 7 and s.props.luminanceHigh == 40)
            for _, control in ipairs(Model.extraControls()) do assert(s.props[control.id .. 'Enabled'] == false) end
            assert(s.props.skipProcessed == false and s.props.skipManualNR == false and s.props.skipAIDenoise == false)
        end }
    unchanged(state)
    assert(state.prefs.profilesV1[key].colorEnabled == false)
end)

print(string.format('\n%d Main workflow tests passed under %s; no Lightroom operations performed.', passed, _VERSION))
