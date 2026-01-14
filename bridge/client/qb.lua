local QBCore = exports['qb-core']:GetCoreObject()

function hasPlyLoaded()
    return QBCore.Functions.GetPlayerData().job ~= nil
end

function handleVehicleKeys(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    TriggerEvent("vehiclekeys:client:SetOwner", plate)
end

function DoNotification(text, type)
    if Config.Notify == 'ox_lib' then
        lib.notify({ title = 'City Worker', description = text, type = type })
    else
        QBCore.Functions.Notify(text, type)
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    OnPlayerLoaded()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    OnPlayerUnload()
end)
