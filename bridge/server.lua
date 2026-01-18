-- =====================================
-- SERVER-SIDE BRIDGE
-- Full QBox Compatibility, Multi-Inventory Support
-- =====================================

local Config = lib.require('config')
local QBCore, ESX = nil, nil

-- =====================================
-- [[ 1. FRAMEWORK AUTO-DETECTION ]]
-- QBox checked FIRST (uses qbx_core)
-- =====================================

if GetResourceState('qbx_core') == 'started' then
    Bridge.Framework = 'qbx'
    QBCore = exports['qbx_core']:GetCoreObject()
    print('^2[DPS-CityWorker] Framework Detected: QBox^7')
elseif GetResourceState('qb-core') == 'started' then
    Bridge.Framework = 'qb'
    QBCore = exports['qb-core']:GetCoreObject()
    print('^2[DPS-CityWorker] Framework Detected: QBCore^7')
elseif GetResourceState('es_extended') == 'started' then
    Bridge.Framework = 'esx'
    ESX = exports['es_extended']:getSharedObject()
    print('^2[DPS-CityWorker] Framework Detected: ESX^7')
else
    Bridge.Framework = 'standalone'
    print('^3[DPS-CityWorker] Warning: No framework detected, running standalone^7')
end

-- =====================================
-- [[ 2. PLAYER FUNCTIONS ]]
-- =====================================

function Bridge.GetPlayer(source)
    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return QBCore and QBCore.Functions.GetPlayer(source)
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerFromId(source)
    end
    return nil
end

