local Config = lib.require('config')
local isHired, activeJob = false, false
local cityBoss, startZone, currZone, currentCone
local sitePoint = nil        -- the point that puts the site prop out when the worker is near
local JobBlip = nil
local CITY_BLIP = nil
local Depot = nil            -- vec4: where the boss stands. Sent by the server.
local CurrentTask = nil
local ControlRoomOpen = false
local Working = false        -- true while a repair is being done, so it cannot be started twice
local clockingOut = false

-- =====================================
-- TARGET HELPERS
-- =====================================

local function AddTargetEntity(entity, options)
    if GetResourceState('ox_target') == 'started' then
        local oxOptions = {}
        for _, opt in ipairs(options) do
            table.insert(oxOptions, {
                icon = opt.icon,
                label = opt.label,
                onSelect = opt.action,
                canInteract = opt.canInteract,
                distance = opt.distance or 2.0
            })
        end
        exports.ox_target:addLocalEntity(entity, oxOptions)
    else
        exports['qb-target']:AddTargetEntity(entity, { options = options, distance = 2.0 })
    end
end

local function RemoveTargetEntity(entity, labels)
    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeLocalEntity(entity, labels)
    else
        exports['qb-target']:RemoveTargetEntity(entity, labels)
    end
end

local function AddTargetZone(name, data, options)
    if GetResourceState('ox_target') == 'started' then
        local oxOptions = {}
        for _, opt in ipairs(options) do
            table.insert(oxOptions, {
                icon = opt.icon,
                label = opt.label,
                onSelect = opt.action,
                canInteract = opt.canInteract,
            })
        end
        return exports.ox_target:addSphereZone({
            name = name,
            coords = data.coords,
            radius = data.radius or 1.5,
            options = oxOptions,
        })
    else
        return exports['qb-target']:AddCircleZone(name, data.coords, data.radius or 1.5, {
            name = name,
            useZ = true,
        }, { options = options, distance = 2.0 })
    end
end

local function RemoveTargetZone(zone)
    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeZone(zone)
    else
        exports['qb-target']:RemoveZone(zone)
    end
end

-- =====================================
-- FORWARD DECLARATIONS
-- =====================================

local StopAllParticles -- Forward declaration for particle cleanup

-- =====================================
-- CLEANUP
-- =====================================

local function cleanupJob()
    -- Stop any active particle effects
    if StopAllParticles then StopAllParticles() end

    if sitePoint then
        sitePoint:remove()
        sitePoint = nil
    end
    if currZone then
        RemoveTargetZone(currZone)
        currZone = nil
    end
    if currentCone and DoesEntityExist(currentCone) then DeleteEntity(currentCone) end
    currentCone = nil
    if JobBlip then
        RemoveBlip(JobBlip)
        JobBlip = nil
    end
    CurrentTask = nil
    activeJob = false
end

--- The shift is over on this game: the job, its markers and the emergency
--- markers all go. Whether a shift is running is decided by the server.
local function leaveShift()
    cleanupJob()
    isHired = false
    if ClearEmergencies then ClearEmergencies() end
end

-- =====================================
-- TASK PROPS & ANIMATIONS
-- =====================================

local function GetTaskProp(taskType)
    local prop = Config.TaskProps and Config.TaskProps[taskType]
    if prop == false then return nil end   -- no marker for this job
    return prop or 'prop_roadcone02a'
end

local function GetTaskAnimation(category)
    if Config.TaskAnimations and Config.TaskAnimations[category] then
        return Config.TaskAnimations[category]
    end
    return { dict = 'amb@world_human_welding@male@base', anim = 'base' }
end

--- A model that is sure to exist: the one asked for, else a road cone.
local function safeModel(model)
    local hash = type(model) == 'string' and joaat(model) or model
    if hash and IsModelInCdimage(hash) and IsModelValid(hash) then return hash end
    return `prop_roadcone02a`
end

--- Puts a marker prop on the ground at a spot. Only called when the player is
--- near, so the ground is loaded. Returns nil if the game will not make it:
--- the job still works without the prop.
function SpawnTaskProp(taskType, coords)
    local wanted = GetTaskProp(taskType)
    if not wanted then return nil end
    local model = safeModel(wanted)
    local ok = pcall(lib.requestModel, model, 5000)
    if not ok then return nil end

    local z = coords.z - 1.0
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 0.5, false)
    if found then z = groundZ end

    local prop = CreateObject(model, coords.x, coords.y, z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not prop or prop == 0 then return nil end
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)
    return prop
end

-- =====================================
-- PARTICLE EFFECTS SYSTEM
-- =====================================

local ActiveParticles = {}

