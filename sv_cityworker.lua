local Config = lib.require('config')
local Server = lib.require('sv_config')
local Players = {}
local SectorHealth = {}
local ActiveEmergencies = {}
local UsedEmergencyLocations = {} -- Track locations currently in use
local Starting = {}      -- source -> true while a shift is being started (stops a double start)
local Blackouts = {}     -- sectorId -> true while that sector is dark
local Cooldowns = {}     -- source -> { key -> os.time() }
local WeatherBonus = nil -- { type = taskType, untilTs = os.time() } while bad weather pays extra
local T = Config.Task or {}
local E = Config.Emergency or {}

--- True when the player has to wait. Otherwise the wait starts now.
local function onCooldown(source, key, seconds)
    local mine = Cooldowns[source] or {}
    Cooldowns[source] = mine
    local now = os.time()
    if mine[key] and now - mine[key] < seconds then return true end
    mine[key] = now
    return false
end

local function nearBoss(source, range)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local b = Sites.depot()
    return #(GetEntityCoords(ped) - vector3(b.x, b.y, b.z)) <= (range or 15.0)
end

--- On shift or not is decided here and nowhere else. The worker's game reads
--- it from this state, so it can never disagree with the server.
local function setShift(source, on)
    local player = Player(source)
    if player and player.state then player.state:set('dpsCityShift', on and true or nil, true) end
end

-- =====================================
-- ITEM DROP SYSTEM
-- =====================================

-- Weighted random selection for scavenged items
local function GetRandomReward()
    if not Config.ItemDrops or not Config.ItemDrops.items then return nil end

    local totalChance = 0
    for _, item in ipairs(Config.ItemDrops.items) do
        totalChance = totalChance + item.chance
    end

    local randomNum = math.random(1, totalChance)
    local current = 0

    for _, item in ipairs(Config.ItemDrops.items) do
        current = current + item.chance
        if randomNum <= current then
            return item
        end
    end
    return nil
end

-- =====================================
-- DATABASE / PERSISTENCE
-- =====================================

