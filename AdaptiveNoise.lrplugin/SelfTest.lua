-- Tests only the three generated fixtures shipped with this plugin.
-- This command imports them into the active catalog. It never uses user selection.
local Application = import 'LrApplication'
local Context = import 'LrFunctionContext'
local Dialogs = import 'LrDialogs'
local Path = import 'LrPathUtils'
local Tasks = import 'LrTasks'
local Date = import 'LrDate'
local ApplicationView = import 'LrApplicationView'
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Batch = dofile(_PLUGIN.path .. '/Batch.lua')

Tasks.startAsyncTask(function()
    Context.callWithContext('AdaptiveNoiseSelfTest', function(context)
        Dialogs.attachErrorDialogToFunctionContext(context)
        if Dialogs.confirm('Adaptive Noise isolated self-test',
            'This imports three generated JPEG test images into the current catalog and adjusts only those test images.\nYour selected photos are not used. Back up your catalog before testing a new plugin.',
            'Run test', 'Cancel') ~= 'ok' then return end
        local catalog = Application.activeCatalog()
        local originalSources = catalog:getActiveSources()
        local originalActive = catalog:getTargetPhoto()
        local originalSelection = originalActive and catalog:getTargetPhotos() or nil
        local originalModule = ApplicationView.getCurrentModuleName()
        local testCollection
        context:addCleanupHandler(function()
            Tasks.pcall(function() catalog:setActiveSources(originalSources) end)
            if originalActive then Tasks.pcall(function() catalog:setSelectedPhotos(originalActive, originalSelection) end) end
            Tasks.pcall(function() ApplicationView.switchToModule(originalModule) end)
            if testCollection then
                Tasks.pcall(function()
                    catalog:withWriteAccessDo('Remove temporary Adaptive Noise test collection', function()
                        testCollection:delete()
                    end, { timeout = 10, asynchronous = false })
                end)
            end
        end)
        local fixtures = Path.child(_PLUGIN.path, 'fixtures')
        local photos, paths, lines = {}, {}, {}
        local function log(text) lines[#lines + 1] = text end
        local runId = 'SelfTest ' .. string.format('%.6f', Date.currentTime())
        for _, iso in ipairs({ 100, 3250, 6400 }) do
            paths[#paths + 1] = Path.child(fixtures, 'iso-' .. iso .. '.jpg')
        end
        local status = catalog:withWriteAccessDo('Import Adaptive Noise test fixtures', function()
            for _, path in ipairs(paths) do
                if not catalog:findPhotoByPath(path) then catalog:addPhoto(path) end
            end
        end, { timeout = 10, asynchronous = false })
        assert(status == 'executed', 'Catalog busy during test import')
        for _, path in ipairs(paths) do
            local photo = assert(catalog:findPhotoByPath(path), 'Imported test photo not found')
            assert(photo:getRawMetadata('path') == path, 'Test fixture path mismatch')
            photos[#photos + 1] = photo
        end
        status = catalog:withWriteAccessDo('Prepare Adaptive Noise test fixtures', function()
            for _, photo in ipairs(photos) do
                photo:applyDevelopSettings({ Exposure2012 = 2, Shadows2012 = 30,
                    LuminanceSmoothing = 0, ColorNoiseReduction = 25,
                    Contrast2012 = 17, Clarity2012 = 9, Vibrance = -7,
                    Sharpness = 38, SharpenEdgeMasking = 27 }, 'Prepare test fixture')
            end
        end, { timeout = 10, asynchronous = false })
        assert(status == 'executed', 'Catalog busy during test preparation')
        Tasks.sleep(0.5)
        local records, profiles, before = {}, {}, {}
        for i, photo in ipairs(photos) do
            local input = Access.read(photo)
            assert(input.iso == ({ 100, 3250, 6400 })[i], 'Fixture ISO metadata was not read correctly')
            assert(input.exposure == 2 and input.shadows == 30, 'Fixture preparation not visible')
            local c = Model.defaults(); c.includeNonRaw = true
            profiles[input.cameraKey] = c
            records[i] = { photo = photo, name = Access.name(photo), input = input }
            before[i] = photo:getDevelopSettings()
        end
        local plan = Batch.plan(records, profiles)
        assert(#plan.changes == 3, 'Expected three fixture adjustments')
        local result = Batch.apply(catalog, plan, nil, runId)
        assert(result.applied == 3 and result.failed == 0 and result.unverified == 0, 'Readback failed: ' .. table.concat(result.details, '\n'))
        log('PASS: all three fixture writes confirmed by Lightroom')
        local expectedLuminance, expectedColor = { 13, 38, 63 }, { 25, 33, 40 }
        for i, photo in ipairs(photos) do
            local settings = photo:getDevelopSettings()
            assert(settings.LuminanceSmoothing == expectedLuminance[i], 'Unexpected luminance target')
            assert(settings.ColorNoiseReduction == expectedColor[i], 'Unexpected color target')
            for _, key in ipairs({ 'Exposure2012', 'Shadows2012', 'Contrast2012', 'Clarity2012',
                'Vibrance', 'Sharpness', 'SharpenEdgeMasking', 'ProcessVersion', 'WhiteBalance',
                'Temperature', 'Tint', 'CropTop', 'CropBottom', 'CropLeft', 'CropRight', 'CropAngle' }) do
                assert(settings[key] == before[i][key], 'Unrelated adjustment changed: ' .. key)
            end
            records[i].input = Access.read(photo)
        end
        log('PASS: expected targets 13/38/63 luminance and 25/33/40 color')
        log('PASS: exposure, shadows, tone, sharpening, white balance, crop and process version preserved')
        local second = Batch.plan(records, profiles)
        assert(#second.changes == 0 and second.unchanged == 3, 'Second run compounded adjustments')
        log('PASS: second run makes zero changes')
        local photo = photos[1]
        -- Lightroom versions have differed in background snapshot behavior.
        -- Exercise recovery with the generated test photo active in Develop.
        status = catalog:withWriteAccessDo('Create temporary Adaptive Noise test collection', function()
            testCollection = assert(catalog:createCollection('Adaptive Noise Test ' .. runId, nil, false))
            testCollection:addPhotos(photos)
        end, { timeout = 10, asynchronous = false })
        assert(status == 'executed', 'Test collection gate aborted')
        assert(catalog:setActiveSources({ testCollection }), 'Unable to show test collection')
        catalog:setSelectedPhotos(photo, { photo })
        ApplicationView.switchToModule('develop')
        Tasks.sleep(0.5)
        local snapshotFound = false
        for _, snapshot in ipairs(photo:getDevelopSnapshots()) do
            if snapshot.name == 'Before Adaptive Noise ' .. runId then
                snapshotFound = true
                status = catalog:withWriteAccessDo('Test Adaptive Noise snapshot restore', function()
                    photo:applyDevelopSnapshot(snapshot.snapshotID)
                end, { timeout = 10, asynchronous = false })
                assert(status == 'executed', 'Snapshot restore gate aborted')
                break
            end
        end
        assert(snapshotFound, 'Recovery snapshot not found')
        Tasks.sleep(0.3)
        local restored = photo:getDevelopSettings()
        assert(restored.LuminanceSmoothing == before[1].LuminanceSmoothing
            and restored.ColorNoiseReduction == before[1].ColorNoiseReduction, 'Snapshot did not restore noise reduction')
        log('PASS: recovery snapshot restores original noise reduction')
        log('Lightroom: ' .. Application.versionString())
        log('Run: ' .. runId)
        log('Scope: three generated fixtures; user-selected photos were not used')
        local report = table.concat(lines, '\n')
        -- Saved beside the plugin, outside its distributable folder.
        local handle = io.open(Path.child(Path.parent(_PLUGIN.path), 'local/runtime-self-test.txt'), 'w')
        if handle then handle:write(report, '\n'); handle:close() end
        Dialogs.message('Adaptive Noise self-test passed', report, 'info')
    end)
end)