-- Particle definitions for task types
local TaskParticles = {
    pipe = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 2.0,
        offset = vec3(0, 0, 0.5),
    },
    water_main = {
        dict = 'core',
        name = 'exp_grd_water',
        scale = 3.0,
        offset = vec3(0, 0, 0.3),
    },
    gas_leak = {
        dict = 'core',
        name = 'exp_grd_smoke',
        scale = 2.0,
        offset = vec3(0, 0, 0.5),
    },
    downed_lines = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 1.5,
        offset = vec3(0, 0, 1.0),
    },
    electrical = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 0.8,
        offset = vec3(0, 0, 0.5),
    },
    transformer = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 1.2,
        offset = vec3(0, 0, 1.5),
    },
    hydrant = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 1.0,
        offset = vec3(0, 0, 0.8),
    },
    storm_drain = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 0.8,
        offset = vec3(0, 0, -0.5),
    },
}

local function StartTaskParticles(taskType, coords)
    local particleData = TaskParticles[taskType]
    if not particleData then return nil end

    -- Request particle asset
    RequestNamedPtfxAsset(particleData.dict)
    local waited = 0
    while not HasNamedPtfxAssetLoaded(particleData.dict) do
        Wait(10)
        waited = waited + 10
        if waited > 3000 then return nil end
    end

    UseParticleFxAsset(particleData.dict)

    local particleCoords = coords + particleData.offset

    -- Start looped particle effect
    local particle = StartParticleFxLoopedAtCoord(
        particleData.name,
        particleCoords.x, particleCoords.y, particleCoords.z,
        0.0, 0.0, 0.0,
        particleData.scale,
        false, false, false, false
    )

    ActiveParticles[taskType] = particle
    return particle
end

local function StopTaskParticles(taskType)
    if ActiveParticles[taskType] then
        StopParticleFxLooped(ActiveParticles[taskType], false)
        ActiveParticles[taskType] = nil
    end
end

StopAllParticles = function()
    for taskType, particle in pairs(ActiveParticles) do
        if DoesParticleFxLoopedExist(particle) then
            StopParticleFxLooped(particle, false)
        end
    end
    ActiveParticles = {}
end

-- =====================================
-- NEXT TASK
-- =====================================

