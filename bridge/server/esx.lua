local ESX = exports["es_extended"]:getSharedObject()

function GetPlayer(source)
    return ESX.GetPlayerFromId(source)
end

function AddMoney(source, account, amount)
    local xPlayer = GetPlayer(source)
    if xPlayer then
        if account == 'money' or account == 'cash' then
            xPlayer.addMoney(amount)
        else
            xPlayer.addAccountMoney(account, amount)
        end
        return true
    end
    return false
end

function GetCharacterName(source)
    local xPlayer = GetPlayer(source)
    if xPlayer then
        return xPlayer.getName()
    end
    return GetPlayerName(source)
end
