-- Shared preview/apply path, also exercised by the isolated Lightroom self-test.
local Tasks = import 'LrTasks'
local Model = dofile(_PLUGIN.path .. '/NoiseModel.lua')
local Access = dofile(_PLUGIN.path .. '/PhotoAccess.lua')
local Skip = dofile(_PLUGIN.path .. '/SkipPolicy.lua')
local M = {}

function M.plan(records, profiles, options)
    local plan = { changes = {}, reasons = {}, unchanged = 0, skipped = 0, total = #records, options = {} }
    for key, default in pairs(Skip.defaults()) do plan.options[key] = options and options[key] == true or default end
    for _, record in ipairs(records) do
        local profile = record.input.cameraKey and profiles[record.input.cameraKey]
        local patch, reason
        if record.error then reason = record.error
        elseif Skip.reason(record.input, plan.options) then reason = Skip.reason(record.input, plan.options)
        elseif not profile then reason = 'No camera profile'
        else patch, reason = Model.calculate(record.input, profile) end
        if patch and next(patch) then
            plan.changes[#plan.changes + 1] = {
                photo = record.photo, name = record.name, input = record.input, patch = patch,
            }
        elseif patch then plan.unchanged = plan.unchanged + 1
        else
            plan.skipped = plan.skipped + 1
            reason = reason or 'Unable to calculate'
            plan.reasons[reason] = (plan.reasons[reason] or 0) + 1
        end
    end
    return plan
end

function M.apply(catalog, plan, progress, runId)
    local result = { applied = 0, stale = 0, protected = 0, failed = 0, unverified = 0, cancelled = 0, details = {} }
    for i, item in ipairs(plan.changes) do
        if progress and progress:isCanceled() then
            result.cancelled = #plan.changes - i + 1
            break
        end
        if progress then
            progress:setCaption(item.name)
            progress:setPortionComplete(i - 1, #plan.changes)
        end
        local state, skipReason
        local ok, err = Tasks.pcall(function()
            local status = catalog:withWriteAccessDo('Adaptive Noise Reduction', function()
                -- The write gate can wait for another catalog operation. Honor a
                -- cancellation that arrived while waiting before touching this photo.
                if progress and progress:isCanceled() then state = 'cancelled'; return end
                local current = Access.read(item.photo)
                skipReason = Skip.reason(current, plan.options)
                if skipReason then state = 'protected'; return end
                if not Model.sameInputs(item.input, current) then state = 'stale'; return end
                if progress and progress:isCanceled() then state = 'cancelled'; return end
                if not item.photo:createDevelopSnapshot('Before Adaptive Noise ' .. runId, false) then
                    error('Could not create recovery snapshot; no adjustment applied.')
                end
                -- Never round-trip the complete settings table: preserve masks, crops,
                -- profiles, process version, and every other develop adjustment.
                if progress and progress:isCanceled() then state = 'cancelled'; return end
                -- An SDK exception does not prove that no setting was changed.
                state = 'submitted'
                item.photo:applyDevelopSettings(item.patch, 'Adaptive Noise Reduction')
                state = 'written'
            end, { timeout = 10, asynchronous = false })
            if status ~= 'executed' then error('Catalog was busy; no adjustment applied.') end
            if state == 'stale' or state == 'cancelled' or state == 'protected' then return end
            if state ~= 'written' then error('No settings were written.') end
            -- Lightroom may finish its internal update after the write gate returns.
            local verified = false
            for attempt = 1, 10 do
                local readback = item.photo:getDevelopSettings()
                verified = true
                for key, value in pairs(item.patch) do
                    if readback[key] ~= value then verified = false; break end
                end
                if verified then break end
                Tasks.sleep(0.1)
            end
            state = verified and 'applied' or 'unverified'
        end)
        if not ok then
            -- A readback error after a committed write is not a failed/no-op write.
            if state == 'submitted' or state == 'written' then result.unverified = result.unverified + 1
            else result.failed = result.failed + 1 end
            result.details[#result.details + 1] = item.name .. ': ' .. tostring(err)
        elseif state == 'cancelled' then
            result.cancelled = #plan.changes - i + 1
            break
        elseif state == 'protected' then
            result.protected = result.protected + 1
            result.details[#result.details + 1] = item.name .. ': ' .. skipReason
        elseif state == 'stale' then
            result.stale = result.stale + 1
            result.details[#result.details + 1] = item.name .. ': changed since preview; skipped'
        elseif state == 'applied' then result.applied = result.applied + 1
        else
            result.unverified = result.unverified + 1
            result.details[#result.details + 1] = item.name .. ': submitted, but readback did not confirm target values'
        end
        Tasks.yield()
    end
    if progress then progress:done() end
    return result
end

return M