function NextDelivery(data)
    if not data or not data.location then
        Bridge.Notify('No work site is free right now. Ask again from the job menu (/citywork).', 'inform')
        return
    end

    cleanupJob()
    activeJob = true
    CurrentTask = data

    local at = vec3(data.location.x, data.location.y, data.location.z)
    local taskType = data.taskType or 'pipe'

    -- Blip and route to the site
    JobBlip = AddBlipForCoord(at.x, at.y, at.z)
    SetBlipSprite(JobBlip, 566)
    SetBlipColour(JobBlip, 5)
    SetBlipRoute(JobBlip, true)
    SetBlipRouteColour(JobBlip, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName('Task: ' .. (data.label or taskType))
    EndTextCommandSetBlipName(JobBlip)

    -- The spot to work at. Made first, so the job works even if the prop does not.
    currZone = AddTargetZone('cityworker_task_' .. tostring(data.id), {
        coords = at,
        radius = 2.0,
    }, {
        {
            icon = 'fas fa-wrench',
            label = data.label or 'Repair',
            action = function()
                DoRepairTask()
            end,
            canInteract = function()
                return activeJob and isHired
            end,
        }
    })

    -- The prop and the effects go out when the worker gets near (the ground is
    -- loaded then) and come back in when they leave.
    local point = lib.points.new({ coords = at, distance = 60 })
    function point:onEnter()
        if sitePoint ~= self then return end
        if currentCone and DoesEntityExist(currentCone) then DeleteEntity(currentCone) end
        currentCone = SpawnTaskProp(taskType, at)
        pcall(StartTaskParticles, taskType, at)
    end
    function point:onExit()
        if sitePoint ~= self then return end
        if currentCone and DoesEntityExist(currentCone) then DeleteEntity(currentCone) end
        currentCone = nil
        StopAllParticles()
    end
    sitePoint = point

    Bridge.Notify('New task: ' .. (data.label or 'Repair Task'), 'inform')
end

local function finishTask(result, doneText)
    cleanupJob()

    local text = (doneText .. ' +$%d | +%d XP'):format(result.payment, result.xp)
    if (result.travelPay or 0) > 0 then text = text .. (' (driving money $%d)'):format(result.travelPay) end
    if (result.teamwork or 0) > 0 then text = text .. (' (teamwork +%d%%)'):format(result.teamwork) end
    Bridge.Notify(text, 'success')
    if result.sectorId then
        Bridge.Notify(('%s is now at %.0f%%'):format(result.sectorLabel or result.sectorId, result.sectorHealth), 'inform')
    end

    Wait(5000)
    if isHired and not CurrentTask then NextDelivery(result.nextTask) end
end

function DoRepairTask()
    if not activeJob or not CurrentTask or Working then return end
    Working = true
    local ok, err = pcall(DoRepairTaskInner, CurrentTask)
    Working = false
    ClearPedTasks(cache.ped)
    if not ok then print('[dps-cityworker] repair failed: ' .. tostring(err)) end
end

local WorkLabels = {
    pipe = 'Repairing pipe...',
    pothole = 'Filling pothole...',
    meter_reading = 'Reading meter...',
    hydrant = 'Fixing hydrant...',
    manhole = 'Checking manhole...',
    storm_drain = 'Clearing drain...',
    electrical = 'Repairing electrical box...',
    transformer = 'Servicing transformer...',
    bridge_inspection = 'Inspecting bridge...',
    utility_locating = 'Locating utilities...',
}

--- `job` is the job as it was when the work started. If the worker is given
--- another job half way through, this one is simply not paid.
function DoRepairTaskInner(job)
    -- The server checks you are at the site with your truck, and starts the clock
    local began, info = lib.callback.await('dps-cityworker:server:BeginTask', false, job.id)
    if not began then
        Bridge.Notify(info or 'You cannot start this job yet', 'error')
        return
    end

    local taskType = job.taskType or 'pipe'
    local animData = GetTaskAnimation(job.category or 'maintenance')
    pcall(lib.requestAnimDict, animData.dict, 5000)

    -- How long the work takes comes from the server (it will not pay sooner)
    local duration = (tonumber(info) or job.seconds or 8) * 1000

    local success = lib.progressBar({
        duration = duration,
        label = WorkLabels[taskType] or job.label or 'Working...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = animData.dict, clip = animData.anim },
    })

    if not success then
        Bridge.Notify('Task cancelled', 'error')
        return
    end

    -- The skill check comes from the server with the job
    if not lib.skillCheck(job.checks or Config.SkillCheck.Difficulty, Config.SkillCheck.Input) then
        Bridge.Notify('Task failed - try again!', 'error')
        return
    end

    local paymentSuccess, result = lib.callback.await('dps-cityworker:server:Payment', false, job.id)

    if paymentSuccess and result then
        finishTask(result, 'Job done!')
    else
        Bridge.Notify('The city could not sign this job off. Stay at the site and try again.', 'error')
    end
end

-- =====================================
-- WORK START/FINISH
-- =====================================

--- Keys come from the key script on this game. The server says when.
RegisterNetEvent('dps-cityworker:client:keys', function(plate, give)
    if type(plate) ~= 'string' then return end
    if GetResourceState('wasabi_carlock') == 'started' then
        pcall(function()
            if give then exports.wasabi_carlock:GiveKey(plate) else exports.wasabi_carlock:RemoveKey(plate) end
        end)
    elseif give then
        TriggerEvent('vehiclekeys:client:SetOwner', plate)
    end
end)

--- Engine and fuel for the truck, once this game can see it. The shift does
--- not wait for this: a truck that is slow to show up no longer locks anyone out.
local function readyTruck(netid)
    CreateThread(function()
        local waited = 0
        while not NetworkDoesEntityExistWithNetworkId(netid) do
            Wait(100)
            waited = waited + 100
            if waited >= 15000 then return end
        end
        local veh = NetToVeh(netid)
        if not veh or veh == 0 then return end
        SetVehicleEngineOn(veh, true, true, false)
        pcall(Bridge.SetVehicleFuel, veh, 100.0)
    end)
end

local function beginShift(task, resumed)
    isHired = true
    Bridge.Notify(resumed and 'You are still on shift. Here is your job.' or 'You started your shift. /citywork opens your job menu.', 'success')
    NextDelivery(task)
    ShowActiveEmergencies()
end

local function depotSpot()
    return Depot and vec3(Depot.x, Depot.y, Depot.z) or nil
end

local function finishWork()
    local spot = depotSpot()
    if not spot or #(GetEntityCoords(cache.ped) - spot) > 15.0 then
        Bridge.Notify('Return to HQ to clock out', 'error')
        return
    end

    if not isHired then return end

    clockingOut = true
    local success = lib.callback.await('dps-cityworker:server:clockOut', false)
    clockingOut = false
    if success then
        leaveShift()
        Bridge.Notify('You ended your shift', 'success')
    end
end

-- =====================================
-- BOSS PED
-- =====================================

local BOSS_OPTIONS = {'Start Work', 'Replace Work Truck', 'Job Menu', 'Finish Work', 'Sub-Contractor Office'}

local function yeetPed()
    if cityBoss and DoesEntityExist(cityBoss) then
        RemoveTargetEntity(cityBoss, BOSS_OPTIONS)
        DeleteEntity(cityBoss)
    end
    cityBoss = nil
end

local function spawnPed()
    if not Depot or (cityBoss and DoesEntityExist(cityBoss)) then return end

    local model = Config.BossModel
    if not pcall(lib.requestModel, model, 10000) then return end
    cityBoss = CreatePed(0, model, Depot.x, Depot.y, Depot.z, Depot.w, false, false)
    SetModelAsNoLongerNeeded(model)
    SetEntityAsMissionEntity(cityBoss, true, true)
    SetPedFleeAttributes(cityBoss, 0, 0)
    SetBlockingOfNonTemporaryEvents(cityBoss, true)
    SetEntityInvincible(cityBoss, true)
    FreezeEntityPosition(cityBoss, true)
    TaskStartScenarioInPlace(cityBoss, 'WORLD_HUMAN_CLIPBOARD', 0, true)

    local options = {
        {
            icon = 'fas fa-hard-hat',
            label = 'Start Work',
            action = function()
                local res = lib.callback.await('dps-cityworker:server:spawnVehicle', false)
                if not res or not res.ok then
                    Bridge.Notify(res and res.msg or 'Could not start work', 'error')
                    return
                end
                if res.netid then readyTruck(res.netid) end
                beginShift(res.task, res.resume)
            end,
            canInteract = function()
                return not isHired
            end,
        },
        {
            icon = 'fas fa-truck-pickup',
            label = 'Replace Work Truck',
            action = function()
                local netid, why = lib.callback.await('dps-cityworker:server:newTruck', false)
                if netid then
                    readyTruck(netid)
                    Bridge.Notify('Here is another truck. Look after this one.', 'success')
                else
                    Bridge.Notify(why or 'No truck available', 'error')
                end
            end,
            canInteract = function()
                return isHired
            end,
        },
        {
            icon = 'fas fa-clipboard-list',
            label = 'Job Menu',
            action = function()
                OpenWorkMenu()
            end,
            canInteract = function()
                return isHired
            end,
        },
        {
            icon = 'fas fa-sign-out-alt',
            label = 'Finish Work',
            action = function()
                finishWork()
            end,
            canInteract = function()
                return isHired
            end,
        },
    }

    -- The company office is the same man. (It used to be a second ped standing inside him.)
    local C = Config.Contractor or {}
    if C.enable and C.bossPed then
        options[#options + 1] = {
            icon = 'fas fa-building',
            label = 'Sub-Contractor Office',
            action = function()
                if OpenCompanyMenu then OpenCompanyMenu() end
            end,
        }
    end

    AddTargetEntity(cityBoss, options)
end

-- =====================================
-- DEPOT (blip, boss, where to clock in)
-- =====================================

--- The depot is wherever the server says it is. An admin can move it in game
--- with /cityspot depot and every player's map follows at once.
local function setDepot(d)
    if type(d) ~= 'table' or not d.x then return end

    yeetPed()
    if startZone then startZone:remove() startZone = nil end
    if CITY_BLIP then RemoveBlip(CITY_BLIP) end

    Depot = vec4(d.x + 0.0, d.y + 0.0, d.z + 0.0, (d.w or 0) + 0.0)

    CITY_BLIP = AddBlipForCoord(Depot.x, Depot.y, Depot.z)
    SetBlipSprite(CITY_BLIP, 566)
    SetBlipDisplay(CITY_BLIP, 4)
    SetBlipScale(CITY_BLIP, 0.8)
    SetBlipAsShortRange(CITY_BLIP, true)
    SetBlipColour(CITY_BLIP, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName("City Worker Job")
    EndTextCommandSetBlipName(CITY_BLIP)

    startZone = lib.points.new({
        coords = vec3(Depot.x, Depot.y, Depot.z),
        distance = 50,
        onEnter = spawnPed,
        onExit = yeetPed,
    })
end

AddStateBagChangeHandler('dpsCityDepot', 'global', function(_, _, value)
    setDepot(value)
end)

CreateThread(function()
    local waited = 0
    while not GlobalState.dpsCityDepot and waited < 30000 do
        Wait(500)
        waited = waited + 500
    end
    if not Depot then setDepot(GlobalState.dpsCityDepot) end
end)

-- =====================================
-- CONTROL ROOM NUI
-- =====================================

local function closeControlRoom()
    ControlRoomOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('dps-cityworker:client:OpenControlRoom', function()
    local canOpen, data = lib.callback.await('dps-cityworker:server:OpenControlRoom', false)
    if not canOpen then return end

    ControlRoomOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = data })
end)

