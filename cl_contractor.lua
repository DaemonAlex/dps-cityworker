--[[
    dps-cityworker — Sub-Contractor Company (client)
    Office ped + /company menu: register, browse/accept contracts, hire crew,
    withdraw funds. All UI through ox_lib so it inherits the house style.
]]

local Config = lib.require('config')
local C = Config.Contractor or {}

local function notify(msg, kind)
    lib.notify({ title = 'Sub-Contractor', description = msg, type = kind or 'inform' })
end

-- Closest other player's server id (for hiring crew)
local function getClosestPlayerServerId()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local closest, closestDist = nil, 5.0
    for _, p in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(p)
        if ped ~= myPed and DoesEntityExist(ped) then
            local d = #(myCoords - GetEntityCoords(ped))
            if d < closestDist then closest = p; closestDist = d end
        end
    end
    return closest and GetPlayerServerId(closest) or nil
end

local openCompanyMenu -- forward declaration

local function openContractsMenu()
    local contracts = lib.callback.await('dps-cityworker:contractor:getOpen', false)
    local options = {}

    if not contracts or #contracts == 0 then
        options[1] = { title = 'No contracts available', description = 'The city posts new work regularly — check back soon.', disabled = true }
    else
        for _, ct in ipairs(contracts) do
            options[#options + 1] = {
                title = ('$%d  —  %d jobs'):format(ct.budget, ct.target_tasks),
                description = ct.description,
                icon = 'clipboard-check',
                onSelect = function()
                    local ok, msg = lib.callback.await('dps-cityworker:contractor:accept', false, ct.id)
                    notify(msg, ok and 'success' or 'error')
                    if ok then openCompanyMenu() end
                end,
            }
        end
    end

    options[#options + 1] = { title = '← Back', icon = 'arrow-left', onSelect = function() openCompanyMenu() end }
    lib.registerContext({ id = 'dps_contracts', title = 'Available City Contracts', options = options })
    lib.showContext('dps_contracts')
end

openCompanyMenu = function()
    local info = lib.callback.await('dps-cityworker:contractor:getCompany', false)

    -- Not an owner yet — offer registration
    if not info then
        local fee = (Config.Economy and Config.Economy.CompanyRegistrationFee) or 5000
        local confirm = lib.alertDialog({
            header = 'Sub-Contractor Office',
            content = ('Register your own city maintenance company for **$%d**?\n\nYou must be a Senior Technician (rank %d) or higher.')
                :format(fee, C.minRankToRegister or 3),
            centered = true, cancel = true,
        })
        if confirm ~= 'confirm' then return end

        local input = lib.inputDialog('Register Company', {
            { type = 'input', label = 'Company Name', required = true, min = 3, max = 40 },
        })
        if not input then return end

        local ok, msg = lib.callback.await('dps-cityworker:contractor:register', false, input[1])
        notify(msg, ok and 'success' or 'error')
        return
    end

    local options = {
        {
            title = info.name,
            description = ('Balance: $%d    Reputation: %d    Crew: %d'):format(info.balance, info.reputation, info.crew or 0),
            icon = 'building',
        },
    }

    if info.active then
        local a = info.active
        local mins = a.deadlineTs and math.max(0, math.floor((a.deadlineTs - os.time()) / 60)) or 0
        options[#options + 1] = {
            title = 'Active Contract',
            description = ('%s\n%d / %d jobs  ·  $%d  ·  %d min left'):format(a.desc, a.progress, a.target, a.budget, mins),
            icon = 'briefcase',
            progress = math.floor((a.progress / math.max(1, a.target)) * 100),
        }
    else
        options[#options + 1] = {
            title = 'Browse Contracts',
            description = 'Accept a city maintenance contract',
            icon = 'clipboard-list', arrow = true,
            onSelect = openContractsMenu,
        }
    end

    options[#options + 1] = {
        title = 'Hire Nearby Worker',
        description = 'Add a nearby on-duty worker to your crew',
        icon = 'user-plus',
        onSelect = function()
            local sid = getClosestPlayerServerId()
            if not sid then notify('No worker nearby', 'error'); return end
            local ok, msg = lib.callback.await('dps-cityworker:contractor:hire', false, sid)
            notify(msg, ok and 'success' or 'error')
        end,
    }

    options[#options + 1] = {
        title = 'Withdraw Funds',
        description = 'Move company balance to your bank',
        icon = 'money-bill-transfer',
        onSelect = function()
            local input = lib.inputDialog('Withdraw Funds', { { type = 'number', label = 'Amount ($)', min = 1 } })
            if not input then return end
            local ok, msg = lib.callback.await('dps-cityworker:contractor:withdraw', false, input[1])
            notify(msg, ok and 'success' or 'error')
            openCompanyMenu()
        end,
    }

    lib.registerContext({ id = 'dps_company', title = 'Sub-Contractor Company', options = options })
    lib.showContext('dps_company')
end

RegisterCommand('company', function() openCompanyMenu() end, false)

-- Office ped players interact with to manage their company
CreateThread(function()
    if not C.enable or not C.bossPed or not Config.BossCoords then return end

    local model = Config.BossModel or `s_m_y_construct_02`
    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 100 do Wait(10); t = t + 1 end
    if not HasModelLoaded(model) then return end

    local c = Config.BossCoords
    local ped = CreatePed(4, model, c.x, c.y, c.z - 1.0, c.w, false, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetModelAsNoLongerNeeded(model)

    exports.ox_target:addLocalEntity(ped, {
        {
            name = 'dps_contractor_office',
            icon = 'fas fa-building',
            label = 'Sub-Contractor Office',
            distance = 2.5,
            onSelect = function() openCompanyMenu() end,
        },
    })
end)
