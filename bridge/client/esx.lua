local ESX = exports["es_extended"]:getSharedObject()

function hasPlyLoaded()
    return ESX.IsPlayerLoaded()
end

function handleVehicleKeys(vehicle)
    -- Basic logic for ESX vehicle keys. 
    -- If you use a specific key script (like qs-keys or cd_garage), update this export.
    local plate = GetVehicleNumberPlateText(vehicle)
    SetVehicleDoorsLocked(vehicle, 1)
    SetVehicleDoorsLockedForAllPlayers(vehicle, false)
end

function DoNotification(text, type)
    if Config.Notify == 'ox_lib' then
        lib.notify({ title = 'City Worker', description = text, type = type })
    else
        ESX.ShowNotification(text)
    end
end

RegisterNetEvent('esx:playerLoaded', function(xPlayer)
    OnPlayerLoaded()
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    OnPlayerUnload()
end)
