-- Run from the repository root: lua5.1 tests/sdk_contract.lua
-- Executes SelfTest.lua against strict, in-memory SDK doubles. This does not
-- launch Lightroom, touch a catalog, import files, or create a runtime receipt.
local pluginPath = (arg and arg[1]) or 'AdaptiveNoise.lrplugin'
local savedPlugin, savedImport, savedOpen = _PLUGIN, import, io.open
local inAsync, inWrite = false, false
local byPath, mutations, messages, receipt = {}, {}, {}, nil
local imported, restored, narrowWrites = 0, 0, 0
local originalPhoto = { path = '/user-photo-never-to-be-mutated.dng' }
local originalSources = { { marker = 'original source' } }
local activePhoto, selectedPhotos, activeSources = originalPhoto, { originalPhoto }, originalSources
local currentModule = 'develop'
local collections = {}

local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = clone(v) end
    return result
end

local function requireAsync()
    assert(inAsync, 'SDK reads must run inside an asynchronous task')
end

local function requireWrite(photo, operation)
    requireAsync()
    assert(inWrite, operation .. ' must run inside a catalog write gate')
    assert(byPath[photo.path] == photo, 'Mutation escaped generated fixtures')
    mutations[#mutations + 1] = { photo = photo, operation = operation }
end

local function fixture(path)
    local iso = tonumber(path:match('/fixtures/iso%-(%d+)%.jpg$'))
    assert(iso == 100 or iso == 3250 or iso == 6400, 'Unexpected import path: ' .. path)
    local photo = { path = path, iso = iso, snapshots = {}, settings = {
        Exposure2012 = 0, Shadows2012 = 0, LuminanceSmoothing = 0,
        ColorNoiseReduction = 25, ProcessVersion = '15.4', WhiteBalance = 'As Shot',
        Temperature = 5100, Tint = 4, CropTop = 0.1, CropBottom = 0.9,
        CropLeft = 0.2, CropRight = 0.8, CropAngle = 1.5,
        MaskGroupBasedCorrections = { { original = true } },
    } }
    function photo:getDevelopSettings()
        requireAsync(); return clone(self.settings)
    end
    function photo:getRawMetadata(key)
        requireAsync()
        if key == 'path' then return self.path end
        if key == 'isoSpeedRating' then return self.iso end
        if key == 'fileFormat' then return 'JPG' end
        error('Unsupported raw metadata key: ' .. tostring(key))
    end
    function photo:getFormattedMetadata(key)
        requireAsync()
        if key == 'cameraMake' then return 'Generated Test' end
        if key == 'cameraModel' then return 'Fixture Camera' end
        if key == 'fileName' then return self.path:match('[^/]+$') end
        error('Unsupported formatted metadata key: ' .. tostring(key))
    end
    function photo:createDevelopSnapshot(name, updateInPlace)
        requireWrite(self, 'snapshot')
        assert(type(name) == 'string' and updateInPlace == false,
            'Recovery snapshots must have a name and must not replace existing snapshots')
        for _, snapshot in ipairs(self.snapshots) do
            if snapshot.name == name then return false end
        end
        self.snapshots[#self.snapshots + 1] = {
            name = name, snapshotID = 'snapshot-' .. self.iso .. '-' .. (#self.snapshots + 1),
            id_global = 'different-global-id-' .. self.iso,
            settings = clone(self.settings),
        }
        return true
    end
    function photo:getDevelopSnapshots()
        requireAsync(); return clone(self.snapshots)
    end
    function photo:applyDevelopSettings(patch, historyName, flattenAutoNow)
        requireWrite(self, 'develop settings')
        assert(flattenAutoNow == nil or flattenAutoNow == false,
            'Noise operation must not flatten automatic settings')
        if historyName == 'Adaptive Noise Reduction' then
            assert(#self.snapshots > 0, 'Noise adjustment preceded recovery snapshot')
            for key in pairs(patch) do
                assert(key == 'LuminanceSmoothing' or key == 'ColorNoiseReduction',
                    'Noise operation wrote unrelated adjustment: ' .. tostring(key))
            end
            narrowWrites = narrowWrites + 1
        else
            assert(historyName == 'Prepare test fixture', 'Unexpected develop operation')
        end
        for key, value in pairs(patch) do self.settings[key] = clone(value) end
    end
    function photo:applyDevelopSnapshot(snapshotID)
        requireWrite(self, 'snapshot restore')
        assert(type(snapshotID) == 'string', 'applyDevelopSnapshot expects snapshot.snapshotID, not a table')
        for _, snapshot in ipairs(self.snapshots) do
            if snapshot.snapshotID == snapshotID then
                self.settings = clone(snapshot.settings); restored = restored + 1; return
            end
        end
        error('Unknown snapshotID; id_global is not the restore identifier')
    end
    return photo
end

local catalog = {}
function catalog:findPhotoByPath(path)
    requireAsync(); return byPath[path]
end
function catalog:addPhoto(path, stackWith, position, metadataPreset, developPreset)
    assert(inAsync and inWrite, 'addPhoto requires async write access')
    assert(stackWith == nil and position == nil and metadataPreset == nil and developPreset == nil,
        'Fixture import must not stack or apply presets')
    assert(not byPath[path], 'Duplicate fixture import')
    byPath[path] = fixture(path); imported = imported + 1
    -- Return an unusable placeholder: callers must reacquire after committing.
    return {}
end
function catalog:withWriteAccessDo(name, callback, options)
    requireAsync()
    assert(not inWrite, 'Nested write gate')
    assert(type(name) == 'string' and type(callback) == 'function', 'Invalid write gate signature')
    assert(options and type(options.timeout) == 'number' and options.asynchronous == false,
        'Write gate must have a timeout and wait for completion')
    inWrite = true
    local ok, message = pcall(callback)
    inWrite = false
    if not ok then error(message, 0) end
    return 'executed'
end
function catalog:setSelectedPhotos(photo, others)
    assert(photo == originalPhoto or byPath[photo.path] == photo,
        'Self-test may only activate a generated fixture or restore original selection')
    for _, other in ipairs(others or {}) do
        assert(other == originalPhoto or byPath[other.path] == other,
            'Self-test may only select generated fixtures or restore original selection')
    end
    activePhoto, selectedPhotos = photo, { photo }
    for _, other in ipairs(others or {}) do selectedPhotos[#selectedPhotos + 1] = other end
end
function catalog:getTargetPhoto() requireAsync(); return activePhoto end
function catalog:getTargetPhotos() requireAsync(); return selectedPhotos end
function catalog:getActiveSources() requireAsync(); return activeSources end
function catalog:setActiveSources(sources)
    requireAsync(); assert(type(sources) == 'table', 'Expected sources array')
    activeSources = sources; return true
end
function catalog:createCollection(name, parent, canReturnPrior)
    assert(inAsync and inWrite, 'createCollection requires async write access')
    assert(type(name) == 'string' and parent == nil and canReturnPrior == false,
        'Temporary collection must be new and must not reuse an existing collection')
    local collection = { photos = {}, deleted = false }
    function collection:addPhotos(photos)
        assert(inAsync and inWrite, 'addPhotos requires async write access')
        for _, photo in ipairs(photos) do
            assert(byPath[photo.path] == photo, 'Temporary collection contained a user photo')
            self.photos[#self.photos + 1] = photo
        end
    end
    function collection:delete()
        assert(inAsync and inWrite, 'Collection deletion requires async write access')
        assert(activeSources[1] ~= self, 'Restore source before deleting test collection')
        self.deleted = true
    end
    collections[#collections + 1] = collection
    return collection
end

local modules = {
    LrApplication = { activeCatalog = function() return catalog end,
        versionString = function() return 'Mock SDK contract only' end },
    LrFunctionContext = { callWithContext = function(_, callback)
        local handlers = {}
        local context = { addCleanupHandler = function(_, handler) handlers[#handlers + 1] = handler end }
        local ok, message = pcall(callback, context)
        for i = #handlers, 1, -1 do
            local cleanupOK, cleanupError = pcall(handlers[i], ok, message)
            if not cleanupOK and ok then ok, message = false, cleanupError end
        end
        if not ok then error(message, 0) end
    end },
    LrDialogs = { attachErrorDialogToFunctionContext = function() end,
        confirm = function() return 'ok' end,
        message = function(title, text) messages[#messages + 1] = { title, text } end },
    LrPathUtils = { child = function(parent, child) return parent .. '/' .. child end,
        parent = function(path) return path:match('^(.*)/[^/]+$') or '.' end },
    LrDate = { currentTime = function() return 1234567.123456 end },
    LrApplicationView = { getCurrentModuleName = function() return currentModule end,
        switchToModule = function(name)
            assert(name == 'develop' or name == 'library', 'Unexpected module switch')
            currentModule = name
        end },
    LrTasks = { pcall = pcall, sleep = function() end, yield = function() end,
        startAsyncTask = function(callback)
            assert(not inAsync, 'Unexpected nested async task'); inAsync = true
            local ok, message = pcall(callback); inAsync = false
            if not ok then error(message, 0) end
        end },
}

_PLUGIN = { path = pluginPath }
function import(name) return assert(modules[name], 'Unexpected SDK import: ' .. name) end
io.open = function(path, mode)
    assert(mode == 'w' and path:match('/runtime%-self%-test%.txt$'), 'Unexpected file operation')
    local chunks = {}
    return { write = function(_, ...)
        for i = 1, select('#', ...) do chunks[#chunks + 1] = tostring(select(i, ...)) end
    end, close = function() receipt = table.concat(chunks); return true end }
end

local ok, message = pcall(function() dofile(pluginPath .. '/SelfTest.lua') end)
_PLUGIN, import, io.open = savedPlugin, savedImport, savedOpen
if not ok then error(message, 0) end
assert(imported == 3 and narrowWrites == 3 and restored == 1, 'Self-test did not complete all contract checks')
assert(#messages == 1 and messages[1][1] == 'Adaptive Noise self-test passed', 'Missing final success dialog')
assert(receipt and receipt:find('Mock SDK contract only', 1, true), 'Mock report was not captured')
if #collections > 0 then
    assert(activeSources == originalSources and activePhoto == originalPhoto,
        'Self-test did not restore original source and selection')
    for _, collection in ipairs(collections) do assert(collection.deleted, 'Temporary collection not cleaned up') end
end
print('PASS: SelfTest SDK contracts, fixture-only mutations, two-key patches, and snapshotID restore (' .. _VERSION .. ')')
print('This is mock verification; no Lightroom catalog or runtime receipt was created.')