RegisterNUICallback('closeUI', function(_, cb)
    closeControlRoom()
    cb('ok')
end)

-- The screen asks for fresh numbers every few seconds while it is open
RegisterNUICallback('refresh', function(_, cb)
    if not ControlRoomOpen then return cb({}) end
    local canOpen, data = lib.callback.await('dps-cityworker:server:OpenControlRoom', false)
    if not canOpen then
        closeControlRoom()
        return cb({})
    end
    cb(data or {})
end)

RegisterNUICallback('dispatchWorker', function(data, cb)
    local ok, msg = lib.callback.await('dps-cityworker:server:DispatchWorker', false, data.worker, data.sector)
    cb({ ok = ok and true or false, msg = msg or (ok and 'Sent' or 'Could not send that worker') })
end)

RegisterNUICallback('closeReport', function(data, cb)
    local ok = lib.callback.await('dps-cityworker:server:CloseReport', false, data.id)
    cb({ ok = ok and true or false })
end)

-- =====================================
-- BLACKOUT EFFECTS
-- =====================================

-- Which sectors are dark is kept by the server in GlobalState.dpsCityBlackouts.
-- Everyone reads the same list, so a repair turns the lights back on for all
-- and a player who joins later sees the blackout too.
local BlackoutActive = {}
local blackoutThread = false

