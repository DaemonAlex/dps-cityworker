--[[
    dps-cityworker — Sub-Contractor Company System
    Senior workers found a company, accept city maintenance contracts, and
    fulfil them with tasks completed by the owner + hired crew. Contracts pay a
    lump sum into company funds; the owner withdraws and splits a cut to crew.
]]

local Config = lib.require('config')
local C = Config.Contractor or {}

-- In-memory state
local Companies      = {}   -- [companyId] = { id, name, owner, balance, reputation }
local OwnerToCompany = {}   -- [ownerIdentifier] = companyId
local ActiveByCompany = {}  -- [companyId] = contract row (with .deadlineTs)
local ActiveBySector = {}   -- [sectorId] = companyId
local Crew           = {}   -- [companyId] = { [identifier] = true }  (session crews)

local function regFee()
    return (Config.Economy and Config.Economy.CompanyRegistrationFee) or 5000
end

local sectorIds = {}
for id in pairs(Config.Sectors or {}) do sectorIds[#sectorIds + 1] = id end

-- ─────────────────────────────────────────────────────────────
-- Online-player helpers
-- ─────────────────────────────────────────────────────────────

local function getOnlineByIdentifier(ident)
    if not ident then return nil end
    for _, pid in ipairs(GetPlayers()) do
        local src = tonumber(pid)
        if Bridge.GetIdentifier(src) == ident then return src end
    end
    return nil
end

local function onlineCrewSources(companyId)
    local out, crew = {}, Crew[companyId] or {}
    for _, pid in ipairs(GetPlayers()) do
        local src = tonumber(pid)
        local id = Bridge.GetIdentifier(src)
        if id and crew[id] then out[#out + 1] = src end
    end
    return out
end

-- ─────────────────────────────────────────────────────────────
-- Contract generation
-- ─────────────────────────────────────────────────────────────

local function generateContracts()
    if not C.enable or #sectorIds == 0 then return end

    local open = MySQL.scalar.await("SELECT COUNT(*) FROM city_contracts WHERE status = 'open'") or 0
    local want = (C.maxOpenContracts or 3) - open
    local range = C.targetTasksRange or { 5, 12 }

    for _ = 1, want do
        local sectorId = sectorIds[math.random(#sectorIds)]
        local label = (Config.Sectors[sectorId] and Config.Sectors[sectorId].label) or sectorId
        local target = math.random(range[1], range[2])
        local budget = target * (C.budgetPerTask or 400)
        local desc = ('City maintenance contract — complete %d jobs in %s'):format(target, label)

        MySQL.insert.await(
            "INSERT INTO city_contracts (sector_id, description, budget, status, target_tasks, progress) VALUES (?, ?, ?, 'open', ?, 0)",
            { sectorId, desc, budget, target })
    end
end

-- ─────────────────────────────────────────────────────────────
-- Completion / expiry
-- ─────────────────────────────────────────────────────────────

local function completeContract(companyId, ct)
    local company = Companies[companyId]
    if not company then return end

    company.balance = company.balance + ct.budget
    company.reputation = company.reputation + (C.reputationPerContract or 10)
    MySQL.update.await('UPDATE city_contractors SET balance = ?, reputation = ? WHERE id = ?',
        { company.balance, company.reputation, companyId })
    MySQL.update.await("UPDATE city_contracts SET status = 'completed', progress = ? WHERE id = ?",
        { ct.progress, ct.id })

    -- Split the crew cut among online crew members
    local cut = math.floor(ct.budget * (C.employeeCut or 0.15))
    local members = onlineCrewSources(companyId)
    if #members > 0 and cut > 0 then
        local each = math.floor(cut / #members)
        for _, src in ipairs(members) do
            Bridge.AddMoney(src, 'cash', each, 'contract-crew-bonus')
            Bridge.Notify(src, ('Crew bonus: +$%d — %s contract complete'):format(each, company.name), 'success')
        end
    end

    local ownerSrc = getOnlineByIdentifier(company.owner)
    if ownerSrc then
        Bridge.Notify(ownerSrc, ('Contract complete! +$%d to %s (reputation %d)'):format(ct.budget, company.name, company.reputation), 'success')
    end

    ActiveByCompany[companyId] = nil
    ActiveBySector[ct.sector_id] = nil
    generateContracts()
end

-- Deadline watchdog
CreateThread(function()
    while true do
        Wait(60000)
        if C.enable then
            local now = os.time()
            for companyId, ct in pairs(ActiveByCompany) do
                if ct.deadlineTs and now > ct.deadlineTs then
                    MySQL.update.await("UPDATE city_contracts SET status = 'expired' WHERE id = ?", { ct.id })
                    local company = Companies[companyId]
                    if company then
                        company.reputation = math.max(0, company.reputation - (C.reputationOnExpire or 5))
                        MySQL.update.await('UPDATE city_contractors SET reputation = ? WHERE id = ?', { company.reputation, companyId })
                        local ownerSrc = getOnlineByIdentifier(company.owner)
                        if ownerSrc then
                            Bridge.Notify(ownerSrc, ('Contract expired — %s lost reputation'):format(company.name), 'error')
                        end
                    end
                    ActiveByCompany[companyId] = nil
                    ActiveBySector[ct.sector_id] = nil
                    generateContracts()
                end
            end
        end
    end
end)

-- ─────────────────────────────────────────────────────────────
-- Progress hook — fired by sv_cityworker after each completed task
-- ─────────────────────────────────────────────────────────────

AddEventHandler('dps-cityworker:contractor:taskDone', function(source, sectorId)
    if not C.enable or not sectorId then return end
    local companyId = ActiveBySector[sectorId]
    if not companyId then return end
    local ct = ActiveByCompany[companyId]
    if not ct then return end

    -- Only owner or crew progress the contract
    local id = Bridge.GetIdentifier(source)
    local company = Companies[companyId]
    local isMember = id and (id == company.owner or (Crew[companyId] and Crew[companyId][id]))
    if not isMember then return end

    ct.progress = (ct.progress or 0) + 1
    MySQL.update.await('UPDATE city_contracts SET progress = ? WHERE id = ?', { ct.progress, ct.id })
    Bridge.Notify(source, ('Contract progress: %d/%d'):format(ct.progress, ct.target_tasks or 0), 'inform')

    if ct.progress >= (ct.target_tasks or 0) then
        completeContract(companyId, ct)
    end
end)

-- ─────────────────────────────────────────────────────────────
-- Player actions
-- ─────────────────────────────────────────────────────────────

local function registerCompany(source, name)
    if not C.enable then return false, 'Contractor system is disabled' end
    name = name and name:gsub('^%s*(.-)%s*$', '%1') or ''
    if #name < 3 or #name > 40 then return false, 'Company name must be 3-40 characters' end

    local id = Bridge.GetIdentifier(source)
    if not id then return false, 'Player not found' end
    if OwnerToCompany[id] then return false, 'You already own a company' end

    local rank = exports['dps-cityworker']:GetPlayerSeniority(source) or 1
    if rank < (C.minRankToRegister or 3) then
        return false, ('Requires rank %d (Senior Technician) to register'):format(C.minRankToRegister or 3)
    end

    if MySQL.scalar.await('SELECT id FROM city_contractors WHERE name = ?', { name }) then
        return false, 'That company name is already taken'
    end

    local fee = regFee()
    local account = (Bridge.GetMoney(source, 'bank') >= fee) and 'bank'
        or ((Bridge.GetMoney(source, 'cash') >= fee) and 'cash' or nil)
    if not account then return false, ('You need $%d to register a company'):format(fee) end
    if not Bridge.RemoveMoney(source, account, fee, 'company-registration') then
        return false, 'Payment failed'
    end

    local companyId = MySQL.insert.await(
        'INSERT INTO city_contractors (name, owner_identifier, balance, reputation) VALUES (?, ?, 0, 0)', { name, id })
    Companies[companyId] = { id = companyId, name = name, owner = id, balance = 0, reputation = 0 }
    OwnerToCompany[id] = companyId
    Crew[companyId] = {}
    return true, ('Registered "%s"! Accept city contracts to earn.'):format(name)
end

local function acceptContract(source, contractId)
    local id = Bridge.GetIdentifier(source)
    local companyId = OwnerToCompany[id]
    if not companyId then return false, 'You do not own a company' end
    if ActiveByCompany[companyId] then return false, 'You already have an active contract' end

    local ct = MySQL.single.await("SELECT * FROM city_contracts WHERE id = ? AND status = 'open'", { contractId })
    if not ct then return false, 'That contract is no longer available' end
    if ActiveBySector[ct.sector_id] then return false, 'Another company already holds that sector' end

    local deadlineTs = os.time() + (C.contractDeadline or 3600)
    MySQL.update.await("UPDATE city_contracts SET status = 'assigned', contractor_id = ?, deadline = FROM_UNIXTIME(?) WHERE id = ?",
        { companyId, deadlineTs, contractId })

    ct.status = 'assigned'; ct.contractor_id = companyId; ct.deadlineTs = deadlineTs
    ct.progress = ct.progress or 0
    ActiveByCompany[companyId] = ct
    ActiveBySector[ct.sector_id] = companyId
    generateContracts()
    return true, 'Contract accepted — get your crew to work before the deadline!'
end

local function withdrawFunds(source, amount)
    local id = Bridge.GetIdentifier(source)
    local companyId = OwnerToCompany[id]
    if not companyId then return false, 'You do not own a company' end

    local company = Companies[companyId]
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'Invalid amount' end
    if company.balance < amount then return false, 'Insufficient company balance' end

    company.balance = company.balance - amount
    MySQL.update.await('UPDATE city_contractors SET balance = ? WHERE id = ?', { company.balance, companyId })
    Bridge.AddMoney(source, C.withdrawAccount or 'bank', amount, 'company-withdrawal')
    return true, ('Withdrew $%d to your %s'):format(amount, C.withdrawAccount or 'bank')
end

local function hireWorker(source, targetId)
    local id = Bridge.GetIdentifier(source)
    local companyId = OwnerToCompany[id]
    if not companyId then return false, 'You do not own a company' end

    targetId = tonumber(targetId)
    local targetIdent = targetId and Bridge.GetIdentifier(targetId)
    if not targetIdent then return false, 'No worker found nearby' end
    if targetIdent == id then return false, 'You are the owner' end

    Crew[companyId] = Crew[companyId] or {}
    Crew[companyId][targetIdent] = true
    Bridge.Notify(targetId, ('You joined %s\'s work crew'):format(Companies[companyId].name), 'success')
    return true, ('Added %s to your crew'):format(Bridge.GetCharacterName(targetId))
end

-- ─────────────────────────────────────────────────────────────
-- Callbacks (client menu)
-- ─────────────────────────────────────────────────────────────

lib.callback.register('dps-cityworker:contractor:register', function(source, name)
    return registerCompany(source, name)
end)

lib.callback.register('dps-cityworker:contractor:getCompany', function(source)
    local companyId = OwnerToCompany[Bridge.GetIdentifier(source)]
    if not companyId then return nil end
    local c = Companies[companyId]
    local ct = ActiveByCompany[companyId]
    return {
        name = c.name, balance = c.balance, reputation = c.reputation,
        crew = (function() local n = 0 for _ in pairs(Crew[companyId] or {}) do n = n + 1 end return n end)(),
        active = ct and {
            desc = ct.description, budget = ct.budget,
            progress = ct.progress or 0, target = ct.target_tasks or 0,
            sector = ct.sector_id, deadlineTs = ct.deadlineTs,
        } or nil,
    }
end)

lib.callback.register('dps-cityworker:contractor:getOpen', function()
    return MySQL.query.await(
        "SELECT id, sector_id, description, budget, target_tasks FROM city_contracts WHERE status = 'open' ORDER BY budget DESC") or {}
end)

lib.callback.register('dps-cityworker:contractor:accept', function(source, contractId)
    return acceptContract(source, contractId)
end)

lib.callback.register('dps-cityworker:contractor:withdraw', function(source, amount)
    return withdrawFunds(source, amount)
end)

lib.callback.register('dps-cityworker:contractor:hire', function(source, targetId)
    return hireWorker(source, targetId)
end)

-- ─────────────────────────────────────────────────────────────
-- Startup
-- ─────────────────────────────────────────────────────────────

CreateThread(function()
    if not C.enable then return end

    -- Wait for the DB to be reachable before loading (same cold-boot race as sv_cityworker)
    local rows
    for _ = 1, 20 do
        local ok, res = pcall(MySQL.query.await, 'SELECT id, name, owner_identifier, balance, reputation FROM city_contractors')
        if ok and res then rows = res; break end
        Wait(1000)
    end
    if not rows then
        print('^1[dps-cityworker]^7 Contractor: database not ready — system offline')
        return
    end

    for _, r in ipairs(rows) do
        Companies[r.id] = { id = r.id, name = r.name, owner = r.owner_identifier, balance = r.balance, reputation = r.reputation }
        OwnerToCompany[r.owner_identifier] = r.id
        Crew[r.id] = {}
    end

    local active = MySQL.query.await("SELECT *, UNIX_TIMESTAMP(deadline) AS deadlineTs FROM city_contracts WHERE status = 'assigned'")
    if active then
        for _, ct in ipairs(active) do
            if ct.contractor_id then
                ActiveByCompany[ct.contractor_id] = ct
                ActiveBySector[ct.sector_id] = ct.contractor_id
            end
        end
    end

    generateContracts()
    print('^2[dps-cityworker]^7 Sub-contractor system online (' .. #sectorIds .. ' sectors)')
end)
