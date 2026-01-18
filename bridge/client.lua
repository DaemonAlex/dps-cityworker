-- =====================================
-- CLIENT-SIDE BRIDGE
-- Unified framework abstraction layer
-- =====================================

local Config = lib.require('config')
local QBCore, ESX = nil, nil

-- Initialize framework connection
CreateThread(function()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif Bridge.Framework == 'esx' then
        ESX = exports['es_extended']:getSharedObject()
    end
end)

-- =====================================
-- PLAYER DATA
-- =====================================

function Bridge.HasPlayerLoaded()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        local PlayerData = QBCore and QBCore.Functions.GetPlayerData() or {}
        return PlayerData.job ~= nil
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.IsPlayerLoaded()
    end
    return true
end

function Bridge.GetPlayerData()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return QBCore and QBCore.Functions.GetPlayerData() or {}
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerData() or {}
    end
    return {}
end

-- =====================================
-- VEHICLE KEYS
-- =====================================

function Bridge.GiveVehicleKeys(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        TriggerEvent('vehiclekeys:client:SetOwner', plate)
    elseif Bridge.Framework == 'esx' then
        -- ESX: Basic unlock behavior
        SetVehicleDoorsLocked(vehicle, 1)
        SetVehicleDoorsLockedForAllPlayers(vehicle, false)
    end
end

-- =====================================
-- NOTIFICATIONS
-- =====================================

function Bridge.Notify(message, type)
    type = type or 'inform'

    if Config.Notify == 'ox_lib' then
        lib.notify({
            title = 'City Worker',
            description = message,
            type = type,
            duration = 5000
        })
    elseif Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        QBCore.Functions.Notify(message, type)
    elseif Bridge.Framework == 'esx' then
        ESX.ShowNotification(message)
    end
end

-- =====================================
-- JOB FUNCTIONS
-- =====================================

function Bridge.GetJob()
    local data = Bridge.GetPlayerData()

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return data.job or {}
    elseif Bridge.Framework == 'esx' then
        return data.job or {}
    end
    return {}
end

function Bridge.HasJob(jobName)
    local job = Bridge.GetJob()
    return job.name == jobName
end

function Bridge.IsOnDuty()
    local job = Bridge.GetJob()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return job.onduty or false
    end
    return true
end

-- =====================================
-- EVENT HANDLERS (Override in main script)
-- =====================================

function OnPlayerLoaded()
    -- Override in cl_cityworker.lua
end

function OnPlayerUnload()
    -- Override in cl_cityworker.lua
end

-- Framework-specific event listeners
if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        OnPlayerLoaded()
    end)

    RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
        OnPlayerUnload()
    end)
elseif Bridge.Framework == 'esx' then
    RegisterNetEvent('esx:playerLoaded', function(xPlayer)
        OnPlayerLoaded()
    end)

    RegisterNetEvent('esx:onPlayerLogout', function()
        OnPlayerUnload()
    end)
end

-- =====================================
-- FUEL SYSTEM (Multi-Script Support)
-- =====================================

local detectedFuelScript = nil

-- Auto-detect fuel script on startup
local function DetectFuelScript()
    if Config.FuelScript and Config.FuelScript.script ~= 'auto' then
        return Config.FuelScript.script
    end

    -- Auto-detection order (most common first)
    local fuelScripts = {
        'ox_fuel',
        'LegacyFuel',
        'ps-fuel',
        'cdn-fuel',
        'qs-fuelstations',
        'lj-fuel',
        'ti_fuel',
        'myFuel',
    }

    for _, script in ipairs(fuelScripts) do
        if GetResourceState(script) == 'started' then
            if Config.Debug then
                print('[DPS-CityWorker] Auto-detected fuel script: ' .. script)
            end
            return script
        end
    end

    return nil -- No fuel script detected
end

-- Initialize fuel detection
CreateThread(function()
    Wait(1000) -- Wait for resources to load
    detectedFuelScript = DetectFuelScript()
end)

function Bridge.SetVehicleFuel(vehicle, fuelLevel)
    if not vehicle or not DoesEntityExist(vehicle) then return false end

    fuelLevel = fuelLevel or 100.0

    -- Check if fuel is enabled in config
    if Config.FuelScript and not Config.FuelScript.enable then
        Entity(vehicle).state.fuel = fuelLevel
        return true
    end

    local fuelScript = detectedFuelScript

    if not fuelScript then
        -- Fallback to statebag
        Entity(vehicle).state.fuel = fuelLevel
        return true
    end

    -- Script-specific fuel setting
    local success = pcall(function()
        if fuelScript == 'ox_fuel' then
            Entity(vehicle).state.fuel = fuelLevel
        elseif fuelScript == 'LegacyFuel' then
            exports['LegacyFuel']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'ps-fuel' then
            exports['ps-fuel']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'cdn-fuel' then
            exports['cdn-fuel']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'qs-fuelstations' then
            exports['qs-fuelstations']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'lj-fuel' then
            exports['lj-fuel']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'ti_fuel' then
            exports['ti_fuel']:SetFuel(vehicle, fuelLevel)
        elseif fuelScript == 'myFuel' then
            exports['myFuel']:SetFuel(vehicle, fuelLevel)
        else
            -- Try generic export pattern
            exports[fuelScript]:SetFuel(vehicle, fuelLevel)
        end
    end)

    if not success then
        -- Fallback to statebag if export fails
        Entity(vehicle).state.fuel = fuelLevel
    end

    return true
end

function Bridge.GetVehicleFuel(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return 0 end

    local fuelScript = detectedFuelScript

    if not fuelScript then
        return Entity(vehicle).state.fuel or 100
    end

    local fuel = 100
    pcall(function()
        if fuelScript == 'ox_fuel' then
            fuel = Entity(vehicle).state.fuel or 100
        elseif fuelScript == 'LegacyFuel' then
            fuel = exports['LegacyFuel']:GetFuel(vehicle)
        elseif fuelScript == 'ps-fuel' then
            fuel = exports['ps-fuel']:GetFuel(vehicle)
        elseif fuelScript == 'cdn-fuel' then
            fuel = exports['cdn-fuel']:GetFuel(vehicle)
        elseif fuelScript == 'qs-fuelstations' then
            fuel = exports['qs-fuelstations']:GetFuel(vehicle)
        elseif fuelScript == 'lj-fuel' then
            fuel = exports['lj-fuel']:GetFuel(vehicle)
        else
            fuel = exports[fuelScript]:GetFuel(vehicle)
        end
    end)

    return fuel or 100
end

-- =====================================
-- BACKWARDS COMPATIBILITY ALIASES
-- =====================================

function hasPlyLoaded()
    return Bridge.HasPlayerLoaded()
end

function handleVehicleKeys(vehicle)
    Bridge.GiveVehicleKeys(vehicle)
end

function DoNotification(text, type)
    Bridge.Notify(text, type)
end

-- =====================================
-- EXPORTS
-- =====================================

exports('IsPlayerLoaded', Bridge.HasPlayerLoaded)
exports('GetPlayerJob', Bridge.GetJob)
exports('HasJob', Bridge.HasJob)
exports('IsOnDuty', Bridge.IsOnDuty)
-- Note: IsPlayerOnDuty export is in cl_cityworker.lua (has access to isHired variable)