local function insideDarkSector()
    local pos = GetEntityCoords(cache.ped)
    for sectorId in pairs(BlackoutActive) do
        local sector = Config.Sectors[sectorId]
        if sector and #(pos - sector.coords) < sector.radius then return true end
    end
    return false
end

local function runBlackouts()
    if blackoutThread then return end
    blackoutThread = true
    CreateThread(function()
        SetArtificialLightsStateAffectsVehicles(false)   -- headlights keep working
        while next(BlackoutActive) do
            if insideDarkSector() then
                SetArtificialLightsState(true)
                Wait(math.random(100, 500))
                SetArtificialLightsState(false)
                Wait(math.random(500, 2000))
            else
                Wait(1000)
            end
        end
        SetArtificialLightsState(false)
        blackoutThread = false
    end)
end

local function applyBlackouts(list)
    list = type(list) == 'table' and list or {}
    for sectorId in pairs(list) do
        local sector = Config.Sectors[sectorId]
        if sector and not BlackoutActive[sectorId] and (isHired or #(GetEntityCoords(cache.ped) - sector.coords) < sector.radius) then
            Bridge.Notify(('ALERT: %s has lost power!'):format(sector.label), 'error')
        end
    end
    for sectorId in pairs(BlackoutActive) do
        local sector = Config.Sectors[sectorId]
        if sector and not list[sectorId] and isHired then
            Bridge.Notify(('%s has power again'):format(sector.label), 'success')
        end
    end
    BlackoutActive = list
    if next(BlackoutActive) then runBlackouts() end
end

AddStateBagChangeHandler('dpsCityBlackouts', 'global', function(_, _, value)
    applyBlackouts(value)
end)

CreateThread(function()
    Wait(3000)
    applyBlackouts(GlobalState.dpsCityBlackouts)
end)

-- =====================================
-- EMERGENCY EVENTS
-- =====================================

local ActiveEmergencyBlips = {}
local EmergencyProps = {}
local EmergencyProximityPoints = {} -- Proximity points that auto-create zones
local EmergencyZoneCreated = {}     -- Track which sectors already have zones spawned
local EmergencyZones = {}           -- sector -> target zone, so it can be removed again

local function showEmergency(data, quiet)
    -- Create emergency blip
    if ActiveEmergencyBlips[data.sector] then
        RemoveBlip(ActiveEmergencyBlips[data.sector])
    end

    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, 126) -- Warning icon
    SetBlipColour(blip, 1) -- Red
    SetBlipScale(blip, 1.2)
    SetBlipFlashes(blip, true)
    SetBlipAsShortRange(blip, false) -- Always visible
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(('EMERGENCY: %s'):format(data.label))
    EndTextCommandSetBlipName(blip)

    ActiveEmergencyBlips[data.sector] = blip

    -- Alert notification with sound
    PlaySoundFrontend(-1, "TIMER_STOP", "HUD_MINI_GAME_SOUNDSET", true)

    -- Set up proximity point so the zone auto-creates when the player arrives
    -- This ensures props/particles/target appear even if the dialog is missed
    EmergencyZoneCreated[data.sector] = false

    -- Remove any previous proximity point for this sector
    if EmergencyProximityPoints[data.sector] then
        EmergencyProximityPoints[data.sector]:remove()
        EmergencyProximityPoints[data.sector] = nil
    end

    local emergencyData = data -- capture for closure
    local point = lib.points.new({
        coords = vec3(data.coords.x, data.coords.y, data.coords.z),
        distance = 80,
    })

    function point:onEnter()
        if isHired and not EmergencyZoneCreated[emergencyData.sector] then
            EmergencyZoneCreated[emergencyData.sector] = true
            CreateEmergencyZone(emergencyData)
        end
    end

    EmergencyProximityPoints[data.sector] = point
    if quiet then return end

    -- Only show detailed alert to on-duty workers
    if isHired then
        lib.notify({
            title = 'EMERGENCY ALERT',
            description = ('%s at %s!\nBonus XP: +%d'):format(data.label, data.sectorLabel, data.xpBonus),
            type = 'error',
            duration = 15000,
            icon = 'fa-solid fa-triangle-exclamation',
        })

        -- Offer to respond
        local response = lib.alertDialog({
            header = 'Emergency Response',
            content = ('**%s** reported at **%s**!\n\nThis is a high-priority emergency. Respond for bonus pay and XP.\n\nSet GPS to emergency location?'):format(data.label, data.sectorLabel),
            centered = true,
            cancel = true,
            labels = { confirm = 'Respond', cancel = 'Ignore' }
        })

        if response == 'confirm' then
            SetNewWaypoint(data.coords.x, data.coords.y)
            Bridge.Notify('GPS set to emergency. Hurry!', 'warning')

            -- Immediately create the zone if not already done by proximity
            if not EmergencyZoneCreated[data.sector] then
                EmergencyZoneCreated[data.sector] = true
                CreateEmergencyZone(data)
            end
        end
    else
        -- Non-workers just see the notification
        lib.notify({
            title = 'City Alert',
            description = ('%s reported at %s'):format(data.label, data.sectorLabel),
            type = 'warning',
            duration = 8000,
        })
    end