-- Load sector health from database on start.
-- Retries until the DB is actually reachable — a fixed wait races oxmysql's
-- async connection on a cold server boot, which is what threw the intermittent
-- "unable to execute a query" here (the table is fine; the connection wasn't up).
CreateThread(function()
    local results
    for _ = 1, 20 do
        local ok, res = pcall(MySQL.query.await, 'SELECT sector_id, health FROM city_infrastructure')
        if ok and res then results = res; break end
        Wait(1000)
    end

    if results then
        for _, row in ipairs(results) do
            SectorHealth[row.sector_id] = row.health
        end
        print('[dps-cityworker] ^2Loaded sector health from database^0')
    else
        print('[dps-cityworker] ^1Database not ready after 20s — sectors will initialize to defaults^0')
    end

    -- Initialize any missing sectors
    for id, data in pairs(Config.Sectors) do
        if not SectorHealth[id] then
            SectorHealth[id] = 100.0
            MySQL.insert.await('INSERT IGNORE INTO city_infrastructure (sector_id, health) VALUES (?, ?)', {id, 100.0})
        end
    end

    -- A sector that was dark when the server stopped is dark again now
    for id in pairs(Config.Sectors) do SetSectorHealth(id, SectorHealth[id], true) end
end)

-- Save sector health to database
local function SaveSectorHealth(sectorId)
    if SectorHealth[sectorId] then
        MySQL.update.await('UPDATE city_infrastructure SET health = ? WHERE sector_id = ?', {SectorHealth[sectorId], sectorId})
    end
end

--- The only place sector health is changed. It also decides whether the sector
--- is dark: the list of dark sectors lives in GlobalState.dpsCityBlackouts, so a
--- repair clears it for everyone and a player who joins later sees it too.
function SetSectorHealth(sectorId, value, quiet)
    local data = Config.Sectors[sectorId]
    if not data then return end
    SectorHealth[sectorId] = math.max(0.0, math.min(100.0, (tonumber(value) or 0) + 0.0))

    local dark = SectorHealth[sectorId] <= data.blackoutThreshold
    if dark ~= (Blackouts[sectorId] == true) or GlobalState.dpsCityBlackouts == nil then
        Blackouts[sectorId] = dark or nil
        local list = {}
        for id in pairs(Blackouts) do list[id] = true end
        GlobalState.dpsCityBlackouts = list
        if dark then
            print(('[dps-cityworker] ^1GRID ALERT: %s has lost power^0'):format(data.label))
        elseif not quiet then
            print(('[dps-cityworker] ^2%s has power again^0'):format(data.label))
        end
    end
    if not quiet then SaveSectorHealth(sectorId) end
end

-- Save all sectors (called periodically)
local function SaveAllSectors()
    for id, health in pairs(SectorHealth) do
        MySQL.update.await('UPDATE city_infrastructure SET health = ? WHERE sector_id = ?', {health, id})
    end
end

-- =====================================
-- PLAYER STATS
-- =====================================

local function GetPlayerStats(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return { rank = 1, xp = 0, total_repairs = 0 } end

    local result = MySQL.single.await('SELECT `rank`, xp, total_repairs, total_earnings FROM city_worker_users WHERE identifier = ?', {identifier})

    if result then
        return result
    end

    return { rank = 1, xp = 0, total_repairs = 0, total_earnings = 0 }
end

local function SavePlayerStats(source, data)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return end

    MySQL.insert.await([[
        INSERT INTO city_worker_users (identifier, `rank`, xp, total_repairs, total_earnings)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `rank` = VALUES(`rank`), xp = VALUES(xp), total_repairs = VALUES(total_repairs), total_earnings = VALUES(total_earnings)
    ]], {identifier, data.rank, data.xp, data.total_repairs or 0, data.total_earnings or 0})
end

-- =====================================
-- SECTOR / GRID MANAGEMENT
-- =====================================

-- Check if any city workers are currently on duty
local function AnyWorkersOnDuty()
    return next(Players) ~= nil
end

-- Decay Loop: Only decays when workers are on duty.
-- When no workers are clocked in, infrastructure holds steady —
-- the city isn't going to crumble just because nobody took the job today.
-- Auto-recovery kicks in for blackouts so the city self-heals when neglected.
CreateThread(function()
    while true do
        Wait(60000 * 10) -- Run every 10 minutes

        if AnyWorkersOnDuty() then
            -- Normal decay — workers are on duty so the system is "live"
            for id, data in pairs(Config.Sectors) do
                if SectorHealth[id] and SectorHealth[id] > 0 then
                    SetSectorHealth(id, SectorHealth[id] - (data.decayRate / 6))
                end
            end
        else
            -- No workers on duty — auto-recover any sector in blackout
            -- Simulates NPC city crews eventually getting things back online
            for id, data in pairs(Config.Sectors) do
                if SectorHealth[id] and SectorHealth[id] <= data.blackoutThreshold then
                    -- Slowly recover: +2% per tick until just above blackout threshold
                    local target = data.blackoutThreshold + 15
                    if SectorHealth[id] < target then
                        SetSectorHealth(id, math.min(target, SectorHealth[id] + 2.0))
                    end
                end

                -- Also auto-resolve stale emergencies when nobody is on duty
                if ActiveEmergencies[id] then
                    local age = os.time() - ActiveEmergencies[id].startTime
                    if age > 1800 then -- 30 minutes with no response
                        -- Free the location slot
                        if ActiveEmergencies[id].locIndex then
                            UsedEmergencyLocations[ActiveEmergencies[id].locIndex] = nil
                        end
                        ActiveEmergencies[id] = nil
                        TriggerClientEvent('dps-cityworker:client:EmergencyResolved', -1, id)
                        print(('[dps-cityworker] ^3AUTO-RESOLVED: %s emergency cleared (no workers)^0'):format(data.label))
                    end
                end
            end
        end

    end
end)

-- Periodic save
CreateThread(function()
    while true do
        Wait(300000) -- Save every 5 minutes
        SaveAllSectors()
    end
end)

--- The sector a place belongs to: inside a sector's own radius first, else the
--- nearest sector within reach. Most work sites are spread over the city, so
--- without the second step they repaired nothing.
local function GetSectorForCoords(coords)
    local at = vector3(coords.x, coords.y, coords.z)
    local best, bestDist
    for id, data in pairs(Config.Sectors) do
        local d = #(at - data.coords)
        if d < data.radius then return id end
        if d <= (Config.SectorReach or 3000.0) and (not bestDist or d < bestDist) then best, bestDist = id, d end
    end
    return best
end

local function RepairSector(coords, amount)
    local id = GetSectorForCoords(coords)
    if not id or not SectorHealth[id] then return nil, 0 end
    SetSectorHealth(id, SectorHealth[id] + amount)
    return id, SectorHealth[id]
end

-- =====================================
-- WORK VEHICLE
-- =====================================

--- Keys are handed out by the key script on the worker's own game (that is
--- how wasabi_carlock and the other key scripts work), so the server asks it to.
local function giveKeys(source, plate, give)
    if not GetPlayerName(source) then return end
    TriggerClientEvent('dps-cityworker:client:keys', source, plate, give and true or false)
end

--- True when another vehicle is parked where the truck comes out.
local function bayBlocked(ignore)
    local spawn = Sites.truck()
    local at = vector3(spawn.x, spawn.y, spawn.z)
    for _, veh in ipairs(GetAllVehicles()) do
        if veh ~= ignore and DoesEntityExist(veh) and #(GetEntityCoords(veh) - at) < 5.0 then return true end
    end
    return false
end

--- Spawns the work truck at the depot. Returns the entity and its plate, or nil
--- when the game never made it (the old code waited for ever).
local function createWorkVehicle(source)
    local spawn = Sites.truck()
    local veh = CreateVehicle(Server.Vehicle, spawn.x, spawn.y, spawn.z, spawn.w, true, true)

    local waited = 0
    while not DoesEntityExist(veh) do
        Wait(50)
        waited = waited + 50
        if waited >= 5000 then return nil end
    end

    local plate = ('CITY%04d'):format(math.random(0, 9999))
    SetVehicleNumberPlateText(veh, plate)
    SetVehicleColours(veh, 111, 111)
    SetVehicleDirtLevel(veh, 1.0)
    giveKeys(source, plate, true)

    local ped = GetPlayerPed(source)
    if ped and ped ~= 0 then TaskWarpPedIntoVehicle(ped, veh, -1) end
    return veh, plate
end

local function removeWorkVehicle(source)
    local p = Players[source]
    if not p then return end
    if p.plate then giveKeys(source, p.plate, false) end
    if p.entity and DoesEntityExist(p.entity) then DeleteEntity(p.entity) end
    p.entity, p.plate = nil, nil
end

-- =====================================
-- TASK SYSTEM
-- =====================================

-- Task types with different properties
-- `checks` is the skill check the worker gets at the end of the work.
local TaskTypes = {
    -- Rank 1
    pipe = { label = 'Water Pipe Repair', xp = 20, repairAmount = 2.0, difficulty = 'easy', minRank = 1, category = 'maintenance', checks = { 'easy', 'easy' } },
    pothole = { label = 'Pothole Repair', xp = 15, repairAmount = 1.5, difficulty = 'easy', minRank = 1, category = 'road', checks = { 'easy' } },
    meter_reading = { label = 'Meter Reading', xp = 10, repairAmount = 0.5, difficulty = 'easy', minRank = 1, category = 'utility' },

    -- Rank 2
    hydrant = { label = 'Fire Hydrant Repair', xp = 22, repairAmount = 1.5, difficulty = 'medium', minRank = 2, category = 'maintenance' },
    manhole = { label = 'Manhole Check', xp = 28, repairAmount = 2.0, difficulty = 'medium', minRank = 2, category = 'sewer' },
    storm_drain = { label = 'Storm Drain Clearing', xp = 25, repairAmount = 2.0, difficulty = 'medium', minRank = 2, category = 'sewer' },

    -- Rank 3
    electrical = { label = 'Electrical Box Repair', xp = 35, repairAmount = 3.0, difficulty = 'medium', minRank = 3, category = 'electrical', checks = { 'medium', 'medium' } },

    -- Rank 4
    transformer = { label = 'Transformer Maintenance', xp = 50, repairAmount = 5.0, difficulty = 'hard', minRank = 4, category = 'electrical', checks = { 'medium', 'hard' } },
    bridge_inspection = { label = 'Bridge Inspection', xp = 55, repairAmount = 4.0, difficulty = 'hard', minRank = 4, category = 'maintenance' },
    utility_locating = { label = 'Utility Locating', xp = 45, repairAmount = 2.0, difficulty = 'hard', minRank = 4, category = 'utility' },

    -- Emergencies (only happen at spots saved with /cityspot emergency)
    water_main = { label = 'Water Main Break', xp = 80, repairAmount = 8.0, difficulty = 'hard', minRank = 2, category = 'emergency', isEmergency = true },
    gas_leak = { label = 'Gas Leak Response', xp = 100, repairAmount = 10.0, difficulty = 'hard', minRank = 3, category = 'emergency', isEmergency = true },
    downed_lines = { label = 'Downed Power Lines', xp = 90, repairAmount = 9.0, difficulty = 'hard', minRank = 4, category = 'emergency', isEmergency = true },
    fallen_tree = { label = 'Fallen Tree Removal', xp = 70, repairAmount = 6.0, difficulty = 'medium', minRank = 2, category = 'emergency', isEmergency = true },
}

--- The saved spots for one kind of job, as a list of places.
local function locationsFor(taskType)
    local list = {}
    for _, site in ipairs(Sites.of(taskType)) do list[#list + 1] = site.coords end
    return list
end

--- How many job spots are saved in all (emergency spots not counted).
local function workSiteCount()
    local n = 0
    for id, task in pairs(TaskTypes) do
        if not task.isEmergency then n = n + #Sites.of(id) end
    end
    return n
end

--- The job types this rank can be given right now: only ones that have a saved spot.
local function tasksForRank(rank)
    local available = {}
    for taskId, task in pairs(TaskTypes) do
        if not task.isEmergency and rank >= task.minRank and #Sites.of(taskId) > 0 then
            available[#available + 1] = taskId
        end
    end
    return available
end

--- How long the work itself takes, in seconds. The client shows a bar this
--- long and the server will not pay before it has passed.
local function TaskSeconds(taskType)
    local task = TaskTypes[taskType]
    local map = T.seconds or { easy = 6, medium = 8, hard = 12 }
    return map[task and task.difficulty or 'easy'] or 8
end

-- =====================================
-- EMERGENCY EVENT SYSTEM
-- =====================================

--- A saved emergency spot that belongs to this sector and is not in use.
--- No spot there means no emergency there: the place is never made up.
local function GetEmergencyLocation(sectorId)
    local candidates = {}
    for _, site in ipairs(Sites.of('emergency')) do
        if not UsedEmergencyLocations[site.id] and GetSectorForCoords(site.coords) == sectorId then
            candidates[#candidates + 1] = site
        end
    end
    if #candidates == 0 then return nil end
    local pick = candidates[math.random(#candidates)]
    UsedEmergencyLocations[pick.id] = sectorId
    return pick.coords, pick.id
end

--- Tell the workers who can deal with it. Nobody else gets the alert.
local function alertWorkers(sectorId)
    local em = ActiveEmergencies[sectorId]
    local task = em and TaskTypes[em.type]
    if not task then return end
    for src, p in pairs(Players) do
        if p.rank >= task.minRank then
            TriggerClientEvent('dps-cityworker:client:EmergencyAlert', src, {
                type = em.type,
                label = task.label,
                sector = sectorId,
                sectorLabel = Config.Sectors[sectorId].label,
                coords = em.coords,
                xpBonus = task.xp,
            })
        end
    end
end

local function TriggerEmergencyEvent(eventType, sectorId)
    if ActiveEmergencies[sectorId] then return false end -- Already active emergency

    local sector = Config.Sectors[sectorId]
    if not sector then return false end

    local task = TaskTypes[eventType]
    if not task or not task.isEmergency then return false end

    local emergencyCoords, locIndex = GetEmergencyLocation(sectorId)
    if not emergencyCoords then return false end

    ActiveEmergencies[sectorId] = {
        type = eventType,
        coords = emergencyCoords,
        startTime = os.time(),
        resolved = false,
        locIndex = locIndex, -- Track which pre-defined location was used
    }

    -- Reduce sector health — but never push directly into blackout from a single event
    -- Emergencies create urgency, not instant catastrophe
    local healthPenalty = task.repairAmount * 2
    local floor = sector.blackoutThreshold + 5
    SetSectorHealth(sectorId, math.max(floor, SectorHealth[sectorId] - healthPenalty))

    alertWorkers(sectorId)

    print(('[dps-cityworker] ^1EMERGENCY: %s in %s!^0'):format(task.label, sector.label))
    return true
end

local function ResolveEmergency(sectorId, source)
    if not ActiveEmergencies[sectorId] then return false end

    local emergency = ActiveEmergencies[sectorId]
    local task = TaskTypes[emergency.type]

    -- Bonus XP and payment for emergency response
    if source and Players[source] then
        local bonusXp = math.floor(task.xp * (E.BonusMultiplier or 1.5))
        local bonusPayment = math.floor(Config.Economy.BasePay * (E.PaymentMultiplier or 2.0))

        Players[source].xp = Players[source].xp + bonusXp
        Bridge.AddMoney(source, Server.Account or 'cash', bonusPayment, 'emergency-response-bonus')
        Bridge.Notify(source, ('Emergency resolved! Bonus: +$%d, +%d XP'):format(bonusPayment, bonusXp), 'success')
    end

    -- Restore sector health
    SetSectorHealth(sectorId, SectorHealth[sectorId] + task.repairAmount)

    -- Free the pre-defined location slot so it can be reused
    if emergency.locIndex then
        UsedEmergencyLocations[emergency.locIndex] = nil
    end

    ActiveEmergencies[sectorId] = nil

    -- Notify all clients
    TriggerClientEvent('dps-cityworker:client:EmergencyResolved', -1, sectorId)

    return true
end

--- From these emergency kinds, the ones a worker on shift has the rank for.
--- An emergency nobody on shift may touch is not started.
local function doableEmergencies(kinds)
    local top = 0
    for _, p in pairs(Players) do if p.rank > top then top = p.rank end end
    local out = {}
    for _, kind in ipairs(kinds) do
        if TaskTypes[kind] and top >= TaskTypes[kind].minRank then out[#out + 1] = kind end
    end
    return out
end

-- Random emergency event spawner
-- Only fires when workers are on duty — no point breaking things nobody can fix
CreateThread(function()
    Wait(300000) -- Wait 5 minutes before first potential emergency

    while true do
        Wait(600000) -- Check every 10 minutes

        if not AnyWorkersOnDuty() then goto continue end

        if math.random(100) <= (E.RandomChance or 15) then
            local sectors = {}
            for id, _ in pairs(Config.Sectors) do
                if not ActiveEmergencies[id] then
                    table.insert(sectors, id)
                end
            end

            if #sectors > 0 then
                local randomSector = sectors[math.random(#sectors)]
                local emergencyTypes = doableEmergencies({'water_main', 'gas_leak', 'downed_lines', 'fallen_tree'})
                if #emergencyTypes > 0 then
                    TriggerEmergencyEvent(emergencyTypes[math.random(#emergencyTypes)], randomSector)
                end
            end
        end

        ::continue::
    end
end)

-- =====================================
-- WEATHER-TRIGGERED EVENTS
-- =====================================

-- The server reads the weather itself (GlobalState.weather.weather, kept filled
-- by dps-fixes). The old code let any worker's game say "it is storming".
local LastWeatherEvent = 0
local RAIN = { RAIN = true, CLEARING = true }
local STORM = { THUNDER = true }

local function freeSectors()
    local sectors = {}
    for id in pairs(Config.Sectors) do
        if not ActiveEmergencies[id] then sectors[#sectors + 1] = id end
    end
    return sectors
end

CreateThread(function()
    while true do
        Wait(300000) -- every 5 minutes
        local state = GlobalState.weather
        local weather = type(state) == 'table' and state.weather or state
        weather = type(weather) == 'string' and weather:upper() or nil
        local now = os.time()

        if weather and AnyWorkersOnDuty() and now - LastWeatherEvent >= (E.WeatherCooldown or 900) then
            if STORM[weather] and math.random(100) <= 40 then
                local sectors = freeSectors()
                local kinds = doableEmergencies({ 'fallen_tree', 'downed_lines' })
                if #sectors > 0 and #kinds > 0
                    and TriggerEmergencyEvent(kinds[math.random(#kinds)], sectors[math.random(#sectors)]) then
                    LastWeatherEvent = now
                end
            elseif (RAIN[weather] or STORM[weather]) and math.random(100) <= 30 then
                WeatherBonus = { type = 'storm_drain', untilTs = now + 600 }
                LastWeatherEvent = now
                for src in pairs(Players) do
                    TriggerClientEvent('dps-cityworker:client:WeatherTaskBonus', src, {
                        type = 'storm_drain',
                        label = 'Storm Drain Clearing',
                        message = 'Heavy rain is flooding the drains. Storm drain jobs pay 25% more for 10 minutes.',
                    })
                end
            end
        end
    end
end)

--- The sector in the worst shape, when one is below the "needs work" line.
local function neediestSector()
    local worst, worstHealth
    for id in pairs(Config.Sectors) do
        local h = SectorHealth[id]
        if h and h < (T.needyBelow or 60) and (not worstHealth or h < worstHealth) then worst, worstHealth = id, h end
    end
    return worst
end

--- Pick where the next job is. Never the place the worker is standing at, so a
--- new job always means a drive. Half the time it goes to the sector that
--- needs work most.
local function pickLocation(taskType, from, last)
    local minTravel = T.minTravel or 150.0
    local near, far = {}, {}
    for _, loc in ipairs(locationsFor(taskType)) do
        local same = last and #(loc - last) < 5.0
        if not same then
            if #(loc - from) >= minTravel then far[#far + 1] = loc else near[#near + 1] = loc end
        end
    end
    local pool = #far > 0 and far or near
    if #pool == 0 then return nil end

    local needy = neediestSector()
    if needy and math.random(2) == 1 then
        local there = {}
        for _, loc in ipairs(pool) do
            if GetSectorForCoords(loc) == needy then there[#there + 1] = loc end
        end
        if #there > 0 then pool = there end
    end
    return pool[math.random(#pool)]
end

--- What the worker's game is told about a job.
local function taskView(job)
    local task = TaskTypes[job.type]
    return {
        id = job.id,
        location = job.location,
        taskType = job.type,
        type = job.type,
        label = task.label,
        category = task.category,
        difficulty = task.difficulty,
        seconds = TaskSeconds(job.type),
        checks = task.checks or Config.SkillCheck.Difficulty,
        assignedBy = job.assignedBy,
    }
end

--- Give this worker a job. The job is a ticket the server keeps: its id, where
--- it is, when it was handed out and where the worker stood at that moment.
--- Pay is only ever made against the ticket.
local function issueTask(source, forcedType)
    local p = Players[source]
    if not p then return nil end
    local ped = GetPlayerPed(source)
    local from = (ped and ped ~= 0) and GetEntityCoords(ped) or Sites.depot().xyz

    -- Try the job types in a mixed-up order until one has a spot to go to.
    -- Bad weather: the job that pays extra is tried first half the time.
    local order = forcedType and { forcedType } or tasksForRank(p.rank)
    for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    if not forcedType and WeatherBonus and os.time() < WeatherBonus.untilTs and math.random(2) == 1 then
        for i, id in ipairs(order) do
            if id == WeatherBonus.type then order[1], order[i] = order[i], order[1] break end
        end
    end

    local taskType, location
    for _, id in ipairs(order) do
        local at = pickLocation(id, from, p.lastLocation)
        if at then taskType, location = id, at break end
    end
    if not location then
        p.task, p.taskType, p.location = nil, nil, nil
        return nil
    end

    p.taskSeq = (p.taskSeq or 0) + 1
    p.task = {
        id = p.taskSeq,
        type = taskType,
        location = location,
        from = from,
        issuedAt = os.time(),
        startedAt = nil,
    }
    p.taskType, p.location = taskType, location   -- read by the crew list
    return taskView(p.task)
end

-- Teamwork bonus calculation (defined here so Payment callback can use it)
local function CalculateTeamworkBonus(source)
    local sourcePed = GetPlayerPed(source)
    if not sourcePed then return 1.0 end

    local sourceCoords = GetEntityCoords(sourcePed)
    local nearbyCount = 0

    for playerId, _ in pairs(Players) do
        if playerId ~= source then
            local ped = GetPlayerPed(playerId)
            if ped and DoesEntityExist(ped) then
                local coords = GetEntityCoords(ped)
                if #(sourceCoords - coords) <= 30.0 then
                    nearbyCount = nearbyCount + 1
                end
            end
        end
    end

    -- 10% bonus per nearby worker, max 30%
    return 1.0 + math.min(nearbyCount * 0.10, 0.30)
end

-- =====================================
-- CALLBACKS
-- =====================================

--- Start of shift. Answers with a table:
---   { ok = true, netid = truck, task = first job }
---   { ok = true, resume = true, task = current job }   already on shift
---   { ok = false, msg = why }
lib.callback.register('dps-cityworker:server:spawnVehicle', function(source)
    if Starting[source] then return { ok = false } end
    local running = Players[source]
    if running then
        -- The worker's game lost track of the shift. Hand it back, do not lock them out.
        setShift(source, true)
        return { ok = true, resume = true, task = running.task and taskView(running.task) or nil }
    end
    -- Shifts start at the depot, next to the boss. Not from anywhere on the map.
    if not nearBoss(source, 15.0) then return { ok = false, msg = 'Go to the depot to start work' } end
    if not Bridge.GetIdentifier(source) then return { ok = false } end
    if workSiteCount() < 2 then
        return { ok = false, msg = 'The city has no work sites set up yet' }
    end
    if bayBlocked() then return { ok = false, msg = 'A vehicle is in the way where the truck comes out. Move it first.' } end

    Starting[source] = true
    local ok, netid, taskData = pcall(function()
        local stats = GetPlayerStats(source)
        if #tasksForRank(stats.rank) == 0 then return false end
        local veh, plate = createWorkVehicle(source)
        if not veh then return nil end
        if not GetPlayerName(source) then      -- left while the truck was spawning
            if DoesEntityExist(veh) then DeleteEntity(veh) end
            return nil
        end
        Players[source] = {
            entity = veh,
            plate = plate,
            rank = stats.rank,
            xp = stats.xp,
            total_repairs = stats.total_repairs or 0,
            total_earnings = stats.total_earnings or 0,
        }
        setShift(source, true)
        local view = issueTask(source)
        if view then view.rank = stats.rank end
        return NetworkGetNetworkIdFromEntity(veh), view
    end)
    Starting[source] = nil

    if not ok then
        print(('[dps-cityworker] ^1start of shift failed for %s: %s^0'):format(source, tostring(netid)))
        return { ok = false }
    end
    if netid == false then return { ok = false, msg = 'There is no work for your rank yet' } end
    if not netid then return { ok = false, msg = 'The depot could not bring a truck out. Try again.' } end
    return { ok = true, netid = netid, task = taskData }
end)

--- A wrecked or lost truck is replaced at the depot.
lib.callback.register('dps-cityworker:server:newTruck', function(source)
    local p = Players[source]
    if not p or Starting[source] then return false, 'You are not on shift' end
    if not nearBoss(source, 15.0) then return false, 'Go to the depot for a new truck' end
    if bayBlocked(p.entity) then return false, 'A vehicle is in the way where the truck comes out. Move it first.' end
    if onCooldown(source, 'newTruck', T.truckCooldown or 120) then return false, 'The depot needs a few minutes to get another truck ready' end

    Starting[source] = true
    removeWorkVehicle(source)
    local veh, plate = createWorkVehicle(source)
    Starting[source] = nil
    if not veh then return false, 'The depot could not bring a truck out. Try again.' end
    if not Players[source] then
        if DoesEntityExist(veh) then DeleteEntity(veh) end
        return false
    end
    p.entity, p.plate = veh, plate
    return NetworkGetNetworkIdFromEntity(veh)
end)

local function endShift(source)
    local p = Players[source]
    if not p then return false end
    pcall(SavePlayerStats, source, p)
    removeWorkVehicle(source)
    Players[source] = nil
    if GetPlayerName(source) then setShift(source, false) end
    return true
end

lib.callback.register('dps-cityworker:server:clockOut', function(source)
    if not nearBoss(source, 20.0) then return false end
    return endShift(source)
end)

--- Switching character ends the shift: the truck goes, the stats are saved
--- for the character that earned them.
local function onLogout(src)
    src = tonumber(src) or source
    if src and endShift(src) then Cooldowns[src] = nil end
end
AddEventHandler('QBCore:Server:OnPlayerUnload', onLogout)
AddEventHandler('esx:playerLogout', onLogout)

-- Cleanup when player drops
AddEventHandler('playerDropped', function()
    local source = source
    endShift(source)
    Starting[source] = nil
    Cooldowns[source] = nil
end)

-- Stopping the script takes every work truck with it, saves every worker,
-- and tells them their shift is over instead of leaving them guessing.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for source, p in pairs(Players) do
        pcall(SavePlayerStats, source, p)
        if p.entity and DoesEntityExist(p.entity) then DeleteEntity(p.entity) end
        pcall(setShift, source, false)
        pcall(Bridge.Notify, source, 'The city depot is restarting. Your shift has ended and your work is saved. Clock in again at the depot.', 'inform')
    end
end)

-- A shift never outlives the script: clear any state left from before a crash.
CreateThread(function()
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and Player(src).state.dpsCityShift then setShift(src, false) end
    end
end)

--- The worker says "I am starting the work now". The server checks they are at
--- the job with their truck, and notes the time. Pay needs this first.
lib.callback.register('dps-cityworker:server:BeginTask', function(source, taskId)
    local p = Players[source]
    local job = p and p.task
    if not job or job.id ~= taskId then return false, 'That is not your current job' end

    local pos = GetEntityCoords(GetPlayerPed(source))
    if #(pos - job.location) > (Config.TaskCompleteDistance or 12.0) then return false, 'You are not at the work site' end

    if (T.truckDistance or 80.0) > 0 and not (T.noTruck and T.noTruck[job.type]) then
        if not p.entity or not DoesEntityExist(p.entity) then
            return false, 'Your work truck is gone. Get a new one at the depot.'
        end
        if #(GetEntityCoords(p.entity) - job.location) > T.truckDistance then
            return false, 'Bring your work truck to the site. The tools are in it.'
        end
    end

    job.startedAt = os.time()
    return true, TaskSeconds(job.type)
end)

lib.callback.register('dps-cityworker:server:Payment', function(source, taskId)
    local ped = GetPlayerPed(source)
    local pos = GetEntityCoords(ped)

    local playerData = Players[source]
    if not playerData then return false, nil end

    -- Pay is made against the job ticket: the right job, started at the site,
    -- the work time passed, and the worker still there.
    local job = playerData.task
    if not job or job.id ~= taskId or job.paying then return false, nil end
    if not job.startedAt then return false, nil end
    if os.time() - job.startedAt < TaskSeconds(job.type) - 1 then return false, nil end
    if #(pos - job.location) > (Config.TaskCompleteDistance or 12.0) then return false, nil end
    job.paying = true

    local taskType = job.type
    local task = TaskTypes[taskType] or TaskTypes.pipe

    -- 1. Calculate Pay based on Rank + Teamwork Bonus
    local rankData = Config.Ranks[playerData.rank] or Config.Ranks[1]
    local teamworkBonus = CalculateTeamworkBonus(source)
    local teamworkPercent = math.floor((teamworkBonus - 1.0) * 100 + 0.5)
    local payment = Config.Economy.BasePay * rankData.payMultiplier * teamworkBonus
    if WeatherBonus and WeatherBonus.type == taskType and os.time() < WeatherBonus.untilTs then
        payment = payment * 1.25
    end
    -- Driving money: a job across the map pays more than one round the corner
    local travel = #(job.location - job.from)
    local travelPay = math.min(Config.Economy.TravelPayMax or 400,
        math.floor(travel / 100.0) * (Config.Economy.TravelPayPer100m or 8))
    payment = math.floor(payment) + travelPay

    -- 2. Add Money (using configured currency)
    local account = Config.Economy.Currency or Server.Account or 'cash'
    local success = Bridge.AddMoney(source, account, payment, 'city-worker-payment')

    if not success then
        job.paying = nil
        print(('[dps-cityworker] ^1ERROR: Failed to pay %s^0'):format(source))
        return false, nil
    end

    -- The ticket is used up. It cannot be paid twice.
    playerData.task = nil
    playerData.lastLocation = job.location

    -- 3. Repair sector health
    local sectorId, newHealth = RepairSector(job.location, task.repairAmount)

    -- 3.5. Contractor system: count this task toward any active company contract in the sector
    if sectorId then
        TriggerEvent('dps-cityworker:contractor:taskDone', source, sectorId)
    end

    -- 4. Handle XP and Progression
    local xpGain = task.xp + math.random(-5, 10)
    playerData.xp = playerData.xp + xpGain
    playerData.total_repairs = (playerData.total_repairs or 0) + 1
    playerData.total_earnings = (playerData.total_earnings or 0) + payment

    -- 5. Check for Rank Up
    local xpNeeded = playerData.rank * 1000
    local rankUp = false

    if playerData.xp >= xpNeeded and Config.Ranks[playerData.rank + 1] then
        playerData.rank = playerData.rank + 1
        rankUp = true
        Bridge.Notify(source, 'Promoted to ' .. Config.Ranks[playerData.rank].label .. '!', 'success')
    end

    -- 5.5. Scavenging / Item Drops
    local foundItem = nil
    if Config.ItemDrops and Config.ItemDrops.enabled then
        local dropChance = math.random(1, 100)
        if dropChance <= Config.ItemDrops.chance then
            local reward = GetRandomReward()
            if reward then
                local amount = math.random(reward.min, reward.max)
                local itemSuccess = Bridge.AddItem(source, reward.name, amount)

                if itemSuccess then
                    foundItem = { name = reward.name, amount = amount }
                    Bridge.Notify(source, ('Found materials: %dx %s'):format(amount, reward.name), 'inform')
                    if Config.Debug then
                        print(('[DPS-CityWorker] Player %s found %dx %s'):format(source, amount, reward.name))
                    end
                end
            end
        end
    end

    -- 6. The next job
    local nextTask = issueTask(source)

    -- 7. Save stats
    SavePlayerStats(source, playerData)

    return true, {
        payment = payment,
        xp = xpGain,
        totalXp = playerData.xp,
        rank = playerData.rank,
        rankUp = rankUp,
        travelPay = travelPay,
        teamwork = teamworkPercent,
        sectorId = sectorId,
        sectorLabel = sectorId and Config.Sectors[sectorId].label or nil,
        sectorHealth = newHealth,
        foundItem = foundItem, -- Scavenged item (nil if none found)
        nextTask = nextTask,
    }
end)

--- A job the worker cannot get to can be swapped for another, but not often.
--- (The old GetNextTask swapped as often as you asked, which was the pay loop.)
lib.callback.register('dps-cityworker:server:SkipTask', function(source)
    local p = Players[source]
    if not p then return false, 'You are not on shift' end
    local wait = T.skipCooldown or 600
    if onCooldown(source, 'skip', wait) then
        return false, ('You can swap a job once every %d minutes'):format(math.ceil(wait / 60))
    end
    if p.task then p.lastLocation = p.task.location end
    local view = issueTask(source)
    if not view then return false, 'There is no other work site for you right now' end
    return true, view
end)

--- Is this player on shift, and on which job. Asked by a game that just
--- started this script (a restart on their side, a crash and rejoin).
lib.callback.register('dps-cityworker:server:ShiftState', function(source)
    local p = Players[source]
    if not p then return false end
    return true, p.task and taskView(p.task) or nil
end)

--- No job right now (every spot was just used): ask for one.
lib.callback.register('dps-cityworker:server:RequestTask', function(source)
    local p = Players[source]
    if not p then return false, 'You are not on shift' end
    if p.task then return true, taskView(p.task) end
    if onCooldown(source, 'request', 10) then return false, 'Give it a few seconds' end
    local view = issueTask(source)
    if not view then return false, 'There is no work site for you right now' end
    return true, view
end)

lib.callback.register('dps-cityworker:server:GetSectorHealth', function(source)
    local data = {}
    for id, health in pairs(SectorHealth) do
        data[id] = {
            health = health,
            label = Config.Sectors[id] and Config.Sectors[id].label or id,
        }
    end
    return data
end)

lib.callback.register('dps-cityworker:server:GetPlayerStats', function(source)
    if Players[source] then
        return {
            rank = Players[source].rank,
            rankLabel = Config.Ranks[Players[source].rank].label,
            xp = Players[source].xp,
            xpNeeded = Players[source].rank * 1000,
            total_repairs = Players[source].total_repairs,
            total_earnings = Players[source].total_earnings,
        }
    end
    return GetPlayerStats(source)
end)

-- =====================================
-- CONTROL ROOM (FOREMAN ONLY)
-- =====================================

--- Staff can open the Control Room without being a Foreman.
local function isStaff(source)
    return IsPlayerAceAllowed(source, 'command.setsectorhealth')
end

local function canControl(source)
    local p = Players[source]
    return (p and p.rank >= 5) or isStaff(source)
end

--- Everything the Control Room screen shows. All of it is read here, live.
local function controlData()
    local sectors = {}
    for id, cfg in pairs(Config.Sectors) do
        local em = ActiveEmergencies[id]
        local sites = 0
        for taskId, task in pairs(TaskTypes) do
            if not task.isEmergency then
                for _, site in ipairs(Sites.of(taskId)) do
                    if GetSectorForCoords(site.coords) == id then sites = sites + 1 end
                end
            end
        end
        sectors[#sectors + 1] = {
            id = id,
            label = cfg.label,
            health = SectorHealth[id] or 100.0,
            dark = Blackouts[id] == true,
            emergency = em and TaskTypes[em.type] and TaskTypes[em.type].label or nil,
            emergencyMinutes = em and math.floor((os.time() - em.startTime) / 60) or nil,
            sites = sites,
        }
    end
    table.sort(sectors, function(a, b) return a.label < b.label end)

    local workers = {}
    for src, p in pairs(Players) do
        local sectorId = p.task and GetSectorForCoords(p.task.location)
        workers[#workers + 1] = {
            id = src,
            name = Bridge.GetCharacterName(src) or ('Worker ' .. src),
            rank = Config.Ranks[p.rank] and Config.Ranks[p.rank].label or tostring(p.rank),
            job = p.task and TaskTypes[p.task.type] and TaskTypes[p.task.type].label or nil,
            working = p.task and p.task.startedAt ~= nil or false,
            sector = sectorId and Config.Sectors[sectorId].label or nil,
        }
    end
    table.sort(workers, function(a, b) return a.name < b.name end)

    local reports = {}
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT id, sector_id, damage_type, TIMESTAMPDIFF(MINUTE, created_at, NOW()) AS age
        FROM city_damage_reports WHERE repaired = 0 ORDER BY id DESC LIMIT 30
    ]])
    for _, row in ipairs(ok and rows or {}) do
        reports[#reports + 1] = {
            id = row.id,
            sector = Config.Sectors[row.sector_id] and Config.Sectors[row.sector_id].label or row.sector_id,
            type = row.damage_type,
            age = row.age or 0,
        }
    end

    return { sectors = sectors, workers = workers, reports = reports }
end

lib.callback.register('dps-cityworker:server:OpenControlRoom', function(source)
    if not canControl(source) then
        Bridge.Notify(source, 'Only Foremen can access the Control Room', 'error')
        return false, nil
    end
    return true, controlData()
end)

--- Send one worker to a sector: they get a job at a saved spot in that sector.
lib.callback.register('dps-cityworker:server:DispatchWorker', function(source, targetId, sectorId)
    if not canControl(source) then return false, 'Only Foremen can dispatch' end
    targetId = tonumber(targetId)
    local target = targetId and Players[targetId]
    if not target then return false, 'That worker is not on shift' end
    if not Config.Sectors[sectorId] then return false, 'Invalid sector' end
    if target.task and target.task.startedAt then return false, 'That worker is in the middle of a job' end

    -- Jobs this worker has the rank for, that have a spot in the sector
    local options = {}
    for _, taskId in ipairs(tasksForRank(target.rank)) do
        for _, site in ipairs(Sites.of(taskId)) do
            if GetSectorForCoords(site.coords) == sectorId
                and not (target.task and #(site.coords - target.task.location) < 5.0) then
                options[#options + 1] = { type = taskId, coords = site.coords }
            end
        end
    end
    if #options == 0 then return false, 'No work site for that worker in ' .. Config.Sectors[sectorId].label end
    if onCooldown(source, 'assign:' .. targetId, 300) then
        return false, 'You sent that worker somewhere a few minutes ago'
    end

    local pick = options[math.random(#options)]
    local ped = GetPlayerPed(targetId)
    target.taskSeq = (target.taskSeq or 0) + 1
    target.task = {
        id = target.taskSeq,
        type = pick.type,
        location = pick.coords,
        from = (ped and ped ~= 0) and GetEntityCoords(ped) or pick.coords,
        issuedAt = os.time(),
        assignedBy = Bridge.GetCharacterName(source),
    }
    target.taskType, target.location = pick.type, pick.coords
    TriggerClientEvent('dps-cityworker:client:TaskAssigned', targetId, taskView(target.task))
    return true, ('Sent to %s: %s'):format(Config.Sectors[sectorId].label, TaskTypes[pick.type].label)
end)

--- A damage report has been dealt with: it leaves the list.
lib.callback.register('dps-cityworker:server:CloseReport', function(source, reportId)
    if not canControl(source) then return false end
    reportId = tonumber(reportId)
    if not reportId then return false end
    local changed = MySQL.update.await(
        'UPDATE city_damage_reports SET repaired = 1, repaired_by = ?, repaired_at = NOW() WHERE id = ? AND repaired = 0',
        { Bridge.GetIdentifier(source), reportId })
    return (changed or 0) > 0
end)

-- =====================================
-- DAMAGE REPORTS
-- =====================================

local DamageTypes = { general = true, pothole = true, streetlight = true, pipe = true, electrical = true }

--- A worker on shift reports damage where they stand. The place is read by the
--- server, never sent by the worker's game.
local function reportDamage(source, damageType)
    if not Players[source] then return false, 'You are not on shift' end
    damageType = DamageTypes[damageType] and damageType or 'general'
    if onCooldown(source, 'report', 120) then return false, 'You reported something a moment ago' end

    local coords = GetEntityCoords(GetPlayerPed(source))
    local sectorId = GetSectorForCoords(coords)
    if not sectorId then return false, 'This is outside the city\'s work area' end

    MySQL.insert.await([[
        INSERT INTO city_damage_reports (sector_id, damage_type, coords_x, coords_y, coords_z, reported_by)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], {sectorId, damageType, coords.x, coords.y, coords.z, Bridge.GetIdentifier(source)})

    -- A reported fault wears the sector down a little
    SetSectorHealth(sectorId, SectorHealth[sectorId] - 0.5)
    return true, 'Damage reported'
end

lib.callback.register('dps-cityworker:server:ReportDamage', function(source, damageType)
    return reportDamage(source, damageType)
end)

-- =====================================
-- ADMIN COMMANDS
-- =====================================

lib.addCommand('setsectorhealth', {
    help = 'Set a sector\'s health percentage (Admin)',
    params = {
        { name = 'sector', type = 'string', help = 'Sector ID (legion, mirror_park, sandy_shores)' },
        { name = 'health', type = 'number', help = 'Health percentage (0-100)' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local sector = args.sector
    local health = math.min(100, math.max(0, args.health))

    if not Config.Sectors[sector] then
        Bridge.Notify(source, 'Invalid sector ID', 'error')
        return
    end

    SetSectorHealth(sector, health)

    Bridge.Notify(source, ('Set %s health to %d%%'):format(Config.Sectors[sector].label, health), 'success')
end)

lib.addCommand('setcityrank', {
    help = 'Set a player\'s city worker rank, 1 to 5 (Admin)',
    params = {
        { name = 'target', type = 'playerId', help = 'Player id' },
        { name = 'rank', type = 'number', help = 'Rank 1-5' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local rank = math.floor(tonumber(args.rank) or 0)
    if not Config.Ranks[rank] then return Bridge.Notify(source, 'Rank is 1 to 5', 'error') end
    local target = args.target
    if not Bridge.GetIdentifier(target) then return Bridge.Notify(source, 'That player has no character loaded', 'error') end

    local p = Players[target]
    if p then
        p.rank, p.xp = rank, (rank - 1) * 1000
        SavePlayerStats(target, p)
    else
        local stats = GetPlayerStats(target)
        stats.rank, stats.xp = rank, (rank - 1) * 1000
        SavePlayerStats(target, stats)
    end
    Bridge.Notify(source, ('City worker rank set to %s'):format(Config.Ranks[rank].label), 'success')
    if target ~= source then Bridge.Notify(target, ('Your city worker rank is now %s'):format(Config.Ranks[rank].label), 'inform') end
end)

lib.addCommand('workstatus', {
    help = 'Check your city worker stats',
}, function(source)
    local stats = GetPlayerStats(source)
    local rankLabel = Config.Ranks[stats.rank] and Config.Ranks[stats.rank].label or 'Unknown'

    Bridge.Notify(source, ('Rank: %s | XP: %d/%d | Repairs: %d'):format(
        rankLabel,
        stats.xp,
        stats.rank * 1000,
        stats.total_repairs or 0
    ), 'inform')
end)

lib.addCommand('controlroom', {
    help = 'Open the Control Room dashboard (Foreman only)',
}, function(source)
    TriggerClientEvent('dps-cityworker:client:OpenControlRoom', source)
end)

lib.addCommand('reportdamage', {
    help = 'Report infrastructure damage at your location',
    params = {
        { name = 'type', type = 'string', help = 'Damage type (pothole, streetlight, pipe, electrical)', optional = true },
    },
}, function(source, args)
    local success, msg = reportDamage(source, args.type or 'general')

    if success then
        Bridge.Notify(source, 'Damage reported to dispatch', 'success')
    else
        Bridge.Notify(source, msg or 'Failed to report damage', 'error')
    end
end)

lib.addCommand('triggeremergency', {
    help = 'Trigger an emergency event (Admin)',
    params = {
        { name = 'type', type = 'string', help = 'Emergency type (water_main, gas_leak, downed_lines, fallen_tree)' },
        { name = 'sector', type = 'string', help = 'Sector ID (legion, mirror_park, sandy_shores)' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local emergencyType = args.type
    local sectorId = args.sector

    if not TaskTypes[emergencyType] or not TaskTypes[emergencyType].isEmergency then
        Bridge.Notify(source, 'Invalid emergency type', 'error')
        return
    end

    if not Config.Sectors[sectorId] then
        Bridge.Notify(source, 'Invalid sector ID', 'error')
        return
    end

    local success = TriggerEmergencyEvent(emergencyType, sectorId)
    if success then
        Bridge.Notify(source, ('Triggered %s in %s'):format(emergencyType, sectorId), 'success')
    else
        Bridge.Notify(source, 'Failed to trigger emergency (already active?)', 'error')
    end
end)

-- =====================================
-- EMERGENCY CALLBACKS
-- =====================================

lib.callback.register('dps-cityworker:server:GetActiveEmergencies', function(source)
    local emergencies = {}
    local p = Players[source]
    if not p then return emergencies end
    for sectorId, emergency in pairs(ActiveEmergencies) do
        local task = TaskTypes[emergency.type]
        if task and p.rank >= task.minRank then emergencies[sectorId] = {
            type = emergency.type,
            label = task and task.label or emergency.type,
            coords = emergency.coords,
            startTime = emergency.startTime,
            sectorLabel = Config.Sectors[sectorId] and Config.Sectors[sectorId].label or sectorId,
        } end
    end
    return emergencies
end)

local function atEmergency(source, em)
    if not em.coords then return true end
    local pos = GetEntityCoords(GetPlayerPed(source))
    return #(pos - vector3(em.coords.x, em.coords.y, em.coords.z)) <= (Config.EmergencyDistance or 20.0)
end

lib.callback.register('dps-cityworker:server:RespondToEmergency', function(source, sectorId)
    local p = Players[source]
    if not p then return false, 'Not on duty' end
    local emergency = ActiveEmergencies[sectorId]
    if not emergency then return false, 'No active emergency' end

    local task = TaskTypes[emergency.type]
    if p.rank < task.minRank then
        return false, ('Needs rank %d (%s)'):format(task.minRank, Config.Ranks[task.minRank].label)
    end
    if not atEmergency(source, emergency) then return false, 'You are not at the emergency' end

    -- The work starts now. It cannot be finished before the work time is up.
    p.emergency = { sector = sectorId, startedAt = os.time() }

    return true, {
        type = emergency.type,
        label = task.label,
        coords = emergency.coords,
        difficulty = task.difficulty,
        xp = task.xp,
        seconds = E.WorkSeconds or 15,
    }
end)

lib.callback.register('dps-cityworker:server:CompleteEmergency', function(source, sectorId)
    local p = Players[source]
    if not p then return false end
    local em = ActiveEmergencies[sectorId]
    if not em then return false end

    local mine = p.emergency
    if not mine or mine.sector ~= sectorId then return false end
    if os.time() - mine.startedAt < (E.WorkSeconds or 15) - 1 then return false end
    if p.rank < TaskTypes[em.type].minRank then return false end
    if not atEmergency(source, em) then return false end

    p.emergency = nil
    local done = ResolveEmergency(sectorId, source)
    if done then SavePlayerStats(source, p) end
    return done
end)

-- =====================================
-- CREW/TEAM SYSTEM
-- =====================================

lib.callback.register('dps-cityworker:server:GetActiveWorkers', function(source)
    local workers = {}
    for playerId, data in pairs(Players) do
        local ped = GetPlayerPed(playerId)
        if ped and DoesEntityExist(ped) then
            local coords = GetEntityCoords(ped)
            workers[playerId] = {
                name = Bridge.GetCharacterName(playerId),
                rank = data.rank,
                rankLabel = Config.Ranks[data.rank] and Config.Ranks[data.rank].label or 'Unknown',
                coords = coords,
                taskType = data.taskType,
            }
        end
    end
    return workers
end)

-- Foreman crew management
--- The jobs a foreman can hand out, for the menu.
lib.callback.register('dps-cityworker:server:TaskList', function(source)
    if not Players[source] or Players[source].rank < 5 then return {} end
    local list = {}
    for id, task in pairs(TaskTypes) do
        if not task.isEmergency then list[#list + 1] = { id = id, label = task.label, minRank = task.minRank } end
    end
    table.sort(list, function(a, b) return a.minRank < b.minRank or (a.minRank == b.minRank and a.label < b.label) end)
    return list
end)

lib.callback.register('dps-cityworker:server:AssignWorkerTask', function(source, targetId, taskType)
    if not Players[source] or Players[source].rank < 5 then
        return false, 'Only Foremen can assign tasks'
    end
    targetId = tonumber(targetId)
    if not targetId or targetId == source then return false, 'Pick another worker' end

    if not Players[targetId] then
        return false, 'Worker not on duty'
    end

    local task = TaskTypes[taskType]
    if not task then
        return false, 'Invalid task type'
    end

    if Players[targetId].rank < task.minRank then
        return false, 'Worker rank too low for this task'
    end
    if task.isEmergency then return false, 'Emergencies cannot be assigned' end
    if onCooldown(source, 'assign:' .. targetId, 300) then
        return false, 'You gave that worker a job a few minutes ago'
    end

    local target = Players[targetId]
    if target.task then target.lastLocation = target.task.location end
    if #Sites.of(taskType) == 0 then return false, 'No site is set up for that job' end
    local old = target.task
    local view = issueTask(targetId, taskType)
    if not view then
        target.task = old
        if old then target.taskType, target.location = old.type, old.location end
        return false, 'No free site for that job right now'
    end
    target.task.assignedBy = Bridge.GetCharacterName(source)
    view.assignedBy = target.task.assignedBy

    -- Notify the target worker
    TriggerClientEvent('dps-cityworker:client:TaskAssigned', targetId, view)

    return true, 'Task assigned'
end)

-- =====================================
-- EXPORTS
-- =====================================

exports('GetSectorHealth', function(sectorId)
    return SectorHealth[sectorId]
end)

exports('GetAllSectorHealth', function()
    return SectorHealth
end)

exports('TriggerBlackout', function(sectorId)
    local data = Config.Sectors[sectorId]
    if not data then return false end
    SetSectorHealth(sectorId, data.blackoutThreshold)
    return true
end)

exports('IsSectorDark', function(sectorId) return Blackouts[sectorId] == true end)
exports('GetSectorForCoords', GetSectorForCoords)

exports('GetPlayerSeniority', function(source)
    if Players[source] then
        return Players[source].rank
    end
    local stats = GetPlayerStats(source)
    return stats.rank
end)

exports('RepairSector', RepairSector)
exports('TriggerEmergency', TriggerEmergencyEvent)
exports('GetActiveEmergencies', function() return ActiveEmergencies end)
exports('ResolveEmergency', ResolveEmergency)
