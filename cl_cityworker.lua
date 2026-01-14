local Config = lib.require('config')
local isHired, activeJob = false
local cityBoss, startZone, currZone, currentCone

-- Initialize Blip
local CITY_BLIP = AddBlipForCoord(Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z)
SetBlipSprite(CITY_BLIP, 566)
SetBlipDisplay(CITY_BLIP, 4)
SetBlipScale(CITY_BLIP, 0.8)
SetBlipAsShortRange(CITY_BLIP, true)
SetBlipColour(CITY_BLIP, 5)
BeginTextCommandSetBlipName("STRING")
AddTextComponentSubstringPlayerName("City Worker Job")
EndTextCommandSetBlipName(CITY_BLIP)

-- Helper: Handle Target differences to clean up code
local function AddTargetEntity(entity, options)
    if GetResourceState('ox_target') == 'started' then
        local oxOptions = {}
        for _, opt in ipairs(options) do
            table.insert(oxOptions, {
                icon = opt.icon,
                label = opt.label,
                onSelect = opt.action,
                canInteract = opt.canInteract,
                distance = opt.distance or 1.5
            })
        end
        exports.ox_target:addLocalEntity(entity, oxOptions)
    else
        exports['qb-target']:AddTargetEntity(entity, { options = options, distance = 1.5 })
    end
end

local function RemoveTargetEntity(entity, labels)
    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeLocalEntity(entity, labels)
    else
        exports['qb-target']:RemoveTargetEntity(entity, labels)
    end
end

local function cleanupJob()
    if currZone then
        if GetResourceState('ox_target') == 'started' then
            exports.ox_target:removeZone(currZone)
        else
            exports['qb-target']:RemoveZone(currZone)
        end
        currZone = nil
    end
    if DoesEntityExist(currentCone) then
        DeleteEntity(currentCone)
        currentCone = nil
    end
    if JobBlip then RemoveBlip(JobBlip) end
end

local function resetJob()
    cleanupJob()
    isHired = false
    activeJob = false
    
    if DoesEntityExist(cityBoss) then
        RemoveTargetEntity(cityBoss, {'Start Work', 'Finish Work'})
        DeleteEntity(cityBoss)
        cityBoss = nil
    end
    if startZone then startZone:remove() startZone = nil end
end

local function startWork(netid, data)
    local workVehicle = lib.waitFor(function()
        if NetworkDoesEntityExistWithNetworkId(netid) then
            return NetToVeh(netid)
        end
    end, 'Could not load entity in time.', 3000)

    SetVehicleNumberPlateText(workVehicle, 'CITY'..tostring(math.random(1000, 9999)))
    SetVehicleColours(workVehicle, 111, 111)
    SetVehicleDirtLevel(workVehicle, 1)
    handleVehicleKeys(workVehicle)
    SetVehicleEngineOn(workVehicle, true, true)
    isHired = true
    NextDelivery(data)
    Wait(500)
    
    if Config.FuelScript and Config.FuelScript.enable then
        exports[Config.FuelScript.script]:SetFuel(workVehicle, 100.0)
    else
        Entity(workVehicle).state.fuel = 100
    end
end

local function finishWork()
    local ped = cache.ped
    local pos = GetEntityCoords(ped)
    local finishspot = vec3(Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z)

    if #(pos - finishspot) > 10.0 or not isHired then return end

    local success = lib.callback.await('dps-cityworker:server:clockOut', false)
    if success then
        DoNotification('You ended your shift.', 'success')
        cleanupJob()
        isHired, activeJob = false
    end
end

local function yeetPed()
    if DoesEntityExist(cityBoss) then
        RemoveTargetEntity(cityBoss, {'Start Work', 'Finish Work'})
        DeleteEntity(cityBoss)
        cityBoss = nil
    end
end

local function spawnPed()
    if DoesEntityExist(cityBoss) then return end
    
    lib.requestModel(Config.BossModel)
    cityBoss = CreatePed(0, Config.BossModel, Config.BossCoords, false, false)
    SetEntityAsMissionEntity(cityBoss)
    SetPedFleeAttributes(cityBoss, 0, 0)
    SetBlockingOfNonTemporaryEvents(cityBoss, true)
    SetEntityInvincible(cityBoss, true