end

RegisterNetEvent('dps-cityworker:client:EmergencyAlert', function(data)
    showEmergency(data, false)
end)

--- Emergencies that were already running when this worker clocked in.
function ShowActiveEmergencies()
    local list = lib.callback.await('dps-cityworker:server:GetActiveEmergencies', false) or {}
    for sectorId, em in pairs(list) do
        if not ActiveEmergencyBlips[sectorId] then
            showEmergency({
                sector = sectorId, type = em.type, label = em.label,
                sectorLabel = em.sectorLabel, coords = em.coords, xpBonus = 0,
            }, true)
            Bridge.Notify(('Emergency in progress: %s at %s'):format(em.label, em.sectorLabel), 'warning')
        end
    end
end

function CreateEmergencyZone(data)
    local groundCoords = vec3(data.coords.x, data.coords.y, data.coords.z)

    -- Marker prop and effects. The zone below works even if these do not.
    if EmergencyProps[data.sector] and DoesEntityExist(EmergencyProps[data.sector]) then DeleteEntity(EmergencyProps[data.sector]) end
    EmergencyProps[data.sector] = SpawnTaskProp(data.type, groundCoords)
    pcall(StartTaskParticles, data.type, groundCoords)

    -- Create target zone at ground-corrected position
    local zoneName = 'emergency_' .. data.sector
    if EmergencyZones[data.sector] then RemoveTargetZone(EmergencyZones[data.sector]) end
    EmergencyZones[data.sector] = AddTargetZone(zoneName, {
        coords = groundCoords,
        radius = 3.0,
    }, {
        {
            icon = 'fas fa-exclamation-triangle',
            label = ('Respond: %s'):format(data.label),
            action = function()
                RespondToEmergency(data.sector)
            end,
            canInteract = function()
                return isHired
            end,
        }
    })
end

function RespondToEmergency(sectorId)
    local canRespond, emergencyData = lib.callback.await('dps-cityworker:server:RespondToEmergency', false, sectorId)

    if not canRespond then
        Bridge.Notify(emergencyData or 'Cannot respond to emergency', 'error')
        return
    end

    -- Emergency repair with higher stakes
    local animData = GetTaskAnimation('emergency')
    lib.requestAnimDict(animData.dict)

    local success = lib.progressBar({
        duration = (emergencyData.seconds or 15) * 1000, -- Emergencies take longer
        label = ('EMERGENCY: %s'):format(emergencyData.label),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = animData.dict, clip = animData.anim },
    })

    ClearPedTasks(cache.ped)

    if not success then
        Bridge.Notify('Emergency response cancelled!', 'error')
        return
    end

    -- Harder skill check for emergencies
    local passed = lib.skillCheck({'medium', 'hard', 'hard'}, Config.SkillCheck.Input)

    if not passed then
        Bridge.Notify('Emergency repair failed! Try again!', 'error')
        return
    end

    -- Complete the emergency
    local completed = lib.callback.await('dps-cityworker:server:CompleteEmergency', false, sectorId)

    if completed then
        Bridge.Notify('Emergency resolved! Great work!', 'success')

        -- Stop particle effects
        StopAllParticles()

        -- Clean up emergency prop
        if EmergencyProps[sectorId] then
            DeleteEntity(EmergencyProps[sectorId])
            EmergencyProps[sectorId] = nil
        end
    end
end

local function clearEmergency(sectorId)
    if ActiveEmergencyBlips[sectorId] then
        RemoveBlip(ActiveEmergencyBlips[sectorId])
        ActiveEmergencyBlips[sectorId] = nil
    end

    -- Remove proximity point
    if EmergencyProximityPoints[sectorId] then
        EmergencyProximityPoints[sectorId]:remove()
        EmergencyProximityPoints[sectorId] = nil
    end
    EmergencyZoneCreated[sectorId] = nil
    if EmergencyZones[sectorId] then
        RemoveTargetZone(EmergencyZones[sectorId])
        EmergencyZones[sectorId] = nil
    end

    if EmergencyProps[sectorId] then
        if DoesEntityExist(EmergencyProps[sectorId]) then DeleteEntity(EmergencyProps[sectorId]) end
        EmergencyProps[sectorId] = nil
        StopAllParticles()
    end
