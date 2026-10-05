local RSGCore = exports['rsg-core']:GetCoreObject()
local Inventory = exports['rsg-inventory']

-- Active smelt jobs keyed by server id: { recipe, amount, smelter, propCoords, startedAt, duration, citizenid }
local pending = {}
-- Jobs interrupted by a disconnect, refunded when the character logs back in (keyed by citizenid)
local owed = {}

local function itemLabel(item)
    local def = RSGCore.Shared.Items[item]
    return def and def.label or item
end

local function itemBox(src, item, action, amount)
    local def = RSGCore.Shared.Items[item]
    if def then TriggerClientEvent('rsg-inventory:client:ItemBox', src, def, action, amount) end
end

-- Unique list of every input item, used for UI counts
local oreList = {}
do
    local seen = {}
    for _, r in ipairs(Config.Recipes) do
        for _, inp in ipairs(r.inputs) do
            if not seen[inp.item] then
                seen[inp.item] = true
                oreList[#oreList + 1] = inp.item
            end
        end
    end
end

local function itemCount(Player, item)
    local total = 0
    for _, v in pairs(Player.PlayerData.items or {}) do
        if v and v.name == item then total = total + (v.amount or 0) end
    end
    return total
end

local function normaliseSmelter(smelterIndex)
    if smelterIndex == 'prop' then return 'prop' end
    local i = tonumber(smelterIndex)
    return (i and Config.Smelters[i]) and i or nil
end

local function nearSmelter(src, smelter, propCoords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pos = GetEntityCoords(ped)

    if smelter == 'prop' then
        -- World props aren't networked, so the reported prop position is checked
        -- against the player's real server-side position.
        if not Config.SmeltProps.enabled or type(propCoords) ~= 'vector3' and type(propCoords) ~= 'table' then return false end
        local x, y, z = tonumber(propCoords.x), tonumber(propCoords.y), tonumber(propCoords.z)
        if not (x and y and z) then return false end
        return #(pos - vector3(x, y, z)) <= Config.MaxUseDistance
    end

    local data = Config.Smelters[smelter]
    return data and #(pos - data.coords.xyz) <= Config.MaxUseDistance or false
end

-- Give back a job's inputs; anything that won't fit is reported in the log
local function refund(src, job, reason)
    for _, inp in ipairs(job.recipe.inputs) do
        local total = inp.amount * job.amount
        if Inventory:AddItem(src, inp.item, total, nil, nil, reason) then
            itemBox(src, inp.item, 'add', total)
        else
            print(('[rsg-smelting] refund failed for %s: %dx %s (inventory full)'):format(src, total, inp.item))
            Webhook.Send('refund_failed', src, {
                { locale('wh_f_item'), ('%dx %s'):format(total, itemLabel(inp.item)) },
                { locale('wh_f_reason'), reason },
            }, locale('wh_desc_refund_failed'))
        end
    end
end

lib.callback.register('rsg-smelting:server:getOreCounts', function(src)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return {} end
    local counts = {}
    for _, item in ipairs(oreList) do
        counts[item] = itemCount(Player, item)
    end
    return counts
end)

lib.callback.register('rsg-smelting:server:startSmelt', function(src, smelterIndex, recipeIndex, amount, propCoords)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return false, locale('err_player') end
    if pending[src] then return false, locale('err_busy') end

    local recipe = Config.Recipes[tonumber(recipeIndex) or 0]
    if not recipe then
        Webhook.Send('suspicious', src, { { locale('wh_f_check'), locale('wh_chk_recipe') }, { locale('wh_f_sent'), tostring(recipeIndex) } })
        return false, locale('err_recipe')
    end

    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or amount > Config.MaxBatch then
        Webhook.Send('suspicious', src, { { locale('wh_f_check'), locale('wh_chk_amount') }, { locale('wh_f_sent'), tostring(amount) }, { locale('wh_f_max'), tostring(Config.MaxBatch) } })
        return false, locale('err_amount')
    end

    local smelter = normaliseSmelter(smelterIndex)
    if not smelter or not nearSmelter(src, smelter, propCoords) then
        Webhook.Send('suspicious', src, { { locale('wh_f_check'), locale('wh_chk_distance') }, { locale('wh_f_smelter'), smelter and Webhook.SmelterName(smelter) or tostring(smelterIndex) } })
        return false, locale('err_distance')
    end

    for _, inp in ipairs(recipe.inputs) do
        if itemCount(Player, inp.item) < inp.amount * amount then
            return false, locale('err_not_enough', itemLabel(inp.item))
        end
    end

    -- Take inputs up front so they can't be dropped/traded mid-smelt.
    -- If any removal fails, roll back what was already taken.
    local taken = {}
    for _, inp in ipairs(recipe.inputs) do
        local total = inp.amount * amount
        if not Inventory:RemoveItem(src, inp.item, total, nil, 'rsg-smelting:start') then
            for _, t in ipairs(taken) do Inventory:AddItem(src, t.item, t.total, nil, nil, 'rsg-smelting:rollback') end
            Webhook.Send('take_failed', src, { { locale('wh_f_item'), ('%dx %s'):format(total, itemLabel(inp.item)) }, { locale('wh_f_recipe'), locale(recipe.label) } })
            return false, locale('err_take_failed')
        end
        taken[#taken + 1] = { item = inp.item, total = total }
        itemBox(src, inp.item, 'remove', total)
    end

    pending[src] = {
        recipe = recipe,
        amount = amount,
        smelter = smelter,
        propCoords = propCoords,
        startedAt = os.time(),
        duration = math.floor(recipe.time * amount / 1000),
        citizenid = Player.PlayerData.citizenid,
        info = Webhook.PlayerInfo(src), -- snapshot for logs after disconnect
    }
    Webhook.Send('smelt_start', src, {
        { locale('wh_f_output'), ('%dx %s'):format(amount, locale(recipe.label)) },
        { locale('wh_f_smelter'), Webhook.SmelterName(smelter) },
        { locale('wh_f_duration'), locale('wh_seconds', pending[src].duration) },
        { locale('wh_f_inputs'), Webhook.Inputs(recipe, amount), inline = false },
    })
    return true
end)

lib.callback.register('rsg-smelting:server:finishSmelt', function(src, cancelled)
    local job = pending[src]
    if not job then return false end
    pending[src] = nil

    if not RSGCore.Functions.GetPlayer(src) then return false end

    if cancelled then
        refund(src, job, 'rsg-smelting:cancel')
        Webhook.Send('smelt_cancel', src, { { locale('wh_f_output'), ('%dx %s'):format(job.amount, locale(job.recipe.label)) }, { locale('wh_f_elapsed'), locale('wh_elapsed_val', os.time() - job.startedAt, job.duration) } })
        return false, locale('smelt_cancelled')
    end

    -- Must have waited the full time (1s tolerance) and still be at the smelter
    local elapsed = os.time() - job.startedAt
    local tooFast = elapsed < job.duration - 1
    if tooFast or not nearSmelter(src, job.smelter, job.propCoords) then
        refund(src, job, 'rsg-smelting:failed')
        Webhook.Send(tooFast and 'suspicious' or 'smelt_failed', src, {
            { locale('wh_f_check'), tooFast and locale('wh_chk_too_early') or locale('wh_chk_left_area') },
            { locale('wh_f_output'), ('%dx %s'):format(job.amount, locale(job.recipe.label)) },
            { locale('wh_f_elapsed'), locale('wh_elapsed_val', elapsed, job.duration) },
            { locale('wh_f_smelter'), Webhook.SmelterName(job.smelter) },
        })
        return false, locale('smelt_failed')
    end

    local output = job.recipe.output
    if Inventory:CanAddItem(src, output, job.amount) and Inventory:AddItem(src, output, job.amount, nil, nil, 'rsg-smelting:finish') then
        itemBox(src, output, 'add', job.amount)
        Webhook.Send('smelt_complete', src, {
            { locale('wh_f_output'), ('%dx %s'):format(job.amount, locale(job.recipe.label)) },
            { locale('wh_f_smelter'), Webhook.SmelterName(job.smelter) },
            { locale('wh_f_consumed'), Webhook.Inputs(job.recipe, job.amount), inline = false },
        })
        return true, locale('smelt_success', job.amount, locale(job.recipe.label))
    end

    refund(src, job, 'rsg-smelting:nospace')
    Webhook.Send('smelt_nospace', src, { { locale('wh_f_output'), ('%dx %s'):format(job.amount, locale(job.recipe.label)) } })
    return false, locale('smelt_no_space')
end)

-- Disconnect mid-smelt: remember the job and refund on next login
AddEventHandler('playerDropped', function()
    local src = source
    local job = pending[src]
    if not job then return end
    pending[src] = nil
    if job.citizenid then
        owed[job.citizenid] = owed[job.citizenid] or {}
        table.insert(owed[job.citizenid], job)
    end
    Webhook.Send('player_dropped', job.info, {
        { locale('wh_f_output'), ('%dx %s'):format(job.amount, locale(job.recipe.label)) },
        { locale('wh_f_held'), Webhook.Inputs(job.recipe, job.amount), inline = false },
    }, locale('wh_desc_dropped'))
end)

RegisterNetEvent('RSGCore:Server:OnPlayerLoaded', function()
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local jobs = owed[Player.PlayerData.citizenid]
    if not jobs then return end
    owed[Player.PlayerData.citizenid] = nil
    SetTimeout(2000, function()
        for _, job in ipairs(jobs) do
            refund(src, job, 'rsg-smelting:rejoin')
            Webhook.Send('rejoin_refund', src, { { locale('wh_f_refunded'), Webhook.Inputs(job.recipe, job.amount), inline = false } })
        end
        TriggerClientEvent('ox_lib:notify', src, { title = locale('smelter_title'), description = locale('smelt_refund_rejoin'), type = 'inform', duration = 5000 })
    end)
end)

-- Resource stopping mid-smelt: refund everyone still online
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for src, job in pairs(pending) do
        refund(src, job, 'rsg-smelting:stop')
        Webhook.Send('resource_stop', src, { { locale('wh_f_refunded'), Webhook.Inputs(job.recipe, job.amount), inline = false } })
    end
    -- unrefunded disconnect jobs are lost on stop: log them so staff can compensate
    for cid, jobs in pairs(owed) do
        for _, job in ipairs(jobs) do
            Webhook.Send('refund_failed', job.info, { { locale('wh_f_citizenid'), cid }, { locale('wh_f_owed'), Webhook.Inputs(job.recipe, job.amount), inline = false } },
                locale('wh_desc_stop'))
        end
    end
    Webhook.Flush()
end)