function Bridge.GetIdentifier(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.PlayerData.citizenid
    elseif Bridge.Framework == 'esx' then
        return player.identifier
    end
    return nil
end

function Bridge.GetCharacterName(source)
    local player = Bridge.GetPlayer(source)
    if not player then return GetPlayerName(source) end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        local charinfo = player.PlayerData.charinfo
        return charinfo.firstname .. ' ' .. charinfo.lastname
    elseif Bridge.Framework == 'esx' then
        return player.getName()
    end
    return GetPlayerName(source)
end

-- =====================================
-- [[ 3. MONEY FUNCTIONS ]]
-- =====================================

function Bridge.AddMoney(source, account, amount, reason)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    reason = reason or 'city-worker-payment'

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        player.Functions.AddMoney(account, amount, reason)
        return true
    elseif Bridge.Framework == 'esx' then
        if account == 'cash' or account == 'money' then
            player.addMoney(amount, reason)
        else
            player.addAccountMoney(account, amount, reason)
        end
        return true
    end
    return false
end

function Bridge.RemoveMoney(source, account, amount, reason)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    reason = reason or 'city-worker-expense'

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.Functions.RemoveMoney(account, amount, reason)
    elseif Bridge.Framework == 'esx' then
        if account == 'cash' or account == 'money' then
            player.removeMoney(amount, reason)
        else
            player.removeAccountMoney(account, amount, reason)
        end
        return true
    end
    return false
end

function Bridge.GetMoney(source, account)
    local player = Bridge.GetPlayer(source)
    if not player then return 0 end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.PlayerData.money[account] or 0
    elseif Bridge.Framework == 'esx' then
        if account == 'cash' or account == 'money' then
            return player.getMoney()
        else
            return player.getAccount(account).money or 0
        end
    end
    return 0
end

-- =====================================
-- [[ 4. ITEM HANDLING (Multi-Inventory) ]]
-- Supports: ox_inventory, qs-inventory, framework default
-- =====================================

function Bridge.AddItem(source, item, count)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    count = count or 1

    -- OX Inventory (Works with QBox, QB, ESX)
    if GetResourceState('ox_inventory') == 'started' then
        local success = exports.ox_inventory:AddItem(source, item, count)
        if Config.Debug then
            print(('[DPS-CityWorker] ox_inventory:AddItem(%s, %s, %d) = %s'):format(source, item, count, tostring(success)))
        end
        return success
    end

    -- Quasar Inventory
    if GetResourceState('qs-inventory') == 'started' then
        local success = exports['qs-inventory']:AddItem(source, item, count)
        if Config.Debug then
            print(('[DPS-CityWorker] qs-inventory:AddItem(%s, %s, %d) = %s'):format(source, item, count, tostring(success)))
        end
        return success
    end

    -- CodeM Inventory
    if GetResourceState('codem-inventory') == 'started' then
        local success = exports['codem-inventory']:AddItem(source, item, count)
        return success
    end

    -- Default Framework Inventories
    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        local success = player.Functions.AddItem(item, count)
        if Config.Debug then
            print(('[DPS-CityWorker] QB AddItem(%s, %d) = %s'):format(item, count, tostring(success)))
        end
        return success
    elseif Bridge.Framework == 'esx' then
        player.addInventoryItem(item, count)
        return true
    end

    return false
end

function Bridge.RemoveItem(source, item, count)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    count = count or 1

    -- OX Inventory
    if GetResourceState('ox_inventory') == 'started' then
        return exports.ox_inventory:RemoveItem(source, item, count)
    end

    -- Quasar Inventory
    if GetResourceState('qs-inventory') == 'started' then
        return exports['qs-inventory']:RemoveItem(source, item, count)
    end

    -- CodeM Inventory
    if GetResourceState('codem-inventory') == 'started' then
        return exports['codem-inventory']:RemoveItem(source, item, count)
    end

    -- Default Framework Inventories
    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.Functions.RemoveItem(item, count)
    elseif Bridge.Framework == 'esx' then
        player.removeInventoryItem(item, count)
        return true
    end

    return false
end

function Bridge.HasItem(source, item, count)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    count = count or 1

    -- OX Inventory
    if GetResourceState('ox_inventory') == 'started' then
        local itemCount = exports.ox_inventory:Search(source, 'count', item)
        return itemCount >= count
    end

    -- Quasar Inventory
    if GetResourceState('qs-inventory') == 'started' then
        local itemData = exports['qs-inventory']:GetItemByName(source, item)
        return itemData and itemData.amount >= count
    end

    -- Default Framework Inventories
    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        local itemData = player.Functions.GetItemByName(item)
        return itemData and itemData.amount >= count
    elseif Bridge.Framework == 'esx' then
        local itemData = player.getInventoryItem(item)
        return itemData and itemData.count >= count
    end

    return false
end

-- =====================================
-- [[ 5. JOB FUNCTIONS ]]
-- =====================================

function Bridge.GetJobName(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.PlayerData.job.name
    elseif Bridge.Framework == 'esx' then
        return player.job.name
    end
    return nil
end

function Bridge.GetJobGrade(source)
    local player = Bridge.GetPlayer(source)
    if not player then return 0 end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.PlayerData.job.grade.level or 0
    elseif Bridge.Framework == 'esx' then
        return player.job.grade or 0
    end
    return 0
end

function Bridge.HasJob(source, jobName)
    return Bridge.GetJobName(source) == jobName
end

function Bridge.IsOnDuty(source)
    local player = Bridge.GetPlayer(source)
    if not player then return false end

    if Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        return player.PlayerData.job.onduty or false
    end
    return true
end

-- =====================================
-- [[ 6. NOTIFICATION ]]
-- =====================================

function Bridge.Notify(source, message, type)
    type = type or 'inform'

    if GetResourceState('ox_lib') == 'started' then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'City Worker',
            description = message,
            type = type
        })
    elseif Bridge.Framework == 'qbx' or Bridge.Framework == 'qb' then
        TriggerClientEvent('QBCore:Notify', source, message, type)
    elseif Bridge.Framework == 'esx' then
        TriggerClientEvent('esx:showNotification', source, message)
    end
end

-- =====================================
-- BACKWARDS COMPATIBILITY ALIASES
-- =====================================

function GetPlayer(source)
    return Bridge.GetPlayer(source)
end

function AddMoney(source, account, amount)
    return Bridge.AddMoney(source, account, amount)
end

function GetCharacterName(source)
    return Bridge.GetCharacterName(source)
end

function GetCid(source)
    return Bridge.GetIdentifier(source)
end

-- =====================================
-- EXPORTS
-- =====================================

exports('GetPlayer', Bridge.GetPlayer)
exports('GetIdentifier', Bridge.GetIdentifier)
exports('GetCharacterName', Bridge.GetCharacterName)
exports('AddMoney', Bridge.AddMoney)
exports('RemoveMoney', Bridge.RemoveMoney)
exports('GetMoney', Bridge.GetMoney)
exports('AddItem', Bridge.AddItem)
exports('RemoveItem', Bridge.RemoveItem)
exports('HasItem', Bridge.HasItem)
exports('GetJobName', Bridge.GetJobName)
exports('GetJobGrade', Bridge.GetJobGrade)
exports('HasJob', Bridge.HasJob)
exports('IsOnDuty', Bridge.IsOnDuty)
exports('GetPlayerSeniority', function(source)
    -- Will be implemented in sv_cityworker
    return 1
end)

print('^2[DPS-CityWorker] Server bridge initialized^7')