end

--- Every emergency marker on this game goes (end of shift).
function ClearEmergencies()
    local ids = {}
    for sectorId in pairs(ActiveEmergencyBlips) do ids[#ids + 1] = sectorId end
    for sectorId in pairs(EmergencyProximityPoints) do ids[#ids + 1] = sectorId end
    for _, sectorId in ipairs(ids) do clearEmergency(sectorId) end
end

RegisterNetEvent('dps-cityworker:client:EmergencyResolved', function(sectorId)
    local had = ActiveEmergencyBlips[sectorId] ~= nil
    clearEmergency(sectorId)

    local sector = Config.Sectors[sectorId]
    if sector and had and isHired then
        lib.notify({
            title = 'Emergency Resolved',
            description = ('%s emergency has been handled'):format(sector.label),
            type = 'success',
            duration = 5000,
        })
    end
end)

-- =====================================
-- WEATHER-TRIGGERED EVENTS
-- =====================================

RegisterNetEvent('dps-cityworker:client:WeatherTaskBonus', function(data)
    if not isHired then return end
    lib.notify({
        title = 'Weather Bonus Active',
        description = data.message,
        type = 'success',
        duration = 15000,
        icon = 'fa-solid fa-cloud-rain',
    })
end)

-- =====================================
-- CREW/TEAM SYSTEM
-- =====================================

-- Task assigned by foreman
RegisterNetEvent('dps-cityworker:client:TaskAssigned', function(data)
    if not isHired then return end

    -- Play notification sound
    PlaySoundFrontend(-1, "CHALLENGE_UNLOCKED", "HUD_AWARDS", true)

    lib.notify({
        title = 'Task Assigned',
        description = ('Foreman %s assigned you: %s'):format(data.assignedBy, data.label),
        type = 'inform',
        duration = 10000,
        icon = 'fa-solid fa-clipboard-list',
    })

    -- The new job replaces the current one
    NextDelivery(data)
end)

-- Asked to join a contractor's crew: the worker decides
lib.callback.register('dps-cityworker:client:crewInvite', function(companyName)
    local answer = lib.alertDialog({
        header = 'Crew invite',
        content = ('**%s** wants you on their work crew.\n\nYour jobs in their contract area count for them, and you get a share when the contract is done.'):format(tostring(companyName)),
        centered = true,
        cancel = true,
        labels = { confirm = 'Join', cancel = 'No thanks' },
    })
    return answer == 'confirm'
end)

-- =====================================
-- JOB MENU (/citywork)
-- =====================================

local function sectorLines()
    local sectors = lib.callback.await('dps-cityworker:server:GetSectorHealth', false) or {}
    local lines = {}
    for _, info in pairs(sectors) do
        lines[#lines + 1] = ('%s: %.0f%%'):format(info.label, info.health)
    end
    table.sort(lines)
    return table.concat(lines, '  \n')
end

local function assignMenu()
    local workers = lib.callback.await('dps-cityworker:server:GetActiveWorkers', false) or {}
    local tasks = lib.callback.await('dps-cityworker:server:TaskList', false) or {}
    local me = cache.serverId
    local options = {}
    for id, w in pairs(workers) do
        if tonumber(id) ~= me then
            options[#options + 1] = {
                title = w.name or ('Worker ' .. id),
                description = w.rankLabel,
                onSelect = function()
                    local pick = {}
                    for _, t in ipairs(tasks) do
                        if (w.rank or 1) >= t.minRank then pick[#pick + 1] = { value = t.id, label = t.label } end
                    end
                    local input = lib.inputDialog('Give a job to ' .. (w.name or id), {
                        { type = 'select', label = 'Job', options = pick, required = true },
                    })
                    if not input then return end
                    local ok, msg = lib.callback.await('dps-cityworker:server:AssignWorkerTask', false, tonumber(id), input[1])
                    Bridge.Notify(msg or (ok and 'Job given' or 'Could not give that job'), ok and 'success' or 'error')
                end,
            }
        end
    end
    if #options == 0 then options[1] = { title = 'No other workers on shift', disabled = true } end
    lib.registerContext({ id = 'cityworker_assign', title = 'Give a job', menu = 'cityworker_menu', options = options })
    lib.showContext('cityworker_assign')
end

function OpenWorkMenu()
    if not isHired then
        Bridge.Notify('You are not on shift. Start work at the city depot.', 'error')
        return
    end
    local stats = lib.callback.await('dps-cityworker:server:GetPlayerStats', false) or {}
    local options = {
        {
            title = ('%s'):format(stats.rankLabel or 'City worker'),
            description = ('XP %d / %d  |  Jobs done %d  |  Earned $%d'):format(
                math.floor(stats.xp or 0), math.floor(stats.xpNeeded or 0), math.floor(stats.total_repairs or 0), math.floor(stats.total_earnings or 0)),
            icon = 'fa-solid fa-id-badge',
            readOnly = true,
        },
        {
            title = CurrentTask and ('Current job: ' .. (CurrentTask.label or 'Repair')) or 'No job right now',
            description = CurrentTask and 'Set the GPS to the work site' or 'Ask the city for a job',
            icon = 'fa-solid fa-location-dot',
            onSelect = function()
                if CurrentTask then
                    SetNewWaypoint(CurrentTask.location.x, CurrentTask.location.y)
                    Bridge.Notify('GPS set to the work site', 'inform')
                    return
                end
                local ok, task = lib.callback.await('dps-cityworker:server:RequestTask', false)
                if not ok then return Bridge.Notify(task or 'No job right now', 'error') end
                NextDelivery(task)
            end,
        },
        {
            title = 'Swap this job',
            description = 'For a site you cannot reach. Limited to once every few minutes.',
            icon = 'fa-solid fa-shuffle',
            disabled = not CurrentTask,
            onSelect = function()
                local ok, task = lib.callback.await('dps-cityworker:server:SkipTask', false)
                if not ok then return Bridge.Notify(task or 'You cannot swap right now', 'error') end
                NextDelivery(task)
            end,
        },
        {
            title = 'City grid',
            description = sectorLines(),
            icon = 'fa-solid fa-bolt',
            readOnly = true,
        },
        {
            title = 'Report damage here',
            description = 'Log a fault where you are standing',
            icon = 'fa-solid fa-triangle-exclamation',
            onSelect = function()
                local input = lib.inputDialog('Report damage', {
                    { type = 'select', label = 'What is it?', required = true, default = 'general', options = {
                        { value = 'general', label = 'General damage' }, { value = 'pothole', label = 'Pothole' },
                        { value = 'streetlight', label = 'Streetlight' }, { value = 'pipe', label = 'Water pipe' },
                        { value = 'electrical', label = 'Electrical' },
                    } },
                })
                if not input then return end
                local ok, msg = lib.callback.await('dps-cityworker:server:ReportDamage', false, input[1])
                Bridge.Notify(msg or (ok and 'Reported' or 'Could not report'), ok and 'success' or 'error')
            end,
        },
    }
    if (stats.rank or 1) >= 5 then
        options[#options + 1] = {
            title = 'Control Room', description = 'Grid, workers on shift, damage reports, dispatch', icon = 'fa-solid fa-tower-broadcast',
            onSelect = function() TriggerEvent('dps-cityworker:client:OpenControlRoom') end,
        }
        options[#options + 1] = {
            title = 'Give a worker a job', icon = 'fa-solid fa-people-arrows',
            onSelect = assignMenu,
        }
    end
    lib.registerContext({ id = 'cityworker_menu', title = 'City Worker', options = options })
    lib.showContext('cityworker_menu')
end

RegisterCommand('citywork', function() OpenWorkMenu() end, false)

-- =====================================
-- SHIFT STATE (decided by the server)
-- =====================================

-- This script just started on this game: ask the server if a shift is running.
CreateThread(function()
    Wait(4000)
    if isHired then return end
    local onShift, task = lib.callback.await('dps-cityworker:server:ShiftState', false)
    if onShift and not isHired then
        isHired = true
        NextDelivery(task)
        ShowActiveEmergencies()
    end
end)

-- The server ended the shift (character switch, script restart, anything):
-- this game follows.
AddStateBagChangeHandler('dpsCityShift', nil, function(bagName, _, value)
    if bagName ~= ('player:%s'):format(cache.serverId) then return end
    if not value and isHired and not clockingOut then leaveShift() end
end)

-- =====================================
-- PLAYER LOAD/UNLOAD
-- =====================================

function OnPlayerLoaded()
    -- Nothing needed on load
end

function OnPlayerUnload()
    leaveShift()
end

-- =====================================
-- RESOURCE CLEANUP
-- =====================================

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        leaveShift()
        yeetPed()
        SetArtificialLightsState(false)
        if ControlRoomOpen then closeControlRoom() end
    end
end)

-- =====================================
-- EXPORTS
-- =====================================

exports('IsPlayerOnDuty', function()
    return isHired
end)

exports('GetNearestWorkZone', function()
    local playerPos = GetEntityCoords(cache.ped)
    local nearest = nil
    local nearestDist = math.huge

    for id, data in pairs(Config.Sectors) do
        local dist = #(playerPos - data.coords)
        if dist < nearestDist then
            nearest = id
            nearestDist = dist
        end
    end

    return nearest, nearestDist
end)
